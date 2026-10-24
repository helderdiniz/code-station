import Foundation
import Testing
@testable import MenuBarApp

// A session put out of the way: what hides it, what keeps it quiet, and what brings it back.
@MainActor
struct SessionSnoozeTests {
    private let testPreferences = TestPreferences()
    private let store: ProjectStore
    private let scratch: ScratchDirectory
    private let project: Project

    init() throws {
        (store, scratch) = TestStore.make()
        project = try TestStore.project(in: store)
    }

    @Test func aSnoozedSessionStopsAskingForAnyone() {
        let sleeping = store.newSession(in: project.id)
        let open = store.newSession(in: project.id)
        store.selection = .session(open.id)
        store.noteTurnEnded(for: sleeping.id)
        #expect(store.unreadCount(in: project.id) == 1)

        store.snooze(sleeping.id, .untilWoken)

        #expect(store.isSnoozed(sleeping.id))
        #expect(store.unreadCount(in: project.id) == 0)

        store.wake(sleeping.id)

        #expect(store.isSnoozed(sleeping.id) == false)
        #expect(store.unreadCount(in: project.id) == 1)
    }

    @Test func theReplyEndsASnoozeThatWaitedForIt() {
        let sleeping = store.newSession(in: project.id)
        let open = store.newSession(in: project.id)
        store.selection = .session(open.id)
        store.snooze(sleeping.id, .untilReply)

        #expect(store.noteTurnEnded(for: sleeping.id))

        #expect(store.isSnoozed(sleeping.id) == false)
        #expect(store.isUnread(sleeping.id))
        #expect(store.unreadCount(in: project.id) == 1)
    }

    @Test func aTimedSnoozeStaysQuietThroughAReplyUntilItsTimeIsUp() {
        let sleeping = store.newSession(in: project.id)
        let open = store.newSession(in: project.id)
        store.selection = .session(open.id)
        let now = Date()
        store.snooze(sleeping.id, .until(now.addingTimeInterval(3_600)))

        store.noteTurnEnded(for: sleeping.id)
        #expect(store.isSnoozed(sleeping.id, now: now))
        #expect(store.unreadCount(in: project.id) == 0)

        // Past its time the snooze is over even before the sweep has run.
        #expect(store.isSnoozed(sleeping.id, now: now.addingTimeInterval(3_601)) == false)
        store.expireSnoozes(now: now.addingTimeInterval(3_601))
        #expect(store.session(sleeping.id)?.snooze == nil)
        #expect(store.unreadCount(in: project.id) == 1)
    }

    @Test func theSnoozeSurvivesARelaunch() throws {
        let sleeping = store.newSession(in: project.id)
        store.snooze(sleeping.id, .untilWoken)
        #expect(store.save())

        let reloaded = ProjectStore(preferences: testPreferences.store, storeURL: store.storeURL)

        #expect(reloaded.isSnoozed(sleeping.id))
        #expect(reloaded.session(sleeping.id)?.snooze == .untilWoken)
    }

    @Test func choicesLandOnTheNextMorningAndTheNextMonday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }

        // A Saturday mid-morning: 8:00 is tomorrow, Monday is two days on.
        let saturday = date(2026, 10, 24, 10)
        #expect(SessionSnooze.Choice.morning.snooze(now: saturday, calendar: calendar)
            == .until(date(2026, 10, 25, 8)))
        #expect(SessionSnooze.Choice.monday.snooze(now: saturday, calendar: calendar)
            == .until(date(2026, 10, 26, 8)))

        // Early on a Monday both land on 8:00 the same morning.
        let earlyMonday = date(2026, 10, 26, 7)
        #expect(SessionSnooze.Choice.morning.snooze(now: earlyMonday, calendar: calendar)
            == .until(date(2026, 10, 26, 8)))
        #expect(SessionSnooze.Choice.monday.snooze(now: earlyMonday, calendar: calendar)
            == .until(date(2026, 10, 26, 8)))

        // At 8:00 sharp the choice means the next one, not this one.
        #expect(SessionSnooze.Choice.monday.snooze(now: date(2026, 10, 26, 8), calendar: calendar)
            == .until(date(2026, 11, 2, 8)))
        #expect(SessionSnooze.Choice.untilReply.snooze().endsOnReply)
        #expect(SessionSnooze.Choice.untilWoken.snooze().deadline == nil)
    }
}
