import StoreKit
import SwiftUI

/// 会员购买页（odui membership-v2 纸墨，对齐 Android `MembershipScreen`）：
/// 页头 + 权益清单 + 套餐单选 + 底部开通条。套餐与价格全部来自后台「营销中心 → 会员套餐」；
/// 支付为苹果内购（StoreKit 2 先单后买，docs/pay/client-integration.md §2）：
/// ① 服务端建支付单（payNo + appAccountToken + productId）② 持久化未完成单
/// ③ StoreKit 购买（带 .appAccountToken）④ 服务端验证成功才 finish ⑤ 刷新登录态。
/// 发货在服务端（支付分发回调）；启动重放与恢复购买兜底中断/重装场景。
struct MembershipView: View {
    private let client: MembershipClient
    private let auth: any AuthRepository
    private let toast: ToastCenter
    /// 购买成功回调（调用方关页 + 跳设置页 + 成功提示）。
    private let onPurchased: () -> Void
    private let onClose: () -> Void
    /// 未完成支付单持久化（先单后买契约 §2.1-2）。
    private let pendingStore = PendingPurchaseStore()

    @State private var member: AuthMember?
    @State private var plans: [MemberPlanData]?
    @State private var loadFailed = false
    @State private var selectedPlanId: Int64?
    @State private var purchasing = false
    @State private var restoring = false

    init(
        client: MembershipClient,
        auth: any AuthRepository,
        toast: ToastCenter,
        onPurchased: @escaping () -> Void,
        onClose: @escaping () -> Void,
    ) {
        self.client = client
        self.auth = auth
        self.toast = toast
        self.onPurchased = onPurchased
        self.onClose = onClose
    }

    private var membershipLabel: String {
        member?.membershipLabel ?? "未开通"
    }

    private var selectedPlan: MemberPlanData? {
        plans?.first { $0.id == selectedPlanId }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaperTopBar(title: "会员", onBack: onClose)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PaperPageHead(
                        kicker: "MEMBERSHIP",
                        title: "书乎会员",
                        sub: member?.membershipActive == true
                            ? "\(membershipLabel) · 全站无广告。"
                            : "一次开通，全站无广告。",
                    )

                    SectionKicker(text: "会员权益 · BENEFITS")
                        .kickerPadding()
                    BenefitRow(title: "开屏广告移除", desc: "启动即达书架，不再等待倒计时。")
                    HairlineRule()
                    BenefitRow(title: "列表广告移除", desc: "书架清清爽爽，只剩你的书。")
                    HairlineRule()
                    Text("更多权益规划中，会员期间免费享用")
                        .font(.system(size: 14))
                        .foregroundStyle(Paper.inkMuted)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)

                    SectionKicker(text: "选择方案 · PLANS")
                        .kickerPadding()
                    plansContent

