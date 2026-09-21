import Foundation

/// 同步状态持久化：游标、最近同步信息、待推送队列（本地变更的 guid 集合）。
/// 队列显式记录而非靠时间戳推断：写操作入队、推送成功出队，断网重启均不丢（data-sync 票 07）。
/// 与 Android `SyncStore` 对应（DataStore → UserDefaults；均为非敏感状态）。
///
/// ⚠️ 所有读写都在同一把锁内完成：待推队列与待落库队列都是
/// **读 → 改 → 写**（UserDefaults 无事务），而调用方遍布多个线程
/// （防抖推送任务、手动同步、视图层写路径）。不加锁时两次并发入队会互相覆盖，
/// 丢掉的那个 guid 意味着该本地变更永远不上行（Android 侧 DataStore 的 edit 本身是原子的）。
public final class SyncStore: @unchecked Sendable {

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
    private let lock = NSRecursiveLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func cursor() -> String? {
        locked { defaults.string(forKey: Keys.cursor) }
    }

    public func saveCursor(_ cursor: String) {
        locked { defaults.set(cursor, forKey: Keys.cursor) }
    }

    public func lastSyncAccountId() -> Int64 {
        locked { defaults.object(forKey: Keys.lastSyncAccountId) as? Int64 ?? 0 }
    }

    public func lastSyncAt() -> Int64 {
        locked { defaults.object(forKey: Keys.lastSyncAt) as? Int64 ?? 0 }
    }

    /// 清空游标与两个队列：换账号时旧账号的同步状态不可复用（票 08）。
    public func clearSyncState() {
        locked {
            defaults.removeObject(forKey: Keys.cursor)
            defaults.removeObject(forKey: Keys.pendingBooks)
            defaults.removeObject(forKey: Keys.pendingRecords)
            defaults.removeObject(forKey: Keys.pendingPullRecords)
        }
    }

    public func saveLastSync(accountId: Int64, atMillis: Int64) {
        locked {
            defaults.set(atMillis, forKey: Keys.lastSyncAt)
            defaults.set(accountId, forKey: Keys.lastSyncAccountId)
        }
    }

    public func pendingBookGuids() -> Set<String> {
        locked { pendingBookGuidsLocked() }
    }

    public func pendingRecordGuids() -> Set<String> {
        locked { pendingRecordGuidsLocked() }
    }

    public func addPendingBooks(_ guids: some Collection<String>) {
        guard !guids.isEmpty else { return }
        locked {
            defaults.set(Array(pendingBookGuidsLocked().union(guids)).sorted(), forKey: Keys.pendingBooks)
        }
    }

    public func addPendingRecords(_ guids: some Collection<String>) {
        guard !guids.isEmpty else { return }
        locked {
            defaults.set(Array(pendingRecordGuidsLocked().union(guids)).sorted(), forKey: Keys.pendingRecords)
        }
    }

    public func removePendingBook(_ guid: String) {
        locked {
            defaults.set(Array(pendingBookGuidsLocked().subtracting([guid])).sorted(), forKey: Keys.pendingBooks)
        }
    }

    public func removePendingRecord(_ guid: String) {
        locked {
            defaults.set(Array(pendingRecordGuidsLocked().subtracting([guid])).sorted(), forKey: Keys.pendingRecords)
        }
    }

    // ---- 未落库的远端记录（其书还没到本地）----
    // 持久化保存，任何一轮同步开头都先重试——与「游标只在整轮成功后推进」配合，
    // 分页中途失败与时序错位都不会丢记录。

    public func pendingPullRecords() -> [SyncRecordChange] {
        locked { pendingPullRecordsLocked() }
    }

    /// 整批合并写入（每页一次，避免逐条 read-modify-write）。
    public func addPendingPullRecords(_ records: some Collection<SyncRecordChange>) {
        guard !records.isEmpty else { return }
        locked {
            var merged = Dictionary(pendingPullRecordsLocked().map { ($0.guid, $0) }, uniquingKeysWith: { _, new in new })
            for record in records { merged[record.guid] = record }
            writePendingPullRecordsLocked(Array(merged.values))
        }
    }

    /// 整批移除已落库的（每页一次）。
    public func removePendingPullRecords(_ guids: some Collection<String>) {
        guard !guids.isEmpty else { return }
        let removing = Set(guids)
        locked {
            writePendingPullRecordsLocked(pendingPullRecordsLocked().filter { !removing.contains($0.guid) })
        }
    }

    // ---- 以下 *Locked 版本假定调用方已持锁（避免自身重入与中途释放）----

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func pendingBookGuidsLocked() -> Set<String> {
        defaults.stringArray(forKey: Keys.pendingBooks).map(Set.init) ?? []
    }

    private func pendingRecordGuidsLocked() -> Set<String> {
        defaults.stringArray(forKey: Keys.pendingRecords).map(Set.init) ?? []
    }

    private func pendingPullRecordsLocked() -> [SyncRecordChange] {
        guard let raw = defaults.string(forKey: Keys.pendingPullRecords),
              let data = raw.data(using: .utf8)
        else { return [] }
        return (try? JSONDecoder().decode([SyncRecordChange].self, from: data)) ?? []
    }

    private func writePendingPullRecordsLocked(_ records: [SyncRecordChange]) {
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
