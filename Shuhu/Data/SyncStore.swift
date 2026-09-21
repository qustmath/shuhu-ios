import Foundation

/// 同步状态持久化：游标、最近同步信息、待推送队列（本地变更的 guid 集合）。
/// 队列显式记录而非靠时间戳推断：写操作入队、推送成功出队，断网重启均不丢（data-sync 票 07）。
/// 与 Android `SyncStore` 对应（DataStore → UserDefaults；均为非敏感状态）。
public struct SyncStore: Sendable {

    private enum Keys {
        static let cursor = "sync.cursor"
        static let lastSyncAt = "sync.last_sync_at"
        static let lastSyncAccountId = "sync.last_sync_account_id"
        static let pendingBooks = "sync.pending_books"
        static let pendingRecords = "sync.pending_records"
        /// 已拉到、但本地还没有其所属书籍的远端记录（JSON），下次同步重试落库。
        static let pendingPullRecords = "sync.pending_pull_records"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func cursor() -> String? {
        defaults.string(forKey: Keys.cursor)
    }

    public func saveCursor(_ cursor: String) {
        defaults.set(cursor, forKey: Keys.cursor)
    }

    public func lastSyncAccountId() -> Int64 {
        defaults.object(forKey: Keys.lastSyncAccountId) as? Int64 ?? 0
    }

    public func lastSyncAt() -> Int64 {
        defaults.object(forKey: Keys.lastSyncAt) as? Int64 ?? 0
    }

    /// 清空游标与待推队列：换账号时旧账号的同步状态不可复用（票 08）。
    public func clearSyncState() {
        defaults.removeObject(forKey: Keys.cursor)
        defaults.removeObject(forKey: Keys.pendingBooks)
        defaults.removeObject(forKey: Keys.pendingRecords)
        defaults.removeObject(forKey: Keys.pendingPullRecords)
    }

    public func saveLastSync(accountId: Int64, atMillis: Int64) {
        defaults.set(atMillis, forKey: Keys.lastSyncAt)
        defaults.set(accountId, forKey: Keys.lastSyncAccountId)
    }

    public func pendingBookGuids() -> Set<String> {
        defaults.stringArray(forKey: Keys.pendingBooks).map(Set.init) ?? []
    }

    public func pendingRecordGuids() -> Set<String> {
        defaults.stringArray(forKey: Keys.pendingRecords).map(Set.init) ?? []
    }

    public func addPendingBooks(_ guids: some Collection<String>) {
        guard !guids.isEmpty else { return }
        defaults.set(Array(pendingBookGuids().union(guids)).sorted(), forKey: Keys.pendingBooks)
    }

    public func addPendingRecords(_ guids: some Collection<String>) {
        guard !guids.isEmpty else { return }
        defaults.set(Array(pendingRecordGuids().union(guids)).sorted(), forKey: Keys.pendingRecords)
    }

    public func removePendingBook(_ guid: String) {
        defaults.set(Array(pendingBookGuids().subtracting([guid])).sorted(), forKey: Keys.pendingBooks)
    }

    public func removePendingRecord(_ guid: String) {
        defaults.set(Array(pendingRecordGuids().subtracting([guid])).sorted(), forKey: Keys.pendingRecords)
    }

    // ---- 未落库的远端记录（其书还没到本地）----
    // 持久化保存，任何一轮同步开头都先重试——与「游标只在整轮成功后推进」配合，
    // 分页中途失败与时序错位都不会丢记录。

    public func pendingPullRecords() -> [SyncRecordChange] {
        guard let raw = defaults.string(forKey: Keys.pendingPullRecords),
              let data = raw.data(using: .utf8)
        else { return [] }
        return (try? JSONDecoder().decode([SyncRecordChange].self, from: data)) ?? []
    }

    /// 整批合并写入（每页一次，避免逐条 read-modify-write）。
    public func addPendingPullRecords(_ records: some Collection<SyncRecordChange>) {
        guard !records.isEmpty else { return }
        var merged = Dictionary(pendingPullRecords().map { ($0.guid, $0) }, uniquingKeysWith: { _, new in new })
        for record in records { merged[record.guid] = record }
        writePendingPullRecords(Array(merged.values))
    }

    /// 整批移除已落库的（每页一次）。
    public func removePendingPullRecords(_ guids: some Collection<String>) {
        guard !guids.isEmpty else { return }
        let removing = Set(guids)
        writePendingPullRecords(pendingPullRecords().filter { !removing.contains($0.guid) })
    }

    private func writePendingPullRecords(_ records: [SyncRecordChange]) {
        guard !records.isEmpty else {
            defaults.removeObject(forKey: Keys.pendingPullRecords)
            return
        }
        guard let data = try? JSONEncoder().encode(records),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(raw, forKey: Keys.pendingPullRecords)
    }
}
