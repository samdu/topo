import XCTest

/// Where Topo sits, in the running chat: each placement over an empty chat, a full one and with the
/// keyboard up; a long press and a drag pins him, the pin outlives a relaunch and the keyboard never
/// rewrites it; a scroll that starts on him scrolls. Read off the badge's debug report
/// (`DebugRun.ChatReport`), whose frames are in the space he is drawn in; the microphone the system
/// finds says where that space is on the screen.
///
/// Every launch sets this device's override (`TOPO_DEBUG_TUNING`) or deliberately leaves it, and
/// the class leaves it empty behind it, so no pin outlives it into another suite.
final class TopoPlacementTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        addTeardownBlock {
            let app = ChatReading.launch(transcript: "empty", tuning: "")
            app.terminate()
        }
    }

    /// On the glass: over an empty chat and a full one the pane is drawn whole (presence 1) and
    /// his shelf is its top edge, over its leading end, his reach inside the transcript's width; with
    /// the keyboard up he rides the row up, over the same end, and back down with it.
    func testOnTheGlassHeSitsOnAPaneThatStays() throws {
        for transcript in ["empty", "full"] {
            let app = ChatReading.launch(transcript: transcript, tuning: #"{"mascot": {"placement": "glass"}}"#,
                                         softwareKeyboard: true)
            let mic = ChatReading.microphone(app)
            XCTAssertTrue(mic.waitForExistence(timeout: 60), "\(transcript): the chat screen")
            let (chat, topo) = try ChatReading.wait(app, "\(transcript): on the glass") { chat, topo in
                topo.roost == "glass" && topo.standing && chat.presence == 1
            }
            XCTAssertEqual(chat.placement, "glass")
            try assertOnTheGlass(topo, transcript)
            try assertFirstDrawnWhereHeStands(topo, transcript)
            ChatReading.attach(app, "glass-\(transcript)", to: self)
            let resting = try XCTUnwrap(topo.paneRect).height
            let risen: (ChatReading.Chat, ChatReading.Topo) -> Bool = { chat, now in
                now.roost == "glass" && now.standing && (now.paneRect?.height ?? resting) < resting - 1 && chat.presence == 1
            }
            let rested: (ChatReading.Chat, ChatReading.Topo) -> Bool = { _, now in
                now.roost == "glass" && now.standing && ChatReading.near(now.frame, topo.frame)
            }
            let placed = { (now: ChatReading.Topo, label: String) in try self.assertOnTheGlass(now, label) }
            let up = try ride(app, "\(transcript): on the short glass", rising: true, there: risen, back: rested, placed: placed)
            try assertOnTheGlass(up, "\(transcript), keyboard up")
            XCTAssertLessThan(try XCTUnwrap(up.box).minY, try XCTUnwrap(topo.box).minY, "he did not ride the pane up")
            ChatReading.attach(app, "glass-\(transcript)-keyboard", to: self)
            let down = try ride(app, "\(transcript): back on the resting glass", rising: false, there: rested, back: risen,
                                placed: placed)
            try assertOnTheGlass(down, "\(transcript), keyboard down")
            app.terminate()
        }
    }

    /// Pinned: over an empty chat and a full one, his box's centre is the pin, a fraction of the
    /// transcript's frame carried to the pane's foot; with the keyboard up he is lifted clear of it,
    /// and with it gone he is back at the pin. The pin this device keeps is the same throughout.
    func testPinnedHeStandsAtThePinAndTheKeyboardOnlyLiftsHimWhileItIsUp() throws {
        let pin = [0.3, 0.8]
        for transcript in ["empty", "full", "continuity"] {
            let app = ChatReading.launch(transcript: transcript,
                                         tuning: #"{"mascot": {"placement": "pinned", "pin": {"x": 0.3, "y": 0.8}}}"#,
                                         softwareKeyboard: true)
            XCTAssertTrue(ChatReading.microphone(app).waitForExistence(timeout: 60), "\(transcript): the chat screen")
            let (chat, topo) = try ChatReading.wait(app, "\(transcript): at the pin") { _, topo in
                topo.roost == "pinned" && topo.standing
            }
            XCTAssertEqual(chat.overridePin, pin)
            try assertAtThePin(topo, pin, transcript)
            try assertFirstDrawnWhereHeStands(topo, transcript)
            XCTAssertEqual(chat.facing, "left", "\(transcript): his centre is left of the middle")
            ChatReading.attach(app, "pinned-\(transcript)", to: self)

            ChatReading.raiseKeyboard(app)
            let keyboard = app.keyboards.element.frame
            let mic = ChatReading.microphone(app)
            let (_, lifted) = try ChatReading.wait(app, "\(transcript): lifted clear of the keyboard") { _, now in
                guard now.standing, let box = now.box, let offset = ChatReading.offset(now, mic: mic) else { return false }
                return box.maxY + offset.dy <= keyboard.minY
            }
            XCTAssertEqual(try XCTUnwrap(lifted.box).midX, try XCTUnwrap(topo.box).midX, accuracy: 0.5)
            XCTAssertEqual(ChatReading.chat(app)?.overridePin, pin, "\(transcript): the keyboard rewrote the pin")
            ChatReading.attach(app, "pinned-\(transcript)-keyboard", to: self)

            ChatReading.lowerKeyboard(app)
            let (after, back) = try ChatReading.wait(app, "\(transcript): back at the pin", timeout: 30) { _, now in
                now.standing && ChatReading.near(now.frame, topo.frame)
            }
            XCTAssertEqual(after.overridePin, pin, "\(transcript): the keyboard rewrote the pin")
            XCTAssertEqual(back.pin, pin)
            app.terminate()
        }
    }

    /// Roaming is what main does: over an empty chat he stands in a gap, clear of the glass.
    func testRoamingIsTheDefault() throws {
        let app = ChatReading.launch(transcript: "empty", tuning: "")
        XCTAssertTrue(ChatReading.microphone(app).waitForExistence(timeout: 60))
        let (chat, topo) = try ChatReading.wait(app, "roaming in a gap") { _, topo in topo.roost == "gap" && topo.standing }
        XCTAssertEqual(chat.placement, "roam")
        XCTAssertNil(chat.overridePlacement)
        let box = try XCTUnwrap(topo.box), pane = try XCTUnwrap(topo.paneRect)
        XCTAssertLessThanOrEqual(box.maxY, pane.minY + 0.5, "roaming on the glass: \(topo)")
        app.terminate()
    }

    /// A long press on him and a drag pins him where the finger lets go: the report says a drag
    /// began and he is pinned, and the override this device keeps holds the pin. A relaunch finds
    /// him there; the keyboard raised and dismissed leaves the kept pin as it was and him back at it.
    func testALongPressAndADragPinHimAndThePinOutlivesARelaunch() throws {
        let app = ChatReading.launch(transcript: "empty", tuning: "", softwareKeyboard: true)
        let mic = ChatReading.microphone(app)
        XCTAssertTrue(mic.waitForExistence(timeout: 60))
        let (_, start) = try ChatReading.wait(app, "roaming in a gap") { _, topo in topo.roost == "gap" && topo.standing }
        let offset = try XCTUnwrap(ChatReading.offset(start, mic: mic))
        let box = try XCTUnwrap(start.box)
        let from = CGPoint(x: box.midX + offset.dx, y: box.midY + offset.dy)
        let to = CGPoint(x: 110, y: 300)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: from.x, dy: from.y))
            .press(forDuration: 1.2, thenDragTo: origin.withOffset(CGVector(dx: to.x, dy: to.y)))
        let (chat, dropped) = try ChatReading.wait(app, "pinned where the drag let go") { chat, topo in
            topo.roost == "pinned" && topo.standing && chat.overridePlacement == "pinned"
        }
        XCTAssertEqual(dropped.drags, 1, "the report does not say a drag began: \(dropped)")
        let placed = try XCTUnwrap(dropped.box)
        XCTAssertEqual(placed.midX + offset.dx, to.x, accuracy: 3, "not where the finger let go: \(dropped)")
        XCTAssertEqual(placed.midY + offset.dy, to.y, accuracy: 3, "not where the finger let go: \(dropped)")
        let pin = try XCTUnwrap(chat.overridePin)
        XCTAssertEqual(chat.placement, "pinned")
        XCTAssertEqual(chat.pin, pin, "the chat does not wear the pin it kept")
        ChatReading.attach(app, "dragged", to: self)
        app.terminate()

        // A relaunch that sets nothing: the kept pin is where he stands.
        let again = ChatReading.launch(transcript: "empty", tuning: nil, softwareKeyboard: true)
        XCTAssertTrue(ChatReading.microphone(again).waitForExistence(timeout: 60))
        let (relaunched, there) = try ChatReading.wait(again, "at the kept pin after a relaunch") { _, topo in
            topo.roost == "pinned" && topo.standing
        }
        XCTAssertEqual(relaunched.overridePin, pin)
        XCTAssertTrue(ChatReading.near(there.frame, dropped.frame), "not where he was left: \(there) against \(dropped)")

        ChatReading.raiseKeyboard(again)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(ChatReading.chat(again)?.overridePin, pin, "the keyboard rewrote the pin")
        ChatReading.lowerKeyboard(again)
        let (after, _) = try ChatReading.wait(again, "back at the pin", timeout: 30) { _, now in
            now.standing && ChatReading.near(now.frame, dropped.frame)
        }
        XCTAssertEqual(after.overridePin, pin, "the keyboard rewrote the pin")
        again.terminate()
    }

    /// A scroll that starts on him scrolls the transcript and begins no drag: the finger moves
    /// before the press would pick him up.
    func testAScrollStartingOnHimScrolls() throws {
        let app = ChatReading.launch(transcript: "full",
                                     tuning: #"{"mascot": {"placement": "pinned", "pin": {"x": 0.5, "y": 0.45}}}"#)
        let mic = ChatReading.microphone(app)
        XCTAssertTrue(mic.waitForExistence(timeout: 60))
        let (_, topo) = try ChatReading.wait(app, "at the pin") { _, topo in topo.roost == "pinned" && topo.standing }
        let offset = try XCTUnwrap(ChatReading.offset(topo, mic: mic))
        let box = try XCTUnwrap(topo.box)
        // Where the transcript's content ends, which a scroll moves.
        let before = try XCTUnwrap(ChatReading.chat(app)?.contentBottom, "the chat reports no scroll")
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: box.midX + offset.dx, dy: box.midY + offset.dy))
        // Up the screen: the fixture is drawn from its top, so there is room to scroll that way.
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -250)))
        let deadline = Date().addingTimeInterval(5)
        var moved = ChatReading.chat(app)?.contentBottom ?? before
        while abs(moved - before) < 20, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            moved = ChatReading.chat(app)?.contentBottom ?? before
        }
        XCTAssertGreaterThan(abs(moved - before), 20, "the transcript did not scroll: \(before) → \(moved)")
        let after = try XCTUnwrap(ChatReading.chat(app)?.mascot)
        XCTAssertEqual(after.drags, 0, "a scroll began a drag: \(after)")
        XCTAssertEqual(after.placement, "pinned")
        XCTAssertEqual(ChatReading.chat(app)?.overridePin, [0.5, 0.45], "the scroll moved the pin")
        app.terminate()
    }

    // MARK: Helpers

    /// On the glass: the engine's shelf — 68 art pixels below his box's top at a scale of 1 — on
    /// the pane's top edge, his box at the leading end, clear of the well.
    private func assertOnTheGlass(_ topo: ChatReading.Topo, _ label: String,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let box = try XCTUnwrap(topo.box, file: file, line: line)
        let pane = try XCTUnwrap(topo.paneRect, file: file, line: line)
        XCTAssertEqual(box.minY + 68, pane.minY, accuracy: 0.5, "\(label): not on the pane's top edge: \(topo)", file: file, line: line)
        let visible = try XCTUnwrap(topo.visibleRect, file: file, line: line)
        XCTAssertLessThan(box.midX, pane.midX, "\(label): not over the pane's leading end: \(topo)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(box.minX, visible.minX - 0.5, "\(label): past the screen's leading edge: \(topo)", file: file, line: line)
        XCTAssertLessThanOrEqual(box.maxX, pane.maxX + 0.5, "\(label): off the pane: \(topo)", file: file, line: line)
    }

    /// At the pin: his box's centre a fraction of the frame across and down, to a point.
    private func assertAtThePin(_ topo: ChatReading.Topo, _ pin: [Double], _ label: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let box = try XCTUnwrap(topo.box, file: file, line: line)
        let frame = try XCTUnwrap(topo.pinFrame, file: file, line: line)
        XCTAssertEqual(box.midX, frame.minX + pin[0] * frame.width, accuracy: 1, "\(label): \(topo)", file: file, line: line)
        XCTAssertEqual(box.midY, frame.minY + pin[1] * frame.height, accuracy: 1, "\(label): \(topo)", file: file, line: line)
    }

    /// The first frame he was drawn at since the launch is the one he stands in, and no glide ever
    /// began: a placed Topo is put where the look places him once the chat is laid out, at once,
    /// and never walks there. The report's history reaches back to its first report, so nothing
    /// drawn before it is missed.
    private func assertFirstDrawnWhereHeStands(_ topo: ChatReading.Topo, _ label: String,
                                               file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(topo.recent.first?.sequence, 1, "\(label): the report's history does not reach its first report", file: file, line: line)
        let first = try XCTUnwrap(topo.recent.first { !$0.hidden && $0.frame != nil }, "\(label): never drawn", file: file, line: line)
        XCTAssertTrue(ChatReading.near(first.frame, topo.frame),
                      "\(label): first drawn at \(first.frame ?? []), and stands at \(topo.frame ?? [])", file: file, line: line)
        XCTAssertEqual(topo.moves, 0, "\(label): a glide began before he stood where he was placed", file: file, line: line)
        XCTAssertFalse(topo.recent.contains { !$0.hidden && !ChatReading.near($0.frame, topo.frame) },
                       "\(label): drawn somewhere else first: \(topo.recent.map { $0.frame ?? [] })", file: file, line: line)
    }

    /// The keyboard moved up (`rising`) or down until he stands `there`, and what the glass drew on
    /// the way judged (`Carry.judge`), only from the samples drawn since this move began. A move
    /// the trail caught nothing informative of — a starved simulator's display link can fire
    /// once or not at all in the keyboard's third of a second — is no verdict either way: the
    /// keyboard is taken back until he stands `back`, that move judged too, and the move made
    /// again, five moves in all. A sample that disagrees fails at once, on any of them, and where
    /// he stands is `placed`'s to hold at the end of every move, so a move that leaves him wrong
    /// fails whether or not its carry was sampled.
    private func ride(_ app: XCUIApplication, _ what: String, rising: Bool,
                      there: (ChatReading.Chat, ChatReading.Topo) -> Bool,
                      back: (ChatReading.Chat, ChatReading.Topo) -> Bool,
                      placed: (ChatReading.Topo, String) throws -> Void) throws -> ChatReading.Topo {
        let cues = 5
        var sampled: [String] = []
        for cue in 1...cues {
            let (now, unridden) = try move(app, "\(what), cue \(cue)", rising: rising, until: there, placed: placed)
            guard let unridden else {
                print("\(what): rode on cue \(cue)")
                return now
            }
            sampled.append("cue \(cue): \(unridden)")
            if cue < cues { _ = try move(app, "\(what), back for cue \(cue + 1)", rising: !rising, until: back, placed: placed) }
        }
        let message = "\(what): no frame of the carry sampled in \(cues) cues; \(sampled.joined(separator: "; "))"
        XCTFail(message)
        throw ChatReading.NotThere(description: message)
    }

    /// One move of the keyboard: waits for him to stand where it leaves him, then for the run it
    /// drew to be complete, and judges the run; where he stands is held at rest before the move,
    /// on his arrival, and again on the report judged. Nil for a ride; for no verdict, what the move sampled
    /// (`Carry.sampled`); a run he did not ride fails, and so does his not getting there. A run
    /// not complete within five seconds of his arrival is no verdict.
    private func move(_ app: XCUIApplication, _ what: String, rising: Bool,
                      until there: (ChatReading.Chat, ChatReading.Topo) -> Bool,
                      placed: (ChatReading.Topo, String) throws -> Void) throws -> (ChatReading.Topo, String?) {
        let before = try ChatReading.wait(app, "\(what): at rest before the move") { _, now in
            now.standing && !(now.trail.last?.moving ?? false)
        }.1
        try placed(before, "\(what), before the move")
        let since = before.trail.last?.t ?? -.infinity
        if rising { ChatReading.raiseKeyboard(app) } else { ChatReading.lowerKeyboard(app) }
        let (_, arrived) = try ChatReading.wait(app, what) { chat, now in there(chat, now) }
        try placed(arrived, what)
        // The run is complete at the first still frame after the slide, one tick after it ends.
        let complete = ChatReading.poll(app, timeout: 5) { chat, now in
            there(chat, now) && Carry.judge(now.trail, since: since, rising: rising) != .incomplete
        }?.1
        // The report judged is the last one read, and where he stands is held on it too: he may
        // have moved since he arrived.
        let now = try complete ?? XCTUnwrap(ChatReading.chat(app)?.mascot, "\(what): no report after arriving")
        try placed(now, "\(what), at the end")
        switch Carry.judge(now.trail, since: since, rising: rising) {
        case .rode: return (now, nil)
        case .incomplete, .noVerdict: return (now, Carry.sampled(now.trail, since: since, rising: rising))
        case let .off(message):
            XCTFail("\(what): \(message)")
            throw ChatReading.NotThere(description: message)
        }
    }
}

