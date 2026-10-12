import Foundation
import WechatOpenSDK

/// 微信开放平台移动应用接入配置。AppID 与 Android 共用同一移动应用；三项登记值互为映照，勿单独改动：
/// AppID / Universal Links（微信后台登记）↔ 关联域（project.yml entitlements）↔ 服务器 AASA（/var/www/apple/）。
public enum WechatConfig {
    public static let appId = "wxf38812d6f87e3561"
    public static let universalLink = "https://rrapi.groovyu.com/app/"
}

/// 微信授权码获取的接缝：真实实现拉起微信 App 授权（移动应用渠道），
/// 授权码交 `AuthRepository.loginWithWechat/bindWechat` 换登录态/绑定。测试注入假实现。
public protocol WechatAuthCodeClient: AnyObject {
    /// 微信登录是否可用（已配置 AppID 且设备装有微信）；UI 据此决定是否显示微信入口。
    var canLogin: Bool { get }

    /// 拉起微信授权并挂起等待授权码；未配置/未安装/取消/超时/失败抛 ApiError（message 可直接展示）。
    func requestAuthCode() async throws -> String

    /// Universal Link 回跳转发（App.onOpenURL 调用，交 SDK 解析后回调 onResp）。
    func handleOpen(url: URL)
}

/// 真实实现：进程内单例（AppContainer 持有）。`requestAuthCode` 与 WXApiDelegate 回调
/// 经 pendingAuth 配对——state 防串扰，挂起的调用方等 state 匹配的那次授权结果，其余回调忽略。
@MainActor
final class WechatAuthClient: NSObject, WechatAuthCodeClient {

    /// 一次授权会话：state 防串扰，continuation 把回调结果交还挂起的调用方。
    private struct PendingAuth {
        let state: String
        let continuation: CheckedContinuation<String, Error>
    }

    /// 与 Android 对齐：用户滞留微信不回时收敛挂起协程。
    private static let timeoutNanoseconds: UInt64 = 5 * 60 * 1_000_000_000

    private let appId: String
    private var pendingAuth: PendingAuth?

    init(appId: String) {
        self.appId = appId
        super.init()
        guard !appId.isEmpty else { return }
        WXApi.registerApp(appId, universalLink: WechatConfig.universalLink)
    }

    var canLogin: Bool { !appId.isEmpty && WXApi.isWXAppInstalled() }

    func requestAuthCode() async throws -> String {
        guard !appId.isEmpty else { throw ApiError(code: nil, "微信登录暂未配置") }
        guard WXApi.isWXAppInstalled() else { throw ApiError(code: nil, "未安装微信，无法使用微信登录") }

        let state = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pendingAuth = PendingAuth(state: state, continuation: continuation)
            let req = SendAuthReq()
            req.scope = "snsapi_userinfo"
            req.state = state
            if !WXApi.send(req) {
                failPending(ApiError(code: nil, "拉起微信失败，请稍后再试"))
                return
            }
            // 超时看门狗：到期时 pendingAuth 已被回调取走则为空操作
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
                self?.failPending(ApiError(code: nil, "微信登录超时，请重试"))
            }
        }
    }

    func handleOpen(url: URL) {
        WXApi.handleOpen(url, delegate: self)
    }

    /// 收敛挂起的调用方：pendingAuth 取走即失效，回调/超时/失败互斥且至多 resume 一次。
    private func failPending(_ error: Error) {
        guard let pending = pendingAuth else { return }
        pendingAuth = nil
        pending.continuation.resume(throwing: error)
    }

    private func succeedPending(_ code: String) {
        guard let pending = pendingAuth else { return }
        pendingAuth = nil
        pending.continuation.resume(returning: code)
    }
}

extension WechatAuthClient: WXApiDelegate {

    func onReq(_ req: BaseReq) {}

    func onResp(_ resp: BaseResp) {
        guard let auth = resp as? SendAuthResp,
              let pending = pendingAuth,
              auth.state == nil || auth.state == pending.state else { return }
        // errCode 原值比较：0=成功、-2=用户取消（对齐 Android ERR_OK/ERR_USER_CANCEL，规避枚举桥接差异）
        switch auth.errCode {
        case 0:
            if let code = auth.code, !code.isEmpty {
                succeedPending(code)
            } else {
                failPending(ApiError(code: nil, "微信授权失败，请重试"))
            }
        case -2:
            failPending(ApiError(code: nil, "已取消微信登录"))
        default:
            failPending(ApiError(code: nil, "微信授权失败（错误码 \(auth.errCode)）"))
        }
    }
}
