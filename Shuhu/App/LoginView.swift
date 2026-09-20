import SwiftUI

/// 登录/注册/重置密码（odui 纸感，对齐 Android LoginScreen/RegisterScreen/ResetPasswordScreen）：
/// 登录 ↔ 注册 ↔ 重置密码三态页内切换（Android 为三个全屏页压栈，iOS 在 sheet 内做状态机）。
/// 协议勾选：不勾选不能登录/注册；验证码发送后 60s 倒计时。
/// debug 构建额外提供「模拟微信登录」与 dev 固定验证码（ADR-0009 开发联调入口，正式版不显示）。
struct LoginView: View {
    private enum Mode {
        case login, register, reset

        var title: String {
            switch self {
            case .login: "登录"
            case .register: "注册"
            case .reset: "重置密码"
            }
        }

        var head: (kicker: String, title: String, sub: String) {
            switch self {
            case .login: ("WELCOME BACK", "欢迎回来", "登录后，阅读数据会同步到云端。")
            case .register: ("JOIN SHUHU", "加入书乎", "注册成功即自动登录，随时开始记录。")
            case .reset: ("RESET PASSWORD", "重置密码", "验证手机号后设置新密码。")
            }
        }
    }

    private let auth: any AuthRepository
    private let toast: ToastCenter
    private let onDone: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .login
    @State private var phone = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var code = ""
    @State private var agreed = false
    @State private var loading = false
    @State private var codeSending = false
    @State private var codeCountdown = 0
    @State private var legalURL: URL?
    #if DEBUG
    @State private var devCode = false
    #endif

    init(auth: any AuthRepository, toast: ToastCenter, onDone: @escaping () async -> Void) {
        self.auth = auth
        self.toast = toast
        self.onDone = onDone
    }

