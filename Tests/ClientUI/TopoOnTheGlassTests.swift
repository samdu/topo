import XCTest

/// Topo on the glass takes nothing from the microphone: at every end of the ranges `look.json`
/// accepts for his size, offset and stroll, a press on the well — in its middle, and at the edge
/// nearest him — reaches `VoiceInput`, counted in the button's debug report.
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
    /// `LookDocument`'s ends for his fields, in every combination, and the default.
    static var extremes: [[String: Any]] {
        var all: [[String: Any]] = [[:]]
        for scale in [0.25, 4] {
            for x in [-4000, 4000] {
                for y in [0, 200] {
                    for stroll in [0, 4000] {
                        all.append(["scale": scale, "offset": ["width": x, "height": y], "stroll": stroll])
                    }
                }
            }
        }
        return all
    }

    override func setUp() {
        continueAfterFailure = false
    }

    func testAPressOnTheWellReachesTheMicrophoneAtEveryExtreme() throws {
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
