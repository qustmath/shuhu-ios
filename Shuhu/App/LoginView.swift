import SwiftUI

/// 登录 / 注册（手机号 + 密码 + 短信验证码，ADR-0004）。注册成功即登录；
/// 登录态经引擎的 session 观察自动触发首轮同步，本页只负责身份。
struct LoginView: View {
    let auth: AuthRepository
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var mode: Mode = .login
    @State private var phone = ""
    @State private var password = ""
    @State private var code = ""
    @State private var countdown = 0
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var countdownTask: Task<Void, Never>?

    enum Mode: String, CaseIterable, Identifiable {
        case login = "登录"
        case register = "注册"
        var id: String { rawValue }
    }

    private var phoneValid: Bool {
        phone.count == 11 && phone.allSatisfy(\.isNumber)
    }

    private var inputValid: Bool {
        phoneValid && !password.isEmpty && (mode == .login || code.count >= 4)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("模式", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section(mode == .login ? "账号登录" : "创建账号") {
                    TextField("手机号", text: $phone)
                        .keyboardType(.numberPad)
                        .textContentType(.username)
                    SecureField("密码", text: $password)
                        .textContentType(.newPassword)
                    if mode == .register {
                        HStack {
                            TextField("验证码", text: $code)
                                .keyboardType(.numberPad)
                            Button {
                                Task { await sendCode() }
                            } label: {
                                Text(countdown > 0 ? "\(countdown)s" : "获取验证码")
                                    .font(.footnote)
                            }
                            .disabled(countdown > 0 || !phoneValid || busy)
                        }
                    }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        Text(busy ? "请稍候…" : (mode == .login ? "登录" : "注册并登录"))
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!inputValid || busy)
                }
                Section {
                    legalFooter
                }
            }
            .navigationTitle(mode == .login ? "登录" : "注册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("提示", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.large])
        .onDisappear { countdownTask?.cancel() }
    }

    private var legalFooter: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                Text("登录即代表同意")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                link("《用户协议》", urlString: LegalPages.terms)
                link("与", urlString: nil)
                link("《隐私政策》", urlString: LegalPages.privacy)
            }
        }
    }

    private func link(_ label: String, urlString: String?) -> some View {
        Group {
            if let urlString {
                Button(label) {
                    if let url = URL(string: urlString) {
                        openURL(url)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.purple)
            } else {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sendCode() async {
        guard phoneValid else { return }
        do {
            try await auth.sendSmsCode(phone: phone, scene: Sms.sceneRegister, method: Sms.methodSms)
            startCountdown()
        } catch {
            errorMessage = (error as? ApiError)?.message ?? error.localizedDescription
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task {
            for remaining in stride(from: 60, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                countdown = remaining
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    countdown = 0
                    return
                }
            }
            countdown = 0
        }
    }

    private func submit() async {
        busy = true
        defer { busy = false }
        do {
            switch mode {
            case .login:
                _ = try await auth.login(phone: phone, password: password)
            case .register:
                _ = try await auth.register(phone: phone, password: password, code: code, method: Sms.methodSms)
            }
            onDone()
            dismiss()
        } catch {
            errorMessage = (error as? ApiError)?.message ?? error.localizedDescription
        }
    }
}
