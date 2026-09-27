import Foundation
import os
import TopoTools
import UserNotifications
import XCTest

@testable import Topo

/// A permission standing where the test puts it, counting its prompts.
private final class Permission: Authorizer, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var standing: Access
    private let answer: Bool
    private var _prompts = 0

    init(_ name: String = "Reminders", _ standing: Access = .granted, answer: Bool = true) {
        self.name = name
        self.standing = standing
        self.answer = answer
    }

    var prompts: Int { lock.withLock { _prompts } }
    func access() async -> Access { lock.withLock { standing } }
    func request() async -> Bool {
        lock.withLock {
            _prompts += 1
            standing = answer ? .granted : .denied
        }
        return answer
    }
}

/// A permission never asked for, whose prompt stays up until the test answers it.
private final class HeldPrompt: Authorizer, @unchecked Sendable {
    let name = "Reminders"
    private let lock = NSLock()
    private var standing = Access.undetermined
    private var answer: CheckedContinuation<Bool, Never>?

    var isUp: Bool { lock.withLock { answer != nil } }
    func access() async -> Access { lock.withLock { standing } }
    func request() async -> Bool {
        await withCheckedContinuation { continuation in lock.withLock { answer = continuation } }
    }

    func allow() {
        let held = lock.withLock {
            standing = .granted
            defer { answer = nil }
            return answer
        }
        held?.resume(returning: true)
    }
}

private final class Reminders: ReminderStore, @unchecked Sendable {
    private let lock = NSLock()
    var records: [ReminderRecord] = []
    private var _touched = false
    var touched: Bool { lock.withLock { _touched } }

    func lists() async throws -> [String] { lock.withLock { _touched = true }; return ["Home", "Work"] }
    func reminders(list: String?, done: Bool) async throws -> [ReminderRecord] {
        lock.withLock {
            _touched = true
            return records.filter { $0.done == done && (list == nil || $0.list == list) }
        }
    }
    func add(title: String, list: String?, due: ToolDates.Reading?, notes: String?) async throws -> ReminderRecord {
        guard list == nil || ["Home", "Work"].contains(list!) else { throw ToolFailure("no list called \(list!)") }
        return lock.withLock {
            _touched = true
            let record = ReminderRecord(id: "r\(records.count + 1)", title: title, list: list ?? "Home", due: due, done: false, notes: notes)
            records.append(record)
            return record
        }
    }
    func complete(id: String) async throws -> ReminderRecord {
        try lock.withLock {
            guard let index = records.firstIndex(where: { $0.id == id }) else { throw ToolFailure("no reminder with the id \(id)") }
            records[index].done = true
            return records[index]
        }
    }
}

private final class Events: EventStore, @unchecked Sendable {
    private let lock = NSLock()
    var records: [EventRecord] = []
    var asked: (Date, Date)?

    func calendars() async throws -> [String] { ["Home"] }
    func events(from: Date, to: Date, calendar: String?) async throws -> [EventRecord] {
        lock.withLock {
            asked = (from, to)
            return records.filter { $0.start < to && $0.end > from }
        }
    }
    func add(title: String, start: ToolDates.Reading, end: ToolDates.Reading, allDay: Bool, calendar: String?,
             location: String?, notes: String?) async throws -> EventRecord {
        lock.withLock {
            let record = EventRecord(id: "e\(records.count + 1)", title: title, calendar: calendar ?? "Home",
                                     start: start.date, end: end.date, allDay: allDay, location: location)
            records.append(record)
            return record
        }
    }
}

private final class Scheduler: NotificationScheduler, @unchecked Sendable {
    private let lock = NSLock()
    var scheduled: [PendingNotification] = []
    func schedule(id: String, title: String, body: String?, at: Date) async throws {
        lock.withLock { scheduled.append(PendingNotification(id: id, title: title, due: at)) }
    }
    func pending() async -> [PendingNotification] {
        lock.withLock { scheduled + [PendingNotification(id: "someone-else", title: "not ours", due: nil)] }
    }
    func cancel(id: String) async -> Bool {
        lock.withLock {
            let before = scheduled.count
            scheduled.removeAll { $0.id == id }
            return scheduled.count < before
        }
    }
}

