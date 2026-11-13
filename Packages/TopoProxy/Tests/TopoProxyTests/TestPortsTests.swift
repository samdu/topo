import Foundation
import Network
import Testing
@testable import TopoProxy
import TopoProxyTestSupport

/// The ports the listener-loss tests take back: below the ephemeral range, each examined once per
/// run, one already held passed over, and a port a test was given never handed to another.
@Suite struct TestPortsTests {
    @Test func everyPortIsBelowTheEphemeralRangeAndDrawnOnce() {
        #expect(TestPorts.range.upperBound < 49152)
        let drawn = (0..<200).compactMap { _ in TestPorts.shared.draw() }
        #expect(drawn.count == 200)
        #expect(drawn.allSatisfy { TestPorts.range.contains($0) })
        #expect(Set(drawn).count == drawn.count)
    }

    /// The listener-loss tests' start lands on a port of the range, not one the system picks.
    @Test func aStartIsOnAPortOfTheRange() async throws {
        let (proxy, port, _) = try await startedProxyOnTestPort(StubUpstream())
        defer { Task { await proxy.stop() } }
        #expect(TestPorts.range.contains(port))
    }

    /// A port something else holds is passed over for the next, and the port a start fell back to
    /// is not handed to the next start once its listener has gone: every port tried is consumed.
    @Test func aHeldPortIsPassedOverAndAFallbackIsNeverHandedAgain() async throws {
        let squatter = try await TestPorts.shared.first { try await squat($0.rawValue) }
        defer { squatter.cancel() }
        let held = try #require(squatter.port?.rawValue)
        let ports = TestPorts(handing: [held], then: .shared)
        let (proxy, fellBack, _) = try await startedProxyOnTestPort(StubUpstream(), from: ports)
        #expect(fellBack != held)
        #expect(TestPorts.range.contains(fellBack))
        await proxy.stop()
        let (next, port, _) = try await startedProxyOnTestPort(StubUpstream(), from: ports)
        defer { Task { await next.stop() } }
        #expect(port != held)
        #expect(port != fellBack, "a port given to one start was handed to the next once its listener went")
    }

    /// The same, read off the draws themselves through a start that binds nothing: the test above
    /// stops its listener and starts again, and a port still held from that stop is skipped as in
    /// use, which a fallback handed twice would hide behind.
    @Test func aPortAStartWasGivenIsNeverDrawnAgain() async throws {
        let held = try #require(TestPorts.shared.draw())
        let ports = TestPorts(handing: [held], then: .shared)
        let tried = Tried()
        let fellBack = try await ports.first { (port: NWEndpoint.Port) -> UInt16 in
            tried.add(port.rawValue)
            if port.rawValue == held { throw NWError.posix(.EADDRINUSE) }
            return port.rawValue
        }
        #expect(fellBack != held)
        let next = try await ports.first { (port: NWEndpoint.Port) -> UInt16 in
            tried.add(port.rawValue)
            return port.rawValue
        }
        #expect(next != held)
        #expect(next != fellBack, "a port given to one start was handed to the next")
        #expect(tried.ports.count == 3)
        #expect(Set(tried.ports).count == tried.ports.count, "a port was tried twice: \(tried.ports)")
    }

    /// A refusal comes only after every port of the range is tried, once each: a run of held ports
    /// never ends the search while one is free. Its own allocator, whose start binds nothing, so the
    /// search costs the suites' allocator no port.
    @Test func everyPortOfTheRangeIsTriedOnceBeforeARefusal() async throws {
        let ports = TestPorts(offset: Int.random(in: 0..<TestPorts.range.count))
        let tried = Tried()
        await #expect(throws: NWError.self) {
            _ = try await ports.first { (port: NWEndpoint.Port) -> Void in
                tried.add(port.rawValue)
                // A search that comes round the range again is that defect, not a hang.
                if tried.ports.count > TestPorts.range.count { throw CancellationError() }
                throw NWError.posix(.EADDRINUSE)
            }
        }
        #expect(tried.ports.count == TestPorts.range.count)
        #expect(Set(tried.ports) == Set(TestPorts.range))
        #expect(ports.draw() == nil)
    }

    /// Every port held is the refusal, not a port of the system's choosing.
    @Test func everyPortHeldIsRefused() async throws {
        let squatter = try await TestPorts.shared.first { try await squat($0.rawValue) }
        defer { squatter.cancel() }
        let held = try #require(squatter.port?.rawValue)
        await #expect(throws: NWError.self) { _ = try await startedProxyOnTestPort(StubUpstream(), from: TestPorts(handing: [held])) }
    }
}

private final class Tried: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UInt16] = []
    var ports: [UInt16] { lock.withLock { stored } }
    func add(_ port: UInt16) { lock.withLock { stored.append(port) } }
}
