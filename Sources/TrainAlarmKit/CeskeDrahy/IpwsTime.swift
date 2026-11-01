import Foundation

/// Date handling for the IPWS back-end.
///
/// Timestamps arrive as WCF strings, `/Date(1793554260000)/`. Without an offset suffix the
/// milliseconds encode *Czech wall-clock time as if it were UTC* (verified against live
/// departure boards), so the components are re-read in Europe/Prague. With an explicit
/// offset (`/Date(ms+0100)/`) the value is a real instant.
enum IpwsTime {
    static let prague = TimeZone(identifier: "Europe/Prague")!

    static let pragueCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = prague
        return calendar
    }()

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    private static let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]

    static func decode(_ raw: String) -> Date? {
        if raw.hasPrefix("/Date("), let close = raw.firstIndex(of: ")") {
            let inner = raw[raw.index(raw.startIndex, offsetBy: 6)..<close]
            let offsetStart = inner.dropFirst().firstIndex { $0 == "+" || $0 == "-" }
            guard let millis = Double(inner[..<(offsetStart ?? inner.endIndex)]) else { return nil }
            let instant = Date(timeIntervalSince1970: millis / 1000)
            return offsetStart == nil ? wallClockAsUTC(instant) : instant
        }
        // ISO 8601 with a zone is an instant; without one it is Prague wall-clock time.
        if let instant = try? Date(raw, strategy: .iso8601) {
            return instant
        }
        let parts = raw.split(whereSeparator: { "-T:. ".contains($0) }).prefix(6).compactMap { Int($0) }
        guard parts.count >= 5 else { return nil }
        return pragueCalendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2],
            hour: parts[3], minute: parts[4], second: parts.count > 5 ? parts[5] : 0
        ))
    }

    private static func wallClockAsUTC(_ instant: Date) -> Date? {
        pragueCalendar.date(from: utcCalendar.dateComponents(fields, from: instant))
    }

    /// Midnight of the Prague calendar day containing `date`, as IPWS expects for `dtDate`.
    static func dayParameter(_ date: Date) -> String {
        let day = pragueCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02dT00:00:00", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }
}
