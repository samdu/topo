import Darwin
import Foundation
import Testing
import TopoCore
import TopoCoreTesting
import TopoTurn
@testable import TopoMind

/// The phone's brain, for the turn the hub gave up on: it answers whatever it is asked, at once.
actor PhoneBrain: Brain {
    private(set) var asked: [BrainRequest] = []

    func answer(_ request: BrainRequest) async throws -> Reply {
        asked.append(request)
        return Reply(text: "the phone's answer", model: "phone", context: 0, outputTokens: 0)
    }

    func describe() async -> String { "the phone" }
}

extension HubRig {
    /// The phone's runner: its own lease, log writer and brain over the same store.
    func phoneRunner(_ brain: PhoneBrain) async throws -> TurnRunner {
        let log = TurnLog(database: db)
        let lease = PrimaryLease(database: db, device: phoneID, endpoint: nil, probe: NoSocketProbe(), timing: fast)
        return TurnRunner(log: log, writer: try await log.writer(for: phoneID), lease: lease, brain: brain)
    }
}

/// Runs `defaults` as another process would: the hub's switch set from a shell.
@discardableResult
func defaults(_ arguments: String...) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    process.arguments = arguments
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

@Suite(.serialized) struct HubStallTests {
    @Test func aSilentMindIsGivenUpOnAtTheBoundAndThePhoneAnswersTheTurnOnce() async throws {
        let silence = Duration.seconds(1)
        let h = try HubRig(silence: silence)
        let hub = h.hub()
        await hub.turnOn()
        #expect(await eventually { await hub.snapshot().holds })
        let pid = try #require(await hub.pid)
        let person = try await h.phoneSays("HANG hello")
        #expect(await eventually { h.rig.inputs.contains("HANG hello") })
        let asked = ContinuousClock.now

        #expect(await eventually { await hub.snapshot().phase == .stopped(.stalled(.silent(silence))) })
        // Not before the bound: the input was written before the fake recorded it.
        #expect(ContinuousClock.now - asked >= .milliseconds(900))
        let stopped = await hub.snapshot()
        #expect(stopped.holds == false)
        #expect(gone(pid))
        #expect(await hub.pid == nil)

        // Stopped, and staying so: no renewal, no pass, no second process, no reply.
        let tag = await h.leaseTag()
        try await Task.sleep(for: .seconds(1.5))
        #expect(await h.leaseTag() == tag)
        #expect(await hub.snapshot().passes == stopped.passes)
        #expect(await hub.snapshot().phase == .stopped(.stalled(.silent(silence))))
        #expect(h.rig.launches.count == 1)
        #expect(try await h.replies().isEmpty)

        // The lease lapses, and the phone answers the turn, under the reply's own nonce.
        #expect(await eventually { await h.lease()?.isExpired(at: Date()) == true })
        let phoneBrain = PhoneBrain()
        let phone = try await h.phoneRunner(phoneBrain)
        let answered = try #require(try await phone.answerPending(model: .sonnet))
        #expect(answered.ref.device == h.phoneID)
        #expect(answered.parents == [person.ref])
        #expect(await phoneBrain.asked.count == 1)

        // Asked again, the hub takes the lease back and writes nothing for that turn: the phone's
        // reply is the one, and the stalled words are not given to Claude Code a second time.
        await hub.tryAgain()
        #expect(await eventually { await hub.snapshot().holds })
        let passes = await hub.snapshot().passes
        #expect(await eventually { await hub.snapshot().passes >= passes + 3 })
        #expect(try await h.replies().count == 1)
        #expect(h.rig.inputs.filter { $0.contains("HANG hello") }.count == 1)
        await hub.turnOff()
    }

    @Test func aStalledTurnIsNotAnsweredByTheHubWhenItIsAskedAgainFirst() async throws {
        let silence = Duration.seconds(1)
        let h = try HubRig(silence: silence)
        let hub = h.hub()
        await hub.turnOn()
        #expect(await eventually { await hub.snapshot().holds })
        try await h.phoneSays("HANG hello")
        #expect(await eventually { await hub.snapshot().phase == .stopped(.stalled(.silent(silence))) })
        // Try again before the phone answered: the turn is cut off, and waits for the person.
        let before = await hub.snapshot().passes
        await hub.tryAgain()
        #expect(await eventually { let s = await hub.snapshot(); return s.phase == .answering && s.passes >= before + 2 })
        try await Task.sleep(for: .seconds(1))
        #expect(try await h.replies().isEmpty)
        #expect(h.rig.inputs.filter { $0.contains("HANG hello") }.count == 1)
        #expect(await hub.snapshot().lastPass?.outcome == .nothing)
        // The person asks again: that turn is answered.
        try await h.phoneSays("again")
        #expect(try await eventually { try await h.replies().count == 1 })
        #expect(try await h.replies().first?.text == "echo: again")
        await hub.turnOff()
    }