                    HStack {
                        Spacer()
                        Button {
                            Task { await restorePurchases() }
                        } label: {
                            Text(restoring ? "恢复中…" : "恢复购买")
                                .font(.system(size: 13))
                                .foregroundStyle(Paper.inkMuted)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .disabled(restoring)
                    }
                }
            }

            bottomBar
        }
        .background(Paper.bg.ignoresSafeArea())
        // sheet 层级高于根视图挂载的 ToastOverlay，页内提示需自挂一份
        .overlay { ToastOverlay(center: toast) }
        .onReceive(auth.session) { member = $0 }
        .task { await loadPlans() }
        .task { await replayUnfinishedPurchases() }
    }

    // ---- 套餐区 ----

    @ViewBuilder
    private var plansContent: some View {
        if plans == nil && !loadFailed {
            Text("套餐加载中…")
                .font(.system(size: 13))
                .foregroundStyle(Paper.inkMuted)
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
        } else if loadFailed || plans?.isEmpty != false {
            VStack(alignment: .leading, spacing: 0) {
                Text(loadFailed ? "套餐加载失败" : "暂无可购套餐")
                    .font(.system(size: 13))
                    .foregroundStyle(Paper.inkMuted)
                Button {
                    Task { await loadPlans() }
                } label: {
                    Text("点击重试")
                        .font(.system(size: 13))
                        .foregroundStyle(Paper.ink)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        } else if let plans {
            VStack(spacing: 0) {
                ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                    PlanRow(
                        plan: plan,
                        selected: plan.id == selectedPlanId,
                        onClick: { selectedPlanId = plan.id },
                    )
                    if index < plans.count - 1 { HairlineRule() }
                }
            }
        }
    }

    // ---- 底部开通条 ----

    private var bottomBar: some View {
        VStack(spacing: 0) {
            HairlineRule()
            // 已是会员的继续购买 = 续费（有效期在剩余期上累加）
            let action = member?.membershipActive == true ? "续费" : "开通"
            PaperPrimaryButton(
                text: selectedPlan.map { "¥\($0.priceLabel) \(action)\($0.name)" } ?? "选择套餐",
                isEnabled: selectedPlan != nil && !purchasing,
            ) {
                Task { await purchase() }
            }
            .padding(.top, 12)
            Text(purchasing ? "支付处理中…" : "开通即视为同意《会员服务协议》· 自动续费可随时取消")
                .font(.system(size: 12))
                .foregroundStyle(Paper.inkMuted)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 8)
        .background(Paper.bg)
    }

    // ---- 动作 ----

    private func loadPlans() async {
        if plans != nil || purchasing { return }
        loadFailed = false
        do {
            let list = try await client.plans()
            plans = list
            if !(list.map(\.id).contains(selectedPlanId ?? -1)) {
                selectedPlanId = list.first?.id
            }
        } catch {
            loadFailed = true
            toast.show(error.localizedDescription)
        }
    }

    /// 真实支付购买选中套餐（StoreKit 2 先单后买）：全链路成功刷新登录态快照并跳回；
    /// 失败/取消给出提示。交易在验证成功前保持未完成（失败可重放，契约 §2.1-4）。
    private func purchase() async {
        guard let plan = selectedPlan, !purchasing else { return }
        purchasing = true
        defer { purchasing = false }
        do {
            // ① 先单后买：服务端建支付单（同套餐有效单重复下单幂等命中）
            let order = try await client.createOrder(planId: plan.id)
            guard let payNo = order.payNo, !payNo.isEmpty,
                  let token = order.appAccountToken, !token.isEmpty,
                  let productId = order.productId, !productId.isEmpty,
                  let tokenUUID = UUID(uuidString: token) else {
                throw ApiError(code: nil, "服务器错误，请稍后再试")
            }
            // ② Create 后立即持久化（中断/被杀后启动重放的依据）
            pendingStore.save(PendingPurchase(payNo: payNo, appAccountToken: token, productId: productId, createdAt: .now))
            // ③ StoreKit 购买：必须带 .appAccountToken（契约 §2.1-3，防一笔交易认领多单）
            guard let product = try await Product.products(for: [productId]).first else {
                throw ApiError(code: nil, "内购商品暂不可用，请稍后再试")
            }
            let result = try await product.purchase(options: [.appAccountToken(tokenUUID)])
            switch result {
            case .success(let verification):
                let transaction = try StoreKitVerifier.verified(verification)
                // ④ 服务端验证成功后才 finish（过早 finish 验证失败将无法补拿凭证）
                let status = try await client.verify(payNo: payNo, transactionId: "\(transaction.id)")
                if status == "success" {
                    pendingStore.remove(payNo: payNo)
                    await transaction.finish()
                    _ = try await auth.refreshProfile() // 把最新 level/expireAt 拉进登录态快照
                    onPurchased()
                } else {
                    // 服务端已确认但分发未完成：交易保持未完成，启动重放会补 finish
                    toast.show("支付确认中，会员权益稍后自动生效")
                }
            case .userCancelled:
                toast.show("已取消支付")
            case .pending:
                toast.show("支付待确认（家长批准后自动生效）")
            @unknown default:
                toast.show("支付未完成，请重试")
            }
        } catch {
            toast.show(error.localizedDescription)
        }
    }

    /// 启动重放（契约 §2.1-5）：对每笔未 finish 的交易按 appAccountToken 找回单据重放
    /// verify——断网/被杀/分发未完成场景唯一的补救路径。找不到单据的孤儿交易不动
    /// （保持未完成，restore/人工核验处理）。
    private func replayUnfinishedPurchases() async {
        for await result in Transaction.unfinished {
            guard let transaction = try? StoreKitVerifier.verified(result) else { continue }
            guard let token = transaction.appAccountToken?.uuidString,
                  let pending = pendingStore.pending(appAccountToken: token) else { continue }
            do {
                let status = try await client.verify(payNo: pending.payNo, transactionId: "\(transaction.id)")
                if status == "success" {
                    pendingStore.remove(payNo: pending.payNo)
                    await transaction.finish()
                    _ = try? await auth.refreshProfile()
                }
            } catch {
                // 验证失败交易保持未完成，下次启动/重进页重放
            }
        }
    }

    /// 恢复购买（换机/重装）：按本地留存的 appAccountToken 逐个找回台账明细；
    /// status=success 视为已履约刷新登录态，needsManualReview 引导联系客服。
    private func restorePurchases() async {
        guard !restoring else { return }
        restoring = true
        defer { restoring = false }
        do {
            let tokens = pendingStore.list().map(\.appAccountToken)
            guard !tokens.isEmpty else {
                toast.show("没有待恢复的购买记录")
                return
            }
            var fulfilled = false
            var manual = false
            for token in tokens {
                let data = try await client.restore(appAccountToken: token)
                if let transactions = data.transactions {
                    fulfilled = fulfilled || transactions.contains { $0.status == "success" }
                }
                if data.needsManualReview == true { manual = true }
            }
            if fulfilled {
                _ = try await auth.refreshProfile()
                onPurchased()
            } else if manual {
                toast.show("购买需要人工核验，请联系客服处理")
            } else {
                toast.show("未找到可恢复的购买记录")
            }
        } catch {
            toast.show(error.localizedDescription)
        }
    }
}

