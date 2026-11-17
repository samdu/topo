import Foundation
import Network
import Testing
import TopoCore
import TopoCoreTesting
@testable import TopoLink

/// The heads-up (`HubNudge.Coming`, `ProbeWire`'s `coming` and `saved`): taken on the channel
/// alone, answered `ready` when the owner has a pass getting ready, and its connection then
/// carries the saved turn's ref and the nudge of the same lease and mark.
@Suite(.serialized) struct ComingWireTests {
    let hub = DeviceID("mac-hub")

    private func lease(_ endpointPort: UInt16, epoch: Int64 = 3) -> Lease {
        Lease(holder: hub, endpoint: "127.0.0.1:\(endpointPort)", epoch: epoch, expiresAt: Date().addingTimeInterval(60))
    }

    /// What the owner was told, in order.
    final class Told: @unchecked Sendable {
        private let lock = NSLock()
        private var said: [String] = []
        var all: [String] { lock.withLock { said } }
        func add(_ s: String) { lock.withLock { said.append(s) } }
    }

    /// A hub's listener with a key that takes heads-ups when `takes` says so, streams one frame to
    /// a nudge and answers it read; `told` records what reached the owner.
    private func hubServer(takes: Bool = true, coming: Bool = true, reads: Bool = true) async throws -> (LeaseProbeServer, UInt16, NudgeKey, Told) {
        let told = Told()
        let key = NudgeKey.mint(hub: hub)
        let server = try LeaseProbeServer(advertising: nil, key: key, holds: { _, epoch in epoch == 3 }, nudged: { _, epoch, mark, stream in
            told.add("nudged \(mark)")
            guard epoch == 3, reads else { return false }
            stream?(.text("Hello."))
            return true
        }, coming: coming ? { @Sendable _, epoch, mark in
            told.add("coming \(mark)")
            guard takes, epoch == 3 else { return nil }
            return LeaseProbeServer.ComingTicket(saved: { told.add("saved \($0)") }, ended: { told.add("ended") })
        } : nil)
        let port = try await server.start()
        let secure = try #require(await server.securePort)
        return (server, port, key.on(port: secure), told)
    }

    private func keys(_ key: NudgeKey, for lease: Lease) async -> NudgeKeys {
        let keys = NudgeKeys()
        let db = InMemoryRecordDatabase()
        try? await key.save(to: db)
        _ = await keys.key(for: lease, in: db)
        return keys
    }

    @Test func aHeadsUpTheHubTakesCarriesTheSavedTurnAndItsNudge() async throws {
        let (server, port, key, told) = try await hubServer()
        defer { Task { await server.stop() } }
        let lease = lease(port)
        let coming = HubNudge.Coming.begin(for: lease, mark: "ab12cd34", keys: await keys(key, for: lease))
        let got = Frames()
        let answer = await coming.saved(.init(device: DeviceID("phone-1a2b3c4d"), sequence: 7), stream: { got.add($0) })
        #expect(answer == .read)
        #expect(got.all == [.text("Hello.")])
        // Mutant: the nudge handed to the owner before the ticket hears the ref.
        #expect(told.all == ["coming ab12cd34", "saved phone-1a2b3c4d/7", "nudged ab12cd34"])
    }

    /// The hub's `no` to the saved line (its wait ended first, or its mind stopped) is no answer
    /// the phone keeps: the nudge goes the usual way, as with no heads-up.
    @Test func aSavedLineAnsweredNoLeavesTheNudgeToGoTheUsualWay() async throws {
        let (server, port, key, told) = try await hubServer(reads: false)
        defer { Task { await server.stop() } }
        let lease = lease(port)
        let coming = HubNudge.Coming.begin(for: lease, mark: "ab12cd34", keys: await keys(key, for: lease))
        // Mutant: any answer to the saved line kept as the nudge's.
        #expect(await coming.nudged(.init(device: DeviceID("phone-1a2b3c4d"), sequence: 7), stream: nil) == nil)
        #expect(told.all == ["coming ab12cd34", "saved phone-1a2b3c4d/7", "nudged ab12cd34"])
        let read = try await hubServer()
        defer { Task { await read.0.stop() } }
        let readLease = self.lease(read.1)
        let taken = HubNudge.Coming.begin(for: readLease, mark: "ab12cd34", keys: await keys(read.2, for: readLease))
        #expect(await taken.nudged(.init(device: DeviceID("phone-1a2b3c4d"), sequence: 7), stream: nil) == true)
    }

