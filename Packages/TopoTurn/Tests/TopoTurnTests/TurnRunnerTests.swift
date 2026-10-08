import Foundation
import Testing
import TopoCore
import TopoCoreTesting
@testable import TopoTurn

@Suite struct TurnRunnerTests {
    @Test func aTurnTakesTheLeaseAppendsBothSidesAndAsksWithTheLog() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("Reply one"), .success("Reply two"))
        let (runner, lease) = try await makeRunner(database: db, brain: brain)

        let first = try await runner.run("I forgot the bins", model: .sonnet)
        #expect(await lease.isPrimary())
        #expect(first.person.role == .person && first.person.text == "I forgot the bins")
        #expect(first.assistant.text == "Reply one")
        #expect(first.assistant.parents == [first.person.ref])
        #expect(first.person.parents.isEmpty)

        let second = try await runner.run("and the milk", model: .fable)
        #expect(second.person.parents == [first.assistant.ref])
        let asked = try #require(brain.requests.last)
        #expect(asked.model == .fable)
        #expect(asked.context.map(\.text) == ["I forgot the bins", "Reply one"])
        #expect(asked.answering == [second.person])
        #expect(asked.parents == [second.person.ref])
        #expect(asked.nonce == TurnRunner.replyNonce(for: [second.person.ref]))

        let transcript = try await TurnLog(database: db).read()
        #expect(transcript.ordered.map(\.text) == ["I forgot the bins", "Reply one", "and the milk", "Reply two"])
        #expect(transcript.heads.count == 1)
    }

    @Test func progressReportsEachStepAndThePersonsTurnBeforeTheReply() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("ok"))
        let (runner, _) = try await makeRunner(database: db, brain: brain)
        let steps = Steps()
        let result = try await runner.run("words", model: .sonnet) { await steps.add($0) }
        let seen = await steps.all
        #expect(seen == [.takingLease, .saving, .asking(person: result.person), .savingReply])
    }

    @Test func aDeviceWithAFreshLeaseSavesThePersonsTurnWithItsRenewalAndFetchesNoLease() async throws {
        let db = RecordingDatabase(inner: InMemoryRecordDatabase())
        let brain = ScriptedBrain(.success("one"), .success("two"))
        let (runner, lease) = try await makeRunner(database: db, brain: brain)
        _ = try await runner.run("first", model: .sonnet)
        let tag = try await db.inner.fetch([Lease.recordID])[Lease.recordID]?.changeTag
        db.reset()
        let steps = Steps()
        let asked = SavedAtAsk()
        brain.duringAnswer = { await asked.set(db.saved) }
        let result = try await runner.run("second", model: .sonnet) { await steps.add($0) }
        #expect(db.leaseFetches == 0)
        // One save before the brain is asked: the person's records and the lease together.
        let before = await asked.saved
        #expect(before.count == 1)
        #expect(before.first?.contains(Lease.recordType) == true)
        #expect(before.first?.contains(Turn.recordType) == true)
        #expect(try await db.inner.fetch([Lease.recordID])[Lease.recordID]?.changeTag != tag)
        #expect(await steps.all == [.saving, .asking(person: result.person), .savingReply])
        #expect(await lease.isPrimary())
        #expect(try await TurnLog(database: db).read().ordered.map(\.text) == ["first", "one", "second", "two"])
    }

    @Test func aFreshLeaseAnotherDeviceClaimedSinceRefusesTheSaveAndWritesNothing() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("one"), .success("never"))
        let (runner, lease) = try await makeRunner(database: db, brain: brain, probe: AlwaysConfirms())
        _ = try await runner.run("first", model: .sonnet)
        let hub = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: NoSocketProbe(),
                               sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        guard case .primary = try await hub.acquire() else { Issue.record("hub should claim"); return }
        // The phone has not heartbeated since: by its own clocks it still holds the lease.
        #expect(await lease.isPrimary())
        let steps = Steps()
        do {
            _ = try await runner.run("second", model: .sonnet) { await steps.add($0) }
            Issue.record("the turn was answered")
        } catch TurnRunnerError.notPrimary(.held(let by)) {
            #expect(by.holder == DeviceID("hub"))
        }
        // Refused with the save, then the long way, which finds the hub.
        #expect(await steps.all == [.saving, .takingLease])
        #expect(brain.requests.count == 1)
        #expect(try await TurnLog(database: db).read().ordered.map(\.text) == ["first", "one"])
        #expect(await hub.isPrimary())
    }

    @Test func aClaimLandingInsideThePersonsSaveRefusesItAndTheTurnGoesTheLongWay() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("one"), .success("never"))
        let (runner, _) = try await makeRunner(database: db, brain: brain, probe: AlwaysConfirms())
        _ = try await runner.run("first", model: .sonnet)
        let hub = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: NoSocketProbe(),
                               sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        await db.setBeforeSave { records in
            guard records.contains(where: { $0.type == Turn.recordType && $0.string("role") == "person" }) else { return }
            await db.setBeforeSave(nil)
            _ = try? await hub.acquire()
        }
        let steps = Steps()
        do {
            _ = try await runner.run("second", model: .sonnet) { await steps.add($0) }
            Issue.record("the turn was answered")
        } catch TurnRunnerError.notPrimary(.held(let by)) {
            #expect(by.holder == DeviceID("hub"))
        }
        #expect(await steps.all == [.saving, .takingLease])
        #expect(brain.requests.count == 1)
        #expect(try await TurnLog(database: db).read().ordered.map(\.text) == ["first", "one"])
    }

    @Test func aLeaseLapsedOnThisDeviceIsTakenAgainBeforeThePersonsTurnIsSaved() async throws {
        let db = RecordingDatabase(inner: InMemoryRecordDatabase())
        let clock = Elapsed()
        let brain = ScriptedBrain(.success("one"), .success("two"))
        let (runner, lease) = try await makeRunner(database: db, brain: brain, clock: clock)
        _ = try await runner.run("first", model: .sonnet)
        clock.advance(LeaseTiming.standard.duration + 1)
        #expect(!(await lease.isPrimary()))
        db.reset()
        let steps = Steps()
        let result = try await runner.run("second", model: .sonnet) { await steps.add($0) }
        #expect(db.leaseFetches == 1)
        #expect(await steps.all == [.takingLease, .saving, .asking(person: result.person), .savingReply])
        #expect(await lease.isPrimary())
    }

    @Test func aFreshLeaseThatLapsesWhileThePersonsSaveWaitsBehindAHeartbeatIsClaimedAfreshInThatSave() async throws {
        let store = InMemoryRecordDatabase()
        let db = HeldSave(store)
        let clock = Elapsed()
        let brain = ScriptedBrain(.success("one"), .success("two"))
        let (runner, lease) = try await makeRunner(database: db, brain: brain, clock: clock)
        _ = try await runner.run("first", model: .sonnet)
        // A heartbeat goes out at 5 s and its request stalls: the lease's gate is taken.
        clock.advance(5)
        await db.holdNextSave()
        let beat = Task { try await lease.heartbeat() }
        while !(await db.holding) { await Task.yield() }
        // The turn begins on a lease fresh by this device's clocks, and its save waits behind it.
        let steps = Steps(), marks = Marks()
        let turn = Task {
            try await Perf.$observer.withValue(marks.add) {
                try await runner.run("second", model: .sonnet) { await steps.add($0) }
            }
        }
        while !(await steps.all.contains(.saving)) { await Task.yield() }
        // The stalled renewal is answered after the duration it was good for.
        clock.advance(LeaseTiming.standard.duration + 1)
        #expect(!(await lease.isPrimary()))
        await db.release()
        #expect(try await !beat.value)
        let result = try await turn.value
        #expect(await steps.all == [.saving, .asking(person: result.person), .savingReply])
        // The lapse is found at the gate and claimed over in the person's own batch, one epoch on.
        let seen = marks.all.filter { ["lease.batch.lapsed", "turn.lease.fresh", "turn.lease.acquired", "turn.person.saved"].contains($0) }
        #expect(seen == ["lease.batch.lapsed", "turn.lease.fresh", "turn.person.saved"])
        #expect(await lease.held?.epoch == 2)
        #expect(await lease.isPrimary())
        #expect(await lease.held == Lease(record: try #require(try await store.fetch([Lease.recordID])[Lease.recordID])))
        #expect(try await TurnLog(database: store).read().ordered.map(\.text) == ["first", "one", "second", "two"])
    }

    @Test func anOwedReplyIsSettledUnderALeaseTakenTheLongWay() async throws {
        let db = RecordingDatabase(inner: InMemoryRecordDatabase())
        let brain = ScriptedBrain(.success("one"), .success("two"))
        let (runner, _) = try await makeRunner(database: db, brain: brain)
        let first = try await runner.run("first", model: .sonnet)
        brain.owes = OwedReply(parents: [first.assistant.ref], nonce: "owed-nonce", text: "owed")
        db.reset()
        _ = try await runner.run("second", model: .sonnet)
        #expect(db.leaseFetches == 1)
        #expect(brain.owes == nil)
        #expect(try await TurnLog(database: db).read().ordered.map(\.text) == ["first", "one", "owed", "second", "two"])
    }

    @Test func aRetryOnAFreshLeaseRenewsItBeforeAnsweringTheTurnAlreadyInTheLog() async throws {
        let db = RecordingDatabase(inner: InMemoryRecordDatabase())
        let brain = ScriptedBrain(.failure(Refused()), .success("ok now"))
        let (runner, _) = try await makeRunner(database: db, brain: brain)
        await #expect(throws: TurnRunnerError.self) { try await runner.run("first", model: .sonnet, nonce: "n") }
        db.reset()
        let asked = SavedAtAsk()
        brain.duringAnswer = { await asked.set(db.saved) }
        let result = try await runner.run("first", model: .sonnet, nonce: "n")
        #expect(result.reply.text == "ok now")
        #expect(db.leaseFetches == 0)
        #expect(await asked.saved == [[Lease.recordType]])
        #expect(try await TurnLog(database: db).read().ordered.map(\.text) == ["first", "ok now"])
    }

    @Test func notPrimaryMeansNoCallAndNoAppend() async throws {
        let db = InMemoryRecordDatabase()
        let other = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: AlwaysConfirms(),
                                 sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        guard case .primary = try await other.acquire() else { Issue.record("hub should claim"); return }
        let brain = ScriptedBrain(.success("never"))
        let (runner, _) = try await makeRunner(database: db, brain: brain, probe: AlwaysConfirms())
        await #expect(throws: TurnRunnerError.self) { try await runner.run("hello?", model: .sonnet) }
        #expect(brain.requests.isEmpty)
        #expect(try await TurnLog(database: db).read().isEmpty)
    }

    @Test func aFailedCallLeavesThePersonsTurnInTheLog() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.failure(Refused()), .success("ok now"))
        let (runner, _) = try await makeRunner(database: db, brain: brain)
        do {
            _ = try await runner.run("first", model: .sonnet)
            Issue.record("expected the reply to fail")
        } catch TurnRunnerError.replyFailed(let person, let underlying) {
            #expect(person.text == "first")
            #expect(underlying is Refused)
        }
        let after = try await TurnLog(database: db).read()
        #expect(after.ordered.map(\.text) == ["first"])

        let second = try await runner.run("second", model: .sonnet)
        #expect(second.person.parents == after.heads)
        let asked = try #require(brain.requests.last)
        #expect(asked.context.map(\.text) == ["first"])
        #expect(asked.answering.map(\.text) == ["second"])
    }

    @Test func aDeviceDisplacedDuringTheCallDoesNotWriteTheReply() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("too late"))
        let (runner, _) = try await makeRunner(database: db, brain: brain)
        let hub = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: NoSocketProbe(),
                               sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        brain.duringAnswer = { _ = try? await hub.acquire() }
        do {
            _ = try await runner.run("hello", model: .sonnet)
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
        let brain = ScriptedBrain(.success("two brains"))
        let (runner, lease) = try await makeRunner(database: db, brain: brain)
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
            _ = try await runner.run("hello", model: .sonnet)
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
        let brain = ScriptedBrain(.failure(Refused()), .success("ok"))
        let (runner, _) = try await makeRunner(database: db, brain: brain)
        let nonce = "same-nonce"
        _ = try? await runner.run("once", model: .sonnet, nonce: nonce)
        let again = try await runner.run("once", model: .sonnet, nonce: nonce)
        #expect(again.person.nonce == nonce)
        // The recovered turn is asked once: it is answered, not also context.
        let asked = try #require(brain.requests.last)
        #expect(asked.context.isEmpty)
        #expect(asked.answering.map(\.text) == ["once"])
        let transcript = try await TurnLog(database: db).read()
        #expect(transcript.ordered.map(\.text) == ["once", "ok"])
    }

    @Test func aRetryAfterTheReplyLandedReturnsThatReplyWithoutAnotherCall() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("the reply"), .success("never"))
        let (runner, _) = try await makeRunner(database: db, brain: brain)
        let nonce = "cut-off-after-commit"
        let first = try await runner.run("words", model: .sonnet, nonce: nonce)
        let again = try await runner.run("words", model: .sonnet, nonce: nonce)
        #expect(again.assistant == first.assistant)
        #expect(brain.requests.count == 1)
        #expect(try await TurnLog(database: db).read().ordered.count == 2)
    }

    @Test func thePrimaryAnswersATurnALimbWroteIntoTheLog() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("from the phone"))
        let (runner, lease) = try await makeRunner(database: db, brain: brain)
        #expect(try await runner.answerPending(model: .sonnet) == nil)
        #expect(!(await lease.isPrimary()))

        let watch = try await TurnLog(database: db).writer(for: DeviceID("watch"))
        let asked = try await watch.append(.person, "bins?", parents: [])
        let answer = try #require(try await runner.answerPending(model: .sonnet))
        #expect(answer.role == .assistant && answer.text == "from the phone")
        #expect(answer.parents == [asked.ref])
        #expect(await lease.isPrimary())
        let request = try #require(brain.requests.last)
        #expect(request.context.isEmpty && request.answering == [asked])
        // Answered, so nothing is pending; no second call.
        #expect(try await runner.answerPending(model: .sonnet) == nil)
        #expect(brain.requests.count == 1)
    }

    @Test func aReplyThatFailedIsRetriedOnTheNextPassAndNeverDoubled() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.failure(Refused()), .success("second time"))
        let (runner, _) = try await makeRunner(database: db, brain: brain)
        let watch = try await TurnLog(database: db).writer(for: DeviceID("watch"))
        _ = try await watch.append(.person, "hello", parents: [])
        await #expect(throws: Refused.self) { try await runner.answerPending(model: .sonnet) }
        let answer = try #require(try await runner.answerPending(model: .sonnet))
        #expect(answer.text == "second time")

        // Another primary answering the same words finds this reply by its nonce and makes no call.
        let other = ScriptedBrain(.success("never"))
        let (hub, _) = try await makeRunner(database: db, device: "hub", brain: other)
        #expect(try await hub.answerPending(model: .sonnet) == nil)
        #expect(other.requests.isEmpty)
        #expect(try await TurnLog(database: db).read().ordered.map(\.text) == ["hello", "second time"])
    }

    @Test func aTurnAcceptedAndThenFailedByTheModelIsAnsweredOnceByALaterPass() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.failure(Refused()), .success("second time"))
        let (runner, _) = try await makeRunner(database: db, brain: brain)
        do {
            _ = try await runner.run("I forgot the bins", model: .sonnet)
            Issue.record("expected the reply to fail")
        } catch TurnRunnerError.replyFailed(let person, let underlying) {
            // The app accepted the turn: it is in the log, so its caller owes nothing for it.
            #expect(person.text == "I forgot the bins")
            #expect(underlying is Refused)
        }
        let accepted = try await TurnLog(database: db).read()
        #expect(accepted.ordered.map(\.text) == ["I forgot the bins"])

        let answer = try #require(try await runner.answerPending(model: .sonnet))
        #expect(answer.text == "second time")
        #expect(answer.parents == accepted.heads)
        // Exactly one reply: the next pass finds nothing waiting and makes no call.
        #expect(try await runner.answerPending(model: .sonnet) == nil)
        #expect(brain.requests.count == 2)
        #expect(try await TurnLog(database: db).read().ordered.map(\.text) == ["I forgot the bins", "second time"])
    }

    @Test func aTurnLeftByADisplacedDeviceIsAnsweredOnceByTheDeviceThatTookTheLease() async throws {
        let db = InMemoryRecordDatabase()
        let phone = ScriptedBrain(.success("too late"))
        let (runner, _) = try await makeRunner(database: db, brain: phone)
        let hubBrain = ScriptedBrain(.success("from the hub"))
        let (hub, hubLease) = try await makeRunner(database: db, device: "hub", brain: hubBrain)
        phone.duringAnswer = { _ = try? await hubLease.acquire() }
        do {
            _ = try await runner.run("bins?", model: .sonnet)
            Issue.record("expected displacement")
        } catch TurnRunnerError.replyFailed(_, let underlying) {
            guard case TurnRunnerError.displaced = underlying else { Issue.record("wrong cause: \(underlying)"); return }
        }
        let accepted = try await TurnLog(database: db).read()
        #expect(accepted.ordered.map(\.text) == ["bins?"])

        let answer = try #require(try await hub.answerPending(model: .sonnet))
        #expect(answer.text == "from the hub")
        #expect(answer.parents == accepted.heads)
        // Nothing waits now, so neither device answers again and the phone makes no second call.
        #expect(try await hub.answerPending(model: .sonnet) == nil)
        #expect(try await runner.answerPending(model: .sonnet) == nil)
        #expect(phone.requests.count == 1)
        #expect(hubBrain.requests.count == 1)
        #expect(try await TurnLog(database: db).read().ordered.map(\.text) == ["bins?", "from the hub"])
    }

    @Test func aReplyIsSavedWhenTheLeaseLapsedDuringTheAnswerAndNobodyElseClaimed() async throws {
        let db = InMemoryRecordDatabase()
        let clock = Elapsed()
        let brain = ScriptedBrain(.success("a long answer"))
        let (runner, lease) = try await makeRunner(database: db, brain: brain, clock: clock)
        // The answer outlasts the lease with no heartbeat landing: the only primary, late.
        brain.duringAnswer = { clock.advance(34) }
        let result = try await runner.run("bins?", model: .sonnet)
        #expect(result.assistant.text == "a long answer")
        #expect(result.assistant.parents == [result.person.ref])
        #expect(await lease.isPrimary())
        #expect(await lease.held?.epoch == 2)
        #expect(try await TurnLog(database: db).read().ordered.map(\.text) == ["bins?", "a long answer"])
    }

    @Test func aReplyIsLeftOutWhenTheLeaseLapsedDuringTheAnswerAndAnotherDeviceClaimed() async throws {
        let db = InMemoryRecordDatabase()
        let clock = Elapsed()
        let phone = ScriptedBrain(.success("too late"))
        let (runner, _) = try await makeRunner(database: db, brain: phone, clock: clock)
        let hubBrain = ScriptedBrain(.success("from the hub"))
        let (hub, hubLease) = try await makeRunner(database: db, device: "hub", brain: hubBrain, clock: clock)
        phone.duringAnswer = {
            clock.advance(34)
            _ = try? await hubLease.acquire()
        }
        do {
            _ = try await runner.run("bins?", model: .sonnet)
            Issue.record("expected displacement")
        } catch TurnRunnerError.replyFailed(_, let underlying) {
            guard case TurnRunnerError.displaced = underlying else { Issue.record("wrong cause: \(underlying)"); return }
        }
        #expect(try await TurnLog(database: db).read().ordered.map(\.text) == ["bins?"])
        let answer = try #require(try await hub.answerPending(model: .sonnet))
        #expect(answer.text == "from the hub")
        #expect(try await TurnLog(database: db).read().ordered.map(\.text) == ["bins?", "from the hub"])
    }

    @Test func aPassThatOnlyWritesAnOwedReplyReturnsItAndTheNextReturnsNothing() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain()
        let (runner, _) = try await makeRunner(database: db, brain: brain)
        let watch = try await TurnLog(database: db).writer(for: DeviceID("watch"))
        let asked = try await watch.append(.person, "bins?", parents: [])
        // The brain finished this reply and its write never landed.
        let nonce = TurnRunner.replyNonce(for: [asked.ref])
        brain.owes = OwedReply(parents: [asked.ref], nonce: nonce, text: "tonight")

        let written = try #require(try await runner.answerPending(model: .sonnet))
        #expect(written.text == "tonight" && written.parents == [asked.ref] && written.nonce == nonce)
        #expect(brain.requests.isEmpty, "the brain was asked again for a reply it had finished")
        #expect(brain.owes == nil)
        #expect(try await runner.answerPending(model: .sonnet) == nil)
        #expect(try await TurnLog(database: db).read().ordered.map(\.text) == ["bins?", "tonight"])
    }

    @Test func aForkOfPersonTurnsGetsOneReplyContinuingEveryHead() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("both"))
        let (runner, _) = try await makeRunner(database: db, brain: brain)
        let log = TurnLog(database: db)
        let a = try await log.writer(for: DeviceID("watch")).append(.person, "one", parents: [])
        let b = try await log.writer(for: DeviceID("pad")).append(.person, "two", parents: [])
        let answer = try #require(try await runner.answerPending(model: .sonnet))
        #expect(Set(answer.parents) == [a.ref, b.ref])
        #expect(try await log.read().heads == [answer.ref])
    }

    @Test func aReadWithTurnsMissingIsNotAnswered() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("never"))
        let (runner, _) = try await makeRunner(database: db, brain: brain)
        let watch = try await TurnLog(database: db).writer(for: DeviceID("watch"))
        // A turn continuing from one the read cannot see: the read is incomplete.
        _ = try await watch.append(.person, "second", parents: [TurnRef(device: DeviceID("ghost"), sequence: 1)])
        #expect(try await runner.answerPending(model: .sonnet) == nil)
        #expect(brain.requests.isEmpty)
    }

    @Test func theReplyNonceIsFixedLengthAndOrderBlind() {
        let a = TurnRef(device: DeviceID("watch"), sequence: 3), b = TurnRef(device: DeviceID("pad"), sequence: 9)
        #expect(TurnRunner.replyNonce(for: [a, b]) == TurnRunner.replyNonce(for: [b, a]))
        #expect(TurnRunner.replyNonce(for: [a]) != TurnRunner.replyNonce(for: [b]))
        let wide = (1...500).map { TurnRef(device: DeviceID("device-\($0)"), sequence: Int64($0)) }
        #expect(TurnRunner.replyNonce(for: wide).count == "answer/".count + 64)
    }
}

