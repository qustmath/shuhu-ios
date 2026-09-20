import Foundation

/// 界面日期文案格式（与 Android `com.shufou.domain.DateFormats` 逐条对应），纯函数。
public enum DateFormats {

    /// 2026-09-04 → `9月4日`。
    public static func shortDate(_ date: CalendarDay) -> String {
        "\(date.month)月\(date.day)日"
    }

    /// 表单风格：`09月04日`（月/日各两位）。
    public static func planDate(_ date: CalendarDay) -> String {
        String(format: "%02d月%02d日", date.month, date.day)
    }

    /// 记录列表：`9月4日 22:00`（日期来自记录本身，时刻来自录入时间 epoch 毫秒，设备时区）。
    public static func recordDateTime(date: CalendarDay, createdAt: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: Date(timeIntervalSince1970: Double(createdAt) / 1000))
        return "\(shortDate(date)) \(time)"
    }

    /// 表单/详情的结束日期展示：计划总天数（含首尾）+ 日期，如 `(5天) 09月04日`。
    public static func planDateWithDuration(days: Int, date: CalendarDay) -> String {
        "(\(days)天) \(planDate(date))"
    }

    /// 剩余天数展示，如 `剩 5 天`。
    public static func daysLeft(_ days: Int) -> String {
        "剩 \(days) 天"
    }

    /// 每日目标展示，如 `今天目标 59 页`。
    public static func dailyTargetLabel(_ target: Int) -> String {
        "今天目标 \(target) 页"
    }

    /// 主页头部日期行，如 `9月19日 · 星期五`。
    public static func todayLine(_ date: CalendarDay) -> String {
        "\(shortDate(date)) · \(date.chineseWeekday)"
    }

    /// 超期警示，如 `已超计划 2 天 · 还差 89 页`。
    public static func overdueLine(daysOver: Int, pagesLeft: Int) -> String {
        "已超计划 \(daysOver) 天 · 还差 \(pagesLeft) 页"
    }
}

public extension CalendarDay {
    /// 中文星期名（星期一 … 星期日），todayLine 用。
    var chineseWeekday: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        let weekday = calendar.component(.weekday, from: calendar.date(from: comps)!)
        // Foundation：1 = 周日 … 7 = 周六
        let names = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        return names[weekday - 1]
    }
}
