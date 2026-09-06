import Foundation
import Network
import Testing
import TopoCore
@testable import TopoLink

@Suite struct TurnWireTests {
    let asked = TurnRef(device: DeviceID("watch"), sequence: 3)
    let answered = TurnRef(device: DeviceID("phone"), sequence: 9)
    let watch = DeviceID("watch")
    let secret = Data((0..<32).map { UInt8($0) })

    @Test func aPrimaryAnswersATurnAndTheReplyNamesItsOwnTurn() async throws {
        let server = try LeaseProbeServer(advertising: nil, answers: { [asked, answered] ref in
            ref == asked ? LiveReply(ref: answered, text: "Bins are Tuesday.\nRecycling too. ✓") : nil
        }, secret: { [secret] in secret }) { _, _ in false }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let client = SocketTurnClient(timeout: 5)
        let reply = try #require(await client.ask("127.0.0.1:\(port)", toAnswer: asked, as: watch, secret: secret))
        #expect(reply.ref == answered)
        #expect(reply.text == "Bins are Tuesday.\nRecycling too. ✓")
        // A ref it will not answer, and a listener that answers nothing, are no.
        #expect(await client.ask("127.0.0.1:\(port)", toAnswer: TurnRef(device: DeviceID("tv"), sequence: 1), as: watch, secret: secret) == nil)
        let mute = try LeaseProbeServer(advertising: nil) { _, _ in true }
        let mutePort = try await mute.start()
        defer { Task { await mute.stop() } }
        #expect(await client.ask("127.0.0.1:\(mutePort)", toAnswer: asked, as: watch, secret: secret) == nil)
        // The probe still works on the same listener.
        #expect(await SocketLeaseProbe(timeout: 2).confirms(Lease(holder: DeviceID("x"), endpoint: "127.0.0.1:\(mutePort)", epoch: 1, expiresAt: Date() + 10)))
    }

