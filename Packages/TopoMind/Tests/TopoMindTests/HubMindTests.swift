import Foundation
import Testing
import TopoCore
import TopoCoreTesting
import TopoTurn
@testable import TopoMind

/// A probe that confirms every holder: `acquire()` never claims over a live lease with it, so the
/// only way the hub can take a fresh lease from the phone is `takeOver()`.
struct Confirming: LeaseProbe {
    func confirms(_ lease: Lease) async -> Bool { true }
}

/// Short leases, so a lapse is seconds and not tens of them.
let fast = LeaseTiming(duration: 2, heartbeat: 0.5)

/// Reads of the log that a test can hold, counting how many are in flight at once.
final class GatedReads: ForwardingDatabase, @unchecked Sendable {
    let base: any RecordDatabase
    private let lock = NSLock()
    private var closed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inFlight = 0
    private(set) var most = 0
    private(set) var held = 0

    init(_ base: any RecordDatabase) { self.base = base }

    func close() { lock.withLock { closed = true } }

    func open() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            closed = false
            defer { waiters = [] }
            return waiters
        }
        resumed.forEach { $0.resume() }
    }

    var holding: Int { lock.withLock { held } }
    var mostAtOnce: Int { lock.withLock { most } }

    func records(ofType type: String, through base: any RecordDatabase) async throws -> [Record] {
        guard type == Turn.recordType else { return try await base.records(ofType: type) }
        lock.withLock {
            inFlight += 1
            most = max(most, inFlight)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if closed {
                held += 1
                waiters.append(continuation)
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
        defer { lock.withLock { inFlight -= 1 } }
        return try await base.records(ofType: type)
    }
}

/// The hub's side and the phone's, over one in-memory store.
struct HubRig {
    let rig: Rig
    let db = InMemoryRecordDatabase()
    let hubID = DeviceID("mac-" + UUID().uuidString.lowercased())
    let phoneID = DeviceID("phone-1a2b3c4d")
    let brain: NativeBrain

    init(_ environment: [String: String] = [:], silence: Duration = NativeBrain.standardSilence,
         turn: Duration = NativeBrain.standardTurn) throws {
        rig = try Rig(environment)
        brain = rig.brain(silence: silence, turn: turn)
    }

    var configuration: NativeBrain.Configuration {
        NativeBrain.Configuration(workingDirectory: rig.work, configDirectory: rig.config, claude: rig.claude,
                                  environment: rig.environment)
    }

    func hub(over database: (any RecordDatabase)? = nil, poll: Duration = .milliseconds(100)) -> HubMind {
        let configuration = self.configuration
        return HubMind(database: database ?? db, device: hubID, endpoint: "127.0.0.1:1", probe: Confirming(),
                       brain: brain, login: { await MindLogin.check(configuration) },
                       model: { .sonnet }, timing: fast, poll: poll)
    }

    /// The phone holding the lease, renewing it every half second.
    func phoneHoldingLease() async throws -> PrimaryLease {
        let lease = PrimaryLease(database: db, device: phoneID, endpoint: nil, probe: NoSocketProbe(), timing: fast)
        guard case .primary = try await lease.acquire() else { throw CancellationError() }
        return lease
    }

    /// A limb's turn: the phone's words, written to the log for the primary to answer.
    @discardableResult
    func phoneSays(_ text: String) async throws -> Turn {
        let log = TurnLog(database: db)
        let writer = try await log.writer(for: phoneID)
        return try await writer.append(.person, text, continuing: try await log.read())
    }

    func lease() async -> Lease? { await db.current(Lease.recordID).flatMap(Lease.init(record:)) }
    func leaseTag() async -> String? { await db.current(Lease.recordID)?.changeTag }

    func replies() async throws -> [Turn] {
        try await TurnLog(database: db).read().ordered.filter { $0.role == .assistant }
    }
}

func eventually(_ seconds: Double = 15, _ condition: () async throws -> Bool) async rethrows -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return try await condition()
}

@Suite(.serialized) struct HubMindTests {
    @Test func offClaimsNothingAndRunsNothing() async throws {
        let h = try HubRig()
        let hub = h.hub()
        try await h.phoneSays("hello")
        try await Task.sleep(for: .seconds(1))
        #expect(await h.lease() == nil)
        #expect(try await h.replies().isEmpty)
        #expect(h.rig.launches.isEmpty)
        #expect(await hub.snapshot().phase == .off)
        #expect(await hub.snapshot().passes == 0)
    }