private struct Directory: ContactDirectory {
    let people = [
        ContactRecord(id: "c1", name: "Helen du Rose", phones: ["mobile +44 7700 900123"], emails: ["home helen@example.com"], birthday: "--03-14"),
        ContactRecord(id: "c2", name: "Krista", organization: "Somewhere"),
    ]
    func search(_ query: String) async throws -> [ContactRecord] { people.filter { $0.name.localizedCaseInsensitiveContains(query) } }
    func contact(id: String) async throws -> ContactRecord? { people.first { $0.id == id } }
}

private struct Place: Locator {
    let at: Date
    func fix() async throws -> LocationFix {
        LocationFix(latitude: 37.76, longitude: -122.42, accuracy: 12, at: at, precise: false, place: "Mission District, San Francisco")
    }
}

final class PhoneToolsTests: XCTestCase {
    private let noon = ISO8601DateFormatter().date(from: "2026-09-26T19:00:00Z")!

    // MARK: Permission first

    /// Review focus 12: a refusal says so, and never reaches the store as an empty answer.
    func testADeniedPermissionIsARefusalAndTheStoreIsNeverTouched() async {
        let store = Reminders()
        let tool = RemindersTool(store: store, authorizer: Permission("Reminders", .denied), broker: PermissionBroker())
        let reply = await tool.run([])
        XCTAssertEqual(reply.status, ToolReply.denied)
        XCTAssertTrue(reply.text.contains("not allowed to use Reminders"), reply.text)
        XCTAssertFalse(store.touched)
    }

    func testTheFirstCallAsksAndTheNextDoesNot() async {
        let permission = Permission("Reminders", .undetermined, answer: true)
        let tool = RemindersTool(store: Reminders(), authorizer: permission, broker: PermissionBroker())
        _ = await tool.run([])
        _ = await tool.run(["lists"])
        XCTAssertEqual(permission.prompts, 1)
        let refused = Permission("Contacts", .undetermined, answer: false)
        let contacts = ContactsTool(directory: Directory(), authorizer: refused, broker: PermissionBroker())
        let reply = await contacts.run(["search", "Helen"])
        XCTAssertEqual(reply.status, ToolReply.denied)
        XCTAssertEqual(refused.prompts, 1)
    }

    /// Codex on #214: a call no tool takes is refused before any prompt, so it never raises one.
    func testACallTheToolDoesNotTakeAsksNothing() async {
        let reminders = Permission("Reminders", .undetermined), calendars = Permission("Calendars", .undetermined)
        let notifications = Permission("Notifications", .undetermined), contacts = Permission("Contacts", .undetermined)
        let location = Permission("Location", .undetermined)
        let broker = PermissionBroker()
        let calls: [(any Tool, [String])] = [
            (RemindersTool(store: Reminders(), authorizer: reminders, broker: broker), ["delete", "r1"]),
            (RemindersTool(store: Reminders(), authorizer: reminders, broker: broker), ["add", "x", "--due", "tomorrow"]),
            (CalendarTool(store: Events(), authorizer: calendars, broker: broker), ["--from", "2026-09-28", "--to", "2026-09-27"]),
            (NotifyTool(scheduler: Scheduler(), authorizer: notifications, broker: broker), ["x", "--in", "soon"]),
            (ContactsTool(directory: Directory(), authorizer: contacts, broker: broker), ["delete", "all"]),
            (LocationTool(locator: Place(at: noon), authorizer: location, broker: broker), ["precise"]),
        ]
        for (tool, arguments) in calls {
            let reply = await tool.run(arguments)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(tool.name) \(arguments): \(reply.text)")
        }
        XCTAssertEqual([reminders, calendars, notifications, contacts, location].map(\.prompts), [0, 0, 0, 0, 0])
    }

