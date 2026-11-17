import Foundation
import Testing
import TopoCore
import TopoCoreTesting
import TopoTurn
@testable import TopoMind

extension HubRig {
    /// A limb's turn under the nonce the phone handed its words over under.
    @discardableResult
    func phoneSays(_ text: String, nonce: String) async throws -> Turn {
        let log = TurnLog(database: db)
        let writer = try await log.writer(for: phoneID)
        return try await writer.append(.person, text, continuing: try await log.read(), nonce: nonce)
    }

    /// The phone answering a turn itself, as it does once it holds the lease.
    @discardableResult
    func phoneAnswers(_ person: Turn, _ text: String) async throws -> Turn {
        let log = TurnLog(database: db)
        let writer = try await log.writer(for: phoneID)
        return try await writer.append(.assistant, text, parents: [person.ref], nonce: TurnRunner.replyNonce(for: [person.ref]))
    }
}

/// Words a phone hands the hub before their turn is saved (`HubMind.hear`, `NativeBrain.hearAhead`):
/// the mind hears them at once, the pass that finds the turn binds the reply to it, and every way
/// the turn fails to come leaves one input, no reply out of place, and the conversation aligned.
@Suite(.serialized) struct HubHearTests {
    /// A hub on, its mind having answered one turn of the log, so it is ready to hear.
    func ready(_ h: HubRig, poll: Duration = .seconds(3600)) async throws -> (HubMind, Lease) {
        let hub = h.hub(poll: poll)
        await hub.turnOn()
        #expect(await eventually { await hub.snapshot().phase == .answering })
        try await says(hub, h, "hello")
        #expect(try await eventually { try await h.replies().count == 1 })
        // The pass that answered has ended; the hub is ready.
        try await Task.sleep(for: .milliseconds(300))
        let lease = try #require(await h.lease())
        return (hub, lease)
    }

    /// A limb's turn saved, and the hub told it moved, as a push or the phone's nudge tells it:
    /// these suites run no poll, so no pass runs but the ones asked for.
    @discardableResult
    func says(_ hub: HubMind, _ h: HubRig, _ text: String, nonce: String = UUID().uuidString) async throws -> Turn {
        let turn = try await h.phoneSays(text, nonce: nonce)
        await hub.trigger(.push)
        return turn
    }

    /// While a pass runs, or one is asked for, nothing is heard: the log may hold a turn the mind
    /// has not been told, and words heard now would be told ahead of it.
    @Test func nothingIsHeardWhileAPassRunsOrIsAskedFor() async throws {
        let h = try HubRig()
        let (hub, lease) = try await ready(h)
        // Another device's turn the mind has not been told, its pass about to run.
        try await h.phoneSays("STREAM first")
        await hub.trigger(.push)
        // Mutant: hearing beside a pass that is asked for or running.
        #expect(!(await hear(hub, lease, "second", nonce: UUID().uuidString)))
        #expect(await eventually { h.rig.inputs.count == 2 })
        #expect(!(await hear(hub, lease, "second", nonce: UUID().uuidString)))
        try Data().write(to: h.rig.log.appending(path: "release"))
        #expect(try await eventually { try await h.replies().count == 2 })
        #expect(h.rig.inputs == ["hello", "STREAM first"])
        await hub.turnOff()
    }

    func hear(_ hub: HubMind, _ lease: Lease, _ words: String, nonce: String, model: String = "sonnet") async -> Bool {
        await hub.hear(holder: lease.holder, epoch: lease.epoch, nonce: nonce, model: model, words: words)
    }