actor SavedAtAsk {
    private(set) var saved: [[String]] = []
    func set(_ batches: [[String]]) { saved = batches }
}

extension TurnRunnerTests {
    @Test func theBrainHasTheWordsBeforeAnySaveSucceeds() async throws {
        let store = InMemoryRecordDatabase()
        let db = Outage(store)
        let brain = ScriptedBrain(.success("Here"))
        brain.hears = true
        let (runner, _) = try await makeRunner(database: db, brain: brain)
        db.away = true
        do {
            _ = try await runner.run("are you there", model: .sonnet, nonce: "n1", known: [])
            Issue.record("expected the turn to be unsaved")
        } catch TurnRunnerError.unsaved(let underlying) {
            guard case RecordDatabaseError.unavailable = underlying else { Issue.record("wrong cause: \(underlying)"); return }
        }
        #expect(brain.heard.map(\.words) == ["are you there"])
        #expect(brain.heard.map(\.nonce) == ["n1"])
        #expect(await store.writes.isEmpty)
        #expect(brain.requests.isEmpty)

        // iCloud is back: the same nonce saves the turn, binds what was heard to it, and writes
        // the reply, with the words heard once.
        db.away = false
        let result = try await runner.run("are you there", model: .sonnet, nonce: "n1", known: [])
        #expect(brain.heard.count == 1)
        let bound = try #require(brain.bound.first)
        #expect(bound.nonce == "n1" && bound.person == result.person)
        #expect(bound.reply == TurnRunner.replyNonce(for: [result.person.ref]))
        #expect(brain.requests.map(\.nonce) == [bound.reply])
        #expect(result.assistant.parents == [result.person.ref])
        #expect(try await TurnLog(database: store).read().ordered.map(\.text) == ["are you there", "Here"])
    }

