import Foundation
import Testing
import TopoCore
import TopoCoreTesting
@testable import TopoTurn

/// A pass that finds a turn the brain heard ahead of its save where the turn is not the log's one
/// head (`Brain.heardAhead(of:)`): that turn is answered first and alone, its reply written as its
/// child under its own reply nonce, and the rest are asked continuing the log with it.
@Suite struct HeardFirstTests {
    /// Writes `text` as the person's, from `device`, continuing the log as it stands.
    @discardableResult
    func says(_ db: InMemoryRecordDatabase, _ device: String, _ text: String, nonce: String = UUID().uuidString,
              continuing read: Transcript? = nil) async throws -> Turn {
        let log = TurnLog(database: db)
        let writer = try await log.writer(for: DeviceID(device))
        let base: Transcript
        if let read { base = read } else { base = try await log.read() }
        return try await writer.append(.person, text, continuing: base, nonce: nonce)
    }

    /// One phone, P then Q before a pass: P's reply first, under its own nonce, then Q's.
    @Test func aHeardTurnBehindTheHeadIsAnsweredFirstAndAlone() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("to P"), .success("to Q"))
        let (runner, _) = try await makeRunner(database: db, device: "mac", brain: brain)
        let p = try await says(db, "phone", "P")
        let q = try await says(db, "phone", "Q")
        brain.heardAheadNonces = [p.nonce]
        let last = try #require(try await runner.answerPending(model: .sonnet))
        #expect(brain.requests.count == 2)
        let first = try #require(brain.requests.first)
        #expect(first.answering == [p])
        #expect(first.parents == [p.ref])
        #expect(first.nonce == TurnRunner.replyNonce(for: [p.ref]))
        let replies = try await TurnLog(database: db).read().ordered.filter { $0.role == .assistant }
        let rp = try #require(replies.first { $0.text == "to P" })
        #expect(rp.parents == [p.ref])
        #expect(rp.nonce == first.nonce)
        let second = try #require(brain.requests.last)
        #expect(second.answering == [q])
        #expect(Set(second.parents) == [q.ref, rp.ref])
        #expect(second.context.contains { $0.ref == rp.ref })
        #expect(last.text == "to Q")
        #expect(Set(last.parents) == [q.ref, rp.ref])
        #expect(brain.landedNonces == [first.nonce, second.nonce])
    }

    /// A heard turn one of two person heads: answered alone, then the other.
    @Test func aHeardTurnBesideAnotherHeadIsAnsweredFirstAndAlone() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("to P"), .success("to X"))
        let (runner, _) = try await makeRunner(database: db, device: "mac", brain: brain)
        let hello = try await says(db, "phone", "hello")
        let read = try await TurnLog(database: db).read()
        let x = try await says(db, "pad", "X", continuing: read)
        let p = try await says(db, "phone", "P", continuing: read)
        #expect(hello.ref != x.ref)
        brain.heardAheadNonces = [p.nonce]
        _ = try await runner.answerPending(model: .sonnet)
        #expect(brain.requests.map(\.answering) == [[p], [x]])
        let transcript = try await TurnLog(database: db).read()
        #expect(transcript.heads.count == 1)
        let rx = try #require(transcript[transcript.heads[0]])
        #expect(rx.text == "to X")
        #expect(rx.parents.contains(x.ref) && rx.parents.count == 2)
    }

    /// Nothing heard: P behind Q is told as context and one reply answers Q, as ever.
    @Test func aTurnNotHeardBehindTheHeadIsContext() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("to Q"))
        let (runner, _) = try await makeRunner(database: db, device: "mac", brain: brain)
        let p = try await says(db, "phone", "P")
        let q = try await says(db, "phone", "Q")
        _ = try await runner.answerPending(model: .sonnet)
        #expect(brain.requests.map(\.answering) == [[q]])
        #expect(brain.requests.first?.context.contains(p) == true)
    }

    /// The heard turn's reply already in the log under its own nonce, the pass's read without it
    /// (the feed behind a device's first turn, which no fetch by ID finds): found by its marker,
    /// not asked again, and the rest asked continuing it.
    @Test func aHeardTurnWhoseReplyIsThereIsNotAskedAgain() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("to Q"))
        let p = try await says(db, "phone", "P")
        let q = try await says(db, "phone", "Q")
        let other = try await TurnLog(database: db).writer(for: DeviceID("other"))
        let rp = try await other.append(.assistant, "to P", parents: [p.ref], nonce: TurnRunner.replyNonce(for: [p.ref]))
        let (runner, _) = try await makeRunner(database: LagBehind(db, hiding: rp.ref), device: "mac", brain: brain)
        brain.heardAheadNonces = [p.nonce]
        let reply = try #require(try await runner.answerPending(model: .sonnet))
        // Mutant: no marker fetched for the heard turn, and its words asked a second time.
        #expect(brain.requests.map(\.answering) == [[q]])
        #expect(Set(reply.parents) == [q.ref, rp.ref])
        #expect(brain.landedNonces.first == rp.nonce)
    }

    /// The heard turn cut off: skipped, as a head the brain holds unresolved; the rest answered.
    @Test func aHeardTurnCutOffIsSkippedAndTheRestAnswered() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.failure(Refused()), .success("to Q"))
        brain.cutsOffHeard = true
        let (runner, _) = try await makeRunner(database: db, device: "mac", brain: brain)
        let p = try await says(db, "phone", "P")
        let q = try await says(db, "phone", "Q")
        brain.heardAheadNonces = [p.nonce]
        let reply = try #require(try await runner.answerPending(model: .sonnet))
        #expect(brain.requests.map(\.answering) == [[p], [q]])
        #expect(reply.text == "to Q")
        #expect(reply.parents == [q.ref])
        // Mutant: a cut-off heard turn failing the pass.
        #expect(try await TurnLog(database: db).read().ordered.filter { $0.role == .assistant }.count == 1)
    }
}

/// A store whose change feed lacks one turn while `hidden`.
final class LagBehind: ForwardingDatabase, @unchecked Sendable {
    let base: any RecordDatabase
    let ref: TurnRef
    private let lock = NSLock()
    private var _hidden = true
    var hidden: Bool {
        get { lock.withLock { _hidden } }
        set { lock.withLock { _hidden = newValue } }
    }
    init(_ base: any RecordDatabase, hiding ref: TurnRef) { self.base = base; self.ref = ref }
    func records(ofType type: String, through base: any RecordDatabase) async throws -> [Record] {
        let all = try await base.records(ofType: type)
        guard hidden else { return all }
        return all.filter { Turn(record: $0)?.ref != ref }
    }
}
