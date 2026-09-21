import Foundation
import Combine
import OSLog

/// 同步引擎（data-sync 票 07/08/09，ADR-0007 客户端主从）：
/// - 本地写操作经 `SyncAwareLibraryRepository` 入待推队列，`notifyLocalChange` 防抖推送
/// - 首次同步把本地全部数据标记待推（本地全量上行，首登合并的基础）
/// - 拉取按游标分页；远端变更经 `applyRemoteBook/applyRemoteRecord` 原样应用（LWW）
/// - 断网/服务端错误一律静默：本地数据不丢，下次触发（启动/写操作/登录）自然重试
/// - 游标只在一轮全部应用成功后推进（见 `pullAll()`）：中途失败不丢已拉取的记录
public final class SyncEngine: SyncController, @unchecked Sendable {

    private static let logger = Logger(subsystem: "ink.groovy.shuhu", category: "sync")

    /// 未装饰的内层仓库：引擎读取与远端应用都走它（避免远端应用被误标为本地变更）。
    private let repository: LibraryRepository
    private let api: SyncApi
    private let apiBaseURL: String
    private let sessionPublisher: CurrentValueSubject<AuthMember?, Never>
    private let store: SyncStore
    private let debounceNanoseconds: UInt64

    private var startTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var syncChain: Task<Bool, Never>?
    private var started = false

    public let syncing = CurrentValueSubject<Bool, Never>(false)
    public let lastSyncAt = CurrentValueSubject<Int64, Never>(0)
    public let pendingSwitchAccount = CurrentValueSubject<AuthMember?, Never>(nil)
    public let pendingSwitchCloudSummary = CurrentValueSubject<SyncCloudSummary?, Never>(nil)

    public init(
        repository: LibraryRepository,
        api: SyncApi,
        apiBaseURL: String,
        session: CurrentValueSubject<AuthMember?, Never>,
        store: SyncStore,
        debounceNanoseconds: UInt64 = 3_000_000_000,
    ) {
        self.repository = repository
        self.api = api
        self.apiBaseURL = apiBaseURL
        self.sessionPublisher = session
        self.store = store
        self.debounceNanoseconds = debounceNanoseconds
    }

    /// 启动：观察登录态自动同步，并做账号切换检测（票 08）：
    /// - 首次登录（从未同步）：重置同步状态后静默合并（本地全量上行 + 云端下行，LWW）
    /// - 同一账号：正常自动同步
    /// - 不同账号：挂起同步，弹窗等待 `resolveAccountSwitch` 裁决
    public func start() {
        guard !started else { return }
        started = true
        lastSyncAt.send(store.lastSyncAt()) // 启动恢复上次同步时间
        startTask = Task { [weak self] in
            guard let self else { return }
            for await member in self.sessionPublisher.values {
                await self.handleSession(member)
            }
        }
    }

    // ---- 本地写操作接入 ----

    /// 装饰器登记本地变更：入待推队列并调度防抖推送。
    public func markBooksChanged(_ guids: some Collection<String>) {
        store.addPendingBooks(guids)
        notifyLocalChange()
    }

    public func markRecordsChanged(_ guids: some Collection<String>) {
        store.addPendingRecords(guids)
        notifyLocalChange()
    }

