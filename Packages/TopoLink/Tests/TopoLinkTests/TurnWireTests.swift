import Foundation
import Network
import Testing
import TopoCore
@testable import TopoLink

@Suite struct TurnWireTests {
    let asked = TurnRef(device: DeviceID("watch"), sequence: 3)
    let answered = TurnRef(device: DeviceID("phone"), sequence: 9)

    @Test func aPrimaryAnswersATurnAndTheReplyNamesItsOwnTurn() async throws {
        let server = try LeaseProbeServer(advertising: nil, answers: { [asked, answered] ref in
            ref == asked ? LiveReply(ref: answered, text: "Bins are Tuesday.\nRecycling too. ✓") : nil
        }) { _, _ in false }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let client = SocketTurnClient(timeout: 5)
        let reply = try #require(await client.ask("127.0.0.1:\(port)", toAnswer: asked))
        #expect(reply.ref == answered)
        #expect(reply.text == "Bins are Tuesday.\nRecycling too. ✓")
        // A ref it will not answer, and a listener that answers nothing, are no.
        #expect(await client.ask("127.0.0.1:\(port)", toAnswer: TurnRef(device: DeviceID("tv"), sequence: 1)) == nil)
        let mute = try LeaseProbeServer(advertising: nil) { _, _ in true }
        let mutePort = try await mute.start()
        defer { Task { await mute.stop() } }
        #expect(await client.ask("127.0.0.1:\(mutePort)", toAnswer: asked) == nil)
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
        let reply = try #require(await SocketTurnClient(timeout: 5).ask("127.0.0.1:\(port)", toAnswer: asked))
        #expect(reply.text == "héllo ✓ wörld")
        #expect(reply.ref == answered)
    }

    /// A request that arrives one byte at a time is still one request, and the server's reply
    /// body is read exactly, no more and no less.
    @Test func serverReadsAFragmentedRequestAndTheBodyIsExact() async throws {
        let server = try LeaseProbeServer(advertising: nil, answers: { [answered] _ in LiveReply(ref: answered, text: "ok") }) { _, _ in false }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
        defer { connection.cancel() }
        try await connection.waitUntilReady()
        for byte in "answer watch/3\n".utf8 {
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
        #expect(await SocketTurnClient(timeout: 2).ask("127.0.0.1:\(port)", toAnswer: asked) == nil)
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
        #expect(await SocketTurnClient(timeout: 0.5).ask("127.0.0.1:\(port)", toAnswer: asked) == nil)
        let took = Date().timeIntervalSince(began)
        #expect(took >= 0.4 && took < 2)
    }

    @Test func wireFormat() {
        #expect(String(decoding: TurnWire.request(asked), as: UTF8.self) == "answer watch/3\n")
        #expect(TurnWire.parseRequest("answer watch/3") == asked)
        #expect(TurnWire.parseRequest("answer") == nil)
        #expect(TurnWire.parseRequest("hold hub 3") == nil)
        let wire = TurnWire.reply(answered, "✓")
        #expect(String(decoding: wire, as: UTF8.self) == "reply phone/9 3\n✓")
    }
}
