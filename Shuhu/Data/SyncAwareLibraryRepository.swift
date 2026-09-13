import Foundation

/// LibraryRepository 装饰器（data-sync 票 07）：读路径全部透传；
/// 写路径先委托内层实现，再把受影响 guid 登记到同步引擎的待推队列并触发防抖推送。
/// 应用层持有的仓库应为本装饰器；引擎内部读取用未装饰的内层实现（避免远端应用被误标为本地变更）。
public final class SyncAwareLibraryRepository: LibraryRepository {

    private let inner: LibraryRepository
    private let engine: SyncEngine

    public init(inner: LibraryRepository, engine: SyncEngine) {
        self.inner = inner
        self.engine = engine
    }

    // ---- 查询：透传 ----

    public func books() async throws -> [Book] {
        try await inner.books()
    }

    public func book(id: Int64) async throws -> Book? {
        try await inner.book(id: id)
    }

    public func records(bookId: Int64) async throws -> [ReadingRecord] {
        try await inner.records(bookId: bookId)
    }

    public func allRecords() async throws -> [ReadingRecord] {
        try await inner.allRecords()
    }

    public func currentPage(bookId: Int64) async throws -> Int? {
        try await inner.currentPage(bookId: bookId)
    }

    // ---- 写入：登记待推 ----

    public func addBook(_ draft: NewBook) async throws -> Book {
        let book = try await inner.addBook(draft)
        engine.markBooksChanged([book.guid])
        return book
    }

    public func updateBook(_ book: Book) async throws {
        try await inner.updateBook(book)
        engine.markBooksChanged([book.guid])
    }

    public func updateBookSortOrder(_ orderedIds: [Int64]) async throws {
        var guids: Set<String> = []
        for id in orderedIds {
            if let book = try await inner.book(id: id) {
                guids.insert(book.guid)
            }
        }
        try await inner.updateBookSortOrder(orderedIds)
        engine.markBooksChanged(guids)
    }

    public func deleteBook(id: Int64) async throws {
        let bookGuid = try await inner.book(id: id)?.guid
        let recordGuids = Set(try await inner.records(bookId: id).map(\.guid))
        try await inner.deleteBook(id: id)
        engine.markRecordsChanged(recordGuids)
        if let bookGuid {
            engine.markBooksChanged([bookGuid])
        }
    }

    public func addRecord(_ draft: NewRecord) async throws -> ReadingRecord {
        let record = try await inner.addRecord(draft)
        engine.markRecordsChanged([record.guid])
        return record
    }

    public func updateRecord(_ record: ReadingRecord) async throws {
        try await inner.updateRecord(record)
        engine.markRecordsChanged([record.guid])
    }

    public func deleteRecord(id: Int64) async throws {
        let guid = try await inner.record(id: id)?.guid
        try await inner.deleteRecord(id: id)
        if let guid {
            engine.markRecordsChanged([guid])
        }
    }

    // ---- 封面 / 墓碑 / 同步专用：透传 ----

    public func saveCoverImage(bytes: Data, fileExtension: String) async throws -> String {
        try await inner.saveCoverImage(bytes: bytes, fileExtension: fileExtension)
    }

    public func deleteCoverFile(path: String?) async throws {
        try await inner.deleteCoverFile(path: path)
    }

    public func coverImageExists(path: String?) async throws -> Bool {
        try await inner.coverImageExists(path: path)
    }

    public func readCoverImage(path: String?) async throws -> Data? {
        try await inner.readCoverImage(path: path)
    }

    public func tombstonedBooks() async throws -> [Book] {
        try await inner.tombstonedBooks()
    }

    public func tombstonedRecords() async throws -> [ReadingRecord] {
        try await inner.tombstonedRecords()
    }

    public func bookByGuid(guid: String) async throws -> Book? {
        try await inner.bookByGuid(guid: guid)
    }

    public func recordByGuid(guid: String) async throws -> ReadingRecord? {
        try await inner.recordByGuid(guid: guid)
    }

    public func record(id: Int64) async throws -> ReadingRecord? {
        try await inner.record(id: id)
    }

    public func applyRemoteBook(_ book: Book) async throws -> Bool {
        try await inner.applyRemoteBook(book)
    }

    public func applyRemoteRecord(_ record: ReadingRecord) async throws -> Bool {
        try await inner.applyRemoteRecord(record)
    }

    public func clearAllLibrary() async throws {
        try await inner.clearAllLibrary()
    }
}
