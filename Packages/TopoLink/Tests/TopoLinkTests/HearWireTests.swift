import Foundation
import Network
import Testing
import TopoCore
import TopoCoreTesting
@testable import TopoLink

/// A hand-over of the person's words (`HubNudge.hear`, `ProbeWire.hear`): taken on the nudge's
/// channel alone, length-prefixed and bounded, and nothing of it on the plain port or the wire.
@Suite(.serialized) struct HearWireTests {
    let hub = DeviceID("mac-hub")
    let nonce = "7D3F2A10-4B5C-4D6E-8F90-A1B2C3D4E5F6"

    private func lease(_ port: UInt16, epoch: Int64 = 3) -> Lease {
        Lease(holder: hub, endpoint: "127.0.0.1:\(port)", epoch: epoch, expiresAt: Date().addingTimeInterval(60))
    }

    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var got: [(Int64, String, String, String)] = []
        var all: [(epoch: Int64, nonce: String, model: String, words: String)] { lock.withLock { got.map { ($0.0, $0.1, $0.2, $0.3) } } }
        func add(_ e: Int64, _ n: String, _ m: String, _ w: String) { lock.withLock { got.append((e, n, m, w)) } }
    }

    /// A hub whose mind takes words at epoch 3.
    private func hubServer(_ key: NudgeKey?, takes: Bool = true) async throws -> (LeaseProbeServer, UInt16, NudgeKey?, Heard) {
        let heard = Heard()
        let server = try LeaseProbeServer(advertising: nil, key: key, holds: { _, epoch in epoch == 3 },
                                          nudged: { _, _, _, _ in true },
                                          heard: { _, epoch, nonce, model, words in
            heard.add(epoch, nonce, model, words)
            return takes && epoch == 3
        })
        let port = try await server.start()
        let bound = await server.securePort
        return (server, port, bound.flatMap { key?.on(port: $0) }, heard)
    }

    @Test func wordsHandedOverOnTheChannelReachTheMindWhole() async throws {
        let (server, port, key, heard) = try await hubServer(.mint(hub: hub))
        defer { Task { await server.stop() } }
        let words = "Turn the hall lights off.\nAnd then — ünïcode, a\u{0} null, and \"quotes\"."
        #expect(await HubNudge.hear(words, nonce: nonce, model: "sonnet", for: lease(port), key: try #require(key)) == .heard)
        let got = try #require(heard.all.first)
        #expect(heard.all.count == 1)
        #expect(got.words == words)
        #expect(got.nonce == nonce)
        #expect(got.model == "sonnet")
        #expect(got.epoch == 3)
    }

    @Test func aMindThatDoesNotTakeThemIsAnsweredNo() async throws {
        let (server, port, key, heard) = try await hubServer(.mint(hub: hub), takes: false)
        defer { Task { await server.stop() } }
        #expect(await HubNudge.hear("words", nonce: nonce, model: "sonnet", for: lease(port), key: try #require(key)) == .no)
        #expect(heard.all.count == 1)
    }

    /// Mutant: the plain port taking a hand-over.
    final class Took: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        var taken: Bool { lock.withLock { done } }
        func take() { lock.withLock { done = true } }
    }

    /// A mind slower to answer than the hub's bound: the hear is cancelled there, and the answer
    /// sent is the mind's own, so a phone is never told `no` for words the mind took. A phone whose
    /// own bound runs out first knows only that they went.
    @Test(arguments: [5.0, 10.0])
    func aSlowMindIsNeverAnsweredNoForWordsItTook(phoneBound: Double) async throws {
        let took = Took()
        let key = NudgeKey.mint(hub: hub)
        let server = try LeaseProbeServer(advertising: nil, key: key, holds: { _, _ in true },
                                          nudged: { _, _, _, _ in true },
                                          heard: { _, _, _, _, _ in
            // A mind past its point of no return when the bound lands: it takes them all the same.
            try? await Task.sleep(for: .seconds(5.5))
            took.take()
            return true
        })
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let secure = try #require(await server.securePort)
        let answer = await HubNudge.hear("words", nonce: nonce, model: "sonnet", for: lease(port),
                                         key: key.on(port: secure), answerBound: phoneBound)
        try await Task.sleep(for: .seconds(1))
        #expect(took.taken)
        // Mutant: the answer given up at the bound, `no` while the mind took the words.
        #expect(answer != .no)
        if phoneBound > 6 { #expect(answer == .heard) }
    }

    /// A mind that honours the cancellation at the bound, taking nothing: answered `no`, at once.
    @Test func aSlowMindThatTakesNothingAtTheBoundIsAnsweredNo() async throws {
        let took = Took()
        let key = NudgeKey.mint(hub: hub)
        let server = try LeaseProbeServer(advertising: nil, key: key, holds: { _, _ in true },
                                          nudged: { _, _, _, _ in true },
                                          heard: { _, _, _, _, _ in
            do { try await Task.sleep(for: .seconds(30)) } catch { return false }
            took.take()
            return true
        })
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let secure = try #require(await server.securePort)
        let began = ContinuousClock.now
        let answer = await HubNudge.hear("words", nonce: nonce, model: "sonnet", for: lease(port),
                                         key: key.on(port: secure), answerBound: 10)
        #expect(answer == .no)
        #expect(ContinuousClock.now - began < .seconds(8))
        #expect(!took.taken)
    }

    @Test func aHandOverOnThePlainPortIsAnsweredNoAndReachesNothing() async throws {
        let (server, port, _, heard) = try await hubServer(.mint(hub: hub))
        defer { Task { await server.stop() } }
        let wire = ProbeWire.hear(lease(port), nonce: nonce, model: "sonnet", words: "words")
        let answer = try await RawBytes.exchange(port, wire)
        #expect(answer == "no")
        #expect(heard.all.isEmpty)
        // A hub with no key takes none on any port.
        let (keyless, keylessPort, none, keylessHeard) = try await hubServer(nil)
        defer { Task { await keyless.stop() } }
        #expect(none == nil)
        #expect(try await RawBytes.exchange(keylessPort, wire) == "no")
        #expect(keylessHeard.all.isEmpty)
    }

    /// The header is judged before any of the body is read: a nonce that is not a UUID, a model
    /// that is not a name, a length of nothing or past the bound, is no request.
    @Test func aHeaderOutOfBoundsIsNoRequest() {
        let base = "hear mac-hub 3"
        for bad in ["\(base) not-a-uuid sonnet 5", "\(base) \(nonce) son/net 5", "\(base) \(nonce) sonnet 0",
                    "\(base) \(nonce) sonnet \(HubNudge.hearMaximum + 1)", "\(base) \(nonce) sonnet -1",
                    "\(base) \(nonce) sonnet", "\(base) \(nonce) \(String(repeating: "a", count: 41)) 5"] {
            // Mutant: a length past the bound accepted.
            #expect(ProbeWire.parse(bad) == nil, "\(bad)")
        }
        guard case .hear(let device, 3, let n, "opus", 12)? = ProbeWire.parse("\(base) \(nonce) opus 12") else {
            Issue.record("a whole header not parsed"); return
        }
        #expect(device == hub && n == nonce)
        #expect(!HubNudge.canHear("", nonce: nonce, model: "sonnet"))
        #expect(!HubNudge.canHear(String(repeating: "x", count: HubNudge.hearMaximum + 1), nonce: nonce, model: "sonnet"))
        #expect(HubNudge.canHear(String(repeating: "x", count: HubNudge.hearMaximum), nonce: nonce, model: "sonnet"))
    }

    /// A body shorter than its length is never a hand-over: the hub waits its bound and answers
    /// no, and the mind is never handed part of the words.
    @Test func aBodyCutShortReachesNothing() async throws {
        let (server, _, key, heard) = try await hubServer(.mint(hub: hub))
        defer { Task { await server.stop() } }
        let channel = try #require(key)
        let header = "hear mac-hub 3 \(nonce) sonnet 20\nonly ten b"
        let answer = try await RawLine.exchange(channel.port, header, using: NudgeTLS.parameters(channel), wait: LeaseProbeServer.requestBound + 1)
        #expect(answer != "heard")
        try await Task.sleep(for: .milliseconds(200))
        #expect(heard.all.isEmpty)
    }

    @Test func noWordOfAHandOverIsOnTheWire() async throws {
        let words = "The secret word is marmalade."
        let (server, port, key, heard) = try await hubServer(.mint(hub: hub))
        defer { Task { await server.stop() } }
        let real = try #require(key)
        let relay = try await Relay(to: real.port)
        defer { relay.stop() }
        #expect(await HubNudge.hear(words, nonce: nonce, model: "sonnet", for: lease(port), key: real.on(port: relay.port)) == .heard)
        #expect(heard.all.count == 1)
        let wire = relay.upstream + relay.downstream
        for plain in ["marmalade", nonce, "hear", "heard", "sonnet"] {
            #expect(wire.range(of: Data(plain.utf8)) == nil, "\(plain) on the wire")
        }
    }

    /// A hub that knows no `hear` (an older build) answers the line `no` and reads none of the
    /// body as a request: the phone takes that as words not handed over.
    @Test func anOlderHubAnswersNoAndThePhoneGoesByTheLog() async throws {
        let key = NudgeKey.mint(hub: hub)
        let server = try LeaseProbeServer(advertising: nil, key: key, holds: { _, _ in true }, nudged: { _, _, _, _ in true })
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let bound = key.on(port: try #require(await server.securePort))
        #expect(await HubNudge.hear("words", nonce: nonce, model: "sonnet", for: lease(port), key: bound) == .no)
        // The channel still nudges as ever.
        #expect(await HubNudge.send(for: lease(port), mark: "ab12cd34", key: bound) == .read)
    }

    @Test func aHubOffTheNetworkIsUnknownAndNotSent() async throws {
        let key = NudgeKey.mint(hub: hub).on(port: 1)
        let answer = await HubNudge.hear("words", nonce: nonce, model: "sonnet", for: lease(1), key: key, connectBound: 1)
        guard case .unknown(_, sent: false) = answer else { Issue.record("\(answer)"); return }
    }

    /// A hand-over to a hub reached whose handshake is slow is not a hub off the network: it
    /// mutes nothing, so the nudge after the save still goes, and drops the kept key as a nudge's
    /// slow handshake does, so that nudge reads the record again.
    @Test func aSlowHandshakeMutesNothingAndDropsTheKeptKey() async throws {
        let silent = try await SilentListener()
        defer { silent.stop() }
        let key = NudgeKey.mint(hub: hub).on(port: silent.port)
        let db = InMemoryRecordDatabase()
        try await key.save(to: db)
        let keys = NudgeKeys()
        #expect(await keys.key(for: lease(silent.port), in: db) == .key(key, read: true))
        let answer = await HubNudge.hear("words", nonce: nonce, model: "sonnet", for: lease(silent.port), key: key,
                                         keys: keys, connectBound: 0.5)
        // Mutant: the hand-over's connection without `TCPReached`, which says `connectTimeout`.
        #expect(answer == .unknown("handshakeTimeout", sent: false))
        // Mutant: the slow handshake muting the endpoint, which the nudge then answers `recently`.
        #expect(!HubNudge.Unreached.shared.recently("127.0.0.1:\(silent.port)"))
        // Mutant: the kept copy left in place.
        #expect(await keys.kept(for: lease(silent.port)) == nil)
    }

    /// A hand-over whose connect is refused mutes the endpoint and drops the kept key, as a nudge's does.
    @Test func aRefusedConnectMutesAndDropsTheKeptKey() async throws {
        let (server, _, live, _) = try await hubServer(.mint(hub: hub))
        let key = try #require(live)
        await server.stop()
        try await Task.sleep(for: .milliseconds(200))
        let db = InMemoryRecordDatabase()
        try await key.save(to: db)
        let keys = NudgeKeys()
        let held = lease(key.port)
        #expect(await keys.key(for: held, in: db) == .key(key, read: true))
        let answer = await HubNudge.hear("words", nonce: nonce, model: "sonnet", for: held, key: key, keys: keys, connectBound: 1)
        #expect(answer == .unknown("connect", sent: false))
        #expect(HubNudge.Unreached.shared.recently("127.0.0.1:\(key.port)"))
        // Mutant: a hand-over that drops no key.
        #expect(await keys.kept(for: held) == nil)
    }
}

extension RawBytes {
    /// `bytes` written to a local port, and the first line back.
    static func exchange(_ port: UInt16, _ bytes: Data) async throws -> String? {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        connection.start(queue: DispatchQueue(label: "test.bytes"))
        try await connection.waitUntilReady()
        try await connection.send(bytes)
        let line = try await RawLine.within(3) { try await connection.readLine(maximum: 256) }
        return line.flatMap { $0 }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
