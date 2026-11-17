import Foundation
import Network
import Testing
import TopoCore
import TopoCoreTesting
@testable import TopoLink

/// The nudge's channel (`NudgeKey`, `NudgeTLS`): a phone with the hub's key is answered and
/// streamed to over TLS, and nothing without it — a wrong key, no key, a plain line, a replay of a
/// session, a tampered record — reaches the mind.
@Suite(.serialized) struct SecureNudgeTests {
    let hub = DeviceID("mac-hub")

    private func lease(_ endpointPort: UInt16, epoch: Int64 = 3) -> Lease {
        Lease(holder: hub, endpoint: "127.0.0.1:\(endpointPort)", epoch: epoch, expiresAt: Date().addingTimeInterval(60))
    }

    /// A hub's listener with `key`, whose nudges stream `words` and answer read; counts them.
    private func hubServer(_ key: NudgeKey?, words: String = "Hello there.") async throws -> (LeaseProbeServer, UInt16, NudgeKey?, Counter) {
        let nudges = Counter()
        let server = try LeaseProbeServer(advertising: nil, key: key, holds: { _, epoch in epoch == 3 }) { _, epoch, _, stream in
            nudges.add()
            guard epoch == 3 else { return false }
            stream?(.text(words))
            return true
        }
        let port = try await server.start()
        let bound = await server.securePort
        return (server, port, bound.flatMap { key?.on(port: $0) }, nudges)
    }

