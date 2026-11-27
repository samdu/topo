@preconcurrency import CloudKit
import Foundation
import TopoCore
import TopoTools
import UIKit

/// The phone's end of a call a hub's mind asks of it (`RemoteCall`, `topo --device iphone …` on
/// the Mac): something says the slot may hold a call (`check(via:)`: a push, the app coming to
/// the front, the wait for a hub's reply), the call is claimed and run through the tools the
/// guest's own `topo` reaches, less the ones a call from another device may not have
/// (`allowed`), and the answer is written back with how the phone came to run it.
///
/// It runs only under a login (`follow(signedIn:)`), and an answer whose login ended while the
/// tool ran is written as a refusal, not as the tool's words.
@MainActor
final class RemoteCallRunner {
    static let shared = RemoteCallRunner()

    /// The tools a hub may ask for. Not `github` or `secret`, whose answers are tokens and would
    /// rest in a synced record; not `files`, `screen`, `open-url` or `photos`, which need the
    /// person at the screen or write into the guest's home; not `context`, which is this
    /// device's own conversation. `home` refuses a lock's and a door's target, as a widget's does.
    static let allowed: Set<String> = ["timer", "notify", "reminders", "calendar", "contacts", "location", "maps",
                                       "home", "activity", "widget", "control", "look", "voice", "log", "perf"]

    private var table: ToolTable?
    private var database: (any RecordDatabase)?
    private var signedIn = false
    private var checking = false
    private var again: String?
    private var watching: Task<Void, Never>?

    func install(tools: [any Tool], database: any RecordDatabase) {
        table = WidgetActions.table(tools.filter { Self.allowed.contains($0.name) })
        self.database = database
    }

    func follow(signedIn: Bool) {
        self.signedIn = signedIn
        if !signedIn { watching?.cancel() }
    }

    /// Reads the slot and runs what it holds. One check at a time; one asked for meanwhile runs
    /// after it, since the call it is for may have been written since the read.
    func check(via: String) async {
        guard signedIn, let table, let database else { return }
        if checking { again = via; return }
        checking = true
        defer { checking = false }
        var via = via
        while true {
            let epoch = LoginLife.shared.epoch
            let state = UIApplication.shared.applicationState
            let how = "via=\(via) app=\(state == .active ? "active" : state == .background ? "background" : "inactive")"
            let ran = await RemoteCalls.serve(DeviceIdentity.current, in: database.answering(within: 8), evidence: { call in
                "\(how) claimed=\(Int(Date().timeIntervalSince(call.askedAt) * 1000))ms"
            }, run: { argv in
                Perf.mark("remote.call \(argv.first ?? "")")
                let reply = await ToolService.bounded(argv, table: table, until: .now + ToolService.defaultBound,
                                                      bound: ToolService.defaultBound)
                guard await epoch.isCurrent else { return (Int64(ToolReply.refused), "topo: signed out on that device while the call ran\n") }
                return (Int64(reply.status), reply.text)
            })
            if ran != nil { Perf.mark("remote.call.done \(how)") }
            guard let next = again else { return }
            again = nil
            via = next
        }
    }

    /// While a hub is answering a turn this phone sent and Topo is in front, the slot is read
    /// every second and a half: the mind's call arrives mid-turn, and a push is the system's to
    /// deliver when it likes.
    func watch(while waiting: @escaping @MainActor () -> Bool) {
        watching?.cancel()
        watching = Task { [weak self] in
            while !Task.isCancelled, waiting() {
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled, waiting() else { return }
                await self?.check(via: "turn")
            }
        }
    }
}

/// The push that says a hub wrote a call into a device's slot: silent, as `TurnPush`.
enum CallPush {
    static let subscriptionID = "tool-call-moved"

    static func subscription() -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: RemoteCall.recordType, predicate: NSPredicate(format: "sequence > 0"),
            subscriptionID: subscriptionID, options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        subscription.zoneID = TopoCloudKit.zoneID
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        return subscription
    }
}

