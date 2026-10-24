import Foundation

// ---- 会员套餐与购买 DTO（与 Android `MembershipApi` 一致）----

/// 会员套餐（付费会员）：四档固定，价格/文案/开关由后台「营销中心 → 会员套餐」配置。
public struct MemberPlanData: Codable, Equatable, Sendable {
    public let id: Int64
    public let code: String
    public let name: String
    /// 价格（分）。
    public let priceCents: Int
    /// 时长（天）；0 或负 = 终身买断。
    public let durationDays: Int
    public var unitLabel: String?
    public var tagLabel: String?
    public var subLabel: String?
    public var sortWeight: Int?

    public init(
        id: Int64, code: String, name: String, priceCents: Int, durationDays: Int,
        unitLabel: String? = nil, tagLabel: String? = nil, subLabel: String? = nil, sortWeight: Int? = nil,
    ) {
        self.id = id
        self.code = code
        self.name = name
        self.priceCents = priceCents
        self.durationDays = durationDays
        self.unitLabel = unitLabel
        self.tagLabel = tagLabel
        self.subLabel = subLabel
        self.sortWeight = sortWeight
    }

    public var isLifetime: Bool { durationDays <= 0 }

    /// 价格文案：68 / 5.70（分 → 元，整元不带小数点）。
    public var priceLabel: String {
        if priceCents % 100 == 0 { return "\(priceCents / 100)" }
        return String(format: "%.2f", Double(priceCents) / 100)
    }
}

public struct MemberPlansData: Codable, Sendable {
    public var plans: [MemberPlanData]?
}

public struct MockPurchaseRequest: Encodable, Sendable {
    public let planId: Int64
}

/// 购买（模拟支付成功）后的会员状态。expireAt = nil 表示终身买断有效。
public struct MembershipPurchaseData: Codable, Sendable {
    public let level: Int?
    public let expireAt: String?
}

/// 会员套餐客户端（付费会员）：套餐查询 + 模拟支付购买。
/// 与 AdsClient 同约：网络层 5s 超时；业务失败抛中文 ApiError（UI 层决定提示形态）。
/// 客户端不自行判断会员状态（免广告由服务端空结果驱动，见 AdsClient）。
public struct MembershipClient: Sendable {

    private let client: ApiClient
    private let timeout: TimeInterval

    public init(client: ApiClient, timeout: TimeInterval = 5) {
        self.client = client
        self.timeout = timeout
    }

    /// 上架套餐列表（排序权重降序，服务端已排好）。
    public func plans() async throws -> [MemberPlanData] {
        let data: MemberPlansData = try await client
            .get("api/v1/membership/plans", timeout: timeout)
            .requireData()
        return data.plans ?? []
    }

    /// 模拟支付购买：服务端直接下发所选套餐的会员权益，返回最新会员状态。
    public func purchase(planId: Int64) async throws -> MembershipPurchaseData {
        try await client.post(
            "api/v1/membership/mock-purchase",
            body: MockPurchaseRequest(planId: planId),
            timeout: timeout,
        ).requireData()
    }

    // ---- 真实支付（pay 模块，Apple 内购先单后买，docs/pay/client-integration.md §2）----

    /// 真实支付下单（channel=apple_iap）：只创建支付单不发货。应答带 payNo +
    /// appAccountToken + productId；同套餐有效单重复下单由服务端幂等命中。
    public func createOrder(planId: Int64) async throws -> MembershipOrderData {
        let data: MembershipOrderData = try await client.post(
            "api/v1/membership/purchase",
            body: CreateOrderRequest(planId: planId, channel: "apple_iap"),
            timeout: timeout,
        ).requireData()
        return data
    }

    /// 服务端验证（先单后买第 ④ 步）：凭交易号走 App Store Server API 拉取并验签，
    /// status=success 即已进入发货分发。验证成功前不得 transaction.finish()。
    public func verify(payNo: String, transactionId: String) async throws -> String {
        let data: AppleVerifyData = try await client.post(
            "api/v1/mods/pay/apple/verify",
            body: AppleVerifyRequest(payNo: payNo, transactionId: transactionId),
            timeout: timeout,
        ).requireData()
        return data.status ?? ""
    }

    /// 恢复购买（换机/重装）：按 appAccountToken 找回本系统台账明细。
    /// 归属不匹配时服务端只回 needsManualReview（不泄露交易信息），引导联系客服。
    public func restore(appAccountToken: String) async throws -> AppleRestoreData {
        try await client.post(
            "api/v1/mods/pay/apple/restore",
            body: AppleRestoreRequest(appAccountToken: appAccountToken),
            timeout: timeout,
        ).requireData()
    }
}

// ---- 真实支付 DTO ----

public struct CreateOrderRequest: Codable, Sendable {
    public let planId: Int64
    public let channel: String

    public init(planId: Int64, channel: String) {
        self.planId = planId
        self.channel = channel
    }
}

/// 下单应答（不发货，发货走服务端支付分发回调）。
public struct MembershipOrderData: Codable, Sendable {
    public let payNo: String?
    public let channel: String?
    public let status: String?
    /// 金额（分；apple_iap 取价目表）。
    public let amount: Int64?
    /// 微信渠道调起七元组（iOS 不用）。
    public let invoke: [String: String]?
    /// StoreKit .appAccountToken 绑定用（每单一个）。
    public let appAccountToken: String?
    public let productId: String?
}

public struct AppleVerifyRequest: Codable, Sendable {
    public let payNo: String
    public let transactionId: String
    public let jws: String?

    public init(payNo: String, transactionId: String, jws: String? = nil) {
        self.payNo = payNo
        self.transactionId = transactionId
        self.jws = jws
    }
}

public struct AppleVerifyData: Codable, Sendable {
    public let payNo: String?
    public let status: String?
}

public struct AppleRestoreRequest: Codable, Sendable {
    public let appAccountToken: String?
    public let originalTransactionId: String?

    public init(appAccountToken: String? = nil, originalTransactionId: String? = nil) {
        self.appAccountToken = appAccountToken
        self.originalTransactionId = originalTransactionId
    }
}

/// 台账明细（含全部状态单：仅 status=success 是已履约/可补发；refunded 不得重新发放）。
public struct RestoreTransactionData: Codable, Sendable {
    public let payNo: String?
    public let status: String?
    public let productId: String?
    public let amount: Int64?
    public let currency: String?
    public let transactionId: String?
    public let paidAt: String?
}

public struct AppleRestoreData: Codable, Sendable {
    public let transactions: [RestoreTransactionData]?
    public let needsManualReview: Bool?
}
