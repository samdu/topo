import Foundation
import Network
import Testing
@testable import TopoProxy

/// The ports the listener-loss tests take back: below the ephemeral range, handed out once, and
/// one already held passed over.
@Suite struct TestPortsTests {
    @Test func everyPortIsBelowTheEphemeralRangeAndHandedOutOnce() {
        #expect(TestPorts.range.upperBound < 49152)
        let taken = (0..<200).map { _ in TestPorts.take() }
        #expect(taken.allSatisfy { TestPorts.range.contains($0) })
        #expect(Set(taken).count == taken.count)
    }

    /// The listener-loss tests' start lands on a port of the range, not one the system picks.
    @Test func aStartIsOnAPortOfTheRange() async throws {
        let (proxy, port, _) = try await startedProxyOnTestPort(StubUpstream())
        defer { Task { await proxy.stop() } }
        #expect(TestPorts.range.contains(port))
    }

    /// A port something else already holds is passed over for the next.
    @Test func aHeldPortIsPassedOverForTheNext() async throws {
        let held = TestPorts.take(), free = TestPorts.take()
        let squatter = try await squat(held)
        defer { squatter.cancel() }
        let (proxy, port, _) = try await startedProxyOnTestPort(StubUpstream(), over: [held, free])
        defer { Task { await proxy.stop() } }
        #expect(port == free)
    }

    /// A refusal comes only after as many tries as the range has ports, each one of the range: a
    /// run of held ports never ends the search while one is free. (The ports are the ones handed
    /// out meanwhile, so a parallel test's draw is one this walk skips, being in use.)
    @Test func everyPortOfTheRangeIsTriedBeforeARefusal() async throws {
        let tried = Tried()
        await #expect(throws: NWError.self) {
            _ = try await TestPorts.first { (port: NWEndpoint.Port) -> Void in
                tried.add(port.rawValue)
                throw NWError.posix(.EADDRINUSE)
            }
        }
        #expect(tried.ports.count == TestPorts.range.count)
        #expect(tried.ports.allSatisfy { TestPorts.range.contains($0) })
    }

    /// Every port held is the refusal, not a port of the system's choosing.
    @Test func everyPortHeldIsRefused() async throws {
        let held = TestPorts.take()
        let squatter = try await squat(held)
        defer { squatter.cancel() }
        await #expect(throws: NWError.self) { _ = try await startedProxyOnTestPort(StubUpstream(), over: [held]) }
    }
}

private final class Tried: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UInt16] = []
    var ports: [UInt16] { lock.withLock { stored } }
    func add(_ port: UInt16) { lock.withLock { stored.append(port) } }
}
