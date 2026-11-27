import Foundation
import Testing
@testable import TopoMind

@Suite struct MindLaunchTests {
    @Test func takesAllowedPairsAndRefusesTheRest() {
        let taken = MindLaunch.arguments(from: [
            "--channels", "buddy-inbox", "--model", "opus", "--permission-mode", "bypassPermissions",
            "--mcp-config", "--add-dir", "--add-dir", "/tmp/x", "--append-system-prompt", "", "stray",
        ])
        #expect(taken == ["--channels", "buddy-inbox", "--add-dir", "/tmp/x"])
    }

    @Test func developmentChannelsComeLastEachNameAnArgument() {
        let taken = MindLaunch.arguments(from: [
            "--dangerously-load-development-channels", "server:buddy-inbox server:other --model", "--add-dir", "/tmp/x",
        ])
        #expect(taken == ["--add-dir", "/tmp/x", "--dangerously-load-development-channels", "server:buddy-inbox", "server:other"])
    }

    @Test func aMissingOrMisshapenFileAddsNothing() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "launch-\(UUID().uuidString).json")
        #expect(MindLaunch.arguments(at: file).isEmpty)
        try Data("[1,2]".utf8).write(to: file)
        #expect(MindLaunch.arguments(at: file).isEmpty)
        try Data(#"{"arguments":["--add-dir","/tmp/y"]}"#.utf8).write(to: file)
        #expect(MindLaunch.arguments(at: file) == ["--add-dir", "/tmp/y"])
        try FileManager.default.removeItem(at: file)
    }
}

@Suite struct MindStreamActivityTests {
    @Test func aToolCallSaysItsNameAndAWrittenFileAndNothingElse() {
        let line = #"{"type":"assistant","message":{"id":"m","content":[{"type":"thinking","thinking":"secret"},{"type":"tool_use","name":"Write","input":{"file_path":"/a/b.swift","content":"x"}},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#
        let events = MindStream.events(in: line)
        #expect(events.contains(.thinking))
        #expect(events.contains(.toolUse(name: "Write", path: "/a/b.swift")))
        #expect(events.contains(.toolUse(name: "Bash", path: nil)))
    }

    @Test func aToolResultOfTheTurnsOwnIsToldAndASubagentsIsNot() {
        let own = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"out"}]}}"#
        let sub = #"{"type":"user","parent_tool_use_id":"t1","message":{"content":[{"type":"tool_result","content":"out"}]}}"#
        #expect(MindStream.events(in: own) == [.toolResult])
        #expect(MindStream.events(in: sub) != [.toolResult])
    }
}
