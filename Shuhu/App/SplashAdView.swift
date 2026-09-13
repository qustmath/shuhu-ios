import SwiftUI

/// 开屏广告（advertising 票 04）：冷启动全屏展示，4 秒倒计时到 0 自动进主页，
/// 可随时点「跳过」。点击素材按落地动作跳转（url→浏览器，internal→路由表）。
/// landingType=none 与未知目标降级：点击等同跳过，且不上报点击。
/// 素材出现即视为真实渲染，上报一次曝光；仅在真实发生跳转时上报点击。
struct SplashAdView: View {
    let creative: AdCreativeData
    let adsClient: AdsClient
    /// 进主页（倒计时到 0 / 跳过 / 点击内部降级后）。
    let onDone: () -> Void

    @State private var secondsLeft = Self.splashSeconds
    @State private var finished = false

    private static let splashSeconds = 4

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            remoteImage
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { handleTap() }
            skipButton
                .padding(.trailing, 16)
        }
        .task {
            adsClient.reportImpressions(slot: AdSlots.splash, ids: [creative.id])
            while secondsLeft > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !finished else { return }
                secondsLeft -= 1
            }
            finish()
        }
    }

    /// 全屏素材；加载失败显示深灰占位，不阻塞倒计时/跳过。
    @ViewBuilder
    private var remoteImage: some View {
        if let url = URL(string: creative.imageUrl) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color(red: 0.16, green: 0.16, blue: 0.16)
                }
            }
        } else {
            Color(red: 0.16, green: 0.16, blue: 0.16)
        }
    }

    private var skipButton: some View {
        Text("跳过 \(secondsLeft)s")
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.black.opacity(0.4), in: Capsule())
            .onTapGesture { finish() }
    }

    private func handleTap() {
        switch LandingRouter.resolve(landingType: creative.landingType, landingTarget: creative.landingTarget) {
        case .openURL(let urlString):
            adsClient.reportClicks(slot: AdSlots.splash, ids: [creative.id])
            open(urlString)
            finish()
        case .internalRoute:
            // 内部路由：会员购买页等上线前不在表中（resolve 已降级 NoOp），此处预留
            adsClient.reportClicks(slot: AdSlots.splash, ids: [creative.id])
            finish()
        case .noOp:
            finish() // 无操作素材与未知目标降级：点击等同跳过，不计点击（没发生跳转）
        }
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onDone()
    }
}
