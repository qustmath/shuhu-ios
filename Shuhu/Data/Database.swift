import GRDB

/// SQLite 数据库装配：表结构以 **Android Room v8 的最终形态**直接建表（ADR-0007 同步就绪），
/// 两端同构后同步契约（shared/sync-api-v1.yaml）按 guid 对齐即可。
/// iOS 已发版，因此后续结构补齐走增量迁移（v2 起），不得改动已应用的 v1。
public enum Database {

    /// 迁移器：v1 = Android v8 同构（含 guid 唯一索引、记录外键级联删除）；v2 起为增量补齐。
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "book") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("author", .text).notNull()
                t.column("total_pages", .integer).notNull()
                t.column("start_date", .text)          // yyyy-MM-dd，nil = 未设
                t.column("end_date", .text)
                t.column("current_round", .integer).notNull().defaults(to: 1)
                t.column("cover_image_path", .text)
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("guid", .text).notNull().defaults(to: "")
                t.column("updated_at", .integer).notNull().defaults(to: 0)
                t.column("deleted_at", .integer)
            }
            try db.create(
                index: "index_book_guid",
                on: "book",
                columns: ["guid"],
                unique: true,
            )

            try db.create(table: "reading_record") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("book_id", .integer)
                    .notNull()
                    .references("book", onDelete: .cascade)
                t.column("date", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.column("page_reached", .integer).notNull()
                t.column("round", .integer).notNull().defaults(to: 1)
                t.column("remark", .text)
                t.column("guid", .text).notNull().defaults(to: "")
                t.column("updated_at", .integer).notNull().defaults(to: 0)
                t.column("deleted_at", .integer)
            }
            try db.create(
                index: "index_reading_record_guid",
                on: "reading_record",
                columns: ["guid"],
                unique: true,
            )
        }

        // v2：补 reading_record(book_id) 索引。v1 漏建，导致按书查记录走全表扫描
        // （Android Room 侧一直有这个索引，见 ReadingRecordEntity 的 indices）。
        migrator.registerMigration("v2") { db in
            try db.create(
                index: "index_reading_record_book_id",
                on: "reading_record",
                columns: ["book_id"],
            )
        }

        return migrator
    }

    /// 打开（或创建）数据库并应用迁移。`path` 为 nil 时用内存库（测试/预览）。
    public static func open(path: String? = nil) throws -> any DatabaseWriter {
        let writer: any DatabaseWriter
        if let path {
            writer = try DatabasePool(path: path)
        } else {
            writer = try DatabaseQueue()
        }
        try migrator.migrate(writer)
        return writer
    }
}