    @Test func wordsHeardThenSavedAreOneInputAndOneReplyAfterTheTurn() async throws {
        let h = try HubRig()
        let (hub, lease) = try await ready(h)
        let nonce = UUID().uuidString
        #expect(await hear(hub, lease, "SLOW second", nonce: nonce))
        // The mind has the words before the log has the turn.
        #expect(await eventually { h.rig.inputs.count == 2 })
        #expect(h.rig.inputs.last == "SLOW second")
        // Answered, and nothing written: a reply never lands before its turn.
        try await Task.sleep(for: .seconds(2))
        // Mutant: the flight's answer written as an owed reply with no turn to continue.
        #expect(try await h.replies().count == 1)
        let person = try await says(hub, h, "SLOW second", nonce: nonce)
        #expect(try await eventually { try await h.replies().count == 2 })
        let reply = try #require(try await h.replies().last)
        #expect(reply.parents == [person.ref])
        #expect(reply.nonce == TurnRunner.replyNonce(for: [person.ref]))
        #expect(reply.text == "echo: SLOW second")
        // Mutant: the pass that finds the turn asks the words again.
        try await Task.sleep(for: .milliseconds(500))
        #expect(h.rig.inputs == ["hello", "SLOW second"])
        await hub.turnOff()
    }

    /// A pass that finds the turn while the mind is still on the words waits for that answer
    /// rather than asking again; the reply is the heard one.
    @Test func aTurnFoundWhileTheMindIsStillOnItsWordsIsAnsweredByThem() async throws {
        let h = try HubRig()
        let (hub, lease) = try await ready(h)
        let nonce = UUID().uuidString
        #expect(await hear(hub, lease, "STREAM now", nonce: nonce))
        let person = try await says(hub, h, "STREAM now", nonce: nonce)
        try await Task.sleep(for: .seconds(1))
        #expect(try await h.replies().count == 1)
        try Data().write(to: h.rig.log.appending(path: "release"))
        #expect(try await eventually { try await h.replies().count == 2 })
        #expect(try await h.replies().last?.parents == [person.ref])
        #expect(h.rig.inputs == ["hello", "STREAM now"])
        await hub.turnOff()
    }

    /// A hand-over that lands after the pass's bind found nothing and before it asks: the ask is
    /// bound to the words heard, and nothing is written a second time.
    @Test func aHandOverBetweenThePasssBindAndItsAskIsThatAsksInput() async throws {
        let rig = try Rig()
        let brain = rig.brain()
        let hello = turn("phone", 1, .person, "hello")
        let first = try await brain.answer(request(hello))
        await brain.landed(turn("mac", 1, .assistant, first.text, parents: [hello.ref]), nonce: request(hello).nonce)
        let nonce = UUID().uuidString
        let person = Turn(ref: TurnRef(device: DeviceID("phone"), sequence: 2), parents: [], role: .person,
                          text: "SLOW between", at: Date(), nonce: nonce)
        let asked = request(person)
        await brain.bind(nonce: nonce, person: person, reply: asked.nonce)
        #expect(await brain.hearAhead("SLOW between", nonce: nonce, model: .sonnet) == nil)
        // Mutant: `answer` not binding the words heard, and so writing them again.
        let reply = try await brain.answer(asked)
        #expect(reply.text == "echo: SLOW between")
        #expect(rig.inputs == ["hello", "SLOW between"])
        await brain.shutdown()
    }

    /// Words are not heard into a conversation that has nothing of the log, nor beside a reply the
    /// mind owes the log, which is written before anything is said after it.
    @Test func wordsAreNotHeardIntoAFreshConversationOrBesideAnOwedReply() async throws {
        let rig = try Rig()
        let brain = rig.brain()
        try await brain.start()
        // Mutant: a fresh conversation given words with nothing of the log told.
        #expect(await brain.hearAhead("words", nonce: UUID().uuidString, model: .sonnet) == .fresh)
        let hello = turn("phone", 1, .person, "hello")
        _ = try await brain.answer(request(hello))
        // Mutant: words heard beside a reply still owed.
        #expect(await brain.hearAhead("words", nonce: UUID().uuidString, model: .sonnet) == .busy)
        await brain.landed(turn("mac", 1, .assistant, "echo: hello", parents: [hello.ref]), nonce: request(hello).nonce)
        // With no process running the model the words were chosen with, none is started for them:
        // the turn goes by the log, which starts one on the model its pass reads.
        _ = await brain.shutdown()
        // Mutant: a hand-over written to no process, or starting one.
        #expect(await brain.hearAhead("words", nonce: UUID().uuidString, model: .sonnet) == .process)
        #expect(rig.inputs == ["hello"])
    }

