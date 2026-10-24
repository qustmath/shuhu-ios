import Foundation
import StoreKit

// 苹果内购（IAP）支撑：先单后买契约（docs/pay/client-integration.md §2）的本地侧。
// 链路编排在 MembershipView，本文件只承载未完成单持久化与 StoreKit 验签解包。

/// 未完成支付单的本地持久化：Create 后立即落盘 payNo + appAccountToken + productId，
/// 购买中断/断网/被杀后启动重放 verify 用（契约 §2.1-2/5）。
/// UserDefaults 在卸载重装后清空——跨重装找回走 restore 端点 + Apple 侧交易；
/// 跨重装持久化（Keychain）是后续增强项。
struct PendingPurchase: Codable, Equatable, Sendable {
    let payNo: String
    let appAccountToken: String
    let productId: String
    let createdAt: Date
}

struct PendingPurchaseStore: Sendable {
    private let defaults: UserDefaults
    private static let key = "shufu.pendingPurchases"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ pending: PendingPurchase) {
        var all = list()
        all.removeAll { $0.payNo == pending.payNo }
        all.append(pending)
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: Self.key)
        }
    }

    func list() -> [PendingPurchase] {
        guard let data = defaults.data(forKey: Self.key),
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
            defaults.set(data, forKey: Self.key)
        }
    }
}

/// StoreKit 2 验签解包：未通过验证的交易一律视为无效（官方 recommended 模式）。
enum StoreKitVerifier {
    static func verified<T>(_ verification: Verification<T>) throws -> T {
        switch verification {
        case .verified(let safe):
            return safe
        case .unverified:
            throw ApiError(code: nil, "交易凭证验证失败")
        }
    }
}
