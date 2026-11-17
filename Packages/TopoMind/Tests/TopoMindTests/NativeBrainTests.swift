import Darwin
import Foundation
import Testing
import TopoCore
import TopoCoreTesting
import TopoTurn
@testable import TopoMind

/// A fake `claude` (`Fixtures/fake-claude`) in a scratch folder of its own, with the brain's
/// directories and what the fake recorded.
struct Rig {
    let root: URL
    let claude: URL
    let config: URL
    let work: URL
    let log: URL
    var environment: [String: String]

    init(_ environment: [String: String] = [:]) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "topo-mind-\(UUID().uuidString)")
        config = root.appending(path: "config")
        work = root.appending(path: "work")
        log = root.appending(path: "log")
        claude = root.appending(path: "claude")
        for dir in [config, work, log] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let fixture = try #require(Bundle.module.url(forResource: "Fixtures/fake-claude", withExtension: nil))
        try FileManager.default.copyItem(at: fixture, to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        self.environment = environment.merging(["FAKE_LOG": log.path]) { $1 }
    }

    func brain(grace: Duration = .seconds(20), silence: Duration = NativeBrain.standardSilence,
               turn: Duration = NativeBrain.standardTurn, earlyBound: TimeInterval = NativeBrain.earlyBound) -> NativeBrain {
        var configuration = NativeBrain.Configuration(workingDirectory: work, configDirectory: config, claude: claude,
                                                      environment: environment, startBound: grace, silenceBound: silence,
                                                      turnBound: turn)
        configuration.earlyBound = earlyBound
        return NativeBrain(configuration)
    }

    func lines(_ name: String) -> [[String: Any]] {
        guard let text = try? String(contentsOf: log.appending(path: name), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    var inputs: [String] { lines("inputs.jsonl").compactMap { $0["content"] as? String } }
    var launches: [[String]] { lines("launches.jsonl").compactMap { $0["args"] as? [String] } }
}

func turn(_ device: String, _ sequence: Int64, _ role: TurnRole, _ text: String, parents: [TurnRef] = []) -> Turn {
    Turn(ref: TurnRef(device: DeviceID(device), sequence: sequence), parents: parents, role: role, text: text, at: Date())
}

func request(_ person: Turn, context: [Turn] = []) -> BrainRequest {
    BrainRequest(context: context, answering: [person], parents: [person.ref],
                 nonce: TurnRunner.replyNonce(for: [person.ref]), model: .sonnet)
}

func gone(_ pid: pid_t) -> Bool { !MindProcess.alive(pid) }

@Suite(.serialized) struct NativeBrainTests {
    @Test func oneTurnIsAnsweredByTheResidentInItsOwnHome() async throws {
        let rig = try Rig()
        let brain = rig.brain()
        let person = turn("phone", 1, .person, "hello")
        let reply = try await brain.answer(request(person))
        #expect(reply.text == "echo: hello")
        #expect(reply.context == 115)
        #expect(reply.outputTokens == 7)
        #expect(rig.inputs == ["hello"])

        let launch = try #require(rig.lines("launches.jsonl").first)
        let args = try #require(launch["args"] as? [String])
        #expect(Array(args.prefix(7)) == ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                                          "--verbose", "--replay-user-messages"])
        #expect(args.contains("--permission-mode") && args[args.firstIndex(of: "--permission-mode")! + 1] == "auto")
        #expect(!args.contains("--dangerously-skip-permissions"))
        // Every piece of a reply is a line as it is made, so a working turn is never long quiet.
        #expect(args.contains("--include-partial-messages"))
        // A debug build (which `swift test` is) asks Haiku whatever the request says.
        #expect(args[args.firstIndex(of: "--model")! + 1] == ClaudeModel.effective(.sonnet).rawValue)
        #expect(!args.contains("--resume"))
        let env = try #require(launch["env"] as? [String: String])
        #expect(env["CLAUDE_CONFIG_DIR"] == rig.config.path)
        // Nothing of the test run's Claude Code session reaches it.
        #expect(env.keys.filter { $0.hasPrefix("CLAUDE") || $0.hasPrefix("ANTHROPIC") } == ["CLAUDE_CONFIG_DIR"])
        #expect(URL(fileURLWithPath: launch["cwd"] as! String).resolvingSymlinksInPath() == rig.work.resolvingSymlinksInPath())
        await brain.shutdown()
    }

    @Test func theEnvironmentIsTheFewInheritedAndTheConfigs() {
        let parent = ["HOME": "/Users/x", "PATH": "/bin", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli",
                      "ANTHROPIC_API_KEY": "k", "CLAUDE_CONFIG_DIR": "/Users/x/.claude", "SECRET": "s"]
        let configured = NativeBrain.Configuration(workingDirectory: URL(fileURLWithPath: "/w"),
                                                   configDirectory: URL(fileURLWithPath: "/c"), environment: ["EXTRA": "1"])
        #expect(NativeBrain.environment(for: configured, parent: parent)
                == ["HOME": "/Users/x", "PATH": "/bin", "EXTRA": "1", "CLAUDE_CONFIG_DIR": "/c"])
        let inheriting = NativeBrain.Configuration(workingDirectory: URL(fileURLWithPath: "/w"), configDirectory: nil,
                                                   stateDirectory: URL(fileURLWithPath: "/s"))
        #expect(NativeBrain.environment(for: inheriting, parent: parent)["CLAUDE_CONFIG_DIR"] == nil)
    }

    @Test func twoTurnsThroughTheRunnerGoInOrderToOneProcess() async throws {
        let rig = try Rig()
        let brain = rig.brain()
        let db = InMemoryRecordDatabase()
        let device = DeviceID("mac")
        let log = TurnLog(database: db)
        let lease = PrimaryLease(database: db, device: device, endpoint: nil, probe: NoSocketProbe(),
                                 sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let runner = TurnRunner(log: log, writer: try await log.writer(for: device), lease: lease, brain: brain)
        let first = try await runner.run("one", model: .sonnet)
        let second = try await runner.run("two", model: .sonnet)
        #expect(first.assistant.text == "echo: one")
        #expect(second.assistant.text == "echo: two")
        #expect(second.person.parents == [first.assistant.ref])
        // The second input is the bare words: the first exchange is the conversation's own.
        #expect(rig.inputs == ["one", "two"])
        #expect(rig.launches.count == 1)
        #expect(await brain.owed() == nil)
        await brain.shutdown()
    }

    @Test func turnsAnsweredElsewhereAreToldBeforeTheTurnAsked() async throws {
        let rig = try Rig()
        let brain = rig.brain()
        let p1 = turn("mac", 1, .person, "one")
        let reply1 = try await brain.answer(request(p1))
        let a1 = turn("mac", 2, .assistant, reply1.text, parents: [p1.ref])
        await brain.landed(a1, nonce: TurnRunner.replyNonce(for: [p1.ref]))
        // The Mac slept; the phone answered two turns.
        let p2 = turn("phone", 1, .person, "while you slept", parents: [a1.ref])
        let a2 = turn("phone", 2, .assistant, "the phone's answer", parents: [p2.ref])
        let p3 = turn("mac", 3, .person, "three", parents: [a2.ref])
        _ = try await brain.answer(request(p3, context: [p1, a1, p2, a2]))
        let told = try #require(rig.inputs.last)
        #expect(told == """
        [Meanwhile, on their other devices — turns of this conversation you have not seen, oldest first:]

        Them: while you slept

        You, answering on another device: the phone's answer

        [They now say:]

        three
        """)
        await brain.landed(turn("mac", 4, .assistant, "echo: three", parents: [p3.ref]), nonce: TurnRunner.replyNonce(for: [p3.ref]))
        // Once told, never told again.
        let p5 = turn("mac", 5, .person, "four")
        _ = try await brain.answer(request(p5, context: [p1, a1, p2, a2, p3, turn("mac", 4, .assistant, "echo: three")]))
        #expect(rig.inputs.last == "four")
        await brain.shutdown()
    }

    @Test func aFreshConversationIsToldTheLogSoFar() async throws {
        let rig = try Rig()
        let brain = rig.brain()
        let p1 = turn("phone", 1, .person, "earlier")
        let a1 = turn("phone", 2, .assistant, "earlier answer")
        let p2 = turn("mac", 1, .person, "now")
        _ = try await brain.answer(request(p2, context: [p1, a1]))
        #expect(rig.inputs.last?.hasPrefix("[The conversation so far, from the log on their devices — the last 2 turns") == true)
        #expect(rig.inputs.last?.hasSuffix("[They now say:]\n\nnow") == true)
        await brain.shutdown()
    }

    @Test func aRelaunchResumesTheSessionAndKnowsWhatItWasTold() async throws {
        let rig = try Rig()
        let p1 = turn("mac", 1, .person, "one")
        let a1 = turn("mac", 2, .assistant, "echo: one", parents: [p1.ref])
        do {
            let brain = rig.brain()
            _ = try await brain.answer(request(p1))
            await brain.landed(a1, nonce: TurnRunner.replyNonce(for: [p1.ref]))
            #expect(await brain.shutdown())
        }
        let session = try #require(rig.lines("inputs.jsonl").first?["session"] as? String)
        let brain = rig.brain()
        let p2 = turn("mac", 3, .person, "two", parents: [a1.ref])
        let reply = try await brain.answer(request(p2, context: [p1, a1]))
        #expect(reply.text == "echo: two")
        #expect(rig.inputs == ["one", "two"])
        let second = try #require(rig.launches.last)
        #expect(second[second.firstIndex(of: "--resume")! + 1] == session)
        #expect(rig.lines("inputs.jsonl").last?["session"] as? String == session)
        await brain.shutdown()
    }

    @Test func aSessionThatCannotBeResumedStartsAFreshOneToldTheLog() async throws {
        let rig = try Rig()
        let p1 = turn("mac", 1, .person, "one")
        let a1 = turn("mac", 2, .assistant, "echo: one", parents: [p1.ref])
        do {
            let brain = rig.brain()
            _ = try await brain.answer(request(p1))
            await brain.landed(a1, nonce: TurnRunner.replyNonce(for: [p1.ref]))
            await brain.shutdown()
        }
        try FileManager.default.removeItem(at: rig.config.appending(path: "fake-sessions"))
        let brain = rig.brain()
        _ = try await brain.answer(request(turn("mac", 3, .person, "two"), context: [p1, a1]))
        #expect(rig.launches.count == 3)
        #expect(rig.launches[1].contains("--resume"))
        #expect(!rig.launches[2].contains("--resume"))
        #expect(rig.inputs.last?.hasPrefix("[The conversation so far") == true)
        await brain.shutdown()
    }

    @Test func notSignedInIsItsOwnErrorAndCountsNothing() async throws {
        let rig = try Rig(["FAKE_SIGNED_OUT": "1"])
        let brain = rig.brain()
        let person = turn("mac", 1, .person, "hello")
        await #expect {
            _ = try await brain.answer(request(person))
        } throws: { error in
            if case NativeBrainError.notSignedIn = error { return true }
            return false
        }
        #expect(await brain.owed() == nil)
        #expect(await brain.unresolved().isEmpty)
        #expect(await brain.describe().contains("no session yet"))
        // The process that found no login is gone; the next request starts one that reads the login.
        #expect(await brain.pid == nil)
        await brain.shutdown()
    }

    @Test func aTurnOfClaudeCodesOwnBeforeTheEchoIsNotTheReply() async throws {
        let rig = try Rig(["FAKE_STRAY": "1"])
        let brain = rig.brain()
        let reply = try await brain.answer(request(turn("mac", 1, .person, "hello")))
        #expect(reply.text == "echo: hello")
        await brain.shutdown()
    }

    @Test func aCancelledTurnsEndIsNotTheNextTurns() async throws {
        let rig = try Rig()
        let brain = rig.brain()
        let slow = turn("mac", 1, .person, "SLOW one")
        let asking = Task { try await brain.answer(request(slow)) }
        try await Task.sleep(for: .milliseconds(400))
        asking.cancel()
        await #expect(throws: CancellationError.self) { _ = try await asking.value }
        let next = turn("mac", 2, .person, "two")
        let reply = try await brain.answer(request(next))
        #expect(reply.text == "echo: two")
        #expect(rig.launches.count == 1)
        await brain.shutdown()
    }

    @Test func aRetryOfACancelledTurnListensRatherThanSendingAgain() async throws {
        let rig = try Rig()
        let brain = rig.brain()
        let slow = turn("mac", 1, .person, "SLOW one")
        let asking = Task { try await brain.answer(request(slow)) }
        try await Task.sleep(for: .milliseconds(400))
        asking.cancel()
        _ = try? await asking.value
        let reply = try await brain.answer(request(slow))
        #expect(reply.text == "echo: SLOW one")
        #expect(rig.inputs.count == 1)
        await brain.shutdown()
    }

    @Test func anErrorResultIsUnresolvedAndTheNextTurnMovesPastIt() async throws {
        let rig = try Rig()
        let brain = rig.brain()
        let failing = turn("mac", 1, .person, "FAIL")
        await #expect {
            _ = try await brain.answer(request(failing))
        } throws: { error in
            if case NativeBrainError.unresolved = error { return true }
            return false
        }
        #expect(await brain.unresolved() == [failing.ref])
        let next = turn("mac", 2, .person, "again", parents: [failing.ref])
        let reply = try await brain.answer(request(next, context: [failing]))
        #expect(reply.text == "echo: again")
        // The conversation had the cut-off turn; it is not told again.
        #expect(rig.inputs.last == "again")
        #expect(await brain.unresolved().isEmpty)
        await brain.shutdown()
    }

    @Test func aReplyNotYetInTheLogIsOwedAndNotAskedAgain() async throws {
        let rig = try Rig()
        let person = turn("mac", 1, .person, "hello")
        do {
            let brain = rig.brain()
            _ = try await brain.answer(request(person))
            await brain.shutdown()
        }
        let brain = rig.brain()
        let owed = try #require(await brain.owed())
        #expect(owed == OwedReply(parents: [person.ref], nonce: TurnRunner.replyNonce(for: [person.ref]), text: "echo: hello"))
        let again = try await brain.answer(request(person))
        #expect(again.text == "echo: hello")
        #expect(rig.inputs.count == 1)
        await brain.landed(turn("mac", 2, .assistant, "echo: hello", parents: [person.ref]), nonce: owed.nonce)
        #expect(await brain.owed() == nil)
    }

    @Test func forgetDropsTheSessionAndWhatWasTold() async throws {
        let rig = try Rig()
        let brain = rig.brain()
        let p1 = turn("mac", 1, .person, "one")
        _ = try await brain.answer(request(p1))
        await brain.landed(turn("mac", 2, .assistant, "echo: one", parents: [p1.ref]), nonce: TurnRunner.replyNonce(for: [p1.ref]))
        let pid = try #require(await brain.pid)
        await brain.forget()
        #expect(gone(pid))
        #expect(!FileManager.default.fileExists(atPath: rig.config.appending(path: "mind.json").path))
        _ = try await brain.answer(request(turn("mac", 3, .person, "two"), context: [p1]))
        #expect(!(rig.launches.last ?? []).contains("--resume"))
        #expect(rig.inputs.last?.hasPrefix("[The conversation so far") == true)
        await brain.shutdown()
    }

    @Test func teardownReapsTheProcessAndWhatItStarted() async throws {
        for ignoring in [false, true] {
            var environment = ["FAKE_CHILD": "1"]
            if ignoring { environment["FAKE_IGNORE_TERM"] = "1" }
            let rig = try Rig(environment)
            let brain = rig.brain()
            try await brain.start()
            let pid = try #require(await brain.pid)
            let children = try #require(rig.lines("children.jsonl").first?["pids"] as? [Int]).map { pid_t($0) }
            #expect(children.count == 2)
            #expect(children.allSatisfy(MindProcess.alive))
            let began = ContinuousClock.now
            #expect(await brain.shutdown())
            // One that ignores SIGTERM and its stdin's end is killed once the grace is out.
            if ignoring { #expect(ContinuousClock.now - began >= .seconds(3)) }
            #expect(gone(pid))
            #expect(children.allSatisfy(gone))
            #expect(await brain.pid == nil)
        }
    }
}
