import SwiftUI

/// 关于页（odui 纸感，对齐 Android `AboutScreen`）：应用图标与版本 + 一段介绍 +
/// 用户协议/隐私政策（App 内浏览器打开）。从设置页「关于」行进入。
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var legalURL: URL?

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 0) {
            PaperTopBar(title: "关于", onBack: { dismiss() })

            ScrollView {
                VStack(spacing: 0) {
                    // 头部：图标 + 应用名 + 版本
                    LogoMark()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    Text("书乎")
                        .font(.paperSerif(22, weight: .bold))
                        .foregroundStyle(Paper.ink)
                        .padding(.top, 10)
                    Text("v\(appVersion)")
                        .font(.paperMono(13))
                        .foregroundStyle(Paper.inkMuted)
                        .padding(.top, 2)

                    // 介绍
                    HairlineRule()
                        .padding(.top, 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("记录每一页，看清阅读轨迹")
                            .font(.paperSerif(17, weight: .bold))
                            .foregroundStyle(Paper.ink)
                        Text("书乎是一款个人阅读记录应用：把在读的书加进来，每天记一笔读到的页数，读得多快、读了多少，一目了然。")
                            .font(.system(size: 14))
                            .lineSpacing(8)
                            .foregroundStyle(Paper.inkMuted)
                            .padding(.top, 8)
                        VStack(alignment: .leading, spacing: 4) {
                            IntroPoint(text: "本地优先：不登录也能完整使用，数据先保存在这台设备上")
                            IntroPoint(text: "阅读计划：设定起止日期，自动算出今天该读多少页")
                            IntroPoint(text: "重读留存：一本书可以多轮重读，往轮的记录完整保留")
                            IntroPoint(text: "云端同步：登录后可跨设备同步书籍与阅读记录")
                        }
                        .padding(.top, 10)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                    HairlineRule()

                    LegalRow(label: "用户协议", urlString: LegalPages.terms) { url in
                        legalURL = url
                    }
                    LegalRow(label: "隐私政策", urlString: LegalPages.privacy) { url in
                        legalURL = url
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(Paper.bg.ignoresSafeArea())
        .sheet(isPresented: Binding(
            get: { legalURL != nil },
            set: { if !$0 { legalURL = nil } },
        )) {
            if let legalURL {
                InAppBrowserView(url: legalURL)
            }
        }
    }
}

/// 介绍要点行：赭红点 + 一句话。
private struct IntroPoint: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("·")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Paper.ochre)
            Text(text)
                .font(.system(size: 14))
                .lineSpacing(7)
                .foregroundStyle(Paper.inkMuted)
        }
    }
}

/// 法律文档行：标签 + 右箭头，整行可点，下缘发丝线。
private struct LegalRow: View {
    let label: String
    let urlString: String
    let onOpen: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button {
                if let url = URL(string: urlString) {
                    onOpen(url)
                }
            } label: {
                HStack {
                    Text(label)
                        .font(.system(size: 15))
                        .foregroundStyle(Paper.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Paper.inkMuted)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 15)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HairlineRule()
        }
    }
}
