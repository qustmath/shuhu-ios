import Foundation
import StoreKit
import Security

// 苹果内购（IAP）支撑：先单后买契约（docs/pay/client-integration.md §2）的本地侧。
// 链路编排在 MembershipView（购买）与 IAPRecovery（启动重放/updates 监听/恢复）。

// ---------------------------------------------------------------------------
// 未完成单持久化（契约 §2.1-2：Keychain 等跨重装存储——审查 S-C1，UserDefaults
// 卸载重装即丢、restore 也找不回 token）
// ---------------------------------------------------------------------------

/// Keychain 通用存取接缝（测试注入内存实现）。
protocol SecureKVStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    func removeValue(forKey key: String)
}

/// Keychain Generic Password 存取（TokenStore 同款实现，独立 service 隔离支付数据）。
struct KeychainStore: SecureKVStore {
    private let service: String

    init(service: String = "ink.groovy.shuhu.pay") {
        self.service = service
    }

    func data(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func set(_ data: Data, forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // 先 update 后 add（R7）：先删后加在 add 失败时会丢旧值
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        assert(addStatus == errSecSuccess, "Keychain add 失败: \(addStatus)")
    }

    func removeValue(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// 测试用内存实现。
final class InMemoryKVStore: SecureKVStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func set(_ data: Data, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = data
    }

    func removeValue(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
}

struct PendingPurchase: Codable, Equatable, Sendable {
    let payNo: String
    let appAccountToken: String
    let productId: String
    let createdAt: Date
}

struct PendingPurchaseStore: Sendable {
    private let store: SecureKVStore
    private static let key = "pendingPurchases"

    init(store: SecureKVStore = KeychainStore()) {
        self.store = store
    }

    func save(_ pending: PendingPurchase) {
        var all = list()
        all.removeAll { $0.payNo == pending.payNo }
        all.append(pending)
        if let data = try? JSONEncoder().encode(all) {
            store.set(data, forKey: Self.key)
        }
    }

    func list() -> [PendingPurchase] {
        guard let data = store.data(forKey: Self.key),
              let all = try? JSONDecoder().decode([PendingPurchase].self, from: data) else { return [] }
        return all
    }

    /// 按交易回传的 appAccountToken 找单（UUID 字符串大小写不敏感）。
    func pending(appAccountToken: String) -> PendingPurchase? {
        list().first { $0.appAccountToken.caseInsensitiveCompare(appAccountToken) == .orderedSame }
    }

    func remove(payNo: String) {
        var all = list()
        all.removeAll { $0.payNo == payNo }
        if let data = try? JSONEncoder().encode(all) {
            store.set(data, forKey: Self.key)
        }
    }
}

// ---------------------------------------------------------------------------
// 交易句柄接缝（修复复核 R6）：IAPRecovery 的编排逻辑面向本接缝编写，生产由
// StoreKit.Transaction 适配、测试注入内存实现——不依赖不可构造的 StoreKit 类型。
protocol IAPTransactionHandle: Sendable {
    var transactionID: String { get }
    var accountToken: UUID? { get }
    var storeProductID: String { get }
    func markFinished() async
}

extension StoreKit.Transaction: IAPTransactionHandle {
    var transactionID: String { "\(id)" }
    var accountToken: UUID? { appAccountToken }
    var storeProductID: String { productID }
    func markFinished() async { await finish() }
}

// ---------------------------------------------------------------------------
// 恢复编排（契约 §2.1-5，审查 S-C2/S-C4）：app 级常驻——启动遍历未完成交易重放
// verify + 监听 Transaction.updates（家长批准等异步交易落地的唯一入口，重进页面
// 才处理是不实承诺）。归属判定：appAccountToken 匹配本地留存单直接重放；对不上的
// 孤儿交易（重装/清数据）先按交易自带 token 走服务端 restore 找回单据再 verify。
// @MainActor：由 AppContainer 装配并起 Task，全部方法运行在主 actor（体量小无性能顾虑）。
// ---------------------------------------------------------------------------

@MainActor
final class IAPRecovery {

    private let client: MembershipClient
    private let auth: any AuthRepository
    /// 未完成单存储（购买页与恢复编排共用同一实例）。
    let pendingStore: PendingPurchaseStore
    private var started = false

    init(client: MembershipClient, auth: any AuthRepository, store: PendingPurchaseStore = PendingPurchaseStore()) {
        self.client = client
        self.auth = auth
        self.pendingStore = store
    }

    /// 幂等启动：先重放存量未完成交易，再常驻监听 updates。
    func start() {
        guard !started else { return }
        started = true
        Task { _ = await replayOnce() }
        Task { await listenUpdates() }
    }

    /// 单轮重放（恢复购买页/测试入口调用），返回本轮 verify 成功的单数。
    func replayOnce() async -> Int {
        var fulfilled = 0
        for await result in Transaction.unfinished {
            let transaction: StoreKit.Transaction
            switch result {
            case .verified(let safe):
                transaction = safe
            case .unverified:
                continue
            }
            if await settle(transaction: transaction) {
                fulfilled += 1
            }
        }
        return fulfilled
    }

    private func listenUpdates() async {
        for await update in Transaction.updates {
            let transaction: StoreKit.Transaction
            switch update {
            case .verified(let safe):
                transaction = safe
            case .unverified:
                continue
            }
            await settle(transaction: transaction)
        }
    }

    /// 认领一笔未完成交易：找单（本地留存 → 孤儿领养）→ verify → finish → 刷快照。
    /// 返回是否完成履约确认。
    private func settle(transaction: any IAPTransactionHandle) async -> Bool {
        guard let token = transaction.accountToken?.uuidString else { return false }
        var pending = pendingStore.pending(appAccountToken: token)
        if pending == nil {
            // 孤儿交易：本地对不上（重装/清数据）——按交易自带 token 走服务端台账找回
            //（S-C4：不能保持未完成干等人工核验，用户侧无任何恢复动作）
            pending = await adoptOrphan(transaction: transaction, token: token)
        }
        guard let pending else { return false }
        switch await verifyAndSettle(payNo: pending.payNo, transaction: transaction) {
        case .fulfilled:
            _ = try? await auth.refreshProfile() // 后台路径尽力刷新快照（N3：刷新归调用方）
            return true
        default:
            return false
        }
    }

    /// restore 找回台账：只认 status=success 且 transactionId 一致的记录（refunded 不得补发）；
    /// needs_manual_review 是隐私边界（零交易字段），保持未完成等人工核验。
    private func adoptOrphan(transaction: any IAPTransactionHandle, token: String) async -> PendingPurchase? {
        guard let data = try? await client.restore(appAccountToken: token),
              let records = data.transactions,
              let match = Self.adoptableRecord(in: records, transactionId: transaction.transactionID),
              let payNo = match.payNo, !payNo.isEmpty
        else { return nil }
        let pending = PendingPurchase(
            payNo: payNo,
            appAccountToken: token,
            productId: match.productId ?? transaction.storeProductID,
            createdAt: .now,
        )
        pendingStore.save(pending)
        return pending
    }

    /// 领养筛选（纯函数，R6 测试点）：success 且 transactionId 一致精确认领；无精确
    /// 匹配时回退认领 created/paying 单（修复复核 R5——重装/清数据场景该单尚未
    /// verify 过、台账无交易号）。安全性：服务端 verify 全量校验（token/产品/金额），
    /// 同单第二笔支付由主线票 17+整改兜底（channel_mismatch，客户端不 finish），
    /// refunded/closed/failed 不领养。
    static func adoptableRecord(
        in records: [RestoreTransactionData],
        transactionId: String,
    ) -> RestoreTransactionData? {
        if let exact = records.first(where: { $0.status == "success" && $0.transactionId == transactionId }) {
            return exact
        }
        return records.first { $0.status == "created" || $0.status == "paying" }
    }

    enum VerifyOutcome {
        case fulfilled        // verify 成功 + finish 完成
        case dispatchPending  // 服务端已确认但分发未完成（交易保持未完成）
        case expiredOrder     // 410：留存已清，换单重下
        case failed(Error)
    }

    /// verify → finish → 清留存（交互式购买与后台重放共用的唯一实现，审查 R4——
    /// 410 清留存收敛在此，两条路径行为一致）。不负责刷新资料（N3）：交互式路径走
    /// refreshAndComplete（失败可软提示），后台路径自行 try? 刷新——共享函数内刷新
    /// 会让交互式路径连刷两次，第二次失败在支付已成功时误提示。
    func verifyAndSettle(payNo: String, transaction: any IAPTransactionHandle) async -> VerifyOutcome {
        do {
            let status = try await client.verify(payNo: payNo, transactionId: transaction.transactionID)
            guard status == "success" else { return .dispatchPending }
            pendingStore.remove(payNo: payNo)
            await transaction.markFinished()
            return .fulfilled
        } catch let apiError as ApiError where apiError.code == 410 {
            // 410 订单过期且交易不匹配：换单重下——清掉本地留存（S-C5，否则重放永久撞 410）
            pendingStore.remove(payNo: payNo)
            return .expiredOrder
        } catch {
            return .failed(error) // 网络/5xx 等：保持未完成，下轮/updates 再试
        }
    }
}