    /// A device that held the lease when it last asked hears before anything is asked of iCloud:
    /// the brain has the words while the lease's own read is still out.
    @Test func aDeviceThatLastHeldTheLeaseHearsBeforeTheLeaseIsAsked() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("one"), .success("two"))
        brain.hears = true
        let (runner, _) = try await makeRunner(database: db, brain: brain, standing: .mine)
        let steps = Steps()
        let result = try await runner.run("words", model: .sonnet, nonce: "n1", known: []) { step in
            if step == .heard {
                for _ in 0..<1000 where brain.heard.isEmpty { await Task.yield() }
                #expect(await db.writes.isEmpty, "something was saved before the brain was given the words")
            }
            await steps.add(step)
        }
        #expect(await steps.all == [.heard, .asking(person: result.person), .savingReply])
        #expect(brain.heard.map(\.nonce) == ["n1"])
        #expect(await runner.standing == .mine)
    }

    /// A launch that does not know where it stands asks the lease first, and the brain hears the
    /// moment the lease answers that this device holds it.
    @Test func aDeviceThatHasNotAskedTheLeaseAsksItFirstAndThenHears() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("ok"))
        brain.hears = true
        let (runner, _) = try await makeRunner(database: db, brain: brain)
        #expect(!(await runner.hear("early", model: .sonnet, nonce: "n0", known: [])))
        let steps = Steps()
        let result = try await runner.run("words", model: .sonnet, nonce: "n1", known: []) { await steps.add($0) }
        #expect(await steps.all == [.takingLease, .saving, .asking(person: result.person), .savingReply])
        #expect(brain.heard.map(\.nonce) == ["n1"])
        #expect(brain.bound.map(\.nonce) == ["n1"])
        // With no read of the log, the turn is asked as a turn in the log is.
        _ = try? await runner.run("more", model: .sonnet, nonce: "n2")
        #expect(brain.heard.map(\.nonce) == ["n1"])
    }

    @Test func twoTurnsHeardInAnOutageLandInOrderEachReplyAfterItsPersonsTurn() async throws {
        let store = InMemoryRecordDatabase()
        let db = Outage(store)
        let brain = ScriptedBrain(.success("one"), .success("two"))
        brain.hears = true
        let (runner, _) = try await makeRunner(database: db, brain: brain, standing: .mine)
        db.away = true
        #expect(await runner.hear("first", model: .sonnet, nonce: "n1", known: []))
        #expect(await runner.hear("second", model: .sonnet, nonce: "n2", known: []))
        await #expect(throws: TurnRunnerError.self) { try await runner.run("first", model: .sonnet, nonce: "n1", known: []) }
        db.away = false
        let first = try await runner.run("first", model: .sonnet, nonce: "n1", known: [])
        let second = try await runner.run("second", model: .sonnet, nonce: "n2", known: [])
        #expect(brain.heard.map(\.nonce) == ["n1", "n2"])
        #expect(second.person.parents == [first.assistant.ref])
        #expect(second.assistant.nonce == TurnRunner.replyNonce(for: [second.person.ref]))
        #expect(try await TurnLog(database: store).read().ordered.map(\.text) == ["first", "one", "second", "two"])
    }

    /// A phone that knows a hub holds the lease asks the lease first. While the lease answers,
    /// its words go to the hub and its brain hears nothing; when the lease cannot be asked, the
    /// brain hears, and hears at once from then on; when a call gets through and the hub still
    /// holds the lease, the phone hands back.
    @Test func aDeviceThatKnowsAHubAsksTheLeaseFirstAndHearsOnlyWhenItCannotBeAsked() async throws {
        let store = InMemoryRecordDatabase()
        let db = Outage(store)
        let brain = ScriptedBrain(.success("from the phone"))
        brain.hears = true
        let (runner, _) = try await makeRunner(database: db, brain: brain, probe: AlwaysConfirms())
        let hub = PrimaryLease(database: store, device: DeviceID("hub"), endpoint: nil, probe: AlwaysConfirms(),
                               sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        guard case .primary = try await hub.acquire() else { Issue.record("hub should claim"); return }
        do {
            _ = try await runner.run("first", model: .sonnet, nonce: "n0", known: [])
            Issue.record("expected not primary")
        } catch TurnRunnerError.notPrimary {
        }
        #expect(brain.heard.isEmpty, "a turn the hub answers ran this device's brain")
        #expect(await runner.standing == .elsewhere)
        #expect(!(await runner.hear("early", model: .sonnet, nonce: "n0b", known: [])))

        db.away = true
        do {
            _ = try await runner.run("are you there", model: .sonnet, nonce: "n1", known: [])
            Issue.record("expected the turn to be unsaved")
        } catch TurnRunnerError.unsaved {
        }
        #expect(brain.heard.map(\.nonce) == ["n1"])
        #expect(await runner.hear("still there", model: .sonnet, nonce: "n2", known: []))

        db.away = false
        do {
            _ = try await runner.run("are you there", model: .sonnet, nonce: "n1", known: [])
            Issue.record("expected not primary")
        } catch TurnRunnerError.notPrimary {
        }
        #expect(!(await runner.hear("later", model: .sonnet, nonce: "n3", known: [])))
        #expect(brain.requests.isEmpty)
        #expect(try await TurnLog(database: store).read().isEmpty)
    }

    @Test func aRetryThatFindsTheHeardReplyLandedBindsItBeforeTheBrainHearsItLanded() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("landed"))
        brain.hears = true
        let (runner, _) = try await makeRunner(database: db, brain: brain)
        let first = try await runner.run("once", model: .sonnet, nonce: "n1", known: [])
        // The acknowledgement was lost: the caller sends the same nonce again.
        let again = try await runner.run("once", model: .sonnet, nonce: "n1", known: [])
        #expect(again.assistant == first.assistant)
        #expect(brain.requests.count == 1)
        #expect(brain.bound.count == 2)
        #expect(brain.bound.allSatisfy { $0.reply == first.assistant.nonce })
        #expect(brain.landedNonces == [first.assistant.nonce, first.assistant.nonce])
    }

    @Test func aPassBindsAHeardTurnThatReachedTheLogAnotherWay() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("answered"))
        brain.hears = true
        let (runner, _) = try await makeRunner(database: db, brain: brain)
        let log = TurnLog(database: db)
        let person = try await log.writer(for: DeviceID("watch")).append(.person, "from the wrist", parents: [], nonce: "n1")
        let reply = try #require(try await runner.answerPending(model: .sonnet))
        let bound = try #require(brain.bound.first)
        #expect(bound.nonce == "n1" && bound.person == person && bound.reply == reply.nonce)
    }

    @Test func aPassBindsNothingBesideAnotherHead() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("answered"))
        brain.hears = true
        let (runner, _) = try await makeRunner(database: db, brain: brain)
        let log = TurnLog(database: db)
        let root = try await log.writer(for: DeviceID("watch")).append(.person, "root", parents: [], nonce: "n0")
        _ = try await log.writer(for: DeviceID("hub")).append(.assistant, "the hub's", parents: [root.ref])
        _ = try await log.writer(for: DeviceID("tablet")).append(.person, "heard here", parents: [root.ref], nonce: "n1")
        _ = try await runner.answerPending(model: .sonnet)
        // The reply answers the fork, under the fork's nonce: the heard words' reply is not it.
        #expect(brain.bound.isEmpty)
    }

    @Test func aRetryWhoseTurnTheLogMovedPastAsksNothingAndWritesNothing() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("never"))
        brain.hears = true
        let (runner, _) = try await makeRunner(database: db, brain: brain)
        let log = TurnLog(database: db)
        // An earlier attempt saved the turn and lost its answer; a watch has continued it since.
        let person = try await log.writer(for: DeviceID("phone")).append(.person, "once", parents: [], nonce: "n1")
        _ = try await log.writer(for: DeviceID("watch")).append(.person, "and then", parents: [person.ref])
        do {
            _ = try await runner.run("once", model: .sonnet, nonce: "n1", known: [])
            Issue.record("expected the turn to be moved past")
        } catch TurnRunnerError.movedPast(let found) {
            #expect(found.ref == person.ref)
        }
        #expect(brain.requests.isEmpty)
        #expect(brain.bound.isEmpty)
        #expect(try await log.read().ordered.map(\.text) == ["once", "and then"])
    }
}

actor Steps {
    private(set) var all: [TurnRunner.Progress] = []
    func add(_ step: TurnRunner.Progress) { all.append(step) }
}
