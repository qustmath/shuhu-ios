import XCTest
@testable import Shuhu

/// 阅读计划（Reading Plan）与每日目标（Daily Target）的纯函数测试。
/// 测试用例逐条镜像 Android 端 `ReadingPlanTest`（双端同一份 spec，ADR-0001）。
final class ReadingPlanTests: XCTestCase {

    private let d = { (month: Int, day: Int) in CalendarDay(year: 2026, month: month, day: day) }

    private func book(totalPages: Int = 294, start: CalendarDay? = nil, end: CalendarDay? = nil) -> Book {
        Book(id: 1, title: "书", author: "", totalPages: totalPages, startDate: start, endDate: end)
    }

    // ---- 含首尾的计划天数 ----

    func testPlanDurationDays_countsInclusiveOfBothEnds() {
        XCTAssertEqual(ReadingPlan.planDurationDays(start: d(8, 31), end: d(9, 4)), 5)
        XCTAssertEqual(ReadingPlan.planDurationDays(start: d(9, 4), end: d(9, 4)), 1, "开始=结束也算 1 天")
        XCTAssertEqual(ReadingPlan.planDurationDays(start: d(8, 1), end: d(8, 31)), 31)
    }

    func testRemainingDays_countsTodayThroughEndDate() {
        XCTAssertEqual(ReadingPlan.remainingDays(today: d(9, 1), endDate: d(9, 4)), 4, "含今天与结束日")
        XCTAssertEqual(ReadingPlan.remainingDays(today: d(9, 4), endDate: d(9, 4)), 1, "结束日当天剩 1 天")
        XCTAssertEqual(ReadingPlan.remainingDays(today: d(9, 5), endDate: d(9, 4)), 0, "刚过结束日为 0（内部值，UI 不展示）")
        XCTAssertEqual(ReadingPlan.remainingDays(today: d(9, 7), endDate: d(9, 4)), -2, "可为负（仅内部使用）")
    }

    // ---- 有计划 / 自由阅读 ----

    func testHasPlan_requiresBothDates() {
        XCTAssertTrue(ReadingPlan.hasPlan(book(start: d(8, 31), end: d(9, 4))))
        XCTAssertFalse(ReadingPlan.hasPlan(book(start: nil, end: nil)), "自由阅读无计划")
        XCTAssertFalse(ReadingPlan.hasPlan(book(start: d(8, 31), end: nil)), "只填开始日期不算计划")
        XCTAssertFalse(ReadingPlan.hasPlan(book(start: nil, end: d(9, 4))))
    }

    // ---- 每日目标 ----

    func testDailyTarget_roundsUp() {
        // spec 参考例子：293 页剩余 / 5 天 = 58.6 → 59
        XCTAssertEqual(
            ReadingPlan.dailyTarget(
                totalPages: 294,
                currentPage: 1,
                startDate: d(8, 31),
                endDate: d(9, 4),
                today: d(8, 31),
            ),
            59,
            "8/31 起、9/4 止、今天 8/31：剩余 5 天，⌈293÷5⌉ = 59",
        )
    }

    func testDailyTarget_exactDivisionNeedsNoRounding() {
        XCTAssertEqual(
            ReadingPlan.dailyTarget(
                totalPages: 300,
                currentPage: 0,
                startDate: d(9, 1),
                endDate: d(9, 5),
                today: d(9, 1),
            ),
            60,
            "300 ÷ 5 = 60，整除即 60",
        )
    }

    func testDailyTarget_onEndDate_usesSingleRemainingDay() {
        XCTAssertEqual(
            ReadingPlan.dailyTarget(
                totalPages: 100,
                currentPage: 0,
                startDate: d(9, 1),
                endDate: d(9, 4),
                today: d(9, 4),
            ),
            100,
            "结束日当天（今天 ≤ 结束日期）仍显示目标，剩余 1 天 → 全部读完",
        )
    }

    func testDailyTarget_disappearsAfterEndDate() {
        // ADR-0002：到期后没有目标、没有倒计时、没有任何逾期提示
        XCTAssertNil(
            ReadingPlan.dailyTarget(
                totalPages: 294,
                currentPage: 1,
                startDate: d(8, 31),
                endDate: d(9, 4),
                today: d(9, 5),
            ),
            "计划到期次日：目标消失",
        )
    }

    func testDailyTarget_isNullWithoutPlan() {
        let today = d(9, 1)
        XCTAssertNil(ReadingPlan.dailyTarget(totalPages: 294, currentPage: 1, startDate: nil, endDate: nil, today: today), "自由阅读：无目标")
        XCTAssertNil(
            ReadingPlan.dailyTarget(totalPages: 294, currentPage: 1, startDate: d(8, 31), endDate: nil, today: today),
            "只填开始日期：不构成计划，无目标",
        )
        XCTAssertNil(
            ReadingPlan.dailyTarget(totalPages: 294, currentPage: 1, startDate: nil, endDate: d(9, 4), today: today),
            "只填结束日期：不构成计划，无目标",
        )
    }

    func testDailyTarget_neverNegative_evenIfCurrentPageBeyondTotal() {
        XCTAssertEqual(
            ReadingPlan.dailyTarget(
                totalPages: 100,
                currentPage: 120,
                startDate: d(8, 31),
                endDate: d(9, 4),
                today: d(9, 1),
            ),
            0,
            "当前页超过总页数（读完了）：目标下限为 0",
        )
    }

    // ---- 日期校验 ----

    func testValidateBookDates_acceptsBothOrNeither() {
        XCTAssertNil(validateBookDates(start: nil, end: nil))
        XCTAssertNil(validateBookDates(start: d(8, 31), end: d(9, 4)))
        XCTAssertNil(validateBookDates(start: d(9, 4), end: d(9, 4)), "开始=结束合法")
    }

    func testValidateBookDates_rejectsSingleDate() {
        XCTAssertEqual(validateBookDates(start: d(8, 31), end: nil), .singleDateOnly)
        XCTAssertEqual(validateBookDates(start: nil, end: d(9, 4)), .singleDateOnly)
    }

    func testValidateBookDates_rejectsEndBeforeStart() {
        XCTAssertEqual(validateBookDates(start: d(9, 4), end: d(8, 31)), .endBeforeStart)
    }

    // ---- 展示文案 ----

    func testDateFormats_matchReferenceScreenshots() {
        XCTAssertEqual(DateFormats.planDateWithDuration(days: 5, date: d(9, 4)), "(5天) 09月04日")
        XCTAssertEqual(DateFormats.daysLeft(5), "剩 5 天")
        XCTAssertEqual(DateFormats.dailyTargetLabel(59), "今天目标 59 页")
    }
}
