import Foundation
import OSLog

// ---- 同步契约 v1 的 DTO（与 shared/sync-api-v1.yaml 一致，镜像 Android `SyncDtos`）----

public struct SyncBookChange: Codable, Equatable, Sendable {
    public let guid: String
    public var title: String?
    public var author: String?
    public var totalPages: Int?
    public var startDate: String?
    public var endDate: String?
    public var currentRound: Int?
    public var coverImagePath: String?
    public var sortOrder: Int?
    public let updatedAt: Int64
    public var deletedAt: Int64?

    public init(
        guid: String,
        title: String? = nil,
        author: String? = nil,
        totalPages: Int? = nil,
        startDate: String? = nil,
        endDate: String? = nil,
        currentRound: Int? = nil,
        coverImagePath: String? = nil,
        sortOrder: Int? = nil,
        updatedAt: Int64,
        deletedAt: Int64? = nil,
    ) {
        self.guid = guid
        self.title = title
        self.author = author
        self.totalPages = totalPages
        self.startDate = startDate
        self.endDate = endDate
        self.currentRound = currentRound
        self.coverImagePath = coverImagePath
        self.sortOrder = sortOrder
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public struct SyncRecordChange: Codable, Equatable, Sendable {
    public let guid: String
    public let bookGuid: String
    public var date: String?
    public var createdAt: Int64?
    public var pageReached: Int?
    public var round: Int?
    public var remark: String?
    public let updatedAt: Int64
    public var deletedAt: Int64?

    public init(
        guid: String,
        bookGuid: String,
        date: String? = nil,
        createdAt: Int64? = nil,
        pageReached: Int? = nil,
        round: Int? = nil,
        remark: String? = nil,
        updatedAt: Int64,
        deletedAt: Int64? = nil,
    ) {
        self.guid = guid
        self.bookGuid = bookGuid
        self.date = date
        self.createdAt = createdAt
        self.pageReached = pageReached
        self.round = round
        self.remark = remark
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public struct SyncPushRequest: Codable, Sendable {
    public var books: [SyncBookChange]
    public var records: [SyncRecordChange]

    public init(books: [SyncBookChange] = [], records: [SyncRecordChange] = []) {
        self.books = books
        self.records = records
    }
}

public struct SyncPushResult: Codable, Equatable, Sendable {
    public let guid: String
    public let entity: String
    public let accepted: Bool
    public let reason: String?
}

public struct SyncPushData: Codable, Sendable {
    public let cursor: String
    public var results: [SyncPushResult]?
}

public struct SyncPullData: Codable, Sendable {
    public let cursor: String
    public var hasMore: Bool?
    public var books: [SyncBookChange]?
    public var records: [SyncRecordChange]?
}

/// 云端有效数据概览（换账号弹窗提示用）。
public struct SyncStatsData: Codable, Sendable {
    public let liveBooks: Int64
    public let liveRecords: Int64
}

/// 封面上传返回（data.path）。
public struct SyncCoverUploadData: Codable, Sendable {
    public let path: String
}

// ---- DTO ↔ 领域模型映射（镜像 Android SyncEngine 的私有扩展）----

public extension SyncBookChange {
    /// 远端书籍 → 领域模型。日期缺失/非法时**按未设置处理并记日志**（与 Android
    /// `parseIsoDateOrNull` 同义）：一本书的日期坏了不该让它整行消失，
    /// 保留书名/页数/记录，用户重新设置计划即可恢复。
    func toDomain() -> Book {
        Book(
            id: 0,
            title: title ?? "",
            author: author ?? "",
            totalPages: totalPages ?? 0,
            startDate: Self.parseDay(startDate, guid: guid, field: "startDate"),
            endDate: Self.parseDay(endDate, guid: guid, field: "endDate"),
            currentRound: currentRound ?? 1,
            coverImagePath: coverImagePath,
            sortOrder: sortOrder ?? 0,
            guid: guid,
            updatedAt: updatedAt,
            deletedAt: deletedAt,
        )
    }

    private static func parseDay(_ raw: String?, guid: String, field: String) -> CalendarDay? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let day = CalendarDay(iso: raw) else {
            Logger(subsystem: "ink.groovy.shuhu", category: "sync")
                .warning("远端书籍日期非法，按未设置处理：guid=\(guid, privacy: .public) \(field, privacy: .public)=\(raw, privacy: .public)")
            return nil
        }
        return day
    }

    static func from(_ book: Book) -> SyncBookChange {
        SyncBookChange(
            guid: book.guid,
            title: book.title,
            author: book.author,
            totalPages: book.totalPages,
            startDate: book.startDate?.iso,
            endDate: book.endDate?.iso,
            currentRound: book.currentRound,
            coverImagePath: book.coverImagePath,
            sortOrder: book.sortOrder,
            updatedAt: book.updatedAt,
            deletedAt: book.deletedAt,
        )
    }
}

public extension SyncRecordChange {
    func toDomain(bookId: Int64) -> ReadingRecord? {
        guard let date, let day = CalendarDay(iso: date) else { return nil }
        return ReadingRecord(
            id: 0,
            bookId: bookId,
            date: day,
            createdAt: createdAt ?? 0,
            pageReached: pageReached ?? 0,
            round: round ?? 1,
            remark: remark,
            guid: guid,
            updatedAt: updatedAt,
            deletedAt: deletedAt,
        )
    }

    static func from(_ record: ReadingRecord, bookGuid: String) -> SyncRecordChange {
        SyncRecordChange(
            guid: record.guid,
            bookGuid: bookGuid,
            date: record.date.iso,
            createdAt: record.createdAt,
            pageReached: record.pageReached,
            round: record.round,
            remark: record.remark,
            updatedAt: record.updatedAt,
            deletedAt: record.deletedAt,
        )
    }
}
