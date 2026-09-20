import SwiftUI

/// odui 纸墨风色板（对齐 Android `ui/theme/Color.kt`，editorial-monocle 设计稿 oklch→sRGB）。
/// 纸底 + 墨色文字 + 发丝线分隔（无卡片无阴影）+ 赭红点缀（每屏最多两次）。
public enum Paper {

    /// 页面纸底 #F9F8F5
    public static let bg = Color(red: 0xF9 / 255, green: 0xF8 / 255, blue: 0xF5 / 255)

    /// 卡面/封面底 #FFFFFF
    public static let surface = Color.white

    /// 墨色主文字、进度条填充 #1B150D
    public static let ink = Color(red: 0x1B / 255, green: 0x15 / 255, blue: 0x0D / 255)

    /// 弱化文字 #625D56
    public static let inkMuted = Color(red: 0x62 / 255, green: 0x5D / 255, blue: 0x56 / 255)

    /// 发丝分隔线 #DFDEDA（全站分隔全靠它，无卡片无阴影）
    public static let hairline = Color(red: 0xDF / 255, green: 0xDE / 255, blue: 0xDA / 255)

    /// 赭红点缀 #9A5048（FAB/主按钮/逾期警示，每屏最多两次）
    public static let ochre = Color(red: 0x9A / 255, green: 0x50 / 255, blue: 0x48 / 255)

    /// 浮标灰 #8E8E93（广告卡上「开通会员，免广告」灰底）
    public static let floatingGray = Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255)
}

public extension Font {

    /// 衬线标题（odui：设备中文衬线）。对齐 Android `FontFamily.Serif`。
    static func paperSerif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// 等宽数字（统计值、页码、日期、百分比、kicker 小标签）。对齐 Android `FontFamily.Monospace`。
    static func paperMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

public extension View {

    /// 中文等宽字距（Android letterSpacing 的 SwiftUI 表达：单位 pt 近似）。
    func paperTracking(_ value: CGFloat) -> some View {
        tracking(value)
    }
}
