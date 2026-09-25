import XCTest

/// Topo over the chat takes nothing from the microphone: wherever a transcript puts him — in a
/// gap beside its turns, or nowhere when it leaves none — a press on the well, in its middle and
/// at its trailing edge, reaches `VoiceInput`, counted in the button's debug report. The glass is
/// never his, keyboard up or down.
///
/// This is the one place a touch is delivered, and it is the press proof only. SwiftUI puts no
/// view of its own under a gesture, so a UIKit hit test cannot tell the microphone from empty glass;
/// a press through the system is what says the gesture got it. That he is never drawn over the
/// well is `MascotGeometryTests`', from geometry: a Topo drawn over the jewel with hit testing off
/// would let every press here through.
///
/// The transcript is a fixture (`TOPO_DEBUG_TRANSCRIPT`), so his roost does not depend on what
/// the account's log holds, and where he stands is read off the badge's debug report
/// (`DebugRun.ChatReport.mascot`) before the press. The ear is held loading, so no press opens
/// anything. A press is counted before it asks for the microphone. The class sorts after
/// `MicrophonePressTests`, so in the suite that class meets the one prompt a cleared lane raises
/// and counts it, and none is left here; run alone, this answers the prompt itself.
///
/// The same holds under the keyboard, where the glass is short and the well with it: a press at
/// the short well's edge is delivered and counted too.
final class TopoOnTheGlassTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// A full transcript and an empty one, each with him where it puts him, photographed as he
    /// stands, then pressed.
    func testAPressOnTheWellReachesTheMicrophoneWhereverHeStands() throws {
        for (transcript, roost) in Self.roosts {
            let app = launch(look: "{}", transcript: transcript)
            let mic = app.images.matching(NSPredicate(format: "label IN %@", Self.labels)).firstMatch
            XCTAssertTrue(mic.waitForExistence(timeout: 60), "\(transcript): the chat screen, with its microphone")
            let standing = try waitForTopo(in: app, "\(transcript): standing in the \(roost)") {
                $0.roost == roost && $0.hidden == (roost == "none") && !$0.walking && $0.frame == $0.to
            }
            assertOffTheGlass(standing, transcript)
            attach(app, "topo-\(transcript)-\(roost)")
            for point in ["the well's middle", "the well's trailing edge"] {
                let before = try report(mic)
                let frame = mic.frame
                let x = point == "the well's middle" ? frame.midX : frame.maxX - 2
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: frame.midY))
                    .press(forDuration: 0.2)
                let deadline = Date().addingTimeInterval(15)
                var after = try report(mic)
                while after.presses != before.presses + 1, Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                    after = try report(mic)
                }
                XCTAssertEqual(after.presses, before.presses + 1,
                               "\(transcript): a press on \(point) did not reach the microphone: \(after.raw)")
                // A prompt the press raised, run alone on a cleared lane, is allowed.
                let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
                if alert.waitForExistence(timeout: 2) {
                    alert.buttons.matching(NSPredicate(format: "label IN {'Allow', 'OK'}")).firstMatch.tap()
                }
            }
            app.terminate()
        }
    }

    /// Under the keyboard the glass is short and the microphone two thirds of its size, and a
    /// press at the short well's edge still reaches `VoiceInput`: the gesture is on the well as
    /// drawn, not as it rests. The keyboard is raised by the flank that raises it, and the press
    /// is delivered through the system, counted in the button's debug report. The keyboard comes
    /// up over where Topo stood in the empty chat, so he is placed in room above it: it is held
    /// that he moved and ended clear, photographed there.
    func testAPressAtTheShortWellsEdgeReachesTheMicrophoneUnderTheKeyboard() throws {
        let app = launch(look: "{}", transcript: "empty", softwareKeyboard: true)
        let mic = app.images.matching(NSPredicate(format: "label IN %@", Self.labels)).firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 60), "the chat screen, with its microphone")
        let resting = mic.frame
        let placed = try waitForTopo(in: app, "standing in a gap of the empty chat") {
            $0.roost == "gap" && !$0.hidden && !$0.walking && $0.frame == $0.to
        }

        let flank = app.buttons["Type instead"]
        XCTAssertTrue(flank.waitForExistence(timeout: 10), "the keyboard flank")
        // A simulator's own account alert arriving late takes the first tap; the flank is tapped
        // again for it, never more than three times.
        for _ in 0..<3 where !app.keyboards.element.exists {
            flank.tap()
            if app.keyboards.element.waitForExistence(timeout: 5) { break }
            dismissAccountAlert()
        }
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 10), "the flank raised no keyboard")
        let deadline = Date().addingTimeInterval(10)
        var short = mic.frame
        while abs(short.width - resting.width * 2 / 3) > 1, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            short = mic.frame
        }
        XCTAssertEqual(short.width, resting.width * 2 / 3, accuracy: 1,
                       "under the keyboard the microphone is not two thirds of its size: \(resting) → \(short)")
        XCTAssertEqual(short.height, resting.height * 2 / 3, accuracy: 1)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "glass-under-the-keyboard"
        shot.lifetime = .keepAlways
        add(shot)
        // The keyboard takes the room he stood in, and he is placed in room above it: standing
        // still, in a gap and with nothing over it, the keyboard included.
        let now = try waitForTopo(in: app, "out from under the keyboard") {
            $0.roost == "gap" && !$0.hidden && !$0.walking && !$0.covered
                && $0.frame == $0.to && $0.frame != placed.frame
        }
        XCTAssertNotEqual(now.frame, placed.frame, "the keyboard came up over him and he did not move: \(now)")
        attach(app, "topo-keyboard-up")

        let before = try report(mic)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: short.maxX - 2, dy: short.midY))
            .press(forDuration: 0.2)
        let pressDeadline = Date().addingTimeInterval(15)
        var after = try report(mic)
        while after.presses != before.presses + 1, Date() < pressDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            after = try report(mic)
        }
        XCTAssertEqual(after.presses, before.presses + 1,
                       "a press at the short well's edge did not reach the microphone: \(after.raw)")
        XCTAssertEqual(mic.frame.width, short.width, accuracy: 1, "the press was not on the short well")
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.waitForExistence(timeout: 2) {
            alert.buttons.matching(NSPredicate(format: "label IN {'Allow', 'OK'}")).firstMatch.tap()
        }
        app.terminate()
    }

    /// Over `continuity`, the layout of Sam's screenshot, with the keyboard up the short glass is
    /// as off limits as the tall one: every report from the keyboard rising to his standing still
    /// has his picture clear of the pane — above its top edge, or not drawn. Every report, and not
    /// only the ones a poll happens to read: each carries the ones before it (`recent`) under a
    /// sequence, and the test holds the sequence has no gap.
    func testWithTheKeyboardUpOverAFullChatHeIsNeverOnTheGlass() throws {
        let app = launch(look: "{}", transcript: "continuity", softwareKeyboard: true)
        let mic = app.images.matching(NSPredicate(format: "label IN %@", Self.labels)).firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 60), "the chat screen, with its microphone")
        let resting = try waitForTopo(in: app, "settled over the full chat") {
            $0.roost != "" && !$0.walking && $0.frame == $0.to && $0.pane != nil
        }
        assertOffTheGlass(resting, "before the keyboard")
        let flank = app.buttons["Type instead"]
        XCTAssertTrue(flank.waitForExistence(timeout: 10), "the keyboard flank")
        for _ in 0..<3 where !app.keyboards.element.exists {
            flank.tap()
            if app.keyboards.element.waitForExistence(timeout: 5) { break }
            dismissAccountAlert()
        }
        let keyboard = app.keyboards.element
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "the flank raised no keyboard")
        // Every report for five seconds as the keyboard rises and he settles, then the one he
        // settles on under the short glass: none has him over the pane.
        let restingPane = try XCTUnwrap(resting.pane)
        var glimpses: [Int: Topo.Glimpse] = [:]
        for glimpse in resting.recent { glimpses[glimpse.sequence] = glimpse }
        let watch = Date().addingTimeInterval(5)
        while Date() < watch {
            if let seen = topo(in: app) {
                for glimpse in seen.recent { glimpses[glimpse.sequence] = glimpse }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let up = try waitForTopo(in: app, "settled over the short glass") {
            guard let pane = $0.pane else { return false }
            return !$0.walking && $0.frame == $0.to && pane[3] < restingPane[3] - 1
        }
        assertOffTheGlass(up, "with the keyboard up")
        for glimpse in up.recent { glimpses[glimpse.sequence] = glimpse }
        let sequences = glimpses.keys.sorted()
        let first = try XCTUnwrap(sequences.first), last = try XCTUnwrap(sequences.last)
        XCTAssertEqual(sequences, Array(first...last), "reports were missed between reads")
        XCTAssertGreaterThanOrEqual(last, up.sequence, "the last report read is not in the record")
        XCTAssertGreaterThan(sequences.count, 1, "the keyboard rising changed nothing he reported")
        for sequence in sequences {
            let glimpse = glimpses[sequence]!
            assertOffTheGlass(Topo(roost: "", frame: glimpse.frame, to: nil, hidden: glimpse.hidden, pane: glimpse.pane),
                              "report \(sequence)")
        }
        attach(app, "topo-keyboard-up-full-chat")
        app.terminate()
    }

    /// He faces the half of the screen he stands on, as the chat's debug report says the roost
    /// decided it (`DebugRun.ChatReport.facing`, `Mascot.facing`): read off the chat itself, so the
    /// roost's decision reaching `Mascot` through the overlay is what is held. `continuity`, a full
    /// chat, puts him in the margin beside the last reply on the right, facing right; so does an
    /// empty chat, whose first roost is the transcript's bottom trailing corner; `left`, the
    /// person's turns only with room beside one narrow bubble, puts him on the left half, facing
    /// as drawn. Each is held against where his frame is: right of the screen's middle or left of it.
    func testHeFacesTheHalfOfTheScreenHeStandsOn() throws {
        for (transcript, facing) in [("continuity", "right"), ("empty", "right"), ("left", "left")] {
            let app = launch(look: "{}", transcript: transcript)
            let standing = try waitForTopo(in: app, "\(transcript): standing in a gap") {
                $0.roost == "gap" && !$0.hidden && !$0.walking && $0.frame == $0.to
            }
            let frame = try XCTUnwrap(standing.frame)
            let centre = frame[0] + frame[2] / 2, middle = Double(app.frame.width) / 2
            XCTAssertEqual(centre > middle, facing == "right",
                           "\(transcript): he stands at \(centre) against the middle \(middle): \(standing)")
            // The facing is handed to `Mascot` off the view update the roost is decided in.
            let deadline = Date().addingTimeInterval(5)
            var seen = self.facing(in: app)
            while seen != facing, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                seen = self.facing(in: app)
            }
            XCTAssertEqual(seen, facing, "\(transcript): \(standing)")
            attach(app, "topo-\(transcript)-facing-\(facing)")
            app.terminate()
        }
    }

    /// The well keeps its press under a placed Topo: with him on the glass beside it, and pinned
    /// over it, a tap and a hold long enough to have been a drag each reach `VoiceInput` — the press
    /// and its release both counted — and no drag began. The pin over the well is worked out from
    /// where the chat reports the well, a fraction of the transcript's frame carried to the pane's
    /// foot, and kept as a drag would keep it (`TOPO_DEBUG_TUNING`), which the test clears after.
    func testThroughAPlacedTopoThePressIsTheMicrophones() throws {
        addTeardownBlock { ChatReading.launch(transcript: "empty", tuning: "").terminate() }
        let beside = ChatReading.launch(transcript: "empty", tuning: #"{"mascot": {"placement": "glass"}}"#)
        XCTAssertTrue(ChatReading.microphone(beside).waitForExistence(timeout: 60), "the chat screen")
        let (_, glass) = try ChatReading.wait(beside, "on the glass beside the well") { _, topo in
            topo.roost == "glass" && topo.standing
        }
        attach(beside, "topo-glass-beside-the-well")
        try pressThrough(beside, "beside the well on the glass")
        beside.terminate()

        let well = try XCTUnwrap(glass.wellRect), frame = try XCTUnwrap(glass.pinFrame)
        let x = (well.midX - frame.minX) / frame.width, y = (well.midY - frame.minY) / frame.height
        let over = ChatReading.launch(transcript: "full",
                                      tuning: #"{"mascot": {"placement": "pinned", "pin": {"x": \#(x), "y": \#(y)}}}"#)
        XCTAssertTrue(ChatReading.microphone(over).waitForExistence(timeout: 60), "the chat screen")
        let (_, pinned) = try ChatReading.wait(over, "pinned over the well") { _, topo in
            topo.roost == "pinned" && topo.standing
        }
        let box = try XCTUnwrap(pinned.box), drawnWell = try XCTUnwrap(pinned.wellRect)
        XCTAssertTrue(box.contains(CGPoint(x: drawnWell.midX, y: drawnWell.midY)), "not over the well's middle: \(pinned)")
        attach(over, "topo-pinned-over-the-well")
        try pressThrough(over, "pinned over the well")
        over.terminate()
    }

    /// A tap on the well's middle and a hold there past the time that picks him up, each counted as
    /// a press and a release by the microphone, with no drag begun.
    private func pressThrough(_ app: XCUIApplication, _ label: String) throws {
        let mic = ChatReading.microphone(app)
        for (press, duration) in [("a tap", 0.1), ("a hold", 1.5)] {
            let before = try XCTUnwrap(ChatReading.mic(mic), "\(label): no report on the microphone")
            let frame = mic.frame
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY))
                .press(forDuration: duration)
            let deadline = Date().addingTimeInterval(15)
            var after = ChatReading.mic(mic)
            while (after?.presses != before.presses + 1 || after?.releases != before.releases + 1), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                after = ChatReading.mic(mic)
            }
            XCTAssertEqual(after?.presses, before.presses + 1, "\(label): \(press) on the well was not the microphone's press")
            XCTAssertEqual(after?.releases, before.releases + 1, "\(label): \(press) on the well was not the microphone's release")
            let topo = try XCTUnwrap(ChatReading.chat(app)?.mascot)
            XCTAssertEqual(topo.drags, 0, "\(label): \(press) on the well began a drag: \(topo)")
            XCTAssertFalse(topo.dragging, "\(label): \(press) on the well picked him up")
            ChatReading.answerPrompt()
        }
    }

    /// Where each transcript puts him at the default look.
    static let roosts = [("full", "gap"), ("empty", "gap")]

    /// His picture, as he read it, is clear of the pane, as he read it: above its top edge, or not
    /// drawn at all.
    private func assertOffTheGlass(_ seen: Topo, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let frame = seen.frame else {
            XCTAssertTrue(seen.hidden, "\(label): a frame of nothing, drawn: \(seen)", file: file, line: line)
            return
        }
        guard let pane = seen.pane else { return XCTFail("\(label): no pane in the report: \(seen)", file: file, line: line) }
        XCTAssertFalse(seen.hidden, "\(label): \(seen)", file: file, line: line)
        XCTAssertLessThanOrEqual(frame[1] + frame[3], pane[1] + 0.5, "\(label): over the glass: \(seen)",
                                 file: file, line: line)
    }

    /// The button's three labels, `VoiceInput`'s state in words.
    static let labels = ["Hold to talk", "Listening; release to send", "Listening; press to send"]

    /// `softwareKeyboard` asks for the keyboard a phone has (`TOPO_DEBUG_SOFTWARE_KEYBOARD`): a
    /// simulator starts with the Mac's keyboard connected, under which nothing rises and the
    /// glass, which goes short on the keyboard's own safe area, stays as it is. `transcript` is the
    /// fixture the chat draws (`TOPO_DEBUG_TRANSCRIPT`).
    private func launch(look: String, transcript: String, softwareKeyboard: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        if softwareKeyboard { app.launchEnvironment["TOPO_DEBUG_SOFTWARE_KEYBOARD"] = "1" }
        app.launchEnvironment["TOPO_CLAUDE_SETUP_TOKEN"] = "ui-test-placeholder"
        app.launchEnvironment["TOPO_DEBUG_KEEP_SPOKEN"] = "1"
        app.launchEnvironment["TOPO_DEBUG_EAR"] = "loading"
        app.launchEnvironment["TOPO_DEBUG_VOICE"] = "loading"
        app.launchEnvironment["TOPO_DEBUG_OUTBOX"] = ""
        app.launchEnvironment["TOPO_DEBUG_LOOK"] = look
        app.launchEnvironment["TOPO_DEBUG_TRANSCRIPT"] = transcript
        // No placement or pin kept from an earlier run: he roams.
        app.launchEnvironment["TOPO_DEBUG_TUNING"] = ""
        app.launchArguments += ["-firstRunAnswered", "YES"]
        app.launch()
        dismissAccountAlert()
        return app
    }

    /// A simulator signed into iCloud can ask for the account's password over the app, which puts
    /// the scene out of the foreground and stops him; it is the simulator's alert and not Topo's,
    /// so it is put away.
    private func dismissAccountAlert() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts["Apple Account Verification"]
        if alert.waitForExistence(timeout: 3) { alert.buttons["Not Now"].tap() }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Where Topo stands, off the badge's debug report.
    struct Topo: Decodable, CustomStringConvertible {
        var roost = ""
        var frame: [Double]?
        var to: [Double]?
        var hidden = true
        var walking = false
        var covered = false
        var moves = 0
        var pane: [Double]?
        var sequence = 0
        var recent: [Glimpse] = []

        struct Glimpse: Decodable {
            var sequence: Int
            var frame: [Double]?
            var pane: [Double]?
            var hidden: Bool
        }

        var description: String {
            "\(roost) at \(frame ?? []) to \(to ?? []) hidden \(hidden) walking \(walking) covered \(covered) moves \(moves) pane \(pane ?? [])"
        }
    }

    private struct ChatReport: Decodable {
        var mascot: Topo?
        var facing: String?
    }
    private struct TopoNotThere: Error { var message: String }

    private func topo(in app: XCUIApplication) -> Topo? {
        let raw = app.buttons["topo-debug-chat"].value as? String ?? ""
        return (try? JSONDecoder().decode(ChatReport.self, from: Data(raw.utf8)))?.mascot
    }

    /// Which way the chat's debug report says he faces.
    private func facing(in app: XCUIApplication) -> String? {
        let raw = app.buttons["topo-debug-chat"].value as? String ?? ""
        return (try? JSONDecoder().decode(ChatReport.self, from: Data(raw.utf8)))?.facing
    }

    /// Waits for him to be as `wanted` says, and fails the test, naming what he was instead, when
    /// he is not by the deadline.
    private func waitForTopo(in app: XCUIApplication, _ what: String, timeout: TimeInterval = 20,
                             _ wanted: (Topo) -> Bool) throws -> Topo {
        let deadline = Date().addingTimeInterval(timeout)
        var seen = topo(in: app)
        // The simulator's account alert can arrive at any point of a run and puts the scene out
        // of the foreground, which stops him; it is put away whenever it is up.
        let accountAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts["Apple Account Verification"]
        while seen.map(wanted) != true, Date() < deadline {
            if accountAlert.exists { accountAlert.buttons["Not Now"].tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            seen = topo(in: app)
        }
        guard let seen, wanted(seen) else {
            let message = "Topo was not \(what) in \(timeout) s: \(seen.map(String.init(describing:)) ?? "never reported")"
            XCTFail(message)
            throw TopoNotThere(message: message)
        }
        return seen
    }

    private struct Report: Decodable {
        var presses: UInt
        var raw = ""
        enum CodingKeys: String, CodingKey { case presses }
    }

    private func report(_ mic: XCUIElement) throws -> Report {
        let raw = mic.value as? String ?? ""
        var report = try JSONDecoder().decode(Report.self, from: Data(raw.utf8))
        report.raw = raw
        return report
    }
}
