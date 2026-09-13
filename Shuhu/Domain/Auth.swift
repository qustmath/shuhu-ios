import Foundation
import Combine

/// 已登录会员的本地快照（服务端会员资料的视图）。与 Android `AuthMember` 对应。
public struct AuthMember: Equatable, Hashable, Sendable, Codable {
    public let id: Int64
    public let phone: String
    public let nickname: String

    public init(id: Int64, phone: String, nickname: String) {
        self.id = id
        self.phone = phone
        self.nickname = nickname
    }

    /// 展示名：优先手机号（正式账号），其次昵称（微信注册的空壳账号）。
    public var displayName: String {
        if !phone.isEmpty { return phone }
        if !nickname.isEmpty { return nickname }
        return "微信用户"
    }

    /// 掩码手机号（138****0001）；未绑定返回空串。
    public var maskedPhone: String {
        phone.count == 11 ? phone.prefix(3) + "****" + phone.suffix(4) : ""
    }
}

/// 网络/认证失败：message 为可直接展示的中文提示（来自服务端，或网络异常的本地兜底）。
/// 与 Android `AuthException` 对应；同步引擎静默吞掉它（数据不丢，下次触发自然重试）。
public struct ApiError: Error, LocalizedError, Sendable {
    /// 业务码或 HTTP 状态码；nil = 本地网络异常（无法区分瞬态与否时用于保守判断）。
    public let code: Int?
    public let message: String

    public init(code: Int? = nil, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// 短信验证码场景与验证方式标识（与服务端 ADR-0003/0004 对齐）。
public enum Sms {
    public static let sceneRegister = "register"
    public static let sceneResetPassword = "reset_password"
    public static let methodSms = "sms"
    public static let methodDev = "dev" // 开发联调：服务端固定码
}

/// 会员认证接缝：注册/登录/登出与登录态观察（UI 只依赖本接口）。
/// 本地优先（ADR-0007）：未登录不影响任何本地功能，本接缝只承载身份。
public protocol AuthRepository: AnyObject {
    /// 当前登录会员；nil = 未登录。进程重启后从持久层恢复。
    var session: CurrentValueSubject<AuthMember?, Never> { get }

    /// 发送短信验证码（同号同场景 60s 1 条；服务端另有手机号/IP 维度限流）。
    func sendSmsCode(phone: String, scene: String, method: String) async throws

    /// 手机号+密码+短信验证码注册，成功后直接进入登录态。
    func register(phone: String, password: String, code: String, method: String) async throws -> AuthMember

    /// 手机号+密码登录。
    func login(phone: String, password: String) async throws -> AuthMember

    /// 登出：撤销服务端会话并清空本地登录态；本地数据不受影响。
    func logout() async

    /// 拉取最新会员资料并刷新登录态快照（进入「我」页时调用）。
    func refreshProfile() async throws -> AuthMember
}
