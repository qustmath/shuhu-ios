import SwiftUI

/// 会员购买页（odui membership-v2 纸墨，对齐 Android `MembershipScreen`）：
/// 页头 + 权益清单 + 套餐单选 + 底部开通条。套餐与价格全部来自后台「营销中心 → 会员套餐」；
/// 支付为模拟实现（mock），真实支付渠道接入后替换 `purchase()` 内的调用。
struct MembershipView: View {
    private let client: MembershipClient
    private let auth: any AuthRepository
    private let toast: ToastCenter
    /// 购买成功回调（调用方关页 + 跳设置页 + 成功提示）。
    private let onPurchased: () -> Void
    private let onClose: () -> Void

    @State private var member: AuthMember?
    @State private var plans: [MemberPlanData]?
    @State private var loadFailed = false
    @State private var selectedPlanId: Int64?
    @State private var purchasing = false

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
                }
            }

            bottomBar
        }
        .background(Paper.bg.ignoresSafeArea())
        .onReceive(auth.session) { member = $0 }
        .task { await loadPlans() }
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
            Text(purchasing ? "模拟支付处理中…" : "开通即视为同意《会员服务协议》· 自动续费可随时取消")
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

    /// 模拟支付购买选中套餐：成功刷新登录态快照（level/expireAt 落在 AuthMember 上），
    /// 广告由服务端空结果自然消失。
    private func purchase() async {
        guard let planId = selectedPlanId, !purchasing else { return }
        purchasing = true
        defer { purchasing = false }
        do {
            _ = try await client.purchase(planId: planId)
            _ = try await auth.refreshProfile() // 把最新 level/expireAt 拉进登录态快照
            onPurchased()
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
