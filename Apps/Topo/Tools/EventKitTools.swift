import EventKit
import Foundation
import TopoTools

// MARK: - Reminders

struct ReminderRecord: Sendable, Equatable {
    var id: String
    var title: String
    var list: String
    var due: ToolDates.Reading?
    var done: Bool
    var notes: String?
}

/// The person's reminders, as `topo reminders` reaches them: EventKit on the phone
/// (`EventKitStore`), a fake in the suites.
protocol ReminderStore: Sendable {
    func lists() async throws -> [String]
    /// Incomplete ones unless `done`, then completed ones; in one list when named.
    func reminders(list: String?, done: Bool) async throws -> [ReminderRecord]
    func add(title: String, list: String?, due: ToolDates.Reading?, notes: String?) async throws -> ReminderRecord
    /// Marks one complete: the one mutation of an existing record any tool makes.
    func complete(id: String) async throws -> ReminderRecord
}

/// `topo reminders`: the person's reminders — read, added, and marked done. Nothing is deleted or
/// edited.
struct RemindersTool: Tool {
    let store: any ReminderStore
    let authorizer: any Authorizer
    let broker: PermissionBroker

    let name = "reminders"
    let summary = "the person's reminders: list them, add one, mark one done"
    let usage = """
    topo reminders [--list NAME] [--due-before DATE] [--done]
                                        the reminders not yet done (with --done, the ones done), one a line, id first
    topo reminders lists                the lists
    topo reminders add TITLE [--list NAME] [--due DATE] [--notes TEXT]
                                        add one (to the default list unless --list names one)
    topo reminders done ID              mark one done

    DATE is 2026-09-27 (a day), 2026-09-27T14:30 (the phone's time zone) or 2026-09-27T14:30:00-07:00.
    """

    enum Call: Equatable {
        case reminders(list: String?, before: Date?, done: Bool)
        case lists
        case add(title: String, list: String?, due: ToolDates.Reading?, notes: String?)
        case done(id: String)
    }

    func run(_ arguments: [String]) async -> ToolReply {
        await PhoneTool.run(authorizer, broker: broker, usage: usage, parse: { try parse(arguments) }) { call in
            switch call {
            case let .reminders(list, before, done):
                var records = try await store.reminders(list: list, done: done)
                if let before {
                    records = records.filter { ($0.due?.date).map { $0 < before } ?? false }
                }
                records.sort { ($0.due?.date ?? .distantFuture, $0.title) < ($1.due?.date ?? .distantFuture, $1.title) }
                return .ok(PhoneTool.lines(records.map(Self.line), none: "no reminders"))
            case .lists:
                return .ok(PhoneTool.lines(try await store.lists(), none: "no lists"))
            case let .add(title, list, due, notes):
                return .ok("added: " + Self.line(try await store.add(title: title, list: list, due: due, notes: notes)) + "\n")
            case let .done(id):
                return .ok("done: " + Self.line(try await store.complete(id: id)) + "\n")
            }
        }
    }

    /// The call the arguments make, or why they make none: nothing here needs the permission.
    func parse(_ arguments: [String]) throws -> Call {
        let parsed = try Arguments(arguments, options: ["list", "due-before", "due", "notes"], flags: ["done"])
        switch parsed.words.first {
        case nil, "list":
            guard parsed.words.count <= 1 else { throw Misuse("reminders takes no \(parsed.words[1])") }
            try parsed.only(["list", "due-before", "done"], for: "reminders")
            return .reminders(list: parsed.options["list"], before: try PhoneTool.date(parsed.options["due-before"], "--due-before")?.date,
                              done: parsed.flags.contains("done"))
        case "lists":
            guard parsed.words.count == 1 else { throw Misuse("reminders lists takes no \(parsed.words[1])") }
            try parsed.only([], for: "reminders lists")
            return .lists
        case "add":
            guard parsed.words.count == 2, !parsed.words[1].isEmpty else { throw Misuse("reminders add takes one title") }
            try parsed.only(["list", "due", "notes"], for: "reminders add")
            return .add(title: parsed.words[1], list: parsed.options["list"], due: try PhoneTool.date(parsed.options["due"], "--due"),
                        notes: parsed.options["notes"])
        case "done":
            guard parsed.words.count == 2 else { throw Misuse("reminders done takes one id") }
            try parsed.only([], for: "reminders done")
            return .done(id: parsed.words[1])
        case let other?:
            throw Misuse("reminders: no \(other)")
        }
    }

