import SwiftUI

/// 纸感内联广告卡（odui ad-block，主页第 2 本书后 / 详情第 2 条记录后共用，对齐 Android `InlineAdCard`）：
/// 纯素材图 + 发丝线边框 + 右上「▾」菜单（可关闭本条，仅本会话）。整图可点，按落地动作跳转并上报点击；
/// landingType=none（公益/品牌图）时不可点、不计点击。曝光上报由调用方按可见性处理。
/// `onOpenMembership` 非空时左下角叠加「开通会员，免广告」入口。
struct InlineAdCard: View {
    let creative: AdCreativeData
    let slot: String
    let adsClient: AdsClient
    let onClosed: () -> Void
    var onOpenMembership: (() -> Void)? = nil

    private var landingAction: LandingRouter.LandingAction {
        LandingRouter.resolve(landingType: creative.landingType, landingTarget: creative.landingTarget)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            adImage
                .onTapGesture { handleTap() }

            // 左下「开通会员，免广告」入口：灰色半透明小标
            if let onOpenMembership {
                Button(action: onOpenMembership) {
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

            // 右上「▾」菜单（关闭本条）
            Menu {
                Button("关闭这条广告") { onClosed() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12))
                    .foregroundStyle(Paper.inkMuted)
                    .padding(4)
                    .background(Paper.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 2))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Paper.hairline, lineWidth: 1))
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