/// The push that shows a hub's words (`RemoteAlert`): an alert the system draws from the record's
/// `title` and `body`, with no code of Topo's run to show it, and `content-available` beside it,
/// so a phone it does wake reads its slot too. Unlike every other push of Topo's, it carries words.
enum AlertPush {
    static let subscriptionID = "alert-said"

    static func subscription() -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: RemoteAlert.recordType, predicate: NSPredicate(format: "sequence > 0"),
            subscriptionID: subscriptionID, options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        subscription.zoneID = TopoCloudKit.zoneID
        let info = CKSubscription.NotificationInfo()
        // No such key is in the app's strings, so each key is its own format: the field's value.
        info.titleLocalizationKey = "%1$@"
        info.titleLocalizationArgs = ["title"]
        info.alertLocalizationKey = "%1$@"
        info.alertLocalizationArgs = ["body"]
        info.soundName = "default"
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        return subscription
    }
}

/// A reply the hub's mind saved, shown by the system as an alert on every device of the Apple ID
/// that has Topo away from the front; with Topo in front the reply is on the screen and the
/// alert is not presented (`TopoAppDelegate`'s `willPresent`).
enum ReplyPush {
    static let subscriptionID = "reply-said"

    static func subscription() -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: RemoteAlert.Kind.reply.recordType, predicate: NSPredicate(format: "sequence > 0"),
            subscriptionID: subscriptionID, options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        subscription.zoneID = TopoCloudKit.zoneID
        let info = CKSubscription.NotificationInfo()
        info.titleLocalizationKey = "%1$@"
        info.titleLocalizationArgs = ["title"]
        info.alertLocalizationKey = "%1$@"
        info.alertLocalizationArgs = ["body"]
        info.soundName = "default"
        subscription.notificationInfo = info
        return subscription
    }

    /// Whether a notification about to be presented is a reply's.
    static func isReply(_ userInfo: [AnyHashable: Any]) -> Bool {
        CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID == subscriptionID
    }
}

enum RemotePushes {
    /// Registers both subscriptions unless this Apple ID has them. A failure costs the pushes only.
    static func ensureSubscriptions() async {
        guard await AppRecords.isCloudKit() else { return }
        let database = CKContainer(identifier: TopoCloudKit.containerIdentifier).privateCloudDatabase
        for (id, make) in [(CallPush.subscriptionID, CallPush.subscription), (AlertPush.subscriptionID, AlertPush.subscription),
                           (ReplyPush.subscriptionID, ReplyPush.subscription)] {
            do {
                _ = try await database.subscription(for: id)
            } catch let error as CKError where error.code == .unknownItem {
                do {
                    _ = try await database.modifySubscriptions(saving: [make()], deleting: [])
                    Perf.mark("remote.subscribed \(id)")
                } catch {
                    Perf.mark("remote.subscribe.failed \(id) \((error as? CKError)?.code.rawValue ?? -1)")
                }
            } catch {}
        }
    }

    /// Which of the two a push is, or nil for anybody else's.
    static func kind(_ userInfo: [AnyHashable: Any]) -> String? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return nil }
        switch notification.subscriptionID {
        case CallPush.subscriptionID: return "push"
        case AlertPush.subscriptionID: return "alert"
        default: return nil
        }
    }
}

/// Whether a nudge to a hub is waiting for its answer, which is while the hub's mind is at work
/// on a turn this phone sent.
final class NudgeWaits: @unchecked Sendable {
    static let shared = NudgeWaits()
    private let lock = NSLock()
    private var waits: Set<UUID> = []

    var isWaiting: Bool { lock.withLock { !waits.isEmpty } }
    func begin() -> UUID {
        let id = UUID()
        lock.withLock { _ = waits.insert(id) }
        return id
    }
    func end(_ id: UUID) { lock.withLock { _ = waits.remove(id) } }
}
