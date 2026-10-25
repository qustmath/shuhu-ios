import Combine
import XCTest
@testable import Shuhu

/// IAPRecovery 编排逻辑（修复复核 R6）：经 IAPTransactionHandle 接缝注入内存交易，
/// 覆盖 verify 结算三落点与领养筛选。Transaction.updates 全环仍依赖真实 StoreKit，
/// 不在单测范围（逻辑入口 settle 已被本文件用例覆盖到判定层）。
@MainActor
final class IAPRecoveryTests: XCTestCase {

    private class FakeAuthRepository: AuthRepository {
        let session = CurrentValueSubject<AuthMember?, Never>(nil)
        var throwOnRefresh = false
        var refreshCount = 0

        func refreshProfile() async throws -> AuthMember {
            refreshCount += 1
            if throwOnRefresh { throw ApiError(code: nil, "登录失效") }
            return AuthMember(id: 1, phone: "13800001234", nickname: "tester")
        }

        // 未触达的成员：测试只覆盖支付恢复编排
        func sendSmsCode(phone: String, scene: String, method: String) async throws { fatalError("unused") }
        func sendBindPhoneCode(phone: String, scene: String, method: String) async throws { fatalError("unused") }
        func register(phone: String, password: String, code: String, method: String) async throws -> AuthMember { fatalError("unused") }
        func resetPassword(phone: String, code: String, newPassword: String, method: String) async throws { fatalError("unused") }
        func bindPhone(phone: String, code: String, oldCode: String?, scene: String, method: String) async throws -> AuthMember { fatalError("unused") }
        func login(phone: String, password: String) async throws -> AuthMember { fatalError("unused") }
        func loginWithWechatDev(devCode: String) async throws -> AuthMember { fatalError("unused") }
        func loginWithWechat(code: String) async throws -> AuthMember { fatalError("unused") }
        func bindWechat(code: String) async throws -> AuthMember { fatalError("unused") }
        func unbindWechat(identityId: Int64) async throws -> AuthMember { fatalError("unused") }
        func setPassword(_ newPassword: String) async throws -> AuthMember { fatalError("unused") }
        func logout() async { fatalError("unused") }
        func updateNickname(_ nickname: String) async throws -> AuthMember { fatalError("unused") }
        func updateAvatar(imageBytes: Data, ext: String) async throws -> AuthMember { fatalError("unused") }
    }

    /// 内存交易句柄（生产是 StoreKit.Transaction 适配）。
    private class FakeTransaction: IAPTransactionHandle, @unchecked Sendable {
        let transactionID: String
        let accountToken: UUID?
        let storeProductID: String
        private(set) var finished = false

        init(id: String, token: UUID?, product: String = "shuhu.member.yearly") {
            self.transactionID = id
            self.accountToken = token
            self.storeProductID = product
        }

        func markFinished() async { finished = true }
    }

    private var kv: InMemoryKVStore!
    private var store: PendingPurchaseStore!
    private var auth: FakeAuthRepository!
    private var client: MembershipClient!
    private var recovery: IAPRecovery!

    override func setUpWithError() throws {
        kv = InMemoryKVStore()
        store = PendingPurchaseStore(store: kv)
        auth = FakeAuthRepository()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let apiClient = ApiClient(baseURL: URL(string: "https://test.local")!, session: URLSession(configuration: config))
        client = MembershipClient(client: apiClient)
        recovery = IAPRecovery(
            client: client,
            auth: auth,
            store: store,
        )
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
    }

    /// Keychain 写失败桩（N17：孤儿领养落盘失败时的降级语义）。
    private class FailingKVStore: SecureKVStore {
        func data(forKey key: String) -> Data? { nil }
        @discardableResult func set(_ data: Data, forKey key: String) -> Bool { false }
        func removeValue(forKey key: String) {}
    }

    private let token = UUID(uuidString: "A1B2C3D4-0000-0000-0000-000000000001")!

    // verify success → .fulfilled：finish、清留存、刷快照
    func testVerifyAndSettle_fulfilled() async throws {
        let pending = PendingPurchase(payNo: "PAY1", appAccountToken: token.uuidString, productId: "shuhu.member.yearly", createdAt: .now)
        store.save(pending)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/mods/pay/apple/verify")
            return TestResponses.ok(AppleVerifyData(payNo: "PAY1", status: "success"))
        }
        let transaction = FakeTransaction(id: "2000000012345678", token: token)

        let outcome = await recovery.verifyAndSettle(payNo: "PAY1", transaction: transaction)

