import Foundation

// A session put out of the way. Its card stays in the rail, marked as snoozed, and it
// stays quiet until the agent replies, until a set time, or until the person brings it
// back. The agent asking something ends any snooze, since an answer is wanted whatever
// was chosen.
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

        // The timed choices name their day and hour, so the pick reads the same at 7:00
        // as it does at 23:00.
        func title(now: Date = Date(), calendar: Calendar = .current) -> String {
            switch self {
            case .untilReply: "Until it replies"
            case .morning:
                "Until " + Self.timeAndDay(SessionSnooze.nextMorning(after: now, calendar: calendar),
                                           now: now, calendar: calendar)
            case .monday: "Until Monday"
            case .untilWoken: "Until I wake it"
            }
        }

        func note(now: Date = Date(), calendar: Calendar = .current) -> String {
            switch self {
            case .untilReply:
                "Comes back, and tells you, when the agent next finishes a turn."
            case .morning, .monday:
                Self.comesBack(snooze(now: now, calendar: calendar).deadline ?? now,
                               now: now, calendar: calendar)
            case .untilWoken:
                "Stays snoozed until you wake it from its menu."
            }
        }

        // "Comes back tomorrow, Sunday 25 October, at 08:00."
        private static func comesBack(_ date: Date, now: Date, calendar: Calendar) -> String {
            var dayStyle = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
            dayStyle.calendar = calendar
            dayStyle.timeZone = calendar.timeZone
            let day = date.formatted(dayStyle)
            let relative = relativeDay(date, now: now, calendar: calendar)
            let when = relative.isEmpty ? "on \(day)" : "\(relative), \(day),"
            return "Comes back \(when) at \(time(date, calendar: calendar))."
        }

        // "08:00 tomorrow". The next morning is always today or tomorrow.
        private static func timeAndDay(_ date: Date, now: Date, calendar: Calendar) -> String {
            "\(time(date, calendar: calendar)) \(relativeDay(date, now: now, calendar: calendar))"
        }

        private static func relativeDay(_ date: Date, now: Date, calendar: Calendar) -> String {
            if calendar.isDate(date, inSameDayAs: now) { return "today" }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
               calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow" }
            return ""
        }

        private static func time(_ date: Date, calendar: Calendar) -> String {
            var style = Date.FormatStyle(date: .omitted, time: .shortened)
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            return date.formatted(style)
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
