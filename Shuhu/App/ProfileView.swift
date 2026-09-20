import SwiftUI
import PhotosUI

/// 设置页（odui editorial 纸感，对齐 Android `ProfileScreen`）：
/// 账号（头像/昵称行内改名/退出）→ 手机号绑定 → 会员 → 数据同步 → 阅读统计（大衬线数字）→ 关于。
struct ProfileView: View {
    private let repository: any LibraryRepository
    private let auth: any AuthRepository
    private let sync: SyncController
    private let toast: ToastCenter
    private let onOpenMembership: () -> Void
    private let onOpenAbout: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var member: AuthMember?
    @State private var syncing = false
    @State private var lastSyncAt: Int64 = 0
    @State private var pendingSwitch: AuthMember?
    @State private var pendingSummary: SyncCloudSummary?

    @State private var showLogin = false
    @State private var showBindPhone = false
    @State private var showAvatarSheet = false
    @State private var editingName = false
    @State private var nameInput = ""

    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var showCamera = false

    @State private var finishedBooks = 0
    @State private var totalPagesRead: Int64 = 0
    @State private var loadError: String?

    init(
        repository: any LibraryRepository,
        auth: any AuthRepository,
        sync: SyncController,
        toast: ToastCenter,
        onOpenMembership: @escaping () -> Void,
        onOpenAbout: @escaping () -> Void,
    ) {
        self.repository = repository
        self.auth = auth
        self.sync = sync
        self.toast = toast
        self.onOpenMembership = onOpenMembership
        self.onOpenAbout = onOpenAbout
    }

