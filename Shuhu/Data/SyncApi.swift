import Foundation

/// 同步端点（走带令牌与 401 续期的客户端）。与 Android `SyncApi`/`CoversApi` 对应。
public struct SyncApi: Sendable {

    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    public func push(_ request: SyncPushRequest) async throws -> SyncPushData {
        try await client.post("api/v1/sync/push", body: request).requireData()
    }

    public func pull(cursor: String?) async throws -> SyncPullData {
        let query = cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
        let envelope: Envelope<SyncPullData> = try await client.get("api/v1/sync/pull", query: query)
        return try envelope.requireData()
    }

    /// 云端数据概览：换账号弹窗展示「云端有 N 本书」（防裸删确认）。
    public func stats() async throws -> SyncStatsData {
        try await client.get("api/v1/sync/stats").requireData()
    }

    /// 封面上传（multipart，单张 ≤5MB），返回服务端引用路径（/static/…）。
    public func uploadCover(bytes: Data, fileExtension: String) async throws -> String {
        let data: SyncCoverUploadData = try await client.uploadMultipart(
            "api/v1/sync/covers",
            fileField: "file",
            filename: "cover.\(fileExtension)",
            mimeType: "image/*",
            bytes: bytes,
        ).requireData()
        return data.path
    }
}