    @Test func aMindThatKeepsWritingPastTheSilenceIsNotGivenUpOn() async throws {
        // Heartbeats every 0.25 s for 3 s, with a 1 s silence bound: lines MindStream names
        // nothing but `other`, and they count.
        let h = try HubRig(silence: .seconds(1))
        let hub = h.hub()
        await hub.turnOn()
        #expect(await eventually { await hub.snapshot().holds })
        try await h.phoneSays("CHATTY hello")
        #expect(try await eventually { try await h.replies().count == 1 })
        #expect(try await h.replies().first?.text == "echo: CHATTY hello")
        #expect(await hub.snapshot().phase == .answering)
        #expect(await hub.snapshot().holds)
        await hub.turnOff()
    }

    @Test func aTurnPastItsBoundIsGivenUpOnHoweverMuchItWrites() async throws {
        let turn = Duration.seconds(2)
        let h = try HubRig(silence: .seconds(1), turn: turn)
        let hub = h.hub()
        await hub.turnOn()
        #expect(await eventually { await hub.snapshot().holds })
        let pid = try #require(await hub.pid)
        try await h.phoneSays("BUSY hello")
        #expect(await eventually { h.rig.inputs.contains("BUSY hello") })
        let asked = ContinuousClock.now
        #expect(await eventually { await hub.snapshot().phase == .stopped(.stalled(.tooLong(turn))) })
        #expect(ContinuousClock.now - asked >= .milliseconds(1900))
        #expect(await hub.snapshot().holds == false)
        #expect(gone(pid))
        try await Task.sleep(for: .seconds(1))
        #expect(try await h.replies().isEmpty)
    }

    @Test func aSwitchKeptOnStartsTheMindAndAnOffFromAnotherProcessStopsIt() async throws {
        let domain = "zone.hexagon.topo.hub.test-\(UUID().uuidString.lowercased())"
        defer {
            _ = try? defaults("delete", domain)
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Preferences/\(domain).plist"))
        }
        let h = try HubRig()
        let hub = h.hub()
        let mindSwitch = MindSwitch(mind: hub, domain: domain, key: "mind.on")
        // Unset is off.
        #expect(await mindSwitch.follow() == false)
        #expect(await hub.snapshot().phase == .off)

        // Kept on before the launch: the launch's follow starts the mind.
        #expect(try defaults("write", domain, "mind.on", "-bool", "true") == 0)
        #expect(await mindSwitch.follow())
        #expect(await eventually { await hub.snapshot().holds })
        try await h.phoneSays("hello")
        #expect(try await eventually { try await h.replies().count == 1 })
        let pid = try #require(await hub.pid)

        // Off, from another process: the next follow stops it, process and lease.
        #expect(try defaults("write", domain, "mind.on", "-bool", "false") == 0)
        #expect(await mindSwitch.follow() == false)
        #expect(await hub.snapshot().phase == .off)
        #expect(await hub.snapshot().holds == false)
        #expect(gone(pid))

        // The menu's set is kept where another process reads it.
        await mindSwitch.set(true)
        let read = Process()
        read.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        read.arguments = ["read", domain, "mind.on"]
        let out = Pipe()
        read.standardOutput = out
        try read.run()
        read.waitUntilExit()
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        #expect(await eventually { await hub.snapshot().holds })
        await hub.turnOff()
    }

    @Test func theRealStoreHasNoSmokeTestControls() {
        let every = ["TOPO_HUB_CLAUDE": "/tmp/fake", "TOPO_HUB_LIMB_SAYS": "hello", "TOPO_HUB_SILENCE": "2",
                     "TOPO_HUB_MIND": "on"]
        let real = HubLaunch(environment: every, entitled: true)
        #expect(real.store == .cloudKit)
        #expect(real.controls == nil)
        #expect(real.switchKey == "mind.on")

        let memory = HubLaunch(environment: every.merging(["TOPO_STORE": "memory"]) { $1 }, entitled: true)
        #expect(memory.store == .memory)
        #expect(memory.controls == .init(claude: URL(fileURLWithPath: "/tmp/fake"), limbSays: "hello", silence: .seconds(2)))
        #expect(memory.switchKey != real.switchKey)

        let unsigned = HubLaunch(environment: [:], entitled: false)
        #expect(unsigned.store == .memory)
        #expect(unsigned.controls == .init(claude: nil, limbSays: nil, silence: nil))
    }

