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

    @Test func progressReportsEachStepAndThePersonsTurnBeforeTheReply() async throws {
        let db = InMemoryRecordDatabase()
        let transport = RecordingTransport((200, reply("ok")))
        let (runner, _) = try await makeRunner(database: db, transport: transport)
        let steps = Steps()
        let result = try await runner.run("words", model: .sonnet5) { await steps.add($0) }
        let seen = await steps.all
        #expect(seen == [.takingLease, .saving, .asking(person: result.person), .savingReply])
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

    @Test func aClaimLandingBetweenTheReplyAndItsWriteRefusesTheWrite() async throws {
        let db = InMemoryRecordDatabase()
        let transport = RecordingTransport((200, reply("two brains")))
        let (runner, lease) = try await makeRunner(database: db, transport: transport)
        let hub = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: NoSocketProbe(),
                               sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        // The claim lands inside the save of the reply's batch, after every check the runner
        // could have made: only the batch's own compare-and-set on the lease can see it.
        await db.setBeforeSave { records in
            guard records.contains(where: { $0.type == Turn.recordType && $0.string("role") == "assistant" }) else { return }
            await db.setBeforeSave(nil)
            _ = try? await hub.acquire()
        }
        do {
            _ = try await runner.run("hello", model: .sonnet5)
            Issue.record("expected displacement")
        } catch TurnRunnerError.replyFailed(_, let underlying) {
            guard case TurnRunnerError.displaced = underlying else { Issue.record("wrong cause: \(underlying)"); return }
        }
        let after = try await TurnLog(database: db).read()
        #expect(after.ordered.map(\.text) == ["hello"])
        #expect(await hub.isPrimary())
        #expect(!(await lease.isPrimary()))
    }

    @Test func theSameNonceAgainFindsTheTurnAlreadyInTheLog() async throws {
        let db = InMemoryRecordDatabase()
        let transport = RecordingTransport((500, "{}"), (200, reply("ok")))
        let (runner, _) = try await makeRunner(database: db, transport: transport)
        let nonce = "same-nonce"
        _ = try? await runner.run("once", model: .sonnet5, nonce: nonce)
        let again = try await runner.run("once", model: .sonnet5, nonce: nonce)
        #expect(again.person.nonce == nonce)
        // The recovered turn goes to the model once, not joined with itself.
        let messages = try #require(transport.lastBody?["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "once"]])
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

    @Test func thePrimaryAnswersATurnALimbWroteIntoTheLog() async throws {
        let db = InMemoryRecordDatabase()
        let transport = RecordingTransport((200, reply("from the phone")))
        let (runner, lease) = try await makeRunner(database: db, transport: transport)
        #expect(try await runner.answerPending(model: .sonnet5) == nil)
        #expect(!(await lease.isPrimary()))

        let watch = try await TurnLog(database: db).writer(for: DeviceID("watch"))
        let asked = try await watch.append(.person, "bins?", parents: [])
        let answer = try #require(try await runner.answerPending(model: .sonnet5))
        #expect(answer.role == .assistant && answer.text == "from the phone")
        #expect(answer.parents == [asked.ref])
        #expect(await lease.isPrimary())
        let messages = try #require(transport.lastBody?["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "bins?"]])
        // Answered, so nothing is pending; no second call.
        #expect(try await runner.answerPending(model: .sonnet5) == nil)
        #expect(transport.requests.count == 1)
    }

    @Test func aNamedTurnIsAnsweredBeforeTheFeedHasIt() async throws {
        let db = InMemoryRecordDatabase()
        let blind = FeedLagDatabase(inner: db)
        let transport = RecordingTransport((200, reply("right away")))
        let (runner, _) = try await makeRunner(database: blind, transport: transport)
        let watch = try await TurnLog(database: db).writer(for: DeviceID("watch"))
        let asked = try await watch.append(.person, "now?", parents: [])
        // The feed has not caught up, so the pass finds nothing; the named path fetches by ID.
        #expect(try await runner.answerPending(model: .sonnet5) == nil)
        let answer = try #require(try await runner.answer(asked.ref, model: .sonnet5))
        #expect(answer.parents == [asked.ref] && answer.text == "right away")
        // Asked again, it is already answered: no second call.
        #expect(try await runner.answer(asked.ref, model: .sonnet5) == nil)
        #expect(transport.requests.count == 1)
        // A ref with no turn, and a reply's ref, are nil.
        #expect(try await runner.answer(TurnRef(device: DeviceID("nobody"), sequence: 1), model: .sonnet5) == nil)
        #expect(try await runner.answer(answer.ref, model: .sonnet5) == nil)
    }

    @Test func aReplyThatFailedIsRetriedOnTheNextPassAndNeverDoubled() async throws {
        let db = InMemoryRecordDatabase()
        let transport = RecordingTransport((500, "{}"), (200, reply("second time")))
        let (runner, _) = try await makeRunner(database: db, transport: transport)
        let watch = try await TurnLog(database: db).writer(for: DeviceID("watch"))
        _ = try await watch.append(.person, "hello", parents: [])
        await #expect(throws: MessagesAPIError.self) { try await runner.answerPending(model: .sonnet5) }
        let answer = try #require(try await runner.answerPending(model: .sonnet5))
        #expect(answer.text == "second time")

        // Another primary answering the same words finds this reply by its nonce and makes no call.
        let other = RecordingTransport((200, reply("never")))
        let (hub, _) = try await makeRunner(database: db, device: "hub", transport: other)
        #expect(try await hub.answerPending(model: .sonnet5) == nil)
        #expect(other.requests.isEmpty)
        #expect(try await TurnLog(database: db).read().ordered.map(\.text) == ["hello", "second time"])
    }

    @Test func aForkOfPersonTurnsGetsOneReplyContinuingEveryHead() async throws {
        let db = InMemoryRecordDatabase()
        let transport = RecordingTransport((200, reply("both")))
        let (runner, _) = try await makeRunner(database: db, transport: transport)
        let log = TurnLog(database: db)
        let a = try await log.writer(for: DeviceID("watch")).append(.person, "one", parents: [])
        let b = try await log.writer(for: DeviceID("pad")).append(.person, "two", parents: [])
        let answer = try #require(try await runner.answerPending(model: .sonnet5))
        #expect(Set(answer.parents) == [a.ref, b.ref])
        #expect(try await log.read().heads == [answer.ref])
    }

    @Test func aReadWithTurnsMissingIsNotAnswered() async throws {
        let db = InMemoryRecordDatabase()
        let transport = RecordingTransport((200, reply("never")))
        let (runner, _) = try await makeRunner(database: db, transport: transport)
        let watch = try await TurnLog(database: db).writer(for: DeviceID("watch"))
        // A turn continuing from one the read cannot see: the read is incomplete.
        _ = try await watch.append(.person, "second", parents: [TurnRef(device: DeviceID("ghost"), sequence: 1)])
        #expect(try await runner.answerPending(model: .sonnet5) == nil)
        #expect(transport.requests.isEmpty)
    }

    @Test func theReplyNonceIsFixedLengthAndOrderBlind() {
        let a = TurnRef(device: DeviceID("watch"), sequence: 3), b = TurnRef(device: DeviceID("pad"), sequence: 9)
        #expect(TurnRunner.replyNonce(for: [a, b]) == TurnRunner.replyNonce(for: [b, a]))
        #expect(TurnRunner.replyNonce(for: [a]) != TurnRunner.replyNonce(for: [b]))
        let wide = (1...500).map { TurnRef(device: DeviceID("device-\($0)"), sequence: Int64($0)) }
        #expect(TurnRunner.replyNonce(for: wide).count == "answer/".count + 64)
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

actor Steps {
    private(set) var all: [TurnRunner.Progress] = []
    func add(_ step: TurnRunner.Progress) { all.append(step) }
}

/// A database whose change feed shows nothing: what a limb's fresh turn looks like to the
/// primary before the feed catches up. Fetch by ID sees everything.
struct FeedLagDatabase: RecordDatabase {
    let inner: InMemoryRecordDatabase
    func save(_ records: [Record]) async throws -> [Record] { try await inner.save(records) }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await inner.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await inner.query(query) }
    func records(ofType type: String) async throws -> [Record] {
        try await inner.records(ofType: type).filter { $0.string("device") != "watch" }
    }
}
