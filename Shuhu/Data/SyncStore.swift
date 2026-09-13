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
}