/// What the glass drew of one move of the keyboard, judged. Frame by frame through a run the
/// keyboard carried, he is as far along his way as the keyboard is along its own: both go by
/// the keyboard's one curve, the pane riding it and he riding the pane. A Topo put at his end at
/// once, or left at his start, is a whole run apart from the keyboard — but only at a sample well
/// inside the run: at 98% of the keyboard's way, a Topo already at his end is within the
/// tolerance, so a run whose every moving sample is that near one end or the other says nothing.
enum Carry: Equatable {
    /// No run the keyboard carried yet: the still frame before, every moving frame, and the
    /// still frame after, with the keyboard's edge having moved more than 100 points.
    case incomplete
    /// A run whose moving samples all agree, none of them informative.
    case noVerdict
    case rode([ChatReading.Topo.Drawn])
    case off(String)

    /// How far he may be from the keyboard's progress at a moving sample, as a share of the way.
    /// Across 720 frames sampled on a simulator, idle and starved, he was never more than 0.0017
    /// off it, so this is some seventeen times that; the smaller it is, the more of the slide a
    /// sample informs from, which is what a starved display link needs.
    static let tolerance = 0.03
    /// Whether a sample `along` the keyboard's way tells a ride from a jump: more than the
    /// tolerance from either end, so a Topo left at his start and one put at his end both fail it.
    static func informs(_ along: Double) -> Bool { along > tolerance && along < 1 - tolerance }