    static func line(_ record: ReminderRecord) -> String {
        PhoneTool.line([record.id, record.title, record.list, due(record.due), record.done ? "done" : nil,
                        record.notes.map { "notes: " + $0.replacingOccurrences(of: "\n", with: " ") }])
    }

    static func due(_ due: ToolDates.Reading?) -> String {
        guard let due else { return "no due date" }
        return "due " + (due.hasTime ? ToolDates.write(due.date) : ToolDates.day(due.date))
    }
}

// MARK: - Calendar

struct EventRecord: Sendable, Equatable {
    var id: String
    var title: String
    var calendar: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String?
}

protocol EventStore: Sendable {
    func calendars() async throws -> [String]
    func events(from: Date, to: Date, calendar: String?) async throws -> [EventRecord]
    /// An all-day event's `start` is its first day's midnight and its `end` the midnight after its
    /// last day.
    func add(title: String, start: ToolDates.Reading, end: ToolDates.Reading, allDay: Bool, calendar: String?,
             location: String?, notes: String?) async throws -> EventRecord
}

/// `topo calendar`: the person's calendar — read, and added to. Nothing is deleted or edited.
struct CalendarTool: Tool {
    let store: any EventStore
    let authorizer: any Authorizer
    let broker: PermissionBroker
    var now: @Sendable () -> Date = { Date() }

    let name = "calendar"
    let summary = "the person's calendar: the events in a span, the calendars, add an event"
    let usage = """
    topo calendar [--from DATE] [--to DATE] [--calendar NAME]
                                        the events from --from (now) to --to (a week later, a year at most), one a line, id first
    topo calendar calendars             the calendars
    topo calendar add TITLE --start DATE --end DATE [--all-day] [--calendar NAME] [--location TEXT] [--notes TEXT]
                                        add one (to the default calendar unless --calendar names one)

    DATE is 2026-09-27 (a day), 2026-09-27T14:30 (the phone's time zone) or 2026-09-27T14:30:00-07:00.
    An all-day event (both DATEs days, or --all-day) runs from --start's day through --end's day:
    --start 2026-09-29 --end 2026-09-29 is the one day.
    """

    enum Call: Equatable {
        case events(from: Date, to: Date, calendar: String?)
        case calendars
        /// An all-day event's `start` is its first day's midnight and its `end` the midnight after
        /// its last day.
        case add(title: String, start: ToolDates.Reading, end: ToolDates.Reading, allDay: Bool, calendar: String?,
                 location: String?, notes: String?)
    }

    func run(_ arguments: [String]) async -> ToolReply {
        await PhoneTool.run(authorizer, broker: broker, usage: usage, parse: { try parse(arguments) }) { call in
            switch call {
            case let .events(from, to, calendar):
                let events = try await store.events(from: from, to: to, calendar: calendar)
                    .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
                return .ok(PhoneTool.lines(events.map(Self.line), none: "no events"))
            case .calendars:
                return .ok(PhoneTool.lines(try await store.calendars(), none: "no calendars"))
            case let .add(title, start, end, allDay, calendar, location, notes):
                let record = try await store.add(title: title, start: start, end: end, allDay: allDay, calendar: calendar,
                                                 location: location, notes: notes)
                return .ok("added: " + Self.line(record) + "\n")
            }
        }
    }

