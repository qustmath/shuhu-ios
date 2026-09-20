import SwiftUI

/// 发丝线表单行（odui f-row）：标签左 76pt、输入右对齐，下缘发丝线。
/// mono 时输入用等宽（手机号/验证码）；trailing 放行内动作（如发送验证码按钮）。
struct PaperFormRow<Trailing: View>: View {
    let label: String
    @Binding var text: String
    var hint = ""
    var mono = false
    var isPassword = false
    var keyboard: UIKeyboardType = .default
    @ViewBuilder let trailing: Trailing

    init(
        label: String,
        text: Binding<String>,
        hint: String = "",
        mono: Bool = false,
        isPassword: Bool = false,
        keyboard: UIKeyboardType = .default,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
    ) {
        self.label = label
        _text = text
        self.hint = hint
        self.mono = mono
        self.isPassword = isPassword
        self.keyboard = keyboard
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.inkMuted)
                    .frame(width: 76, alignment: .leading)
                Group {
                    if isPassword {
                        SecureField("", text: $text, prompt: promptText)
                    } else {
                        TextField("", text: $text, prompt: promptText)
                    }
                }
                .font(mono ? .paperMono(16) : .system(size: 17))
                .foregroundStyle(Paper.ink)
                .tint(Paper.ochre)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                trailing
                    .padding(.leading, 12)
            }
            .padding(.horizontal, 22)
            .frame(height: 58)
            HairlineRule()
        }
    }

    private var promptText: Text {
        Text(hint)
            .font(.system(size: 15))
            .foregroundColor(Paper.inkMuted.opacity(0.7))
    }
}

/// 验证码输入行（odui f-row + 圆角胶囊发送按钮）：发送后 60s 倒计时，倒计时内禁用。
struct SmsCodeRow: View {
    @Binding var code: String
    let countdown: Int
    let sending: Bool
    let submitLoading: Bool
    var label = "验证码"
    let onSend: () -> Void

    private var enabled: Bool {
        countdown <= 0 && !sending && !submitLoading
    }

    var body: some View {
        PaperFormRow(label: label, text: $code, hint: "6 位数字", mono: true, keyboard: .numberPad) {
            Button(action: onSend) {
                Text(buttonText)
                    .font(countdown > 0 ? .paperMono(13) : .system(size: 13))
                    .foregroundStyle(enabled ? Paper.ink : Paper.inkMuted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .overlay(
                        Capsule().stroke(enabled ? Paper.inkMuted : Paper.inkMuted.opacity(0.4), lineWidth: 1),
                    )
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
        }
    }

    private var buttonText: String {
        if countdown > 0 { return "\(countdown)s 后重发" }
        return sending ? "发送中…" : "获取验证码"
    }
}

/// 协议勾选行（odui）：纸感方框（发丝线边框，选中墨底白勾）+ 可点协议链接；
/// 不勾选时由调用方禁用提交按钮。整行文案 13/20 InkMuted，书名号 Ink 下划线可点。
struct LegalAgreementRow: View {
    @Binding var agreed: Bool
    /// 打开协议页（App 内浏览器）：terms / privacy。
    let onOpen: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                agreed.toggle()
            } label: {
                ZStack {
                    if agreed {
                        RoundedRectangle(cornerRadius: 3).fill(Paper.ink)
                    }
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(agreed ? Paper.ink : Paper.inkMuted, lineWidth: 1)
                    if agreed {
                        Text("✓")
                            .font(.system(size: 11))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 18, height: 18)
                .padding(.top, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(attributedText)
                .font(.system(size: 13))
                .lineSpacing(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.openURL, OpenURLAction { url in
                    if url.host == "terms" {
                        onOpen(LegalPages.terms)
                    } else {
                        onOpen(LegalPages.privacy)
                    }
                    return .handled
                })
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var attributedText: AttributedString {
        var full = AttributedString("我已阅读并同意")
        full.foregroundColor = Paper.inkMuted
        var terms = AttributedString("《用户协议》")
        terms.foregroundColor = Paper.ink
        terms.underlineStyle = .single
        terms.link = URL(string: "shuhu-legal://terms")!
        var conjunction = AttributedString("和")
        conjunction.foregroundColor = Paper.inkMuted
        var privacy = AttributedString("《隐私政策》")
        privacy.foregroundColor = Paper.ink
        privacy.underlineStyle = .single
        privacy.link = URL(string: "shuhu-legal://privacy")!
        full.append(terms)
        full.append(conjunction)
        full.append(privacy)
        return full
    }
}
