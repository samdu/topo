import Foundation
import TopoTools
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
        let day = await tool.run(["add", "Helen visits", "--start", "2026-09-29", "--end", "2026-09-30"])
        XCTAssertTrue(day.text.contains("all day 2026-09-29"), day.text)
        XCTAssertTrue(store.records[1].allDay)
        let listed = await tool.run(["--from", "2026-09-28", "--to", "2026-10-01"])
        XCTAssertEqual(listed.text.split(separator: "\n").count, 2)
    }

    func testCalendarRefusesABackwardsOrEndlessSpan() async {
        let tool = CalendarTool(store: Events(), authorizer: Permission("Calendars"), broker: PermissionBroker())
        for arguments in [["--from", "2026-09-28", "--to", "2026-09-27"], ["--from", "2026-01-01", "--to", "2028-01-01"],
                          ["add", "x", "--start", "2026-09-28T10:00"], ["add", "x", "--start", "2026-09-28T10:00", "--end", "2026-09-28T09:00"]] {
            let reply = await tool.run(arguments)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(arguments)")
        }
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
}
