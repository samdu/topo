import XCTest
@testable import TopoUserland

/// The verdict on one input over Claude Code's own transcript, from real recordings: a turn that
/// read a file and answered, and one killed while its Bash tool ran.
final class GuestTranscriptTests: XCTestCase {
    private let answeredInput = "aaaaaaaa-0000-4000-8000-000000000001"
    private let cutInput = "aaaaaaaa-0000-4000-8000-000000000002"

    func testATurnThatRanAToolAndFinishedIsAnswered() throws {
        let lines = try Transcripts.lines("answered-with-tool")
        XCTAssertEqual(GuestTranscript.verdict(for: answeredInput, in: lines), .answered("marmalade"))
    }

    func testAnInputNoEntryCarriesWasNotReceived() throws {
        let lines = try Transcripts.lines("answered-with-tool")
        XCTAssertEqual(GuestTranscript.verdict(for: "never-sent", in: lines), .notReceived)
        XCTAssertEqual(GuestTranscript.verdict(for: answeredInput, in: []), .notReceived)
    }

    /// Killed while its tool ran: the input is there, a tool call and its result after it, and no
    /// reply that ends the turn.
    func testATurnKilledMidToolIsUnresolved() throws {
        let lines = try Transcripts.lines("cut-mid-tool")
        XCTAssertEqual(GuestTranscript.verdict(for: cutInput, in: lines), .unresolved)
    }

    /// The same answered turn cut back to before its last message, and cut in the middle of a
    /// line as a killed process leaves it: unresolved, and the half line is skipped.
    func testATranscriptCutBeforeTheReplyIsUnresolved() throws {
        let lines = try Transcripts.lines("answered-with-tool")
        let finalMessage = try XCTUnwrap(lines.lastIndex { $0.contains(#""stop_reason":"end_turn""#) })
        let firstOfIt = try XCTUnwrap(lines.firstIndex { $0.contains(#""stop_reason":"end_turn""#) })
        XCTAssertLessThanOrEqual(firstOfIt, finalMessage)
        let before = Array(lines[..<firstOfIt])
        XCTAssertEqual(GuestTranscript.verdict(for: answeredInput, in: before), .unresolved)
        let torn = before + [String(lines[finalMessage].prefix(40))]
        XCTAssertEqual(GuestTranscript.verdict(for: answeredInput, in: torn), .unresolved)
    }

    /// An error Claude Code wrote in the model's place is no reply.
    func testASyntheticErrorIsNoReply() {
        let lines = [
            #"{"type":"user","uuid":"in-1","message":{"role":"user","content":"hello"}}"#,
            #"{"type":"assistant","isApiErrorMessage":true,"message":{"id":"x","model":"<synthetic>","content":[{"type":"text","text":"API Error: 500"}],"stop_reason":"stop_sequence"}}"#,
        ]
        XCTAssertEqual(GuestTranscript.verdict(for: "in-1", in: lines), .unresolved)
    }

    /// Only what comes between the input and the next prompt is its reply: a later turn's answer
    /// is not an earlier one's, and an earlier turn keeps its own.
    func testAReplyBelongsToTheInputBeforeIt() {
        let lines = [
            #"{"type":"user","uuid":"in-1","message":{"role":"user","content":"first"}}"#,
            #"{"type":"assistant","message":{"id":"m1","model":"claude-haiku-4-5","content":[{"type":"text","text":"one"}],"stop_reason":"end_turn"}}"#,
            #"{"type":"user","uuid":"in-2","message":{"role":"user","content":"second"}}"#,
            #"{"type":"assistant","message":{"id":"m2","model":"claude-haiku-4-5","content":[{"type":"tool_use","name":"Bash"}],"stop_reason":"tool_use"}}"#,
            #"{"type":"user","uuid":"r","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
        ]
        XCTAssertEqual(GuestTranscript.verdict(for: "in-1", in: lines), .answered("one"))
        XCTAssertEqual(GuestTranscript.verdict(for: "in-2", in: lines), .unresolved)
    }

    /// The files under a home: the named session's is read, and so is any other session changed
    /// since the input went, which is where an input sent before the session id was known lands.
    func testTheVerdictIsFoundInTheNamedSessionOrOneChangedSince() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent(".claude/projects/-home-topo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let answered = try Transcripts.lines("answered-with-tool").joined(separator: "\n") + "\n"
        try Data(answered.utf8).write(to: project.appendingPathComponent("S1.jsonl"))
        let cut = try Transcripts.lines("cut-mid-tool").joined(separator: "\n") + "\n"
        try Data(cut.utf8).write(to: project.appendingPathComponent("S2.jsonl"))
        let before = Date(timeIntervalSinceNow: -60)

        XCTAssertEqual(GuestTranscript.verdict(for: answeredInput, home: home, session: "S1", since: before),
                       .answered("marmalade"))
        XCTAssertEqual(GuestTranscript.verdict(for: cutInput, home: home, session: nil, since: before), .unresolved)
        XCTAssertEqual(GuestTranscript.verdict(for: answeredInput, home: home, session: "S2", since: before),
                       .answered("marmalade"), "an input in another session changed since it went is found there")
        XCTAssertEqual(GuestTranscript.verdict(for: answeredInput, home: home, session: "S2", since: Date(timeIntervalSinceNow: 3600)),
                       .notReceived, "only files changed since the input went are searched beyond the named one")
        XCTAssertEqual(GuestTranscript.verdict(for: "never-sent", home: home, session: "S1", since: before), .notReceived)
    }
}
