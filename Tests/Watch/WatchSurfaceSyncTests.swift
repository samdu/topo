import XCTest

@testable import TopoWatch

/// Review Focus 9: the watch fetches when opened, on the push and on the refresh the system
/// grants, and never on a clock of its own.
@MainActor
final class WatchSurfaceSyncTests: XCTestCase {
    func testNoFetchWithoutACue() async {
        var fetches = 0
        var asked: [Date] = []
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let sync = WatchSurfaceSync(fetch: { fetches += 1 }, schedule: { asked.append($0) }, now: { now })

        now += 3600
        await Task.yield()
        XCTAssertEqual(fetches, 0, "an hour passed and the watch fetched on its own")

        await sync.opened()
        await sync.pushed()
        XCTAssertEqual(fetches, 2)
        await sync.refreshed()
        XCTAssertEqual(fetches, 3)
        XCTAssertEqual(asked, [now + WatchSurfaceSync.refreshInterval], "the next refresh was not asked for 30 minutes on")
    }

    /// A push landing while a fetch runs is one more fetch after it, never a second at once.
    /// Two fetches asked for while one runs make exactly one more after it: never two at once,
    /// and never none.
    func testFetchesAreSingleFlight() async {
        var running = 0
        var most = 0
        var fetches = 0
        var release: CheckedContinuation<Void, Never>?
        let sync = WatchSurfaceSync(fetch: {
            running += 1
            most = max(most, running)
            fetches += 1
            if fetches == 1 { await withCheckedContinuation { release = $0 } }
            running -= 1
        }, schedule: { _ in })
        let first = Task { await sync.pushed() }
        while release == nil { await Task.yield() }
        let second = Task { await sync.pushed() }
        let third = Task { await sync.opened() }
        for _ in 0..<50 { await Task.yield() }
        release?.resume()
        await first.value
        await second.value
        await third.value
        XCTAssertEqual(most, 1)
        XCTAssertEqual(fetches, 2, "fetches asked for during one ran none after it, or more than one")
    }
}