    @Test func aPhoneWithTheKeyIsStreamedTheReplyAndAnsweredRead() async throws {
        let (server, port, key, nudges) = try await hubServer(.mint(hub: hub))
        defer { Task { await server.stop() } }
        let got = Frames()
        let answer = await HubNudge.send(for: lease(port), mark: "ab12cd34", key: try #require(key), stream: { got.add($0) })
        #expect(answer == .read)
        #expect(got.all == [.text("Hello there.")])
        #expect(nudges.count == 1)
    }

    @Test func aWrongSecretIsRefusedInTheHandshakeAndNothingRuns() async throws {
        let (server, port, key, nudges) = try await hubServer(.mint(hub: hub))
        defer { Task { await server.stop() } }
        let right = try #require(key)
        let wrong = NudgeKey(hub: hub, identity: right.identity, secret: NudgeKey.mint(hub: hub).secret, port: right.port)
        let got = Frames()
        #expect(await HubNudge.send(for: lease(port), mark: "ab12cd34", key: wrong, stream: { got.add($0) }) == .unreached("handshake"))
        #expect(got.all.isEmpty)
        #expect(nudges.count == 0)
        // A handshake that failed is not a hub off the network: the right key is tried at once.
        #expect(await HubNudge.send(for: lease(port), mark: "ab12cd34", key: right) == .read)
        // The hub counts the failed handshake, and not the one that opened the channel.
        var failed = await server.handshakesFailed
        for _ in 0..<200 where failed == 0 {
            try await Task.sleep(for: .milliseconds(10))
            failed = await server.handshakesFailed
        }
        #expect(failed == 1)
    }

    /// Another hub's key is never offered to this hub's endpoint.
    @Test func anotherHubsKeyIsNotSent() async throws {
        let (server, port, key, nudges) = try await hubServer(.mint(hub: hub))
        defer { Task { await server.stop() } }
        let real = try #require(key)
        let theirs = NudgeKey(hub: DeviceID("mac-other"), identity: real.identity, secret: real.secret, port: real.port)
        #expect(await HubNudge.send(for: lease(port), mark: "ab12cd34", key: theirs) == .unreached("noKey"))
        #expect(nudges.count == 0)
    }

    @Test func anotherKeysIdentityIsRefusedInTheHandshake() async throws {
        let (server, port, key, nudges) = try await hubServer(.mint(hub: hub))
        defer { Task { await server.stop() } }
        let other = NudgeKey.mint(hub: hub).on(port: try #require(key).port)
        #expect(await HubNudge.send(for: lease(port), mark: "ab12cd34", key: other, stream: { _ in }) == .unreached("handshake"))
        #expect(nudges.count == 0)
    }

    @Test func aPlainNudgeIsAnsweredNoAndRunsNothingWhileTheProbeStillAnswers() async throws {
        let (server, port, key, nudges) = try await hubServer(.mint(hub: hub))
        defer { Task { await server.stop() } }
        for line in ["moved mac-hub 3 ab12cd34 stream\n", "moved mac-hub 3 ab12cd34\n"] {
            #expect(try await RawLine.exchange(port, line) == "no")
        }
        #expect(nudges.count == 0)
        #expect(try await RawLine.exchange(port, "hold mac-hub 3\n") == "yes")
        #expect(await SocketLeaseProbe().confirms(lease(port)))
        // The plain line to the secure port is no handshake: nothing answers it and nothing runs.
        #expect(try await RawLine.exchange(try #require(key).port, "moved mac-hub 3 ab12cd34 stream\n") != "read")
        #expect(nudges.count == 0)
    }

    @Test func aHubWithNoKeyStreamsToNobody() async throws {
        let (server, port, key, nudges) = try await hubServer(nil)
        defer { Task { await server.stop() } }
        #expect(key == nil)
        #expect(try await RawLine.exchange(port, "moved mac-hub 3 ab12cd34 stream\n") == "no")
        #expect(nudges.count == 0)
    }

    @Test func aSessionSeenOnTheWireCarriesNoWordAndCannotBePlayedAgain() async throws {
        let words = "The secret word is marmalade."
        let (server, port, key, nudges) = try await hubServer(.mint(hub: hub), words: words)
        defer { Task { await server.stop() } }
        let real = try #require(key)
        let relay = try await Relay(to: real.port)
        defer { relay.stop() }
        let got = Frames()
        #expect(await HubNudge.send(for: lease(port), mark: "ab12cd34", key: real.on(port: relay.port), stream: { got.add($0) }) == .read)
        #expect(got.all == [.text(words)])
        #expect(nudges.count == 1)
        let wire = relay.upstream + relay.downstream
        #expect(!wire.isEmpty)
        for plain in ["marmalade", "ab12cd34", "moved", "read", "mac-hub"] {
            #expect(wire.range(of: Data(plain.utf8)) == nil, "\(plain) on the wire")
        }
        // What the phone sent, played again to the hub: a new handshake under a new random of the
        // hub's, which the old bytes do not finish.
        _ = try? await RawBytes.send(real.port, relay.upstream)
        try await Task.sleep(for: .milliseconds(300))
        #expect(nudges.count == 1)
    }

    @Test func aRecordTamperedWithOnTheWayEndsTheConnectionUnread() async throws {
        let (server, port, key, nudges) = try await hubServer(.mint(hub: hub))
        defer { Task { await server.stop() } }
        let real = try #require(key)
        // What the phone seals after its handshake reaches the hub changed.
        let relay = try await Relay(to: real.port, tamper: true)
        defer { relay.stop() }
        let answer = await HubNudge.send(for: lease(port), mark: "ab12cd34", key: real.on(port: relay.port), connectBound: 2, answerBound: 3)
        #expect(answer != .read)
        #expect(nudges.count == 0)
    }

    /// The suite each end reads off its handshake is what admits it: a phone that offers only a
    /// suite with no ephemeral exchange is refused by the hub, and a hub that would agree only to
    /// one is refused by the phone, though both hold the key.
    @Test func anotherSuiteIsRefusedByEitherEnd() async throws {
        let key = NudgeKey.mint(hub: hub)
        let (server, port, bound, nudges) = try await hubServer(key)
        defer { Task { await server.stop() } }
        let weak = NudgeTLS.parameters(try #require(bound), suites: [0x00A8])
        #expect(try await RawLine.exchange(try #require(bound).port, "moved mac-hub 3 ab12cd34 stream\n", using: weak) != "read")
        #expect(nudges.count == 0)

        let other = try LeaseProbeServer(advertising: nil, key: key, suites: [0x00A8], holds: { _, _ in true }) { _, _, _, _ in
            nudges.add(); return true
        }
        let otherPort = try await other.start()
        defer { Task { await other.stop() } }
        let otherKey = key.on(port: try #require(await other.securePort))
        #expect(await HubNudge.send(for: lease(otherPort), mark: "ab12cd34", key: otherKey) == .unreached("agreement"))
        #expect(nudges.count == 0)
    }

    @Test func aKeyIsReadOncePerEpochAndAgainAfterAFailedHandshake() async throws {
        let db = CountingDatabase()
        let keys = NudgeKeys()
        #expect(await keys.key(for: lease(1), in: db) == .none)
        let key = NudgeKey.mint(hub: hub).on(port: 4242)
        try await key.save(to: db)
        #expect(await keys.key(for: lease(1), in: db) == .key(key, read: true))
        let fetches = db.fetches
        #expect(await keys.key(for: lease(1), in: db) == .key(key, read: false))
        #expect(db.fetches == fetches)
        // A hub that launched again minted another; its new epoch reads it.
        let next = NudgeKey.mint(hub: hub).on(port: 4243)
        try await next.save(to: db)
        #expect(await keys.key(for: lease(1), in: db) == .key(key, read: false))
        #expect(await keys.key(for: lease(1, epoch: 4), in: db) == .key(next, read: true))
        // A stale copy's failure leaves the newer one; the kept one's drops it.
        await keys.failed(key)
        #expect(await keys.key(for: lease(1, epoch: 4), in: db) == .key(next, read: false))
        await keys.failed(next)
        #expect(await keys.key(for: lease(1, epoch: 4), in: db) == .key(next, read: true))
        db.failing = true
        await keys.failed(next)
        #expect(await keys.key(for: lease(1, epoch: 4), in: db) == .unread("unavailable"))
    }

    /// The phone's whole path: no key record sends nothing, a gate that says no sends nothing,
    /// and a key the hub has replaced is read again after the one refused handshake.
    @Test func thePhonesPathReadsTheKeyAndReadsItAgainAfterARefusal() async throws {
        let db = InMemoryRecordDatabase()
        let keys = NudgeKeys()
        let (server, port, bound, nudges) = try await hubServer(.mint(hub: hub))
        defer { Task { await server.stop() } }
        let current = try #require(bound)
        #expect(await HubNudge.send(for: lease(port), mark: "ab12cd34", keys: keys, in: db) == .unreached("noKey"))
        #expect(nudges.count == 0)
        try await current.save(to: db)
        #expect(await HubNudge.send(for: lease(port), mark: "ab12cd34", keys: keys, in: db, reachable: { _, _ in false }) == .unreached("gated"))
        #expect(nudges.count == 0)
        let asked = Asked()
        #expect(await HubNudge.send(for: lease(port), mark: "ab12cd34", keys: keys, in: db,
                                    reachable: { host, port in asked.add("\(host):\(port)"); return true }) == .read)
        #expect(asked.all == ["127.0.0.1:\(current.port)"])
        #expect(nudges.count == 1)
        // The hub's key replaced under the same epoch: the kept copy is refused once, dropped,
        // and the record read again.
        let stale = NudgeKey.mint(hub: hub).on(port: current.port)
        try await stale.save(to: db)
        let fresh = NudgeKeys()
        #expect(await fresh.key(for: lease(port), in: db) == .key(stale, read: true))
        #expect(await HubNudge.send(for: lease(port), mark: "ab12cd34", keys: fresh, in: db) == .unreached("handshake"))
        try await current.save(to: db)
        #expect(await HubNudge.send(for: lease(port), mark: "ab12cd34", keys: fresh, in: db) == .read)
        #expect(nudges.count == 2)
    }

    /// The phone kept the last launch's key, whose channel's port is now closed, under an epoch the
    /// new launch's key record had not reached yet: the refused connect mutes the endpoint and
    /// drops the copy, so the first nudge after the mute reads the record again and is answered.
    @Test func aKeyWhosePortIsClosedIsReadAgainOnceTheMuteIsOver() async throws {
        HubNudge.Unreached.shared.forget()
        defer { HubNudge.Unreached.shared.forget() }
        let db = InMemoryRecordDatabase()
        let keys = NudgeKeys()
        let (old, _, oldKey, _) = try await hubServer(.mint(hub: hub))
        try await #require(oldKey).save(to: db)
        await old.stop()
        try await Task.sleep(for: .milliseconds(200))
        let (server, port, liveKey, nudges) = try await hubServer(.mint(hub: hub))
        defer { Task { await server.stop() } }
        #expect(await HubNudge.send(for: lease(port), mark: "ab12cd34", keys: keys, in: db) == .unreached("connect"))
        try await #require(liveKey).save(to: db)
        // Muted: no read of the record and no connect.
        #expect(await HubNudge.send(for: lease(port), mark: "ab12cd34", keys: keys, in: db) == .unreached("recently"))
        HubNudge.Unreached.shared.forget()
        // Mutant: the copy kept after a refused connect, which is the dead port again.
        #expect(await HubNudge.send(for: lease(port), mark: "ab12cd34", keys: keys, in: db) == .read)
        #expect(nudges.count == 1)
    }

    /// A hub reached whose handshake has not finished at the connect bound is not a hub off the
    /// network: the endpoint is not muted and the next nudge tries it at once.
    @Test func aHandshakeSlowerThanTheBoundIsNotAHubOffTheNetwork() async throws {
        HubNudge.Unreached.shared.forget()
        defer { HubNudge.Unreached.shared.forget() }
        let silent = try await SilentListener()
        defer { silent.stop() }
        let key = NudgeKey.mint(hub: hub).on(port: silent.port)
        let endpointLease = Lease(holder: hub, endpoint: "127.0.0.1:\(silent.port)", epoch: 3, expiresAt: Date().addingTimeInterval(60))
        // Mutant: a bound that runs out said as `connectTimeout` whether or not TCP connected.
        #expect(await HubNudge.send(for: endpointLease, mark: "ab12cd34", key: key, connectBound: 0.5) == .unreached("handshakeTimeout"))
        #expect(!HubNudge.Unreached.shared.recently("127.0.0.1:\(silent.port)"))
    }

    /// A host that never answers runs out as a connect that was not made, and is muted.
    @Test func aHostThatNeverAnswersRunsOutUnconnected() async throws {
        HubNudge.Unreached.shared.forget()
        defer { HubNudge.Unreached.shared.forget() }
        // TEST-NET-1 (RFC 5737): routed nowhere, so a SYN to it is never answered, or the route refused.
        let nowhere = Lease(holder: hub, endpoint: "192.0.2.1:4567", epoch: 3, expiresAt: Date().addingTimeInterval(60))
        let key = NudgeKey.mint(hub: hub).on(port: 4567)
        let answer = await HubNudge.send(for: nowhere, mark: "ab12cd34", key: key, connectBound: 0.5)
        // Mutant: every bound that runs out said as a slow handshake.
        #expect(answer == .unreached("connectTimeout") || answer == .unreached("connect"), "\(answer)")
        #expect(HubNudge.Unreached.shared.recently("192.0.2.1:4567"))
    }

    /// A key with no port is no key: nothing is connected to.
    @Test func aKeyWithNoPortIsNotUsed() async throws {
        HubNudge.Unreached.shared.forget()
        let (server, port, _, nudges) = try await hubServer(.mint(hub: hub))
        defer { Task { await server.stop() } }
        // Mutant: the port's guard gone, which connects to port 0.
        #expect(await HubNudge.send(for: lease(port), mark: "ab12cd34", key: NudgeKey.mint(hub: hub)) == .unreached("noKey"))
        #expect(nudges.count == 0)
        #expect(!HubNudge.Unreached.shared.recently("127.0.0.1:\(port)"))
    }

    /// The key's save goes again over the version a conflict names, and gives up after three.
    @Test func theKeysSaveGoesAgainOverAConflict() async throws {
        let db = ConflictingSaves(conflicts: 2)
        let key = NudgeKey.mint(hub: hub).on(port: 4242)
        // Mutant: a conflict thrown at once.
        try await key.save(to: db)
        #expect(try await NudgeKey.read(for: hub, from: db) == key)
        let always = ConflictingSaves(conflicts: 3)
        await #expect(throws: NudgeKey.Contended.self) { try await key.save(to: always) }
    }

    /// A connection to the channel that never begins its handshake is closed at the bound.
    @Test func silenceOnTheChannelIsClosedAtTheBound() async throws {
        let (server, _, key, _) = try await hubServer(.mint(hub: hub))
        defer { Task { await server.stop() } }
        let began = Date()
        _ = try? await RawLine.exchange(try #require(key).port, nil, wait: LeaseProbeServer.requestBound + 3)
        let took = Date().timeIntervalSince(began)
        #expect(took >= LeaseProbeServer.requestBound - 0.5 && took < LeaseProbeServer.requestBound + 3)
    }

    @Test func aRecordThatIsNotAWholeKeyIsNone() throws {
        #expect(NudgeKey.mint(hub: hub).identity != NudgeKey.mint(hub: hub).identity)
        let key = NudgeKey.mint(hub: hub).on(port: 4242)
        #expect(NudgeKey(record: key.record(changeTag: nil)) == key)
        var short = key.record(changeTag: nil)
        short.fields["secret"] = .string(Data(count: 16).base64EncodedString())
        #expect(NudgeKey(record: short) == nil)
        var portless = key.record(changeTag: nil)
        portless.fields["port"] = .int(0)
        #expect(NudgeKey(record: portless) == nil)
        var elsewhere = key.record(changeTag: nil)
        elsewhere.fields["hub"] = .string("mac-other")
        #expect(NudgeKey(record: elsewhere) == nil)
        // Mutant: an identity that is not sixteen lowercase hex digits taken.
        for identity in ["0123456789ABCDEF", "0123456789abcde", "0123456789abcdeg"] {
            var named = key.record(changeTag: nil)
            named.fields["identity"] = .string(identity)
            #expect(NudgeKey(record: named) == nil, "\(identity)")
        }
    }

    /// A failure is said by its kind: a conflict's error carries the record, which is the secret.
    @Test func aFailureIsSaidByKind() {
        let key = NudgeKey.mint(hub: hub)
        let conflict = RecordDatabaseError.serverRecordChanged(NudgeKey.recordID(for: hub), server: key.record(changeTag: "t"))
        #expect(NudgeKey.kind(of: conflict) == "contended")
        #expect(NudgeKey.kind(of: NudgeKey.Contended()) == "contended")
        #expect(NudgeKey.kind(of: RecordDatabaseError.unavailable(underlying: URLError(.timedOut))) == "unavailable")
    }

    @Test func nothingSaysTheSecret() {
        let key = NudgeKey.mint(hub: hub)
        let secret = key.secret.base64EncodedString()
        var dumped = ""
        dump(key, to: &dumped)
        for said in [String(describing: key), String(reflecting: key), "\(key)", dumped] {
            #expect(!said.contains(secret))
            #expect(said.contains(key.identity))
        }
    }

    /// The key's record printed as a whole, and an error that carries it, as a generic log line
    /// would print them, say every field but the secret.
    @Test func noPrintOfTheKeysRecordSaysTheSecret() {
        let key = NudgeKey.mint(hub: hub).on(port: 4242)
        let secret = key.secret.base64EncodedString()
        let record = key.record(changeTag: "t")
        let conflict = RecordDatabaseError.serverRecordChanged(record.id, server: record)
        var dumped = "", dumpedError = ""
        dump(record, to: &dumped)
        dump(conflict, to: &dumpedError)
        // Mutant: `Record` printed by Swift's default, every field whole.
        for said in [String(describing: record), String(reflecting: record), "\(record)", dumped,
                     String(describing: conflict), String(reflecting: conflict), "\(conflict)", dumpedError] {
            #expect(!said.contains(secret), "\(said)")
            #expect(said.contains(key.identity))
        }
        #expect(NudgeKey(record: record) == key, "the secret is in the record all the same")
    }
}

// MARK: - Doubles

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func add() { lock.withLock { n += 1 } }
}

final class Frames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [ReplyFrame] = []
    var all: [ReplyFrame] { lock.withLock { frames } }
    func add(_ frame: ReplyFrame) { lock.withLock { frames.append(frame) } }
}

final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var said: [String] = []
    var all: [String] { lock.withLock { said } }
    func add(_ s: String) { lock.withLock { said.append(s) } }
}

