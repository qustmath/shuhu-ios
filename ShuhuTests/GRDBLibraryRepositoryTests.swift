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
        // 同毫秒写入时两值相等：语义是「单调不减」（LWW 比较依据），不强制严格递增
        XCTAssertGreaterThanOrEqual(tombstones.first!.updatedAt, book.updatedAt, "墓碑行刷新 updatedAt")
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

    // ---- 归轮（轮次：新记录归入书籍当前轮次）----

    func testAddRecord_assignsBookCurrentRound() async throws {
        let inserted = try await repository.addBook(draft())
        let day = CalendarDay(year: 2026, month: 9, day: 12)
        let round1 = try await repository.addRecord(NewRecord(bookId: inserted.id, date: day, pageReached: 100))
        XCTAssertEqual(round1.round, 1, "currentRound=1 时新记录归第 1 轮")

        var book = inserted
        book.currentRound = 2
        try await Task.sleep(nanoseconds: 2_000_000)
        try await repository.updateBook(book)

        let round2 = try await repository.addRecord(NewRecord(bookId: book.id, date: day, pageReached: 10))
        XCTAssertEqual(round2.round, 2, "新记录自动归入书籍当前轮次")
        let currentPage = try await repository.currentPage(bookId: book.id)
        XCTAssertEqual(currentPage, 10, "当前页只看当前轮次，不受第 1 轮历史影响")
    }

    func testUpdateBook_roundTripsCurrentRound_forReread() async throws {
        let inserted = try await repository.addBook(draft())
        var book = inserted
        book.currentRound = 2
        try await Task.sleep(nanoseconds: 2_000_000)
        try await repository.updateBook(book)

        let reloaded = try await repository.book(id: inserted.id)
        XCTAssertEqual(reloaded?.currentRound, 2, "重读写回的 currentRound 持久化")
    }

    // ---- 封面文件 ----

    private func repositoryWithTempCovers() throws -> (GRDBLibraryRepository, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shuhu-covers-\(UUID().uuidString)", isDirectory: true)
        let repo = GRDBLibraryRepository(writer: try Database.open(), coversDirectory: dir)
        return (repo, dir)
    }

    func testCoverImage_roundTripsThroughBookAndFiles() async throws {
        let (repo, dir) = try repositoryWithTempCovers()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])

        let path = try await repo.saveCoverImage(bytes: bytes, fileExtension: "png")
        XCTAssertTrue(path.hasSuffix(".png"), "文件按 UUID + 扩展名落盘")
        let exists = try await repo.coverImageExists(path: path)
        XCTAssertTrue(exists)
        let readBack = try await repo.readCoverImage(path: path)
        XCTAssertEqual(readBack, bytes, "字节可原样读回（同步上传用）")

        let book = try await repo.addBook(
            NewBook(title: "有封面的书", author: "", totalPages: 100, coverImagePath: path),
        )
        let reloaded = try await repo.book(id: book.id)
        XCTAssertEqual(reloaded?.coverImagePath, path, "封面路径随书入库并可读回")

        try await repo.deleteCoverFile(path: path)
        let existsAfterDelete = try await repo.coverImageExists(path: path)
        XCTAssertFalse(existsAfterDelete)
    }

    func testDeleteCoverFile_isSilentForNullOrMissing() async throws {
        let (repo, dir) = try repositoryWithTempCovers()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await repo.deleteCoverFile(path: nil)
        try await repo.deleteCoverFile(path: dir.appendingPathComponent("不存在的文件.jpg").path)
    }

    func testDeleteBook_cascadesCoverFile() async throws {
        let (repo, dir) = try repositoryWithTempCovers()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = try await repo.saveCoverImage(bytes: Data([0xFF, 0xD8]), fileExtension: "jpg")
        let book = try await repo.addBook(
            NewBook(title: "书", author: "", totalPages: 10, coverImagePath: path),
        )

        try await repo.deleteBook(id: book.id)

        let exists = try await repo.coverImageExists(path: path)
        XCTAssertFalse(exists, "删书级联删除封面文件，避免垃圾文件堆积")
    }

    // ---- 同步引擎专用（guid 读取 / 远端 LWW 应用 / 物理清空）----

    func testByGuid_readersIncludeTombstones() async throws {
        let book = try await repository.addBook(draft())
        let day = CalendarDay(year: 2026, month: 9, day: 12)
        let record = try await repository.addRecord(NewRecord(bookId: book.id, date: day, pageReached: 10))

        let bookByGuid = try await repository.bookByGuid(guid: book.guid)
        XCTAssertEqual(bookByGuid?.id, book.id)

        try await repository.deleteRecord(id: record.id)
        let tombstoned = try await repository.recordByGuid(guid: record.guid)
        XCTAssertNotNil(tombstoned?.deletedAt, "guid 读取含墓碑行（同步推送用）")
    }

    func testApplyRemoteBook_insertNew_appliesNewer_ignoresOlderAndMissingTombstone() async throws {
        // 本地无行 + 远端墓碑 → 忽略（无需落一行墓碑）
        let remoteTombstone = Book(title: "云删除", author: "", totalPages: 10, guid: "g-tomb", updatedAt: 100, deletedAt: 100)
        let appliedTombstone = try await repository.applyRemoteBook(remoteTombstone)
        XCTAssertFalse(appliedTombstone)

        // 本地无行 + 远端活行 → 插入，guid/updatedAt/sortOrder 原样
        let remote = Book(
            title: "云端书", author: "作者", totalPages: 300,
            currentRound: 2, coverImagePath: nil, sortOrder: 5,
            guid: "g-1", updatedAt: 2_000,
        )
        let applied = try await repository.applyRemoteBook(remote)
        XCTAssertTrue(applied)
        let local = try await repository.bookByGuid(guid: "g-1")
        XCTAssertEqual(local?.title, "云端书")
        XCTAssertEqual(local?.updatedAt, 2_000, "updatedAt 原样应用（LWW 依据）")
        XCTAssertEqual(local?.currentRound, 2)
        XCTAssertEqual(local?.sortOrder, 5)

        // 本地较新 → 忽略
        let older = Book(title: "旧改名", author: "", totalPages: 300, guid: "g-1", updatedAt: 1_000)
        let appliedOlder = try await repository.applyRemoteBook(older)
        XCTAssertFalse(appliedOlder)
        let unchanged = try await repository.bookByGuid(guid: "g-1")
        XCTAssertEqual(unchanged?.title, "云端书")

        // 本地较旧 → 覆盖整行；远端无封面时保留本地封面路径
        var withCover = local!
        withCover.coverImagePath = "/covers/local.jpg"
        try await repository.updateBook(withCover) // updatedAt 推进到「现在」
        let localAfterUpdate = try await repository.bookByGuid(guid: "g-1")!
        let newerRemote = Book(title: "云改名", author: "", totalPages: 300, guid: "g-1", updatedAt: localAfterUpdate.updatedAt + 60_000)
        let appliedNewer = try await repository.applyRemoteBook(newerRemote)
        XCTAssertTrue(appliedNewer)
        let merged = try await repository.bookByGuid(guid: "g-1")
        XCTAssertEqual(merged?.title, "云改名")
        XCTAssertEqual(merged?.coverImagePath, "/covers/local.jpg", "远端无封面 → 保留本地封面路径（票 09 前妥协）")
    }

    func testApplyRemoteRecord_insertNewAndIgnoreOlder() async throws {
        let book = try await repository.addBook(draft())
        let remote = ReadingRecord(bookId: book.id, date: CalendarDay(year: 2026, month: 9, day: 12), pageReached: 42, round: 1, guid: "r-1", updatedAt: 2_000)
        let applied = try await repository.applyRemoteRecord(remote)
        XCTAssertTrue(applied)
        let local = try await repository.recordByGuid(guid: "r-1")
        XCTAssertEqual(local?.pageReached, 42)

        let older = ReadingRecord(bookId: book.id, date: CalendarDay(year: 2026, month: 9, day: 12), pageReached: 10, round: 1, guid: "r-1", updatedAt: 1_000)
        let appliedOlder = try await repository.applyRemoteRecord(older)
        XCTAssertFalse(appliedOlder)
        let unchanged = try await repository.recordByGuid(guid: "r-1")
        XCTAssertEqual(unchanged?.pageReached, 42, "本地较新 → 忽略远端旧行")
    }

    func testClearAllLibrary_physicallyRemovesEverything() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shufu-clear-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = GRDBLibraryRepository(writer: try Database.open(), coversDirectory: dir)

        let coverPath = try await repo.saveCoverImage(bytes: Data([0x89]), fileExtension: "jpg")
        let book = try await repo.addBook(
            NewBook(title: "书", author: "", totalPages: 10, coverImagePath: coverPath),
        )
        let record = try await repo.addRecord(NewRecord(bookId: book.id, date: CalendarDay(year: 2026, month: 9, day: 12), pageReached: 1))
        try await repo.deleteRecord(id: record.id) // 制造墓碑行

        try await repo.clearAllLibrary()

        let books = try await repo.books()
        XCTAssertTrue(books.isEmpty)
        let bookTombstones = try await repo.tombstonedBooks()
        XCTAssertTrue(bookTombstones.isEmpty, "物理清空含墓碑（不打新墓碑）")
        let recordTombstones = try await repo.tombstonedRecords()
        XCTAssertTrue(recordTombstones.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: coverPath), "封面文件一并清理")
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
