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
    func testFetchesAreSingleFlight() async {
        var running = 0
        var most = 0
        var fetches = 0
        let sync = WatchSurfaceSync(fetch: {
            running += 1
            most = max(most, running)
            fetches += 1
            await Task.yield()
            running -= 1
        }, schedule: { _ in })
        async let a: Void = sync.pushed()
        async let b: Void = sync.pushed()
        async let c: Void = sync.opened()
        _ = await (a, b, c)
        XCTAssertEqual(most, 1)
        XCTAssertLessThanOrEqual(fetches, 2)
    }
}
