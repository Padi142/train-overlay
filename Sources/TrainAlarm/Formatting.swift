import SwiftUI
import TrainAlarmKit

extension Date {
    /// "07:05" — always 24-hour, like Czech timetables.
    var clockTime: String {
        formatted(Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: .current,
            calendar: .current
        ))
    }
}

/// Minutes until `date`, split for display: ("23", "min"), ("1:05", "h"), ("now", "").
struct Countdown {
    let value: String
    let unit: String

    init(until date: Date, from now: Date) {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        switch minutes {
        case ..<1: (value, unit) = ("now", "")
        case ..<60: (value, unit) = ("\(minutes)", "min")
        default: (value, unit) = (String(format: "%d:%02d", minutes / 60, minutes % 60), "h")
        }
    }

    var text: String { unit.isEmpty ? value : "\(value) \(unit)" }
}

extension Ride {
    /// Colour that communicates the delay at a glance.
    var delayTint: Color {
        guard let delay else { return .secondary }
        return switch delay {
        case ...0: .green
        case ..<5: .orange
        default: .red
        }
    }
}
