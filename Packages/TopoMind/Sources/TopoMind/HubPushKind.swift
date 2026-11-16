@preconcurrency import CloudKit
import Foundation
import TopoCore

/// What a remote notification the hub was handed is, judged from its dictionary alone. The push
/// carries nothing the hub reads, so this decides only whether it is a reason for a pass and what
/// the `push` log line says about it: the subscription's id and the container, never the payload.
public enum HubPushKind: Equatable, Sendable {
    /// A CloudKit push of the hub's own subscription.
    case hubs
    /// A CloudKit push for the log's container under another subscription id (nil when the
    /// notification names none). Still a reason for a pass: the hub's topic carries only what
    /// this container's subscriptions saved from this app, and a pass costs one read.
    case container(subscription: String?)
    /// A CloudKit push for another container (nil when it names none).
    case otherContainer(String?)
    /// Not a CloudKit push at all, with its top-level keys.
    case notCloudKit(keys: [String])

    /// True when the push should start a pass.
    public var triggers: Bool {
        switch self {
        case .hubs, .container: true
        case .otherContainer, .notCloudKit: false
        }
    }

    public static func of(
        _ userInfo: [AnyHashable: Any],
        subscription: String,
        container: String = CloudKitRecordDatabase.containerIdentifier
    ) -> HubPushKind {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            return .notCloudKit(keys: userInfo.keys.map { "\($0)" }.sorted())
        }
        guard notification.containerIdentifier == container else { return .otherContainer(notification.containerIdentifier) }
        if notification.subscriptionID == subscription { return .hubs }
        return .container(subscription: notification.subscriptionID)
    }

    /// The log line's words: the kind, the subscription or container id, or a push's top-level keys;
    /// never a value of the payload.
    public var described: String {
        switch self {
        case .hubs: "the hub's subscription"
        case .container(let id): "the container's, subscription \(id ?? "none")"
        case .otherContainer(let id): "another container's, \(id ?? "none named")"
        case .notCloudKit(let keys): "not CloudKit's, keys \(keys.joined(separator: ","))"
        }
    }
}
