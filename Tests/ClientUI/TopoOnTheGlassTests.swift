import XCTest

/// Topo over the chat takes nothing from the microphone: with him sitting on the glass's leading
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
            let placed = try waitForTopo(in: app) { $0.roost == roost && !$0.hidden }
            XCTAssertEqual(placed.roost, roost, "\(transcript): he is not where the transcript leaves him: \(placed)")
            attach(app, "topo-\(transcript)-\(roost)")
            for point in ["the well's middle", "the well's edge nearest the flank"] {
                let before = try report(mic)
                let frame = mic.frame
                let x = point == "the well's middle" ? frame.midX : frame.minX + 2
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
        let placed = try waitForTopo(in: app) { $0.roost == "gap" && !$0.hidden }

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
        // The keyboard takes the room he stood in, and he strolls to room above it: one glide,
        // ending in a gap clear of the keyboard.
        let now = try waitForTopo(in: app) {
            $0.moves > placed.moves && $0.roost == "gap" && !$0.hidden && $0.frame != placed.frame
        }
        XCTAssertGreaterThan(now.moves, placed.moves, "the keyboard came up over him and he did not move: \(now)")
        XCTAssertEqual(now.roost, "gap", "\(now)")
        XCTAssertFalse(now.hidden, "\(now)")
        attach(app, "topo-keyboard-up")

        let before = try report(mic)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: short.minX + 2, dy: short.midY))
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
        var hidden = true
        var moves = 0
        var description: String { "\(roost) \(frame ?? []) hidden \(hidden) moves \(moves)" }
    }

    private struct ChatReport: Decodable { var mascot: Topo? }

    private func topo(in app: XCUIApplication) -> Topo? {
        let raw = app.buttons["topo-debug-chat"].value as? String ?? ""
        return (try? JSONDecoder().decode(ChatReport.self, from: Data(raw.utf8)))?.mascot
    }

    /// Waits for him to be placed as `wanted` says, answering whatever he is by the deadline.
    private func waitForTopo(in app: XCUIApplication, timeout: TimeInterval = 20,
                             _ wanted: (Topo) -> Bool) throws -> Topo {
        let deadline = Date().addingTimeInterval(timeout)
        var seen = topo(in: app)
        while seen.map(wanted) != true, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            seen = topo(in: app)
        }
        return try XCTUnwrap(seen, "Topo was never placed")
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
