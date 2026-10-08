import TopoTurn
import XCTest

@testable import Topo

/// What the bar's two controls stand on: what a model is called, and whether replies are read.
@MainActor
final class ChatBarTests: XCTestCase {
    /// What the bar's menu and the notice call a model is the look's name for it, and the family's
    /// where the look names none; a document sets one name without touching the others, and one
    /// it refuses costs that name alone.
    func testAModelIsCalledWhatTheLookCallsIt() {
        XCTAssertEqual(ClaudeModel.allCases.map { Look.Mind().name($0.rawValue) }, ClaudeModel.allCases.map(\.displayName))
        XCTAssertNil(Look.Mind().name(ClaudeModel.haiku.rawValue))
        let reading = LookDocument.read(#"{"mind": {"sonnet": "  Sonnet 5.5 ", "opus": "", "fable": 7}}"#)
        XCTAssertEqual(reading.look.mind.sonnet, "Sonnet 5.5")
        XCTAssertEqual(reading.look.mind.opus, "Opus")
        XCTAssertEqual(reading.look.mind.fable, "Fable")
        XCTAssertEqual(reading.notes.count, 2, "\(reading.notes)")
        for refused in [String(repeating: "m", count: Look.Mind.longest + 1), "two\nlines", "   "] {
            let data = try! JSONSerialization.data(withJSONObject: ["mind": ["opus": refused]])
            let read = LookDocument.read(String(data: data, encoding: .utf8))
            XCTAssertEqual(read.look.mind.opus, "Opus", refused.debugDescription)
            XCTAssertEqual(read.notes.count, 1, refused.debugDescription)
        }
    }

    /// Read aloud until somebody mutes: a phone never asked reads replies.
    func testRepliesAreReadAloudUntilMuted() throws {
        let name = "mute-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(Mute.readsAloud(defaults))
        defaults.set(false, forKey: Mute.key)
        XCTAssertFalse(Mute.readsAloud(defaults))
        defaults.set(true, forKey: Mute.key)
        XCTAssertTrue(Mute.readsAloud(defaults))
    }

    /// The chat's debug report carries the model the bar set apart from the model a request
    /// carries for it, which in a debug build is the pin whatever was set.
    func testTheReportCarriesTheModelSetApartFromTheModelAsked() throws {
        for model in ClaudeModel.allCases {
            let raw = DebugRun.chatReport(spoken: nil, turns: [], error: nil, speaker: Speaker.Report(), voice: .ready, model: model)
            let report = try JSONDecoder().decode(DebugRun.ChatReport.self, from: Data(raw.utf8))
            XCTAssertEqual(report.model, model.rawValue)
            XCTAssertEqual(report.effectiveModel, ClaudeModel.effective(model).rawValue)
            XCTAssertEqual(report.effectiveModel, ClaudeModel.haiku.rawValue, "a debug build asks \(model) unpinned")
        }
    }
}
