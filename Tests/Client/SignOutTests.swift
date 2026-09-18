import XCTest

@testable import Topo

/// Letting go of the login. Four things end, and which of them end, in what order, is what this
/// covers: the reply in the ear, the transcript and its outbox, the folder on disk, and the
/// tokens last. A call left out is a reply still being read, or a memory still on disk, for an
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
                              forgetLogin: { calls.ended.append("login") })
        return (signOut, calls)
    }

    func testSigningOutEndsEveryOneOfThem() {
        let (signOut, calls) = signOut()
        signOut.act()
        XCTAssertEqual(Set(calls.ended), ["speaker", "harness", "memory", "login"])
    }

    func testTheLoginGoesLast() {
        let (signOut, calls) = signOut()
        signOut.act()
        XCTAssertEqual(calls.ended.last, "login",
                       "the tokens go last, so nothing above runs without an account to run against")
    }

    func testTheSpeakerIsStoppedFirst() {
        let (signOut, calls) = signOut()
        signOut.act()
        XCTAssertEqual(calls.ended.first, "speaker",
                       "a reply still being read would hold the process open past the login")
    }

    func testTheOrderIsTheWholeOrder() {
        let (signOut, calls) = signOut()
        signOut.act()
        XCTAssertEqual(calls.ended, ["speaker", "harness", "memory", "login"])
    }

    /// Nothing is ended by building the value: the button's press is what ends them.
    func testNothingHappensUntilItIsTaken() {
        let (_, calls) = signOut()
        XCTAssertTrue(calls.ended.isEmpty)
    }
}