    @Test func signedOutAtTheSwitchClaimsNothingAndSaysSo() async throws {
        let h = try HubRig(["FAKE_LOGIN_SIGNED_OUT": "1"])
        let hub = h.hub()
        try await h.phoneSays("hello")
        await hub.turnOn()
        #expect(await eventually { await hub.snapshot().phase == .stopped(.signedOut) })
        try await Task.sleep(for: .seconds(0.5))
        #expect(await h.lease() == nil)
        #expect(h.rig.launches.isEmpty)
        #expect(await hub.snapshot().login == .signedOut)
        await hub.turnOff()
    }

    @Test func onTakesOverOnceAnswersALimbAndNeverTakesBackOnATimer() async throws {
        let h = try HubRig()
        let phone = try await h.phoneHoldingLease()
        let hub = h.hub()
        await hub.turnOn()
        // The phone's lease was fresh, and the probe confirms it: only the takeover moves it.
        #expect(await eventually { await h.lease()?.holder == h.hubID })
        #expect(await hub.snapshot().takeovers == 1)

        let first = try await h.phoneSays("hello")
        #expect(try await eventually { try await h.replies().count == 1 })
        let reply = try #require(try await h.replies().first)
        #expect(reply.text == "echo: hello")
        #expect(reply.parents == [first.ref])
        #expect(reply.ref.device == h.hubID)

        // A second turn: answered by the same process, with no second takeover.
        try await h.phoneSays("again")
        #expect(try await eventually { try await h.replies().count == 2 })
        #expect(await hub.snapshot().takeovers == 1)
        #expect(h.rig.launches.count == 1)

        // The phone claims the lease back (as a build that does not yield would). The hub yields
        // at its next heartbeat and asks for the lease before each pass; it does not take it.
        guard case .primary = try await phone.takeOver() else { Issue.record("the phone's claim"); return }
        let claimed = try #require(await h.lease())
        try await h.phoneSays("the phone's now")
        try await Task.sleep(for: .seconds(1.5))
        let after = try #require(await h.lease())
        #expect(after.holder == h.phoneID)
        #expect(after.epoch == claimed.epoch)
        #expect(try await h.replies().count == 2)
        #expect(await hub.snapshot().takeovers == 1)
        #expect(await hub.snapshot().holds == false)

        await phone.abandon()
        await hub.turnOff()
    }

    @Test func offMidPassWritesNoReplyAndTheProcessIsGone() async throws {
        let h = try HubRig()
        let hub = h.hub()
        await hub.turnOn()
        #expect(await eventually { await hub.snapshot().holds })
        try await h.phoneSays("SLOW hello")
        // The fake has the words and takes 1.5 s to answer them.
        #expect(await eventually { h.rig.inputs.contains("SLOW hello") })
        let pid = try #require(await hub.pid)
        await hub.turnOff()
        #expect(gone(pid))
        #expect(await hub.pid == nil)
        #expect(await hub.snapshot().phase == .off)
        #expect(await hub.snapshot().holds == false)
        // Past the fake's answer, and past the lease's lapse: nothing was written, nothing renewed.
        let tag = await h.leaseTag()
        try await Task.sleep(for: .seconds(2.5))
        #expect(try await h.replies().isEmpty)
        #expect(await h.leaseTag() == tag)
    }

    @Test func sleepStopsRenewalsAndWakeTakesOverOnce() async throws {
        let h = try HubRig()
        let hub = h.hub()
        await hub.turnOn()
        #expect(await eventually { await hub.snapshot().holds })
        #expect(await hub.snapshot().takeovers == 1)

        await hub.willSleep()
        #expect(await hub.snapshot().phase == .asleep)
        let tag = await h.leaseTag()
        // Three heartbeats' worth: the record does not move.
        try await Task.sleep(for: .seconds(1.5))
        #expect(await h.leaseTag() == tag)
        #expect(await hub.snapshot().holds == false)

        // The phone answers meanwhile: it claims the lapsed lease and renews it.
        #expect(await eventually { await h.lease()?.isExpired(at: Date()) == true })
        let phone = try await h.phoneHoldingLease()
        #expect(await h.lease()?.holder == h.phoneID)

        await hub.didWake()
        #expect(await eventually { await h.lease()?.holder == h.hubID })
        #expect(await hub.snapshot().takeovers == 2)
        try await h.phoneSays("good morning")
        #expect(try await eventually { try await h.replies().count == 1 })
        try await Task.sleep(for: .seconds(1))
        #expect(await hub.snapshot().takeovers == 2)

        await phone.abandon()
        await hub.turnOff()
    }