    /// The call the arguments make, or why they make none: nothing here needs the permission.
    func parse(_ arguments: [String]) throws -> Call {
        let parsed = try Arguments(arguments, options: ["from", "to", "calendar", "start", "end", "location", "notes"],
                                   flags: ["all-day"])
        let days = Calendar.current
        switch parsed.words.first {
        case nil, "events":
            guard parsed.words.count <= 1 else { throw Misuse("calendar takes no \(parsed.words[1])") }
            try parsed.only(["from", "to", "calendar"], for: "calendar")
            let from = try PhoneTool.date(parsed.options["from"], "--from")?.date ?? now()
            let to = try PhoneTool.date(parsed.options["to"], "--to")?.date ?? from.addingTimeInterval(7 * 86400)
            guard to > from else { throw ToolFailure("--to has to be after --from", status: ToolReply.usage) }
            // A calendar year, leap day and all: 2026-01-01 to 2027-01-01 and no further.
            guard let limit = days.date(byAdding: .year, value: 1, to: from), to <= limit else {
                throw ToolFailure("a span of at most a year, please", status: ToolReply.usage)
            }
            return .events(from: from, to: to, calendar: parsed.options["calendar"])
        case "calendars":
            guard parsed.words.count == 1 else { throw Misuse("calendar calendars takes no \(parsed.words[1])") }
            try parsed.only([], for: "calendar calendars")
            return .calendars
        case "add":
            guard parsed.words.count == 2, !parsed.words[1].isEmpty else { throw Misuse("calendar add takes one title") }
            try parsed.only(["start", "end", "all-day", "calendar", "location", "notes"], for: "calendar add")
            guard let start = try PhoneTool.date(parsed.options["start"], "--start"),
                  let end = try PhoneTool.date(parsed.options["end"], "--end") else {
                throw Misuse("calendar add needs --start and --end")
            }
            let title = parsed.words[1], calendar = parsed.options["calendar"]
            let location = parsed.options["location"], notes = parsed.options["notes"]
            if parsed.flags.contains("all-day") || (!start.hasTime && !end.hasTime) {
                return try Self.allDay(title, start, end, calendar, location, notes)
            }
            guard end.date >= start.date else { throw ToolFailure("--end is before --start", status: ToolReply.usage) }
            return .add(title: title, start: start, end: end, allDay: false, calendar: calendar, location: location, notes: notes)
        case let other?:
            throw Misuse("calendar: no \(other)")
        }
    }

    /// From `start`'s day through `end`'s, as midnight to the midnight after the last day.
    private static func allDay(_ title: String, _ start: ToolDates.Reading, _ end: ToolDates.Reading, _ calendar: String?,
                               _ location: String?, _ notes: String?) throws -> Call {
        let days = Calendar.current
        let first = days.startOfDay(for: start.date), last = days.startOfDay(for: end.date)
        guard last >= first else { throw ToolFailure("--end's day is before --start's", status: ToolReply.usage) }
        guard let after = days.date(byAdding: .day, value: 1, to: last) else {
            throw ToolFailure("no day after \(ToolDates.day(last))", status: ToolReply.usage)
        }
        return .add(title: title, start: ToolDates.Reading(date: first, hasTime: false), end: ToolDates.Reading(date: after, hasTime: false),
                    allDay: true, calendar: calendar, location: location, notes: notes)
    }

    static func line(_ event: EventRecord) -> String {
        let when = event.allDay
            ? "all day " + ToolDates.day(event.start) + (Calendar.current.isDate(event.start, inSameDayAs: event.end.addingTimeInterval(-1)) ? "" : " to " + ToolDates.day(event.end.addingTimeInterval(-1)))
            : ToolDates.write(event.start) + " to " + ToolDates.write(event.end)
        return PhoneTool.line([event.id, event.title, when, event.calendar, event.location.map { "at " + $0 }])
    }
}

// MARK: - EventKit

/// Reminders or Calendars, as EventKit stands them: only full access is access, since every tool
/// reads; write-only is a refusal.
struct EventKitAuthorizer: Authorizer {
    let entity: EKEntityType
    let store: EventKitStore

    var name: String { entity == .reminder ? "Reminders" : "Calendars" }

    func access() async -> Access {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .fullAccess: .granted
        case .notDetermined: .undetermined
        case .restricted: .restricted
        default: .denied
        }
    }

    func request() async -> Bool {
        await store.requestFullAccess(to: entity)
    }
}

/// The one `EKEventStore`, which both tools share, reachable only through `Confined`: its fetches
/// and saves block, so they run on a queue of their own, never the cooperative pool, and a save
/// whose call was cancelled at the service's bound is not made.
final class EventKitStore: ReminderStore, EventStore, Sendable {
    private let confined = Confined(EKEventStore(), label: "zone.hexagon.topo.eventkit")

    func requestFullAccess(to entity: EKEntityType) async -> Bool {
        await withCheckedContinuation { continuation in
            confined.async { store in
                let answer: @Sendable (Bool, (any Error)?) -> Void = { granted, _ in continuation.resume(returning: granted) }
                if entity == .reminder {
                    store.requestFullAccessToReminders(completion: answer)
                } else {
                    store.requestFullAccessToEvents(completion: answer)
                }
            }
        }
    }

