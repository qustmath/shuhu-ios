import Foundation

/// 记录校验错误；消息由 UI 层结合具体数值格式化。
public enum RecordValidationError: Equatable, Sendable {
    /// 新增时页码未超过当前页；编辑时页码小于 1。
    case belowOrEqualCurrentPage
    /// 页码超过总页数。
    case aboveTotalPages
}

/// 领域规则（spec: Derived-state rules / Validation）。全部为纯函数，不依赖 UI 框架。
/// 与 Android 端 `com.shufou.domain.ReadingRules` 逐条对应（ADR-0001：同一份 spec 双端原生）。
public enum ReadingRules {

    /// 当前页 = 当前轮次中最新一条记录（按日期，再录入时间，再 id 兜底）的页码；无记录时为 0。
    ///
    /// id 兜底是必须的：同一天同一毫秒录入的两条记录若没有确定次序，
    /// 「最新一条」就取决于列表顺序，两端（乃至同一端的两次查询）会得出不同的当前页与已读完判定。
    public static func currentPage(records: [ReadingRecord], round: Int = 1) -> Int {
        records
            .filter { $0.round == round }
            .max { a, b in
                if a.date != b.date { return a.date < b.date }
                if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
                return a.id < b.id
            }?
            .pageReached ?? 0
    }

    /// 进度 = 当前页 / 总页数，结果限定在 0...1。
    public static func progressPercent(currentPage: Int, totalPages: Int) -> Double {
        guard totalPages > 0 else { return 0 }
        return min(max(Double(currentPage) / Double(totalPages), 0), 1)
    }

    /// 是否已读完：当前页达到总页数（读完的书归入主页「已读完」分区）。
    public static func isFinished(currentPage: Int, totalPages: Int) -> Bool {
        currentPage >= totalPages
    }

    /// 新增记录的页码校验：必须落在 (当前页, 总页数] 区间内。
    public static func validateNewRecord(
        pageReached: Int,
        currentPage: Int,
        totalPages: Int,
    ) -> RecordValidationError? {
        if pageReached <= currentPage { return .belowOrEqualCurrentPage }
        if pageReached > totalPages { return .aboveTotalPages }
        return nil
    }

    /// 编辑既有记录的页码校验：只要求落在 [1, 总页数]；允许改小（历史可能重排）。
    public static func validateEditRecord(
        pageReached: Int,
        totalPages: Int,
    ) -> RecordValidationError? {
        if pageReached < 1 { return .belowOrEqualCurrentPage }
        if pageReached > totalPages { return .aboveTotalPages }
        return nil
    }

    // ---- 轮次（Round）语义：对应 Android 票据 06 ----

    /// 某一轮次的全部记录（含备注），排序沿用仓库给的展示顺序。
    public static func recordsOfRound(records: [ReadingRecord], round: Int) -> [ReadingRecord] {
        records.filter { $0.round == round }
    }

    /// 当前页所属轮次 = 书籍的 currentRound；新增记录应归入该轮。
    public static func currentRoundOf(book: Book) -> Int {
        book.currentRound
    }

    /// 轮次数 = max(currentRound, 记录中出现的最大轮次, 1)。
    public static func roundCount(book: Book, records: [ReadingRecord]) -> Int {
        max(book.currentRound, records.map(\.round).max() ?? 0, 1)
    }

    /// 是否为多轮书：只有多轮书才显示「第 N 轮」标记，单轮书不出现轮次概念。
    public static func hasMultipleRounds(book: Book, records: [ReadingRecord]) -> Bool {
        roundCount(book: book, records: records) > 1
    }
}
