import TopoCore
import TopoTurn
import XCTest

@testable import Topo

/// The lines the chat shows when a turn does not finish on this device. The words are in the log
/// by the time any of them is shown, so none of them may read as "say it again": a second send is
/// a second turn, and the one already in the log is answered by whichever primary next runs a pass.
@MainActor
final class HarnessTests: XCTestCase {
    private let outcomes: [LeaseOutcome] = [
        .held(by: Lease(holder: DeviceID("hub"), endpoint: nil, epoch: 2, expiresAt: Date())),
        .unreachable(Lease(holder: DeviceID("hub"), endpoint: nil, epoch: 2, expiresAt: Date())),
        .contended,
    ]

    func testNoLeaseOutcomeAsksThePersonToSayItAgain() {
        for outcome in outcomes {
            let line = Harness.describe(outcome)
            XCTAssertFalse(line.lowercased().contains("try again"), "\(outcome): \(line)")
            XCTAssertTrue(line.hasSuffix("."), "\(outcome): \(line)")
        }
    }

    func testDisplacementSaysTheWordsAreInTheLog() {
        let line = Harness.describe(TurnRunnerError.displaced)
        XCTAssertTrue(line.contains("in the log"), line)
        XCTAssertFalse(line.lowercased().contains("try again"), line)
    }
}