    private var method: String {
        #if DEBUG
        devCode ? Sms.methodDev : Sms.methodSms
        #else
        Sms.methodSms
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            PaperTopBar(title: mode.title) {
                if mode == .login { dismiss() } else { mode = .login }
            }
            PaperPageHead(
                kicker: mode.head.kicker,
                title: mode.head.title,
                sub: mode.head.sub,
            )

            PaperFormRow(label: "手机号", text: $phone, hint: "请输入 11 位手机号", mono: true, keyboard: .phonePad)
            if mode != .login {
                SmsCodeRow(
                    code: $code,
                    countdown: codeCountdown,
                    sending: codeSending,
                    submitLoading: loading,
                    onSend: { Task { await sendCode() } },
                )
            }
            PaperFormRow(
                label: mode == .reset ? "新密码" : "密码",
                text: $password,
                hint: "至少 6 位",
                isPassword: true,
            )
            if mode != .login {
                PaperFormRow(label: "确认密码", text: $confirm, hint: "再输入一次", isPassword: true)
            }
            if mode != .reset {
                LegalAgreementRow(agreed: $agreed) { urlString in
                    legalURL = URL(string: urlString)
                }
            }
            #if DEBUG
            if mode != .login {
                Button {
                    devCode.toggle()
                } label: {
                    Text(devCode ? "开发联调验证码：开（固定 123456）" : "开发联调验证码：关")
                        .font(.system(size: 13))
                        .foregroundStyle(Paper.inkMuted)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
            #endif

            Spacer()

            HairlineRule()
            VStack(spacing: 6) {
                PaperPrimaryButton(
                    text: submitText,
                    isEnabled: !loading && (mode == .reset || agreed),
                ) {
                    Task { await submit() }
                }
                if mode == .login {
                    HStack(spacing: 4) {
                        Button {
                            mode = .reset
                        } label: {
                            Text("忘记密码？")
                                .font(.system(size: 13))
                                .foregroundStyle(Paper.inkMuted)
                                .padding(10)
                        }
                        .buttonStyle(.plain)
                        Text("·")
                            .foregroundStyle(Paper.hairline)
                        Button {
                            mode = .register
                        } label: {
                            Text("没有账号？去注册")
                                .font(.system(size: 13))
                                .foregroundStyle(Paper.inkMuted)
                                .padding(10)
                        }
                        .buttonStyle(.plain)
                    }
                }
                #if DEBUG
                if mode == .login {
                    HairlineRule()
                    Button {
                        Task { await loginWithWechatDev() }
                    } label: {
                        Text("模拟微信登录（开发联调）")
                            .font(.system(size: 15))
                            .foregroundStyle(Paper.ink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Paper.inkMuted, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(loading)
                    Text("仅此开发构建可见，正式版不显示")
                        .font(.system(size: 12))
                        .foregroundStyle(Paper.inkMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                #endif
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 8)
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

    private var submitText: String {
        if loading {
            switch mode {
            case .login: return "登录中…"
            case .register: return "注册中…"
            case .reset: return "提交中…"
            }
        }
        switch mode {
        case .login: return "登 录"
        case .register: return "注册并登录"
        case .reset: return "重置密码"
        }
    }

    // ---- 动作 ----

    private func sendCode() async {
        guard validatePhone() else { return }
        codeSending = true
        do {
            try await auth.sendSmsCode(
                phone: phone.trimmingCharacters(in: .whitespaces),
                scene: mode == .register ? Sms.sceneRegister : Sms.sceneResetPassword,
                method: method,
            )
            codeSending = false
            toast.show("验证码已发送")
            startCountdown()
        } catch {
            codeSending = false
            toast.show(error.localizedDescription)
        }
    }

    private func startCountdown() {
        codeCountdown = 60
        Task {
            while codeCountdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                codeCountdown -= 1
            }
        }
    }

    private func submit() async {
        switch mode {
        case .login: await loginSubmit()
        case .register: await registerSubmit()
        case .reset: await resetSubmit()
        }
    }

    private func loginSubmit() async {
        guard validatePhonePassword() else { return }
        await run(successMessage: "登录成功", closeOnSuccess: true) {
            _ = try await auth.login(phone: phone.trimmingCharacters(in: .whitespaces), password: password)
        }
    }

    private func registerSubmit() async {
        guard validatePhonePassword() else { return }
        guard password == confirm else {
            toast.show("两次输入的密码不一致")
            return
        }
        guard validateCode() else { return }
        await run(successMessage: "注册成功", closeOnSuccess: true) {
            _ = try await auth.register(
                phone: phone.trimmingCharacters(in: .whitespaces),
                password: password,
                code: code.trimmingCharacters(in: .whitespaces),
                method: method,
            )
        }
    }

    private func resetSubmit() async {
        guard validatePhone(), validateCode() else { return }
        guard !password.isEmpty, password.count >= 6 else {
            toast.show("密码长度不能少于 6 位")
            return
        }
        guard password == confirm else {
            toast.show("两次输入的密码不一致")
            return
        }
        await run(successMessage: "密码已重置，请重新登录", closeOnSuccess: false) {
            try await auth.resetPassword(
                phone: phone.trimmingCharacters(in: .whitespaces),
                code: code.trimmingCharacters(in: .whitespaces),
                newPassword: password,
                method: method,
            )
        }
        // 重置成功回登录页（不进入登录态，用新密码重新登录）
    }

    /// 开发联调：固定 dev 身份，重复登录进同一个测试会员（ADR-0009）。
    private func loginWithWechatDev() async {
        await run(successMessage: "登录成功", closeOnSuccess: true) {
            _ = try await auth.loginWithWechatDev(devCode: "dev:ios")
        }
    }

    private func run(successMessage: String, closeOnSuccess: Bool, block: () async throws -> Void) async {
        loading = true
        do {
            try await block()
            loading = false
            toast.show(successMessage)
            if closeOnSuccess {
                dismiss()
                await onDone()
            } else {
                mode = .login
            }
        } catch {
            loading = false
            toast.show(error.localizedDescription)
        }
    }

    // ---- 校验（提示经 Toast 呈现，不污染页面）----

    @discardableResult
    private func validatePhone() -> Bool {
        let trimmed = phone.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            toast.show("请输入手机号")
            return false
        }
        guard trimmed.range(of: #"^1\d{10}$"#, options: .regularExpression) != nil else {
            toast.show("手机号格式不正确")
            return false
        }
        return true
    }

    @discardableResult
    private func validatePhonePassword() -> Bool {
        guard validatePhone() else { return false }
        if password.isEmpty {
            toast.show("请输入密码")
            return false
        }
        guard password.count >= 6 else {
            toast.show("密码长度不能少于 6 位")
            return false
        }
        return true
    }

    @discardableResult
    private func validateCode() -> Bool {
        guard !code.trimmingCharacters(in: .whitespaces).isEmpty else {
            toast.show("请输入验证码")
            return false
        }
        return true
    }
}
