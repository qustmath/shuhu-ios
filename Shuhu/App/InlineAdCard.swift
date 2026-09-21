import SwiftUI

/// 纸感内联广告卡（odui ad-block，主页第 2 本书后 / 详情第 2 条记录后共用，对齐 Android `InlineAdCard`）：
/// 纯素材图 + 发丝线边框 + 右上「广告 ▾」（点开微信广告式下拉，可关闭本条，仅本会话）。整图可点，
/// 按落地动作跳转并上报点击；landingType=none（公益/品牌图）时不可点、不计点击。菜单展开时点图只收起菜单。
/// 曝光上报由调用方按可见性处理。`onOpenMembership` 非空时左下角叠加「开通会员，免广告」入口。
///
/// 2026-09-21：右上角从 SwiftUI `Menu` 改成自绘下拉。旧版只有一个 20pt 的小箭头，摸不准、点了没反应
/// （点偏一点就落到素材图上，而无落地动作的素材按设计不响应）。现在按钮含「广告」字样、点击区放大，
/// 下拉直接挂在按钮下方（贴在卡片内，不会画到行外）。
struct InlineAdCard: View {
    let creative: AdCreativeData
    let slot: String
    let adsClient: AdsClient
    let onClosed: () -> Void
    var onOpenMembership: (() -> Void)? = nil

    @State private var menuOpen = false

    private var landingAction: LandingRouter.LandingAction {
        LandingRouter.resolve(landingType: creative.landingType, landingTarget: creative.landingTarget)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            adImage
                .contentShape(Rectangle())
                .onTapGesture { handleTap() }

            // 左下「开通会员，免广告」入口：灰色半透明小标
            if let onOpenMembership {
                Button {
                    menuOpen = false
                    onOpenMembership()
                } label: {
                    Text("开通会员，免广告")
                        .font(.system(size: 10))
                        .tracking(0.5)
                        .foregroundStyle(Paper.surface)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Paper.floatingGray.opacity(0.65), in: RoundedRectangle(cornerRadius: 2))
                }
                .buttonStyle(.plain)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            // 右上「广告 ▾」+ 下拉（微信广告式：菜单上边缘紧贴按钮下沿）
            VStack(alignment: .trailing, spacing: 0) {
                Button {
                    menuOpen.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Text("广告")
                            .font(.system(size: 10))
                            .tracking(0.8)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Paper.inkMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Paper.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 2))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Paper.hairline, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ad-menu-button")
                .accessibilityLabel("广告选项")

                if menuOpen {
                    Button {
                        menuOpen = false
                        onClosed()
                    } label: {
                        Text("关闭这条广告")
                            .font(.system(size: 13))
                            .foregroundStyle(Paper.ink)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(minWidth: 126, alignment: .leading)
                            .background(Paper.surface, in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Paper.hairline, lineWidth: 1))
                            .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    .accessibilityIdentifier("ad-close-menu-item")
                }
            }
            .padding(8)
        }
    }

    private var adImage: some View {
        AsyncImage(url: URL(string: creative.imageUrl)) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Rectangle().fill(Paper.hairline) // 加载中/失败占位
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1344 / 480, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Paper.hairline, lineWidth: 1))
    }

    private func handleTap() {
        // 菜单展开时点素材图只收起菜单（odui 网页版：点空白处收起，且不触发跳转）
        if menuOpen {
            menuOpen = false
            return
        }
        switch landingAction {
        case .openURL(let url):
            adsClient.reportClicks(slot: slot, ids: [creative.id])
            if let target = URL(string: url) {
                UIApplication.shared.open(target)
            }
        case .internalRoute(let route):
            adsClient.reportClicks(slot: slot, ids: [creative.id])
            // 会员购买页：走调用方注入的导航（详情页广告/会员入口共用）
            if route == "membership.purchase" {
                onOpenMembership?()
            }
        case .noOp:
            break // 不可点素材：不响应、不计点击
        }
    }
}
