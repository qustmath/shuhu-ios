import Foundation
import XCTest
@testable import Shuhu

/// 日期文案格式测试：镜像 Android `DateFormats` 全部函数。
final class DateFormatsTests: XCTestCase {

    private func d(_ month: Int, _ day: Int, year: Int = 2026) -> CalendarDay {
        CalendarDay(year: year, month: month, day: day)
    }

    func testShortDate() {
        XCTAssertEqual(DateFormats.shortDate(d(9, 4)), "9月4日")
        XCTAssertEqual(DateFormats.shortDate(d(12, 31)), "12月31日")
    }

    func testPlanDate_paddedTwoDigits() {
        XCTAssertEqual(DateFormats.planDate(d(9, 4)), "09月04日")
        XCTAssertEqual(DateFormats.planDate(d(8, 31)), "08月31日")
    }

    func testRecordDateTime_dateFromRecord_timeFromCreatedAt() {
        // 2026-09-04 22:00 本地时间 ≈ createdAt 毫秒；断言日期部分精确、时刻部分格式合法
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 22, minute: 0))!
        let millis = Int64(date.timeIntervalSince1970 * 1000)
        let text = DateFormats.recordDateTime(date: d(9, 4), createdAt: millis)
        XCTAssertTrue(text.hasPrefix("9月4日 "), "日期来自记录本身：\(text)")
        XCTAssertEqual(text.count, "9月4日 ".count + 5, "时刻 HH:mm：\(text)")
        XCTAssertTrue(text.hasSuffix("22:00"), "本地时区 22:00：\(text)")
    }

    func testTodayLine_withChineseWeekday() {
        XCTAssertEqual(DateFormats.todayLine(d(9, 19)), "9月19日 · 星期六")
        XCTAssertEqual(DateFormats.todayLine(d(9, 20)), "9月20日 · 星期日")
        XCTAssertEqual(DateFormats.todayLine(d(1, 1)), "1月1日 · 星期四")
    }

    func testOverdueLine() {
        XCTAssertEqual(DateFormats.overdueLine(daysOver: 2, pagesLeft: 89), "已超计划 2 天 · 还差 89 页")
    }

    func testPlanDateWithDuration() {
        XCTAssertEqual(DateFormats.planDateWithDuration(days: 5, date: d(9, 4)), "(5天) 09月04日")
    }
}
