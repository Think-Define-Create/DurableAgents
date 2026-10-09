import Foundation

public enum Cron {
    public static func validate(_ expression: String, timeZone: String) throws {
        guard TimeZone(identifier: timeZone) != nil else {
            throw ScheduleError.invalidTimeZone(timeZone)
        }
        _ = try fields(expression)
    }

    public static func matches(_ expression: String, at date: Date, timeZone: TimeZone) -> Bool {
        guard let parsed = try? fields(expression) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        guard let minute = parts.minute, let hour = parts.hour, let day = parts.day,
              let month = parts.month, let weekday = parts.weekday
        else {
            return false
        }
        let cronWeekday = weekday - 1
        let dayMatch = parsed.dayOfMonth(day) || parsed.dayOfMonthIsStar
        let weekMatch = parsed.dayOfWeek(cronWeekday) || parsed.dayOfWeekIsStar
        let dayOK: Bool
        if parsed.dayOfMonthIsStar && parsed.dayOfWeekIsStar {
            dayOK = true
        } else if parsed.dayOfMonthIsStar {
            dayOK = weekMatch
        } else if parsed.dayOfWeekIsStar {
            dayOK = dayMatch
        } else {
            dayOK = parsed.dayOfMonth(day) || parsed.dayOfWeek(cronWeekday)
        }
        return parsed.minute(minute) && parsed.hour(hour) && parsed.month(month) && dayOK
    }

    /// The next minute, strictly after `date`, that matches. Scans at most a year.
    public static func next(after date: Date, expression: String, timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard var cursor = calendar.date(bySetting: .second, value: 0, of: date) else { return nil }
        if cursor <= date {
            cursor = calendar.date(byAdding: .minute, value: 1, to: cursor) ?? cursor
        }
        for _ in 0..<(366 * 24 * 60) {
            if matches(expression, at: cursor, timeZone: timeZone) {
                return cursor
            }
            guard let next = calendar.date(byAdding: .minute, value: 1, to: cursor) else { return nil }
            cursor = next
        }
        return nil
    }

    /// Latest matching minute at or before `date`, looking back at most `days`.
    static func previous(atOrBefore date: Date, expression: String, timeZone: TimeZone, days: Int) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard var cursor = calendar.date(bySetting: .second, value: 0, of: date) else { return [] }
        if cursor > date {
            cursor = calendar.date(byAdding: .minute, value: -1, to: cursor) ?? cursor
        }
        var found: [Date] = []
        let limit = max(1, days) * 24 * 60
        for _ in 0..<limit {
            if matches(expression, at: cursor, timeZone: timeZone) {
                found.append(cursor)
            }
            guard let earlier = calendar.date(byAdding: .minute, value: -1, to: cursor) else { break }
            cursor = earlier
        }
        return found.reversed()
    }

    private struct Fields {
        var minute: (Int) -> Bool
        var hour: (Int) -> Bool
        var dayOfMonth: (Int) -> Bool
        var month: (Int) -> Bool
        var dayOfWeek: (Int) -> Bool
        var dayOfMonthIsStar: Bool
        var dayOfWeekIsStar: Bool
    }

    private static func fields(_ expression: String) throws -> Fields {
        let parts = expression.split(separator: " ").map(String.init)
        guard parts.count == 5 else { throw ScheduleError.invalidCron(expression) }
        return Fields(
            minute: try matcher(parts[0], range: 0...59),
            hour: try matcher(parts[1], range: 0...23),
            dayOfMonth: try matcher(parts[2], range: 1...31),
            month: try matcher(parts[3], range: 1...12),
            dayOfWeek: try weekdayMatcher(parts[4]),
            dayOfMonthIsStar: parts[2] == "*",
            dayOfWeekIsStar: parts[4] == "*"
        )
    }

    private static func weekdayMatcher(_ text: String) throws -> (Int) -> Bool {
        let inner = try matcher(text == "7" ? "0" : text.replacingOccurrences(of: "7", with: "0"), range: 0...6)
        return inner
    }

    private static func matcher(_ text: String, range: ClosedRange<Int>) throws -> (Int) -> Bool {
        if text == "*" { return { range.contains($0) } }
        let pieces = text.split(separator: ",").map(String.init)
        if pieces.isEmpty { throw ScheduleError.invalidCron(text) }
        var allowed: Set<Int> = []
        for piece in pieces {
            if piece.hasPrefix("*/") {
                guard let step = Int(piece.dropFirst(2)), step > 0 else { throw ScheduleError.invalidCron(text) }
                for value in range where value % step == 0 {
                    allowed.insert(value)
                }
                continue
            }
            let bounds = piece.split(separator: "-").map(String.init)
            if bounds.count == 2, let lower = Int(bounds[0]), let upper = Int(bounds[1]), lower <= upper {
                for value in lower...upper where range.contains(value) {
                    allowed.insert(value)
                }
                continue
            }
            guard let value = Int(piece), range.contains(value) else { throw ScheduleError.invalidCron(text) }
            allowed.insert(value)
        }
        return { allowed.contains($0) }
    }
}
