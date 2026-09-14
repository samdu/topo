import AVFoundation
import XCTest

/// A spoken question, answered aloud, end to end: `capital-of-france.wav` looping into the
/// simulator's microphone, the hold on the chat screen's microphone, Parakeet hearing it, the
/// words sent as a spoken turn through the ordinary harness (the lease, the CloudKit log, the
/// Messages API, Haiku in a debug build), the reply landing in the log as that turn's child, and
/// the speaker reading that reply to its end.
///
/// Nothing is stubbed and nothing is skipped: every prerequisite missing is a failure naming it.
/// They come from the test runner's environment (`TEST_RUNNER_`-prefixed on the `xcodebuild`
/// command line, which is what `scripts/simulator-run.sh --talk` does):
///
/// - `TOPO_TALK_SETUP_TOKEN`: a Claude Code setup token, handed to the app's launch environment
///   and nowhere else.
/// - `TOPO_UITEST_EAR_MODELS`: a directory `scripts/fetch-ear-models.sh` filled.
/// - a loopback lane playing the fixture into the host's default input, and an iCloud account on
///   the simulator; neither is declared, and both fail by name when absent (a refused press, an
///   error line on the chat screen).
///
/// Everything read is debug-only accessibility values, decoded strictly: the microphone's
/// `VoiceInput.Report` and the chat title's `DebugRun.ChatReport`.
@MainActor
final class SpokenTurnTests: XCTestCase {
    /// The words spoken in `capital-of-france.wav`.
    static let question = ["what", "is", "the", "capital", "of", "france", "answer", "in", "one", "word"]
    static let answer = "paris"

    override func setUp() {
        continueAfterFailure = false
    }

