import Foundation

/// 服务端时间是 ISO-8601 字符串，这里集中做解析与展示，避免各页面各写一套。
enum POSDate {

    // MARK: - 格式化器

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    // MARK: - 解析 / 序列化

    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return isoFractional.date(from: raw) ?? isoPlain.date(from: raw)
    }

    static func isoString(_ date: Date) -> String {
        isoFractional.string(from: date)
    }

    /// 计划项的 `planDate` 口径：本地日期 `yyyy-MM-dd`。
    static func dayKey(_ date: Date = Date()) -> String {
        dayKeyFormatter.string(from: date)
    }

    // MARK: - 展示

    /// 相对时间：刚刚 / x 分钟前 / 今天 HH:mm / 昨天 HH:mm / MM-dd HH:mm。
    static func relative(_ date: Date?) -> String {
        guard let date else { return "尚未同步" }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if Calendar.current.isDateInToday(date) { return clockFormatter.string(from: date) }
        if Calendar.current.isDateInYesterday(date) { return "昨天 \(clockFormatter.string(from: date))" }
        return monthDayFormatter.string(from: date)
    }

    static func relative(_ raw: String?) -> String {
        relative(parse(raw))
    }

    /// 消息气泡用短时间戳。
    static func shortStamp(_ raw: String?) -> String {
        guard let date = parse(raw) else { return "" }
        if Calendar.current.isDateInToday(date) { return clockFormatter.string(from: date) }
        return monthDayFormatter.string(from: date)
    }

    // MARK: - 计划项时间

    /// `startTime` 形如 "09:30"，换算成当天分钟数；无法解析返回 nil。
    static func minutesOfDay(from clock: String?) -> Int? {
        guard let clock else { return nil }
        let parts = clock.split(separator: ":")
        guard parts.count >= 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else { return nil }
        return hour * 60 + minute
    }

    static func minutesSinceMidnight(_ date: Date = Date()) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}