    /// Every run drawn since the clock read `since` — the trail's last sample before the move, so
    /// a run from an earlier move is never judged as this one's. One run off fails the move
    /// whatever the others did, and a ride needs every run ridden: each with a sample that informs.
    static func judge(_ trail: [ChatReading.Topo.Drawn], since: Double, rising: Bool) -> Carry {
        let runs = carried(trail.filter { $0.t >= since }, rising: rising)
        guard !runs.isEmpty else { return .incomplete }
        var told = true
        for run in runs {
            guard let first = run.first, let last = run.last else { continue }
            let keyboard = last.keyboard - first.keyboard, him = last.top - first.top
            guard abs(him) > 20 else { return .off("he did not move with the pane: \(run)") }
            var this = false
            for sample in run.dropFirst().dropLast() {
                let along = (sample.keyboard - first.keyboard) / keyboard
                let his = (sample.top - first.top) / him
                guard abs(his - along) <= tolerance else {
                    return .off("at \(sample) he is \(Int(his * 100))% of his way and the keyboard \(Int(along * 100))%: \(run)")
                }
                if informs(along) { this = true }
            }
            told = told && this
        }
        return told ? .rode(runs.flatMap { $0 }) : .noVerdict
    }

    /// What a move drew of the keyboard's way, for a failure to show: each moving frame since
    /// `since` as `him/keyboard` percentages of the way, the first twenty of them. Starvation
    /// reads as few frames or none mid-slide; drift, as the two apart.
    static func sampled(_ trail: [ChatReading.Topo.Drawn], since: Double, rising: Bool) -> String {
        let trail = trail.filter { $0.t >= since }
        let runs = carried(trail, rising: rising)
        guard !runs.isEmpty else { return "incomplete, \(trail.filter(\.moving).count) moving frames" }
        // Only a run `judge` has not already failed reaches here, so he moved more than 20 points.
        let shares = runs.flatMap { run -> [String] in
            guard let first = run.first, let last = run.last else { return [] }
            let keyboard = last.keyboard - first.keyboard, him = last.top - first.top
            return run.filter(\.moving).map { sample in
                "\(Int(((sample.top - first.top) / him * 100).rounded()))/\(Int(((sample.keyboard - first.keyboard) / keyboard * 100).rounded()))"
            }
        }
        let more = shares.count > 20 ? " and \(shares.count - 20) more" : ""
        return "[\(shares.prefix(20).joined(separator: " "))\(more)]"
    }

