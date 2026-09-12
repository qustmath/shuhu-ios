import XCTest
@testable import Shuhu

/// `CalendarDay` 的跨天计算与文本形态：与 Android `java.time.LocalDate` 对齐。
final class CalendarDayTests: XCTestCase {

    func testIsoRoundTrip() {
        let day = CalendarDay(year: 2026, month: 9, day: 4)
        XCTAssertEqual(day.iso, "2026-09-04")
        XCTAssertEqual(CalendarDay(iso: "2026-09-04"), day)
    }

    func testIsoRejectsMalformed() {
        // 与 Android LocalDate.parse 同样严格：月日必须两位
        XCTAssertNil(CalendarDay(iso: "2026-9-4"))
        XCTAssertNil(CalendarDay(iso: "26-09-04"))
        XCTAssertNil(CalendarDay(iso: "2026/09/04"))
        XCTAssertNil(CalendarDay(iso: "2026-13-01"))
        XCTAssertNil(CalendarDay(iso: "2026-09-00"))
        XCTAssertNil(CalendarDay(iso: "2026-02-31"), "不存在的日历日（Foundation 会把它归到 03-03）")
        XCTAssertNil(CalendarDay(iso: ""))
    }

    func testDaysUntil_acrossMonthBoundary() {
        // 08-31 → 09-04 = 4 天（ChronoUnit.DAYS.between(from, to) 方向语义）
        XCTAssertEqual(CalendarDay(year: 2026, month: 8, day: 31).days(until: CalendarDay(year: 2026, month: 9, day: 4)), 4)
        XCTAssertEqual(CalendarDay(year: 2026, month: 9, day: 4).days(until: CalendarDay(year: 2026, month: 8, day: 31)), -4)
        XCTAssertEqual(CalendarDay(year: 2026, month: 9, day: 4).days(until: CalendarDay(year: 2026, month: 9, day: 4)), 0)
    }

    func testDaysUntil_acrossYearBoundary() {
        let from = CalendarDay(year: 2026, month: 12, day: 31)
        let to = CalendarDay(year: 2027, month: 1, day: 2)
        XCTAssertEqual(from.days(until: to), 2)
    }

    func testAdding_daysCrossesMonthAndYear() {
        XCTAssertEqual(CalendarDay(year: 2026, month: 8, day: 31).adding(days: 4), CalendarDay(year: 2026, month: 9, day: 4))
        XCTAssertEqual(CalendarDay(year: 2026, month: 12, day: 30).adding(days: 5), CalendarDay(year: 2027, month: 1, day: 4))
        XCTAssertEqual(CalendarDay(year: 2026, month: 9, day: 4).adding(days: -5), CalendarDay(year: 2026, month: 8, day: 30))
    }

    func testComparable_isChronological() {
        XCTAssertTrue(CalendarDay(year: 2026, month: 9, day: 4) < CalendarDay(year: 2026, month: 9, day: 5))
        XCTAssertTrue(CalendarDay(year: 2026, month: 8, day: 31) < CalendarDay(year: 2026, month: 9, day: 1))
        XCTAssertTrue(CalendarDay(year: 2025, month: 12, day: 31) < CalendarDay(year: 2026, month: 1, day: 1))
    }

    func testToday_usesGivenTimeZone() {
        // 同一时刻：UTC 是 09-12 23:00 时，东八区是 09-13 07:00
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let instant = utc.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 23))!
        XCTAssertEqual(
            CalendarDay.today(now: instant, timeZone: TimeZone(secondsFromGMT: 0)!),
            CalendarDay(year: 2026, month: 9, day: 12),
        )
        XCTAssertEqual(
            CalendarDay.today(now: instant, timeZone: TimeZone(identifier: "Asia/Shanghai")!),
            CalendarDay(year: 2026, month: 9, day: 13),
        )
    }

    func testCodable_usesIsoString() throws {
        let day = CalendarDay(year: 2026, month: 9, day: 4)
        let data = try JSONEncoder().encode(day)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"2026-09-04\"")
        XCTAssertEqual(try JSONDecoder().decode(CalendarDay.self, from: data), day)
    }
}
