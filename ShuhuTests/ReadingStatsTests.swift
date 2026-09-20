import XCTest
@testable import Shuhu

/// 统计纯函数测试：镜像 Android `ReadingStatsTest` 关键用例。
final class ReadingStatsTests: XCTestCase {

    private func record(
        bookId: Int64,
        page: Int,
        round: Int = 1,
        date: CalendarDay = CalendarDay(year: 2026, month: 9, day: 12),
        createdAt: Int64 = 0,
    ) -> ReadingRecord {
        ReadingRecord(bookId: bookId, date: date, createdAt: createdAt, pageReached: page, round: round)
    }

    // ---- 累计阅读页数：轮内差值求和 ----

    func testTotalPagesRead_sumsDeltasWithinEachRound_fromZero() {
        let records = [
            record(bookId: 1, page: 10),
            record(bookId: 1, page: 35),
            record(bookId: 1, page: 20, createdAt: 1), // 改小的修正：差值 −15（真实反映）
        ]
        // 按时间序 0→10→35→20：差值 10 + 25 − 15 = 20（并列 createdAt 的前后序不影响总和）
        XCTAssertEqual(ReadingStats.totalPagesRead(records: records), 20)
    }

    func testTotalPagesRead_countsEachBookAndRoundIndependently() {
        let records = [
            record(bookId: 1, page: 100, round: 1),
            record(bookId: 1, page: 30, round: 2), // 重读：第 2 轮从 0 重新起算
            record(bookId: 2, page: 50),
        ]
        XCTAssertEqual(ReadingStats.totalPagesRead(records: records), 180, "书1轮1=100 + 书1轮2=30 + 书2=50")
    }

    func testTotalPagesRead_ordersByDateBeforeCreatedAt() {
        // 录入顺序乱（补记）：按日期先后计算差值，与录入时间无关
        let records = [
            record(bookId: 1, page: 50, date: CalendarDay(year: 2026, month: 9, day: 13), createdAt: 1),
            record(bookId: 1, page: 20, date: CalendarDay(year: 2026, month: 9, day: 12), createdAt: 2),
        ]
        XCTAssertEqual(ReadingStats.totalPagesRead(records: records), 50, "先 12 日 0→20（+20），再 13 日 20→50（+30）")
    }

    func testTotalPagesRead_emptyIsZero() {
        XCTAssertEqual(ReadingStats.totalPagesRead(records: []), 0)
    }

    // ---- 已读完本数 ----

    func testFinishedBookCount_usesCurrentRoundPage() {
        let books = [
            Book(id: 1, title: "读完", author: "", totalPages: 100, currentRound: 2),
            Book(id: 2, title: "在读", author: "", totalPages: 300, currentRound: 1),
            Book(id: 3, title: "第一轮读完", author: "", totalPages: 100, currentRound: 1),
        ]
        let records = [
            record(bookId: 1, page: 10, round: 2), // 重读后第 2 轮只读到 10 页 → 未读完
            record(bookId: 2, page: 299),
            record(bookId: 3, page: 100),
        ]
        XCTAssertEqual(ReadingStats.finishedBookCount(books: books, records: records), 1, "书1 重读中不算、书2 未到、仅书3 读完")
    }

    func testFinishedBookCount_noRecordsMeansNotFinished() {
        let books = [Book(id: 1, title: "书", author: "", totalPages: 10)]
        XCTAssertEqual(ReadingStats.finishedBookCount(books: books, records: []), 0)
    }

    // ---- 区间已读页数（首页「本月已读页」）----

    func testTotalPagesReadBetween_countsOnlyDeltasWithinRange() {
        let records = [
            record(bookId: 1, page: 10, date: CalendarDay(year: 2026, month: 8, day: 31)), // 区间外首条：只推进基数
            record(bookId: 1, page: 35, date: CalendarDay(year: 2026, month: 9, day: 1)),  // +25 归 9 月
            record(bookId: 1, page: 60, date: CalendarDay(year: 2026, month: 9, day: 20)), // +25 归 9 月
            record(bookId: 1, page: 90, date: CalendarDay(year: 2026, month: 10, day: 1)), // 区间外
        ]
        let from = CalendarDay(year: 2026, month: 9, day: 1)
        let to = CalendarDay(year: 2026, month: 9, day: 30)
        XCTAssertEqual(ReadingStats.totalPagesReadBetween(records: records, from: from, to: to), 50)
    }

    func testTotalPagesReadBetween_emptyIsZero() {
        let from = CalendarDay(year: 2026, month: 9, day: 1)
        XCTAssertEqual(ReadingStats.totalPagesReadBetween(records: [], from: from, to: from), 0)
    }

    // ---- 某日期后读完的本数（首页「今年读完」）----

    func testFinishedCountSince_requiresFinishDatedOnOrAfterEarliest() {
        let books = [
            Book(id: 1, title: "今年读完", author: "", totalPages: 100),
            Book(id: 2, title: "去年读完", author: "", totalPages: 100),
            Book(id: 3, title: "读完但无记录", author: "", totalPages: 100),
            Book(id: 4, title: "未读完", author: "", totalPages: 100),
        ]
        let records = [
            record(bookId: 1, page: 100, date: CalendarDay(year: 2026, month: 3, day: 5)),
            record(bookId: 2, page: 100, date: CalendarDay(year: 2025, month: 12, day: 31)),
            record(bookId: 4, page: 99, date: CalendarDay(year: 2026, month: 3, day: 5)),
        ]
        let earliest = CalendarDay(year: 2026, month: 1, day: 1)
        XCTAssertEqual(
            ReadingStats.finishedCountSince(books: books, records: records, earliest: earliest),
            1,
            "书2 去年读完不计、书3 无记录无从 dating 不计、书4 未读完不计",
        )
    }

    func testFinishedCountSince_usesCurrentRoundLastRecordDate() {
        let books = [Book(id: 1, title: "书", author: "", totalPages: 100, currentRound: 2)]
        let records = [
            record(bookId: 1, page: 100, round: 1, date: CalendarDay(year: 2025, month: 6, day: 1)), // 第 1 轮去年读完
            record(bookId: 1, page: 100, round: 2, date: CalendarDay(year: 2026, month: 2, day: 10)), // 第 2 轮今年读完
        ]
        let earliest = CalendarDay(year: 2026, month: 1, day: 1)
        XCTAssertEqual(
            ReadingStats.finishedCountSince(books: books, records: records, earliest: earliest),
            1,
            "以当前轮（第 2 轮）最后一条记录日期为准",
        )
    }
}
