import XCTest

/// Topo over the chat takes nothing from the microphone: with him sitting on the glass's trailing
/// flank, where a transcript with no gap in it leaves him, and with him standing in a gap away
/// from it, a press on the well — in its middle, and at the edge nearest the flank — reaches
/// `VoiceInput`, counted in the button's debug report.
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

    /// A transcript whose turns leave no gap puts him on the flank; an empty one leaves him in a
    /// gap over it. Each is photographed as he stands, then pressed.
    func testAPressOnTheWellReachesTheMicrophoneWithHimOnTheFlankAndAway() throws {
        for (transcript, roost) in [("full", "flank"), ("empty", "gap")] {
            let app = launch(look: "{}", transcript: transcript)
            let mic = app.images.matching(NSPredicate(format: "label IN %@", Self.labels)).firstMatch
            XCTAssertTrue(mic.waitForExistence(timeout: 60), "\(transcript): the chat screen, with its microphone")
            _ = try waitForTopo(in: app, "\(transcript): standing in the \(roost)") {
                $0.roost == roost && !$0.hidden && !$0.walking && $0.frame == $0.to
            }
            attach(app, "topo-\(transcript)-\(roost)")
            for point in ["the well's middle", "the well's edge nearest the flank"] {
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
    /// up over where Topo stood in the empty chat, so he glides to room above it:
    /// it is held that he moved and ended clear, photographed there.
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
        // The keyboard takes the room he stood in, and he hurries to room above it: a glide that
        // has ended, with his picture where he is now — not where he was going — in a gap and
        // with nothing over it, the keyboard included.
        let now = try waitForTopo(in: app, "out from under the keyboard") {
            $0.moves > placed.moves && $0.roost == "gap" && !$0.hidden && !$0.walking && !$0.covered
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

    /// A chat with no gap above the keyboard — `continuity`, the layout of Sam's screenshot — has
    /// him on the short glass's trailing flank once the keyboard is up, drawn and standing still,
    /// right of the microphone: the glass is shorter than he is, so he stands on its foot.
    func testWithTheKeyboardUpOverAFullChatHeStandsOnTheShortGlass() throws {
        let app = launch(look: "{}", transcript: "continuity", softwareKeyboard: true)
        let mic = app.images.matching(NSPredicate(format: "label IN %@", Self.labels)).firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 60), "the chat screen, with its microphone")
        _ = try waitForTopo(in: app, "on the flank of a chat with no gap") {
            $0.roost == "flank" && !$0.hidden && !$0.walking && $0.frame == $0.to
        }
        let flank = app.buttons["Type instead"]
        XCTAssertTrue(flank.waitForExistence(timeout: 10), "the keyboard flank")
        for _ in 0..<3 where !app.keyboards.element.exists {
            flank.tap()
            if app.keyboards.element.waitForExistence(timeout: 5) { break }
            dismissAccountAlert()
        }
        let keyboard = app.keyboards.element
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "the flank raised no keyboard")
        // The glass under the keyboard is shorter than he is, and he stands on its foot: his
        // picture's bottom edge is the pane's, both as he read them, in one space.
        let up = try waitForTopo(in: app, "on the short glass's foot") {
            guard $0.roost == "flank", !$0.hidden, !$0.walking, $0.frame == $0.to,
                  let frame = $0.frame, let pane = $0.pane else { return false }
            return pane[3] < frame[3] && abs((frame[1] + frame[3]) - (pane[1] + pane[3])) < 0.5
        }
        let frame = try XCTUnwrap(up.frame)
        let pane = try XCTUnwrap(up.pane)
        XCTAssertEqual(frame[1] + frame[3], pane[1] + pane[3], accuracy: 0.5, "not on the short glass's foot: \(up)")
        XCTAssertLessThan(frame[1], pane[1], "the glass is not shorter than he is: \(up)")
        XCTAssertGreaterThanOrEqual(frame[0], Double(mic.frame.maxX) - 0.5, "not right of the microphone: \(up)")
        attach(app, "topo-keyboard-up-full-chat")
        app.terminate()
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
        var description: String {
            "\(roost) at \(frame ?? []) to \(to ?? []) hidden \(hidden) walking \(walking) covered \(covered) moves \(moves) pane \(pane ?? [])"
        }
    }

    private struct ChatReport: Decodable { var mascot: Topo? }
    private struct TopoNotThere: Error { var message: String }

    private func topo(in app: XCUIApplication) -> Topo? {
        let raw = app.buttons["topo-debug-chat"].value as? String ?? ""
        return (try? JSONDecoder().decode(ChatReport.self, from: Data(raw.utf8)))?.mascot
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