        guard case .fulfilled = outcome else { return XCTFail("期望 fulfilled，实得 \(outcome)") }
        XCTAssertTrue(transaction.finished, "成功后必须 finish（契约 §2.1-4 之外不允许早 finish）")
        XCTAssertNil(store.pending(appAccountToken: token.uuidString), "已履约单清留存")
        XCTAssertEqual(auth.refreshCount, 0, "N3：刷新归调用方，共享函数不刷")
    }

    // 服务端已确认但分发未完成 → .dispatchPending：不 finish、不清留存
    func testVerifyAndSettle_dispatchPendingKeepsUnfinished() async throws {
        let pending = PendingPurchase(payNo: "PAY1", appAccountToken: token.uuidString, productId: "shuhu.member.yearly", createdAt: .now)
        store.save(pending)
        MockURLProtocol.handler = { _ in
            TestResponses.ok(AppleVerifyData(payNo: "PAY1", status: "paying"))
        }
        let transaction = FakeTransaction(id: "2000000012345678", token: token)

        let outcome = await recovery.verifyAndSettle(payNo: "PAY1", transaction: transaction)

        guard case .dispatchPending = outcome else { return XCTFail("期望 dispatchPending，实得 \(outcome)") }
        XCTAssertFalse(transaction.finished, "分发未完成不得 finish")
        XCTAssertNotNil(store.pending(appAccountToken: token.uuidString), "保持未完成待下轮重放")
    }

    // 410 → .expiredOrder：清留存（R4/R5——重放不永久撞 410）且不 finish
    func testVerifyAndSettle_expiredOrderClearsPending() async throws {
        let pending = PendingPurchase(payNo: "PAY1", appAccountToken: token.uuidString, productId: "shuhu.member.yearly", createdAt: .now)
        store.save(pending)
        MockURLProtocol.handler = { _ in
            TestResponses.businessError(code: 410, message: "订单已过期，请重新下单")
        }
        let transaction = FakeTransaction(id: "2000000012345678", token: token)

        let outcome = await recovery.verifyAndSettle(payNo: "PAY1", transaction: transaction)

        guard case .expiredOrder = outcome else { return XCTFail("期望 expiredOrder，实得 \(outcome)") }
        XCTAssertNil(store.pending(appAccountToken: token.uuidString), "410 必须清留存，否则重放永久撞 410")
        XCTAssertFalse(transaction.finished)
    }

    // 领养筛选（纯函数）：success+txid 精确优先；回退认领 created/paying（R5，票 17 后安全）
    func testAdoptableRecord_filters() {
        let records = [
            RestoreTransactionData(payNo: "PAY1", status: "success", productId: nil, amount: nil, currency: nil, transactionId: "2000000012345678", paidAt: nil),
            RestoreTransactionData(payNo: "PAY2", status: "refunded", productId: nil, amount: nil, currency: nil, transactionId: "2000000012345679", paidAt: nil),
            RestoreTransactionData(payNo: "PAY4", status: "paying", productId: nil, amount: nil, currency: nil, transactionId: nil, paidAt: nil),
        ]

        let adopted = IAPRecovery.adoptableRecord(in: records, transactionId: "2000000012345678")
        XCTAssertEqual(adopted?.payNo, "PAY1", "精确匹配优先")

        // 无精确匹配 → 回退认领 created/paying 单（verify 交服务端全量校验）
        XCTAssertEqual(IAPRecovery.adoptableRecord(in: records, transactionId: "2000000012345670")?.payNo, "PAY4")

        // refunded/closed/failed 不领养
        let terminal = [records[1]]
        XCTAssertNil(IAPRecovery.adoptableRecord(in: terminal, transactionId: "2000000012345679"))
    }

    // N15：孤儿领养的 restore 网络失败必须抛出（settle 包装 .failed → replayOnce 标可重试），
    // 静默 nil 会让恢复页把网络失败误报成「未找到可恢复的购买记录」
    func testAdoptOrphan_restoreNetworkFailureThrows() async throws {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let transaction = FakeTransaction(id: "2000000012345678", token: token)

        do {
            _ = try await recovery.adoptOrphan(transaction: transaction, token: token.uuidString)
            XCTFail("restore 网络失败应抛出而非静默返回 nil")
        } catch {
            XCTAssertTrue(IAPRecovery.isRetryableRestoreError(error), "网络错误必须判为可重试")
        }
    }

    // 服务端可达但无单据 → nil 而非抛错：保持未完成等人工核验不是「失败」
    func testAdoptOrphan_noRecordsReturnsNil() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/mods/pay/apple/restore")
            return TestResponses.ok(AppleRestoreData(transactions: [], needsManualReview: false))
        }
        let transaction = FakeTransaction(id: "2000000012345678", token: token)

        let adopted = try await recovery.adoptOrphan(transaction: transaction, token: token.uuidString)

        XCTAssertNil(adopted)
    }

    // N16：sync/restore 的用户取消（登录/验证弹窗点取消）不是网络/服务故障
    func testUserCancellationIsNotServiceFailure() {
        XCTAssertTrue(IAPRecovery.isUserCancellation(SKError(.paymentCancelled)))
        XCTAssertFalse(IAPRecovery.isUserCancellation(URLError(.timedOut)))
        XCTAssertFalse(IAPRecovery.isUserCancellation(ApiError(code: 500, "服务器错误")))
    }

    // N17：孤儿领养的 pending 落盘失败不阻断领养——内存 pending 继续参与 verify（锁定降级语义）
    func testAdoptOrphan_saveFailureStillAdopts() async throws {
        MockURLProtocol.handler = { _ in
            TestResponses.ok(AppleRestoreData(transactions: [
                RestoreTransactionData(payNo: "PAY1", status: "success", productId: "shuhu.member.yearly", amount: nil, currency: nil, transactionId: "2000000012345678", paidAt: nil),
            ], needsManualReview: false))
        }
        let failingRecovery = IAPRecovery(
            client: client,
            auth: auth,
            store: PendingPurchaseStore(store: FailingKVStore()),
        )
        let transaction = FakeTransaction(id: "2000000012345678", token: token)

        let adopted = try await failingRecovery.adoptOrphan(transaction: transaction, token: token.uuidString)

        XCTAssertEqual(adopted?.payNo, "PAY1", "落盘失败只留痕不阻断：内存 pending 继续参与 verify")
    }
}
