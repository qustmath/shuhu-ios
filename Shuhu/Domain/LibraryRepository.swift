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

    /// 新增记录：生成 guid、记 updatedAt。
    func addRecord(_ draft: NewRecord) async throws -> ReadingRecord

    /// 更新记录，刷新 updatedAt。
    func updateRecord(_ record: ReadingRecord) async throws

    /// 软删单条记录。
    func deleteRecord(id: Int64) async throws

    // ---- 墓碑读取（同步上行用；本地 UI 不可见） ----

    func tombstonedBooks() async throws -> [Book]

    func tombstonedRecords() async throws -> [ReadingRecord]
}

/// 添加书籍的表单草稿（无 id 与同步字段）。
public struct NewBook: Sendable {
    public var title: String
    public var author: String
    public var totalPages: Int
    public var startDate: CalendarDay?
    public var endDate: CalendarDay?

    public init(title: String, author: String, totalPages: Int, startDate: CalendarDay? = nil, endDate: CalendarDay? = nil) {
        self.title = title
        self.author = author
        self.totalPages = totalPages
        self.startDate = startDate
        self.endDate = endDate
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
