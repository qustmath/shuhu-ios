import XCTest
@testable import Shuhu

/// GRDB 仓库的写语义测试：逐条对齐 Android `RoomLibraryRepositoryTest` 的关键行为
/// （guid/updatedAt 仓库维护、软删级联、sortOrder 末尾追加、墓碑查询）。
final class GRDBLibraryRepositoryTests: XCTestCase {

    private var repository: GRDBLibraryRepository!

    override func setUpWithError() throws {
        repository = GRDBLibraryRepository(writer: try Database.open()) // 内存库
    }

    private func draft(title: String = "我是个怪圈", totalPages: Int = 434) -> NewBook {
        NewBook(title: title, author: "侯世达", totalPages: totalPages)
    }

    // ---- 新增 ----

    func testAddBook_assignsSortOrderAndGuidAndUpdatedAt() async throws {
        let first = try await repository.addBook(draft())
        let second = try await repository.addBook(draft(title: "秘密"))

        XCTAssertEqual(first.sortOrder, 1, "首本书 sortOrder = 1")
        XCTAssertEqual(second.sortOrder, 2, "新书排末尾（max + 1）")
        XCTAssertFalse(first.guid.isEmpty)
        XCTAssertFalse(second.guid.isEmpty)
        XCTAssertNotEqual(first.guid, second.guid, "guid 为 UUID，各不相同")
        XCTAssertGreaterThan(first.updatedAt, 0, "updatedAt 由仓库维护（毫秒）")
        XCTAssertNil(first.deletedAt)
        XCTAssertEqual(first.currentRound, 1, "轮次 1 起算")
    }

    func testAddBook_listOrderedBySortOrder() async throws {
        _ = try await repository.addBook(draft(title: "A"))
        _ = try await repository.addBook(draft(title: "B"))
        let books = try await repository.books()
        XCTAssertEqual(books.map(\.title), ["A", "B"], "按 sortOrder 升序")
    }

    // ---- 更新 ----

    func testUpdateBook_refreshesUpdatedAt_keepsGuid() async throws {
        let inserted = try await repository.addBook(draft())
        var book = inserted
        book.title = "改名了"
        try await Task.sleep(nanoseconds: 2_000_000) // 保证毫秒时间戳可比
        try await repository.updateBook(book)

        let reloaded = try await repository.book(id: inserted.id)
        XCTAssertEqual(reloaded?.title, "改名了")
        XCTAssertEqual(reloaded?.guid, inserted.guid, "guid 终身不变")
        XCTAssertGreaterThanOrEqual(reloaded!.updatedAt, inserted.updatedAt)
    }

    // ---- 记录与当前页 ----

    func testAddRecord_andCurrentPage_followsNewestRecord() async throws {
        let book = try await repository.addBook(draft())
        let today = CalendarDay(year: 2026, month: 9, day: 12)
        _ = try await repository.addRecord(NewRecord(bookId: book.id, date: today, pageReached: 65))
        _ = try await repository.addRecord(NewRecord(bookId: book.id, date: today, pageReached: 80, remark: "加油"))

        let records = try await repository.records(bookId: book.id)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.pageReached, 80, "同日多条按录入时间倒序")
        XCTAssertEqual(records.first?.remark, "加油")

        let currentPage = try await repository.currentPage(bookId: book.id)
        XCTAssertEqual(currentPage, 80, "当前页 = 最新记录的累计页码")
    }

    func testCurrentPage_isNilWithoutRecords() async throws {
        let book = try await repository.addBook(draft())
        let currentPage = try await repository.currentPage(bookId: book.id)
        XCTAssertNil(currentPage)
    }

    // ---- 软删与墓碑 ----

    func testDeleteBook_tombstonesBookAndItsRecords() async throws {
        let book = try await repository.addBook(draft())
        _ = try await repository.addRecord(NewRecord(bookId: book.id, date: CalendarDay(year: 2026, month: 9, day: 12), pageReached: 10))

        try await repository.deleteBook(id: book.id)

        let books = try await repository.books()
        XCTAssertTrue(books.isEmpty, "列表不再展示已删书")
        let records = try await repository.records(bookId: book.id)
        XCTAssertTrue(records.isEmpty, "记录随书一并不可见")

        let tombstones = try await repository.tombstonedBooks()
        XCTAssertEqual(tombstones.count, 1, "墓碑保留（同步传播用）")
        XCTAssertNotNil(tombstones.first?.deletedAt)
        XCTAssertGreaterThan(tombstones.first!.updatedAt, book.updatedAt, "墓碑行刷新 updatedAt")
        let recordTombstones = try await repository.tombstonedRecords()
        XCTAssertEqual(recordTombstones.count, 1, "记录墓碑级联")
    }

    func testDeleteRecord_tombstonesOnlyThatRecord() async throws {
        let book = try await repository.addBook(draft())
        let kept = try await repository.addRecord(NewRecord(bookId: book.id, date: CalendarDay(year: 2026, month: 9, day: 11), pageReached: 10))
        let removed = try await repository.addRecord(NewRecord(bookId: book.id, date: CalendarDay(year: 2026, month: 9, day: 12), pageReached: 20))

        try await repository.deleteRecord(id: removed.id)

        let records = try await repository.records(bookId: book.id)
        XCTAssertEqual(records.map(\.id), [kept.id], "仅剩未删记录")
        let tombstones = try await repository.tombstonedRecords()
        XCTAssertEqual(tombstones.map(\.id), [removed.id])
    }

    // ---- 排序 ----

    func testUpdateBookSortOrder_rewritesOrderInTransaction() async throws {
        let a = try await repository.addBook(draft(title: "A"))
        let b = try await repository.addBook(draft(title: "B"))
        try await repository.updateBookSortOrder([b.id, a.id])

        let books = try await repository.books()
        XCTAssertEqual(books.map(\.title), ["B", "A"], "拖动后的顺序持久化")
    }

    // ---- 迁移幂等 ----

    func testMigration_isIdempotent_onExistingDatabase() async throws {
        // 迁移器对已迁移的库重复执行应为 no-op（GRDB 按 migration id 记账）
        let path = NSTemporaryDirectory() + "shuhu-idempotent-\(UUID().uuidString).sqlite"
        _ = try Database.open(path: path)
        _ = try Database.open(path: path) // 第二次打开不报错
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        try? FileManager.default.removeItem(atPath: path)
    }
}
