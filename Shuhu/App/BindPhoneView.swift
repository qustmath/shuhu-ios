import SwiftUI

/// 绑定/换绑手机号页（odui 纸感，对齐 Android `BindPhoneScreen`）：
/// 未绑定走单验证（新号验证码）；已绑定走双验证（旧号确认码 + 新号验证码）。
/// 旧号/新号的「发送中」与倒计时状态相互独立。
struct BindPhoneView: View {
    private let auth: any AuthRepository
    private let currentPhone: String
    private let toast: ToastCenter
    private let onBound: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var newPhone = ""
    @State private var newCode = ""
    @State private var oldCode = ""
    @State private var loading = false
    @State private var oldCodeSending = false
    @State private var oldCodeCountdown = 0
    @State private var newCodeSending = false
    @State private var newCodeCountdown = 0
    #if DEBUG
    @State private var devCode = false
    #endif

    init(auth: any AuthRepository, currentPhone: String, toast: ToastCenter, onBound: @escaping () async -> Void) {
        self.auth = auth
        self.currentPhone = currentPhone
        self.toast = toast
        self.onBound = onBound
    }

    private var rebind: Bool { !currentPhone.isEmpty }

    private var method: String {
        #if DEBUG
        devCode ? Sms.methodDev : Sms.methodSms
        #else
        Sms.methodSms
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            PaperTopBar(title: rebind ? "换绑手机号" : "绑定手机号", onBack: { dismiss() })
            PaperPageHead(
                kicker: rebind ? "CHANGE PHONE" : "BIND PHONE",
                title: rebind ? "换绑手机号" : "绑定手机号",
                sub: rebind ? "需分别验证当前手机号与新手机号。" : "绑定后可用手机号+密码登录。",
            )

            if rebind {
                // 当前手机号行（只读）
                HStack {
                    Text("当前手机号")
                        .font(.system(size: 14))
                        .foregroundStyle(Paper.inkMuted)
                    Spacer()
                    Text(masked(currentPhone))
                        .font(.paperMono(16))
                        .foregroundStyle(Paper.ink)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 15)
                SmsCodeRow(
                    code: $oldCode,
                    countdown: oldCodeCountdown,
                    sending: oldCodeSending,
                    submitLoading: loading,
                    label: "当前手机号验证码",
                    onSend: { Task { await sendOldPhoneCode() } },
                )
            }
            PaperFormRow(label: "新手机号", text: $newPhone, hint: "请输入 11 位手机号", mono: true, keyboard: .phonePad)
            SmsCodeRow(
                code: $newCode,
                countdown: newCodeCountdown,
                sending: newCodeSending,
                submitLoading: loading,
                label: "新手机号验证码",
                onSend: { Task { await sendNewPhoneCode() } },
            )
            #if DEBUG
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
            #endif

            Spacer()

            HairlineRule()
            PaperPrimaryButton(
                text: loading ? "提交中…" : (rebind ? "换绑手机号" : "绑定手机号"),
                isEnabled: !loading,
            ) {
                Task { await submit() }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .background(Paper.bg.ignoresSafeArea())
    }

    // ---- 动作 ----

    /// 发送旧号确认码：phone 必须是当前绑定号，服务端据此发旧号确认码。
    private func sendOldPhoneCode() async {
        oldCodeSending = true
        do {
            try await auth.sendBindPhoneCode(phone: currentPhone, scene: Sms.sceneRebindPhone, method: method)
            oldCodeSending = false
            toast.show("验证码已发送")
            startCountdown(isOld: true)
        } catch {
            oldCodeSending = false
            toast.show(error.localizedDescription)
        }
    }

    /// 发送新号验证码：换绑与绑定共用，服务端按请求号是否为绑定号自动区分场景。
    private func sendNewPhoneCode() async {
        guard validatePhone(newPhone) else { return }
        newCodeSending = true
        do {
            try await auth.sendBindPhoneCode(
                phone: newPhone.trimmingCharacters(in: .whitespaces),
                scene: rebind ? Sms.sceneRebindPhone : Sms.sceneBindPhone,
                method: method,
            )
            newCodeSending = false
            toast.show("验证码已发送")
            startCountdown(isOld: false)
        } catch {
            newCodeSending = false
            toast.show(error.localizedDescription)
        }
    }

    private func startCountdown(isOld: Bool) {
        if isOld { oldCodeCountdown = 60 } else { newCodeCountdown = 60 }
        Task {
            while isOld ? oldCodeCountdown > 0 : newCodeCountdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if isOld { oldCodeCountdown -= 1 } else { newCodeCountdown -= 1 }
            }
        }
    }

    private func submit() async {
        guard validatePhone(newPhone) else { return }
        guard !newCode.trimmingCharacters(in: .whitespaces).isEmpty else {
            toast.show("请输入验证码")
            return
        }
        if rebind, oldCode.trimmingCharacters(in: .whitespaces).isEmpty {
            toast.show("请输入当前手机号的验证码")
            return
        }
        loading = true
        do {
            _ = try await auth.bindPhone(
                phone: newPhone.trimmingCharacters(in: .whitespaces),
                code: newCode.trimmingCharacters(in: .whitespaces),
                oldCode: rebind ? oldCode.trimmingCharacters(in: .whitespaces) : nil,
                scene: rebind ? Sms.sceneRebindPhone : Sms.sceneBindPhone,
                method: method,
            )
            loading = false
            toast.show(rebind ? "手机号已更新" : "绑定成功")
            dismiss()
            await onBound()
        } catch {
            loading = false
            toast.show(error.localizedDescription)
        }
    }

    @discardableResult
    private func validatePhone(_ phone: String) -> Bool {
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

    /// 页内兜底掩码（正常应使用 AuthMember.maskedPhone）。
    private func masked(_ phone: String) -> String {
        phone.count == 11 ? phone.prefix(3) + "****" + phone.suffix(4) : phone
    }
}
