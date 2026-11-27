import XCTest
@testable import TopoUserland

/// What the transcript's work row reads off a tool call: the line's summary, the step's input,
/// and a thought's text — the turn's own only.
final class ToolStepTests: XCTestCase {
    func testTheRecordedToolTurnGivesEachCallItsSummaryAndInput() throws {
        let events = try Recording.lines("tool-turn").flatMap(StreamJSON.events(in:))
        let inputs = events.compactMap { event -> (String, String, String)? in
            if case .toolInput(_, let name, let summary, let input) = event { return (name, summary, input) }
            return nil
        }
        XCTAssertEqual(inputs.map(\.0), ["WebSearch", "Write", "Write", "Read", "Edit", "Bash"])
        XCTAssertEqual(inputs[0].1, "capital city of Australia")
        XCTAssertEqual(inputs[1].1, "capital.md")
        XCTAssertTrue(inputs[1].2.hasPrefix("file_path: /root/memory/capital.md\ncontent"), inputs[1].2)
        let thoughts = events.compactMap { if case .thought(let text) = $0 { return text } else { return nil } }
        XCTAssertFalse(thoughts.isEmpty, "the recording's thinking carries text")
    }

    /// A Bash line reads as the description the model wrote, never its command; the step holds
    /// the command.
    func testABashCallsSummaryIsItsDescriptionAndItsInputHoldsTheCommand() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"description":"Fetch it","command":"TOKEN=s3cret curl x"}}]}}"#
        XCTAssertEqual(StreamJSON.events(in: line), [
            .toolUse(name: "Bash", id: "t1"),
            .toolInput(id: "t1", name: "Bash", summary: "Fetch it", input: "command: TOKEN=s3cret curl x\ndescription: Fetch it"),
        ])
        XCTAssertEqual(ToolStep.summary(name: "Bash", input: ["command": "TOKEN=s3cret curl x"]), "")
    }

    func testASubagentsCallAndThoughtMakeNoStep() {
        let line = #"{"type":"assistant","parent_tool_use_id":"toolu_1","message":{"content":[{"type":"thinking","thinking":"hm"},{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/a"}}]}}"#
        XCTAssertEqual(StreamJSON.events(in: line), [.thinking, .toolUse(name: "Read", id: "t2")])
    }

    func testAThoughtCarriesItsTextWhenItHasAny() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":""},{"type":"thinking","thinking":"weigh it"}]}}"#
        XCTAssertEqual(StreamJSON.events(in: line), [.thinking, .thought(nil), .thinking, .thought("weigh it")])
    }

    func testSummariesAreOneShortLine() {
        XCTAssertEqual(ToolStep.summary(name: "mcp__homeclaw__set", input: [:]), "homeclaw · set")
        XCTAssertEqual(ToolStep.summary(name: "WebFetch", input: ["url": "https://example.com/a?k=secret"]), "example.com")
        XCTAssertEqual(ToolStep.summary(name: "Read", input: ["file_path": "/root/memory/notes.md"]), "notes.md")
        let long = ToolStep.summary(name: "Agent", input: ["description": String(repeating: "y", count: 300) + "\nmore"])
        XCTAssertEqual(long.count, ToolStep.summaryMax)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testALongTextKeepsItsHeadAndTail() {
        let text = String(repeating: "h", count: 100) + "MIDDLE" + String(repeating: "t", count: 100)
        let (kept, cut) = ToolStep.cap(text, 80)
        XCTAssertTrue(cut)
        XCTAssertTrue(kept.hasPrefix("hhh"))
        XCTAssertTrue(kept.hasSuffix("ttt"))
        XCTAssertFalse(kept.contains("MIDDLE"))
        XCTAssertFalse(ToolStep.cap("short", 80).cut)
    }
}
