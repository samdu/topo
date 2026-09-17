import AVFoundation
import XCTest

/// The microphone, pressed. Nothing else in the suite touches it: the client tests exercise
/// objects and `scripts/simulator-run.sh` sends a typed turn, and a press is a gesture on the
/// running app, which only an XCUITest makes. After a tap, a hold and a release the test holds
/// that the app is still running and back at rest, that each press reached `VoiceInput`, which
/// branch the press took, and what the microphone delivered: buffers counted inside the input
/// tap after the engine started, and on the on-device branch the samples that reached the
/// sink. All of it is read from the button's debug-only accessibility value, a JSON
/// `VoiceInput.Report`, decoded strictly. A crash on the press is an app that is no longer
/// running, whatever the cause: an Objective-C exception out of `installTap`, or a runtime trap.
///
/// Every success records what the press did (the microphone ran, or was refused and why) as an
/// activity with the report attached, so the result bundle says what was tested. A host with no
/// audio input cannot run the microphone at all: the press is refused at `VoiceInput`'s input
/// guard, before the tap, and the test ends in `XCTSkip` naming the coverage that is missing,
/// never in a pass. Any other refusal fails.
///
/// The first press is also where the permission prompts are counted, and the count is a running
/// total across this class's tests, which share one process. The microphone is the only
/// permission Topo asks for, so one press in the run raises one alert and every press after it
/// raises none. On a lane that cleared the app's grants (`TOPO_UITEST_PRIVACY_RESET=1`) each test
/// that pressed holds the total is exactly one, so a reset that did not happen fails as loudly as
/// a permission that should not be asked for; elsewhere it holds at most one. Every alert
/// answered has to carry the microphone usage description.
///
/// The lane is declared by the test runner's environment (`TEST_RUNNER_`-prefixed on the
/// `xcodebuild` command line):
///
/// - `TOPO_UITEST_AUDIO_INPUT=1`: the host has an audio input (CI's loopback device). A refused
///   hold is then a failure, not a skip.
/// - `TOPO_UITEST_EAR_MODELS=<dir>`: Parakeet's model directories, for the test in which the
///   real recogniser hears `purple-elephants.wav` through the simulator's microphone. The lane
///   plays the fixture on a loop into the host's input (CI: `afplay` into the loopback device);
///   the simulator's own output does not reach a host loopback, so the runner cannot play it.
///
/// The app is launched signed in with a placeholder token (`DebugRun.signIn` takes it from the
/// environment) and past the first-run question, which is the chat screen with its microphone,
/// and with `TOPO_DEBUG_KEEP_SPOKEN`, so what a press hears is never sent and the token never
/// reaches the API. The permission prompt of a fresh simulator is answered through SpringBoard.
@MainActor
final class MicrophonePressTests: XCTestCase {
    /// The words spoken in `purple-elephants.wav`.
    static let phrase = ["purple", "elephants", "juggle", "seven", "lanterns"]
    /// `INFOPLIST_KEY_NSMicrophoneUsageDescription` in `project.yml`, which is the body of the
    /// one alert a first press raises.
    static let microphoneUsage = "Topo listens when you press the microphone"

    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    private var laneHasInput: Bool { environment["TOPO_UITEST_AUDIO_INPUT"] == "1" }
    /// True on a lane that cleared the app's privacy grants before the suite, where the number of
    /// prompts a run raises is exact rather than a ceiling.
    private var laneResetPrivacy: Bool { environment["TOPO_UITEST_PRIVACY_RESET"] == "1" }
    /// Every permission alert this run has answered, across the class's tests: the runner keeps
    /// one process for them, and the grant one test gives stands for the rest.
    private static var promptsAnswered: [String] = []

    override func setUp() {
        continueAfterFailure = false
    }

    /// The on-device branch over `TOPO_DEBUG_EAR=stub`: an ear resident without a model, so the
    /// tap, the sample sink, the caption loop and the release's decode all run, over an engine
    /// that returns no words.
    func testAPressOnTheStubEarDeliversAudioToTheSink() throws {
        let app = launch(environment: ["TOPO_DEBUG_EAR": "stub"])
        try tapHoldAndRelease(app, branch: .stubEar)
    }