    func testASpokenQuestionIsAnsweredAloud() throws {
        let environment = ProcessInfo.processInfo.environment
        let token = try XCTUnwrap(environment["TOPO_TALK_SETUP_TOKEN"].flatMap { $0.isEmpty ? nil : $0 },
                                  "a Claude setup token in TEST_RUNNER_TOPO_TALK_SETUP_TOKEN")
        let models = try XCTUnwrap(environment["TOPO_UITEST_EAR_MODELS"].flatMap { $0.isEmpty ? nil : $0 },
                                   "Parakeet's models in TEST_RUNNER_TOPO_UITEST_EAR_MODELS")

        let app = XCUIApplication()
        app.launchEnvironment["TOPO_CLAUDE_SETUP_TOKEN"] = token
        app.launchEnvironment["TOPO_DEBUG_EAR"] = models
        // Past the first-run question, replies read aloud whatever this simulator was left set
        // to, and no line left waiting by an earlier launch riding ahead of the question.
        app.launchArguments += ["-firstRunAnswered", "YES", "-readAloud", "YES", "-topo.harness.outbox", ""]
        app.launch()

        let mic = app.images.matching(NSPredicate(format: "label == 'Hold to talk' OR label BEGINSWITH 'Listening'")).firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 60), "the chat screen, with its microphone")
        let title = app.descendants(matching: .any)[Self.chatReportIdentifier]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the chat title carries its report")
        XCTAssertNil(try chat(app).spoken, "no turn spoken before the press")

        try waitFor(timeout: 600, "Parakeet is resident", { try self.voice(app) }) { $0.ear == "ready" || $0.ear == "failed" }
        XCTAssertEqual(try voice(app).ear, "ready", "Parakeet loaded from \(models)")

        // The hold spans two loops and a second, so a whole question is in it wherever the loop
        // starts. On a simulator that has not answered the microphone and speech prompts, the
        // first hold is released while they are up and starts nothing; answer them and hold again.
        let hold = 2 * (try fixtureDuration()) + 1
        var before = try voice(app)
        var after = try holdAndRelease(app, mic, hold: hold, after: before)
        if after.sessions == before.sessions, after.refusal == nil {
            record("the first hold met the permission prompts and started nothing", after.raw)
            before = after
            after = try holdAndRelease(app, mic, hold: hold, after: before)
        }
        if let refusal = after.refusal {
            XCTFail("the hold was refused (\(refusal)); this test needs a loopback lane playing the question into the host's default input: \(after.raw)")
        }
        XCTAssertEqual(after.sessions, before.sessions + 1, "the hold ran the microphone: \(after.raw)")
        XCTAssertEqual(after.recogniser, "parakeet", "Parakeet heard the hold: \(after.raw)")
        let heard = after.capture.heard.trimmingCharacters(in: .whitespacesAndNewlines)
        record("heard: \"\(heard)\"", after.raw)
        let words = Self.words(heard)
        for word in Self.question {
            XCTAssertTrue(words.contains(word), "Parakeet heard \"\(word)\" in the question: \(after.raw)")
        }

        // The spoken turn and its reply, found by the nonce the chat sent it under.
        let answered = try waitFor(timeout: 240, "the spoken turn was answered", { try self.chat(app) }) {
            $0.reply != nil || ($0.error != nil && $0.spoken != nil)
        }
        let person = try XCTUnwrap(answered.person, "the spoken turn is in the log: \(answered.raw)")
        let reply = try XCTUnwrap(answered.reply, "a reply to the spoken turn is in the log: \(answered.raw)")
        XCTAssertEqual(person.text, heard, "the turn is what Parakeet heard: \(answered.raw)")
        XCTAssertTrue(reply.parents.contains(person.ref), "the reply continues from the spoken turn: \(answered.raw)")
        record("turn \(person.ref): \"\(person.text)\"; reply \(reply.ref): \"\(reply.text)\"", answered.raw)
        XCTAssertTrue(reply.text.lowercased().contains(Self.answer), "the reply says \(Self.answer): \(answered.raw)")

        // The speaker read that reply, to its end.
        let spoken = try waitFor(timeout: 120, "the speaker finished the reply", { try self.chat(app) }) {
            $0.speaker.text == reply.text && $0.speaker.finished
        }
        XCTAssertEqual(spoken.speaker.text, reply.text, "the speaker was given the reply: \(spoken.raw)")
        XCTAssertTrue(spoken.speaker.started, "the speaker started the reply: \(spoken.raw)")
        XCTAssertTrue(spoken.speaker.finished, "the speaker finished the reply: \(spoken.raw)")
        record("spoken by \(spoken.speaker.engine.map(\.rawValue) ?? "nothing"), started and finished", spoken.raw)
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - The press

    private func holdAndRelease(_ app: XCUIApplication, _ mic: XCUIElement, hold: TimeInterval,
                                after before: VoiceReport) throws -> VoiceReport {
        mic.press(forDuration: hold)
        allowPrompts()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3), "the app survived the hold")
        XCTAssertTrue(app.images["Hold to talk"].waitForExistence(timeout: 60), "the button is back at rest")
        return try waitFor(timeout: 60, "the hold reached VoiceInput", { try self.voice(app) }) {
            $0.presses == before.presses + 1
        }
    }

    /// Taps through whatever permission prompts are up, microphone then speech.
    private func allowPrompts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN {'Allow', 'OK'}")).firstMatch
        for _ in 0..<2 where allow.waitForExistence(timeout: 3) {
            allow.tap()
        }
    }

    // MARK: - The reports

    static let chatReportIdentifier = "topo-debug-chat"

    /// `VoiceInput.Report`, the part of it this test reads.
    struct VoiceReport: Decodable {
        var presses: UInt
        var sessions: UInt
        var refusal: String?
        var ear: String
        var recogniser: String?
        var capture: Capture
        var raw = ""

        struct Capture: Decodable {
            var heard: String
        }

        enum CodingKeys: String, CodingKey { case presses, sessions, refusal, ear, recogniser, capture }
    }

    /// `DebugRun.ChatReport`.
    struct ChatReport: Decodable {
        var spoken: String?
        var person: TurnReport?
        var reply: TurnReport?
        var error: String?
        var speaker: SpeakerReport
        var raw = ""

        enum CodingKeys: String, CodingKey { case spoken, person, reply, error, speaker }
    }

    struct TurnReport: Decodable {
        var ref: String
        var parents: [String]
        var text: String
    }

    /// `Speaker.Report`.
    struct SpeakerReport: Decodable {
        enum Engine: String, Decodable { case pocket, system }
        var speaks: UInt
        var engine: Engine?
        var text: String
        var started: Bool
        var finished: Bool
    }

    private func voice(_ app: XCUIApplication) throws -> VoiceReport {
        let mic = app.images.matching(NSPredicate(format: "label == 'Hold to talk' OR label BEGINSWITH 'Listening'")).firstMatch
        var report: VoiceReport = try Self.decode(mic.value as? String ?? "", "the microphone")
        report.raw = mic.value as? String ?? ""
        return report
    }

    private func chat(_ app: XCUIApplication) throws -> ChatReport {
        let raw = app.descendants(matching: .any)[Self.chatReportIdentifier].value as? String ?? ""
        var report: ChatReport = try Self.decode(raw, "the chat title")
        report.raw = raw
        return report
    }

    static func decode<Report: Decodable>(_ raw: String, _ element: String) throws -> Report {
        do {
            return try JSONDecoder().decode(Report.self, from: Data(raw.utf8))
        } catch {
            throw MalformedReport(description: "\(element)'s accessibility value is not a report: \"\(raw)\" (\(error))")
        }
    }

    struct MalformedReport: Error, CustomStringConvertible {
        var description: String
    }

    /// Polls a report until `condition` holds; fails the test with the last one if it does not.
    @discardableResult
    private func waitFor<Report>(timeout: TimeInterval, _ what: String, _ read: () throws -> Report,
                                 until condition: (Report) -> Bool) throws -> Report {
        let deadline = Date().addingTimeInterval(timeout)
        var last = try read()
        while !condition(last), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            last = try read()
        }
        XCTAssertTrue(condition(last), "\(what): \(last)")
        return last
    }

    /// A step of the run, as an XCTest activity with the report attached, and in the log.
    private func record(_ summary: String, _ raw: String) {
        XCTContext.runActivity(named: summary) { activity in
            let attachment = XCTAttachment(string: raw)
            attachment.name = "report"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        print("[talk] \(summary) — \(raw)")
    }

    private func fixtureDuration() throws -> TimeInterval {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "capital-of-france", withExtension: "wav"),
                                "capital-of-france.wav is in the test bundle")
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Lowercased words, punctuation dropped, the question's one number spelled.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { $0 == "1" ? "one" : $0 }
    }
}
