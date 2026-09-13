import SwiftUI
import Combine

/// 「我」页（设置）：账号与同步区（登录/登出/立即同步/换账号裁决）
/// + 应用名与版本 + 两项统计 + 法律条款入口（Android `ProfileScreen` 镜像）。
struct ProfileView: View {
    private let repository: any LibraryRepository
    private let auth: AuthRepository
    private let sync: SyncController

    @State private var member: AuthMember?
    @State private var syncing = false
    @State private var lastSyncAt: Int64 = 0
    @State private var pendingSwitch: AuthMember?
    @State private var pendingSummary: SyncCloudSummary?
    @State private var showLogin = false
    @State private var showLogoutConfirm = false
    @State private var finishedBooks = 0
    @State private var totalPagesRead: Int64 = 0
    @State private var loadError: String?

    @State private var legalURL: URL?

    init(repository: any LibraryRepository, auth: AuthRepository, sync: SyncController) {
        self.repository = repository
        self.auth = auth
        self.sync = sync
    }

    private var lastSyncText: String {
        guard lastSyncAt > 0 else { return "从未同步" }
        let date = Date(timeIntervalSince1970: TimeInterval(lastSyncAt) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    var body: some View {
        List {
            accountSection
            Section {
                HStack {
                    Text("书乎")
                        .font(.headline)
                    Text("v\(appVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                statRow(label: "已读完", value: "\(finishedBooks)", unit: "本")
                statRow(label: "累计阅读", value: "\(totalPagesRead)", unit: "页")
            }
            Section {
                legalRow("用户协议", urlString: LegalPages.terms)
                legalRow("隐私政策", urlString: LegalPages.privacy)
            }
            Section {
                Text("所有数据仅保存在这台设备上；登录后可云同步")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .task {
            for await value in auth.session.values {
                member = value
            }
        }
        .task {
            for await value in sync.syncing.values {
                syncing = value
            }
        }
        .task {
            for await value in sync.lastSyncAt.values {
                lastSyncAt = value
            }
        }
        .task {
            for await value in sync.pendingSwitchAccount.values {
                pendingSwitch = value
                if value != nil {
                    pendingSummary = sync.pendingSwitchCloudSummary.value
                }
            }
        }
        .task { await reload() }
        .sheet(isPresented: $showLogin) {
            LoginView(auth: auth) {
                await refreshStats()
            }
        }
        .alert("退出登录", isPresented: $showLogoutConfirm) {
            Button("退出", role: .destructive) { Task { await auth.logout() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本地数据保留不动，退出后将不再同步。")
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
        .sheet(isPresented: Binding(
            get: { legalURL != nil },
            set: { if !$0 { legalURL = nil } },
        )) {
            if let legalURL {
                InAppBrowserView(url: legalURL)
            }
        }
    }

    // ---- 账号与同步 ----

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if let member {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.displayName)
                            .font(.headline)
                        Text("已登录")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Button {
                    Task { await syncNow() }
                } label: {
                    HStack {
                        Text(syncing ? "同步中…" : "立即同步")
                            .foregroundStyle(.purple)
                        Spacer()
                        if syncing {
                            ProgressView()
                        }
                    }
                }
                .disabled(syncing)
                Text("上次同步：\(lastSyncText)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("退出登录") { showLogoutConfirm = true }
                    .foregroundStyle(.red)
            } else {
                Button {
                    showLogin = true
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("登录 / 注册")
                        Text("登录后可同步阅读数据")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var switchMessage: String {
        if let summary = pendingSummary {
            return "云端已有 \(summary.liveBooks) 本书、\(summary.liveRecords) 条记录。并入将保留本地数据自动合并；清空将删除本机全部数据后按云端重建。"
        }
        return "无法获取云端概览。并入将保留本地数据自动合并；若选择清空，请务必确认云端数据不再需要。"
    }

    /// 手动同步；失败（已登录前提下）给一次性提示。
    private func syncNow() async {
        let ok = await sync.syncNow()
        if !ok, auth.session.value != nil {
            loadError = "同步失败，请检查网络后重试"
        }
    }

    // ---- 统计与其它 ----

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private func statRow(label: String, value: String, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.body.bold())
                .foregroundStyle(.purple)
            Text(unit)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func legalRow(_ label: String, urlString: String) -> some View {
        Button {
            legalURL = URL(string: urlString) // App 内打开（与 Android WebViewScreen 一致）
        } label: {
            HStack {
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func reload() async {
        do {
            let books = try await repository.books()
            let records = try await repository.allRecords()
            finishedBooks = ReadingStats.finishedBookCount(books: books, records: records)
            totalPagesRead = ReadingStats.totalPagesRead(records: records)
            // 进入「我」页刷新会员资料（服务端可能已改名/换绑，静默失败不提示）
            if auth.session.value != nil {
                _ = try? await auth.refreshProfile()
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func refreshStats() async {
        do {
            let books = try await repository.books()
            let records = try await repository.allRecords()
            finishedBooks = ReadingStats.finishedBookCount(books: books, records: records)
            totalPagesRead = ReadingStats.totalPagesRead(records: records)
        } catch {
            // 统计刷新失败不打扰用户
        }
    }
}