// MARK: - 子组件

private extension View {
    func kickerPadding() -> some View {
        padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 8)
    }
}

/// 权益行：标题 + ✓ + 说明（odui benefit-row）。
private struct BenefitRow: View {
    let title: String
    let desc: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Paper.ink)
                Spacer()
                Text("✓")
                    .font(.system(size: 16))
                    .foregroundStyle(Paper.ink)
            }
            Text(desc)
                .font(.system(size: 13))
                .foregroundStyle(Paper.inkMuted)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }
}

/// 套餐单选行（odui plan-row）：圆点 radio + 名称/角标/副标题 + 右侧衬线价格。
private struct PlanRow: View {
    let plan: MemberPlanData
    let selected: Bool
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 14) {
                // radio：选中 = 墨色描边 + 实心点
                Circle()
                    .stroke(selected ? Paper.ink : Paper.inkMuted, lineWidth: 1)
                    .frame(width: 20, height: 20)
                    .overlay {
                        if selected {
                            Circle().fill(Paper.ink).frame(width: 10, height: 10)
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(plan.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Paper.ink)
                            .lineLimit(1)
                        if let tag = plan.tagLabel, !tag.isEmpty {
                            Text(tag)
                                .font(.paperMono(10))
                                .tracking(0.8)
                                .foregroundStyle(Paper.ink)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Paper.ink, lineWidth: 1))
                        }
                    }
                    if let sub = plan.subLabel, !sub.isEmpty {
                        Text(sub)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Paper.inkMuted)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(alignment: .lastTextBaseline, spacing: 0) {
                        Text("¥")
                            .font(.system(size: 14))
                            .foregroundStyle(Paper.ink)
                        Text(plan.priceLabel)
                            .font(.paperSerif(26, weight: .bold))
                            .foregroundStyle(Paper.ink)
                    }
                    Text(plan.unitLabel ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(Paper.inkMuted)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
