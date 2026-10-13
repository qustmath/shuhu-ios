import Foundation

// ---- 建议与反馈 DTO（与 Android `FeedbackApi` 一致；feedback mod，ADR-0008）----

/// 反馈类型（服务端白名单校验）。
public enum FeedbackType {
    public static let suggestion = "suggestion"
    public static let bug = "bug"
    public static let other = "other"

    /// 类型枚举 → 展示文案（历史列表与类型选择共用）。
    public static func label(of type: String?) -> String {
        switch type {
        case suggestion: return "建议"
        case bug: return "问题"
        case other: return "其他"
        default: return type ?? ""
        }
    }
}

/// 反馈状态：pending 待处理 / replied 已回复（后台回复即翻转）。
public enum FeedbackStatus {
    public static let pending = "pending"
    public static let replied = "replied"

    public static func label(of status: String?) -> String {
        status == replied ? "已回复" : "待处理"
    }
}

public struct FeedbackSubmitRequest: Encodable, Sendable {
    public let type: String
    public let content: String
    public let contact: String
    public let images: [String]
}

/// 我的反馈条目（含官方回复）。字段全部可选：坏数据降级为空展示，不炸解码。
public struct FeedbackItemData: Codable, Equatable, Sendable {
    public let id: Int64
    public var type: String?
    public var content: String?
    public var contact: String?
    public var images: [String]?
    public var status: String?
    public var reply: String?
    public var repliedAt: String?
    public var createdAt: String?
}

public struct FeedbackListData: Codable, Sendable {
    public var list: [FeedbackItemData]?
    public var total: Int64?
}

public struct FeedbackUploadData: Codable, Sendable {
    public var url: String?
}

/// 建议与反馈客户端（feedback mod）：提交、我的反馈列表、截图上传。
/// 与 MembershipClient 同约：网络层 5s 超时；业务失败抛中文 ApiError。
/// 全部端点要求会员登录（MemberAuth），须走带令牌与 401 续期的认证客户端装配。
public struct FeedbackClient: Sendable {

    private let client: ApiClient
    private let timeout: TimeInterval

    public init(client: ApiClient, timeout: TimeInterval = 5) {
        self.client = client
        self.timeout = timeout
    }

    /// 提交反馈：截图先经 `upload` 换取 URL 再随单提交。每会员每日限 5 条（超限服务端 429）。
    public func submit(type: String, content: String, contact: String, images: [String]) async throws {
        try await client.post(
            "api/v1/mods/feedback",
            body: FeedbackSubmitRequest(type: type, content: content, contact: contact, images: images),
            timeout: timeout,
        ).requireOk()
    }

    /// 我的反馈列表（仅本人，id 倒序；服务端钳制 page≥1、pageSize≤20）。
    public func myList(page: Int, pageSize: Int = 20) async throws -> FeedbackListData {
        let data: FeedbackListData = try await client.get(
            "api/v1/mods/feedback",
            query: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "pageSize", value: String(pageSize)),
            ],
            timeout: timeout,
        ).requireData()
        return data
    }

    /// 上传一张截图（服务端校验大小/类型，未配置存储时返回可读错误），返回图片 URL。
    public func upload(bytes: Data, fileExtension: String) async throws -> String {
        let data: FeedbackUploadData = try await client.uploadMultipart(
            "api/v1/mods/feedback/upload",
            fileField: "file",
            filename: "feedback.\(fileExtension)",
            mimeType: "image/jpeg",
            bytes: bytes,
        ).requireData()
        guard let url = data.url, !url.isEmpty else {
            throw ApiError(code: nil, "服务器错误，请稍后再试")
        }
        return url
    }
}