    private static func calendar(named name: String?, for entity: EKEntityType, in store: EKEventStore) throws -> EKCalendar {
        let calendars = store.calendars(for: entity)
        if let name {
            guard let found = calendars.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw ToolFailure("no \(entity == .reminder ? "list" : "calendar") called \(name); there are \(calendars.map(\.title).joined(separator: ", "))")
            }
            return found
        }
        let fallback = entity == .reminder ? store.defaultCalendarForNewReminders() : store.defaultCalendarForNewEvents
        guard let fallback else { throw ToolFailure("this phone has no default \(entity == .reminder ? "list" : "calendar")") }
        return fallback
    }

    // Reminders

    func lists() async throws -> [String] {
        try await confined.run { store, _ in store.calendars(for: .reminder).map(\.title).sorted() }
    }

    func reminders(list: String?, done: Bool) async throws -> [ReminderRecord] {
        try await withCheckedThrowingContinuation { continuation in
            confined.async { store in
                do {
                    let calendars = try list.map { [try Self.calendar(named: $0, for: .reminder, in: store)] }
                    let predicate = done
                        ? store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: calendars)
                        : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
                    store.fetchReminders(matching: predicate) { reminders in
                        continuation.resume(returning: (reminders ?? []).map(Self.record))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func add(title: String, list: String?, due: ToolDates.Reading?, notes: String?) async throws -> ReminderRecord {
        try await confined.run { store, cancellation in
            let reminder = EKReminder(eventStore: store)
            reminder.title = title
            reminder.calendar = try Self.calendar(named: list, for: .reminder, in: store)
            reminder.notes = notes
            if let due {
                let units: Set<Calendar.Component> = due.hasTime ? [.year, .month, .day, .hour, .minute, .timeZone] : [.year, .month, .day]
                reminder.dueDateComponents = Calendar.current.dateComponents(units, from: due.date)
            }
            try cancellation.check()
            try store.save(reminder, commit: true)
            return Self.record(reminder)
        }
    }

    func complete(id: String) async throws -> ReminderRecord {
        try await confined.run { store, cancellation in
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
                throw ToolFailure("no reminder with the id \(id)")
            }
            reminder.isCompleted = true
            try cancellation.check()
            try store.save(reminder, commit: true)
            return Self.record(reminder)
        }
    }

    static func record(_ reminder: EKReminder) -> ReminderRecord {
        var due: ToolDates.Reading?
        if let components = reminder.dueDateComponents, let date = Calendar.current.date(from: components) {
            due = ToolDates.Reading(date: date, hasTime: components.hour != nil)
        }
        return ReminderRecord(id: reminder.calendarItemIdentifier, title: reminder.title ?? "", list: reminder.calendar?.title ?? "",
                              due: due, done: reminder.isCompleted, notes: reminder.notes)
    }

    // Calendar

    func calendars() async throws -> [String] {
        try await confined.run { store, _ in store.calendars(for: .event).map(\.title).sorted() }
    }

    func events(from: Date, to: Date, calendar: String?) async throws -> [EventRecord] {
        try await confined.run { store, _ in
            let calendars = try calendar.map { [try Self.calendar(named: $0, for: .event, in: store)] }
            let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
            return store.events(matching: predicate).map(Self.record)
        }
    }

    func add(title: String, start: ToolDates.Reading, end: ToolDates.Reading, allDay: Bool, calendar: String?,
             location: String?, notes: String?) async throws -> EventRecord {
        try await confined.run { store, cancellation in
            let event = EKEvent(eventStore: store)
            event.title = title
            event.calendar = try Self.calendar(named: calendar, for: .event, in: store)
            event.startDate = start.date
            // EventKit ends an all-day event on the last second of its last day.
            event.endDate = allDay ? end.date.addingTimeInterval(-1) : end.date
            event.isAllDay = allDay
            event.location = location
            event.notes = notes
            try cancellation.check()
            try store.save(event, span: .thisEvent, commit: true)
            return Self.record(event)
        }
    }

    static func record(_ event: EKEvent) -> EventRecord {
        EventRecord(id: event.calendarItemIdentifier, title: event.title ?? "", calendar: event.calendar?.title ?? "",
                    start: event.startDate, end: event.endDate, allDay: event.isAllDay, location: event.location)
    }
}
