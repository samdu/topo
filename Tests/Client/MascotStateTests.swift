import Foundation
import TopoUserland
import XCTest

@testable import Topo

/// What moves Topo: the guest's events made into his state by `MascotMapping`, over what Claude
/// Code actually wrote in the guest (`Packages/TopoUserland/Tests/StreamJSON`, recorded and
/// redacted) rather than over tool names made up here.
@MainActor
final class MascotStateTests: XCTestCase {
    /// A recording, as the updates a guest turn delivers: its events, then an answered end.
    private func recorded(_ name: String) throws -> [StreamEvent] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Packages/TopoUserland/Tests/StreamJSON/\(name).jsonl")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
            .flatMap(StreamJSON.events(in:))
    }

    /// Every pose the turn passes through, with a repeat of the one before left out.
    private func poses(through events: [StreamEvent], memory: String?) -> [MascotState.Activity] {
        var state = MascotState(model: "")
        var seen: [MascotState.Activity] = []
        for event in events {
            state = MascotMapping.next(state, .event(event), memory: memory)
            if seen.last != state.activity { seen.append(state.activity) }
        }
        return seen
    }

    // MARK: The table

    /// The plan's table, tool by tool.
    func testTheActivityTable() {
        let memory = "/home/topo/memory"
        func activity(_ tool: String, _ path: String? = nil, memory: String? = memory) -> MascotState.Activity? {
            MascotMapping.activity(tool: tool, path: path, memory: memory)
        }
        // A file tool under the memory's mount is yoga, whatever the file is.
        for tool in ["Write", "Edit", "MultiEdit", "NotebookEdit"] {
            XCTAssertEqual(activity(tool, "/home/topo/memory/Groceries.md"), .yoga, tool)
            XCTAssertEqual(activity(tool, "/home/topo/memory/scripts/tidy.py"), .yoga, tool)
        }
        XCTAssertEqual(activity("Write", "/home/topo/memory"), .yoga)
        // Code by its extension is building; anything else is writing.
        XCTAssertEqual(activity("Write", "/root/work/capital.py"), .building)
        XCTAssertEqual(activity("Edit", "/root/App/View.swift"), .building)
        XCTAssertEqual(activity("MultiEdit", "/root/Makefile"), .building)
        XCTAssertEqual(activity("NotebookEdit", "/root/a.ipynb"), .building)
        XCTAssertEqual(activity("Write", "/root/notes/letter.md"), .writing)
        XCTAssertEqual(activity("Edit", "/root/README"), .writing)
        XCTAssertEqual(activity("Write", nil), .writing, "a write naming no file is still a write")
        // A path only looks like it is in the memory: a sibling, and a walk out of it.
        XCTAssertEqual(activity("Write", "/home/topo/memory-old/a.md"), .writing)
        XCTAssertEqual(activity("Write", "/home/topo/memory/../elsewhere/a.md"), .writing)
        XCTAssertEqual(activity("Write", "/home/topo/other/../memory/a.md"), .yoga)
        XCTAssertEqual(activity("Write", "memory/a.md"), .writing, "a relative path is in no mount")
        // With nothing mounted, which is today, nothing is yoga.
        XCTAssertEqual(activity("Write", "/home/topo/memory/Groceries.md", memory: nil), .writing)
        // Bash builds; the web searches.
        XCTAssertEqual(activity("Bash"), .building)
        XCTAssertEqual(activity("WebSearch"), .searching)
        XCTAssertEqual(activity("WebFetch"), .searching)
        // What says nothing about the work leaves the pose alone, and nothing is the calendar yet.
        for tool in ["Read", "Glob", "Grep", "Task", "TodoWrite", "Skill", "mcp__calendar__list"] {
            XCTAssertNil(activity(tool, "/root/x.md"), tool)
        }
        let named = ["Bash", "WebSearch", "WebFetch", "Write", "Edit", "MultiEdit", "NotebookEdit", "Read", "Task"]
        XCTAssertFalse(named.contains { activity($0, "/home/topo/memory/a.md") == .calendar
            || activity($0, "/a.md") == .calendar })
    }

    // MARK: Over recorded turns

    /// The recorded tool turn — a search, a note written, code written, a file read, the note
    /// edited, a command run — with the note's folder standing in for the memory's mount, which
    /// is the only way yoga is reached until the notes folder is mounted in the guest.
    func testARecordedToolTurnGoesThroughItsPoses() throws {
        let events = try recorded("tool-turn")
        XCTAssertEqual(poses(through: events, memory: "/root/memory"), [
            .idle, .thinking, .searching, .thinking, .yoga, .thinking, .building, .thinking,
            .yoga, .thinking, .building, .thinking,
        ])
        // Today, with no memory mounted, the note is writing.
        XCTAssertEqual(poses(through: events, memory: nil), [
            .idle, .thinking, .searching, .thinking, .writing, .thinking, .building, .thinking,
            .writing, .thinking, .building, .thinking,
        ])
    }

    /// `system/init` names the model and every assistant message's usage the context; he wears
    /// the last of each.
    func testInitNamesTheModelAndUsageTheContext() throws {
        let events = try recorded("tool-turn")
        var state = MascotState(model: "")
        state = MascotMapping.next(state, .event(events[0]), memory: nil)
        guard case .started(_, let model) = events[0] else { return XCTFail("the recording does not start with init") }
        XCTAssertEqual(state.model, model)
        XCTAssertEqual(state.tokens, 0)

        for event in events { state = MascotMapping.next(state, .event(event), memory: nil) }
        let usages = events.compactMap { if case .usage(let usage) = $0 { usage } else { nil } }
        let last = try XCTUnwrap(usages.last)
        XCTAssertGreaterThan(last.context, 0)
        XCTAssertEqual(state.tokens, last.context)
        XCTAssertEqual(state.model, last.model, "the model that wrote the message is the head")
    }

    /// The two-turn recording, each turn begun and ended as the session delivers it: each thinks
    /// and the first runs Bash, and each ends idle, the second inheriting nothing.
    func testTwoRecordedTurnsEachStartAndEndIdle() throws {
        let lines = try recorded("two-turns")
        let split = try XCTUnwrap(lines.firstIndex { if case .result = $0 { true } else { false } })
        let mascot = Mascot()
        for turn in [Array(lines[...split]), Array(lines[(split + 1)...])] {
            mascot.guestTurnBegan()
            XCTAssertEqual(mascot.state.activity, .idle)
            var seen: Set<MascotState.Activity> = []
            for event in turn {
                if case .result(let result) = event {
                    mascot.guest(.ended(.answered(result)))
                } else {
                    mascot.guest(.event(event))
                }
                seen.insert(mascot.state.activity)
            }
            XCTAssertTrue(seen.contains(.thinking))
            XCTAssertEqual(mascot.state.activity, .idle, "a turn answered leaves him idle")
        }
    }

    // MARK: Whole turns

    /// Answered, failed or abandoned, the end of a turn is idle; and a turn whose updates stop
    /// with no end at all is idle too.
    func testEveryWayATurnEndsReturnsHimToIdle() {
        let result = StreamEvent.TurnResult(isError: false, subtype: "success", text: "ok", session: "s", duration: nil)
        let ends: [GuestSession.TurnEnd?] = [
            .answered(result),
            .failed(.result(StreamEvent.TurnResult(isError: true, subtype: "error_during_execution", text: nil,
                                                   session: "s", duration: nil))),
            .failed(.exited("killed")), .failed(.silent(.seconds(180))), .failed(.input("EPIPE")),
            .abandoned,
            nil,
        ]
        for end in ends {
            let mascot = Mascot()
            mascot.guestTurnBegan()
            mascot.guest(.event(.toolUse(name: "Bash")))
            XCTAssertEqual(mascot.state.activity, .building)
            if let end { mascot.guest(.ended(end)) } else { mascot.guestTurnGone() }
            XCTAssertEqual(mascot.state.activity, .idle, "\(String(describing: end))")
        }
    }

    /// A turn abandoned mid-search is followed by one that has done nothing yet: the second turn
    /// starts idle, and the first turn's pose is nowhere in it.
    func testALaterTurnInheritsNoPose() {
        let mascot = Mascot()
        mascot.guestTurnBegan()
        mascot.guest(.event(.toolUse(name: "WebSearch")))
        XCTAssertEqual(mascot.state.activity, .searching)
        // The stream is cut off without an end, and the next turn is sent.
        mascot.guestTurnBegan()
        XCTAssertEqual(mascot.state.activity, .idle)
        mascot.guest(.event(.text("hello")))
        XCTAssertEqual(mascot.state.activity, .idle, "text is not work in a pose")
        mascot.guest(.event(.thinking))
        XCTAssertEqual(mascot.state.activity, .thinking)
    }

    /// The model and the context outlast a turn; only the pose goes.
    func testATurnsEndKeepsTheModelAndTheContext() {
        let mascot = Mascot()
        mascot.guestTurnBegan()
        mascot.guest(.event(.started(session: "s", model: "claude-fable-5-1")))
        mascot.guest(.event(.usage(.init(model: "claude-fable-5-1", context: 212_000, output: 9))))
        mascot.guest(.ended(.abandoned))
        XCTAssertEqual(mascot.state, MascotState(model: "claude-fable-5-1", tokens: 212_000, activity: .idle))
        XCTAssertEqual(mascot.state.input.activity, "idle")
        XCTAssertEqual(mascot.state.input.tokens, 212_000)
    }

    // MARK: The chat's harness

    /// With no guest turn, he wears the model the harness asks and the context of its last reply,
    /// and never a pose: the Messages API turn runs no tools.
    func testTheHarnessSetsTheModelAndTheContextAndNoPose() {
        let mascot = Mascot(model: "claude-sonnet-5")
        mascot.harness(model: "claude-haiku-4-5-20251001", tokens: nil)
        XCTAssertEqual(mascot.state, MascotState(model: "claude-haiku-4-5-20251001", tokens: 0, activity: .idle))
        mascot.harness(model: "claude-haiku-4-5-20251001", tokens: 4_210)
        XCTAssertEqual(mascot.state.tokens, 4_210)
        mascot.harness(model: "claude-opus-5", tokens: nil)
        XCTAssertEqual(mascot.state.tokens, 4_210, "a reply with no usage does not empty the context")
        XCTAssertEqual(mascot.state.activity, .idle)
    }
}
