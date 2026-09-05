import Foundation
import Testing
import TopoCore
import TopoCoreTesting
@testable import TopoTurn

@Suite struct TurnRunnerTests {
    @Test func aTurnTakesTheLeaseAppendsBothSidesAndSendsHistory() async throws {
        let db = InMemoryRecordDatabase()
        let transport = RecordingTransport((200, reply("Reply one")), (200, reply("Reply two")))
        let (runner, lease) = try await makeRunner(database: db, transport: transport)

        let first = try await runner.run("I forgot the bins", model: .sonnet5)
        #expect(await lease.isPrimary())
        #expect(first.person.role == .person && first.person.text == "I forgot the bins")
        #expect(first.assistant.text == "Reply one")
        #expect(first.assistant.parents == [first.person.ref])
        #expect(first.person.parents.isEmpty)

        let second = try await runner.run("and the milk", model: .fable51)
        #expect(second.person.parents == [first.assistant.ref])
        let body = try #require(transport.lastBody)
        #expect(body["model"] as? String == "claude-fable-5-1")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.map { $0["content"] } == ["I forgot the bins", "Reply one", "and the milk"])

        let transcript = try await TurnLog(database: db).read()
        #expect(transcript.ordered.map(\.text) == ["I forgot the bins", "Reply one", "and the milk", "Reply two"])
        #expect(transcript.heads.count == 1)
    }

    @Test func notPrimaryMeansNoCallAndNoAppend() async throws {
        let db = InMemoryRecordDatabase()
        let other = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: AlwaysConfirms(),
                                 sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        guard case .primary = try await other.acquire() else { Issue.record("hub should claim"); return }
        let transport = RecordingTransport((200, reply("never")))
        let (runner, _) = try await makeRunner(database: db, transport: transport, probe: AlwaysConfirms())
        await #expect(throws: TurnRunnerError.self) { try await runner.run("hello?", model: .sonnet5) }
        #expect(transport.requests.isEmpty)
        #expect(try await TurnLog(database: db).read().isEmpty)
    }

    @Test func aFailedCallLeavesThePersonsTurnInTheLog() async throws {
        let db = InMemoryRecordDatabase()
        let transport = RecordingTransport((500, "{}"), (200, reply("ok now")))
        let (runner, _) = try await makeRunner(database: db, transport: transport)
        do {
            _ = try await runner.run("first", model: .sonnet5)
            Issue.record("expected the reply to fail")
        } catch TurnRunnerError.replyFailed(let person, let underlying) {
            #expect(person.text == "first")
            #expect(underlying as? MessagesAPIError == .http(status: 500, message: nil))
        }
        let after = try await TurnLog(database: db).read()
        #expect(after.ordered.map(\.text) == ["first"])

        let second = try await runner.run("second", model: .sonnet5)
        #expect(second.person.parents == after.heads)
        let messages = try #require(transport.lastBody?["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "first\n\nsecond"]])
    }

    @Test func aDeviceDisplacedDuringTheCallDoesNotWriteTheReply() async throws {
        let db = InMemoryRecordDatabase()
        let transport = RecordingTransport((200, reply("too late")))
        let (runner, _) = try await makeRunner(database: db, transport: transport)
        let hub = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: NoSocketProbe(),
                               sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        transport.duringRequest = { _ = try? await hub.acquire() }
        do {
            _ = try await runner.run("hello", model: .sonnet5)
            Issue.record("expected displacement")
        } catch TurnRunnerError.replyFailed(_, let underlying) {
            guard case TurnRunnerError.displaced = underlying else { Issue.record("wrong cause: \(underlying)"); return }
        }
        let after = try await TurnLog(database: db).read()
        #expect(after.ordered.map(\.text) == ["hello"])
        #expect(await hub.isPrimary())
    }

    @Test func theSameNonceAgainFindsTheTurnAlreadyInTheLog() async throws {
        let db = InMemoryRecordDatabase()
        let transport = RecordingTransport((500, "{}"), (200, reply("ok")))
        let (runner, _) = try await makeRunner(database: db, transport: transport)
        let nonce = "same-nonce"
        _ = try? await runner.run("once", model: .sonnet5, nonce: nonce)
        let again = try await runner.run("once", model: .sonnet5, nonce: nonce)
        #expect(again.person.nonce == nonce)
        let transcript = try await TurnLog(database: db).read()
        #expect(transcript.ordered.map(\.text) == ["once", "ok"])
    }

    @Test func aRetryAfterTheReplyLandedReturnsThatReplyWithoutAnotherCall() async throws {
        let db = InMemoryRecordDatabase()
        let transport = RecordingTransport((200, reply("the reply")), (200, reply("never")))
        let (runner, _) = try await makeRunner(database: db, transport: transport)
        let nonce = "cut-off-after-commit"
        let first = try await runner.run("words", model: .sonnet5, nonce: nonce)
        let again = try await runner.run("words", model: .sonnet5, nonce: nonce)
        #expect(again.assistant == first.assistant)
        #expect(transport.requests.count == 1)
        #expect(try await TurnLog(database: db).read().ordered.count == 2)
    }

    @Test func historyIsCappedAndRolesAlternate() {
        let d = DeviceID("d")
        var turns: [Turn] = []
        for i in 1...50 {
            turns.append(Turn(ref: TurnRef(device: d, sequence: Int64(i)), parents: [], role: i % 2 == 0 ? .assistant : .person, text: "t\(i)", at: Date()))
        }
        let messages = TurnRunner.messages(from: turns.suffix(39))
        #expect(messages.count == 38)
        #expect(messages.first?.role == .user)
        #expect(messages.first?.content == "t13")
        let leadingAssistant = TurnRunner.messages(from: [turns[1], turns[2]])
        #expect(leadingAssistant == [ChatMessage(role: .user, content: "t3")])
    }
}