    /// Every run of frames the keyboard carried up (`rising`) or down: the still frame before it,
    /// every moving frame, and the still frame after. Empty until one such run is complete.
    static func carried(_ trail: [ChatReading.Topo.Drawn], rising: Bool) -> [[ChatReading.Topo.Drawn]] {
        var runs: [[ChatReading.Topo.Drawn]] = []
        var run: [ChatReading.Topo.Drawn] = []
        for sample in trail {
            if sample.moving {
                run.append(sample)
            } else if run.contains(where: \.moving) {
                run.append(sample)
                runs.append(run)
                run = [sample]
            } else {
                run = [sample]
            }
        }
        return runs.filter { run in
            guard let first = run.first, let last = run.last, !first.moving, !last.moving, run.count >= 3 else { return false }
            return rising ? last.keyboard < first.keyboard - 100 : last.keyboard > first.keyboard + 100
        }
    }
}

/// `Carry.judge` against trails written by hand: the verdicts a starved simulator's sparse samples
/// must and must not give, which no run on a fast one is sure to reach. Launches nothing.
final class CarryJudgeTests: XCTestCase {
    private typealias Drawn = ChatReading.Topo.Drawn

    /// The keyboard rising from the foot at 874 to 539, him from 617 to 342, each sample `(keyboard
    /// along, him along)` as shares of the way, at clock `from` on.
    private func rise(_ moving: [(Double, Double)], from start: Double = 1) -> [Drawn] {
        let still = Drawn(t: start, top: 617, keyboard: 874, moving: false)
        let samples = moving.enumerated().map { index, share in
            Drawn(t: start + 0.1 * Double(index + 1), top: 617 - 275 * share.1, keyboard: 874 - 335 * share.0, moving: true)
        }
        let end = Drawn(t: start + 0.1 * Double(moving.count + 1), top: 342, keyboard: 539, moving: false)
        return [still] + samples + [end]
    }

