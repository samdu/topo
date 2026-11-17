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

    /// A pass that bound the words heard to their turn and was then stopped before it asked
    /// (`TurnRunner`'s cancellation check, a stop's `stopFlight`): the bound record stands, and the
    /// next pass's ask listens to the words again on the same process rather than writing them twice.
    @Test func aPassStoppedAfterItsBindLeavesTheWordsForTheNextAsk() async throws {
        let rig = try Rig()
        let brain = rig.brain()
        let hello = turn("phone", 1, .person, "hello")
        let first = try await brain.answer(request(hello))
        await brain.landed(turn("mac", 1, .assistant, first.text, parents: [hello.ref]), nonce: request(hello).nonce)
        let nonce = UUID().uuidString
        let person = Turn(ref: TurnRef(device: DeviceID("phone"), sequence: 2), parents: [], role: .person,
                          text: "SLOW stopped", at: Date(), nonce: nonce)
        let asked = request(person)
        #expect(await brain.hearAhead("SLOW stopped", nonce: nonce, model: .sonnet) == nil)
        await brain.bind(nonce: nonce, person: person, reply: asked.nonce)
        // The pass is cancelled here, asking nothing; the stop ends the flight.
        await brain.stopFlight()
        // Mutant: the bound record dropped at the stop, and the words written a second time.
        let reply = try await brain.answer(asked)
        #expect(reply.text == "echo: SLOW stopped")
        #expect(rig.inputs == ["hello", "SLOW stopped"])
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
    /// answered as ever. Past the bound they no longer keep other hand-overs out; the mind's reply
    /// to them is kept, and a turn saved under their nonce after that is answered with it, its
    /// words not told again.
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
        // The kept words handed again: heard, with nothing sent.
        // Mutant: a kept nonce not known to the hand-over, its words told a second time.
        #expect(await hear(hub, lease, "lost words", nonce: lost))
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.rig.inputs == ["hello", "lost words", "next"])
        // Past the bound another hand-over is heard.
        let other = UUID().uuidString
        #expect(await hear(hub, lease, "other", nonce: other))
        #expect(await eventually { h.rig.inputs.count == 4 })
        try await says(hub, h, "other", nonce: other)
        #expect(try await eventually { try await h.replies().count == 3 })
        // The turn arrives late: the mind's reply to its words is written, bound to it.
        let late = try await says(hub, h, "lost words", nonce: lost)
        #expect(try await eventually { try await h.replies().count == 4 })
        try await Task.sleep(for: .milliseconds(500))
        // Mutant: a kept reply forgotten, and the late turn held cut off with nothing for the person.
        let reply = try #require(try await h.replies().last)
        #expect(reply.parents == [late.ref])
        #expect(reply.text == "echo: lost words")
        // Mutant: the late turn asked a second time.
        #expect(h.rig.inputs == ["hello", "lost words", "next", "other"])
        #expect(await h.brain.unresolved().isEmpty)
        await hub.turnOff()
    }

    /// Words the mind was cut off on, whose turn never came by the bound: a turn saved under their
    /// nonce later is held cut off, as any turn the mind was cut off on is, and not asked again.
    @Test func wordsCutOffWhoseTurnComesPastTheBoundAreHeldCutOff() async throws {
        let h = try HubRig(earlyBound: 1.5)
        let (hub, lease) = try await ready(h)
        let lost = UUID().uuidString
        #expect(await hear(hub, lease, "FAIL lost words", nonce: lost))
        #expect(await eventually { h.rig.inputs.count == 2 })
        try await Task.sleep(for: .seconds(1.6))
        try await says(hub, h, "next")
        #expect(try await eventually { try await h.replies().count == 2 })
        let late = try await says(hub, h, "FAIL lost words", nonce: lost)
        try await Task.sleep(for: .seconds(1))
        // Mutant: a dropped nonce forgotten, and the late turn asked a second time.
        #expect(h.rig.inputs == ["hello", "FAIL lost words", "next"])
        #expect(try await h.replies().count == 2)
        #expect(await h.brain.unresolved() == [late.ref])
        await hub.turnOff()
    }

    /// Words heard ahead whose turn a request answers beside another person's, when the ledger's
    /// one record of an input could not take them first: the mind is not told them again, and
    /// the request is told the other turn alone. Their own reply is not written: the request's
    /// reply answers both.
    @Test func heardWordsAnsweredBesideAnotherTurnAreNotToldAgain() async throws {
        let rig = try Rig()
        let brain = rig.brain()
        let hello = turn("phone", 1, .person, "hello")
        let first = request(hello)
        _ = try await brain.answer(first)
        let rHello = turn("mac", 1, .assistant, "echo: hello", parents: [hello.ref])
        await brain.landed(rHello, nonce: first.nonce)
        let nonce = UUID().uuidString
        #expect(await brain.hearAhead("pee words", nonce: nonce, model: .sonnet) == nil)
        #expect(await eventually { rig.inputs.count == 2 })
        let p = Turn(ref: TurnRef(device: DeviceID("phone"), sequence: 2), parents: [rHello.ref], role: .person,
                     text: "pee words", at: Date(), nonce: nonce)
        let q = Turn(ref: TurnRef(device: DeviceID("ipad"), sequence: 1), parents: [rHello.ref], role: .person,
                     text: "queue words", at: Date())
        #expect(await brain.heardAhead(of: p))
        let heads = [p.ref, q.ref]
        _ = try await brain.answer(BrainRequest(context: [hello, rHello], answering: [p, q], parents: heads,
                                                nonce: TurnRunner.replyNonce(for: heads), model: .sonnet))
        // Mutant: the heard turn rendered with the rest.
        #expect(rig.inputs == ["hello", "pee words", "queue words"])
        await brain.shutdown()
    }

    /// A turn saved under the nonce of words heard ahead, with other words, beside another: the
    /// saved words are told as said.
    @Test func aSavedTurnBesideAnotherWhoseWordsDifferIsToldAsSaved() async throws {
        let rig = try Rig()
        let brain = rig.brain()
        let hello = turn("phone", 1, .person, "hello")
        let first = request(hello)
        _ = try await brain.answer(first)
        let rHello = turn("mac", 1, .assistant, "echo: hello", parents: [hello.ref])
        await brain.landed(rHello, nonce: first.nonce)
        let nonce = UUID().uuidString
        #expect(await brain.hearAhead("pee words", nonce: nonce, model: .sonnet) == nil)
        #expect(await eventually { rig.inputs.count == 2 })
        let p = Turn(ref: TurnRef(device: DeviceID("phone"), sequence: 2), parents: [rHello.ref], role: .person,
                     text: "pee words, edited", at: Date(), nonce: nonce)
        let q = Turn(ref: TurnRef(device: DeviceID("ipad"), sequence: 1), parents: [rHello.ref], role: .person,
                     text: "queue words", at: Date())
        #expect(!(await brain.heardAhead(of: p)))
        let heads = [p.ref, q.ref]
        _ = try await brain.answer(BrainRequest(context: [hello, rHello], answering: [p, q], parents: heads,
                                                nonce: TurnRunner.replyNonce(for: heads), model: .sonnet))
        // Mutant: a match by nonce alone, the edited words dropped.
        #expect(rig.inputs.last == "pee words, edited\n\nqueue words")
        await brain.shutdown()
    }

    /// Words heard ahead while the ledger's one record of an input holds a turn the mind was cut
    /// off on: the brain does not say it heard them alone, since binding them would take that
    /// record's place, and a request answers them beside the rest, not told again.
    @Test func heardWordsBesideAHeldCutOffTurnAreNotAnsweredAlone() async throws {
        let rig = try Rig()
        let brain = rig.brain()
        let hello = turn("phone", 1, .person, "hello")
        let first = request(hello)
        _ = try await brain.answer(first)
        let rHello = turn("mac", 1, .assistant, "echo: hello", parents: [hello.ref])
        await brain.landed(rHello, nonce: first.nonce)
        let nonce = UUID().uuidString
        #expect(await brain.hearAhead("pee words", nonce: nonce, model: .sonnet) == nil)
        #expect(await eventually { rig.inputs.count == 2 })
        // Another device's turn, asked while the words wait for theirs, and cut off.
        let cut = turn("pad", 1, .person, "FAIL cut off", parents: [rHello.ref])
        await #expect(throws: (any Error).self) { try await brain.answer(request(cut, context: [hello, rHello])) }
        try #require(await brain.unresolved() == [cut.ref])
        let p = Turn(ref: TurnRef(device: DeviceID("phone"), sequence: 2), parents: [rHello.ref], role: .person,
                     text: "pee words", at: Date(), nonce: nonce)
        // Mutant: the record's slot not asked, and the heard turn answered alone over the cut-off one.
        #expect(!(await brain.heardAhead(of: p)))
        await brain.shutdown()
    }

    /// Words heard ahead whose turn is the one turn a request answers, beside a head the reply
    /// continues too (one held cut off): the reply is the heard one, and nothing is told again.
    @Test func heardWordsAnsweredAloneBesideAnotherHeadAreBound() async throws {
        let rig = try Rig()
        let brain = rig.brain()
        let hello = turn("phone", 1, .person, "hello")
        let first = request(hello)
        _ = try await brain.answer(first)
        let rHello = turn("mac", 1, .assistant, "echo: hello", parents: [hello.ref])
        await brain.landed(rHello, nonce: first.nonce)
        let x = turn("ipad", 1, .person, "from the pad", parents: [rHello.ref])
        let nonce = UUID().uuidString
        #expect(await brain.hearAhead("fork words", nonce: nonce, model: .sonnet) == nil)
        #expect(await eventually { rig.inputs.count == 2 })
        let p = Turn(ref: TurnRef(device: DeviceID("phone"), sequence: 2), parents: [rHello.ref], role: .person,
                     text: "fork words", at: Date(), nonce: nonce)
        let heads = [p.ref, x.ref]
        let reply = try await brain.answer(BrainRequest(context: [hello, rHello, x], answering: [p], parents: heads,
                                                        nonce: TurnRunner.replyNonce(for: heads), model: .sonnet))
        // Mutant: a bind only under the turn's own parents, and the words asked again.
        #expect(reply.text == "echo: fork words")
        #expect(rig.inputs == ["hello", "fork words"])
        await brain.shutdown()
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

    /// Words heard ahead stall the mind while a heartbeat of the lease is out, so the stop waits
    /// for it; a sleep and a wake meanwhile start the mind again on a process of its own, which
    /// the stalled turn's stop leaves running.
    @Test func aStallsStopOvertakenByAWakeLeavesTheNewProcess() async throws {
        let h = try HubRig(silence: .seconds(1))
        let gate = PassGate(h.db)
        let configuration = h.configuration
        let hub = HubMind(database: gate, device: h.hubID, endpoint: "127.0.0.1:1", probe: Confirming(),
                          brain: h.brain, login: { await MindLogin.check(configuration) }, model: { .sonnet },
                          timing: LeaseTiming(duration: 8, heartbeat: 0.2), poll: .seconds(3600), answeringPoll: .seconds(3600))
        await hub.turnOn()
        #expect(await eventually { await hub.snapshot().phase == .answering })
        try await says(hub, h, "hello")
        #expect(try await eventually { try await h.replies().count == 1 })
        try await Task.sleep(for: .milliseconds(300))
        let lease = try #require(await h.lease())
        let stalled = try #require(await hub.pid)
        #expect(await hear(hub, lease, "HANG ahead", nonce: UUID().uuidString))
        gate.arm(.leaseSave)
        #expect(await eventually { gate.holding })
        // The silence bound runs out on the words, and the mind's stop waits for the heartbeat.
        #expect(await eventually { await hub.snapshot().mind.contains("stalled") })
        try await Task.sleep(for: .milliseconds(200))
        // Mutant: a stop that does not wait for the heartbeat out, which has stopped the mind by now.
        #expect(await hub.snapshot().phase == .answering)
        let sleeping = Task { await hub.willSleep() }
        try await Task.sleep(for: .milliseconds(200))
        await hub.didWake()
        // The new session's process is up before the lease's gate lets its takeover through.
        #expect(await eventually { if let pid = await hub.pid { return pid != stalled } else { return false } })
        let woken = try #require(await hub.pid)
        gate.release()
        await sleeping.value
        #expect(await eventually { await hub.snapshot().phase == .answering })
        try await Task.sleep(for: .milliseconds(500))
        // Mutant: the stalled turn's stop shutting the brain down after the wake began again.
        #expect(await hub.pid == woken)
        await hub.turnOff()
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
