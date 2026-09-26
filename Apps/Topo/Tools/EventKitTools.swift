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

    func run(_ arguments: [String]) async -> ToolReply {
        await PhoneTool.run(authorizer, broker: broker, usage: usage) {
            let parsed = try Arguments(arguments, options: ["list", "due-before", "due", "notes"], flags: ["done"])
            switch parsed.words.first {
            case nil, "list":
                guard parsed.options["due"] == nil, parsed.options["notes"] == nil else { throw Arguments.Refusal.unknown("--due or --notes") }
                let before = try PhoneTool.date(parsed.options["due-before"], "--due-before")
                var records = try await store.reminders(list: parsed.options["list"], done: parsed.flags.contains("done"))
                if let before {
                    records = records.filter { ($0.due?.date).map { $0 < before.date } ?? false }
                }
                records.sort { ($0.due?.date ?? .distantFuture, $0.title) < ($1.due?.date ?? .distantFuture, $1.title) }
                return .ok(PhoneTool.lines(records.map(Self.line), none: "no reminders"))
            case "lists":
                return .ok(PhoneTool.lines(try await store.lists(), none: "no lists"))
            case "add":
                guard parsed.words.count == 2, !parsed.words[1].isEmpty else {
                    return .usage("topo reminders add takes one title\n\n\(usage)\n")
                }
                let due = try PhoneTool.date(parsed.options["due"], "--due")
                let record = try await store.add(title: parsed.words[1], list: parsed.options["list"], due: due,
                                                 notes: parsed.options["notes"])
                return .ok("added: " + Self.line(record) + "\n")
            case "done":
                guard parsed.words.count == 2 else { return .usage("topo reminders done takes one id\n\n\(usage)\n") }
                return .ok("done: " + Self.line(try await store.complete(id: parsed.words[1])) + "\n")
            case let other?:
                return .usage("topo reminders: no \(other)\n\n\(usage)\n")
            }
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
                                        the events from --from (now) to --to (a week later), one a line, id first
    topo calendar calendars             the calendars
    topo calendar add TITLE --start DATE --end DATE [--all-day] [--calendar NAME] [--location TEXT] [--notes TEXT]
                                        add one (to the default calendar unless --calendar names one)

    DATE is 2026-09-27 (a day), 2026-09-27T14:30 (the phone's time zone) or 2026-09-27T14:30:00-07:00.
    """

    func run(_ arguments: [String]) async -> ToolReply {
        await PhoneTool.run(authorizer, broker: broker, usage: usage) {
            let parsed = try Arguments(arguments, options: ["from", "to", "calendar", "start", "end", "location", "notes"],
                                       flags: ["all-day"])
            switch parsed.words.first {
            case nil, "events":
                let from = try PhoneTool.date(parsed.options["from"], "--from")?.date ?? now()
                let to = try PhoneTool.date(parsed.options["to"], "--to")?.date ?? from.addingTimeInterval(7 * 86400)
                guard to > from else { throw ToolFailure("--to has to be after --from", status: ToolReply.usage) }
                guard to.timeIntervalSince(from) <= 366 * 86400 else {
                    throw ToolFailure("a span of at most a year, please", status: ToolReply.usage)
                }
                let events = try await store.events(from: from, to: to, calendar: parsed.options["calendar"])
                    .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
                return .ok(PhoneTool.lines(events.map(Self.line), none: "no events"))
            case "calendars":
                return .ok(PhoneTool.lines(try await store.calendars(), none: "no calendars"))
            case "add":
                guard parsed.words.count == 2, !parsed.words[1].isEmpty else {
                    return .usage("topo calendar add takes one title\n\n\(usage)\n")
                }
                guard let start = try PhoneTool.date(parsed.options["start"], "--start"),
                      let end = try PhoneTool.date(parsed.options["end"], "--end") else {
                    return .usage("topo calendar add needs --start and --end\n\n\(usage)\n")
                }
                let allDay = parsed.flags.contains("all-day") || (!start.hasTime && !end.hasTime)
                guard end.date >= start.date else { throw ToolFailure("--end is before --start", status: ToolReply.usage) }
                let record = try await store.add(title: parsed.words[1], start: start, end: end, allDay: allDay,
                                                 calendar: parsed.options["calendar"], location: parsed.options["location"],
                                                 notes: parsed.options["notes"])
                return .ok("added: " + Self.line(record) + "\n")
            case let other?:
                return .usage("topo calendar: no \(other)\n\n\(usage)\n")
            }
        }
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
        do {
            return entity == .reminder ? try await store.store.requestFullAccessToReminders()
                                       : try await store.store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }
}

/// The one `EKEventStore`, which both tools share. Its fetches run on queues of their own, never
/// the cooperative pool: `events(matching:)` is synchronous.
final class EventKitStore: ReminderStore, EventStore, @unchecked Sendable {
    let store = EKEventStore()
    private let queue = DispatchQueue(label: "zone.hexagon.topo.eventkit")

    private func off<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private func calendar(named name: String?, for entity: EKEntityType) throws -> EKCalendar {
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
        try await off { self.store.calendars(for: .reminder).map(\.title).sorted() }
    }

    func reminders(list: String?, done: Bool) async throws -> [ReminderRecord] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let calendars = try list.map { [try self.calendar(named: $0, for: .reminder)] }
                    let predicate = done
                        ? self.store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: calendars)
                        : self.store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
                    self.store.fetchReminders(matching: predicate) { reminders in
                        continuation.resume(returning: (reminders ?? []).map(Self.record))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func add(title: String, list: String?, due: ToolDates.Reading?, notes: String?) async throws -> ReminderRecord {
        try await off {
            let reminder = EKReminder(eventStore: self.store)
            reminder.title = title
            reminder.calendar = try self.calendar(named: list, for: .reminder)
            reminder.notes = notes
            if let due {
                let units: Set<Calendar.Component> = due.hasTime ? [.year, .month, .day, .hour, .minute, .timeZone] : [.year, .month, .day]
                reminder.dueDateComponents = Calendar.current.dateComponents(units, from: due.date)
            }
            try self.store.save(reminder, commit: true)
            return Self.record(reminder)
        }
    }

    func complete(id: String) async throws -> ReminderRecord {
        try await off {
            guard let reminder = self.store.calendarItem(withIdentifier: id) as? EKReminder else {
                throw ToolFailure("no reminder with the id \(id)")
            }
            reminder.isCompleted = true
            try self.store.save(reminder, commit: true)
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
        try await off { self.store.calendars(for: .event).map(\.title).sorted() }
    }

    func events(from: Date, to: Date, calendar: String?) async throws -> [EventRecord] {
        try await off {
            let calendars = try calendar.map { [try self.calendar(named: $0, for: .event)] }
            let predicate = self.store.predicateForEvents(withStart: from, end: to, calendars: calendars)
            return self.store.events(matching: predicate).map(Self.record)
        }
    }

    func add(title: String, start: ToolDates.Reading, end: ToolDates.Reading, allDay: Bool, calendar: String?,
             location: String?, notes: String?) async throws -> EventRecord {
        try await off {
            let event = EKEvent(eventStore: self.store)
            event.title = title
            event.calendar = try self.calendar(named: calendar, for: .event)
            event.startDate = start.date
            event.endDate = end.date
            event.isAllDay = allDay
            event.location = location
            event.notes = notes
            try self.store.save(event, span: .thisEvent, commit: true)
            return Self.record(event)
        }
    }

    static func record(_ event: EKEvent) -> EventRecord {
        EventRecord(id: event.calendarItemIdentifier, title: event.title ?? "", calendar: event.calendar?.title ?? "",
                    start: event.startDate, end: event.endDate, allDay: event.isAllDay, location: event.location)
    }
}
