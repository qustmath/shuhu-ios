import Foundation
import GRDB

/// `LibraryRepository` 的 GRDB 实现：写语义逐条对齐 Android `RoomLibraryRepository`
/// （guid 生成、updatedAt 毫秒、软删级联、sortOrder 末尾追加、拖动排序事务、封面文件存取）。
/// 封面图片以文件形式存于应用沙盒（coversDirectory），数据库只存路径。
public final class GRDBLibraryRepository: LibraryRepository, Sendable {

    private let writer: any DatabaseWriter
    private let coversDirectory: URL

    public init(writer: any DatabaseWriter, coversDirectory: URL? = nil) {
        self.writer = writer
        let dir: URL
        if let coversDirectory {
            dir = coversDirectory
        } else {
            // 默认与数据库同住 Application Support
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            dir = base.appendingPathComponent("covers", isDirectory: true)
        }
        self.coversDirectory = dir
    }

    /// 应用入口用：文档目录下的 shuhu.sqlite。
    public static func makeDefault() throws -> GRDBLibraryRepository {
        let dir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let covers = dir.appendingPathComponent("covers", isDirectory: true)
        try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        return GRDBLibraryRepository(
            writer: try Database.open(path: dir.appendingPathComponent("shuhu.sqlite").path),
            coversDirectory: covers,
        )
    }

    // ---- 查询 ----

    public func books() async throws -> [Book] {
        try await writer.read { db in
            try BookRow
                .filter(sql: "deleted_at IS NULL")
                .order(Column("sort_order"), Column("id"))
                .fetchAll(db)
                .map(\.toDomain)
        }
    }

    public func book(id: Int64) async throws -> Book? {
        try await writer.read { db in
            try BookRow.filter(Column("id") == id).fetchOne(db)?.toDomain
        }
    }

    public func records(bookId: Int64) async throws -> [ReadingRecord] {
        try await writer.read { db in
            try RecordRow
                .filter(Column("book_id") == bookId)
                .filter(sql: "deleted_at IS NULL")
                .order(Column("date").desc, Column("created_at").desc, Column("id").desc)
                .fetchAll(db)
                .map(\.toDomain)
        }
    }

    public func currentPage(bookId: Int64) async throws -> Int? {
        try await writer.read { db in
            let book = try BookRow.filter(Column("id") == bookId).fetchOne(db)
            guard let round = book?.current_round else { return nil }
            return try RecordRow
                .filter(Column("book_id") == bookId)
                .filter(sql: "deleted_at IS NULL")
                .filter(Column("round") == round)
                .order(Column("date").desc, Column("created_at").desc, Column("id").desc)
                .fetchOne(db)?
                .page_reached
        }
    }

    // ---- 写入 ----

    public func addBook(_ draft: NewBook) async throws -> Book {
        let now = currentTimeMillis()
        return try await writer.write { db in
            // 与 Android BookDao.maxSortOrder 同语义：全表取最大（含墓碑行）
            let maxOrder = try Int64.fetchOne(db, sql: "SELECT MAX(sort_order) FROM book") ?? 0
            var row = BookRow(draft: draft)
            row.sort_order = Int(maxOrder) + 1 // 新书排末尾
            row.guid = UUID().uuidString
            row.updated_at = now
            try row.insert(db)
            row.id = db.lastInsertedRowID
            return row.toDomain
        }
    }

    public func updateBook(_ book: Book) async throws {
        let now = currentTimeMillis()
        try await writer.write { db in
            var row = BookRow(book: book)
            row.updated_at = now
            try row.update(db)
        }
    }

    public func deleteBook(id: Int64) async throws {
        let now = currentTimeMillis()
        let coverPath = try await writer.read { db in
            try BookRow.filter(Column("id") == id).fetchOne(db)?.cover_image_path
        }
        _ = try await writer.write { db in
            // 记录一并打墓碑（与 Android 一致：只墓碑未删行），再墓碑书本身
            try db.execute(
                sql: "UPDATE reading_record SET deleted_at = ?, updated_at = ? WHERE book_id = ? AND deleted_at IS NULL",
                arguments: [now, now, id],
            )
            try db.execute(
                sql: "UPDATE book SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL",
                arguments: [now, now, id],
            )
        }
        deleteCoverFileSync(coverPath)
    }

    public func updateBookSortOrder(_ orderedIds: [Int64]) async throws {
        let now = currentTimeMillis()
        _ = try await writer.write { db in
            for (index, id) in orderedIds.enumerated() {
                try db.execute(
                    sql: "UPDATE book SET sort_order = ?, updated_at = ? WHERE id = ?",
                    arguments: [index, now, id],
                )
            }
        }
    }

    public func addRecord(_ draft: NewRecord) async throws -> ReadingRecord {
        let now = currentTimeMillis()
        return try await writer.write { db in
            // 新记录归入书籍当前轮次（与 Android 票据 06「添加记录自动归入 book.currentRound」一致）
            guard let bookRow = try BookRow.filter(Column("id") == draft.bookId).fetchOne(db) else {
                throw LibraryRepositoryError.bookNotFound
            }
            var row = RecordRow(draft: draft)
            row.round = bookRow.current_round
            row.guid = UUID().uuidString
            row.updated_at = now
            try row.insert(db)
            row.id = db.lastInsertedRowID
            return row.toDomain
        }
    }

