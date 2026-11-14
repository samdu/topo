import XCTest
@testable import TopoUserland

/// The launch's SessionStart hook (`ClaudeLauncher.hookCommand`) run as Claude Code runs it, in
/// the booted guest's own shell, over transcripts made from what Claude Code 2.1.316 wrote: its
/// record of the hook's output on a start, a prompt and its reply, and a compaction's boundary
/// and summary. Marks are dated relative to now, so the hook's own clock is the one judged.
final class GuestSessionStartHookTests: XCTestCase {
    private let fm = FileManager.default
    private var host: URL!
    private var point = ""

    /// The recorded lines: the home's own hook's record, this hook's record of a start that told
    /// the time and the memory as mounted, a prompt, its reply, a compaction's boundary, and its
    /// summary.
    private var homeHook = "", told = "", prompt = "", reply = "", boundary = "", summary = ""

    override func setUp() async throws {
        _ = try SharedGuest.booted()
        let lines = try Transcripts.lines("session-start-hooks")
        (homeHook, told, prompt, reply, boundary, summary) = (lines[0], lines[1], lines[2], lines[3], lines[4], lines[5])
        let id = UUID().uuidString.prefix(8)
        host = fm.temporaryDirectory.appendingPathComponent("hook-\(id)", isDirectory: true)
        try fm.createDirectory(at: host, withIntermediateDirectories: true)
        point = "/opt/hook-\(id)"
        try Guest.shared.mount(host, at: point)
    }

    override func tearDown() async throws {
        if let host { try? fm.removeItem(at: host) }
    }

    private var now: Int { Int(Date().timeIntervalSince1970) }

    /// The launch the recorded start's marks are given to.
    private let earlier = "0a1b2c3d-0000-4000-8000-000000000001"

    /// The recorded start's record with its time mark dated `seconds` and its memory mark `memory`.
    private func told(at seconds: Int, memory: String = "mounted") throws -> String {
        let line = told.replacingOccurrences(of: #"\[topo: time [0-9]+\]"#, with: ClaudeLauncher.timeMark(seconds, launch: earlier),
                                             options: .regularExpression)
        XCTAssertNotEqual(line, told)
        return line.replacingOccurrences(of: "[topo: memory mounted]",
                                         with: ClaudeLauncher.memoryMark(mounted: memory == "mounted", at: seconds, launch: earlier))
    }

