import XCTest

/// Topo on the glass takes nothing from the microphone: with him at home and with him as close to
/// the well as `look.json` can put him, a press on the well — in its middle, and at the edge
/// nearest him — reaches `VoiceInput`, counted in the button's debug report. Those three looks
/// are the only ones pressed. The other combinations of the ranges' ends are `MascotGeometryTests`',
/// which holds at every one that his canvas ends before the well and that a hit test does not
/// land on him; no test delivers a press at them.
///
/// This is the one place a touch is delivered. SwiftUI puts no view of its own under a gesture,
/// so a UIKit hit test lands on the hosting view wherever it is asked and cannot tell the
/// microphone from empty glass (`MascotGeometryTests` holds only that he is not what is hit);
/// a press through the system is what says the gesture got it.
///
/// The look arrives as `TOPO_DEBUG_LOOK`. The ear is held loading, so no press opens anything.
/// A press is counted before it asks for the microphone. The class sorts after
/// `MicrophonePressTests`, so in the suite that class meets the one prompt a cleared lane raises
/// and counts it, and none is left here; run alone, this answers the prompt itself.
final class TopoOnTheGlassTests: XCTestCase {
    /// The default, and the ends of `LookDocument`'s ranges that bring him nearest the
    /// microphone: the largest he is drawn, the furthest he strolls, pushed right toward the well,
    /// standing on the pane's top edge and down at its foot beside the jewel.
    static var extremes: [[String: Any]] { [
        [:],
        ["scale": 4, "offset": ["width": 4000, "height": 0], "stroll": 4000],
        ["scale": 4, "offset": ["width": 4000, "height": 200], "stroll": 4000],
    ] }

    override func setUp() {
        continueAfterFailure = false
    }

    func testAPressOnTheWellReachesTheMicrophoneWithHimNearestIt() throws {
        for mascot in Self.extremes {
            let look = String(decoding: try JSONSerialization.data(withJSONObject: ["mascot": mascot], options: [.sortedKeys]),
                              as: UTF8.self)
            var app: XCUIApplication?
            for point in ["the well's middle", "the well's edge nearest him"] {
                let running = app ?? launch(look: look)
                app = running
                let mic = running.images.matching(NSPredicate(format: "label IN %@", Self.labels)).firstMatch
                XCTAssertTrue(mic.waitForExistence(timeout: 60), "\(look): the chat screen, with its microphone")
                let before = try report(mic)
                let frame = mic.frame
                let x = point == "the well's middle" ? frame.midX : frame.minX + 2
                running.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: frame.midY))
                    .press(forDuration: 0.2)
                let deadline = Date().addingTimeInterval(15)
                var after = try report(mic)
                while after.presses != before.presses + 1, Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                    after = try report(mic)
                }
                XCTAssertEqual(after.presses, before.presses + 1, "\(look): a press on \(point) did not reach the microphone: \(after.raw)")
                // A prompt the press raised, run alone on a cleared lane, is allowed.
                let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
                if alert.waitForExistence(timeout: 2) {
                    alert.buttons.matching(NSPredicate(format: "label IN {'Allow', 'OK'}")).firstMatch.tap()
                }
            }
            app?.terminate()
        }
    }

    /// The button's three labels, `VoiceInput`'s state in words.
    static let labels = ["Hold to talk", "Listening; release to send", "Listening; press to send"]

    private func launch(look: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOPO_CLAUDE_SETUP_TOKEN"] = "ui-test-placeholder"
        app.launchEnvironment["TOPO_DEBUG_KEEP_SPOKEN"] = "1"
        app.launchEnvironment["TOPO_DEBUG_EAR"] = "loading"
        app.launchEnvironment["TOPO_DEBUG_VOICE"] = "loading"
        app.launchEnvironment["TOPO_DEBUG_OUTBOX"] = ""
        app.launchEnvironment["TOPO_DEBUG_LOOK"] = look
        app.launchArguments += ["-firstRunAnswered", "YES"]
        app.launch()
        return app
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
