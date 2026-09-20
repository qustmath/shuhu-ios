import Foundation

// ---- 广告下发与上报 DTO（advertising 票 02 契约，与 Android `AdsApi` 一致）----

public struct AdCreativeData: Codable, Equatable, Sendable {
    public let id: Int64
    public let title: String
    public let imageUrl: String
    public let landingType: String
    public let landingTarget: String
    public var sortWeight: Int?

    public init(
        id: Int64, title: String, imageUrl: String,
        landingType: String, landingTarget: String, sortWeight: Int? = nil,
    ) {
        self.id = id
        self.title = title
        self.imageUrl = imageUrl
        self.landingType = landingType
        self.landingTarget = landingTarget
        self.sortWeight = sortWeight
    }
}

public struct AdActiveData: Codable, Sendable {
    public let slot: String
    public var creatives: [AdCreativeData]?
}

public struct AdReportRequest: Codable, Sendable {
    public let slot: String
    public let ids: [Int64]

    public init(slot: String, ids: [Int64]) {
        self.slot = slot
        self.ids = ids
    }
}

/// 广告位 code（与后端种子一致，CONTEXT.md 术语）。
public enum AdSlots {
    public static let splash = "splash"
    public static let homeListBottom = "home_list_bottom"
    /// 详情页第 2 条记录后内联卡（odui 改版新增）。
    public static let detailRecordsInline = "detail_records_inline"
}

/// 广告客户端（advertising 票 04/05 共享）：拉取生效素材 + 曝光/点击上报。
/// - 拉取带 3s 超时，失败/无素材一律返回空列表（不阻塞 UI、不 crash）
/// - 上报 fire-and-forget：异步发送、失败静默，绝不影响 UI 流程
/// - 客户端不做会员判断（免广告由服务端空结果驱动）
public struct AdsClient: Sendable {

    private let api: AdsApi

    public init(api: AdsApi) {
        self.api = api
    }

    /// 拉取某广告位当前生效素材；任何失败返回空列表。
    public func activeCreatives(slot: String) async -> [AdCreativeData] {
        do {
            return try await api.active(slot: slot).creatives ?? []
        } catch {
            return [] // 静默进主页
        }
    }

    /// 曝光上报（fire-and-forget）。
    public func reportImpressions(slot: String, ids: [Int64]) {
        report(slot: slot, ids: ids, impression: true)
    }

    /// 点击上报（fire-and-forget）。
    public func reportClicks(slot: String, ids: [Int64]) {
        report(slot: slot, ids: ids, impression: false)
    }

    private func report(slot: String, ids: [Int64], impression: Bool) {
        guard !ids.isEmpty else { return }
        Task {
            _ = try? await api.report(slot: slot, ids: ids, impression: impression)
        }
    }
}

/// 广告端点（可选会员鉴权：复用 authed 客户端，匿名/失效 token 均匿名放行，服务端永不 401）。
public struct AdsApi: Sendable {

    private let client: ApiClient

    /// 广告请求的独立超时（秒）：开屏拉取不阻塞启动。
    private let timeout: TimeInterval

    public init(client: ApiClient, timeout: TimeInterval = 3) {
        self.client = client
        self.timeout = timeout
    }

    public func active(slot: String) async throws -> AdActiveData {
        try await client.get(
            "api/v1/ads/active",
            query: [URLQueryItem(name: "slot", value: slot)],
            timeout: timeout,
        ).requireData()
    }

    public func report(slot: String, ids: [Int64], impression: Bool) async throws {
        let path = impression ? "api/v1/ads/impressions" : "api/v1/ads/clicks"
        let _: Envelope<EmptyData> = try await client.post(path, body: AdReportRequest(slot: slot, ids: ids), timeout: timeout)
    }
}
