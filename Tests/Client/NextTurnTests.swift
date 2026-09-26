import Foundation
import TopoAuth
import TopoCore
import TopoCoreTesting
import TopoTurn
import XCTest

@testable import Topo

/// The row at the end of the transcript as state: what it holds, what it refuses to hold, and
/// what it comes back holding after the app has been killed with words on the line. Each test
/// drives a real `NextTurn` against a real `Harness` over the in-memory log, and holds the log
/// beside the row — the row's whole job is to say one turn once, so a row that looks right over
/// a log with two turns in it is not right.
@MainActor
final class NextTurnTests: XCTestCase {
    private let phone = DeviceID("phone")

    // MARK: Words on their way cannot be typed over, or edited over

    /// The reviewer's sequence: a turn is on its way, and holding an older landed turn offers to
    /// put its words in the row. The row is drawing the words being sent, so it must refuse them
    /// — a row showing "B" over a turn saying "A" is the one thing the bubble cannot do.
    func testALandedTurnsWordsAreRefusedWhileAnotherTurnIsOnItsWay() async throws {
        let db = InMemoryRecordDatabase()
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport((200, reply("Will do."))))
        let row = NextTurn()

        row.text = "call Helen"
        await send(row, via: harness)
        let landed = try XCTUnwrap(harness.turns.first { $0.role == .person })
        XCTAssertEqual(landed.text, "call Helen")

        // A second turn, held before it reaches the log.
        let offline = self.harness(db, defaults: makeDefaults(), transport: ScriptedTransport(),
                                   ensureZone: { throw Unexpected() })
        await offline.refresh()
        row.text = "and book the flights"
        row.send(via: offline)
        XCTAssertTrue(row.sending(in: offline), "the second turn is on its way")

        let took = row.edit(landed, in: offline)

