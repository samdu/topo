import Foundation
import Network
import Testing
import TopoCore
@testable import TopoLink

/// The nudge: a `moved` line to the holder of the lease over its channel, answered `read` when its
/// pass has ended.
@Suite struct HubNudgeTests {
    let hub = DeviceID("mac-hub")

    /// A listener with a fresh key of the hub's, started: its probe's port and the key at its
    /// channel's port.
    func started(_ nudged: LeaseProbeServer.Nudged? = nil,
                 holds: @escaping LeaseProbeServer.Holds = { _, _ in false }) async throws -> (LeaseProbeServer, UInt16, NudgeKey) {
        let key = NudgeKey.mint(hub: hub)
        let server = try LeaseProbeServer(advertising: nil, key: key, holds: holds, nudged: nudged)
        let port = try await server.start()
        return (server, port, key.on(port: try #require(await server.securePort)))
    }

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
        #expect(ProbeWire.parse("moved mac-hub 3 ab12cd34\n") == .moved(DeviceID("mac-hub"), 3, mark: "ab12cd34", stream: false))
        #expect(ProbeWire.parse("moved mac-hub 3 ab12cd34 stream\n") == .moved(DeviceID("mac-hub"), 3, mark: "ab12cd34", stream: true))
        #expect(ProbeWire.parse("moved mac-hub 3 ab12cd34 words") == nil)
        #expect(ProbeWire.parse("hold mac-hub 3") == .hold(DeviceID("mac-hub"), 3))
        #expect(ProbeWire.parse("moved mac-hub 3") == nil)
        #expect(ProbeWire.parse("moved mac-hub x ab") == nil)
        #expect(ProbeWire.parse("moved mac-hub 3 a/b") == nil)
        #expect(ProbeWire.parse("moved mac-hub 3 " + String(repeating: "a", count: 17)) == nil)
        #expect(String(decoding: ProbeWire.nudge(lease(port: 1), mark: "ab12"), as: UTF8.self) == "moved mac-hub 3 ab12\n")
    }

    @Test func aNudgeIsAnsweredReadOnceItsPassHasEnded() async throws {
        let passes = Passes()
        let (server, port, key) = try await started { device, epoch, mark, _ in
            guard device == DeviceID("mac-hub"), epoch == 3 else { return false }
            return await passes.nudged(mark, hold: true)
        }
        defer { Task { await server.stop() } }
        let sent = Task { await HubNudge.send(for: lease(port: port), mark: "ab12cd34", key: key) }
        try await waitFor { passes.waiting == 1 }
        // Held while the pass runs.
        try await Task.sleep(for: .milliseconds(200))
        #expect(passes.marks == ["ab12cd34"])
        passes.release()
        #expect(await sent.value == .read)
        // Another lease's nudge asks for no pass.
        #expect(await HubNudge.send(for: lease(epoch: 4, port: port), mark: "x", key: key) == .no)
        #expect(passes.count == 1)
    }

    @Test func aListenerWithNoMindSaysNoAndAProbeStillWorks() async throws {
        let (server, port, key) = try await started(holds: { _, epoch in epoch == 3 })
        defer { Task { await server.stop() } }
        #expect(await HubNudge.send(for: lease(port: port), mark: "ab", key: key) == .no)
        #expect(await SocketLeaseProbe().confirms(lease(port: port)))
    }

    @Test func moreNudgesThanTheCapAreAnsweredNoAtOnce() async throws {
        let passes = Passes()
        let (server, port, key) = try await started { _, _, mark, _ in
            await passes.nudged(mark, hold: true)
        }
        defer { Task { await server.stop() } }
        let held = (0..<LeaseProbeServer.nudgesAtOnce).map { i in
            Task { await HubNudge.send(for: lease(port: port), mark: "m\(i)", key: key) }
        }
        try await waitFor { passes.waiting == LeaseProbeServer.nudgesAtOnce }
        #expect(await HubNudge.send(for: lease(port: port), mark: "over", key: key) == .no)
        #expect(passes.count == LeaseProbeServer.nudgesAtOnce)
        passes.release()
        for task in held { #expect(await task.value == .read) }
    }

    @Test func nobodyListeningIsUnreachedQuickly() async throws {
        let (placeholder, port, key) = try await started(holds: { _, _ in true })
        await placeholder.stop()
        try await Task.sleep(for: .milliseconds(50))
        let began = Date()
        guard case .unreached = await HubNudge.send(for: lease(port: port), mark: "ab", key: key, connectBound: 0.5) else {
            Issue.record("a closed port answered"); return
        }
        #expect(Date().timeIntervalSince(began) < 2)
        #expect(await HubNudge.send(for: Lease(holder: hub, endpoint: nil, epoch: 1, expiresAt: Date()), mark: "ab", key: key) == .unreached("noEndpoint"))
    }

    @Test func aListenerThatNeverAnswersIsGivenUpOnAtTheBound() async throws {
        let passes = Passes()
        let (server, port, key) = try await started { _, _, mark, _ in
            await passes.nudged(mark, hold: true)
        }
        defer { Task { await server.stop(); passes.release() } }
        let began = Date()
        #expect(await HubNudge.send(for: lease(port: port), mark: "ab", key: key, answerBound: 0.5) == .unreached("answer"))
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

    /// What a streamed nudge was handed, in order.
    final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var _frames: [ReplyFrame] = []
        var frames: [ReplyFrame] { lock.withLock { _frames } }
        func add(_ frame: ReplyFrame) { lock.withLock { _frames.append(frame) } }
    }

    @Test func aStreamedNudgeHandsEveryFrameInOrderBeforeItsAnswer() async throws {
        let ref = TurnRef(device: DeviceID("phone-a"), sequence: 4)
        let words = ["Hel", "lo.\nA line", " with \"quotes\" and ünïcode", "\n\nDone."]
        let gate = Passes()
        let (server, port, key) = try await started { _, _, mark, stream in
            guard let stream else { return false }
            stream(.turn([ref]))
            stream(.message)
            for word in words { stream(.text(word)) }
            stream(.tool)
            // The pass runs on after the last frame; the answer waits for its end.
            return await gate.nudged(mark, hold: true)
        }
        defer { Task { await server.stop() } }
        let received = Received()
        let sent = Task { await HubNudge.send(for: lease(port: port), mark: "ab12cd34", key: key, stream: { received.add($0) }) }
        try await waitFor { received.frames.count == words.count + 3 }
        // Mutant: frames held back to the pass's end, or a line split across reads dropped.
        #expect(received.frames == [.turn([ref]), .message] + words.map(ReplyFrame.text) + [.tool])
        gate.release()
        #expect(await sent.value == .read)
    }

    @Test func aNudgeThatAsksNoStreamIsSentNoFrames() async throws {
        let (server, port, key) = try await started { _, _, _, stream in
            stream == nil
        }
        defer { Task { await server.stop() } }
        #expect(await HubNudge.send(for: lease(port: port), mark: "ab", key: key) == .read)
    }

    @Test func framesSurviveTheWire() {
        let frames: [ReplyFrame] = [.turn([TurnRef(device: DeviceID("a/b"), sequence: 9)]), .message, .text("x\ny\u{2028}"), .tool]
        for frame in frames {
            let line = String(decoding: frame.line, as: UTF8.self)
            #expect(line.filter { $0 == "\n" }.count == 1 && line.hasSuffix("\n"))
            #expect(ReplyFrame(line: String(line.dropLast())) == frame)
        }
        #expect(ReplyFrame(line: "read") == nil)
        #expect(ReplyFrame(line: "{\"k\":\"turn\",\"refs\":[]}") == nil)
    }

    @Test func aFailedConnectIsRememberedUntilTheNetworkChanges() async throws {
        var clock: TimeInterval = 100
        let box = Clock(clock)
        let unreached = HubNudge.Unreached(now: { box.now }, watchPath: false)
        unreached.pathChanged("satisfied pdp_ip0:cellular")
        #expect(!unreached.recently("10.0.0.2:5"))
        unreached.failed("10.0.0.2:5")
        #expect(unreached.recently("10.0.0.2:5"))
        #expect(!unreached.recently("10.0.0.3:5"))
        // The same network: still remembered, until the while is up.
        unreached.pathChanged("satisfied pdp_ip0:cellular")
        #expect(unreached.recently("10.0.0.2:5"))
        clock += HubNudge.Unreached.forgetAfter
        box.now = clock
        #expect(!unreached.recently("10.0.0.2:5"))
        // A change of network forgets at once.
        unreached.failed("10.0.0.2:5")
        unreached.pathChanged("satisfied en0:wifi")
        // Mutant: failures kept across a change of network.
        #expect(!unreached.recently("10.0.0.2:5"))
        unreached.failed("10.0.0.2:5")
        unreached.forget()
        #expect(!unreached.recently("10.0.0.2:5"))
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval
        init(_ value: TimeInterval) { self.value = value }
        var now: TimeInterval {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date() + 5
        while !condition() {
            guard Date() < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
