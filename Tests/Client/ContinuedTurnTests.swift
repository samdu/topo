import BackgroundTasks
import XCTest

@testable import Topo

final class ContinuedTurnTests: XCTestCase {
    @MainActor
    func testATurnsRequestFailsRatherThanQueuesAndCarriesTheFixedWords() throws {
        guard #available(iOS 26, *) else { throw XCTSkip("BGContinuedProcessingTaskRequest is iOS 26 on") }
        let identifier = "\(ContinuedTurns.prefix).\(UUID().uuidString)"
        let request = ContinuedTurns.request(identifier: identifier)
        XCTAssertEqual(request.identifier, identifier)
        XCTAssertEqual(request.strategy, .fail, "a turn's task is worth having now or not at all")
        XCTAssertEqual(request.title, "Topo")
        XCTAssertEqual(request.subtitle, "Working on a reply", "the pill is drawn on the lock screen: fixed words, never the turn's")
    }

    func testTheIdentifierIsUnderTheWildcardThePlistPermits() throws {
        guard #available(iOS 26, *) else { throw XCTSkip("BGContinuedProcessingTaskRequest is iOS 26 on") }
        let permitted = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])
        XCTAssertTrue(permitted.contains("\(ContinuedTurns.prefix).*"), "\(permitted)")
    }
}