    /// The mind's turn on words heard ahead ends before the pass that binds them asks: that
    /// request has no frames of its own, so its followers are handed no `.turn` that would wipe
    /// what they drew; a request for another turn is handed as ever.
    @Test func aHeardReplyEndedBeforeItsPassIsNotBegunAgain() throws {
        let cast = ReplyCast()
        let nonce = UUID().uuidString
        let person = Turn(ref: TurnRef(device: DeviceID("phone"), sequence: 2), parents: [], role: .person,
                          text: "w", at: Date(), nonce: nonce)
        let other = Turn(ref: TurnRef(device: DeviceID("pad"), sequence: 3), parents: [], role: .person,
                         text: "o", at: Date(), nonce: UUID().uuidString)
        let frames = Frames()
        let id = cast.follow(HubMind.mark(of: nonce), frames.hand)
        cast.beginHeard(nonce)
        cast.writeHeard(.message)
        cast.writeHeard(.text("Heard."))
        cast.endHeard()
        cast.begin([person])
        cast.end()
        // Mutant: the heard lane's turn forgotten at its end.
        #expect(frames.frames == [.heard(nonce), .message, .text("Heard.")])
        #expect(frames.words == "Heard.")
        // Once that request has ended, the same mark is the request lane's again.
        cast.begin([person])
        #expect(frames.frames.last == .turn([person.ref]))
        cast.end()
        let others = Frames()
        let otherID = cast.follow(HubMind.mark(of: other.nonce), others.hand)
        cast.beginHeard(nonce)
        cast.endHeard()
        cast.begin([other])
        #expect(others.frames == [.turn([other.ref])])
        cast.stop(id)
        cast.stop(otherID)
    }

