/// 阅读计划（Reading Plan）相关的派生状态与校验。全部为纯函数。
///
/// ⚠️ ADR-0002：计划到期后（今天 > 结束日期），每日目标与倒计时**完全消失**，
/// 本文件刻意不提供任何"逾期/落后"类计算结果。
///
/// 与 Android 端 `com.shufou.domain.ReadingPlan` 逐函数对应，测试用例一一镜像。
public enum ReadingPlan {

    /// 有阅读计划 = 两个日期都设置。
    public static func hasPlan(_ book: Book) -> Bool {
        book.startDate != nil && book.endDate != nil
    }

    /// 计划总天数，含首尾：08-31 → 09-04 = 5 天。
    public static func planDurationDays(start: CalendarDay, end: CalendarDay) -> Int {
        start.days(until: end) + 1
    }

    /// 剩余天数，含今天与结束日：今天 09-01、结束 09-04 → 4 天；
    /// 可为 0 或负（已过期的内部判断依据，仅内部使用，UI 不展示）。
    public static func remainingDays(today: CalendarDay, endDate: CalendarDay) -> Int {
        today.days(until: endDate) + 1
    }

    /// 今天目标 = ⌈(总页数 − 当前页) ÷ 剩余天数⌉。
    /// 仅当存在阅读计划且今天 ≤ 结束日期时给出；其余情况（自由阅读 / 已到期）返回 nil，UI 不显示任何目标。
    /// 剩余页数按 0 下限处理（读完的书目标为 0，不产生负数）。
    public static func dailyTarget(
        totalPages: Int,
        currentPage: Int,
        startDate: CalendarDay?,
        endDate: CalendarDay?,
        today: CalendarDay,
    ) -> Int? {
        guard let start = startDate, let end = endDate else { return nil }
        guard today <= end else { return nil }
        let remainingPages = max(totalPages - currentPage, 0)
        let days = remainingDays(today: today, endDate: end)
        return Int(ceil(Double(remainingPages) / Double(days)))
    }
}

/// 书籍日期校验错误。
public enum BookDateError: Equatable, Sendable {
    /// 只填了一个日期：计划需要开始与结束日期同时存在。
    case singleDateOnly

    /// 结束日期早于开始日期。
    case endBeforeStart
}

/// 校验表单中的起止日期：两个都填或都不填；都填时结束日期不得早于开始日期。
public func validateBookDates(start: CalendarDay?, end: CalendarDay?) -> BookDateError? {
    switch (start, end) {
    case (nil, nil):
        return nil
    case (let s?, let e?):
        return e < s ? .endBeforeStart : nil
    default:
        return .singleDateOnly
    }
}

/// 计划相关展示文案（与 Android 端 `DateFormats` 逐条对应，参照同一批设计稿）。
public enum PlanLabels {

    /// 计划结束日标签：`(5天) 09月04日`。
    public static func planDateWithDuration(durationDays: Int, end: CalendarDay) -> String {
        String(format: "(%d天) %02d月%02d日", durationDays, end.month, end.day)
    }

    /// 剩余天数标签：`剩 5 天`。
    public static func daysLeft(_ days: Int) -> String {
        "剩 \(days) 天"
    }

    /// 每日目标标签：`今天目标 59 页`。
    public static func dailyTargetLabel(_ target: Int) -> String {
        "今天目标 \(target) 页"
    }
}