    /// What the hook prints over `lines` (nil: no transcript at all), handed `source` as Claude
    /// Code hands it, with `note` and `launch` in the launch's environment as `launchEnvironment`
    /// puts them, and with the guest's `date` answering `clock` when one is given.
    private func hook(over lines: [String]?, memory: Bool?, source: String = "resume", note: String? = nil,
                      path: String? = nil, launch: String = "0a1b2c3d-0000-4000-8000-000000000002",
                      clock: Int? = nil) async throws -> String {
        let name = "\(UUID().uuidString).jsonl"
        if let lines { try (lines.joined(separator: "\n") + "\n").write(to: host.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let input = #"{"session_id":"s","transcript_path":"\#(path ?? "\(point)/\(name)")","hook_event_name":"SessionStart","source":"\#(source)"}"#
        var environment = Guest.environment
        environment["HOOK_INPUT"] = input
        environment["HOOK_COMMAND"] = ClaudeLauncher.hookCommand(memory: memory)
        environment[ClaudeLauncher.noteVariable] = note
        environment[ClaudeLauncher.noteMarkVariable] = note.map(ClaudeLauncher.noteMark)
        environment[ClaudeLauncher.launchVariable] = launch
        environment["HOOK_CLOCK"] = clock.map(String.init)
        let ran = try await Guest.shared.run("/bin/sh", ["-c", #"""
            if [ -n "$HOOK_CLOCK" ]; then d=$(mktemp -d) && printf '#!/bin/sh\necho %s\n' "$HOOK_CLOCK" > "$d/date" \
              && chmod +x "$d/date" && PATH="$d:$PATH"; fi; printf '%s' "$HOOK_INPUT" | sh -c "$HOOK_COMMAND"
            """#], environment: environment)
        XCTAssertEqual(ran.status, 0, ran.errors)
        XCTAssertEqual(ran.errors, "")
        return ran.output
    }

    private func toldTime(_ output: String) -> Bool {
        output.contains(ClaudeLauncher.timePrompt) && output.range(of: #"\[topo: time [0-9]+ [0-9a-z-]+\]"#, options: .regularExpression) != nil
    }

    private func toldMemory(_ output: String, mounted: Bool) -> Bool {
        output.contains(ClaudeLauncher.memoryPrompt(mounted: mounted))
            && output.range(of: #"\[topo: memory \#(mounted ? "mounted" : "unmounted") at [0-9]+ [0-9a-z-]+\]"#, options: .regularExpression) != nil
    }

    /// A conversation with no transcript yet is told its time and its memory, each followed by
    /// its mark, dated by the hook's clock and ending with the launch's id, so two launches'
    /// tellings are never the same bytes, which Claude Code drops; one asked nothing of its memory
    /// is told nothing of it.
    func testAFreshConversationIsToldItsTimeAndItsMemory() async throws {
        let before = now
        let launch = "0a1b2c3d-0000-4000-8000-00000000000a"
        let output = try await hook(over: nil, memory: true, source: "startup", launch: launch)
        XCTAssertTrue(toldTime(output), output)
        XCTAssertTrue(toldMemory(output, mounted: true), output)
        let stamp = try XCTUnwrap(output.firstMatch(of: #/\[topo: time ([0-9]+) /#).map { Int($0.1)! })
        XCTAssertTrue((before...now).contains(stamp), "\(stamp) not in \(before)...\(now)")
        XCTAssertTrue(output.contains(ClaudeLauncher.timeMark(stamp, launch: launch)), output)
        XCTAssertTrue(output.contains(ClaudeLauncher.memoryMark(mounted: true, at: stamp, launch: launch)), output)
        let twin = try await hook(over: nil, memory: true, source: "startup", launch: "0a1b2c3d-0000-4000-8000-00000000000b", clock: stamp)
        XCTAssertTrue(toldTime(twin) && toldMemory(twin, mounted: true), twin)
        XCTAssertNotEqual(twin, output, "two launches in one second told the same bytes")
        let unsaid = try await hook(over: nil, memory: nil, source: "startup")
        XCTAssertTrue(toldTime(unsaid), unsaid)
        XCTAssertFalse(unsaid.contains("Obsidian vault"), unsaid)
        XCTAssertFalse(unsaid.contains("[topo: memory"), unsaid)
    }

    /// The time is told at most once a `timeGap`: a resume a minute after it was told is told
    /// nothing at all, one past the gap is told the time alone, and a mark dated after now (a
    /// clock set back) is told again.
    func testTheTimeIsToldAgainOnlyPastTheGap() async throws {
        let inside = try await hook(over: [homeHook, told(at: now - 60), prompt, reply], memory: true)
        XCTAssertEqual(inside, "")
        let clock = now
        let short = try await hook(over: [told(at: clock - ClaudeLauncher.timeGap + 1), prompt, reply], memory: true, clock: clock)
        XCTAssertEqual(short, "")
        let edge = try await hook(over: [told(at: clock - ClaudeLauncher.timeGap), prompt, reply], memory: true, clock: clock)
        XCTAssertTrue(toldTime(edge), edge)
        XCTAssertTrue(edge.contains(ClaudeLauncher.timeMark(clock, launch: "0a1b2c3d-0000-4000-8000-000000000002")), edge)
        let newest = try await hook(over: [told(at: now - ClaudeLauncher.timeGap - 100), prompt, reply, told(at: now - 60)], memory: true)
        XCTAssertEqual(newest, "", "an older mark was read over the newest")
        let past = try await hook(over: [homeHook, told(at: now - ClaudeLauncher.timeGap - 5), prompt, reply], memory: true)
        XCTAssertTrue(toldTime(past), past)
        XCTAssertFalse(past.contains("Obsidian vault"), past)
        let ahead = try await hook(over: [told(at: now + 3600), prompt, reply], memory: true)
        XCTAssertTrue(toldTime(ahead), ahead)
    }

    /// The memory is told when its state differs from the last the conversation was told, and
    /// once: a mount that went away is told so, and the next resume in that state is not.
    func testAChangeOfTheMountIsToldOnce() async throws {
        let lines = [try told(at: now - 60), prompt, reply]
        let changed = try await hook(over: lines, memory: false)
        XCTAssertTrue(toldMemory(changed, mounted: false), changed)
        XCTAssertFalse(toldTime(changed), changed)
        let again = try await hook(over: lines + [try told(at: now - 30, memory: "unmounted"), prompt, reply], memory: false)
        XCTAssertEqual(again, "")
        let back = try await hook(over: lines + [try told(at: now - 30, memory: "unmounted")], memory: true)
        XCTAssertTrue(toldMemory(back, mounted: true), back)
    }

    /// A compaction takes away what the conversation was told before it: a resume after the
    /// boundary is told both again. The compaction's own hook runs before Claude Code writes the
    /// boundary, so it tells both over marks that stand. The cut note it never tells: the
    /// process told it at its start, in a record written only with its first input, so a
    /// `/compact` that is that input finds no mark.
    func testACompactionIsToldAgainWhatItTookAway() async throws {
        let compacted = try await hook(over: [told(at: now - 60), prompt, reply, boundary, summary], memory: true)
        XCTAssertTrue(toldTime(compacted), compacted)
        XCTAssertTrue(toldMemory(compacted, mounted: true), compacted)
        let after = try await hook(over: [told(at: now - 60), prompt, reply, boundary, summary, told(at: now - 30)], memory: true)
        XCTAssertEqual(after, "")

        let note = "Your last process was cut short."
        let noted = told.replacingOccurrences(of: "[topo: memory mounted]",
                                              with: "[topo: memory mounted]\\n\\n\(note)\\n\(ClaudeLauncher.noteMark(note))")
        let compacting = try await hook(over: [noted, prompt, reply], memory: true, source: "compact", note: note)
        XCTAssertTrue(toldTime(compacting), compacting)
        XCTAssertTrue(toldMemory(compacting, mounted: true), compacting)
        XCTAssertFalse(compacting.contains(note), "a compaction told a cut already told")
        let first = try await hook(over: [try told(at: now - 60), prompt, reply], memory: true, source: "compact", note: note)
        XCTAssertTrue(toldTime(first), first)
        XCTAssertFalse(first.contains(note), "a /compact as the first input told the cut a second time")
    }

    /// A `/clear` typed in the chat begins a new session in the same process, whose hook is
    /// handed the new transcript: it is told the time and the memory, and not the cut, which the
    /// process told at its start.
    func testAClearIsToldItsTimeAndMemoryAndNotTheCut() async throws {
        let note = "Your last process was cut short."
        let cleared = try await hook(over: [told(at: now - 60), prompt, reply], memory: false, source: "clear", note: note)
        XCTAssertTrue(toldTime(cleared), cleared)
        XCTAssertTrue(toldMemory(cleared, mounted: false), cleared)
        XCTAssertFalse(cleared.contains(note), cleared)
        let fresh = try await hook(over: nil, memory: true, source: "clear", note: note)
        XCTAssertTrue(toldTime(fresh) && toldMemory(fresh, mounted: true), fresh)
        XCTAssertFalse(fresh.contains(note), fresh)
    }

    /// Only the records of SessionStart hooks' output on the main chain count, and only what the
    /// hook printed in them: a mark a person writes, one a reply quotes, a tool call whose input
    /// is laid out as such a record, a sub-agent's record, and the hook's own command, which
    /// Claude Code keeps in the record beside what it printed, are never read as told.
    func testAMarkTheHookDidNotPrintIsNotTold() async throws {
        let marks = "\(ClaudeLauncher.timeMark(now - 10, launch: earlier)) \(ClaudeLauncher.memoryMark(mounted: true, at: now - 10, launch: earlier))"
        let person = prompt.replacingOccurrences(of: #""content":"one""#, with: #""content":"\#(marks)""#)
        let quoted = reply.replacingOccurrences(of: #""text":"ok""#, with: #""text":"\#(marks)""#)
        XCTAssertNotEqual(person, prompt)
        XCTAssertNotEqual(quoted, reply)
        let command = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: [ClaudeLauncher.hookCommand(memory: true)],
                                                                         options: .withoutEscapingSlashes), encoding: .utf8))
            .dropFirst().dropLast()
        let silent = homeHook.replacingOccurrences(of: #""command":"echo HOME-HOOK""#, with: #""command":\#(command)"#)
        XCTAssertNotEqual(silent, homeHook)
        let call = #"{"type":"tool_use","id":"t","name":"Bash","input":{"type":"hook_success","hookEvent":"SessionStart","command":"echo '\#(marks)'"}}"#
        let tool = reply.replacingOccurrences(of: #"{"type":"text","text":"ok"}"#, with: call)
        XCTAssertNotEqual(tool, reply)
        let sidechain = try told(at: now - 10).replacingOccurrences(of: #""isSidechain":false"#, with: #""isSidechain":true"#)
        XCTAssertNotEqual(sidechain, try told(at: now - 10))
        let output = try await hook(over: [silent, person, quoted, tool, sidechain], memory: true)
        XCTAssertTrue(toldTime(output), output)
        XCTAssertTrue(toldMemory(output, mounted: true), output)
    }

    /// A cut's note is told unless its mark is in the hook's output anywhere in the transcript,
    /// before a compaction included, after the time and the memory; and a transcript that cannot
    /// be read, or no path at all, tells everything.
    func testANoteIsToldOnceAndAnUnreadableTranscriptTellsAll() async throws {
        let note = "Your last process was cut short."
        let then = now - 60
        let lines = [try told(at: then), prompt, reply]
        let output = try await hook(over: lines, memory: true, note: note)
        XCTAssertEqual(output, note + "\n" + ClaudeLauncher.noteMark(note))
        let mark = ClaudeLauncher.memoryMark(mounted: true, at: then, launch: earlier)
        let noted = try told(at: then).replacingOccurrences(of: mark, with: "\(mark)\\n\\n\(note)\\n\(ClaudeLauncher.noteMark(note))")
        XCTAssertNotEqual(noted, try told(at: then))
        let before = try await hook(over: [noted, prompt, reply, boundary, summary, told(at: now - 30)], memory: true, note: note)
        XCTAssertEqual(before, "")

        for path in [point, "\(point)/none.jsonl", ""] {
            let all = try await hook(over: lines, memory: true, note: note, path: path)
            XCTAssertTrue(toldTime(all), "\(path): \(all)")
            XCTAssertTrue(toldMemory(all, mounted: true), "\(path): \(all)")
            XCTAssertTrue(all.hasSuffix("\n\n" + note + "\n" + ClaudeLauncher.noteMark(note)), "\(path): \(all)")
        }
    }
}
