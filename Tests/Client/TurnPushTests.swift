import CloudKit
import TopoCore
import XCTest

@testable import Topo

final class TurnPushTests: XCTestCase {
    func testItAsksForTurnsAsTheyAreCreated() {
        let subscription = TurnPush.subscription()
        XCTAssertEqual(subscription.recordType, Turn.recordType)
        XCTAssertTrue(subscription.querySubscriptionOptions.contains(.firesOnRecordCreation))
        // Creation only: a turn record is written once and never updated, so an
        // update or a delete firing this would be a record that is not a turn.
        XCTAssertFalse(subscription.querySubscriptionOptions.contains(.firesOnRecordUpdate))
        XCTAssertFalse(subscription.querySubscriptionOptions.contains(.firesOnRecordDeletion))
    }

    func testItIsScopedToTheLogsZone() {
        XCTAssertEqual(TurnPush.subscription().zoneID, TopoCloudKit.zoneID)
    }

    /// The predicate has to match every turn while asking only about a field
    /// the schema marks queryable — a match-all is answered out of the record
    /// name's index, which the development schema does not mark.
    ///
    /// Read rather than evaluated: CloudKit disables local evaluation of a
    /// subscription's predicate, so what a turn record matches is the
    /// server's answer and not this suite's to assert. Sequence numbers
    /// start at 1, so `sequence > 0` is every turn.
    func testItAsksAboutSequenceRatherThanMatchingEverything() {
        let predicate = TurnPush.subscription().predicate
        XCTAssertNotEqual(predicate.predicateFormat, NSPredicate(value: true).predicateFormat)
        XCTAssertEqual(predicate.predicateFormat, "sequence > 0")
    }

    /// Silent, so there is no permission to ask for and nothing is shown.
    func testItIsSilent() {
        let info = TurnPush.subscription().notificationInfo
        XCTAssertEqual(info?.shouldSendContentAvailable, true)
        XCTAssertNil(info?.alertBody)
        XCTAssertNil(info?.soundName)
    }

    /// Fixed, so a second launch finds the subscription rather than making another.
    func testTheSubscriptionIsNamedTheSameEveryTime() {
        XCTAssertEqual(TurnPush.subscription().subscriptionID, TurnPush.subscriptionID)
        XCTAssertEqual(TurnPush.subscription().subscriptionID, TurnPush.subscription().subscriptionID)
    }

    /// Only the reject path is covered. `CKNotification` has no public
    /// initialiser and its remote-notification dictionary is an undocumented
    /// shape, so a payload this suite builds proves nothing about one APNs
    /// delivers: a hand-made "ours" would pass by matching the guess rather
    /// than the format. What is asserted is that anything not recognisable
    /// as our subscription's is refused, which is the half that matters —
    /// the accept path costs a wasted read, the reject path is the guard.
    func testAPushThatIsNotOursIsRefused() {
        XCTAssertFalse(TurnPush.isOurs([:]))
        XCTAssertFalse(TurnPush.isOurs(["aps": ["content-available": 1]]))
        XCTAssertFalse(TurnPush.isOurs(["ck": ["ce": 2, "cd": ["sid": "something-else"]]]))
    }
}
