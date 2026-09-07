@preconcurrency import CloudKit
import Foundation
import TopoCore

/// The push that wakes a primary the moment a limb writes a turn, so an
/// answer does not wait on the next pass of the five-second loop.
///
/// The push carries nothing. It says only "the log moved"; the turn itself is
/// read from CloudKit as every other read is, so a push that is duplicated,
/// delayed or forged costs one read and can put nothing into the transcript.
/// That is what keeps the rule — CloudKit is truth — true of the fast path as
/// well as the slow one, and it is why this needs no authentication of its
/// own.
///
/// The loop stays. Apple delivers a background push at the system's
/// discretion, so this is an accelerator and never the only way a turn is
/// noticed: with every push dropped, the app behaves exactly as it did before.
enum TurnPush {
    /// Fixed, so the subscription is made once per Apple ID and every later
    /// launch finds it rather than making a second one.
    static let subscriptionID = "turn-created"

    /// Fires on a turn being created, in the log's zone, silently.
    ///
    /// A zone subscription would be the obvious choice against a change-feed
    /// reader, and is wrong here: the primary lease lives in this zone and is
    /// heartbeated every five seconds, so a zone subscription would push to
    /// every device twice a turn and constantly in between — the poll this
    /// replaces, in APNs traffic.
    ///
    /// The predicate is `sequence > 0`, which every turn satisfies, rather
    /// than a match-all. A match-all predicate is answered out of the record
    /// name's index, which the development schema never marks queryable —
    /// the same reason `TurnLog.read()` takes the change feed instead of a
    /// query. `sequence` is queryable already, because `read(device:after:)`
    /// filters on it.
    static func subscription() -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: Turn.recordType,
            predicate: NSPredicate(format: "sequence > 0"),
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation])
        subscription.zoneID = TopoCloudKit.zoneID
        let info = CKSubscription.NotificationInfo()
        // Silent: no banner, no sound, and no permission to ask for. The app
        // is woken to read the log, not to say anything to the person.
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        return subscription
    }

    /// Registers the subscription unless this Apple ID already has it.
    ///
    /// Called on every launch and cheap when it is already there: one fetch,
    /// no write. A failure is the caller's to swallow — a device that cannot
    /// subscribe still answers on the loop, so this must never be a reason
    /// the screen shows an error.
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

    /// True when a push is this subscription's. Anything else — a share
    /// invitation, another subscription added later — is not ours to act on.
    static func isOurs(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return false }
        return notification.subscriptionID == subscriptionID
    }
}