    private var lastSyncText: String {
        guard lastSyncAt > 0 else { return "上次同步：—" }
        let date = Date(timeIntervalSince1970: TimeInterval(lastSyncAt) / 1000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "上次同步 " + formatter.string(from: date)
    }

    var body: some View {
        VStack(spacing: 0) {
            PaperTopBar(title: "设置", onBack: { dismiss() })

            ScrollView {
                VStack(spacing: 0) {
                    PaperPageHead(kicker: "SETTINGS", title: "设置", titleSize: 30)
                        .padding(.top, -6)

                    // ── 账号区 ──
                    HairlineRule()
                    accountSection

                    // ── 手机号 ──
                    phoneRow

                    // ── 会员（仅登录后）──
                    if member != nil {
                        HairlineRule()
                        Button(action: onOpenMembership) {
                            SettingsRow(
                                title: "会员",
                                sub: member?.membershipLabel ?? "未开通",
                                action: member?.membershipActive == true ? "查看" : "开通会员，免广告",
                                actionAccent: true,
                                showChevron: true,
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // ── 数据同步（仅登录后）──
                    if member != nil {
                        HairlineRule()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("数据同步")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Paper.ink)
                                Text(lastSyncText)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Paper.inkMuted)
                            }
                            Spacer()
                            Button {
                                Task { await syncNow() }
                            } label: {
                                Text(syncing ? "同步中…" : "立即同步")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Paper.ochre)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            .disabled(syncing)
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 15)
                    }
                    HairlineRule()

                    // ── 阅读统计：大衬线数字 ──
                    VStack(alignment: .leading, spacing: 10) {
                        SectionKicker(text: "阅读统计 · STATS")
                            .padding(.horizontal, 22)
                        HStack(spacing: 0) {
                            BigStatCell(value: "\(finishedBooks)", unit: "本", label: "已读完")
                            Rectangle()
                                .fill(Paper.hairline)
                                .frame(width: 1, height: 84)
                            BigStatCell(value: totalPagesRead.formatted(), unit: "页", label: "累计阅读")
                        }
                    }
                    .padding(.top, 18)

                    // ── 关于 ──
                    Spacer().frame(height: 18)
                    HairlineRule()
                    Button(action: onOpenAbout) {
                        HStack {
                            Text("关于")
                                .font(.system(size: 15))
                                .foregroundStyle(Paper.ink)
                            Spacer()
                            Text("v\(appVersion)")
                                .font(.paperMono(13))
                                .foregroundStyle(Paper.inkMuted)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13))
                                .foregroundStyle(Paper.inkMuted)
                                .padding(.leading, 4)
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 15)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    HairlineRule()

                    Text("未登录时，所有数据仅保存在这台设备上")
                        .font(.paperMono(11))
                        .tracking(0.7)
                        .foregroundStyle(Paper.inkMuted)
                        .frame(maxWidth: .infinity)
                        .padding(22)
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(Paper.bg.ignoresSafeArea())
        .task { await reload() }
        .onReceive(auth.session) { member = $0 }
        .onReceive(sync.syncing) { syncing = $0 }
        .onReceive(sync.lastSyncAt) { lastSyncAt = $0 }
        .onReceive(sync.pendingSwitchAccount) { value in
            pendingSwitch = value
            if value != nil {
                pendingSummary = sync.pendingSwitchCloudSummary.value
            }
        }
        .sheet(isPresented: $showLogin) {
            LoginView(auth: auth, toast: toast) {
                await refreshStats()
            }
        }
        .sheet(isPresented: $showBindPhone) {
            if let member {
                BindPhoneView(auth: auth, currentPhone: member.phone, toast: toast) {
                    // 绑定结果已随 refreshProfile 落进登录态
                }
            }
        }
        .sheet(isPresented: $showAvatarSheet) {
            avatarPickSheet
                .presentationDetents([.height(240)])
                .presentationDragIndicator(.hidden)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data, ext in
                showCamera = false
                updateAvatar(bytes: data, ext: ext)
            }
            .ignoresSafeArea()
        }
        .onChange(of: avatarPickerItem) { _, item in
            guard let item else { return }
            showAvatarSheet = false // 选完即收弹层（与 Android onPicked 一致）
            Task {
                defer { avatarPickerItem = nil }
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let ext = item.supportedContentTypes.contains(.png) ? "png"
                    : item.supportedContentTypes.contains(.webP) ? "webp" : "jpg"
                updateAvatar(bytes: data, ext: ext)
            }
        }
        .alert(
            "检测到账号切换",
            isPresented: Binding(
                get: { pendingSwitch != nil },
                set: { shown in if !shown { pendingSwitch = nil } },
            ),
        ) {
            Button("并入新账号") {
                Task { await sync.resolveAccountSwitch(mergeIntoNewAccount: true) }
            }
            Button("清空本地，以云端为准", role: .destructive) {
                Task { await sync.resolveAccountSwitch(mergeIntoNewAccount: false) }
            }
        } message: {
            Text(switchMessage)
        }
        .alert("出错了", isPresented: .init(get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(loadError ?? "")
        }
    }

    // ---- 账号区 ----

    @ViewBuilder
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionKicker(text: "账号 · ACCOUNT")
            if let member {
                HStack(alignment: .center, spacing: 16) {
                    avatarView(member)
                    VStack(alignment: .leading, spacing: 4) {
                        if editingName {
                            HStack(spacing: 8) {
                                TextField("", text: $nameInput)
                                    .font(.paperSerif(22, weight: .bold))
                                    .foregroundStyle(Paper.ink)
                                    .tint(Paper.ochre)
                                    .onChange(of: nameInput) { _, v in
                                        if v.count > 12 { nameInput = String(v.prefix(12)) }
                                    }
                                Button {
                                    let value = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !value.isEmpty {
                                        updateNickname(value)
                                        editingName = false
                                    }
                                } label: {
                                    Text("保存")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Paper.ochre)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            HStack(spacing: 4) {
                                Text(member.displayName)
                                    .font(.paperSerif(24, weight: .bold))
                                    .foregroundStyle(Paper.ink)
                                    .lineLimit(1)
                                Button {
                                    nameInput = member.nickname.isEmpty ? member.displayName : member.nickname
                                    editingName = true
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 14))
                                        .foregroundStyle(Paper.inkMuted)
                                        .padding(4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Text("已登录 · 数据同步到云端")
                            .font(.system(size: 13))
                            .foregroundStyle(Paper.inkMuted)
                    }
                    Spacer(minLength: 0)
                    Button {
                        Task { await auth.logout() }
                    } label: {
                        Text("退出登录")
                            .font(.system(size: 13))
                            .foregroundStyle(Paper.inkMuted)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    showLogin = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("登录 / 注册")
                                .font(.paperSerif(22, weight: .bold))
                                .foregroundStyle(Paper.ink)
                            Text("登录后可同步阅读数据")
                                .font(.system(size: 13))
                                .foregroundStyle(Paper.inkMuted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13))
                            .foregroundStyle(Paper.inkMuted)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    /// 头像：有服务器头像显示图片，否则昵称首字；右下角相机小徽章；点按弹「更换头像」层。
    private func avatarView(_ member: AuthMember) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Button {
                showAvatarSheet = true
            } label: {
                ZStack {
                    Circle()
                        .fill(Paper.surface)
                        .overlay(Circle().stroke(Paper.hairline, lineWidth: 1))
                    if !member.avatar.isEmpty, let url = avatarURL(member.avatar) {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Text(String(member.displayName.prefix(1)))
                                    .font(.paperSerif(26))
                                    .foregroundStyle(Paper.ink)
                            }
                        }
                    } else {
                        Text(member.displayName.isEmpty ? "书" : String(member.displayName.prefix(1)))
                            .font(.paperSerif(26))
                            .foregroundStyle(Paper.ink)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
            // 右下角相机小徽章
            Button {
                showAvatarSheet = true
            } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Paper.surface)
                    .frame(width: 22, height: 22)
                    .background(Paper.inkMuted.opacity(0.62), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    /// 服务端头像引用：完整 URL 直接用，相对路径拼 API 主机（与 Android 同口径）。
    private func avatarURL(_ avatar: String) -> URL? {
        if avatar.hasPrefix("http") { return URL(string: avatar) }
        return URL(string: "https://rrapi.groovy.ink" + avatar)
    }

    // ---- 手机号行 ----

    @ViewBuilder
    private var phoneRow: some View {
        HairlineRule()
        let bound = !(member?.phone.isEmpty ?? true)
        SettingsRow(
            title: "手机号",
            sub: member == nil
                ? "登录后可用手机号+密码登录"
                : (bound ? "已绑定 \(member?.maskedPhone ?? "")" : "未绑定 · 绑定后可用手机号+密码登录"),
            action: bound ? "换绑" : "绑定",
            actionAccent: false,
            showChevron: true,
            enabled: member != nil,
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if member != nil { showBindPhone = true }
        }
    }

    // ---- 更换头像弹层 ----

    private var avatarPickSheet: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 999)
                .fill(Paper.hairline)
                .frame(width: 36, height: 4)
                .padding(.top, 8)
                .padding(.bottom, 10)
            PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                SheetOption(text: "从相册选择")
            }
            Button {
                // 先收弹层再开相机（避免在 sheet 上叠 fullScreenCover）
                showAvatarSheet = false
                showCamera = true
            } label: {
                SheetOption(text: "拍照")
            }
            .buttonStyle(.plain)
            HairlineRule()
            Button { showAvatarSheet = false } label: {
                SheetOption(text: "取消", muted: true)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 26)
        .background(Paper.bg.ignoresSafeArea())
    }

    // ---- 动作 ----

    private var switchMessage: String {
        if let summary = pendingSummary {
            return "新账号云端：\(summary.liveBooks) 本书 · \(summary.liveRecords) 条记录。并入将保留本地数据自动合并；清空将删除本机全部数据后按云端重建。"
        }
        return "无法获取云端概览。并入将保留本地数据自动合并；若选择清空，请务必确认云端数据不再需要。"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// 立即同步：结果以 Toast 呈现；进行中由 syncing 驱动按钮态。
    private func syncNow() async {
        let ok = await sync.syncNow()
        toast.show(ok ? "同步成功" : "同步失败，请检查网络后重试")
    }

    private func updateNickname(_ nickname: String) {
        Task {
            do {
                _ = try await auth.updateNickname(nickname)
                toast.show("昵称已更新")
            } catch {
                toast.show(error.localizedDescription)
            }
        }
    }

    private func updateAvatar(bytes: Data, ext: String) {
        Task {
            do {
                _ = try await auth.updateAvatar(imageBytes: bytes, ext: ext)
                toast.show("头像已更新")
            } catch {
                toast.show(error.localizedDescription)
            }
        }
    }

    private func reload() async {
        await refreshStats()
        // 进入「我」页刷新会员资料（服务端可能已改名/换绑/会员变更，静默失败不提示）
        if auth.session.value != nil {
            _ = try? await auth.refreshProfile()
        }
    }

    private func refreshStats() async {
        do {
            let books = try await repository.books()
            let records = try await repository.allRecords()
            finishedBooks = ReadingStats.finishedBookCount(books: books, records: records)
            totalPagesRead = ReadingStats.totalPagesRead(records: records)
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - 子组件

/// 通用设置行：左侧标题+说明，右侧动作 + chevron（odui bind-row）。
private struct SettingsRow: View {
    let title: String
    let sub: String
    let action: String
    var actionAccent = false
    var showChevron = false
    var enabled = true

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(Paper.ink)
                Text(sub)
                    .font(.system(size: 12))
                    .foregroundStyle(Paper.inkMuted)
            }
            Spacer()
            Text(action)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(actionAccent ? Paper.ochre : Paper.inkMuted)
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(Paper.inkMuted)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
        .opacity(enabled ? 1 : 0.6)
    }
}

/// 大衬线统计格（设置页 STATS 区）。
private struct BigStatCell: View {
    let value: String
    let unit: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.paperSerif(44, weight: .bold))
                    .foregroundStyle(Paper.ink)
                Text(unit)
                    .font(.system(size: 15))
                    .foregroundStyle(Paper.inkMuted)
                    .padding(.bottom, 6)
            }
            Text(label)
                .font(.system(size: 12))
                .tracking(0.7)
                .foregroundStyle(Paper.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
    }
}

/// 弹层选项行（更换头像等底部弹层用）。
private struct SheetOption: View {
    let text: String
    var muted = false

    var body: some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(muted ? Paper.inkMuted : Paper.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
    }
}