    /// The keyboard falling back to the foot, him from 342 to 617: the same verdicts the other way.
    private func fall(_ moving: [(Double, Double)]) -> [Drawn] {
        rise(moving).map { Drawn(t: $0.t, top: 959 - $0.top, keyboard: 1413 - $0.keyboard, moving: $0.moving) }
    }

    func testAFallIsJudgedTheSameWay() {
        guard case .rode = Carry.judge(fall([(0.5, 0.5)]), since: 0, rising: false) else { return XCTFail("a fall ridden is not a ride") }
        guard case .off = Carry.judge(fall([(0.5, 1)]), since: 0, rising: false) else { return XCTFail("a fall jumped passed") }
        XCTAssertEqual(Carry.judge(fall([(0.98, 1)]), since: 0, rising: false), .noVerdict)
        XCTAssertEqual(Carry.judge(fall([(0.5, 0.5)]), since: 0, rising: true), .incomplete, "a fall read as a rise")
    }

    func testARideSampledMidwayIsARide() {
        guard case .rode = Carry.judge(rise([(0.5, 0.5)]), since: 0, rising: true) else { return XCTFail("not a ride") }
    }

    func testAJumpSampledMidwayIsOff() {
        guard case .off = Carry.judge(rise([(0.5, 1)]), since: 0, rising: true) else { return XCTFail("a jump passed") }
        guard case .off = Carry.judge(rise([(0.5, 0)]), since: 0, rising: true) else { return XCTFail("staying put passed") }
    }

