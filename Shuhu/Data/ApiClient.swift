import Foundation

/// home 响应约定：code=0 成功；失败时 code=HTTP 状态码、message 为中文提示。
/// 与 Android `ApiEnvelope` 对应。
public struct Envelope<Data: Decodable>: Decodable {
    public let code: Int
    public let message: String
    public let data: Data?

    public init(code: Int, message: String, data: Data?) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// 无业务数据的响应体占位（登出等；data 为 null 或 {} 均可解）。
public struct EmptyData: Codable, Sendable {
    public init() {}
}

public extension Envelope {
    /// 解开 home 响应约定：code!=0 抛中文 ApiError；data 缺失视为服务器错误。
    func requireData() throws -> Data {
        if code != 0 { throw ApiError(code: code, message) }
        guard let data else { throw ApiError(code: code, "服务器错误，请稍后再试") }
        return data
    }

    /// 无业务数据的端点（登出等）只校验业务码。
    func requireOk() throws {
        if code != 0 { throw ApiError(code: code, message) }
    }
}

/// HTTP 客户端：统一 JSON 信封解码、Bearer 令牌附带与 401 续期重试。
/// 公开端点（登录/注册/刷新）与会员端点（me/sync）共用，仅配置不同。
/// `session` 可注入（测试用 URLProtocol 桩替换）。
public final class ApiClient: @unchecked Sendable {

    public let baseURL: URL
    private let session: URLSession
    private var tokenProvider: (@Sendable () -> String?)?
    private var refresher: (@Sendable () async -> String?)?

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// 装配认证钩子：tokenProvider 同步取当前 access token；refresher 在 401 时续期一次。
    public func configure(
        tokenProvider: @escaping @Sendable () -> String?,
        refresher: @escaping @Sendable () async -> String?,
    ) {
        self.tokenProvider = tokenProvider
        self.refresher = refresher
    }

    // ---- 端点便捷方法 ----

    public func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> Envelope<T> {
        let (data, _) = try await send(path: path, method: "GET", query: query, body: nil, contentType: nil)
        return try decode(data)
    }

    public func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> Envelope<T> {
        let payload = try JSONEncoder().encode(body)
        let (data, _) = try await send(path: path, method: "POST", query: [], body: payload, contentType: "application/json")
        return try decode(data)
    }

    /// multipart 上传（封面）：单文件字段上传，返回服务端引用路径等业务数据。
    public func uploadMultipart<T: Decodable>(
        _ path: String,
        fileField: String,
        filename: String,
        mimeType: String,
        bytes: Data,
    ) async throws -> Envelope<T> {
        let boundary = "shufu-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(bytes)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let (data, _) = try await send(
            path: path,
            method: "POST",
            query: [],
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
        )
        return try decode(data)
    }

    // ---- 内部 ----

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ApiError(code: nil, "服务器错误，请稍后再试")
        }
    }

    private func send(
        path: String,
        method: String,
        query: [URLQueryItem],
        body: Data?,
        contentType: String?,
    ) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else {
            throw ApiError(code: nil, "服务器错误，请稍后再试")
        }
        let baseRequest = URLRequest(url: url)
        var request = baseRequest
        request.httpMethod = method
        request.httpBody = body
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        var attempt = 0
        while true {
            attempt += 1
            var authenticated = request
            if let token = tokenProvider?() {
                authenticated.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, response): (Data, HTTPURLResponse)
            do {
                let (payload, urlResponse) = try await session.data(for: authenticated)
                guard let http = urlResponse as? HTTPURLResponse else {
                    throw ApiError(code: nil, "服务器错误，请稍后再试")
                }
                data = payload
                response = http
            } catch let error as ApiError {
                throw error
            } catch {
                throw ApiError(code: nil, "网络连接失败，请检查网络")
            }

            // 401 → 续期一次并重试；续期失败（nil）则把 401 交给上层按登录失效处理
            if response.statusCode == 401, attempt == 1, refresher != nil {
                if (await refresher?()) != nil {
                    continue
                }
            }
            if !(200..<300).contains(response.statusCode) {
                throw ApiError(code: response.statusCode, errorMessage(from: data))
            }
            return (data, response)
        }
    }

    /// 从错误响应体里取服务端中文提示；解析失败给兜底文案。
    private func errorMessage(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(Envelope<EmptyData>.self, from: data),
           !envelope.message.isEmpty {
            return envelope.message
        }
        return "服务器错误，请稍后再试"
    }
}
