@preconcurrency import CloudKit
import Foundation
import TopoCore
import TopoMind

/// The push that wakes the hub's answering loop the moment a turn is created, so a limb's words
/// do not wait on the loop's next poll. The phone's `TurnPush` is the same subscription, under the
/// phone's own id.
///
/// Its own id, `hub-turn-created`, and the hub never saves or reads the phone's: subscriptions are
/// kept in the Apple ID's private database, so the id is what tells the hub's from the phone's,
/// and a save under `turn-created` would be a save over the phone's. A push reaches the hub on
/// its own bundle's topic (`com.apple.icloud-container.zone.hexagon.topo.hub`); any CloudKit push
/// of the log's container that arrives there starts a pass, whatever subscription id it names,
/// and the delegate logs which id that was (`HubPushKind`).
///
/// The push carries nothing: the turn is read from the log as every other read is, so a push
/// that is duplicated, delayed or forged costs one read. The loop's poll stays underneath; a
/// content-available push goes at APNs' low priority and can land after the poll has answered its
/// turn (`docs/hub.md`).
enum HubPush {
    static let subscriptionID = "hub-turn-created"

    /// Fires on a turn being created in the log's zone, silently. `sequence > 0` for the reason
    /// `TurnPush` gives: a match-all predicate needs the record-name index the development schema
    /// never marks queryable, and `sequence` is queryable already.
    static func subscription() -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: Turn.recordType,
            predicate: NSPredicate(format: "sequence > 0"),
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation])
        subscription.zoneID = TopoCloudKit.zoneID
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        return subscription
    }

    /// A save whose results have no entry for the subscription's id.
    struct SaveUnanswered: Error, CustomStringConvertible {
        var description: String { "the save answered with no result for \(HubPush.subscriptionID)" }
    }

    /// What `ensureSubscription()` found and did, for the `hub` log line.
    enum Outcome: Equatable {
        /// The fetch by id found it; nothing was written.
        case found
        /// It was saved now, and the read by id straight after says whether the server answers
        /// for it (`nil` when that read failed for a reason other than its absence).
        case saved(readBack: Bool?)

        var described: String {
            switch self {
            case .found: "already there"
            case .saved(readBack: true): "saved, and read back"
            case .saved(readBack: false): "saved, but a read by id straight after does not find it"
            case .saved(readBack: nil): "saved; the read back failed"
            }
        }
    }

    /// Saves the subscription unless a fetch by id finds it: one fetch when it does. The caller
    /// only calls it against the real store.
    ///
    /// The save is judged by its own result for this id: the call throws only for the whole
    /// request, a subscription the server refused is in its per-item result, and a result with no
    /// entry for the id is a save that did not happen. The read back after a save tells a
    /// subscription the server does not answer for by id from one that is gone by the next launch.
    static func ensureSubscription() async throws -> Outcome {
        let database = CKContainer(identifier: TopoCloudKit.containerIdentifier).privateCloudDatabase
        if try await isThere(database) { return .found }
        let (saved, _) = try await database.modifySubscriptions(saving: [subscription()], deleting: [])
        guard let result = saved[subscriptionID] else { throw SaveUnanswered() }
        _ = try result.get()
        return .saved(readBack: try? await isThere(database))
    }

    /// True when a fetch by id finds the subscription, false when the server says it has no such
    /// item; any other failure throws.
    private static func isThere(_ database: CKDatabase) async throws -> Bool {
        do {
            _ = try await database.subscription(for: subscriptionID)
            return true
        } catch let error as CKError where error.code == .unknownItem {
            return false
        }
    }

    /// What a push is, for the delegate's log line and whether it starts a pass (`HubPushKind`).
    static func kind(_ userInfo: [AnyHashable: Any]) -> HubPushKind {
        HubPushKind.of(userInfo, subscription: subscriptionID, container: TopoCloudKit.containerIdentifier)
    }
}
