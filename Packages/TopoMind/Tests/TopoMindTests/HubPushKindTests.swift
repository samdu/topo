import Testing
import TopoCore
import TopoMind

/// The hub's reading of a remote notification, over dictionaries shaped as CloudKit sends a
/// query subscription's silent push (`ck.qry.sid`, `ck.cid`).
@Suite struct HubPushKindTests {
    static let hubs = "hub-turn-created"

    static func push(subscription: String?, container: String = CloudKitRecordDatabase.containerIdentifier) -> [AnyHashable: Any] {
        var query: [String: Any] = ["dbs": 1, "fo": 1, "rid": "turn/ios-1/2", "zid": "Topo", "zoid": "_defaultOwner"]
        if let subscription { query["sid"] = subscription }
        return [
            "aps": ["content-available": 1],
            "ck": ["ce": 2, "cid": container, "nid": "6e7a2b4c-0000-0000-0000-000000000000", "qry": query],
        ]
    }

    @Test func theHubsOwnSubscriptionTriggers() {
        let kind = HubPushKind.of(Self.push(subscription: Self.hubs), subscription: Self.hubs)
        #expect(kind == .hubs)
        #expect(kind.triggers)
    }

    @Test func anotherSubscriptionOfTheContainerTriggersAndIsNamed() {
        let kind = HubPushKind.of(Self.push(subscription: "turn-created"), subscription: Self.hubs)
        #expect(kind == .container(subscription: "turn-created"))
        #expect(kind.triggers)
        #expect(kind.described.contains("turn-created"))
    }

    @Test func anotherContainerDoesNot() {
        let kind = HubPushKind.of(Self.push(subscription: Self.hubs, container: "iCloud.example.other"), subscription: Self.hubs)
        #expect(kind == .otherContainer("iCloud.example.other"))
        #expect(!kind.triggers)
    }

    @Test func aPushThatIsNotCloudKitsDoesNot() {
        let kind = HubPushKind.of(["aps": ["content-available": 1]], subscription: Self.hubs)
        #expect(kind == .notCloudKit(keys: ["aps"]))
        #expect(!kind.triggers)
    }
}
