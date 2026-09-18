@preconcurrency import CloudKit
import Foundation
import TopoCore

/// The push that says a revision of the memory was written, so the folder catches up the moment
/// another device edits rather than at the end of the answering loop's interval.
///
/// `TurnPush`'s twin, and everything true of that one is true of this: the push carries nothing,
/// the revision is read from CloudKit as every other read is, and a push that is duplicated,
/// delayed or forged costs one sync and can put nothing in the folder. The loop stays underneath,
/// so with every push dropped the folder is still current within the interval.
///
/// The iOS target only, as the folder is.
enum NotePush {
    /// Fixed, so the subscription is made once per Apple ID.
    static let subscriptionID = "note-created"

    /// Fires on a revision being created, in the memory's zone, silently. The predicate is
    /// `sequence > 0`, which every revision satisfies: a match-all is answered out of the record
    /// name's index, which the development schema never marks queryable, and `sequence` is
    /// queryable already because `MemoryStore.read(device:after:)` filters on it.
    static func subscription() -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: Note.recordType,
            predicate: NSPredicate(format: "sequence > 0"),
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation])
        subscription.zoneID = TopoCloudKit.zoneID
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        return subscription
    }

    /// Registers the subscription unless this Apple ID already has it. A failure is the caller's
    /// to swallow: a device that cannot subscribe still syncs on the loop.
    static func ensureSubscription() async throws {
        let database = CKContainer(identifier: TopoCloudKit.containerIdentifier).privateCloudDatabase
        do {
            _ = try await database.subscription(for: subscriptionID)
            return
        } catch let error as CKError where error.code == .unknownItem {
            // Not there yet, which is the only error worth continuing past.
        }
        _ = try await database.modifySubscriptions(saving: [subscription()], deleting: [])
    }

    /// True when a push is this subscription's, and not the turn subscription's or anybody
    /// else's.
    static func isOurs(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return false }
        return notification.subscriptionID == subscriptionID
    }
}