    @Test func notSignedInStopsTheLoopAndLetsTheLeaseGo() async throws {
        // `auth status` says signed in; the turn finds the login gone, as an expired one would.
        let h = try HubRig(["FAKE_SIGNED_OUT": "1"])
        let hub = h.hub()
        await hub.turnOn()
        #expect(await eventually { await hub.snapshot().holds })
        let pid = try #require(await hub.pid)
        try await h.phoneSays("hello")
        #expect(await eventually { await hub.snapshot().phase == .stopped(.signedOut) })
        #expect(await hub.snapshot().holds == false)
        #expect(await hub.snapshot().login == .signedOut)
        #expect(gone(pid))
        let passes = await hub.snapshot().passes
        let tag = await h.leaseTag()
        try await Task.sleep(for: .seconds(1.5))
        #expect(await h.leaseTag() == tag)
        #expect(await hub.snapshot().passes == passes)
        #expect(try await h.replies().isEmpty)
        // The lease lapses, and the phone takes it.
        #expect(await eventually { await h.lease()?.isExpired(at: Date()) == true })
        let phone = try await h.phoneHoldingLease()
        #expect(await h.lease()?.holder == h.phoneID)
        await phone.abandon()
        await hub.turnOff()
    }

    @Test func triggersAtOnceRunOnePassAndNeverTwoTogether() async throws {
        let h = try HubRig()
        let gated = GatedReads(h.db)
        // No poll to speak of: only triggers run a pass.
        let hub = h.hub(over: gated, poll: .seconds(3600))
        await hub.turnOn()
        #expect(await eventually { let s = await hub.snapshot(); return s.passes == 1 && s.lastPass != nil })

        gated.close()
        await hub.trigger(.push)
        #expect(await eventually { gated.holding == 1 })
        // Two at once, while that pass is held reading the log.
        async let a: Void = hub.trigger(.push)
        async let b: Void = hub.trigger(.push)
        _ = await (a, b)
        try await Task.sleep(for: .milliseconds(300))
        #expect(gated.holding == 1)
        gated.open()
        // The held pass, and one more for the two that came while it ran.
        #expect(await eventually { await hub.snapshot().passes == 3 })
        try await Task.sleep(for: .milliseconds(500))
        #expect(await hub.snapshot().passes == 3)
        #expect(gated.mostAtOnce == 1)

        // Two at once while the loop waits: one pass.
        async let c: Void = hub.trigger(.push)
        async let d: Void = hub.trigger(.poll)
        _ = await (c, d)
        #expect(await eventually { await hub.snapshot().passes >= 4 })
        try await Task.sleep(for: .milliseconds(500))
        #expect(await hub.snapshot().passes == 4)
        #expect(gated.mostAtOnce == 1)
        await hub.turnOff()
    }

    @Test func theHomeExcludesEveryMemoryFileAboveIt() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "topo-home-\(UUID().uuidString)")
        let work = root.appending(path: "a/home"), config = root.appending(path: "a/claude")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data(#"{"model": "x", "claudeMdExcludes": ["/kept"]}"#.utf8).write(to: config.appending(path: "settings.json"))
        try MindHome.prepare(work: work, config: config)
        #expect(FileManager.default.fileExists(atPath: work.path))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: config.appending(path: "settings.json"))) as? [String: Any])
        #expect(object["model"] as? String == "x")
        let excludes = try #require(object["claudeMdExcludes"] as? [String])
        #expect(excludes.first == "/kept")
        let above = root.appending(path: "a").standardizedFileURL.path
        #expect(excludes.contains("\(above)/CLAUDE.md"))
        #expect(excludes.contains("\(above)/.claude/CLAUDE.md"))
        #expect(excludes.contains("/CLAUDE.md"))
        #expect(!excludes.contains { $0.hasPrefix(work.standardizedFileURL.path + "/") })
        // Again: nothing added twice.
        try MindHome.prepare(work: work, config: config)
        let again = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: config.appending(path: "settings.json"))) as? [String: Any])
        #expect((again["claudeMdExcludes"] as? [String])?.count == excludes.count)
        // A file that is not an object is the person's, and is left alone.
        try Data("not json".utf8).write(to: config.appending(path: "settings.json"))
        #expect(throws: MindHome.Unreadable.self) { try MindHome.prepare(work: work, config: config) }
    }

    @Test func theLoginIsAskedOfTheMindsOwnConfig() async throws {
        let h = try HubRig()
        #expect(await MindLogin.check(h.configuration) == .signedIn("claude.ai, max"))
        let asked = try #require(h.rig.lines("auth.jsonl").first)
        #expect(asked["config"] as? String == h.rig.config.path)
        let out = try HubRig(["FAKE_LOGIN_SIGNED_OUT": "1"])
        #expect(await MindLogin.check(out.configuration) == .signedOut)
    }
}