/// The in-memory store, counting fetches, and failing them while `failing`.
final class CountingDatabase: RecordDatabase, @unchecked Sendable {
    private let inner = InMemoryRecordDatabase()
    private let lock = NSLock()
    private var _fetches = 0
    private var _failing = false
    var fetches: Int { lock.withLock { _fetches } }
    var failing: Bool {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }
    func save(_ records: [Record]) async throws -> [Record] { try await inner.save(records) }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] {
        lock.withLock { _fetches += 1 }
        if failing { throw RecordDatabaseError.unavailable(underlying: URLError(.notConnectedToInternet)) }
        return try await inner.fetch(ids)
    }
    func query(_ query: RecordQuery) async throws -> [Record] { try await inner.query(query) }
    func records(ofType type: String) async throws -> [Record] { try await inner.records(ofType: type) }
}

/// One connection to a local port: `line` sent (if any), and the first line back, or nil when the
/// connection ends or `wait` passes with none.
enum RawLine {
    static func exchange(_ port: UInt16, _ line: String?, using parameters: NWParameters = .tcp,
                         wait: TimeInterval = 3) async throws -> String? {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        let deadline = Task {
            try? await Task.sleep(for: .seconds(wait))
            connection.cancel()
        }
        defer { deadline.cancel(); connection.cancel() }
        connection.start(queue: DispatchQueue(label: "test.raw"))
        try await connection.waitUntilReady()
        if let line { try await connection.send(Data(line.utf8)) }
        let answer = try? await connection.readLine(maximum: 256)
        return answer.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

enum RawBytes {
    /// `bytes` written to a local port in one go, the connection then held a moment and closed.
    static func send(_ port: UInt16, _ bytes: Data) async throws {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        connection.start(queue: DispatchQueue(label: "test.bytes"))
        try await connection.waitUntilReady()
        try await connection.send(bytes)
        _ = try? await RawLine.within(1) { try await connection.readLine(maximum: 4096) }
    }
}

extension RawLine {
    static func within<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T? {
        await LeaseProbeServer.within(seconds, work)
    }
}

/// A TCP relay on a local port to `target`, keeping every byte each way; with `tamper`, the
/// client's sealed records reach the target with every byte of their payload changed.
final class Relay: @unchecked Sendable {
    private final class Tap: @unchecked Sendable {
        let lock = NSLock()
        var up = Data()
        var down = Data()
        var connections: [NWConnection] = []
    }
    private let listener: NWListener
    private let tap = Tap()
    let port: UInt16
    var upstream: Data { tap.lock.withLock { tap.up } }
    var downstream: Data { tap.lock.withLock { tap.down } }

    init(to target: UInt16, tamper: Bool = false) async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let tap = self.tap
        let box = OneShot<UInt16>()
        listener.stateUpdateHandler = { [weak listener] state in
            if case .ready = state { box.resume(.success(listener?.port?.rawValue ?? 0)) }
            if case .failed(let error) = state { box.resume(.failure(error)) }
        }
        let queue = DispatchQueue(label: "test.relay")
        @Sendable func pump(_ from: NWConnection, _ to: NWConnection, upstream: Bool) {
            from.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                if var data, !data.isEmpty {
                    tap.lock.withLock {
                        if upstream {
                            // A chunk that begins an application-data record (type 23) has its
                            // sealed payload changed, its header left whole.
                            if tamper, data.first == 23, data.count > 5 {
                                for i in data.indices.dropFirst(5) { data[i] ^= 0x01 }
                            }
                            tap.up.append(data)
                        } else {
                            tap.down.append(data)
                        }
                    }
                    to.send(content: data, completion: .idempotent)
                }
                if complete || error != nil {
                    to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                    return
                }
                pump(from, to, upstream: upstream)
            }
        }
        listener.newConnectionHandler = { client in
            let server = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: target)!, using: .tcp)
            tap.lock.withLock { tap.connections += [client, server] }
            client.start(queue: queue)
            server.start(queue: queue)
            pump(client, server, upstream: true)
            pump(server, client, upstream: false)
        }
        listener.start(queue: queue)
        port = try await box.value()
    }

    func stop() {
        listener.cancel()
        tap.lock.withLock { tap.connections.forEach { $0.cancel() } }
    }
}

