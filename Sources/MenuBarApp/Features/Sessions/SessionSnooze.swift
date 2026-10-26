import Foundation

// A session put out of the way. Its card stays in the rail, marked as snoozed, and it
// stays quiet until a set time or until the person brings it back. Snoozes saved before
// may instead end when the agent next replies. The agent asking something ends any snooze, since an answer is wanted whatever
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
    // The answers the snooze dialog offers, in the order they run out. A snooze that ends
    // on the next reply is still honoured when it was saved before, but no longer offered.
    enum Choice: CaseIterable, Identifiable, Hashable {
        case morning, nextWeek, untilWoken

        var id: Self { self }

        // The timed choices name their day, so the pick reads the same at 7:00 as it
        // does at 23:00, and a Monday a week away never reads as today.
        func title(now: Date = Date(), calendar: Calendar = .current) -> String {
            switch self {
            case .morning:
                let morning = SessionSnooze.nextMorning(after: now, calendar: calendar)
                return "Until \(Self.time(morning, calendar: calendar)) \(Self.relativeDay(morning, now: now, calendar: calendar))"
            case .nextWeek:
                var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.abbreviated)
                style = Self.localised(style, calendar: calendar)
                return "Until " + SessionSnooze.nextWeek(after: now, calendar: calendar).formatted(style)
            case .untilWoken:
                return "Until I wake it"
            }
        }

        func note(now: Date = Date(), calendar: Calendar = .current) -> String {
            switch self {
            case .morning, .nextWeek:
                Self.comesBack(snooze(now: now, calendar: calendar).deadline ?? now,
                               now: now, calendar: calendar)
            case .untilWoken:
                "Stays snoozed until you choose Wake up."
            }
        }

        var icon: String {
            switch self {
            case .morning: "sunrise"
            case .nextWeek: "calendar"
            case .untilWoken: "bell.slash"
            }
        }

        // "Comes back tomorrow, Sunday 25 October, at 08:00."
        private static func comesBack(_ date: Date, now: Date, calendar: Calendar) -> String {
            let day = date.formatted(localised(.dateTime.weekday(.wide).day().month(.wide), calendar: calendar))
            let relative = relativeDay(date, now: now, calendar: calendar)
            let when = relative.isEmpty ? "on \(day)" : "\(relative), \(day),"
            return "Comes back \(when) at \(time(date, calendar: calendar))."
        }

        private static func relativeDay(_ date: Date, now: Date, calendar: Calendar) -> String {
            if calendar.isDate(date, inSameDayAs: now) { return "today" }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
               calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow" }
            return ""
        }

        private static func time(_ date: Date, calendar: Calendar) -> String {
            date.formatted(localised(Date.FormatStyle(date: .omitted, time: .shortened), calendar: calendar))
        }

        private static func localised(_ style: Date.FormatStyle, calendar: Calendar) -> Date.FormatStyle {
            var style = style
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            if let locale = calendar.locale { style.locale = locale }
            return style
        }

        func snooze(now: Date = Date(), calendar: Calendar = .current) -> SessionSnooze {
            switch self {
            case .morning: .until(SessionSnooze.nextMorning(after: now, calendar: calendar))
            case .nextWeek: .until(SessionSnooze.nextWeek(after: now, calendar: calendar))
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

    // The first Monday 8:00 after the next morning, so it never lands on the same moment
    // as the morning choice, as it would late on a Sunday or early on a Monday.
    static func nextWeek(after now: Date, calendar: Calendar = .current) -> Date {
        let morning = nextMorning(after: now, calendar: calendar)
        return calendar.nextDate(after: morning,
                                 matching: DateComponents(hour: wakeHour, minute: 0, weekday: 2),
                                 matchingPolicy: .nextTime) ?? morning.addingTimeInterval(7 * 86_400)
    }
}
