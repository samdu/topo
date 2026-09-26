import Foundation
import TopoTools
import UserNotifications

struct PendingNotification: Sendable, Equatable {
    var id: String
    var title: String
    var due: Date?
}

/// The notifications Topo has scheduled: `UNUserNotificationCenter` on the phone, a fake in the suites.
protocol NotificationScheduler: Sendable {
    func schedule(id: String, title: String, body: String?, at: Date) async throws
    func pending() async -> [PendingNotification]
    /// Whether there was one with that id to cancel.
    func cancel(id: String) async -> Bool
}

/// `topo notify`: a notification on this phone, now or later. Only Topo's own are listed or
/// cancelled.
struct NotifyTool: Tool {
    let scheduler: any NotificationScheduler
    let authorizer: any Authorizer
    let broker: PermissionBroker
    var now: @Sendable () -> Date = { Date() }
    var makeID: @Sendable () -> String = { "topo-" + UUID().uuidString.prefix(8).lowercased() }

    /// Every id Topo schedules starts with this, and only those are listed or cancelled.
    static let prefix = "topo-"

    let name = "notify"
    let summary = "a notification on this phone, now or at a time; list or cancel the ones pending"
    let usage = """
    topo notify TITLE [BODY] [--at DATE | --in SPAN]
                                        a notification now, at DATE, or after SPAN (90s, 15m, 2h, 1d)
    topo notify list                    the ones pending, id first
    topo notify cancel ID               cancel one

    DATE is 2026-09-27T14:30 (the phone's time zone) or 2026-09-27T14:30:00-07:00.
    """

    func run(_ arguments: [String]) async -> ToolReply {
        await PhoneTool.run(authorizer, broker: broker, usage: usage) {
            let parsed = try Arguments(arguments, options: ["at", "in"])
            switch parsed.words.first {
            case "list" where parsed.words.count == 1:
                let lines = await scheduler.pending().filter { $0.id.hasPrefix(Self.prefix) }
                    .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
                    .map { PhoneTool.line([$0.id, $0.title, $0.due.map { "at " + ToolDates.write($0) }]) }
                return .ok(PhoneTool.lines(lines, none: "nothing pending"))
            case "cancel" where parsed.words.count == 2:
                let id = parsed.words[1]
                guard id.hasPrefix(Self.prefix), await scheduler.cancel(id: id) else {
                    throw ToolFailure("no pending notification of Topo's with the id \(id)")
                }
                return .ok("cancelled: \(id)\n")
            case let title? where (1...2).contains(parsed.words.count) && !title.isEmpty:
                guard parsed.options["at"] == nil || parsed.options["in"] == nil else {
                    return .usage("topo notify takes --at or --in, not both\n\n\(usage)\n")
                }
                var due = now().addingTimeInterval(1)
                if let at = try PhoneTool.date(parsed.options["at"], "--at") {
                    guard at.date > now() else { throw ToolFailure("--at \(parsed.options["at"]!) has passed", status: ToolReply.usage) }
                    due = at.date
                } else if let span = parsed.options["in"] {
                    guard let seconds = ToolDates.duration(span) else {
                        throw ToolFailure("--in \(span) is not a span; write it as 90s, 15m, 2h or 1d", status: ToolReply.usage)
                    }
                    due = now().addingTimeInterval(seconds)
                }
                let id = makeID()
                try await scheduler.schedule(id: id, title: title, body: parsed.words.count == 2 ? parsed.words[1] : nil, at: due)
                return .ok("scheduled: " + PhoneTool.line([id, title, "at " + ToolDates.write(due)]) + "\n")
            default:
                return .usage("\(usage)\n")
            }
        }
    }
}

struct NotificationAuthorizer: Authorizer {
    let name = "Notifications"

    func access() async -> Access {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .undetermined
        case .denied: .denied
        default: .granted
        }
    }

    func request() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
}

struct UserNotificationScheduler: NotificationScheduler {
    func schedule(id: String, title: String, body: String?, at due: Date) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.body = body }
        content.sound = .default
        let seconds = max(1, due.timeIntervalSinceNow)
        let trigger: UNNotificationTrigger = seconds < 3600
            ? UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
            : UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second, .timeZone], from: due), repeats: false)
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func pending() async -> [PendingNotification] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().map { request in
            var due: Date?
            if let trigger = request.trigger as? UNCalendarNotificationTrigger { due = trigger.nextTriggerDate() }
            if let trigger = request.trigger as? UNTimeIntervalNotificationTrigger { due = trigger.nextTriggerDate() }
            return PendingNotification(id: request.identifier, title: request.content.title, due: due)
        }
    }

    func cancel(id: String) async -> Bool {
        let center = UNUserNotificationCenter.current()
        guard await center.pendingNotificationRequests().contains(where: { $0.identifier == id }) else { return false }
        center.removePendingNotificationRequests(withIdentifiers: [id])
        return true
    }
}
