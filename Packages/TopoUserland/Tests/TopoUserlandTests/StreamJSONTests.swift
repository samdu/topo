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

    /// A turn that searched, wrote a note, wrote code, read, edited and ran a command, recorded in
    /// the guest from Claude Code 2.1.278 and redacted the same way. A file tool carries the file
    /// it names and nothing else of its input; no other tool carries a path; every thinking block
    /// is an event, in order with the tools.
    func testARecordedToolTurnNamesTheFilesItWroteAndThatItThought() throws {
        let events = try events("tool-turn")
        let tools = events.compactMap { event -> StreamEvent? in
            switch event {
            case .toolUse, .thinking: event
            default: nil
            }
        }
        XCTAssertEqual(tools, [
            .thinking, .toolUse(name: "WebSearch"),
            .thinking, .toolUse(name: "Write", path: "/root/memory/capital.md"),
            .thinking, .toolUse(name: "Write", path: "/root/work/capital.py"),
            .thinking, .toolUse(name: "Read"),
            .thinking, .toolUse(name: "Edit", path: "/root/memory/capital.md"),
            .thinking, .toolUse(name: "Bash"),
            .thinking,
        ])
        XCTAssertFalse(events.contains { if case .malformed = $0 { return true } else { return false } })
        guard case .result(let result)? = events.last else { return XCTFail("no result at the end") }
        XCTAssertFalse(result.isError)
    }

    /// The two-turn recording's thinking blocks are events too.
    func testTheTwoTurnRecordingThinksBeforeEachAnswer() throws {
        XCTAssertEqual(try events("two-turns").filter { $0 == .thinking }.count, 3)
    }

    /// Only the file tools' own key is read, and a path of any other type is none.
    func testOnlyAFileToolsOwnKeyIsItsPath() {
        func tool(_ name: String, _ input: String) -> [StreamEvent] {
            StreamJSON.events(in: #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"\#(name)","input":\#(input)}]}}"#)
        }
        XCTAssertEqual(tool("NotebookEdit", #"{"notebook_path":"/a.ipynb","new_source":"x"}"#),
                       [.toolUse(name: "NotebookEdit", path: "/a.ipynb")])
        XCTAssertEqual(tool("MultiEdit", #"{"file_path":"/b.swift","edits":[]}"#), [.toolUse(name: "MultiEdit", path: "/b.swift")])
        XCTAssertEqual(tool("Read", #"{"file_path":"/c.md"}"#), [.toolUse(name: "Read")], "Read writes nothing")
        XCTAssertEqual(tool("Write", #"{"file_path":7}"#), [.toolUse(name: "Write")])
        XCTAssertEqual(tool("Write", #"{"path":"/d.md"}"#), [.toolUse(name: "Write")])
        XCTAssertEqual(StreamJSON.events(in: #"{"type":"assistant","message":{"content":[{"type":"redacted_thinking","data":"x"}]}}"#),
                       [.thinking])
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
        let launcher = ClaudeLauncher { [:] }
        XCTAssertEqual(Array(launcher.commandLine(resume: nil, model: nil).prefix(4)),
                       ["-c", "cd \"$HOME\" && exec \"$@\"", "sh", "/usr/local/bin/claude"])
    }

    /// The bypass is set only by the resident's launcher: its command line carries the flag and
    /// its environment `IS_SANDBOX=1`, which Claude Code needs to bypass as root. Whatever the
    /// resident starts inherits the environment, so `IS_SANDBOX`, by design; the flag is an
    /// argument and is not inherited. No other launch path sets either: the environment
    /// the app's other guest programs are given (`Guest.environment`, which `Guest.run` defaults to
    /// and the debug userland command builds on) carries neither.
    func testOnlyTheResidentsLauncherSetsTheBypass() async throws {
        let launcher = ClaudeLauncher { ["ANTHROPIC_BASE_URL": "http://127.0.0.1:4242"] }
        XCTAssertTrue(launcher.commandLine(resume: "S1", model: nil).contains("--dangerously-skip-permissions"))
        let environment = try await launcher.launchEnvironment()
        XCTAssertEqual(environment["IS_SANDBOX"], "1")
        XCTAssertEqual(environment["HOME"], ClaudeLauncher.home)
        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], "http://127.0.0.1:4242")
        XCTAssertNil(Guest.environment["IS_SANDBOX"], "a launch path besides the resident's sets IS_SANDBOX")
    }

    /// The launcher's own keys are applied after what the callback supplies, so nothing supplied
    /// turns the sandbox off or moves the home.
    func testTheCallbackCannotOverrideTheLaunchersOwnKeys() async throws {
        let launcher = ClaudeLauncher { ["IS_SANDBOX": "0", "HOME": "/root", "CLAUDE_CODE_OAUTH_TOKEN": "t"] }
        let environment = try await launcher.launchEnvironment()
        XCTAssertEqual(environment["IS_SANDBOX"], "1")
        XCTAssertEqual(environment["HOME"], ClaudeLauncher.home)
        XCTAssertEqual(environment["CLAUDE_CODE_OAUTH_TOKEN"], "t", "what the callback supplies for its own keys stands")
        XCTAssertFalse(Guest.environment.values.contains { $0.contains("dangerously") })
    }
}