    /// A reply whose line and body arrive in pieces, split inside a multi-byte character, is
    /// still the reply.
    @Test func clientReadsAFragmentedReply() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let bound = OneShot<UInt16>()
        let wire = TurnWire.reply(answered, "héllo ✓ wörld")
        listener.stateUpdateHandler = { state in if case .ready = state { bound.resume(.success(listener.port?.rawValue ?? 0)) } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Task {
                _ = try? await connection.readLine(maximum: 256)
                for byte in wire {
                    try? await connection.send(Data([byte]))
                    try? await Task.sleep(for: .milliseconds(2))
                }
            }
        }
        listener.start(queue: .global())
        let port = try await bound.value()
        defer { listener.cancel() }
        let reply = try #require(await SocketTurnClient(timeout: 5).ask("127.0.0.1:\(port)", toAnswer: asked, as: watch, secret: secret))
        #expect(reply.text == "héllo ✓ wörld")
        #expect(reply.ref == answered)
    }

    /// A request that arrives one byte at a time is still one request, and the server's reply
    /// body is read exactly, no more and no less.
    @Test func serverReadsAFragmentedRequestAndTheBodyIsExact() async throws {
        let server = try LeaseProbeServer(advertising: nil, answers: { [answered] _ in LiveReply(ref: answered, text: "ok") },
                                          secret: { [secret] in secret }) { _, _ in false }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
        defer { connection.cancel() }
        try await connection.waitUntilReady()
        for byte in TurnWire.request(asked, from: watch, secret: secret) {
            try await connection.send(Data([byte]))
            try await Task.sleep(for: .milliseconds(3))
        }
        let (line, rest) = try await connection.readLineKeepingRest(maximum: 256)
        let (ref, count) = try #require(TurnWire.parseReplyLine(line))
        #expect(ref == answered && count == 2)
        #expect(try await connection.readExactly(count, startingWith: rest) == Data("ok".utf8))
    }

    @Test func aBodyCutShortAndAnAbsurdCountAreNo() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let bound = OneShot<UInt16>()
        listener.stateUpdateHandler = { state in if case .ready = state { bound.resume(.success(listener.port?.rawValue ?? 0)) } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Task {
                _ = try? await connection.readLine(maximum: 256)
                try? await connection.send(Data("reply phone/9 10\nshort".utf8))
                try? await Task.sleep(for: .milliseconds(50))
                connection.cancel()
            }
        }
        listener.start(queue: .global())
        let port = try await bound.value()
        defer { listener.cancel() }
        #expect(await SocketTurnClient(timeout: 2).ask("127.0.0.1:\(port)", toAnswer: asked, as: watch, secret: secret) == nil)
        #expect(TurnWire.parseReplyLine("reply phone/9 \(TurnWire.maximumBody + 1)") == nil)
        #expect(TurnWire.parseReplyLine("reply phone/9 -1") == nil)
        #expect(TurnWire.parseReplyLine("no") == nil)
    }

    @Test func silenceIsNoWithinTheTimeout() async throws {
        let silent = try NWListener(using: .tcp, on: .any)
        let bound = OneShot<UInt16>()
        silent.stateUpdateHandler = { state in if case .ready = state { bound.resume(.success(silent.port?.rawValue ?? 0)) } }
        silent.newConnectionHandler = { $0.start(queue: .global()) }
        silent.start(queue: .global())
        let port = try await bound.value()
        defer { silent.cancel() }
        let began = Date()
        #expect(await SocketTurnClient(timeout: 0.5).ask("127.0.0.1:\(port)", toAnswer: asked, as: watch, secret: secret) == nil)
        let took = Date().timeIntervalSince(began)
        #expect(took >= 0.4 && took < 2)
    }

    /// A stranger on the LAN who can spell a ref gets no, and so does a device with the wrong
    /// secret or a listener with none; the same request replayed gets the same reply.
    @Test func onlyAHolderOfTheLinkSecretIsAnswered() async throws {
        let server = try LeaseProbeServer(advertising: nil, answers: { [answered] _ in LiveReply(ref: answered, text: "yours") },
                                          secret: { [secret] in secret }) { _, _ in false }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let wrong = Data(repeating: 9, count: 32)
        #expect(await SocketTurnClient(timeout: 5).ask("127.0.0.1:\(port)", toAnswer: asked, as: watch, secret: wrong) == nil)
        // A bare request, as the wire was before the secret, is no.
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
        defer { connection.cancel() }
        try await connection.waitUntilReady()
        try await connection.send(Data("answer watch/3\n".utf8))
        #expect(try await connection.readLine(maximum: 16) == "no")
        // The right secret is answered, and the same bytes again get the same reply.
        let request = TurnWire.request(asked, from: watch, secret: secret)
        for _ in 0..<2 {
            let again = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            again.start(queue: .global())
            try await again.waitUntilReady()
            try await again.send(request)
            let (line, rest) = try await again.readLineKeepingRest(maximum: 256)
            let (ref, count) = try #require(TurnWire.parseReplyLine(line))
            #expect(ref == answered)
            #expect(try await again.readExactly(count, startingWith: rest) == Data("yours".utf8))
            again.cancel()
        }
        // A listener with no secret answers nobody.
        let none = try LeaseProbeServer(advertising: nil, answers: { [answered] _ in LiveReply(ref: answered, text: "x") }) { _, _ in false }
        let nonePort = try await none.start()
        defer { Task { await none.stop() } }
        #expect(await SocketTurnClient(timeout: 5).ask("127.0.0.1:\(nonePort)", toAnswer: asked, as: watch, secret: secret) == nil)
    }

    /// A connection that opens and says nothing is dropped within the request deadline.
    @Test func aSilentClientIsDropped() async throws {
        let server = try LeaseProbeServer(advertising: nil) { _, _ in true }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
        defer { connection.cancel() }
        try await connection.waitUntilReady()
        let began = Date()
        // The drop reads as the end of the stream, or as an error; either way nothing was said.
        let line = try? await connection.readLine(maximum: 16)
        #expect(line == nil || line == "")
        let took = Date().timeIntervalSince(began)
        #expect(took >= LeaseProbeServer.requestDeadline - 0.5 && took < LeaseProbeServer.requestDeadline + 3)
    }

    /// A black-holed address costs the connect deadline, not the reply's.
    @Test func aDroppedConnectionCostsSecondsNotMinutes() async throws {
        let began = Date()
        // 10.255.255.1 is unrouted here; a SYN to it is swallowed.
        #expect(await SocketTurnClient(connectTimeout: 0.5, timeout: 120).ask("10.255.255.1:9", toAnswer: asked, as: watch, secret: secret) == nil)
        let took = Date().timeIntervalSince(began)
        #expect(took < 5)
    }

    @Test func wireFormat() {
        let line = String(decoding: TurnWire.request(asked, from: watch, secret: secret), as: UTF8.self)
        #expect(line.hasPrefix("answer watch/3 watch ") && line.hasSuffix("\n"))
        let request = try! #require(TurnWire.parseRequest(line))
        #expect(request.ref == asked && request.asker == watch && request.verifies(with: secret))
        #expect(!request.verifies(with: Data(repeating: 1, count: 32)))
        #expect(TurnWire.parseRequest("answer watch/3") == nil)
        #expect(TurnWire.parseRequest("answer") == nil)
        #expect(TurnWire.parseRequest("hold hub 3") == nil)
        let wire = TurnWire.reply(answered, "✓")
        #expect(String(decoding: wire, as: UTF8.self) == "reply phone/9 3\n✓")
    }
}
