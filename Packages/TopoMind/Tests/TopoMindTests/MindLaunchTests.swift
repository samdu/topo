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