    @Test func aHeadsUpTheHubDoesNotTakeLeavesTheNudgeToGoTheUsualWay() async throws {
        let (server, port, key, told) = try await hubServer(takes: false)
        defer { Task { await server.stop() } }
        let lease = lease(port)
        let coming = HubNudge.Coming.begin(for: lease, mark: "ab12cd34", keys: await keys(key, for: lease))
        #expect(await coming.saved(.init(device: DeviceID("phone-1a2b3c4d"), sequence: 7), stream: nil) == nil)
        #expect(told.all == ["coming ab12cd34"])
    }

    @Test func aHubBuiltBeforeTheHeadsUpAnswersNoAndRunsNothing() async throws {
        let (server, port, key, told) = try await hubServer(coming: false)
        defer { Task { await server.stop() } }
        let lease = lease(port)
        let coming = HubNudge.Coming.begin(for: lease, mark: "ab12cd34", keys: await keys(key, for: lease))
        #expect(await coming.saved(.init(device: DeviceID("phone-1a2b3c4d"), sequence: 7), stream: nil) == nil)
        #expect(told.all.isEmpty)
        // The plain nudge still goes.
        #expect(await HubNudge.send(for: lease, mark: "ab12cd34", key: key) == .read)
    }

    @Test func aPhoneWithNoKeptKeySendsNothing() async throws {
        let (server, port, _, told) = try await hubServer()
        defer { Task { await server.stop() } }
        let coming = HubNudge.Coming.begin(for: lease(port), mark: "ab12cd34", keys: NudgeKeys())
        #expect(await coming.saved(.init(device: DeviceID("phone-1a2b3c4d"), sequence: 7), stream: nil) == nil)
        #expect(told.all.isEmpty)
    }

    @Test func aHeadsUpClosedBeforeItsSaveEndsTheWait() async throws {
        let (server, port, key, told) = try await hubServer()
        defer { Task { await server.stop() } }
        let lease = lease(port)
        let coming = HubNudge.Coming.begin(for: lease, mark: "ab12cd34", keys: await keys(key, for: lease))
        #expect(await eventually { told.all == ["coming ab12cd34"] })
        coming.cancel()
        // Mutant: the ticket not told the heads-up ended when no save line comes.
        #expect(await eventually(2) { told.all == ["coming ab12cd34", "ended"] })
        #expect(await coming.saved(.init(device: DeviceID("phone-1a2b3c4d"), sequence: 7), stream: nil) == nil)
    }

