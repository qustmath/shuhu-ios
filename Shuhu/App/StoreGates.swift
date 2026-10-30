import Foundation

/// App Store 送审期的功能闸门（2026-10-30）。
///
/// 首次送审被 2.1 信息不足退回时，两项功能对审核暂时关闭：
/// - 会员购买：内购尚未接入（付费 App 协议待生效），价格页点开通只会提示「暂不可用」，
///   留着既是死链又会让审核以为在卖未接入的东西（3.1.1）。
/// - 微信登录：有第三方社交登录就必须同时提供 Sign in with Apple（4.8），本版不接。
///
/// 关闭时入口与落地动作一并隐藏（设置行、广告卡「开通会员」、广告 internal 落地），
/// 页面本身保留，重新开放只需把对应开关改 true 并随版本提交。
enum StoreGates {
    /// 会员页入口与会员相关文案（设置页会员行、广告卡「开通会员，免广告」、
    /// 广告落地 `membership.purchase`）。
    static let membershipVisible = false
    /// 微信登录与微信绑定入口（登录页「微信登录」按钮、设置页微信绑定行）。
    static let wechatLoginVisible = false
}
