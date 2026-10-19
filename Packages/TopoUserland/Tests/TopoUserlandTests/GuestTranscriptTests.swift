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

    /// What 2.1.285 wrote in the guest when it compacted at its threshold between an input and
    /// its reply: the boundary, then the summary as a `user` entry, then the reply. The input is
    /// still answered, by its own reply and no later one's; the input before it is too, and one
    /// the transcript ends on is unresolved.
    func testACompactionBetweenAnInputAndItsReplyIsStillAnswered() throws {
        let lines = try Transcripts.lines("auto-compaction")
        func input(_ number: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", number) }
        XCTAssertEqual(lines.filter { $0.contains(#""isCompactSummary":true"#) }.count, 2)
        guard case .answered(let plain) = GuestTranscript.verdict(for: input(2), in: lines),
              case .answered(let first) = GuestTranscript.verdict(for: input(6), in: lines),
              case .answered(let second) = GuestTranscript.verdict(for: input(14), in: lines) else {
            return XCTFail("an input answered across a compaction was not read as answered")
        }
        XCTAssertTrue(plain.hasPrefix("one, two, three"), plain)
        XCTAssertTrue(first.hasPrefix("one, two, three"), first)
        XCTAssertTrue(second.hasPrefix("one, two, three"), second)
        XCTAssertEqual(GuestTranscript.verdict(for: input(21), in: lines), .unresolved)
        // Cut after the summary and before the reply: received, and not answered.
        let summary = try XCTUnwrap(lines.firstIndex { $0.contains(#""isCompactSummary":true"#) })
        XCTAssertEqual(GuestTranscript.verdict(for: input(6), in: Array(lines[...summary])), .unresolved)
    }

    /// A background task that ends while a turn runs writes its notice into the transcript
    /// between the input and the reply, as 2.1.285 did on the phone (`queueTranscriptOnly`): the
    /// reply is still the input's. A notice Claude Code answers itself is a prompt, and its reply
    /// is not the input's.
    func testABackgroundTasksNoticeBetweenAnInputAndItsReplyEndsNothing() {
        let input = "aaaaaaaa-0000-4000-8000-000000000003"
        func notice(queued: Bool) -> String {
            #"{"type":"user","uuid":"n","isSidechain":false,"origin":{"kind":"task-notification"},"promptSource":"system","queueSkipAttachments":true,"# +
                (queued ? #""queueTranscriptOnly":true,"# : "") +
                #""message":{"role":"user","content":"<task-notification> <task-id>b</task-id> </task-notification>"}}"#
        }
        let prompt = #"{"type":"user","uuid":"\#(input)","isSidechain":false,"message":{"role":"user","content":"hello"}}"#
        let reply = #"{"type":"assistant","isSidechain":false,"message":{"id":"m","model":"claude-haiku-4-5","stop_reason":"end_turn","content":[{"type":"text","text":"hi"}]}}"#
        XCTAssertEqual(GuestTranscript.verdict(for: input, in: [prompt, notice(queued: true), reply]), .answered("hi"))
        XCTAssertEqual(GuestTranscript.verdict(for: input, in: [prompt, notice(queued: false), reply]), .unresolved)
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

    /// Cut after the final message's thinking block, which carries `end_turn`, and before its
    /// text block: a finished message with no words is no reply.
    func testATranscriptCutBetweenTheFinalThinkingAndItsTextIsUnresolved() throws {
        let lines = try Transcripts.lines("answered-with-tool")
        let text = try XCTUnwrap(lines.lastIndex { $0.contains(#""stop_reason":"end_turn""#) })
        let thinking = try XCTUnwrap(lines.firstIndex { $0.contains(#""stop_reason":"end_turn""#) })
        XCTAssertLessThan(thinking, text)
        XCTAssertTrue(lines[thinking].contains(#""type":"thinking""#))
        XCTAssertTrue(lines[text].contains(#""type":"text""#))
        let cut = Array(lines[...thinking])
        XCTAssertEqual(GuestTranscript.verdict(for: answeredInput, in: cut), .unresolved)
        XCTAssertEqual(GuestTranscript.verdict(for: answeredInput, in: Array(lines[...text])), .answered("marmalade"))
    }

    private static func assistant(_ id: String, _ block: String, stop: String, more: String = "") -> String {
        #"{"type":"assistant"\#(more),"message":{"id":"\#(id)","model":"claude-haiku-4-5","content":[\#(block)],"stop_reason":"\#(stop)"}}"#
    }
    private static func text(_ words: String) -> String { #"{"type":"text","text":"\#(words)"}"# }
    private static let thinking = #"{"type":"thinking","thinking":""}"#
    private static let toolUse = #"{"type":"tool_use","name":"Bash"}"#
    private static let toolResult = #"{"type":"user","uuid":"r","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#
    private static let input = #"{"type":"user","uuid":"in-1","message":{"role":"user","content":"where is it?"}}"#

    /// A turn of two messages round a tool call, as Claude Code writes it — an entry per
    /// content block, each carrying its message's stop reason.
    private static let twoMessages = [
        input,
        assistant("m1", thinking, stop: "tool_use"),
        assistant("m1", text("Let me look. "), stop: "tool_use"),
        assistant("m1", toolUse, stop: "tool_use"),
        toolResult,
        assistant("m2", thinking, stop: "end_turn"),
        assistant("m2", text("It is on the shelf."), stop: "end_turn"),
    ]

    /// The reply is every message's words: what was said before the tool call and what was said
    /// after it, in order, one blank line between.
    func testAReplyIsTheWordsOfEveryMessageOfTheTurn() {
        XCTAssertEqual(GuestTranscript.verdict(for: "in-1", in: Self.twoMessages),
                       .answered("Let me look. \n\nIt is on the shelf."))
    }

    /// Words before a tool call do not make a reply of a turn that never finished: cut before
    /// the final message, or after its thinking and before its words, it is unresolved still.
    func testWordsBeforeAToolCallAreNoReplyUntilTheLastMessageHasItsOwn() {
        for cut in 2..<Self.twoMessages.count {
            XCTAssertEqual(GuestTranscript.verdict(for: "in-1", in: Array(Self.twoMessages.prefix(cut))), .unresolved,
                           "cut after \(cut) lines")
        }
        // A last message that finished with no words of its own is no reply either, whatever
        // was said before it.
        let wordless = Array(Self.twoMessages.dropLast())
        XCTAssertEqual(GuestTranscript.verdict(for: "in-1", in: wordless), .unresolved)
    }

    /// A sub-agent's entry is named by the tool call it was written inside (`parent_tool_use_id`)
    /// whether or not it is marked a sidechain, and its words are not the reply's.
    func testASubagentsEntryByItsParentToolCallIsNotTheReplys() {
        let lines = [
            Self.input,
            Self.assistant("m1", Self.text("First"), stop: "tool_use"),
            Self.assistant("m1", Self.toolUse, stop: "tool_use"),
            Self.assistant("s1", Self.text("a sub-agent's words"), stop: "end_turn", more: #","parent_tool_use_id":"toolu_1""#),
            Self.toolResult,
            Self.assistant("m2", Self.text("Last"), stop: "end_turn"),
        ]
        XCTAssertEqual(GuestTranscript.verdict(for: "in-1", in: lines), .answered("First\n\nLast"))
        // A sub-agent's finished message is not the turn's last: the turn has not answered.
        XCTAssertEqual(GuestTranscript.verdict(for: "in-1", in: Array(lines.dropLast())), .unresolved)
    }

    /// A message's text blocks run on, a message with no words adds no break, and a sub-agent's
    /// words and a synthetic error's are not the reply's.
    func testWhichWordsAreTheReplys() {
        let lines = [
            Self.input,
            Self.assistant("m1", Self.text("One, "), stop: "tool_use"),
            Self.assistant("m1", Self.text("two."), stop: "tool_use"),
            Self.assistant("m1", Self.toolUse, stop: "tool_use"),
            Self.assistant("s1", Self.text("a sub-agent's words"), stop: "end_turn", more: #","isSidechain":true"#),
            Self.toolResult,
            Self.assistant("m2", Self.toolUse, stop: "tool_use"),
            Self.toolResult,
            #"{"type":"assistant","isApiErrorMessage":true,"message":{"id":"e","model":"<synthetic>","content":[{"type":"text","text":"API Error: 500"}],"stop_reason":"stop_sequence"}}"#,
            Self.assistant("m3", Self.text("  "), stop: "tool_use"),
            Self.assistant("m3", Self.toolUse, stop: "tool_use"),
            Self.toolResult,
            Self.assistant("m4", Self.text("Three."), stop: "end_turn"),
        ]
        XCTAssertEqual(GuestTranscript.verdict(for: "in-1", in: lines), .answered("One, two.\n\nThree."))
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

    /// A transcript that cannot be read is no answer: not received is never concluded from it.
    func testATranscriptThatCannotBeReadIsUnreadable() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        let project = home.appendingPathComponent(".claude/projects/-home-topo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("S1.jsonl")
        let answered = try Transcripts.lines("answered-with-tool").joined(separator: "\n") + "\n"
        try Data(answered.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: home)
        }
        try XCTSkipIf((try? Data(contentsOf: file)) != nil, "missing coverage: this host reads a file with no permissions")
        let before = Date(timeIntervalSinceNow: -60)
        XCTAssertEqual(GuestTranscript.verdict(for: answeredInput, home: home, session: "S1", since: before), .unreadable)
        XCTAssertEqual(GuestTranscript.verdict(for: answeredInput, home: home, session: nil, since: before), .unreadable)
    }

    /// A folder of transcripts that cannot be listed is no answer either: the projects folder, or
    /// one project's, unlisted is `unreadable`, never not received.
    func testAFolderOfTranscriptsThatCannotBeListedIsUnreadable() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        let projects = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let project = projects.appendingPathComponent("-home-topo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let answered = try Transcripts.lines("answered-with-tool").joined(separator: "\n") + "\n"
        try Data(answered.utf8).write(to: project.appendingPathComponent("S1.jsonl"))
        defer {
            for folder in [projects, project] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            }
            try? FileManager.default.removeItem(at: home)
        }
        let before = Date(timeIntervalSinceNow: -60)

        for folder in [project, projects] {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
            try XCTSkipIf((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil,
                          "missing coverage: this host lists a folder with no permissions")
            for session in ["S1", nil] {
                XCTAssertEqual(GuestTranscript.verdict(for: answeredInput, home: home, session: session, since: before),
                               .unreadable, "\(folder.lastPathComponent) unlisted, session \(session ?? "none")")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
        XCTAssertEqual(GuestTranscript.verdict(for: answeredInput, home: home, session: "S1", since: before),
                       .answered("marmalade"), "listed again, the transcript says what it says")
    }

    /// What is not there is an answer: no projects folder at all is a Claude Code that never wrote
    /// a transcript, and a file beside the project folders is not a folder that failed to list.
    func testNoTranscriptsAtAllIsNotReceived() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let before = Date(timeIntervalSinceNow: -60)
        XCTAssertEqual(GuestTranscript.verdict(for: answeredInput, home: home, session: "S1", since: before), .notReceived)
        let projects = home.appendingPathComponent(".claude/projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: projects.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(GuestTranscript.verdict(for: answeredInput, home: home, session: nil, since: before), .notReceived)
    }
}