    /// 本地写操作后由装饰器调用：防抖合并写高峰为一次同步。
    public func notifyLocalChange() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.debounceNanoseconds)
            } catch {
                return // 被下一次写操作取消
            }
            _ = await self.syncNow()
        }
    }

    /// 手动触发一轮完整同步。false = 未登录、换账号待裁决，或网络/服务端失败。
    /// 多处触发并发到达时按提交顺序串行执行（对齐 Android Mutex 语义）。
    @discardableResult
    public func syncNow() async -> Bool {
        let previous = syncChain
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            _ = await previous?.value
            return await self.performSync()
        }
        syncChain = task
        return await task.value
    }

    /// 裁决换账号弹窗（票 08）。两个分支都必须先重置同步状态：游标与待推队列属于旧账号。
    /// - 并入：保留本地数据，走首登静默合并（本地全量上行、云端下行，LWW 逐条取新）
    /// - 清空：本地（含墓碑）物理清空后按云端全量重建；硬删除不打墓碑，云端不受影响
    public func resolveAccountSwitch(mergeIntoNewAccount: Bool) async {
        guard pendingSwitchAccount.value != nil else { return }
        pendingSwitchAccount.send(nil)
        pendingSwitchCloudSummary.send(nil)
        if !mergeIntoNewAccount {
            try? await repository.clearAllLibrary()
        }
        store.clearSyncState()
        _ = await syncNow()
    }

    // ---- 一轮同步 ----

    private func performSync() async -> Bool {
        guard let member = sessionPublisher.value else { return false }
        if pendingSwitchAccount.value != nil { return false } // 账号未裁决前，旧账号的游标不可用
        syncing.send(true)
        defer { syncing.send(false) }
        do {
            try await ensureInitialUploadMarked()
            try await healRelativeCoverReferences()
            try await markLocalCoversPending()
            try await pushPending()
            try await pullAll()
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            store.saveLastSync(accountId: member.id, atMillis: now)
            lastSyncAt.send(now)
            return true
        } catch {
            return false // 断网/5xx/401 均静默：本地数据不丢，下次触发自然重试
        }
    }

    private func handleSession(_ member: AuthMember?) async {
        guard let member else {
            pendingSwitchAccount.send(nil)
            pendingSwitchCloudSummary.send(nil)
            return
        }
        let lastAccountId = store.lastSyncAccountId()
        if lastAccountId == 0 {
            store.clearSyncState() // 游标/队列属于全新安装，防御性重置
            _ = await syncNow()
        } else if lastAccountId == member.id {
            _ = await syncNow()
        } else {
            pendingSwitchAccount.send(member)
            await fetchPendingSwitchCloudSummary() // 弹窗展示「云端有 N 本书」
        }
    }

    /// 取新账号云端概览；失败保持 nil（弹窗按「未知」处理，清空需二次确认）。
    private func fetchPendingSwitchCloudSummary() async {
        let summary: SyncCloudSummary?
        do {
            let stats = try await api.stats()
            summary = SyncCloudSummary(liveBooks: stats.liveBooks, liveRecords: stats.liveRecords)
        } catch {
            summary = nil
        }
        pendingSwitchCloudSummary.send(summary)
    }

    /// 首次同步（无游标）：本地全部行（含墓碑）标记待推，走 LWW 静默合并。
    private func ensureInitialUploadMarked() async throws {
        if store.cursor() != nil { return }
        store.addPendingBooks(try await repository.books().map(\.guid) + repository.tombstonedBooks().map(\.guid))
        store.addPendingRecords(try await repository.allRecords().map(\.guid) + repository.tombstonedRecords().map(\.guid))
    }

    /// 治愈历史手尾（票 09 初版曾把本地引用写成相对 /static/ 路径）：每轮同步把本地相对
    /// 引用改写为完整 URL。仅修本地展示，updatedAt 虽推进但封面内容与云端一致（推送时
    /// 剥回相对路径），不会引起数据冲突。
    private func healRelativeCoverReferences() async throws {
        for book in try await repository.books() {
            guard let path = book.coverImagePath, path.hasPrefix("/static/") else { continue }
            var updated = book
            updated.coverImagePath = Self.trimTrailingSlash(apiBaseURL) + path
            try await repository.updateBook(updated)
        }
    }

    /// 封面自愈（票 09）：每轮同步把「本地路径且文件就在本机」的封面行重新标记待推——
    /// 上传换服务端引用后以新 updatedAt 覆盖云端旧行，他端拉取即得可用 URL；
    /// 换引用后不再满足条件，不会反复推。文件不在本机的行跳过（多半是另一台设备的路径）。
    private func markLocalCoversPending() async throws {
        var guids: [String] = []
        for book in try await repository.books() {
            guard let path = book.coverImagePath,
                  !path.hasPrefix("http"),
                  !path.hasPrefix("/static/"),
                  try await repository.coverImageExists(path: path)
            else { continue }
            guids.append(book.guid)
        }
        store.addPendingBooks(guids)
    }

    /// 推送待推变更：接收与被拒（服务端较新）均出队——被拒的由随后的 pull 拉回服务端版本修正。
    private func pushPending() async throws {
        let bookGuids = store.pendingBookGuids()
        let recordGuids = store.pendingRecordGuids()
        if bookGuids.isEmpty && recordGuids.isEmpty { return }

        // 本地 bookId → 书籍 guid 的映射（含墓碑书；记录的 bookGuid 外键由此解析）
        var bookGuidById: [Int64: String] = [:]
        for book in try await repository.books() { bookGuidById[book.id] = book.guid }
        for book in try await repository.tombstonedBooks() { bookGuidById[book.id] = book.guid }

        var books: [SyncBookChange] = []
        var vanishedBooks: Set<String> = []
        for guid in bookGuids {
            guard let row = try await repository.bookByGuid(guid: guid) else {
                vanishedBooks.insert(guid) // 行已不存在（理论不发生：删除走墓碑）→ 出队丢弃
                continue
            }
            let prepared = try await uploadLocalCoverIfNeeded(row)
            var change = SyncBookChange.from(prepared)
            change.coverImagePath = toServerCoverReference(prepared.coverImagePath)
            books.append(change)
        }

        var records: [SyncRecordChange] = []
        var vanishedRecords: Set<String> = []
        for guid in recordGuids {
            guard let record = try await repository.recordByGuid(guid: guid) else {
                vanishedRecords.insert(guid)
                continue
            }
            guard let bookGuid = bookGuidById[record.bookId] else {
                vanishedRecords.insert(guid)
                continue
            }
            records.append(SyncRecordChange.from(record, bookGuid: bookGuid))
        }
        vanishedBooks.forEach { store.removePendingBook($0) }
        vanishedRecords.forEach { store.removePendingRecord($0) }
        if books.isEmpty && records.isEmpty { return }

        let response = try await api.push(SyncPushRequest(books: books, records: records))
        for result in response.results ?? [] {
            if result.entity == "book" {
                store.removePendingBook(result.guid)
            } else {
                store.removePendingRecord(result.guid)
            }
        }
        // 注意：不采纳 push 返回的游标。push 游标是服务端高水位，直接采纳会跳过
        // 其他设备此前写入而本机尚未拉取的行；拉取只按本机已应用的游标推进。
    }

    /// 本地封面推送前上传（票 09）：本地文件 → 服务端引用。
    /// 本地行引用写**完整 URL**（直接加载），推送与云端存**相对路径**（/static/…，
    /// 他端拉取时再改写为完整 URL）；删除本地原文件（只保留最新一份）。
    /// 已是服务端路径/URL 的跳过；上传失败向上抛，整轮同步静默重试。
    private func uploadLocalCoverIfNeeded(_ book: Book) async throws -> Book {
        guard let path = book.coverImagePath else { return book }
        if path.hasPrefix("http://") || path.hasPrefix("https://") || path.hasPrefix("/static/") {
            return book
        }
        // 文件不在本机：不清引用、按原样推（多半是另一台设备的路径，留待那台设备自愈）
        guard let bytes = try await repository.readCoverImage(path: path) else { return book }
        let ext = (path as NSString).pathExtension
        let uploaded = try await api.uploadCover(bytes: bytes, fileExtension: ext.isEmpty ? "jpg" : ext)
        let fullURL = Self.trimTrailingSlash(apiBaseURL) + uploaded
        var updated = book
        updated.coverImagePath = fullURL
        // 内层仓库更新引用（推进 updatedAt，本行本就在待推中）；删除本地原文件
        try await repository.updateBook(updated)
        try? await repository.deleteCoverFile(path: path)
        return (try await repository.bookByGuid(guid: book.guid)) ?? updated
    }

    /// 推送用的封面引用：本服务的完整 URL 剥回相对路径（云端统一存 /static/…）。
    private func toServerCoverReference(_ path: String?) -> String? {
        guard let path else { return nil }
        let base = Self.trimTrailingSlash(apiBaseURL)
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    /// 分页拉取远端变更：**逐页应用**，书与记录都当场落库。
    ///
    /// ⚠️ 游标只在**本轮全部页与全部待落库记录都处理成功后**推进一次（不许在分页循环里落盘）：
    /// 分页中途任一页失败会抛错并由 `performSync` 静默吞掉，若先前已推进游标，
    /// 那几页已下发的记录就再也拉不回来了。游标不推进时重拉同一批是安全的：
    /// applyRemote* 幂等（本地不旧就跳过、墓碑不落行）。
    ///
    /// 记录的书可能还没到本地（书在后续页，或书那一行本轮没拉下来）：
    /// 这类记录进持久化的待落库队列（`SyncStore.addPendingPullRecords`），
    /// 每轮同步开头先重试。整库拉完仍无法落库的才判定为孤儿（其书在云端不存在）、
    /// 记日志丢弃——服务端 push 已从源头拦截孤儿记录，此处只兜存量坏数据。
    ///
    /// 封面（票 09）：服务端引用改写为完整 URL；远端墓碑或封面被替换时级联删除本地旧封面文件。
    private func pullAll() async throws {
        var cursor = store.cursor()
        var lastCursor = cursor
        var buffered: [String: SyncRecordChange] = [:]
        // 上一轮遗留的待落库记录：保持原相对路径（本轮拉到同一本后会覆盖为完整 URL）
        for record in store.pendingPullRecords() { buffered[record.guid] = record }

        while true {
            let response = try await api.pull(cursor: cursor)
            for change in response.books ?? [] {
                try await applyRemoteBookChange(change)
            }
            for record in response.records ?? [] { buffered[record.guid] = record }
            let applied = try await drainBufferedRecords(&buffered)
            store.removePendingPullRecords(applied)
            store.addPendingPullRecords(Array(buffered.values))
            lastCursor = response.cursor
            guard response.hasMore == true else { break }
            cursor = response.cursor
        }

        // 整库已拉完，仍未映射到本地书的记录：其书在云端不存在（游标语义保证不会漏页）
        if !buffered.isEmpty {
            for change in buffered.values {
                Self.logger.warning("丢弃孤儿阅读记录：guid=\(change.guid, privacy: .public) 挂靠的书 \(change.bookGuid, privacy: .public) 在云端不存在")
            }
            Self.logger.warning("本轮同步丢弃 \(buffered.count) 条孤儿阅读记录（其书在云端不存在）")
            store.removePendingPullRecords(Array(buffered.keys))
        }
        if let lastCursor {
            store.saveCursor(lastCursor)
        }
    }

    /// 尝试把缓冲里能映射到本地书的记录落库，返回已落库记录的 guid（用于清理持久化队列）。
    /// 仍未能落库的留在缓冲里（其书尚未就位）。
    private func drainBufferedRecords(_ buffered: inout [String: SyncRecordChange]) async throws -> [String] {
        var applied: [String] = []
        for change in Array(buffered.values) {
            guard let book = try await repository.bookByGuid(guid: change.bookGuid) else { continue }
            guard let record = change.toDomain(bookId: book.id) else {
                // 日期缺失/非法：无法落库，按不可用数据丢弃（镜像 Android 的解析失败处理）
                Self.logger.warning("丢弃无法解析的远端记录：guid=\(change.guid, privacy: .public)")
                buffered.removeValue(forKey: change.guid)
                applied.append(change.guid)
                continue
            }
            if try await repository.applyRemoteRecord(record) {
                store.removePendingRecord(change.guid)
            }
            applied.append(change.guid)
            buffered.removeValue(forKey: change.guid)
        }
        return applied
    }

    /// 应用一条远端书籍变更；封面由服务端引用改写为完整 URL，被替换/墓碑时删本地旧文件。
    private func applyRemoteBookChange(_ change: SyncBookChange) async throws {
        let localBefore = try await repository.bookByGuid(guid: change.guid)
        var domain = change.toDomain()
        if let cover = domain.coverImagePath, cover.hasPrefix("/static/") {
            domain.coverImagePath = Self.trimTrailingSlash(apiBaseURL) + cover
        }
        if try await repository.applyRemoteBook(domain) {
            store.removePendingBook(change.guid)
            let oldCover = localBefore?.coverImagePath
            let coverReplaced = domain.coverImagePath != oldCover || domain.deletedAt != nil
            if coverReplaced, let oldCover, !oldCover.hasPrefix("http") {
                try? await repository.deleteCoverFile(path: oldCover)
            }
        }
    }

    private static func trimTrailingSlash(_ url: String) -> String {
        url.hasSuffix("/") ? String(url.dropLast()) : url
    }
}
