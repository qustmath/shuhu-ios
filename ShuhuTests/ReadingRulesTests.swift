import XCTest
@testable import Shuhu

/// 领域规则纯函数测试：逐条镜像 Android `ReadingRulesTest` 的关键用例
/// （按轮计算当前页、isFinished、重读后进度归零且历史保留、轮次标记条件、页码校验）。
final class ReadingRulesTests: XCTestCase {

    private func record(
        date: CalendarDay,
        page: Int,
        round: Int = 1,
        createdAt: Int64 = 0,
        remark: String? = nil,
    ) -> ReadingRecord {
        ReadingRecord(bookId: 1, date: date, createdAt: createdAt, pageReached: page, round: round, remark: remark)
    }

    private let d1 = CalendarDay(year: 2026, month: 9, day: 11)
    private let d2 = CalendarDay(year: 2026, month: 9, day: 12)

    // ---- 当前页按轮次计算 ----

    func testCurrentPage_ignoresOtherRounds() {
        let records = [
            record(date: d1, page: 100),
            record(date: d2, page: 150, round: 2),
        ]
        XCTAssertEqual(ReadingRules.currentPage(records: records, round: 1), 100, "第 1 轮的当前页不受第 2 轮记录影响")
        XCTAssertEqual(ReadingRules.currentPage(records: records, round: 2), 150)
        XCTAssertEqual(ReadingRules.currentPage(records: records, round: 3), 0, "无记录的轮次为 0")
    }

    func testCurrentPage_picksNewestByDateThenCreatedAt() {
        let records = [
            record(date: d1, page: 10, createdAt: 2),
            record(date: d2, page: 20, createdAt: 1),
        ]
        XCTAssertEqual(ReadingRules.currentPage(records: records), 20, "先按日期，日期新者胜")
        let sameDay = [
            record(date: d2, page: 30, createdAt: 1),
            record(date: d2, page: 40, createdAt: 2),
        ]
        XCTAssertEqual(ReadingRules.currentPage(records: sameDay), 40, "同日按录入时间")
    }

    // ---- isFinished 与重读 ----

    func testIsFinished_reachesTotalPages() {
        XCTAssertTrue(ReadingRules.isFinished(currentPage: 300, totalPages: 300))
        XCTAssertTrue(ReadingRules.isFinished(currentPage: 310, totalPages: 300), "补记超过总页数也算读完")
        XCTAssertFalse(ReadingRules.isFinished(currentPage: 299, totalPages: 300))
    }

    func testReread_resetsProgressToZero_andIsNoLongerFinished_butHistoryIsPreserved() {
        // 重读：currentRound +1 写回；第 2 轮无记录 → 当前页 0、不再算读完；第 1 轮记录原样保留
        var book = Book(title: "书", author: "", totalPages: 300, currentRound: 1)
        let history = [record(date: d2, page: 300)]
        XCTAssertEqual(ReadingRules.currentPage(records: history, round: book.currentRound), 300)
        XCTAssertTrue(ReadingRules.isFinished(currentPage: 300, totalPages: 300))

        book.currentRound += 1
        XCTAssertEqual(ReadingRules.currentPage(records: history, round: book.currentRound), 0, "新轮次无记录，进度归零")
        XCTAssertFalse(ReadingRules.isFinished(currentPage: 0, totalPages: 300), "重读后不再算已读完")
        XCTAssertEqual(history.count, 1, "历史记录保留")
        XCTAssertEqual(history[0].remark, nil)
    }

    // ---- 轮次标记 ----

    func testRoundLabel_appearsOnlyForMultiRoundBooks() {
        let single = Book(title: "书", author: "", totalPages: 100)
        XCTAssertFalse(ReadingRules.hasMultipleRounds(book: single, records: []), "单轮书不出现轮次概念")

        let reread = Book(title: "书", author: "", totalPages: 100, currentRound: 2)
        XCTAssertTrue(ReadingRules.hasMultipleRounds(book: reread, records: []), "重读后（第 2 轮）即多轮书")

        let oldRecords = [record(date: d1, page: 100, round: 2)]
        let backToOne = Book(title: "书", author: "", totalPages: 100, currentRound: 1)
        XCTAssertTrue(ReadingRules.hasMultipleRounds(book: backToOne, records: oldRecords), "currentRound=1 但历史里有更高轮次，也是多轮书")
    }

    func testRecordsOfRound_filtersByRoundKeepingOrder() {
        let records = [
            record(date: d1, page: 10),
            record(date: d2, page: 20, round: 2),
            record(date: d2, page: 30),
        ]
        let first = ReadingRules.recordsOfRound(records: records, round: 1)
        XCTAssertEqual(first.map(\.pageReached), [10, 30], "只保留第 1 轮，顺序不变")
        let second = ReadingRules.recordsOfRound(records: records, round: 2)
        XCTAssertEqual(second.map(\.pageReached), [20])
    }

    func testCurrentPage_breaksTiesById_regardlessOfListOrder() {
        // 同一日期、同一录入毫秒（导入/同步等场景可能出现）：id 大者视为最新，
        // 且结论不得随列表顺序变化——否则两端会算出不同的当前页与「已读完」判定。
        let smaller = ReadingRecord(id: 7, bookId: 1, date: d2, createdAt: 1_000, pageReached: 100)
        let larger = ReadingRecord(id: 8, bookId: 1, date: d2, createdAt: 1_000, pageReached: 150)
        XCTAssertEqual(ReadingRules.currentPage(records: [smaller, larger]), 150)
        XCTAssertEqual(ReadingRules.currentPage(records: [larger, smaller]), 150, "结论与列表顺序无关")
    }

    // ---- 页码校验 ----

    func testValidateNewRecord_mustBeWithinCurrentPageAndTotal() {
        XCTAssertEqual(ReadingRules.validateNewRecord(pageReached: 50, currentPage: 49, totalPages: 300), nil)
        XCTAssertEqual(ReadingRules.validateNewRecord(pageReached: 49, currentPage: 49, totalPages: 300), .belowOrEqualCurrentPage, "必须超过当前页")
        XCTAssertEqual(ReadingRules.validateNewRecord(pageReached: 301, currentPage: 49, totalPages: 300), .aboveTotalPages)
    }

    func testValidateEditRecord_onlyRequiresOneToTotalPages() {
        XCTAssertEqual(ReadingRules.validateEditRecord(pageReached: 1, totalPages: 300), nil)
        XCTAssertEqual(ReadingRules.validateEditRecord(pageReached: 120, totalPages: 300), nil, "允许改小（历史可能重排）")
        XCTAssertEqual(ReadingRules.validateEditRecord(pageReached: 0, totalPages: 300), .belowOrEqualCurrentPage)
        XCTAssertEqual(ReadingRules.validateEditRecord(pageReached: 301, totalPages: 300), .aboveTotalPages)
    }
}
