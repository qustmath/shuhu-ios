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

/// 未登录重置密码：短信验证后仅重设密码（服务端回登录态也不采纳，必须用新密码重新登录）。
public struct ResetPasswordRequest: Encodable, Sendable {
    public let phone: String
    public let method: String
    public let code: String
    public let newPassword: String
}

/// 绑定/换绑手机号（已登录）：
/// scene=bind_phone 验新号（phone+code）；scene=rebind_phone 双验证（oldCode 验旧号 + code 验新号）。
public struct BindPhoneRequest: Encodable, Sendable {
    public let method: String
    public let scene: String
    public let phone: String
    public let code: String
    public let oldCode: String?

    public init(method: String, scene: String, phone: String, code: String, oldCode: String? = nil) {
        self.method = method
        self.scene = scene
        self.phone = phone
        self.code = code
        self.oldCode = oldCode
    }
}

public struct RefreshRequest: Encodable, Sendable {
    public let refreshToken: String
}

public struct LogoutRequest: Encodable, Sendable {
    public let refreshToken: String
}

/// 微信登录（channel=mobile_app；dev 联调时 code 为伪 code）。
public struct WechatLoginRequest: Encodable, Sendable {
    public let channel: String
    public let code: String
}

/// 更新个人资料请求。avatar 为 nil 时序列化省略该字段（不动头像）；只改昵称传 nil。
public struct UpdateProfileRequest: Encodable, Sendable {
    public let nickname: String
    public let avatar: String?

    public init(nickname: String, avatar: String? = nil) {
        self.nickname = nickname
        self.avatar = avatar
    }
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

/// 登录/注册/刷新令牌/微信登录的统一返回：令牌 + 最新会员资料。
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

    public func resetPassword(phone: String, code: String, newPassword: String, method: String) async throws {
        let envelope: Envelope<EmptyData> = try await publicClient.post(
            "api/v1/member/password/reset",
            body: ResetPasswordRequest(phone: phone, method: method, code: code, newPassword: newPassword),
        )
        // 只校验业务码：重置后不进入登录态，必须用新密码重新登录
        try envelope.requireOk()
    }

    public func login(phone: String, password: String) async throws -> AuthMember {
        let data: MemberLoginData = try await publicClient
            .post("api/v1/member/login", body: LoginRequest(phone: phone, password: password))
            .requireData()
        return saveLogin(data)
    }

    public func loginWithWechatDev(devCode: String) async throws -> AuthMember {
        let data: MemberLoginData = try await publicClient
            .post("api/v1/member/wechat/login", body: WechatLoginRequest(channel: "mobile_app", code: devCode))
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

    // ---- 已登录端点 ----

    public func sendBindPhoneCode(phone: String, scene: String, method: String) async throws {
        let envelope: Envelope<EmptyData> = try await memberClient.post(
            "api/v1/member/phone/code",
            body: SmsCodeRequest(phone: phone, method: method, scene: scene),
        )
        try envelope.requireOk()
    }

    public func bindPhone(phone: String, code: String, oldCode: String?, scene: String, method: String) async throws -> AuthMember {
        let envelope: Envelope<EmptyData> = try await memberClient.post(
            "api/v1/member/phone/bind",
            body: BindPhoneRequest(method: method, scene: scene, phone: phone, code: code, oldCode: oldCode),
        )
        try envelope.requireOk()
        // 绑定结果服务端不回数据，拉最新资料刷新登录态快照
        return try await refreshProfile()
    }

    public func refreshProfile() async throws -> AuthMember {
        let profile: MemberProfileData = try await memberClient
            .get("api/v1/member/me")
            .requireData()
        let member = AuthMember(profile: profile)
        tokenStore.saveProfile(member)
        session.send(member)
        return member
    }

    public func updateNickname(_ nickname: String) async throws -> AuthMember {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ApiError("昵称不能为空") }
        let envelope: Envelope<EmptyData> = try await memberClient.put(
            "api/v1/member/profile",
            body: UpdateProfileRequest(nickname: trimmed),
        )
        try envelope.requireOk()
        // 保存后拉最新资料刷新登录态快照
        return try await refreshProfile()
    }

    public func updateAvatar(imageBytes: Data, ext: String) async throws -> AuthMember {
        // 1) 复用封面上传通道把图片传到服务器，拿到相对路径
        let uploaded: SyncCoverUploadData = try await memberClient
            .uploadMultipart(
                "api/v1/sync/covers",
                fileField: "file",
                filename: "avatar.\(ext)",
                mimeType: "image/*",
                bytes: imageBytes,
            )
            .requireData()
        // 2) 把服务器路径写入资料（nickname 用当前昵称，避免被清空）
        let currentNickname = session.value?.nickname ?? ""
        let envelope: Envelope<EmptyData> = try await memberClient.put(
            "api/v1/member/profile",
            body: UpdateProfileRequest(
                nickname: currentNickname.isEmpty ? "书友" : currentNickname,
                avatar: uploaded.path,
            ),
        )
        try envelope.requireOk()
        return try await refreshProfile()
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
        let member = AuthMember(profile: data.member)
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

private extension AuthMember {
    init(profile: MemberProfileData) {
        self.init(
            id: profile.id,
            phone: profile.phone ?? "",
            nickname: profile.nickname ?? "",
            avatar: profile.avatar ?? "",
            level: profile.level ?? 0,
            expireAt: profile.expireAt,
        )
    }
}
