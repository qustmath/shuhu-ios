import SwiftUI

/// 首页列表底部广告卡（advertising 票 05）：素材图 + 标题 + 左上角「广告」小标，
/// 视觉与书籍卡片协调（同圆角白卡）。点击按落地动作跳转并上报点击；
/// landingType=none（无操作，如公益/品牌图）时整卡不可点击、不计点击。
struct ListBottomAdCard: View {
    let creative: AdCreativeData
    let adsClient: AdsClient

    /// 出现在屏幕上即视为曝光，只上报一次（主页持有已报集合去重）。
    var onVisible: () -> Void

    private var landingAction: LandingRouter.LandingAction {
        LandingRouter.resolve(landingType: creative.landingType, landingTarget: creative.landingTarget)
    }

    var body: some View {
        Group {
            if case .noOp = landingAction {
                card // 无操作素材：整卡不可点击
            } else {
                card.onTapGesture { handleTap() }
            }
        }
        .onAppear(perform: onVisible)
    }

    private var card: some View {
        ZStack(alignment: .bottomLeading) {
            remoteImage
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .clipped()
            // 底部标题渐变条
            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom,
            )
            .frame(height: 44)
            .overlay(alignment: .leading) {
                Text(creative.title)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
            }
            // 左上角「广告」小标
            Text("广告")
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
        }
        .frame(height: 120)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var remoteImage: some View {
        if let url = URL(string: creative.imageUrl) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color(red: 0.94, green: 0.93, blue: 0.96)
                }
            }
        } else {
            Color(red: 0.94, green: 0.93, blue: 0.96)
        }
    }

    private func handleTap() {
        switch landingAction {
        case .openURL(let urlString):
            adsClient.reportClicks(slot: AdSlots.homeListBottom, ids: [creative.id])
            if let url = URL(string: urlString) {
                UIApplication.shared.open(url)
            }
        case .internalRoute:
            // 内部路由目标上线前 resolve 已降级 NoOp；此处仅为穷尽性
            adsClient.reportClicks(slot: AdSlots.homeListBottom, ids: [creative.id])
        case .noOp:
            break // 不可点击分支不会进入
        }
    }
}