    /// A press the ear cannot hear, over `TOPO_DEBUG_EAR=loading`: an ear whose load never
    /// finishes, so it is never resident. The refusal comes before the audio session and before
    /// the input guard, so this test runs on every host, one with no microphone included.
    func testAPressWhileTheEarIsNotResidentIsRefusedWithItsReason() throws {
        let app = launch(environment: ["TOPO_DEBUG_EAR": "loading"])
        let mic = microphone(in: app)
        XCTAssertTrue(mic.waitForExistence(timeout: 60), "the chat screen, with its microphone")
        let before = try waitForReport(app, timeout: 30, "the ear is loading") { $0.ear == "loading" }

        // The first press meets the microphone prompt, and its release while the prompt is up
        // starts nothing; answer it, then hold for real.
        mic.press(forDuration: 0.5)
        answerOnePrompt()
        XCTAssertEqual(app.state, .runningForeground, "the app survived the permission prompt")

        mic.press(forDuration: 1.5)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3), "the app survived the hold")
        let after = try waitForReport(app, timeout: 30, "the hold reached VoiceInput") { $0.refusal != nil }
        XCTAssertEqual(after.refusal, "loading", "the refusal is the ear's own words: \(after.raw)")
        XCTAssertEqual(after.sessions, before.sessions, "a refused hold opened no session: \(after.raw)")
        XCTAssertEqual(after.capture, Capture(), "a refused hold delivered nothing: \(after.raw)")
        XCTAssertEqual(app.state, .runningForeground)
        record("the ear is not resident; the press was refused: \(after.refusal ?? "")", after)
    }

    /// The whole path: fixture audio looping on the host's input, captured by the simulator's
    /// microphone, converted by the sink, and recognised by Parakeet as the fixture's words. The
    /// hold is two loops and a second long, so it spans at least one whole phrase wherever in
    /// the loop it starts.
    func testParakeetHearsTheFixtureThroughTheMicrophone() throws {
        guard let models = environment["TOPO_UITEST_EAR_MODELS"], !models.isEmpty else {
            throw XCTSkip("missing coverage: no Parakeet models on this lane (TOPO_UITEST_EAR_MODELS), so no recogniser turned microphone audio into words")
        }
        let app = launch(environment: ["TOPO_DEBUG_EAR": models])
        let loop = try fixtureDuration()
        let report = try tapHoldAndRelease(app, branch: .parakeet, hold: 2 * loop + 1)
        XCTAssertGreaterThan(report.capture.tapRMS, 0.005, "the fixture's energy reached the input tap, not silence: \(report.raw)")
        XCTAssertGreaterThan(report.capture.sinkRMS, 0.005, "the fixture's energy reached the sink: \(report.raw)")
        let heard = Self.words(report.capture.heard)
        record("recognised: \"\(report.capture.heard)\"", report)
        for word in Self.phrase {
            XCTAssertTrue(heard.contains(word), "Parakeet heard \"\(word)\" in the fixture: \(report.raw)")
        }
    }

    // MARK: - The press

    enum Branch: String {
        case stubEar = "the ear (stub engine)"
        case parakeet = "the ear (Parakeet)"
    }

    private func launch(environment: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOPO_CLAUDE_SETUP_TOKEN"] = "ui-test-placeholder"
        app.launchEnvironment["TOPO_DEBUG_KEEP_SPOKEN"] = "1"
        // This lane presses the microphone and speaks nothing, so the voice is held at loading
        // and asks for none of its 351 MB. What reads a reply aloud is the talk lane's to prove.
        app.launchEnvironment["TOPO_DEBUG_VOICE"] = "loading"
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launchArguments += ["-firstRunAnswered", "YES"]
        app.launch()
        return app
    }

    /// The button in any of its states. Its label is `VoiceInput`'s state in words.
    private func microphone(in app: XCUIApplication) -> XCUIElement {
        app.images.matching(NSPredicate(format: "label == 'Hold to talk' OR label BEGINSWITH 'Listening'")).firstMatch
    }

    @discardableResult
    private func tapHoldAndRelease(_ app: XCUIApplication, branch: Branch, hold: TimeInterval = 1.5) throws -> Report {
        let mic = microphone(in: app)
        XCTAssertTrue(mic.waitForExistence(timeout: 60), "the chat screen, with its microphone")

        // The ear the launch asked for is resident before the first press, or the press would
        // be refused for want of one.
        switch branch {
        case .stubEar:
            try waitForReport(app, timeout: 30, "the stub ear is resident") { $0.ear == "ready" }
        case .parakeet:
            try waitForReport(app, timeout: 600, "Parakeet is resident") { $0.ear == "ready" || $0.ear == "failed" }
            XCTAssertEqual(try report(app).ear, "ready", "Parakeet loaded from the models directory")
        }

        // The first press on a fresh simulator meets the microphone prompt, and its release
        // while it is up starts nothing (`VoiceInput.pressUp` during `starting`). On a simulator
        // that has answered it, the press opens the microphone, and a press whose release lands
        // inside the tap limit leaves it open hands-free: close it.
        mic.press(forDuration: 0.5)
        answerOnePrompt()
        XCTAssertEqual(app.state, .runningForeground, "the app survived the permission prompt")
        closeHandsFree(app, mic)
        XCTAssertTrue(app.images["Hold to talk"].waitForExistence(timeout: 15), "the button is at rest before the tap")

        // A tap. Released before the microphone is running it starts nothing, by design
        // (`VoiceInput.pressUp` during `starting`); if it did open the microphone hands-free, the
        // next press closes it. Either way the tap is a press `VoiceInput.begin` handled.
        let beforeTap = try report(app)
        mic.press(forDuration: 0.1)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3), "the app survived the tap")
        try waitForReport(app, timeout: 15, "the tap reached VoiceInput") { $0.presses == beforeTap.presses + 1 }
        closeHandsFree(app, mic)
        XCTAssertTrue(app.images["Hold to talk"].waitForExistence(timeout: 15), "the button is at rest before the hold")
        let before = try report(app)

        // A hold, longer than the start and past the tap limit, then the release.
        mic.press(forDuration: hold)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3), "the app survived the hold")
        XCTAssertTrue(app.images["Hold to talk"].waitForExistence(timeout: 60), "the session ended and the button is back to rest")
        let after = try waitForReport(app, timeout: 60, "the hold reached VoiceInput") { $0.presses == before.presses + 1 }
        XCTAssertEqual(app.state, .runningForeground)

        if let refusal = after.refusal {
            // Refused before the tap: the session count stands still and nothing was delivered.
            // A host may lack an audio input; any other refusal is a fault on the press.
            XCTAssertEqual(after.sessions, before.sessions, "a refused hold opened no session: \(after.raw)")
            XCTAssertEqual(after.capture, Capture(), "a refused hold delivered nothing: \(after.raw)")
            record("\(branch.rawValue); microphone refused: \(refusal)", after)
            guard refusal == "no audio input" else {
                XCTFail("the hold was refused for a reason that is a fault: \(after.raw)")
                return after
            }
            if laneHasInput {
                XCTFail("this lane declares an audio input (TOPO_UITEST_AUDIO_INPUT=1), and the hold was refused for want of one: \(after.raw)")
            }
            throw XCTSkip("missing coverage: this host has no audio input, so the press over \(branch.rawValue) was refused at the input guard; the tap, the buffers, the sink and the decode did not run")
        }

        // The microphone ran: one new session, and audio counted inside the tap.
        XCTAssertEqual(after.sessions, before.sessions + 1, "the hold's session ran its microphone: \(after.raw)")
        let capture = after.capture
        XCTAssertGreaterThan(capture.buffers, 0, "buffers reached the input tap: \(after.raw)")
        XCTAssertGreaterThan(capture.rate, 0, "the tap's buffers had a sample rate: \(after.raw)")
        let seconds = Double(capture.frames) / max(capture.rate, 1)
        XCTAssertGreaterThan(seconds, 0.5, "the tap was fed for most of the hold, not a buffer or two: \(after.raw)")
        let expected = Double(capture.frames) * 16_000 / max(capture.rate, 1)
        XCTAssertEqual(Double(capture.sunk), expected, accuracy: max(expected * 0.1, 2_048),
                       "the sink holds what the tap delivered, at the ear's rate: \(after.raw)")
        record(String(format: "%@; microphone ran: %d buffers, %.2f s at %.0f Hz, tap RMS %.4f, %d samples sunk, ended by %@%@, heard \"%@\"",
                      branch.rawValue, capture.buffers, seconds, capture.rate, capture.tapRMS, capture.sunk, capture.ended,
                      capture.recogniserError.map { " (\($0))" } ?? "", capture.heard), after)
        return after
    }

    // MARK: - The report

    /// `VoiceInput.Report`, as the button's accessibility value carries it. Counts are unsigned,
    /// so a negative one fails the decode rather than reading as a number.
    struct Report: Decodable {
        var presses: UInt
        var sessions: UInt
        var refusal: String?
        var ear: String
        var capture: Capture
        var raw = ""

        enum CodingKeys: String, CodingKey { case presses, sessions, refusal, ear, capture }
    }

    struct Capture: Decodable, Equatable {
        var buffers: UInt = 0
        var frames: UInt = 0
        var rate = 0.0
        var tapRMS = 0.0
        var sunk: UInt = 0
        var sinkRMS = 0.0
        var heard = ""
        var ended = ""
        var recogniserError: String?
    }

    /// The report, strictly: a value that is not a whole `Report` throws, and the test fails.
    private func report(_ app: XCUIApplication) throws -> Report {
        let raw = microphone(in: app).value as? String ?? ""
        return try Self.decode(raw)
    }

    static func decode(_ raw: String) throws -> Report {
        do {
            var report = try JSONDecoder().decode(Report.self, from: Data(raw.utf8))
            report.raw = raw
            return report
        } catch {
            throw MalformedReport(raw: raw, error: "\(error)")
        }
    }

    struct MalformedReport: Error, CustomStringConvertible {
        var raw: String
        var error: String
        var description: String { "the microphone's accessibility value is not a report: \"\(raw)\" (\(error))" }
    }

    /// Polls the report until `condition` holds; fails the test with the last report if it does not.
    @discardableResult
    private func waitForReport(_ app: XCUIApplication, timeout: TimeInterval, _ what: String,
                               until condition: (Report) -> Bool) throws -> Report {
        let deadline = Date().addingTimeInterval(timeout)
        var last = try report(app)
        while !condition(last), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            last = try report(app)
        }
        XCTAssertTrue(condition(last), "\(what): \(last.raw)")
        return last
    }

    /// The branch this press took and what it delivered, as an activity in the log and the
    /// result bundle, with the report attached.
    private func record(_ summary: String, _ report: Report) {
        XCTContext.runActivity(named: "branch: \(summary)") { activity in
            let attachment = XCTAttachment(string: report.raw)
            attachment.name = "microphone report"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        print("[microphone] \(summary) — \(report.raw)")
    }

    /// A press whose release landed inside the tap limit left the microphone open until the
    /// next press; that press closes it.
    private func closeHandsFree(_ app: XCUIApplication, _ mic: XCUIElement) {
        guard app.images["Listening; press to send"].waitForExistence(timeout: 3) else { return }
        mic.press(forDuration: 0.1)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3), "the app survived closing the hands-free session")
    }

    /// The fixture's length, from the copy in this bundle, which is the file the lane loops.
    private func fixtureDuration() throws -> TimeInterval {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "purple-elephants", withExtension: "wav"),
                                "purple-elephants.wav is in the UI test bundle")
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Lowercased words, punctuation dropped, digits spelled for the fixture's one number.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { $0 == "7" ? "seven" : $0 }
    }

    /// Answers the permission prompts a first press raises, and holds that there is at most one
    /// of them and that it is the microphone's. On a simulator whose grants the lane cleared
    /// there is exactly one; on a later test in the same run, none, the grant already given. A
    /// second prompt is a permission Topo asks for and should not.
    private func answerOnePrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var answered: [String] = []
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 5) else { break }
            let text = ([alert.label] + alert.staticTexts.allElementsBoundByIndex.map(\.label))
                .filter { !$0.isEmpty }.joined(separator: " — ")
            let allow = alert.buttons.matching(NSPredicate(format: "label IN {'Allow', 'OK'}")).firstMatch
            guard allow.waitForExistence(timeout: 3) else { break }
            allow.tap()
            answered.append(text)
        }
        Self.promptsAnswered += answered
        let total = Self.promptsAnswered
        XCTContext.runActivity(named: "permission prompts: \(answered.count) here, \(total.count) in this run") { _ in }
        if laneResetPrivacy {
            XCTAssertEqual(total.count, 1,
                           "this lane cleared the app's grants (TOPO_UITEST_PRIVACY_RESET=1), so one press in the run raises the microphone prompt and nothing raises another: \(total)")
        } else {
            XCTAssertLessThanOrEqual(total.count, 1, "a press asks for one permission: \(total)")
        }
        for prompt in total {
            XCTAssertTrue(prompt.contains(Self.microphoneUsage),
                          "the only prompt a press raises is the microphone's: \(prompt)")
        }
    }
}