        XCTAssertFalse(took, "a landed turn's words were taken into a row holding a turn on its way")
        XCTAssertEqual(row.text, "and book the flights", "the row is no longer drawing the words being sent")
        XCTAssertEqual(offline.waiting, ["and book the flights"], "the line is not what the row shows")
        let turns = try await log(db).filter { $0.role == .person }.map(\.text)
        XCTAssertEqual(turns, ["call Helen"], "the log took a second turn")
    }

    /// The same offer with nothing on its way is the whole point of Edit, so the refusal above
    /// has to be the turn in flight and not the offer being gone.
    func testALandedTurnsWordsComeBackIntoAFreeRow() async throws {
        let db = InMemoryRecordDatabase()
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport((200, reply("Will do."))))
        let row = NextTurn()
        row.text = "call Helen"
        await send(row, via: harness)
        let landed = try XCTUnwrap(harness.turns.first { $0.role == .person })

        XCTAssertFalse(row.sending(in: harness), "the turn landed, so the row is free")
        XCTAssertTrue(row.edit(landed, in: harness))
        XCTAssertEqual(row.text, "call Helen")
        XCTAssertTrue(row.typing, "the words came back with nowhere to type them")
        let turns = try await log(db).filter { $0.role == .person }.map(\.text)
        XCTAssertEqual(turns, ["call Helen"], "editing wrote to the log")
    }

    // MARK: The row after a relaunch

    /// The app is killed with words said and not in the log. The screen that comes back is a
    /// fresh one, and the row it draws has to be the row the turn was sent from: the words in it,
    /// on their way, under the nonce they were first said with — which is where the way back is.
    func testARelaunchComesBackToTheRowTheTurnWasSentFrom() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let offline = harness(db, defaults: defaults, transport: ScriptedTransport(),
                              ensureZone: { throw Unexpected() })
        let sending = NextTurn()
        sending.text = "water the plants"
        sending.send(via: offline)
        await offline.retry()
        XCTAssertEqual(offline.waiting, ["water the plants"], "the turn never reached the log")

        // The app goes away. A new harness and a new row start over the same disk.
        let relaunched = harness(db, defaults: defaults, transport: ScriptedTransport(),
                                 ensureZone: { throw Unexpected() })
        let row = NextTurn()
        await relaunched.refresh()

        XCTAssertTrue(row.resume(from: relaunched), "the row came back empty")

        XCTAssertEqual(row.text, "water the plants")
        XCTAssertEqual(row.sent, relaunched.owed.first?.nonce, "the row is holding a nonce of its own")
        XCTAssertTrue(row.sending(in: relaunched), "the words are not drawn as on their way")
        XCTAssertTrue(row.canWithdraw(in: relaunched), "the way back is not offered where it is needed")

        // And the way back works from there: one nonce, one turn, said once.
        let held = try XCTUnwrap(row.sent)
        let taken = await row.withdraw(via: relaunched)
        XCTAssertEqual(taken, held, "the way back took back something other than what the row held")
        XCTAssertNil(row.sent, "the row is still holding a turn nothing is sending")
        XCTAssertEqual(row.text, "water the plants", "the words to be changed went with the turn")
        XCTAssertTrue(relaunched.waiting.isEmpty, "the words are still on the line")
        XCTAssertNil(defaults.data(forKey: "topo.harness.outbox"))
        let turns = try await log(db)
        XCTAssertTrue(turns.isEmpty, "a turn nobody sent reached the log")
    }

    /// A relaunch whose read finds the turn already in the log — the acknowledgement was lost,
    /// not the write. Those words are said: they belong to the transcript, and a row that drew
    /// them would offer to say them a second time.
    func testARelaunchThatFindsTheTurnInTheLogLeavesTheRowEmpty() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let offline = harness(db, defaults: defaults, transport: ScriptedTransport(),
                              ensureZone: { throw Unexpected() })
        let nonce = offline.willSend("water the plants")

        // The write did land, under that same nonce; only the answer to it was lost.
        let log = TurnLog(database: db)
        let writer = try await log.writer(for: phone)
        _ = try await writer.append(.person, "water the plants", continuing: try await log.read(), nonce: nonce)

        let relaunched = harness(db, defaults: defaults, transport: ScriptedTransport(),
                                 ensureZone: { throw Unexpected() })
        await relaunched.refresh()
        XCTAssertEqual(relaunched.owed.first?.nonce, nonce, "the line still holds the words")

        XCTAssertTrue(relaunched.said(nonce), "the read did not find the turn")
        let row = NextTurn()
        XCTAssertFalse(row.resume(from: relaunched), "the row took up words that are already said")
        XCTAssertEqual(row.text, "")
        XCTAssertNil(row.sent)
    }

    /// Two turns said before the app went away, the first of which reached the log and lost only
    /// its acknowledgement. Its retry settles it silently; what was said behind it is still owed,
    /// and it is that turn the row has to come back holding — a row resumed from the head of the
    /// line would find the head said and come back empty over a turn nobody can see or take back.
    func testARelaunchResumesTheTurnBehindOneThatLanded() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let offline = harness(db, defaults: defaults, transport: ScriptedTransport(),
                              ensureZone: { throw Unexpected() })
        let landed = offline.willSend("call Helen")
        let owed = offline.willSend("and book the flights")

        // The first turn did reach the log, under its own nonce; only the answer to it was lost.
        let log = TurnLog(database: db)
        let writer = try await log.writer(for: phone)
        _ = try await writer.append(.person, "call Helen", continuing: try await log.read(), nonce: landed)

        let relaunched = harness(db, defaults: defaults, transport: ScriptedTransport(),
                                 ensureZone: { throw Unexpected() })
        await relaunched.refresh()
        XCTAssertEqual(relaunched.owed.map(\.nonce), [landed, owed], "both turns are still on the line")
        XCTAssertTrue(relaunched.said(landed), "the read did not find the first turn")

        let row = NextTurn()
        XCTAssertTrue(row.resume(from: relaunched), "the row came back empty over a turn still owed")

        XCTAssertEqual(row.text, "and book the flights", "the row came back holding the wrong turn")
        XCTAssertEqual(row.sent, owed)
        XCTAssertTrue(row.sending(in: relaunched), "the words are not drawn as on their way")
        XCTAssertTrue(row.canWithdraw(in: relaunched), "the way back is not offered for the turn nobody can see")
    }

    /// A screen that has not been away: the row is already holding something, and a resume that
    /// wrote over it would lose what is being typed.
    func testResumingDoesNotWriteOverARowInUse() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let offline = harness(db, defaults: defaults, transport: ScriptedTransport(),
                              ensureZone: { throw Unexpected() })
        offline.willSend("water the plants")
        let row = NextTurn()
        row.text = "half a thought"

        XCTAssertFalse(row.resume(from: offline))
        XCTAssertEqual(row.text, "half a thought")
        XCTAssertNil(row.sent)
    }

    // MARK: -

    private func send(_ row: NextTurn, via harness: Harness) async {
        row.send(via: harness)
        await harness.retry()
        row.clearIfLanded(in: harness)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "topo.tests.row.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private func harness(_ database: any RecordDatabase, defaults: UserDefaults,
                         transport: ScriptedTransport,
                         ensureZone: @escaping @Sendable () async throws -> Void = {}) -> Harness {
        Harness(database: database, tokens: FixedToken(), device: phone, ensureZone: ensureZone,
                defaults: defaults, brain: guestBrain(over: transport), leaseSleep: parked,
                pause: { _ in throw CancellationError() })
    }

    private func log(_ database: any RecordDatabase) async throws -> [Turn] {
        try await TurnLog(database: database).read().ordered
    }
}

private final class ScriptedTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, String)]

    init(_ replies: (Int, String)...) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock {
            let (status, text) = replies.isEmpty ? (500, "{}") : replies.removeFirst()
            return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

private func reply(_ text: String) -> String {
    #"{"id":"msg","type":"message","model":"claude-haiku-4-5","content":[{"type":"text","text":"\#(text)"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#
}

private struct FixedToken: TokenProvider {
    func accessToken() async throws -> String { "tok" }
}

private struct Unexpected: Error {}

/// A heartbeat loop that never beats inside a test: the lease is renewed by the turns themselves.
private let parked: @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }
