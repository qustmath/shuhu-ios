import XCTest
@testable import Shuhu

/// 同步状态持久化（游标、待推队列、待落库队列）。
///
/// 重点是**并发读改写不丢更新**：待推队列是「读 → union → 写」，UserDefaults 没有事务，
/// 而调用方遍布防抖推送任务、手动同步与视图层写路径。丢一个 guid 就意味着
/// 那条本地变更永远不会上行（Android 侧 DataStore 的 edit 本身是原子的）。
final class SyncStoreTests: XCTestCase {

    private func makeStore() -> SyncStore {
        SyncStore(defaults: UserDefaults(suiteName: "sync-store-tests-\(UUID().uuidString)")!)
    }

    private func record(_ guid: String) -> SyncRecordChange {
        SyncRecordChange(
            guid: guid, bookGuid: "b-1", date: "2026-09-09",
            createdAt: 1, pageReached: 10, round: 1, updatedAt: 1,
        )
    }

    func testConcurrentEnqueue_doesNotLoseGuids() {
        let store = makeStore()
        let count = 200

        DispatchQueue.concurrentPerform(iterations: count) { index in
            store.addPendingBooks(["b-\(index)"])
        }

        XCTAssertEqual(store.pendingBookGuids().count, count, "并发入队丢 guid 会让本地变更永不上行")
    }

    func testConcurrentEnqueueAndDequeue_keepsConsistency() {
        let store = makeStore()
        let count = 200
        store.addPendingRecords((0..<count).map { "r-\($0)" })

        DispatchQueue.concurrentPerform(iterations: count) { index in
            store.removePendingRecord("r-\(index)")
        }

        XCTAssertTrue(store.pendingRecordGuids().isEmpty, "并发出队后不得残留")
    }

    func testConcurrentPendingPullRecords_mergeWithoutLoss() {
        let store = makeStore()
        let count = 100

        DispatchQueue.concurrentPerform(iterations: count) { index in
            store.addPendingPullRecords([self.record("pull-\(index)")])
        }

        XCTAssertEqual(store.pendingPullRecords().count, count, "待落库队列并发合并不得丢记录")
    }

    func testPendingPullRecords_roundTripAndRemoval() {
        let store = makeStore()
        store.addPendingPullRecords([record("r-1"), record("r-2")])

        XCTAssertEqual(Set(store.pendingPullRecords().map(\.guid)), ["r-1", "r-2"])

        store.removePendingPullRecords(["r-1"])
        XCTAssertEqual(store.pendingPullRecords().map(\.guid), ["r-2"])
    }

    func testClearSyncState_wipesCursorAndEveryQueue() {
        let store = makeStore()
        store.saveCursor("20.3")
        store.addPendingBooks(["b-1"])
        store.addPendingRecords(["r-1"])
        store.addPendingPullRecords([record("r-2")])

        store.clearSyncState()

        XCTAssertNil(store.cursor(), "换账号后旧游标不可复用")
        XCTAssertTrue(store.pendingBookGuids().isEmpty)
        XCTAssertTrue(store.pendingRecordGuids().isEmpty)
        XCTAssertTrue(store.pendingPullRecords().isEmpty)
    }
}