    @Test func aHeadsUpOnThePlainPortOrASavedLineFirstIsAnsweredNo() async throws {
        let (server, port, key, told) = try await hubServer()
        defer { Task { await server.stop() } }
        #expect(try await RawLine.exchange(port, "coming mac-hub 3 ab12cd34\n") == "no")
        #expect(try await RawLine.exchange(port, "saved phone-1a2b3c4d/7\n") == "no")
        #expect(told.all.isEmpty)
        // As the channel's first line, a saved line is no heads-up.
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: key.port)!, using: NudgeTLS.parameters(key))
        defer { connection.cancel() }
        connection.start(queue: DispatchQueue(label: "test.saved"))
        try await connection.waitUntilReady()
        try await connection.send(Data("saved phone-1a2b3c4d/7 stream\n".utf8))
        #expect(try await connection.readLine(maximum: 16).trimmingCharacters(in: .whitespacesAndNewlines) == "no")
        #expect(told.all.isEmpty)
    }

    @Test func aLineAfterReadyThatIsNotASaveEndsTheHeadsUp() async throws {
        let (server, _, key, told) = try await hubServer()
        defer { Task { await server.stop() } }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: key.port)!, using: NudgeTLS.parameters(key))
        defer { connection.cancel() }
        connection.start(queue: DispatchQueue(label: "test.garbage"))
        try await connection.waitUntilReady()
        try await connection.send(Data("coming mac-hub 3 ab12cd34\n".utf8))
        let lines = NWConnection.Lines(connection)
        #expect(try await lines.next(maximum: 16) == "ready")
        try await connection.send(Data("saved ../etc/7\n".utf8))
        #expect(try await lines.next(maximum: 16) == "no")
        #expect(told.all == ["coming ab12cd34", "ended"])
    }

    @Test func theWireParsesItsLinesAndNothingElse() {
        #expect(ProbeWire.parse("coming mac-hub 3 ab12cd34") == .coming(hub, 3, mark: "ab12cd34"))
        #expect(ProbeWire.parse("saved phone-1a2b3c4d/7") == .saved(.init(device: DeviceID("phone-1a2b3c4d"), sequence: 7), stream: false))
        #expect(ProbeWire.parse("saved phone-1a2b3c4d/7 stream") == .saved(.init(device: DeviceID("phone-1a2b3c4d"), sequence: 7), stream: true))
        for line in ["coming mac-hub 3", "coming mac-hub x ab12cd34", "coming mac-hub 3 ab-12", "saved phone/0", "saved phone",
                     "saved ph one/1", "saved phone/1 words", "saved a/b/1", "coming mac-hub 3 ab12cd34 stream"] {
            #expect(ProbeWire.parse(line) == nil, "\(line)")
        }
        // A plain `moved` is the line it always was, so a hub built before the heads-up takes it.
        let lease = Lease(holder: hub, endpoint: "127.0.0.1:1", epoch: 3, expiresAt: Date())
        #expect(String(decoding: ProbeWire.nudge(lease, mark: "ab12cd34", stream: true), as: UTF8.self) == "moved mac-hub 3 ab12cd34 stream\n")
        #expect(String(decoding: ProbeWire.coming(lease, mark: "ab12cd34"), as: UTF8.self) == "coming mac-hub 3 ab12cd34\n")
    }

    @Test func theHeadsUpsHoldTheNudgesPlaces() async throws {
        let told = Told()
        let key = NudgeKey.mint(hub: hub)
        let server = try LeaseProbeServer(advertising: nil, key: key, holds: { _, _ in true }, nudged: { _, _, _, _ in true },
                                          coming: { _, _, mark in
            told.add(mark)
            return LeaseProbeServer.ComingTicket(saved: { _ in }, ended: {})
        })
        defer { Task { await server.stop() } }
        _ = try await server.start()
        let secure = key.on(port: try #require(await server.securePort))
        var open: [NWConnection] = []
        defer { open.forEach { $0.cancel() } }
        for i in 0..<LeaseProbeServer.nudgesAtOnce {
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: secure.port)!, using: NudgeTLS.parameters(secure))
            connection.start(queue: DispatchQueue(label: "test.place.\(i)"))
            try await connection.waitUntilReady()
            try await connection.send(Data("coming mac-hub 3 m\(i)\n".utf8))
            #expect(try await NWConnection.Lines(connection).next(maximum: 16) == "ready")
            open.append(connection)
        }
        // One more, past the places: answered no, and the owner is asked nothing.
        let more = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: secure.port)!, using: NudgeTLS.parameters(secure))
        defer { more.cancel() }
        more.start(queue: DispatchQueue(label: "test.place.more"))
        try await more.waitUntilReady()
        try await more.send(Data("coming mac-hub 3 more\n".utf8))
        #expect(try await more.readLine(maximum: 16).trimmingCharacters(in: .whitespacesAndNewlines) == "no")
        #expect(told.all.count == LeaseProbeServer.nudgesAtOnce)
    }
}

func eventually(_ seconds: Double = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
