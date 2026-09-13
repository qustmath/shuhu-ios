import Foundation

/// 仓库操作错误。
public enum LibraryRepositoryError: Error, Sendable {
    /// 目标书籍不存在（如已被删除）。
    case bookNotFound
}

/// 本地书库仓库协议。命名与语义对齐 Android 端 `LibraryRepository`（ADR-0001：双端原生、同一份 spec）。
///
/// 全部写入走「仓库维护 guid / updatedAt / 墓碑」的约定（同步就绪，ADR-0007）：
/// - 新建行由仓库生成 UUID `guid` 与毫秒 `updatedAt`；
/// - 删除一律软删（打墓碑），物理删除只发生在账号切换等明确场景；
/// - 查询默认过滤墓碑。
public protocol LibraryRepository: Sendable {

    // ---- 查询（未删行） ----

    /// 全部书籍，按 sortOrder 升序、id 升序。
    func books() async throws -> [Book]

    func book(id: Int64) async throws -> Book?

    /// 某本书的记录，date 倒序、同日按 createdAt 倒序（与 Android 一致）。
    func records(bookId: Int64) async throws -> [ReadingRecord]

    /// 全部书籍的全部记录（统计页汇总用），排序同 `records(bookId:)` 语义。
    func allRecords() async throws -> [ReadingRecord]

    /// 当前页 = 当前轮次最新一条记录的 pageReached；无记录返回 nil。
    func currentPage(bookId: Int64) async throws -> Int?

    // ---- 写入（仓库维护同步字段） ----

    /// 新增书籍：分配 sortOrder（现有最大值 + 1，新书排末尾）、生成 guid、记 updatedAt。
    func addBook(_ draft: NewBook) async throws -> Book

    /// 更新书籍（保留原 id/sortOrder/guid），刷新 updatedAt。
    func updateBook(_ book: Book) async throws

    /// 软删书籍：书与其全部未删记录一并打墓碑（同一事务）。
    func deleteBook(id: Int64) async throws

    /// 拖动排序：按给定顺序重写 sortOrder（同一事务，全部刷新 updatedAt）。
    func updateBookSortOrder(_ orderedIds: [Int64]) async throws

    /// 新增记录：生成 guid、记 updatedAt；自动归入该书当前轮次（currentRound）。
    func addRecord(_ draft: NewRecord) async throws -> ReadingRecord

    /// 更新记录，刷新 updatedAt。
    func updateRecord(_ record: ReadingRecord) async throws

    /// 软删单条记录。
    func deleteRecord(id: Int64) async throws

    // ---- 封面文件（Android `LibraryRepository` 同名契约）----

    /// 把封面图片字节存入仓库管理的沙盒存储，返回文件路径（存入 Book.coverImagePath）。
    func saveCoverImage(bytes: Data, fileExtension: String) async throws -> String

    /// 删除封面文件；路径为空或文件不存在时静默忽略。
    func deleteCoverFile(path: String?) async throws

    /// 封面文件是否仍然存在（用于界面优雅降级）。
    func coverImageExists(path: String?) async throws -> Bool

    /// 读取封面文件字节（同步上传用）；路径为空或文件不存在返回 nil。
    func readCoverImage(path: String?) async throws -> Data?

    // ---- 墓碑读取（同步上行用；本地 UI 不可见） ----

    func tombstonedBooks() async throws -> [Book]

    func tombstonedRecords() async throws -> [ReadingRecord]

    // ---- 同步引擎专用（data-sync 票 07；UI 不应调用）----

    /// 按 guid 读取书籍（含墓碑行；同步推送与冲突判定用）。
    func bookByGuid(guid: String) async throws -> Book?

    /// 按 guid 读取记录（含墓碑行）。
    func recordByGuid(guid: String) async throws -> ReadingRecord?

    /// 按 id 读取未删记录（装饰器登记变更用）。
    func record(id: Int64) async throws -> ReadingRecord?

    /// 原样应用远端书籍状态（LWW 下行）：guid/updatedAt/sortOrder/deletedAt 一律按远端值，
    /// 不走用户写入语义（不重新分配 guid、不推进 updatedAt）。
    /// 本地不存在且远端为墓碑 → 忽略；本地较新或相同 → 忽略；
    /// 远端 coverImagePath 为 nil 时保留本地封面路径（封面一致性在票 09 完善）。
    /// - Returns: true = 远端被实际应用（插入或覆盖）；false = 被忽略
    @discardableResult
    func applyRemoteBook(_ book: Book) async throws -> Bool

    /// 原样应用远端记录状态，语义与返回值同 `applyRemoteBook`。
    @discardableResult
    func applyRemoteRecord(_ record: ReadingRecord) async throws -> Bool

    /// 清空全部本地书籍与阅读记录（含墓碑，物理删除，封面文件一并清理）。
    /// 专用于换账号「清空本地，以云端为准」：**不打墓碑**——墓碑会被推上云端误删云端数据，
    /// 故必须绕开用户删除语义直连物理清空。仅同步引擎调用，UI 不得使用。
    func clearAllLibrary() async throws
}

/// 添加书籍的表单草稿（无 id 与同步字段）。
public struct NewBook: Sendable {
    public var title: String
    public var author: String
    public var totalPages: Int
    public var startDate: CalendarDay?
    public var endDate: CalendarDay?
    /// 封面文件路径；添加模式下先经 saveCoverImage 落盘再随书入库。
    public var coverImagePath: String?

    public init(
        title: String,
        author: String,
        totalPages: Int,
        startDate: CalendarDay? = nil,
        endDate: CalendarDay? = nil,
        coverImagePath: String? = nil,
    ) {
        self.title = title
        self.author = author
        self.totalPages = totalPages
        self.startDate = startDate
        self.endDate = endDate
        self.coverImagePath = coverImagePath
    }
}

/// 添加阅读记录的表单草稿。
public struct NewRecord: Sendable {
    public var bookId: Int64
    public var date: CalendarDay
    public var pageReached: Int
    public var remark: String?

    public init(bookId: Int64, date: CalendarDay, pageReached: Int, remark: String? = nil) {
        self.bookId = bookId
        self.date = date
        self.pageReached = pageReached
        self.remark = remark
    }
}
