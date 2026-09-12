/// 一本书。可能带有阅读计划（可选起止日期），可能带封面。
/// 两个日期都设置时视为有阅读计划（Planned Reading），否则为自由阅读（Free Reading）。
/// `currentRound` 为当前所处轮次（1 起算）；「重读」会使其 +1，当前页随之归零，旧轮次记录全部保留。
///
/// 与 Android 端 `com.shufou.domain.Book` 逐字段对应（ADR-0001 双端原生、同一份 spec）。
public struct Book: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var title: String
    public var author: String
    public var totalPages: Int
    public var startDate: CalendarDay?
    public var endDate: CalendarDay?
    public var currentRound: Int
    /// 封面图片文件的存储路径（应用沙盒内）；nil = 无封面。
    public var coverImagePath: String?
    /// 列表展示顺序（拖动排序后持久化）；小者在前。
    public var sortOrder: Int
    /// 全局稳定 ID（同步用）：本地新建时由仓库生成 UUID，跨端关联一律用它（ADR-0007）。
    public var guid: String
    /// 最后修改时间（毫秒）；仓库写入时维护，是同步 LWW 的比较依据。
    public var updatedAt: Int64
    /// 墓碑：非 nil 表示已删除（待同步传播）；查询默认过滤，对用户不可见。
    public var deletedAt: Int64?

    public init(
        id: Int64 = 0,
        title: String,
        author: String,
        totalPages: Int,
        startDate: CalendarDay? = nil,
        endDate: CalendarDay? = nil,
        currentRound: Int = 1,
        coverImagePath: String? = nil,
        sortOrder: Int = 0,
        guid: String = "",
        updatedAt: Int64 = 0,
        deletedAt: Int64? = nil,
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.totalPages = totalPages
        self.startDate = startDate
        self.endDate = endDate
        self.currentRound = currentRound
        self.coverImagePath = coverImagePath
        self.sortOrder = sortOrder
        self.guid = guid
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
