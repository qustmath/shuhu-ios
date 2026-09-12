/// 一条阅读记录：记录某日「读到了第几页」（累计页码，不是当天读的页数）。
/// 可编辑、可删除、可补记（date 可以往前改）；createdAt 用于同日多条记录的排序。
///
/// 与 Android 端 `com.shufou.domain.ReadingRecord` 逐字段对应。
public struct ReadingRecord: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var bookId: Int64
    /// 用户视角的阅读日期（可补记为过去）。
    public var date: CalendarDay
    /// 录入时间戳（毫秒），用于同日记录按录入时间倒序。
    public var createdAt: Int64
    /// 读到的累计页码。
    public var pageReached: Int
    /// 所属轮次（1 起算）。
    public var round: Int
    /// 备注（Remark）：随记录保存的想法/摘录，可空多行文本。
    public var remark: String?
    /// 全局稳定 ID（同步用）：本地新建时由仓库生成 UUID。
    public var guid: String
    /// 最后修改时间（毫秒）；仓库写入时维护，是同步 LWW 的比较依据。
    public var updatedAt: Int64
    /// 墓碑：非 nil 表示已删除（待同步传播）；查询默认过滤，对用户不可见。
    public var deletedAt: Int64?

    public init(
        id: Int64 = 0,
        bookId: Int64,
        date: CalendarDay,
        createdAt: Int64 = 0,
        pageReached: Int,
        round: Int = 1,
        remark: String? = nil,
        guid: String = "",
        updatedAt: Int64 = 0,
        deletedAt: Int64? = nil,
    ) {
        self.id = id
        self.bookId = bookId
        self.date = date
        self.createdAt = createdAt
        self.pageReached = pageReached
        self.round = round
        self.remark = remark
        self.guid = guid
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
