import SwiftUI
import TopoTools
import XCTest

@testable import Topo

/// `topo look`: the mind's hand on this phone's look, through `Tuning`. Every value is judged by
/// `LookDocument`'s own reader before it is kept, a refusal changes nothing, what is kept is worn
/// at once and outlives a launch, and Reset — the sheet's or the tool's — takes it back.
@MainActor
final class LookToolTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "topo-looktool-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    /// The vault's look.json, and what it makes.
    private static let vaultDocument = #"{"transcript": {"replyTrailingInset": 80}}"#
    private var vault: Look { LookDocument.read(Self.vaultDocument).look }

    private func tool(_ tuning: Tuning, document: String = LookToolTests.vaultDocument) -> LookTool {
        let reading = LookDocument.read(document)
        return LookTool(vault: { (reading.look, reading) }, tuning: { tuning })
    }

    func testASetIsWornAtOnceAndOutlivesALaunch() async throws {
        let store = defaults()
        let tuning = Tuning(defaults: store)
        let reply = await tool(tuning).run(["set", "transcript.replyTrailingInset", "24", "transcript.personLeadingInset", "30"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertTrue(reply.text.contains("set: transcript.replyTrailingInset 24"))
        XCTAssertEqual(tuning.worn(over: vault).transcript.replyTrailingInset, 24)
        XCTAssertEqual(tuning.worn(over: vault).transcript.personLeadingInset, 30)
        let relaunched = Tuning(defaults: store)
        XCTAssertEqual(relaunched.worn(over: vault).transcript.replyTrailingInset, 24)
    }

    /// Review focus 7: a value the reader refuses changes nothing, and the reader's note is the answer.
    func testWhatTheReaderRefusesChangesNothing() async throws {
        let tuning = Tuning(defaults: defaults())
        _ = await tool(tuning).run(["set", "mascot.clearance", "20"])
        let before = tuning.document
        for (field, value) in [
            ("transcript.replyTrailingInset", "201"),
            ("transcript.replyTrailingInset", "-1"),
            ("mascot.scale", "1e400"),
            ("mascot.scale", "nan"),
            ("mascot.scale", "\"big\""),
            ("mascot.placement", "sideways"),
            ("mascot.wings", "2"),
            ("nothing.here", "1"),
            ("transcript", "4"),
            ("mascot.pin", #"{"x": 2, "y": 0.5}"#),
            ("mascot..scale", "1"),
        ] {
            let reply = await tool(tuning).run(["set", field, value])
            XCTAssertEqual(reply.status, ToolReply.refused, "\(field) \(value): \(reply.text)")
            XCTAssertTrue(reply.text.hasPrefix("refused: "), "\(field) \(value): \(reply.text)")
            XCTAssertEqual(tuning.document, before, "\(field) \(value) changed the override")
        }
    }

    /// A pressable length under its floor is refused like any other out-of-range value.
    func testThePressablesFloorHolds() async throws {
        let tuning = Tuning(defaults: defaults())
        let reply = await tool(tuning).run(["set", "badge.size", "2"])
        XCTAssertNotEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertTrue(tuning.isEmpty)
    }

    /// One refusal among several takes no other field down with it.
    func testOneRefusalLeavesTheOthersStanding() async throws {
        let tuning = Tuning(defaults: defaults())
        let reply = await tool(tuning).run(["set", "mascot.scale", "2", "mascot.clearance", "99", "mascot.placement", "glass"])
        XCTAssertEqual(reply.status, ToolReply.refused)
        let worn = tuning.worn(over: vault)
        XCTAssertEqual(worn.mascot.scale, 2)
        XCTAssertEqual(worn.mascot.clearance, Look().mascot.clearance)
        XCTAssertEqual(worn.mascot.placement, .glass)
    }

    /// A slider and the tool setting the same field are one value: the one set last is worn.
    func testASliderAndTheToolAreOneValue() async throws {
        let tuning = Tuning(defaults: defaults())
        tuning.set(.clearance, to: 10)
        _ = await tool(tuning).run(["set", "mascot.clearance", "30"])
        XCTAssertEqual(tuning.worn(over: vault).mascot.clearance, 30)
        XCTAssertNil(tuning.values[.clearance])
        tuning.set(.clearance, to: 5)
        XCTAssertEqual(tuning.worn(over: vault).mascot.clearance, 5)
        XCTAssertFalse(tuning.document?.contains("30") ?? true)
    }

    /// What the mind set is worn in a release build, where the sliders' values are not.
    func testTheMindsFieldsAreWornWhereTheSlidersAreNot() async throws {
        let store = defaults()
        let debug = Tuning(defaults: store, knobs: true)
        debug.set(.scale, to: 2)
        _ = await tool(debug).run(["set", "transcript.replyTrailingInset", "24"])
        let release = Tuning(defaults: store, knobs: false)
        let worn = release.worn(over: vault)
        XCTAssertEqual(worn.transcript.replyTrailingInset, 24)
        XCTAssertEqual(worn.mascot.scale, vault.mascot.scale)
    }

    func testResetTakesFieldsBackAndTheSheetsResetTakesEverything() async throws {
        let store = defaults()
        let tuning = Tuning(defaults: store)
        _ = await tool(tuning).run(["set", "transcript.replyTrailingInset", "24", "mascot.scale", "2"])
        tuning.pin(at: CGPoint(x: 0.5, y: 0.5))
        let one = await tool(tuning).run(["reset", "transcript.replyTrailingInset", "mascot.clearance"])
        XCTAssertEqual(one.text, "reset: transcript.replyTrailingInset\nunchanged: mascot.clearance was not set on this phone\n")
        XCTAssertEqual(tuning.worn(over: vault).transcript.replyTrailingInset, 80)
        XCTAssertEqual(tuning.worn(over: vault).mascot.scale, 2)
        tuning.reset()
        XCTAssertTrue(tuning.isEmpty)
        XCTAssertNil(store.string(forKey: Tuning.key))
        XCTAssertNil(store.string(forKey: Tuning.mindKey))
        _ = await tool(tuning).run(["set", "mascot.scale", "2"])
        let all = await tool(tuning).run(["reset"])
        XCTAssertEqual(all.status, ToolReply.ok)
        XCTAssertTrue(Tuning(defaults: store).isEmpty)
    }

    func testShowSaysEachFieldsValueRangeAndSource() async throws {
        let tuning = Tuning(defaults: defaults())
        _ = await tool(tuning).run(["set", "transcript.personLeadingInset", "12", "bubble.cornerRadius", "3"])
        let reply = await tool(tuning).run([])
        XCTAssertEqual(reply.status, ToolReply.ok)
        XCTAssertTrue(reply.text.contains("transcript.personLeadingInset 12 pt (0–200 pt) from this phone"), reply.text)
        XCTAssertTrue(reply.text.contains("transcript.replyTrailingInset 80 pt (0–200 pt) from look.json"), reply.text)
        XCTAssertTrue(reply.text.contains("mascot.clearance \(Int(Look().mascot.clearance)) pt (0–64 pt) from the compiled look"), reply.text)
        XCTAssertTrue(reply.text.contains("Also set on this phone:\nbubble.cornerRadius 3"), reply.text)
        XCTAssertTrue(reply.text.hasSuffix("look.json: 1 field\n"), reply.text)
    }

    /// Codex on #189: where a value came from is where it was read, not a guess from its value, so
    /// a look.json that sets a field to the compiled default is still what set it.
    func testAFieldTheVaultSetsToItsDefaultIsSaidToComeFromLookJSON() async throws {
        let tuning = Tuning(defaults: defaults())
        let clearance = String(format: "%g", Double(Look().mascot.clearance))
        let reply = await tool(tuning, document: #"{"mascot": {"clearance": \#(clearance)}}"#).run([])
        XCTAssertTrue(reply.text.contains("mascot.clearance \(clearance) pt (0–64 pt) from look.json"), reply.text)
        XCTAssertTrue(reply.text.contains("mascot.scale \(String(format: "%g", Double(Look().mascot.scale))) pt a pixel (0.25–4 pt a pixel) from the compiled look"), reply.text)
    }

    /// Codex on #189: a compound field is set and taken back whole. A path into one is refused and
    /// changes nothing, where taking one key out of it left a pin the reader then refused.
    func testResettingPartOfACompoundFieldIsRefused() async throws {
        let tuning = Tuning(defaults: defaults())
        let set = await tool(tuning).run(["set", "mascot.pin", #"{"x": 0.3, "y": 0.4}"#])
        XCTAssertEqual(set.status, ToolReply.ok, set.text)
        let before = tuning.document
        let reply = await tool(tuning).run(["reset", "mascot.pin.x"])
        XCTAssertEqual(reply.status, ToolReply.refused, reply.text)
        XCTAssertTrue(reply.text.contains("mascot.pin"), reply.text)
        XCTAssertEqual(tuning.document, before)
        XCTAssertEqual(tuning.worn(over: vault).mascot.pin, CGPoint(x: 0.3, y: 0.4))
        let nothing = await tool(tuning).run(["reset", "mascot.wings"])
        XCTAssertEqual(nothing.status, ToolReply.refused, nothing.text)
        let whole = await tool(tuning).run(["reset", "mascot.pin"])
        XCTAssertEqual(whole.text, "reset: mascot.pin\n")
        XCTAssertFalse(tuning.sets(["mascot", "pin"]))
    }

    /// Codex on #189: the userland run prints what the guest's command wrote, and `env` there is
    /// the tool service's token unless it is redacted on that printer too.
    func testTheUserlandRunRedactsTheToolToken() {
        let lines = DebugRun.guestLines(output: "TOPO_TOOLS_TOKEN=abc123\nCLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-xyz\nPWD=/\n",
                                        errors: "Authorization: Bearer def456\n", status: 0)
        let all = lines.joined(separator: "\n")
        for secret in ["abc123", "oat01-xyz", "def456"] { XCTAssertFalse(all.contains(secret), all) }
        XCTAssertEqual(lines, ["guest: TOPO_TOOLS_TOKEN=[redacted]", "guest: CLAUDE_CODE_OAUTH_TOKEN=[redacted]",
                               "guest: PWD=/", "guest stderr: Authorization: Bearer [redacted]", "guest exit: 0"])
    }

    func testAWrongCallIsAUsageError() async throws {
        let tuning = Tuning(defaults: defaults())
        for arguments in [["set"], ["set", "mascot.scale"], ["paint"]] {
            let reply = await tool(tuning).run(arguments)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(arguments)")
        }
        XCTAssertTrue(tuning.isEmpty)
    }

    /// Review focus 15: the resident's environment carries the tool service's port and token, and
    /// the redaction the guest-turn run prints through hides the token.
    func testTheToolTokenIsRedactedFromAToolResult() {
        let line = DebugRun.toolResultLine(tool: "Bash", isError: false, text: "TOPO_TOOLS_TOKEN=abc123 TOPO_TOOLS_URL=http://127.0.0.1:1")
        XCTAssertFalse(line.contains("abc123"))
        XCTAssertTrue(line.contains("TOPO_TOOLS_TOKEN=[redacted]"))
    }
}
