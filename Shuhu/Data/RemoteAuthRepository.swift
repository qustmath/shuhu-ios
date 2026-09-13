import Foundation
import Combine

// ---- 认证端点 DTO（与 Android `AuthDtos` 一致）----

/// 注册：短信验证必填（scene=register，ADR-0004），method=sms 正式渠道 / dev 联调固定码。
public struct RegisterRequest: Encodable, Sendable {
    public let phone: String
    public let password: String
    public let method: String
    public let code: String
}

public struct LoginRequest: Encodable, Sendable {
    public let phone: String
    public let password: String
}

/// 公开发码：scene=register/reset_password（白名单在服务端）。
public struct SmsCodeRequest: Encodable, Sendable {
    public let phone: String
    public let method: String
    public let scene: String
}

public struct RefreshRequest: Encodable, Sendable {
    public let refreshToken: String
}

public struct LogoutRequest: Encodable, Sendable {
    public let refreshToken: String
}

/// 会员资料。微信注册的空壳账号 username/phone 为 JSON null，故均可空。
public struct MemberProfileData: Codable, Sendable {
    public let id: Int64
    public let username: String?
    public let phone: String?
    public let nickname: String?
    public let avatar: String?
    public let invitationCode: String?
    public let level: Int?
    public let expireAt: String?
    public let createdAt: String?
}

/// 登录/注册/刷新令牌的统一返回：令牌 + 最新会员资料。
public struct MemberLoginData: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresIn: Int64
    public let member: MemberProfileData
}

/// 会员认证的远端实现：公开端点直调；会员端点（me 等）经带认证钩子的客户端。
/// 401 时由 ApiClient 回调 `refreshAccessToken` 续期并重试一次（旋转：旧 refresh 用后即废）。
public final class RemoteAuthRepository: AuthRepository, @unchecked Sendable {

    public let session = CurrentValueSubject<AuthMember?, Never>(nil)

    private let publicClient: ApiClient
    private let memberClient: ApiClient
    private let tokenStore: TokenStore

    private let lock = NSLock()
    private var accessToken: String?
    private let refreshMutex = NSLock()

    public init(publicClient: ApiClient, memberClient: ApiClient, tokenStore: TokenStore) {
        self.publicClient = publicClient
        self.memberClient = memberClient
        self.tokenStore = tokenStore
        memberClient.configure(
            tokenProvider: { [weak self] in self?.currentAccessToken() },
            refresher: { [weak self] in await self?.refreshAccessToken() },
        )
    }

    /// 应用启动时从 Keychain 恢复登录态与令牌。
    public func restore() {
        let tokens = tokenStore.tokens()
        let member = tokenStore.member()
        lock.lock()
        accessToken = tokens?.accessToken
        lock.unlock()
        session.send(member)
    }

    /// 内存中的 access token，供 ApiClient 同步读取（随 restore/save/logout 维护）。
    public func currentAccessToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return accessToken
    }

    // ---- 公开端点 ----

    public func sendSmsCode(phone: String, scene: String, method: String) async throws {
        let envelope: Envelope<EmptyData> = try await publicClient.post(
            "api/v1/member/sms/code",
            body: SmsCodeRequest(phone: phone, method: method, scene: scene),
        )
        try envelope.requireOk()
    }

    public func register(phone: String, password: String, code: String, method: String) async throws -> AuthMember {
        let data: MemberLoginData = try await publicClient
            .post("api/v1/member/register", body: RegisterRequest(phone: phone, password: password, method: method, code: code))
            .requireData()
        return saveLogin(data)
    }

    public func login(phone: String, password: String) async throws -> AuthMember {
        let data: MemberLoginData = try await publicClient
            .post("api/v1/member/login", body: LoginRequest(phone: phone, password: password))
            .requireData()
        return saveLogin(data)
    }

    public func logout() async {
        if let refresh = tokenStore.tokens()?.refreshToken {
            let _: Envelope<EmptyData>? = try? await publicClient.post(
                "api/v1/member/logout",
                body: LogoutRequest(refreshToken: refresh),
            )
        }
        tokenStore.clear()
        lock.lock()
        accessToken = nil
        lock.unlock()
        session.send(nil)
    }

    public func refreshProfile() async throws -> AuthMember {
        let profile: MemberProfileData = try await memberClient
            .get("api/v1/member/me")
            .requireData()
        let member = AuthMember(id: profile.id, phone: profile.phone ?? "", nickname: profile.nickname ?? "")
        tokenStore.saveProfile(member)
        session.send(member)
        return member
    }

    /// 认证器回调：用 refresh token 换新令牌（旋转：旧 refresh 用后即废）。
    /// 成功返回新 access token；refresh 也失效（4xx/业务拒绝）时清空登录态并返回 nil，
    /// UI 经 session 观察安静回到未登录。5xx/断网属瞬态失败，保留登录态下次再试。
    public func refreshAccessToken() async -> String? {
        refreshMutex.lock()
        defer { refreshMutex.unlock() }
        // 并发的后续 401 会读到前一个刷新写入的最新 refresh token
        guard let currentRefresh = tokenStore.tokens()?.refreshToken else { return nil }
        do {
            let data: MemberLoginData = try await publicClient
                .post("api/v1/member/refresh-token", body: RefreshRequest(refreshToken: currentRefresh))
                .requireData()
            saveLogin(data)
            lock.lock()
            defer { lock.unlock() }
            return accessToken
        } catch {
            let sessionInvalid: Bool
            if let error = error as? ApiError {
                sessionInvalid = error.code.map { (400..<500).contains($0) } ?? false
            } else {
                sessionInvalid = false
            }
            if sessionInvalid {
                tokenStore.clear()
                lock.lock()
                accessToken = nil
                lock.unlock()
                session.send(nil)
            }
            return nil
        }
    }

    // ---- 内部 ----

    @discardableResult
    private func saveLogin(_ data: MemberLoginData) -> AuthMember {
        let member = AuthMember(id: data.member.id, phone: data.member.phone ?? "", nickname: data.member.nickname ?? "")
        tokenStore.save(
            tokens: TokenStore.Tokens(accessToken: data.accessToken, refreshToken: data.refreshToken),
            member: member,
        )
        lock.lock()
        accessToken = data.accessToken
        lock.unlock()
        session.send(member)
        return member
    }
}
