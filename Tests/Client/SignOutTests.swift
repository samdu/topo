import XCTest

@testable import Topo

/// Letting go of the login. Five things end, and which of them end, in what order, is what this
/// covers: the reply in the ear, the transcript and its outbox, the folder on disk, the
/// connections' tokens, and the login's tokens last. A call left out is a reply still being read, or a memory still on disk, for an
/// account the app no longer has.
@MainActor
final class SignOutTests: XCTestCase {
    /// What was ended, in the order it was ended in.
    private final class Calls {
        var ended: [String] = []
    }

    private func signOut() -> (SignOut, Calls) {
        let calls = Calls()
        let signOut = SignOut(stopSpeaking: { calls.ended.append("speaker") },
                              forgetHarness: { calls.ended.append("harness") },
                              forgetMemory: { calls.ended.append("memory") },
                              forgetConnections: { calls.ended.append("connections") },
                              forgetLogin: { calls.ended.append("login") })
        return (signOut, calls)
    }

    func testSigningOutEndsEveryOneOfThem() async {
        let (signOut, calls) = signOut()
        await signOut.act()
        XCTAssertEqual(Set(calls.ended), ["speaker", "harness", "memory", "connections", "login"])
    }

    func testTheLoginGoesLast() async {
        let (signOut, calls) = signOut()
        await signOut.act()
        XCTAssertEqual(calls.ended.last, "login",
                       "the tokens go last, so nothing above runs without an account to run against")
    }

    func testTheSpeakerIsStoppedFirst() async {
        let (signOut, calls) = signOut()
        await signOut.act()
        XCTAssertEqual(calls.ended.first, "speaker",
                       "a reply still being read would hold the process open past the login")
    }

    func testTheOrderIsTheWholeOrder() async {
        let (signOut, calls) = signOut()
        await signOut.act()
        XCTAssertEqual(calls.ended, ["speaker", "harness", "memory", "connections", "login"])
    }

    /// Nothing is ended by building the value: the button's press is what ends them.
    func testNothingHappensUntilItIsTaken() {
        let (_, calls) = signOut()
        XCTAssertTrue(calls.ended.isEmpty)
    }

    /// The far end of a takeover ends the same things, the connections among them, the login last.
    func testATakeoverForgetsTheConnectionsBeforeTheLogin() async {
        let calls = Calls()
        let takeover = Takeover(demoteHarness: { calls.ended.append("harness") },
                                acceptDemotion: { calls.ended.append("role") },
                                stopSpeaking: { calls.ended.append("speaker") },
                                forgetMemory: { calls.ended.append("memory") },
                                forgetConnections: { calls.ended.append("connections") },
                                forgetLogin: { calls.ended.append("login") })
        await takeover.act()
        XCTAssertEqual(calls.ended, ["harness", "role", "speaker", "memory", "connections", "login"])
    }

    /// A phone found a viewer at launch with a login or something waiting demotes, forgets the
    /// memory and the connections, and the login last.
    func testAViewerWithALoginEndsItAllTheLoginLast() async {
        let calls = Calls()
        await arrival(calls, holdsLogin: true).act()
        XCTAssertEqual(calls.ended, ["harness", "memory", "connections", "login"])
    }

    /// One with no login and nothing waiting still forgets a connection's token, whose keychain
    /// item outlives the login's.
    func testAViewerWithNoLoginStillForgetsItsConnections() async {
        let calls = Calls()
        await arrival(calls, holdsLogin: false).act()
        XCTAssertEqual(calls.ended, ["connections"])
    }

    private func arrival(_ calls: Calls, holdsLogin: Bool) -> ViewerArrival {
        ViewerArrival(holdsLogin: { holdsLogin },
                      demoteHarness: { calls.ended.append("harness") },
                      forgetMemory: { calls.ended.append("memory") },
                      forgetConnections: { calls.ended.append("connections") },
                      forgetLogin: { calls.ended.append("login") })
    }
}
