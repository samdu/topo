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

/// A forwarder whose ups and downs the test makes.
private final class FakeForwarder: ForwarderChanges, @unchecked Sendable {
    private let lock = NSLock()
    private var changed: (@Sendable (UInt16?) -> Void)?
    private let initial: UInt16?
    private let duringStart: [UInt16?]

    /// `duringStart`: changes the forwarder makes after the port now and before the start answers.
    init(_ initial: UInt16?, duringStart: [UInt16?] = []) {
        self.initial = initial
        self.duringStart = duringStart
    }
    func start(_ changed: @escaping @Sendable (UInt16?) -> Void) async {
        lock.withLock { self.changed = changed }
        changed(initial)
        for port in duringStart { changed(port) }
    }
    func emit(_ port: UInt16?) { lock.withLock { changed }?(port) }
}

/// Fails the first `count` writes.
private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int
    init(_ count: Int) { left = count }
    func take() -> Bool { lock.withLock { guard left > 0 else { return false }; left -= 1; return true } }
}

private final class LoggedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

/// Every port handed to the guest's rewrite and every list written, in one order.
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func port(_ port: UInt16?) { lock.withLock { events.append("port \(port.map(String.init) ?? "cleared")") } }
    func write(_ servers: [String]) { lock.withLock { events.append("write \(servers.joined(separator: " "))") } }
    var all: [String] { lock.withLock { events } }
}

@MainActor
final class GuestResolverTests: XCTestCase {
    private func resolver(_ forwarder: FakeForwarder, _ events: Events, changes: FakePathChanges = FakePathChanges(),
                          servers: [String] = ["192.168.1.1"]) -> GuestResolver {
        GuestResolver(changes: changes, forwarder: forwarder, servers: { servers },
                      setPort: events.port, write: { events.write($0) }, log: { _ in })
    }

    /// The forwarder going down while the boot's start is under way: the first write is the
    /// phone's servers with the rewrite cleared, never the stub over a stopped forwarder.
    func testAForwarderDownDuringTheStartIsTheFirstWrite() async {
        let events = Events()
        let resolver = resolver(FakeForwarder(5353, duringStart: [nil]), events)
        await resolver.start()
        await resolver.settle()
        XCTAssertEqual(events.all, ["port cleared", "write 192.168.1.1"])
    }

    /// A write that fails is logged and tried again until it is made, however many tries it takes.
    func testAFailedWriteIsTriedUntilItIsMade() async {
        let events = Events()
        let failures = Failures(8)
        let logged = LoggedLines()
        let resolver = GuestResolver(changes: FakePathChanges(), forwarder: FakeForwarder(5353), servers: { ["192.168.1.1"] },
                                     setPort: events.port,
                                     write: { servers in
                                         if failures.take() { throw POSIXError(.EIO) }
                                         events.write(servers)
                                     },
                                     retryDelay: .milliseconds(1), log: logged.add)
        await resolver.start()
        XCTAssertEqual(events.all, ["port 5353", "write 127.0.0.53"])
        XCTAssertEqual(logged.all.count, 8)
    }

    /// The stub's write failing and the forwarder going down before the next try: what is written
    /// is the phone's servers, read as the try starts, never the stub.
    func testARetryWritesTheStateAsItIsThen() async {
        let events = Events()
        let forwarder = FakeForwarder(5353)
        let failures = Failures(1)
        let resolver = GuestResolver(changes: FakePathChanges(), forwarder: forwarder, servers: { ["192.168.1.1"] },
                                     setPort: events.port,
                                     write: { servers in
                                         if failures.take() {
                                             forwarder.emit(nil)
                                             throw POSIXError(.EIO)
                                         }
                                         events.write(servers)
                                     },
                                     retryDelay: .milliseconds(50), log: { _ in })
        await resolver.start()
        await resolver.settle()
        XCTAssertEqual(events.all, ["port 5353", "port cleared", "write 192.168.1.1"])
    }

    private func waitFor(_ count: Int, _ events: Events) async {
        for _ in 0..<200 where events.all.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Review focus 3: with the forwarder up at the boot, the rewrite is given its port before
    /// the first write, and the first write is the stub alone.
    func testForwarderReadyWritesSentinel() async {
        let events = Events()
        await resolver(FakeForwarder(5353), events).start()
        XCTAssertEqual(events.all, ["port 5353", "write 127.0.0.53"])
    }

    /// Review focus 3: the forwarder going down clears the rewrite and writes the phone's servers.
    func testForwarderFailedWritesPhoneServers() async {
        let events = Events()
        let forwarder = FakeForwarder(5353)
        let resolver = resolver(forwarder, events)
        await resolver.start()
        forwarder.emit(nil)
        await resolver.settle()
        XCTAssertEqual(events.all, ["port 5353", "write 127.0.0.53", "port cleared", "write 192.168.1.1"])
    }

    /// Review focus 3: a restart writes the stub again, with the new port given first; a forwarder
    /// down at the boot writes the phone's servers until it is up.
    func testForwarderRestartedWritesSentinelAgain() async {
        let events = Events()
        let forwarder = FakeForwarder(nil)
        let resolver = resolver(forwarder, events)
        await resolver.start()
        for port: UInt16? in [6000, nil, 6001] {
            forwarder.emit(port)
            await resolver.settle()
        }
        XCTAssertEqual(events.all, ["port cleared", "write 192.168.1.1", "port 6000", "write 127.0.0.53",
                                    "port cleared", "write 192.168.1.1", "port 6001", "write 127.0.0.53"])
    }

    /// Review focus 3: a path change while the forwarder is up writes the stub, not the servers.
    func testPathChangeWhileForwarderUpKeepsSentinel() async {
        let events = Events()
        let changes = FakePathChanges()
        await resolver(FakeForwarder(5353), events, changes: changes, servers: ["100.100.100.100"]).start()
        changes.change()
        await waitFor(3, events)
        XCTAssertEqual(events.all, ["port 5353", "write 127.0.0.53", "write 127.0.0.53"])
    }

    /// An up and a down in quick succession end with the last: the phone's servers.
    func testTheLastForwarderChangeIsTheLastWrite() async {
        let events = Events()
        let forwarder = FakeForwarder(nil)
        let resolver = resolver(forwarder, events)
        await resolver.start()
        forwarder.emit(7000)
        forwarder.emit(nil)
        await resolver.settle()
        XCTAssertEqual(events.all.last, "write 192.168.1.1")
        XCTAssertEqual(events.all.filter { $0.hasPrefix("port") }.last, "port cleared")
    }

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
