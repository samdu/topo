@preconcurrency import CloudKit
import Foundation
import TopoCore

/// The push that wakes the hub's answering loop the moment a turn is created, so a limb's words
/// do not wait on the loop's next poll. The phone's `TurnPush` is the same subscription, under the
/// phone's own id.
///
/// Its own id, `hub-turn-created`, and the hub never saves or reads the phone's: subscriptions are
/// kept in the Apple ID's private database, so the id is what tells the hub's from the phone's,
/// and a save under `turn-created` would be a save over the phone's. Where CloudKit sends both
/// subscriptions' pushes to every app of the container that registered for them, each turn is
/// two pushes to each such app; each acts only on its own (`isOurs`).
///
/// The push carries nothing: the turn is read from the log as every other read is, so a push
/// that is duplicated, delayed or forged costs one read. The loop's poll stays underneath.
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

    /// Saves the subscription unless the Apple ID has it already: one fetch when it does. True
    /// when it was saved now. The caller only calls it against the real store.
    static func ensureSubscription() async throws -> Bool {
        let database = CKContainer(identifier: TopoCloudKit.containerIdentifier).privateCloudDatabase
        do {
            _ = try await database.subscription(for: subscriptionID)
            return false
        } catch let error as CKError where error.code == .unknownItem {
            // Not there yet, which is the only error worth continuing past.
        }
        _ = try await database.modifySubscriptions(saving: [subscription()], deleting: [])
        return true
    }

    /// True when a push is this subscription's.
    static func isOurs(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return false }
        return notification.subscriptionID == subscriptionID
    }
}
