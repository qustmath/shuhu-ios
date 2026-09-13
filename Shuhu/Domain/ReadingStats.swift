import Foundation

/// 「我」页统计（spec: Stats）。全部为纯函数。与 Android 端 `ReadingStats` 逐条对应。
public enum ReadingStats {

    /// 累计阅读页数 = 每本书每一轮内「相邻记录差值」之和，每轮第一条从 0 起算。
    /// 组内按时间顺序（日期，再录入时间，再 id）计算差值；记录被改小时该步差值可为负（对修正的真实反映）。
    public static func totalPagesRead(records: [ReadingRecord]) -> Int64 {
        var total: Int64 = 0
        var groups: [String: [ReadingRecord]] = [:]
        for record in records {
            groups["\(record.bookId)#\(record.round)", default: []].append(record)
        }
        for group in groups.values {
            let sorted = group.sorted { a, b in
                if a.date != b.date { return a.date < b.date }
                if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
                return a.id < b.id
            }
            var previous = 0
            for record in sorted {
                total += Int64(record.pageReached - previous)
                previous = record.pageReached
            }
        }
        return total
    }

    /// 已读完本数：当前页（按各自当前轮计算）达到总页数的书。
    public static func finishedBookCount(books: [Book], records: [ReadingRecord]) -> Int {
        books.filter { book in
            let page = ReadingRules.currentPage(
                records.filter { $0.bookId == book.id },
                round: book.currentRound,
            )
            return ReadingRules.isFinished(currentPage: page, totalPages: book.totalPages)
        }.count
    }
}