    @Test func wordsHeardTwiceAreHeardOnce() async throws {
        let h = try HubRig()
        let (hub, lease) = try await ready(h)
        let nonce = UUID().uuidString
        #expect(await hear(hub, lease, "SLOW twice", nonce: nonce))
        // Mutant: a second hand-over of the nonce sent again.
        #expect(await hear(hub, lease, "SLOW twice", nonce: nonce))
        try await Task.sleep(for: .seconds(2))
        #expect(h.rig.inputs == ["hello", "SLOW twice"])
        try await says(hub, h, "SLOW twice", nonce: nonce)
        #expect(try await eventually { try await h.replies().count == 2 })
        // Once landed, the same words handed over again are not heard.
        #expect(!(await hear(hub, lease, "SLOW twice", nonce: nonce)))
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.rig.inputs == ["hello", "SLOW twice"])
        await hub.turnOff()
    }

    /// The pass found the turn and answered it before the hand-over arrived: the hand-over is
    /// refused, while the mind is on the turn and after its reply landed.
    @Test func aHandOverAfterThePassFoundTheTurnIsRefused() async throws {
        let h = try HubRig()
        let (hub, lease) = try await ready(h)
        let nonce = UUID().uuidString
        try await says(hub, h, "STREAM late", nonce: nonce)
        #expect(await eventually { h.rig.inputs.count == 2 })
        // Mutant: a hand-over taken while a turn is with the process.
        #expect(!(await hear(hub, lease, "STREAM late", nonce: nonce)))
        try Data().write(to: h.rig.log.appending(path: "release"))
        #expect(try await eventually { try await h.replies().count == 2 })
        // Mutant: no memory of the nonces whose replies landed.
        #expect(!(await hear(hub, lease, "STREAM late", nonce: nonce)))
        try await Task.sleep(for: .milliseconds(500))
        #expect(h.rig.inputs == ["hello", "STREAM late"])
        #expect(try await h.replies().count == 2)
        await hub.turnOff()
    }

    @Test func nothingIsHeardForAnotherLeaseAMindNotAnsweringOrAFreshConversation() async throws {
        let h = try HubRig()
        let hub = h.hub(poll: .seconds(3600))
        let nonce = UUID().uuidString
        let off = Lease(holder: h.hubID, endpoint: nil, epoch: 1, expiresAt: Date().addingTimeInterval(60))
        #expect(!(await hear(hub, off, "words", nonce: nonce)))
        await hub.turnOn()
        #expect(await eventually { await hub.snapshot().holds })
        let lease = try #require(await h.lease())
        // Mutant: hearing before a pass has told the mind the log (a fresh conversation).
        #expect(!(await hear(hub, lease, "words", nonce: nonce)))
        try await says(hub, h, "hello")
        #expect(try await eventually { try await h.replies().count == 1 })
        try await Task.sleep(for: .milliseconds(300))
        // Mutant: the epoch not checked.
        let stale = Lease(holder: lease.holder, endpoint: nil, epoch: lease.epoch + 1, expiresAt: lease.expiresAt)
        #expect(!(await hear(hub, stale, "words", nonce: nonce)))
        #expect(!(await hear(hub, lease, "words", nonce: nonce, model: "gpt")))
        #expect(h.rig.inputs == ["hello"])
        await hub.willSleep()
        #expect(!(await hear(hub, lease, "words", nonce: nonce)))
        // After the wake the lease is this Mac's again, but nothing is heard until a pass has
        // told the mind what the log gained meanwhile.
        await hub.didWake()
        #expect(await eventually { await hub.snapshot().holds })
        try await Task.sleep(for: .milliseconds(400))
        let woken = try #require(await h.lease())
        // Mutant: a start that keeps the readiness of the session before it.
        #expect(!(await hear(hub, woken, "words", nonce: nonce)))
        #expect(h.rig.inputs == ["hello"])
        await hub.turnOff()
    }

    /// Words whose turn never comes wait unbound, and are not the next turn's: that turn is
    /// answered as ever. Past the bound they are moved past, and a turn saved under their nonce
    /// after that is held cut off rather than asked again.
    @Test func wordsWhoseTurnNeverComesAreBoundedAndAccounted() async throws {
        let h = try HubRig(earlyBound: 1.5)
        let (hub, lease) = try await ready(h)
        let lost = UUID().uuidString
        #expect(await hear(hub, lease, "lost words", nonce: lost))
        #expect(await eventually { h.rig.inputs.count == 2 })
        // While they wait, another hand-over is refused and goes by the log.
        #expect(!(await hear(hub, lease, "other", nonce: UUID().uuidString)))
        try await Task.sleep(for: .seconds(1.6))
        try await says(hub, h, "next")
        #expect(try await eventually { try await h.replies().count == 2 })
        // Mutant: the next turn's input re-tells or repeats the words heard.
        #expect(h.rig.inputs == ["hello", "lost words", "next"])
        #expect(try await h.replies().last?.text == "echo: next")
        // The turn arrives late: the mind has its words, so it is held cut off and not asked.
        let late = try await says(hub, h, "lost words", nonce: lost)
        try await Task.sleep(for: .seconds(1))
        // Mutant: a dropped nonce forgotten, and the late turn asked a second time.
        #expect(h.rig.inputs == ["hello", "lost words", "next"])
        #expect(try await h.replies().count == 2)
        #expect(await h.brain.unresolved() == [late.ref])
        await hub.turnOff()
    }

    /// The lease goes (here the switch, the phone then answering the turn itself) after the mind
    /// heard the words: the hub writes no reply for them, and its next turn's input tells the
    /// phone's reply and not the words again.
    @Test func wordsHeardThenTheLeaseLostWriteNothingAndAreAccountedNextTurn() async throws {
        let h = try HubRig()
        let (hub, lease) = try await ready(h)
        let nonce = UUID().uuidString
        #expect(await hear(hub, lease, "heard words", nonce: nonce))
        #expect(await eventually { h.rig.inputs.count == 2 })
        try await Task.sleep(for: .milliseconds(500))
        await hub.turnOff()
        let person = try await says(hub, h, "heard words", nonce: nonce)
        try await h.phoneAnswers(person, "the phone's answer")
        await hub.turnOn()
        try await says(hub, h, "after")
        #expect(try await eventually { try await h.replies().count == 3 })
        let last = try #require(h.rig.inputs.last)
        #expect(last.contains("the phone's answer"))
        // Mutant: the words the mind heard told again as the person's turn.
        #expect(!last.contains("Them: heard words"))
        #expect(h.rig.inputs.filter { $0.contains("heard words") }.count == 1)
        #expect(try await h.replies().filter { $0.parents == [person.ref] }.map(\.text) == ["the phone's answer"])
        await hub.turnOff()
    }

    /// The saved turn's words are not the words heard: the saved turn wins, and is asked.
    @Test func aSavedTurnThatDiffersFromTheWordsHeardIsAnsweredAsSaved() async throws {
        let h = try HubRig()
        let (hub, lease) = try await ready(h)
        let nonce = UUID().uuidString
        #expect(await hear(hub, lease, "first words", nonce: nonce))
        #expect(await eventually { h.rig.inputs.count == 2 })
        try await Task.sleep(for: .milliseconds(300))
        try await says(hub, h, "other words", nonce: nonce)
        #expect(try await eventually { try await h.replies().count == 2 })
        // Mutant: bound by nonce alone, the heard reply written for words it did not answer.
        #expect(try await h.replies().last?.text == "echo: other words")
        await hub.turnOff()
    }

    /// A sleep, and the switch, with the mind on words heard ahead: each returns at once rather
    /// than when the turn ends, and after the wake the turn is listened to again, not asked again.
    @Test func aSleepWithWordsInFlightStopsAtOnceAndTheWakeListensAgain() async throws {
        let h = try HubRig()
        let (hub, lease) = try await ready(h)
        let nonce = UUID().uuidString
        #expect(await hear(hub, lease, "STREAM asleep", nonce: nonce))
        #expect(await eventually { h.rig.inputs.count == 2 })
        let person = try await says(hub, h, "STREAM asleep", nonce: nonce)
        // A pass has found the turn and waits for the slot the flight holds.
        try await Task.sleep(for: .milliseconds(600))
        // Mutant: the stop not ending the flight, and so waiting for the turn's end.
        #expect(await within(5) { await hub.willSleep() } != nil)
        #expect(try await h.replies().count == 1)
        await hub.didWake()
        try Data().write(to: h.rig.log.appending(path: "release"))
        #expect(try await eventually(20) { try await h.replies().count == 2 })
        #expect(try await h.replies().last?.parents == [person.ref])
        #expect(h.rig.inputs == ["hello", "STREAM asleep"])
        #expect(await within(5) { await hub.turnOff() } != nil)
    }

    @Test func theSwitchOffWithWordsInFlightReturnsAtOnceAndWritesNothing() async throws {
        let h = try HubRig()
        let (hub, lease) = try await ready(h)
        let nonce = UUID().uuidString
        #expect(await hear(hub, lease, "STREAM off", nonce: nonce))
        #expect(await eventually { h.rig.inputs.count == 2 })
        try await says(hub, h, "STREAM off", nonce: nonce)
        #expect(await within(8) { await hub.turnOff() } != nil)
        #expect(await hub.pid == nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await h.replies().count == 1)
    }

    /// The phone's nudge after the save follows the heard reply: `.heard` with the nonce, what was
    /// written so far, then the rest, and the log's reply is the same words.
    @Test func theNudgeAfterTheSaveIsStreamedTheHeardReply() async throws {
        let h = try HubRig()
        let (hub, lease) = try await ready(h, poll: .seconds(3600))
        let nonce = UUID().uuidString
        #expect(await hear(hub, lease, "STREAM heard", nonce: nonce))
        let person = try await says(hub, h, "STREAM heard", nonce: nonce)
        let frames = Frames()
        let answered = AnswerBox<Bool>()
        Task {
            let read = await hub.nudge(holder: lease.holder, epoch: lease.epoch, mark: HubMind.mark(of: person.nonce), stream: frames.hand)
            answered.lock.withLock { answered.value = read }
        }
        #expect(await eventually { frames.words == "One. Two.\n\nThree." })
        // Mutant: the heard reply on the request lane, or begun again as the turn's.
        #expect(frames.frames.first == .heard(nonce))
        #expect(!frames.frames.contains { if case .turn = $0 { true } else { false } })
        try Data().write(to: h.rig.log.appending(path: "release"))
        #expect(await eventually { answered.lock.withLock { answered.value } == true })
        #expect(try await h.replies().last?.text == frames.words)
        #expect(!frames.frames.contains(.cut))
        await hub.turnOff()
    }
}