    @Test func theStatusSaysNoWordOfATurn() async throws {
        let h = try HubRig()
        let hub = h.hub()
        await hub.turnOn()
        #expect(await eventually { await hub.snapshot().holds })
        try await h.phoneSays("octarine is the colour of magic")
        #expect(try await eventually { try await h.replies().count == 1 })
        let root = h.rig.root.appending(path: "status")
        try HubStatus(pid: getpid(), store: .memory, on: true, snapshot: await hub.snapshot(),
                      leaseHolder: h.hubID.rawValue).write(in: root)
        let text = try String(contentsOf: root.appending(path: HubStatus.fileName), encoding: .utf8)
        #expect(!text.contains("octarine"))
        #expect(!text.contains("magic"))
        let status = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(status["phase"] as? String == "answering")
        #expect(status["login"] as? String == "signed in (claude.ai, max)")
        #expect(status["holds"] as? Bool == true)
        #expect((status["lastPass"] as? String)?.hasPrefix("answered by ") == true)
        await hub.turnOff()
    }

    @Test func theStatusSaysNoReasonClaudeCodeGave() async throws {
        let h = try HubRig(["FAKE_DIE": "1", "FAKE_DIE_SAYS": "words of claude's own"])
        let hub = h.hub()
        await hub.turnOn()
        #expect(await eventually { if case .stopped(.notStarted) = await hub.snapshot().phase { true } else { false } })
        let snapshot = await hub.snapshot()
        // The menu says why; the status a shell reads says only that it failed.
        #expect(snapshot.mind.contains("words of claude's own"))
        let root = h.rig.root.appending(path: "status")
        try HubStatus(pid: getpid(), store: .memory, on: true, snapshot: snapshot, leaseHolder: nil).write(in: root)
        let text = try String(contentsOf: root.appending(path: HubStatus.fileName), encoding: .utf8)
        #expect(!text.contains("claude's own"))
        #expect(text.contains("stopped notStarted"))
        #expect(text.contains("the last start failed"))
        await hub.turnOff()
    }

    @Test func aKilledHubsMindAndWhatItStartedDieWithIt() async throws {
        let rig = try Rig(["FAKE_CHILD": "1"])
        let process = try MindProcess(executable: rig.claude.path,
                                      arguments: NativeBrain.arguments(model: "m", resume: nil, permissionMode: "auto"),
                                      environment: NativeBrain.environment(for: .init(workingDirectory: rig.work,
                                                                                      configDirectory: rig.config,
                                                                                      environment: rig.environment)),
                                      directory: rig.work.path, lifeline: true)
        #expect(await eventually { rig.lines("children.jsonl").count == 1 })
        let children = try #require(rig.lines("children.jsonl").first?["pids"] as? [Int32])
        let watcher = try #require(process.watcherPID)
        // A turn under way: Claude Code would carry it to its end with its stdin closed.
        try await process.write(MindStream.userTurn("HANG hello", id: "a"))
        #expect(await eventually { rig.inputs.contains("HANG hello") })
        // What the hub's death does to the lifeline: its write end closes.
        process.cutLifeline()
        #expect(await eventually(5) { gone(process.pid) && children.allSatisfy(gone) })
        #expect(await eventually(5) { gone(watcher) })
    }

    @Test func aTornDownMindsWatcherGoesWithItAndDoesNothing() async throws {
        let rig = try Rig()
        let brain = rig.brain()
        try await brain.start()
        let pid = try #require(await brain.pid)
        let watcher = try #require(await brain.watcherPID)
        #expect(MindProcess.alive(watcher))
        #expect(await brain.shutdown())
        #expect(gone(pid))
        #expect(await eventually(5) { gone(watcher) })
    }

    @Test func aResidentAnEarlierHubLeftIsReapedBeforeTheNextStarts() async throws {
        let rig = try Rig()
        let first = rig.brain()
        try await first.start()
        let left = try #require(await first.pid)
        // A second launch over the same home, the first never torn down: as after a crash.
        let second = rig.brain()
        try await second.start()
        let now = try #require(await second.pid)
        #expect(now != left)
        #expect(gone(left))
        #expect(await second.shutdown())

        // A record naming a process that is not the one it was written for is left alone.
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["30"]
        try other.run()
        defer { other.terminate() }
        let record = #"{"pid": \#(other.processIdentifier), "started": "1.0"}"#
        try Data(record.utf8).write(to: rig.config.appending(path: "resident.json"))
        let third = rig.brain()
        try await third.start()
        #expect(MindProcess.alive(other.processIdentifier))
        #expect(await third.shutdown())
    }
}