    /// Codex on #214: the service answers status 4 at its bound by cancelling the call. A prompt
    /// allowed after that stands for the next call, and this one adds nothing, so a retry never
    /// makes a second reminder.
    func testACallCancelledWhileItsPromptIsUpDoesNothingWhenThePersonAllows() async throws {
        let store = Reminders()
        let prompt = HeldPrompt()
        let tool = RemindersTool(store: store, authorizer: prompt, broker: PermissionBroker())
        let call = Task { await tool.run(["add", "Milk"]) }
        for _ in 0..<500 where !prompt.isUp { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(prompt.isUp)
        call.cancel()
        prompt.allow()
        let reply = await call.value
        XCTAssertEqual(reply.status, ToolReply.timedOut, reply.text)
        XCTAssertTrue(store.records.isEmpty)
        let retry = await tool.run(["add", "Milk"])
        XCTAssertEqual(retry.status, ToolReply.ok, retry.text)
        XCTAssertEqual(store.records.map(\.title), ["Milk"])
    }

    // MARK: Confined

    func testConfinedWorkRunsOnItsOwnQueue() async throws {
        let confined = Confined("the store", label: "test.confined")
        let key = DispatchSpecificKey<Int>()
        confined.queue.setSpecific(key: key, value: 1)
        let seen = try await confined.run { value, _ in (value, DispatchQueue.getSpecific(key: key)) }
        XCTAssertEqual(seen.0, "the store")
        XCTAssertEqual(seen.1, 1)
    }

    /// A call cancelled at the bound before the queue reached it never runs.
    func testConfinedWorkCancelledBeforeTheQueueReachesItNeverRuns() async throws {
        let confined = Confined((), label: "test.confined")
        let hold = DispatchSemaphore(value: 0)
        confined.queue.async { hold.wait() }
        let ran = OSAllocatedUnfairLock(initialState: false)
        let call = Task { try await confined.run { _, _ in ran.withLock { $0 = true } } }
        try await Task.sleep(for: .milliseconds(50))
        call.cancel()
        hold.signal()
        do {
            try await call.value
            XCTFail("a cancelled call ran")
        } catch is CancellationError {}
        XCTAssertFalse(ran.withLock { $0 })
    }

    /// A call cancelled while its work was under way stops at the check before it saves.
    func testConfinedWorkCancelledWhileItRunsSavesNothing() async throws {
        let confined = Confined((), label: "test.confined")
        let started = OSAllocatedUnfairLock(initialState: false), saved = OSAllocatedUnfairLock(initialState: false)
        let proceed = DispatchSemaphore(value: 0)
        let call = Task {
            try await confined.run { _, cancellation in
                started.withLock { $0 = true }
                proceed.wait()
                try cancellation.check()
                saved.withLock { $0 = true }
            }
        }
        for _ in 0..<500 where !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        call.cancel()
        proceed.signal()
        do {
            try await call.value
            XCTFail("a cancelled call saved")
        } catch is CancellationError {}
        XCTAssertFalse(saved.withLock { $0 })
    }

    // MARK: Reminders

    func testRemindersAddListAndMarkDone() async {
        let store = Reminders()
        let tool = RemindersTool(store: store, authorizer: Permission(), broker: PermissionBroker())
        let added = await tool.run(["add", "Buy oat milk", "--list", "Home", "--due", "2026-09-27", "--notes", "the barista one"])
        XCTAssertEqual(added.status, ToolReply.ok, added.text)
        XCTAssertEqual(added.text, "added: r1 | Buy oat milk | Home | due 2026-09-27 | notes: the barista one\n")
        _ = await tool.run(["add", "Call Helen", "--due", "2026-09-26T18:00"])
        let listed = await tool.run([])
        XCTAssertEqual(listed.text.split(separator: "\n").first.map(String.init), "r2 | Call Helen | Home | due \(ToolDates.write(ToolDates.read("2026-09-26T18:00")!.date))")
        let before = await tool.run(["--due-before", "2026-09-27"])
        XCTAssertFalse(before.text.contains("oat milk"))
        let done = await tool.run(["done", "r1"])
        XCTAssertEqual(done.status, ToolReply.ok)
        XCTAssertTrue(done.text.hasSuffix("| done | notes: the barista one\n"), done.text)
        let reply1 = await tool.run([])
        XCTAssertFalse(reply1.text.contains("oat milk"))
        let reply2 = await tool.run(["--done"])
        XCTAssertTrue(reply2.text.contains("oat milk"))
    }

    func testRemindersRefuseWhatTheyDoNotTake() async {
        let tool = RemindersTool(store: Reminders(), authorizer: Permission(), broker: PermissionBroker())
        for arguments in [["add"], ["add", "a", "b"], ["done"], ["delete", "r1"], ["--colour", "red"], ["add", "x", "--due", "tomorrow"]] {
            let reply = await tool.run(arguments)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(arguments): \(reply.text)")
        }
        let missing = await tool.run(["done", "r9"])
        XCTAssertEqual(missing.status, ToolReply.failed)
        XCTAssertEqual(missing.text, "topo: no reminder with the id r9\n")
        let list = await tool.run(["add", "x", "--list", "Nowhere"])
        XCTAssertEqual(list.status, ToolReply.failed)
    }

    /// Codex on #214: `--notes --done` is `--notes` missing its value, not a note reading "--done".
    func testAnOptionIsNeverTheValueOfTheOneBeforeIt() async {
        let store = Reminders()
        let tool = RemindersTool(store: store, authorizer: Permission(), broker: PermissionBroker())
        let reply = await tool.run(["add", "Milk", "--notes", "--done"])
        XCTAssertEqual(reply.status, ToolReply.usage, reply.text)
        XCTAssertTrue(reply.text.hasPrefix("topo: --notes needs a value\n"), reply.text)
        XCTAssertFalse(store.touched)
    }

    /// Codex on #214: an option one form takes is refused by the others, not ignored.
    func testAnOptionForAnotherFormIsRefusedNotIgnored() async {
        let store = Reminders()
        let reminders = RemindersTool(store: store, authorizer: Permission(), broker: PermissionBroker())
        for arguments in [["add", "Milk", "--due-before", "2026-09-28"], ["add", "Milk", "--done"], ["--due", "2026-09-28"],
                          ["--notes", "x"], ["lists", "--list", "Home"], ["done", "r1", "--notes", "x"], ["list", "extra"]] {
            let reply = await reminders.run(arguments)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(arguments): \(reply.text)")
        }
        XCTAssertFalse(store.touched)
        let refused = await reminders.run(["add", "Milk", "--due-before", "2026-09-28"])
        XCTAssertTrue(refused.text.hasPrefix("topo: reminders add takes no --due-before\n"), refused.text)

        let events = Events()
        let calendar = CalendarTool(store: events, authorizer: Permission("Calendars"), broker: PermissionBroker())
        for arguments in [["--start", "2026-09-28"], ["--all-day"], ["calendars", "--from", "2026-09-28"],
                          ["add", "x", "--start", "2026-09-28", "--end", "2026-09-28", "--from", "2026-09-28"]] {
            let reply = await calendar.run(arguments)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(arguments): \(reply.text)")
        }
        XCTAssertNil(events.asked)
        XCTAssertTrue(events.records.isEmpty)

        let scheduler = Scheduler()
        let notify = NotifyTool(scheduler: scheduler, authorizer: Permission("Notifications"), broker: PermissionBroker())
        for arguments in [["list", "--in", "5m"], ["cancel", "topo-abc", "--at", "2026-09-28T10:00"]] {
            let reply = await notify.run(arguments)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(arguments): \(reply.text)")
        }
    }

    // MARK: Calendar

    func testCalendarDefaultsToTheWeekAheadAndAdds() async {
        let store = Events()
        let now = noon
        let tool = CalendarTool(store: store, authorizer: Permission("Calendars"), broker: PermissionBroker(), now: { now })
        let reply3 = await tool.run([])
        XCTAssertEqual(reply3.text, "no events\n")
        XCTAssertEqual(store.asked?.0, now)
        XCTAssertEqual(store.asked?.1, now.addingTimeInterval(7 * 86400))
        let added = await tool.run(["add", "Dentist", "--start", "2026-09-28T09:00", "--end", "2026-09-28T10:00", "--location", "Valencia St"])
        XCTAssertEqual(added.status, ToolReply.ok, added.text)
        XCTAssertTrue(added.text.hasPrefix("added: e1 | Dentist | "), added.text)
        XCTAssertTrue(added.text.hasSuffix("| Home | at Valencia St\n"), added.text)
        let days = await tool.run(["add", "Helen visits", "--start", "2026-09-29", "--end", "2026-09-30"])
        XCTAssertTrue(days.text.hasPrefix("added: e2 | Helen visits | all day 2026-09-29 to 2026-09-30 | "), days.text)
        XCTAssertTrue(store.records[1].allDay)
        let listed = await tool.run(["--from", "2026-09-28", "--to", "2026-10-01"])
        XCTAssertEqual(listed.text.split(separator: "\n").count, 2)
    }

    func testCalendarRefusesABackwardsOrEndlessSpan() async {
        let store = Events()
        let tool = CalendarTool(store: store, authorizer: Permission("Calendars"), broker: PermissionBroker())
        for arguments in [["--from", "2026-09-28", "--to", "2026-09-27"], ["--from", "2026-01-01", "--to", "2028-01-01"],
                          ["add", "x", "--start", "2026-09-28T10:00"], ["add", "x", "--start", "2026-09-28T10:00", "--end", "2026-09-28T09:00"],
                          ["add", "x", "--start", "2026-09-30", "--end", "2026-09-29"],
                          ["add", "x", "--all-day", "--start", "2026-09-30T09:00", "--end", "2026-09-29T23:00"]] {
            let reply = await tool.run(arguments)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(arguments)")
        }
        XCTAssertTrue(store.records.isEmpty)
    }

    /// Codex on #214: the most is a calendar year, not 366 days. 2026 is not a leap year, so 366
    /// days from its first day is a day past a year.
    func testCalendarsLongestSpanIsACalendarYear() async {
        let store = Events()
        let tool = CalendarTool(store: store, authorizer: Permission("Calendars"), broker: PermissionBroker())
        let over = await tool.run(["--from", "2026-01-01", "--to", "2027-01-02"])
        XCTAssertEqual(over.status, ToolReply.usage, over.text)
        XCTAssertNil(store.asked)
        let year = await tool.run(["--from", "2026-01-01", "--to", "2027-01-01"])
        XCTAssertEqual(year.status, ToolReply.ok, year.text)
        let leap = await tool.run(["--from", "2027-03-01", "--to", "2028-03-01"])
        XCTAssertEqual(leap.status, ToolReply.ok, leap.text)
    }

    /// Codex on #214: an all-day --end names the last day, so one day is --start and --end the
    /// same day, and the store is given midnight to the midnight after it — never a zero-length
    /// event said as ending the day before it starts.
    func testAnAllDayEventRunsThroughItsEndDay() async throws {
        let store = Events()
        let tool = CalendarTool(store: store, authorizer: Permission("Calendars"), broker: PermissionBroker())
        let one = await tool.run(["add", "Holiday", "--start", "2026-09-29", "--end", "2026-09-29"])
        XCTAssertEqual(one.status, ToolReply.ok, one.text)
        XCTAssertEqual(one.text, "added: e1 | Holiday | all day 2026-09-29 | Home\n")
        let record = try XCTUnwrap(store.records.first)
        let days = Calendar.current
        XCTAssertEqual(record.start, try XCTUnwrap(ToolDates.read("2026-09-29")).date)
        XCTAssertEqual(record.end, days.date(byAdding: .day, value: 1, to: record.start))
        let flagged = await tool.run(["add", "Trip", "--all-day", "--start", "2026-10-02T09:00", "--end", "2026-10-04T08:00"])
        XCTAssertEqual(flagged.text, "added: e2 | Trip | all day 2026-10-02 to 2026-10-04 | Home\n")
    }

    // MARK: Notify

    func testNotifySchedulesListsAndCancelsOnlyItsOwn() async {
        let scheduler = Scheduler()
        let now = noon
        let tool = NotifyTool(scheduler: scheduler, authorizer: Permission("Notifications"), broker: PermissionBroker(),
                              now: { now }, makeID: { "topo-abc" })
        let later = await tool.run(["Stretch", "Your back will thank you", "--in", "15m"])
        XCTAssertEqual(later.status, ToolReply.ok, later.text)
        XCTAssertEqual(scheduler.scheduled.first?.due, now.addingTimeInterval(900))
        let listed = await tool.run(["list"])
        XCTAssertEqual(listed.text, "topo-abc | Stretch | at \(ToolDates.write(now.addingTimeInterval(900)))\n")
        let reply4 = await tool.run(["cancel", "someone-else"])
        XCTAssertEqual(reply4.status, ToolReply.failed)
        let reply5 = await tool.run(["cancel", "topo-abc"])
        XCTAssertEqual(reply5.text, "cancelled: topo-abc\n")
        let reply6 = await tool.run(["Past", "--at", "2026-09-26T10:00:00Z"])
        XCTAssertEqual(reply6.status, ToolReply.usage)
        let reply7 = await tool.run(["x", "--at", "2026-09-27T10:00", "--in", "5m"])
        XCTAssertEqual(reply7.status, ToolReply.usage)
        let reply8 = await tool.run(["x", "--in", "soon"])
        XCTAssertEqual(reply8.status, ToolReply.usage)
        let reply9 = await tool.run([])
        XCTAssertEqual(reply9.status, ToolReply.usage)
    }

    // MARK: Contacts and location

    func testContactsSearchAndShow() async {
        let tool = ContactsTool(directory: Directory(), authorizer: Permission("Contacts"), broker: PermissionBroker())
        let reply10 = await tool.run(["search", "helen"])
        XCTAssertEqual(reply10.text,
                       "c1 | Helen du Rose | mobile +44 7700 900123 | home helen@example.com\n")
        let reply11 = await tool.run(["search", "nobody"])
        XCTAssertEqual(reply11.text, "nobody found for nobody\n")
        let reply12 = await tool.run(["show", "c1"])
        XCTAssertEqual(reply12.text,
                       "name: Helen du Rose\nphone: mobile +44 7700 900123\nemail: home helen@example.com\nbirthday: --03-14\n")
        let reply13 = await tool.run(["show", "c9"])
        XCTAssertEqual(reply13.status, ToolReply.failed)
        let reply14 = await tool.run(["add", "someone"])
        XCTAssertEqual(reply14.status, ToolReply.usage)
    }

    /// Codex on #214: the adapter sends a phone number to Contacts' phone matcher and an address
    /// to its email matcher, not both to the name matcher the fake stands for. Whether Contacts
    /// then finds the person is the device's to show.
    func testContactsSearchSendsNumbersAndAddressesToTheirMatchers() {
        for query in ["+44 7700 900123", "07700 900123", "(415) 555-0100", "415-555-0100", "+447700900123"] {
            XCTAssertEqual(ContactStoreDirectory.match(for: query), .phone, query)
        }
        for query in ["helen@example.com", "Helen@Example.COM"] {
            XCTAssertEqual(ContactStoreDirectory.match(for: query), .email, query)
        }
        for query in ["helen", "Helen du Rose", "Flat 4", "Apartment 12B"] {
            XCTAssertEqual(ContactStoreDirectory.match(for: query), .name, query)
        }
    }

    func testLocationSaysHowGoodTheFixIs() async {
        let now = noon
        let tool = LocationTool(locator: Place(at: now.addingTimeInterval(-3)), authorizer: Permission("Location"),
                                broker: PermissionBroker(), now: { now })
        let reply = await tool.run([])
        XCTAssertEqual(reply.status, ToolReply.ok)
        XCTAssertTrue(reply.text.hasPrefix("latitude 37.76000\nlongitude -122.42000\naccuracy 12 m (approximate"), reply.text)
        XCTAssertTrue(reply.text.contains("(3 s ago)"), reply.text)
        XCTAssertTrue(reply.text.hasSuffix("place Mission District, San Francisco\n"), reply.text)
        let reply15 = await tool.run(["precise"])
        XCTAssertEqual(reply15.status, ToolReply.usage)
    }

    /// Review focus 9's other half: making the tools asks for nothing, so launch raises no prompt.
    /// Each prompt is raised only through the broker, from a call.
    func testMakingTheToolsAsksNothing() async {
        let permissions = ["Reminders", "Calendars", "Notifications", "Contacts", "Location"].map { Permission($0, .undetermined) }
        let broker = PermissionBroker()
        _ = RemindersTool(store: Reminders(), authorizer: permissions[0], broker: broker)
        _ = CalendarTool(store: Events(), authorizer: permissions[1], broker: broker)
        _ = NotifyTool(scheduler: Scheduler(), authorizer: permissions[2], broker: broker)
        _ = ContactsTool(directory: Directory(), authorizer: permissions[3], broker: broker)
        _ = LocationTool(locator: Place(at: noon), authorizer: permissions[4], broker: broker)
        XCTAssertEqual(permissions.map(\.prompts), [0, 0, 0, 0, 0])
    }

    /// Codex on #214: a notification that comes due with the app in front is shown, which iOS does
    /// only when the app's notification delegate says so. The host app's launch has run, so the
    /// delegate is what the running app installed. That iOS then draws the banner is the device's
    /// to show.
    @MainActor
    func testANotificationDueWithTheAppInFrontIsShown() throws {
        let delegate = try XCTUnwrap(UNUserNotificationCenter.current().delegate as? TopoAppDelegate)
        XCTAssertTrue(delegate.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))))
        XCTAssertEqual(TopoAppDelegate.inFront, [.banner, .list, .sound])
    }
}
