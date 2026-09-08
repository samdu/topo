import TopoAuth
import XCTest

@testable import Topo

/// The debug-only launch hooks. This bundle is itself a debug build, which is why it can see them.
final class DebugRunTests: XCTestCase {
    func testATokenInTheEnvironmentSignsTheAppIn() throws {
        let store = InMemoryTokenStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(DebugRun.signIn(store: store,
                                      environment: ["TOPO_CLAUDE_SETUP_TOKEN": "  sk-ant-oat01-test  ",
                                                    "TOPO_CLAUDE_SETUP_TOKEN_DAYS": "2"],
                                      now: now))
        let tokens = try XCTUnwrap(try store.load())
        XCTAssertEqual(tokens.accessToken, "sk-ant-oat01-test")
        // A setup token cannot be exchanged, so nothing is kept to exchange it with.
        XCTAssertTrue(tokens.refreshToken.isEmpty)
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(2 * 86_400))
        XCTAssertFalse(tokens.isExpired(at: now))
    }

    func testWithoutOneNothingIsTouched() throws {
        let store = InMemoryTokenStore()
        XCTAssertFalse(DebugRun.signIn(store: store, environment: [:]))
        XCTAssertFalse(DebugRun.signIn(store: store, environment: ["TOPO_CLAUDE_SETUP_TOKEN": "   "]))
        XCTAssertNil(try store.load())
    }

    func testOnlyAnAskedForTurnIsSent() {
        XCTAssertNil(DebugRun.words([:]))
        XCTAssertNil(DebugRun.words(["TOPO_DEBUG_SEND": " \n "]))
        XCTAssertEqual(DebugRun.words(["TOPO_DEBUG_SEND": " what did I forget "]), "what did I forget")
    }
}
