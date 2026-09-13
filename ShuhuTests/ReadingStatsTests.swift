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
}