    /// At 98% of the keyboard's way a Topo already at his end is within the tolerance: that sample
    /// cannot tell the two apart, so it is no verdict and never a ride.
    func testALoneSampleNearAnEndIsNoVerdict() {
        XCTAssertEqual(Carry.judge(rise([(0.98, 1)]), since: 0, rising: true), .noVerdict)
        XCTAssertEqual(Carry.judge(rise([(0.02, 0)]), since: 0, rising: true), .noVerdict)
        XCTAssertEqual(Carry.judge(rise([(0.98, 1), (0.99, 1)]), since: 0, rising: true), .noVerdict)
    }

    /// Informative from the tolerance in: a jump sampled at 96% is caught, and so is a Topo
    /// left at his start at 4%.
    func testTheInformativeSpanIsWhereAJumpFails() {
        guard case .off = Carry.judge(rise([(0.96, 1)]), since: 0, rising: true) else { return XCTFail("a jump at 96% passed") }
        guard case .off = Carry.judge(rise([(0.04, 0)]), since: 0, rising: true) else { return XCTFail("staying put at 4% passed") }
        XCTAssertFalse(Carry.informs(Carry.tolerance))
        XCTAssertFalse(Carry.informs(1 - Carry.tolerance))
    }

    func testNoMovingSampleIsIncomplete() {
        XCTAssertEqual(Carry.judge(rise([]), since: 0, rising: true), .incomplete)
        XCTAssertEqual(Carry.judge([], since: 0, rising: true), .incomplete)
        XCTAssertEqual(Carry.judge(Array(rise([(0.5, 0.5)]).dropLast()), since: 0, rising: true), .incomplete)
    }

