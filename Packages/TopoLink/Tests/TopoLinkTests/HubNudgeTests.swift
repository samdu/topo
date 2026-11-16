import Foundation
import Network
import Testing
import TopoCore
@testable import TopoLink

/// The nudge: a `moved` line to the holder of the lease, answered `read` when its pass has ended.
@Suite struct HubNudgeTests {
    let hub = DeviceID("mac-hub")

    func lease(epoch: Int64 = 3, port: UInt16) -> Lease {
        Lease(holder: hub, endpoint: "127.0.0.1:\(port)", epoch: epoch, expiresAt: Date() + 10)
    }

    /// Counts the nudges the listener was handed and holds each until `release`.
    final class Passes: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [CheckedContinuation<Bool, Never>] = []
        private(set) var marks: [String] = []
        var count: Int { lock.withLock { marks.count } }
        var waiting: Int { lock.withLock { held.count } }

        func nudged(_ mark: String, hold: Bool) async -> Bool {
            lock.withLock { marks.append(mark) }
            guard hold else { return true }
            return await withCheckedContinuation { c in lock.withLock { held.append(c) } }
        }

        func release(_ answer: Bool = true) {
            let all = lock.withLock { defer { held = [] }; return held }
            all.forEach { $0.resume(returning: answer) }
        }
    }

    @Test func theWire() {
        #expect(ProbeWire.parse("moved mac-hub 3 ab12cd34\n") == .moved(DeviceID("mac-hub"), 3, mark: "ab12cd34"))
        #expect(ProbeWire.parse("hold mac-hub 3") == .hold(DeviceID("mac-hub"), 3))
        #expect(ProbeWire.parse("moved mac-hub 3") == nil)
        #expect(ProbeWire.parse("moved mac-hub x ab") == nil)
        #expect(ProbeWire.parse("moved mac-hub 3 a/b") == nil)
        #expect(ProbeWire.parse("moved mac-hub 3 " + String(repeating: "a", count: 17)) == nil)
        #expect(String(decoding: ProbeWire.nudge(lease(port: 1), mark: "ab12"), as: UTF8.self) == "moved mac-hub 3 ab12\n")
    }

    @Test func aNudgeIsAnsweredReadOnceItsPassHasEnded() async throws {
        let passes = Passes()
        let server = try LeaseProbeServer(advertising: nil, holds: { _, _ in false }) { device, epoch, mark in
            guard device == DeviceID("mac-hub"), epoch == 3 else { return false }
            return await passes.nudged(mark, hold: true)
        }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let sent = Task { await HubNudge.send(for: lease(port: port), mark: "ab12cd34") }
        try await waitFor { passes.waiting == 1 }
        // Held while the pass runs.
        try await Task.sleep(for: .milliseconds(200))
        #expect(passes.marks == ["ab12cd34"])
        passes.release()
        #expect(await sent.value == .read)
        // Another lease's nudge asks for no pass.
        #expect(await HubNudge.send(for: lease(epoch: 4, port: port), mark: "x") == .no)
        #expect(passes.count == 1)
    }

    @Test func aListenerWithNoMindSaysNoAndAProbeStillWorks() async throws {
        let server = try LeaseProbeServer(advertising: nil) { _, epoch in epoch == 3 }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        #expect(await HubNudge.send(for: lease(port: port), mark: "ab") == .no)
        #expect(await SocketLeaseProbe().confirms(lease(port: port)))
    }

    @Test func moreNudgesThanTheCapAreAnsweredNoAtOnce() async throws {
        let passes = Passes()
        let server = try LeaseProbeServer(advertising: nil, holds: { _, _ in false }) { _, _, mark in
            await passes.nudged(mark, hold: true)
        }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let held = (0..<LeaseProbeServer.nudgesAtOnce).map { i in
            Task { await HubNudge.send(for: lease(port: port), mark: "m\(i)") }
        }
        try await waitFor { passes.waiting == LeaseProbeServer.nudgesAtOnce }
        #expect(await HubNudge.send(for: lease(port: port), mark: "over") == .no)
        #expect(passes.count == LeaseProbeServer.nudgesAtOnce)
        passes.release()
        for task in held { #expect(await task.value == .read) }
    }

    @Test func nobodyListeningIsUnreachedQuickly() async throws {
        let placeholder = try LeaseProbeServer(advertising: nil) { _, _ in true }
        let port = try await placeholder.start()
        await placeholder.stop()
        try await Task.sleep(for: .milliseconds(50))
        let began = Date()
        guard case .unreached = await HubNudge.send(for: lease(port: port), mark: "ab", connectBound: 0.5) else {
            Issue.record("a closed port answered"); return
        }
        #expect(Date().timeIntervalSince(began) < 2)
        #expect(await HubNudge.send(for: Lease(holder: hub, endpoint: nil, epoch: 1, expiresAt: Date()), mark: "ab") == .unreached("noEndpoint"))
    }

    @Test func aListenerThatNeverAnswersIsGivenUpOnAtTheBound() async throws {
        let passes = Passes()
        let server = try LeaseProbeServer(advertising: nil, holds: { _, _ in false }) { _, _, mark in
            await passes.nudged(mark, hold: true)
        }
        let port = try await server.start()
        defer { Task { await server.stop(); passes.release() } }
        let began = Date()
        #expect(await HubNudge.send(for: lease(port: port), mark: "ab", answerBound: 0.5) == .unreached("answer"))
        #expect(Date().timeIntervalSince(began) < 2)
    }

    /// A connection that says nothing is closed by the listener at its bound.
    @Test func silenceIsClosedByTheListener() async throws {
        let server = try LeaseProbeServer(advertising: nil) { _, _ in true }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
        defer { connection.cancel() }
        try await connection.waitUntilReady()
        let began = Date()
        let line = try? await connection.readLine(maximum: 16)
        let took = Date().timeIntervalSince(began)
        #expect(line == "no" || line == nil || line == "")
        #expect(took >= LeaseProbeServer.requestBound - 0.5 && took < LeaseProbeServer.requestBound + 3)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date() + 5
        while !condition() {
            guard Date() < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
