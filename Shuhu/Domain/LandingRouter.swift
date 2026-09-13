import Foundation

/// 广告落地动作路由（纯 Foundation，可测）。与 Android `domain/ads/LandingRouter` 对应：
/// 素材的 landingType + landingTarget → 客户端动作。
/// url → 打开浏览器（校验 https scheme）；internal → 内部路由表映射到导航动作；
/// none → 无操作（素材不可点击，如公益/品牌图），点击等同跳过且不计点击；
/// 未知 internal 目标（如会员购买页上线前的 membership.purchase）安全降级 NoOp，不 crash。
public enum LandingRouter {

    public enum LandingAction: Equatable {
        /// 外部 https 链接，浏览器打开。
        case openURL(String)
        /// 内部路由：由调用方按路由名执行导航。
        case internalRoute(String)
        /// 无动作（未知/非法目标安全降级）。
        case noOp
    }

    /// 内部路由表：内部路由名 → 是否已支持（App 内已有对应页面/动作）。
    /// 会员购买页随付费会员功能上线后在此登记；当前为空，覆盖未知目标降级。
    private static let internalRoutes: Set<String> = []

    public static func resolve(landingType: String, landingTarget: String) -> LandingAction {
        switch landingType {
        case "url":
            if landingTarget.hasPrefix("https://") {
                return .openURL(landingTarget)
            }
            return .noOp
        case "internal":
            if internalRoutes.contains(landingTarget) {
                return .internalRoute(landingTarget)
            }
            return .noOp
        // 无操作素材：不可点击，点击等同跳过；不是异常输入
        case "none":
            return .noOp
        default:
            return .noOp
        }
    }
}
