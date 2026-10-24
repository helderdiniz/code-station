import Foundation

// A session put out of the way. Its card leaves the rail and it stays quiet until the
// agent replies, until a set time, or until the person brings it back. The agent asking
// something ends any snooze, since an answer is wanted whatever was chosen.
enum SessionSnooze: Codable, Equatable, Sendable {
    case untilReply
    case until(Date)
    case untilWoken

    // A timed snooze runs out on its own; the others only end when something ends them.
    func isActive(now: Date = Date()) -> Bool {
        if case .until(let date) = self { return date > now }
        return true
    }

    var endsOnReply: Bool { self == .untilReply }

    var deadline: Date? {
        if case .until(let date) = self { return date }
        return nil
    }

    // "until it replies", "until 08:00", "until Mon 08:00", "until you wake it".
    func phrase(now: Date = Date(), calendar: Calendar = .current) -> String {
        switch self {
        case .untilReply:
            "until it replies"
        case .until(let date):
            "until " + (calendar.isDate(date, inSameDayAs: now)
                ? date.formatted(date: .omitted, time: .shortened)
                : date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        case .untilWoken:
            "until you wake it"
        }
    }
}

extension SessionSnooze {
    // The answers the snooze dialog offers, in the order they run out.
    enum Choice: CaseIterable, Identifiable, Hashable {
        case untilReply, morning, monday, untilWoken

        var id: Self { self }

        var title: String {
            switch self {
            case .untilReply: "Until it replies"
            case .morning: "Until 8:00"
            case .monday: "Until Monday"
            case .untilWoken: "Until I wake it"
            }
        }

        var note: String {
            switch self {
            case .untilReply: "Comes back, and tells you, when the agent next finishes a turn."
            case .morning: "Comes back at 8:00 tomorrow, or later today if it is still early."
            case .monday: "Comes back at 8:00 on Monday morning."
            case .untilWoken: "Stays out of the way until you wake it from its menu."
            }
        }

        func snooze(now: Date = Date(), calendar: Calendar = .current) -> SessionSnooze {
            switch self {
            case .untilReply: .untilReply
            case .morning: .until(SessionSnooze.nextMorning(after: now, calendar: calendar))
            case .monday: .until(SessionSnooze.nextMonday(after: now, calendar: calendar))
            case .untilWoken: .untilWoken
            }
        }
    }

    static let wakeHour = 8

    // The next 8:00 strictly after now.
    static func nextMorning(after now: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: now, matching: DateComponents(hour: wakeHour, minute: 0),
                          matchingPolicy: .nextTime) ?? now.addingTimeInterval(86_400)
    }

    // The next Monday 8:00 strictly after now.
    static func nextMonday(after now: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: now,
                          matching: DateComponents(hour: wakeHour, minute: 0, weekday: 2),
                          matchingPolicy: .nextTime) ?? now.addingTimeInterval(7 * 86_400)
    }
}