    public func updateRecord(_ record: ReadingRecord) async throws {
        let now = currentTimeMillis()
        try await writer.write { db in
            var row = RecordRow(record: record)
            row.updated_at = now
            try row.update(db)
        }
    }

    public func deleteRecord(id: Int64) async throws {
        let now = currentTimeMillis()
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE reading_record SET deleted_at = ?, updated_at = ? WHERE id = ?",
                arguments: [now, now, id],
            )
        }
    }

    // ---- 封面文件 ----

    public func saveCoverImage(bytes: Data, fileExtension: String) async throws -> String {
        let ext = fileExtension.isEmpty ? "jpg" : fileExtension
        try FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
        let file = coversDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try bytes.write(to: file, options: .atomic)
        return file.path
    }

    public func deleteCoverFile(path: String?) async throws {
        deleteCoverFileSync(path)
    }

    public func coverImageExists(path: String?) async throws -> Bool {
        guard let path, !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    public func readCoverImage(path: String?) async throws -> Data? {
        guard let path, !path.isEmpty else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    /// 同步删除封面文件；路径为空或文件不存在时静默忽略（与 Android 语义一致）。
    private func deleteCoverFileSync(_ path: String?) {
        guard let path, !path.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    // ---- 墓碑 ----

    public func tombstonedBooks() async throws -> [Book] {
        try await writer.read { db in
            try BookRow.filter(sql: "deleted_at IS NOT NULL").fetchAll(db).map(\.toDomain)
        }
    }

    public func tombstonedRecords() async throws -> [ReadingRecord] {
        try await writer.read { db in
            try RecordRow.filter(sql: "deleted_at IS NOT NULL").fetchAll(db).map(\.toDomain)
        }
    }
}

private func currentTimeMillis() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

// ---- 行类型（数据库列 ↔ 领域模型）----
// id 用可选 Int64：插入时留空由 SQLite 自增分配，插入后经 lastInsertedRowID 回填。

private struct BookRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "book"

    var id: Int64?
    var title: String
    var author: String
    var total_pages: Int
    var start_date: String?
    var end_date: String?
    var current_round: Int
    var cover_image_path: String?
    var sort_order: Int
    var guid: String
    var updated_at: Int64
    var deleted_at: Int64?

    init(draft: NewBook) {
        id = nil
        title = draft.title
        author = draft.author
        total_pages = draft.totalPages
        start_date = draft.startDate?.iso
        end_date = draft.endDate?.iso
        current_round = 1
        cover_image_path = draft.coverImagePath
        sort_order = 0
        guid = ""
        updated_at = 0
        deleted_at = nil
    }

    init(book: Book) {
        id = book.id
        title = book.title
        author = book.author
        total_pages = book.totalPages
        start_date = book.startDate?.iso
        end_date = book.endDate?.iso
        current_round = book.currentRound
        cover_image_path = book.coverImagePath
        sort_order = book.sortOrder
        guid = book.guid
        updated_at = book.updatedAt
        deleted_at = book.deletedAt
    }

    var toDomain: Book {
        Book(
            id: id ?? 0,
            title: title,
            author: author,
            totalPages: total_pages,
            startDate: start_date.flatMap(CalendarDay.init(iso:)),
            endDate: end_date.flatMap(CalendarDay.init(iso:)),
            currentRound: current_round,
            coverImagePath: cover_image_path,
            sortOrder: sort_order,
            guid: guid,
            updatedAt: updated_at,
            deletedAt: deleted_at,
        )
    }
}

private struct RecordRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "reading_record"

    var id: Int64?
    var book_id: Int64
    var date: String
    var created_at: Int64
    var page_reached: Int
    var round: Int
    var remark: String?
    var guid: String
    var updated_at: Int64
    var deleted_at: Int64?

    init(draft: NewRecord) {
        id = nil
        book_id = draft.bookId
        date = draft.date.iso
        created_at = currentTimeMillis()
        page_reached = draft.pageReached
        round = 1
        remark = draft.remark
        guid = ""
        updated_at = 0
        deleted_at = nil
    }

    init(record: ReadingRecord) {
        id = record.id
        book_id = record.bookId
        date = record.date.iso
        created_at = record.createdAt
        page_reached = record.pageReached
        round = record.round
        remark = record.remark
        guid = record.guid
        updated_at = record.updatedAt
        deleted_at = record.deletedAt
    }

    var toDomain: ReadingRecord {
        ReadingRecord(
            id: id ?? 0,
            bookId: book_id,
            date: CalendarDay(iso: date)!,
            createdAt: created_at,
            pageReached: page_reached,
            round: round,
            remark: remark,
            guid: guid,
            updatedAt: updated_at,
            deletedAt: deleted_at,
        )
    }
}
