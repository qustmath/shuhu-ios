import SwiftUI

// MARK: - 分隔与标签

/// 发丝分隔线（1pt 满宽；odui 全站分隔全靠它，无卡片无阴影）。
struct HairlineRule: View {
    var body: some View {
        Rectangle()
            .fill(Paper.hairline)
            .frame(height: 1)
    }
}

/// 区块小标题（mono 11 muted tracking 1.3），如「会员权益 · BENEFITS」。
struct SectionKicker: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.paperMono(11))
            .tracking(1.3)
            .foregroundStyle(Paper.inkMuted)
    }
}

/// 页头大标题区（登录/注册/会员/设置页）：mono kicker + 衬线大标题 + 副标题。
struct PaperPageHead: View {
    let kicker: String
    let title: String
    var sub: String? = nil
    var titleSize: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kicker)
                .font(.paperMono(11))
                .tracking(1.3)
                .foregroundStyle(Paper.inkMuted)
            Text(title)
                .font(.paperSerif(titleSize, weight: .bold))
                .foregroundStyle(Paper.ink)
                .padding(.top, 8)
            if let sub {
                Text(sub)
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.inkMuted)
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 26)
    }
}

// MARK: - 按钮

/// 赭红主按钮（odui btn-primary）：50pt 方角 4pt，禁用时 40% 透明。
struct PaperPrimaryButton: View {
    let text: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 16, weight: .semibold))
                .tracking(2)
                .foregroundStyle(isEnabled ? .white : Paper.bg)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Paper.ochre.opacity(isEnabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 4))
        }
        .disabled(!isEnabled)
        .buttonStyle(.plain)
    }
}

/// 44pt 圆形发丝线图标按钮（设置齿轮/编辑铅笔/关闭 ✕，三处观感一致）。
struct CircleHairlineButton: View {
    let systemName: String
    var iconSize: CGFloat = 17
    var iconColor: Color = Paper.ink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize))
                .foregroundStyle(iconColor)
                .frame(width: 44, height: 44)
                .overlay(Circle().stroke(Paper.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 顶栏

/// 全屏页共用顶栏：左「‹」返回 + 居中小标题（13 tracking 1 muted）+ 右侧槽位。
struct PaperTopBar<Trailing: View>: View {
    let title: String
    let onBack: () -> Void
    @ViewBuilder let trailing: Trailing

    init(title: String, onBack: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.onBack = onBack
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Paper.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            trailing
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .overlay(alignment: .center) {
            Text(title)
                .font(.system(size: 13))
                .tracking(1)
                .foregroundStyle(Paper.inkMuted)
        }
    }
}

// MARK: - 书籍部件

/// 轮次标签「第 N 轮」（mono 11，发丝线边框，2pt 圆角）。
struct RoundTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.paperMono(11))
            .foregroundStyle(Paper.ink)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Paper.hairline, lineWidth: 1))
    }
}

/// 书脊排印占位：白面、发丝线描边、左缘 3pt 墨线、竖排书名（每字一行实现竖排，最多 5 行）。
struct BookSpine: View {
    let title: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Paper.surface)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Paper.hairline, lineWidth: 1))
            // 左缘墨线（书脊签名，与 logo 中缝同语言）
            Rectangle()
                .fill(Paper.ink)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            // 竖排书名：每字符一行，居中，超出省略
            Text(Self.verticalized(title))
                .font(.paperSerif(13))
                .tracking(1.8)
                .lineSpacing(4)
                .lineLimit(5)
                .multilineTextAlignment(.center)
                .foregroundStyle(Paper.ink)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
        .clipped()
    }

    private static func verticalized(_ title: String) -> String {
        title.prefix(12).map(String.init).joined(separator: "\n")
    }
}

// MARK: - Toast

/// 轻提示中心（Android Toast 对应）：全局单例，2.5 秒自动消失。
@MainActor
final class ToastCenter: ObservableObject {
    @Published private(set) var text: String?
    private var dismissTask: Task<Void, Never>?

    func show(_ text: String) {
        dismissTask?.cancel()
        self.text = text
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.text = nil
        }
    }
}

/// Toast 覆盖层：底部居中、墨底白字胶囊。
struct ToastOverlay: View {
    @ObservedObject var center: ToastCenter

    var body: some View {
        if let text = center.text {
            VStack {
                Spacer()
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Paper.ink.opacity(0.86), in: Capsule())
                    .padding(.bottom, 64)
            }
            .frame(maxWidth: .infinity)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: center.text)
            .allowsHitTesting(false)
        }
    }
}
