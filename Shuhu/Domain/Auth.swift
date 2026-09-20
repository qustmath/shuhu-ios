import Foundation
import Combine

/// 已登录会员的本地快照（服务端会员资料的视图）。与 Android `AuthMember` 对应。
public struct AuthMember: Equatable, Hashable, Sendable {
    public let id: Int64
    public let phone: String
    public let nickname: String
    /// 头像：服务端相对路径或完整 URL；空串 = 未设置。
    public let avatar: String
    /// 会员等级；>0 = 付费会员。
    public let level: Int
    /// 会员到期时间（服务端 RFC3339）；nil = 无到期时间（终身/未开通）。
    public let expireAt: String?

    public init(id: Int64, phone: String, nickname: String, avatar: String = "", level: Int = 0, expireAt: String? = nil) {
        self.id = id
        self.phone = phone
        self.nickname = nickname
        self.avatar = avatar
        self.level = level
        self.expireAt = expireAt
    }

    /// 展示名：优先昵称（用户自取的名字），无昵称回落手机号，最后兜底「微信用户」。
    public var displayName: String {
        if !nickname.isEmpty { return nickname }
        if !phone.isEmpty { return phone }
        return "微信用户"
    }

    /// 掩码手机号（138****0001）；未绑定返回空串。
    public var maskedPhone: String {
        phone.count == 11 ? phone.prefix(3) + "****" + phone.suffix(4) : ""
    }

    /// 付费会员生效中（展示口径，与服务端 IsAdFree 一致）：
    /// level > 0 且（expireAt 为空 = 终身买断，或到期时间在未来）。
    /// 注意：免广告由服务端广告接口空结果驱动，本字段仅用于会员状态展示。
    public var membershipActive: Bool {
        guard level > 0 else { return false }
        guard let expireAt else { return true }
        guard let date = Self.parseRFC3339(expireAt) else { return false }
        return date > Date()
    }

    /// 会员状态短文案（设置页入口/会员页头部用）。
    public var membershipLabel: String {
        guard membershipActive else { return "未开通" }
        guard let expireAt else { return "永久会员" }
        // RFC3339 以 yyyy-MM-dd 开头，取日期段即 Android OffsetDateTime.toLocalDate() 语义
        return expireAt.count >= 10 ? "有效期至 \(expireAt.prefix(10))" : "已开通"
    }

    /// RFC3339/ISO8601 解析（容忍小数秒）。
    private static func parseRFC3339(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// AuthMember 的 Codable 自定义：老版本快照（无 avatar/level/expireAt 键）解码给默认值，
/// 避免升级后本地登录态被误判失效。
extension AuthMember: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, phone, nickname, avatar, level, expireAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        phone = try container.decode(String.self, forKey: .phone)
        nickname = try container.decode(String.self, forKey: .nickname)
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar) ?? ""
        level = try container.decodeIfPresent(Int.self, forKey: .level) ?? 0
        expireAt = try container.decodeIfPresent(String.self, forKey: .expireAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(phone, forKey: .phone)
        try container.encode(nickname, forKey: .nickname)
        try container.encode(avatar, forKey: .avatar)
        try container.encode(level, forKey: .level)
        try container.encodeIfPresent(expireAt, forKey: .expireAt)
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
    public static let sceneBindPhone = "bind_phone"
    /// 换绑：服务端按请求号推导发旧号/新号。
    public static let sceneRebindPhone = "rebind_phone"
    public static let methodSms = "sms"
    public static let methodDev = "dev" // 开发联调：服务端固定码，仅 debug 构建暴露入口
}

/// 会员认证接缝：注册/登录/登出与登录态观察（UI 只依赖本接口）。
/// 本地优先（ADR-0007）：未登录不影响任何本地功能，本接缝只承载身份。
public protocol AuthRepository: AnyObject {
    /// 当前登录会员；nil = 未登录。进程重启后从持久层恢复。
    var session: CurrentValueSubject<AuthMember?, Never> { get }

    /// 发送短信验证码（同号同场景 60s 1 条；服务端另有手机号/IP 维度限流）。
    func sendSmsCode(phone: String, scene: String, method: String) async throws

    /// 已登录发送绑定/换绑验证码：换绑发旧号时 phone 传当前绑定号。
    func sendBindPhoneCode(phone: String, scene: String, method: String) async throws

    /// 手机号+密码+短信验证码注册，成功后直接进入登录态。
    func register(phone: String, password: String, code: String, method: String) async throws -> AuthMember

    /// 未登录重置密码：短信验证通过后仅重设密码，不签发令牌——需用新密码重新登录。
    func resetPassword(phone: String, code: String, newPassword: String, method: String) async throws

    /// 绑定/换绑手机号：scene=bindPhone 时 oldCode 传 nil；scene=rebindPhone 时需旧号确认码 + 新号验证码。
    /// 成功后刷新登录态快照。
    func bindPhone(phone: String, code: String, oldCode: String?, scene: String, method: String) async throws -> AuthMember

    /// 手机号+密码登录。
    func login(phone: String, password: String) async throws -> AuthMember

    /// 开发联调：以 dev 伪 code 走微信登录全链路（ADR-0009）。
    /// 仅 debug 构建在 UI 暴露入口；真实微信 SDK 接入后由正式登录替代。
    func loginWithWechatDev(devCode: String) async throws -> AuthMember

    /// 登出：撤销服务端会话并清空本地登录态；本地数据不受影响。
    func logout() async

    /// 拉取最新会员资料并刷新登录态快照（进入「我」页时调用）。
    func refreshProfile() async throws -> AuthMember

    /// 修改昵称并刷新登录态快照；昵称去空格后不能为空。
    func updateNickname(_ nickname: String) async throws -> AuthMember

    /// 上传头像并写入资料，刷新登录态快照；imageBytes 为图片原始字节。
    func updateAvatar(imageBytes: Data, ext: String) async throws -> AuthMember
}
