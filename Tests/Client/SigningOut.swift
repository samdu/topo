import XCTest

@testable import Topo

/// A sign-out in the middle of work begun under the login, for a feature's suite. The feature is
/// built with the suite's own `LoginLife` and its work parked on one of the suite's gates (a
/// gated fetcher, a host that waits); then:
///
///     let login = LoginLife()
///     let feature = Feature(…, login: login)
///     let running = Task { await feature.start() }
///     await SigningOut.midFlight(login, reached: { fetcher.pending == 1 }) { fetcher.release(…) }
///     await running.value
///     XCTAssert(<nothing kept>)
///
/// `midFlight` waits for `reached` (the work is at its gate) and fails the test if it never is,
/// so a test cannot pass by signing out before the work began; then ends the login as a sign-out
/// does (the epoch, then the teardowns), lets the work land, and waits for every teardown to
/// finish. The release comes before that wait because a teardown may queue behind the very work
/// it ends (`ActivityKeeper.endAll` at the keeper's gate).
@MainActor
enum SigningOut {
    static func midFlight(_ login: LoginLife, reached: () -> Bool = { true }, release: () -> Void = {},
                          file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !reached() { await Task.yield() }
        XCTAssertTrue(reached(), "the work never reached its gate, so nothing was in flight at the sign-out", file: file, line: line)
        login.moveEpoch()
        login.runTeardowns()
        release()
        await login.tornDown()
        await settle()
    }

    /// The login ends as a sign-out ends it, and every teardown has finished.
    static func now(_ login: LoginLife) async {
        login.moveEpoch()
        login.runTeardowns()
        await login.tornDown()
    }

    /// Lets tasks the release woke reach their next suspension.
    static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
