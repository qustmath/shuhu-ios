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
}
