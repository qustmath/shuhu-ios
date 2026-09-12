import Foundation

/// 用户视角的日历日：无时刻、无时区语义，镜像 Android 的 `java.time.LocalDate`。
///
/// 文本形态 `yyyy-MM-dd`，与 Android 端及服务端的 ISO 存储一致。
/// 跨天计算用格里历 + 正午 UTC（规避夏令时跳变），结果与 `ChronoUnit.DAYS` 一致。
public struct CalendarDay: Hashable, Comparable, Codable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// 解析 `yyyy-MM-dd`（Android/服务端的存储格式）；格式不合法返回 nil。
    /// 与 Android `LocalDate.parse` 同样严格：年 4 位、月日各 2 位、且是真实存在的日历日（02-31 拒绝）。
    public init?(iso: String) {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        // 真实日历日校验：Foundation 会把 02-31 归一到 03-03，往返不一致即拒绝
        let candidate = CalendarDay(year: y, month: m, day: d)
        let roundTripped = candidate.adding(days: 0)
        guard roundTripped == candidate else { return nil }
        year = y
        month = m
        day = d
    }

    /// `yyyy-MM-dd`（四位年、两位月日，与 Android `LocalDate.toString()` 一致）。
    public var iso: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// 设备本地时区的今天（与 Android `LocalDate.now()` 同语义）。
    public static func today(now: Date = Date(), timeZone: TimeZone = .current) -> CalendarDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let comps = calendar.dateComponents([.year, .month, .day], from: now)
        return CalendarDay(
            year: comps.year ?? 1970,
            month: comps.month ?? 1,
            day: comps.day ?? 1,
        )
    }

    /// 与另一天的间隔天数：`self` 在后为正，在前为负（镜像 `ChronoUnit.DAYS.between` 的方向语义）。
    /// 例：08-31.days(until: 09-04) = 4。
    public func days(until other: CalendarDay) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateComponents([.day], from: noonUTC(calendar), to: other.noonUTC(calendar)).day!
    }

    /// 往前/往后推 N 天（跨月、跨年由格里历进位）。
    public func adding(days value: Int) -> CalendarDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let moved = calendar.date(byAdding: .day, value: value, to: noonUTC(calendar))!
        let comps = calendar.dateComponents([.year, .month, .day], from: moved)
        return CalendarDay(year: comps.year!, month: comps.month!, day: comps.day!)
    }

    /// 正午 UTC 的时刻：任何时区的日界变化都不会影响按天差值。
    private func noonUTC(_ calendar: Calendar) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        return calendar.date(from: comps)!
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// `Codable` 以 `yyyy-MM-dd` 字符串编解码（与 Android 端/服务端 JSON 一致）。
public extension CalendarDay {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let day = CalendarDay(iso: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "非法日期字符串，期望 yyyy-MM-dd",
            )
        }
        self = day
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso)
    }
}