    /// A ride from an earlier move is not this one's: only the samples since the move began count.
    func testAnEarlierMovesRideIsNotThisOnes() {
        let earlier = rise([(0.5, 0.5)], from: 1)
        let now = rise([(0.98, 1)], from: 5)
        XCTAssertEqual(Carry.judge(earlier + now, since: 5, rising: true), .noVerdict)
        XCTAssertEqual(Carry.judge(earlier, since: 5, rising: true), .incomplete)
    }

    /// What a move sampled reads as each moving frame's shares, him then keyboard.
    func testWhatAMoveSampledReadsAsShares() {
        XCTAssertEqual(Carry.sampled(rise([(0.98, 1), (0.99, 1)]), since: 0, rising: true), "[100/98 100/99]")
        XCTAssertEqual(Carry.sampled(rise(Array(repeating: (0.5, 0.5), count: 25)), since: 0, rising: true),
                       "[" + Array(repeating: "50/50", count: 20).joined(separator: " ") + " and 5 more]")
        XCTAssertEqual(Carry.sampled(Array(rise([(0.5, 0.5)]).dropLast()), since: 0, rising: true), "incomplete, 1 moving frames")
    }

    /// Two runs in one move: the first off, the second ridden. The move fails on the first.
    func testARunOffFailsTheMoveWhateverRunsAfterIt() {
        let off = rise([(0.5, 1)], from: 1), ridden = rise([(0.5, 0.5)], from: 2)
        guard case .off = Carry.judge(off + ridden, since: 0, rising: true) else { return XCTFail("a run off was passed over") }
        guard case .off = Carry.judge(ridden + off, since: 0, rising: true) else { return XCTFail("a run off was passed over") }
        XCTAssertEqual(Carry.judge(rise([(0.98, 1)], from: 1) + ridden, since: 0, rising: true), .noVerdict, "a run not ridden was passed over")
        guard case .rode = Carry.judge(rise([(0.4, 0.4)], from: 1) + ridden, since: 0, rising: true) else { return XCTFail("two runs ridden are not a ride") }
    }

    /// Any sample that disagrees fails, however many agree.
    func testOneSampleOffIsOff() {
        guard case .off = Carry.judge(rise([(0.3, 0.3), (0.6, 0.95), (0.9, 0.9)]), since: 0, rising: true) else {
            return XCTFail("a disagreeing sample passed")
        }
    }
}
