import Foundation
@testable import Topo
import XCTest

/// A path whose changes the test makes.
private final class FakePathChanges: PathChanges, @unchecked Sendable {
    private let lock = NSLock()
    private var changed: (@Sendable () -> Void)?
    private var starts = 0
    private(set) var cancelled = false

    var started: Int { lock.withLock { starts } }
    func start(_ changed: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.changed = changed
            starts += 1
        }
    }
    func cancel() { lock.withLock { cancelled = true } }
    func change() { lock.withLock { changed }?() }
}

/// What the phone's resolver lists, and every list written, in order.
private final class Servers: @unchecked Sendable {
    private let lock = NSLock()
    private var now: [String]
    private var writes: [[String]] = []

    init(_ now: [String]) { self.now = now }
    func set(_ servers: [String]) { lock.withLock { now = servers } }
    func current() -> [String] { lock.withLock { now } }
    func record(_ servers: [String]) { lock.withLock { writes.append(servers) } }
    var written: [[String]] { lock.withLock { writes } }
}

@MainActor
final class GuestResolverTests: XCTestCase {
    private func waitFor(_ count: Int, _ servers: Servers) async {
        for _ in 0..<200 where servers.written.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The first write is made before `start` answers; every path change after it writes what the
    /// phone lists then, VPN or not.
    func testAPathChangeRewritesTheResolverWithThePhonesServersThen() async {
        let changes = FakePathChanges()
        let servers = Servers(["192.168.1.1"])
        let resolver = GuestResolver(changes: changes, servers: servers.current, write: servers.record)
        await resolver.start()
        XCTAssertEqual(servers.written, [["192.168.1.1"]])

        servers.set(["100.100.100.100", "fd7a:115c:a1e0::53"])
        changes.change()
        await waitFor(2, servers)
        XCTAssertEqual(servers.written, [["192.168.1.1"], ["100.100.100.100", "fd7a:115c:a1e0::53"]])

        servers.set([])
        changes.change()
        await waitFor(3, servers)
        XCTAssertEqual(servers.written.last, [], "an empty list is written as one, for the file's fallback")
    }

    /// A second start writes nothing more and listens to nothing more.
    func testStartingTwiceIsStartingOnce() async {
        let changes = FakePathChanges()
        let servers = Servers(["10.0.0.1"])
        let resolver = GuestResolver(changes: changes, servers: servers.current, write: servers.record)
        await resolver.start()
        await resolver.start()
        XCTAssertEqual(servers.written.count, 1)
        XCTAssertEqual(changes.started, 1, "a second start listened to the path again")
    }

    /// The phone's own path monitor calls back once started, which is the resolver's first cue
    /// after the boot's write and its only one until the network changes.
    func testThePhonesPathMonitorCallsBack() async {
        let changes = NetworkPathChanges()
        let called = expectation(description: "the path monitor called back")
        called.assertForOverFulfill = false
        changes.start { called.fulfill() }
        await fulfillment(of: [called], timeout: 5)
        changes.cancel()
    }

    /// Writes run one after another: a path change while a write is still going waits for it.
    func testWritesNeverOverlap() async {
        final class Writer: @unchecked Sendable {
            let lock = NSLock()
            var running = 0
            var most = 0
            var done = 0
            func write(_ servers: [String]) async {
                lock.withLock { running += 1; most = max(most, running) }
                try? await Task.sleep(for: .milliseconds(50))
                lock.withLock { running -= 1; done += 1 }
            }
        }
        let writer = Writer()
        let changes = FakePathChanges()
        let resolver = GuestResolver(changes: changes, servers: { ["10.0.0.1"] }, write: { await writer.write($0) })
        await resolver.start()
        changes.change()
        changes.change()
        changes.change()
        for _ in 0..<200 where writer.lock.withLock({ writer.done }) < 4 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(writer.lock.withLock { writer.done }, 4)
        XCTAssertEqual(writer.lock.withLock { writer.most }, 1, "two writes of the resolver overlapped")
    }
}
