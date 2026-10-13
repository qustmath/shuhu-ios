import SwiftUI

/// 微信注册会员首次设置密码（服务端 PUT /member/password/set，仅未设密码账号可用）。
/// 解绑唯一微信前必须先设置：手机号验证码登录尚未上线，密码是微信之外的唯一登录方式
///（服务端 model.HasUsableLoginAfterUnbind 判定）。
struct SetPasswordView: View {
    private let auth: any AuthRepository
    private let toast: ToastCenter

    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var confirm = ""
    @State private var loading = false

    init(auth: any AuthRepository, toast: ToastCenter) {
        self.auth = auth
        self.toast = toast
    }

    var body: some View {
        VStack(spacing: 0) {
            PaperTopBar(title: "设置密码", onBack: { dismiss() })
            PaperPageHead(
                kicker: "SET PASSWORD",
                title: "设置密码",
                sub: "设置后可用手机号+密码登录；解绑微信前需先设置密码。",
            )
            PaperFormRow(label: "新密码", text: $password, hint: "至少 6 位", isPassword: true)
            PaperFormRow(label: "确认密码", text: $confirm, hint: "再输入一次", isPassword: true)

            Spacer()

            HairlineRule()
            PaperPrimaryButton(
                text: loading ? "提交中…" : "设置密码",
                isEnabled: !loading,
            ) {
                Task { await submit() }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .background(Paper.bg.ignoresSafeArea())
        // sheet 层级高于根视图挂载的 ToastOverlay，页内提示需自挂一份
        .overlay { ToastOverlay(center: toast) }
    }

    private func submit() async {
        guard password.count >= 6 else {
            toast.show("密码长度不能少于 6 位")
            return
        }
        guard password == confirm else {
            toast.show("两次输入的密码不一致")
            return
        }
        loading = true
        do {
            _ = try await auth.setPassword(password)
            loading = false
            toast.show("密码已设置")
            dismiss()
        } catch {
            loading = false
            toast.show(error.localizedDescription)
        }
    }
}
