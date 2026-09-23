import XCTest
@testable import TopoUserland

/// The stream-json parser over what Claude Code 2.1.278 wrote in the guest (recorded, then its
/// session ids, message ids and signatures redacted), and over lines it must not trust.
final class StreamJSONTests: XCTestCase {
    private func events(_ name: String) throws -> [StreamEvent] {
        try Recording.lines(name).flatMap(StreamJSON.events(in:))
    }

    func testARecordedTwoTurnSessionReadsAsItsTurns() throws {
        let events = try events("two-turns")
        let session = "00000000-0000-4000-8000-000000000001"
        let started = events.filter { if case .started = $0 { return true } else { return false } }
        XCTAssertEqual(started, Array(repeating: .started(session: session, model: "claude-haiku-4-5-20251001"), count: 2),
                       "init comes once per turn, naming the model")
        XCTAssertTrue(events.contains(.toolUse(name: "Bash")))
        let results = events.compactMap { if case .result(let result) = $0 { return result } else { return nil } }
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { !$0.isError && $0.subtype == "success" && $0.session == session })
        XCTAssertEqual(results.last?.text, "marmalade")
        XCTAssertTrue(events.contains(.text("marmalade")))
        let usage = events.compactMap { if case .usage(let usage) = $0 { return usage } else { return nil } }
        XCTAssertFalse(usage.isEmpty)
        XCTAssertTrue(usage.allSatisfy { $0.model == "claude-haiku-4-5-20251001" && $0.context > 0 })
        XCTAssertFalse(events.contains { if case .malformed = $0 { return true } else { return false } },
                       "a line Claude Code wrote was read as malformed")
        // What the app does not read is named, not dropped silently.
        XCTAssertTrue(events.contains(.other("system/thinking_tokens")))
        XCTAssertTrue(events.contains(.other("rate_limit_event")))
        XCTAssertTrue(events.contains(.other("user")), "a tool's result coming back")
    }

    func testTheFailedResumeIsAnErrorResult() throws {
        let events = try events("resume-failed")
        guard case .result(let result)? = events.first, events.count == 1 else { return XCTFail("\(events)") }
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.subtype, "error_during_execution")
        XCTAssertEqual(result.session, "00000000-0000-4000-8000-000000000002")
    }

    func testLinesThatAreNotEventsAreMalformedAndNothingElse() {
        XCTAssertEqual(StreamJSON.events(in: "Error: something went wrong"), [.malformed("Error: something went wrong")])
        XCTAssertEqual(StreamJSON.events(in: "[1,2,3]"), [.malformed("[1,2,3]")])
        XCTAssertEqual(StreamJSON.events(in: #"{"subtype":"init","session_id":"x"}"#),
                       [.malformed(#"{"subtype":"init","session_id":"x"}"#)], "no type")
        XCTAssertEqual(StreamJSON.events(in: #"{"type":"system","subtype":"init"}"#),
                       [.malformed(#"{"type":"system","subtype":"init"}"#)], "an init naming no session")
        XCTAssertEqual(StreamJSON.events(in: #"{"type":"assistant","message":"text"}"#),
                       [.malformed(#"{"type":"assistant","message":"text"}"#)])
        XCTAssertEqual(StreamJSON.events(in: #"{"type":"result""#), [.malformed(#"{"type":"result""#)], "cut short")
        XCTAssertEqual(StreamJSON.events(in: ""), [])
        XCTAssertEqual(StreamJSON.events(in: "   "), [])
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(StreamJSON.events(in: long), [.malformed(String(repeating: "x", count: 200) + "…")])
    }

    func testAnUnknownEventIsNamedAndNotRead() {
        XCTAssertEqual(StreamJSON.events(in: #"{"type":"stream_event","event":{"type":"content_block_delta"}}"#),
                       [.other("stream_event")])
        XCTAssertEqual(StreamJSON.events(in: #"{"type":"system","subtype":"compact_boundary"}"#),
                       [.other("system/compact_boundary")])
    }

    func testAResultWithNoIsErrorIsAnErrorUnlessItSaysSuccess() {
        guard case .result(let failed)? = StreamJSON.events(in: #"{"type":"result","subtype":"error_max_turns"}"#).first,
              case .result(let fine)? = StreamJSON.events(in: #"{"type":"result","subtype":"success","result":"ok"}"#).first
        else { return XCTFail() }
        XCTAssertTrue(failed.isError)
        XCTAssertFalse(fine.isError)
    }

    func testTheTurnWrittenIsAUserMessage() throws {
        let line = StreamJSON.userTurn("say \"hi\"\nplease")
        XCTAssertFalse(line.contains("\n"), "a turn must be one line")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "user")
        let message = try XCTUnwrap(object["message"] as? [String: Any])
        XCTAssertEqual(message["role"] as? String, "user")
        XCTAssertEqual(message["content"] as? String, "say \"hi\"\nplease")
    }

    func testClaudeCodesArguments() {
        XCTAssertEqual(ClaudeLauncher.arguments(model: "claude-haiku-4-5-20251001", resume: nil),
                       ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                        "--dangerously-skip-permissions", "--model", "claude-haiku-4-5-20251001"])
        XCTAssertEqual(ClaudeLauncher.arguments(model: nil, resume: "S1").suffix(2), ["--resume", "S1"])
        let launcher = ClaudeLauncher(model: nil) { [:] }
        XCTAssertEqual(Array(launcher.commandLine(resume: nil).prefix(4)),
                       ["-c", "cd \"$HOME\" && exec \"$@\"", "sh", "/usr/local/bin/claude"])
    }
}