/// A TCP listener on a local port that takes every connection and never says a byte: a hub whose
/// channel's handshake does not finish.
final class SilentListener: @unchecked Sendable {
    private final class Held: @unchecked Sendable {
        private let lock = NSLock()
        private var connections: [NWConnection] = []
        func keep(_ connection: NWConnection) { lock.withLock { connections.append(connection) } }
    }
    private let listener: NWListener
    private let held = Held()
    let port: UInt16
    init() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let box = OneShot<UInt16>()
        listener.newConnectionHandler = { [held] connection in
            held.keep(connection)
            connection.start(queue: DispatchQueue(label: "test.silent"))
        }
        listener.stateUpdateHandler = { [weak listener] state in
            if case .ready = state { box.resume(.success(listener?.port?.rawValue ?? 0)) }
            if case .failed(let error) = state { box.resume(.failure(error)) }
        }
        listener.start(queue: DispatchQueue(label: "test.silent.listener"))
        port = try await box.value()
    }
    func stop() { listener.cancel() }
}

/// A store whose first `conflicts` saves of a record lose to another writer between the read and
/// the save, as `serverRecordChanged` with that writer's version.
final class ConflictingSaves: RecordDatabase, @unchecked Sendable {
    private let inner = InMemoryRecordDatabase()
    private let lock = NSLock()
    private var left: Int
    init(conflicts: Int) { left = conflicts }
    func save(_ records: [Record]) async throws -> [Record] {
        let lose = lock.withLock { () -> Bool in defer { left -= 1 }; return left > 0 }
        if lose, let record = records.first {
            let saved = try await inner.save([Record(type: record.type, id: record.id, fields: [:], changeTag: try await inner.fetch(record.id)?.changeTag)])
            throw RecordDatabaseError.serverRecordChanged(record.id, server: saved[0])
        }
        return try await inner.save(records)
    }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await inner.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await inner.query(query) }
    func records(ofType type: String) async throws -> [Record] { try await inner.records(ofType: type) }
}
