import AVFoundation
import Foundation
import TopoTools
import UIKit
import XCTest

@testable import Topo

/// AlarmKit's permission where the test puts it, counting its prompts.
private final class AlarmPermission: ThrowingPrompt, @unchecked Sendable {
    let name = "Alarms"
    private let lock = NSLock()
    private var standing: Access
    private let answer: Bool
    private var _prompts = 0

    /// Called as the prompt goes up: where a test makes the app inactive, as a system alert does.
    var onPrompt: @Sendable () async -> Void = {}
    /// Called as the standing is read: where a test sends the app to the background after the
    /// broker's read and before its prompt.
    var onAccess: @Sendable () async -> Void = {}
    /// Where set, the prompt stays up until the test opens it.
    var gate: Gate?
    /// Where set, the request throws this with the standing left as it was.
    var failure: (any Error)?
    /// Where set, a no at the prompt leaves the standing undetermined and the request returns it so.
    var keepsNothing = false
    /// Where set, the request returns its answer while the standing still reads undetermined.
    var lags = false

    init(_ standing: Access, answer: Bool = true) {
        self.standing = standing
        self.answer = answer
    }

    var prompts: Int { lock.withLock { _prompts } }
    var reads: Int { lock.withLock { _reads } }
    private var _reads = 0
    func access() async -> Access {
        await onAccess()
        return lock.withLock { _reads += 1; return standing }
    }
    func request() async -> Bool {
        await onPrompt()
        if let gate {
            await gate.wait()
        } else {
            // A prompt stays up a moment, so a second call made meanwhile finds it up.
            try? await Task.sleep(for: .milliseconds(50))
        }
        return lock.withLock {
            _prompts += 1
            if !lags, answer || !keepsNothing { standing = answer ? .granted : .denied }
            return answer
        }
    }
    func prompt() async throws -> Access {
        if let failure {
            lock.withLock { _prompts += 1 }
            throw failure
        }
        let granted = await request()
        return granted ? .granted : (keepsNothing ? .undetermined : .denied)
    }
}

private final class FakeAlarms: AlarmScheduler, @unchecked Sendable {
    private let lock = NSLock()
    let permission: any Authorizer
    private var scheduled: [(id: UUID, plan: TimerPlan)] = []
    private var states: [UUID: TimerStatus.State] = [:]
    private(set) var acts: [(TimerTool.Act, UUID)] = []
    /// An act AlarmKit refuses.
    var actFails = false
    /// What a schedule throws, where set.
    var scheduleThrows: (any Error)?
    /// Where set, a schedule waits here, having said so in `scheduling`.
    var scheduleGate: Gate?
    private(set) var scheduling = false
    /// Where set, a list read waits here once it has read, having said so in `listing`.
    var alarmsGate: Gate?
    private(set) var listing = false
    /// What the Live Activity says, per alarm.
    var fires: [UUID: Date] = [:]
    var left: [UUID: TimeInterval] = [:]

    init(_ permission: any Authorizer) { self.permission = permission }

    var authorizer: any Authorizer { permission }
    var count: Int { lock.withLock { scheduled.count } }
    var last: TimerPlan? { lock.withLock { scheduled.last?.plan } }
    func set(_ id: UUID, _ state: TimerStatus.State) { lock.withLock { states[id] = state } }
    /// An alarm AlarmKit holds in `state`, set by no tool.
    func holds(_ id: UUID, _ state: TimerStatus.State) {
        lock.withLock {
            if !scheduled.contains(where: { $0.id == id }) {
                scheduled.append((id, TimerPlan(when: .after(60), label: "Timer", title: "Timer", pausedTitle: "Timer",
                                                buttonColor: .token(.onPrimary), tint: .token(.primary))))
            }
            states[id] = state
        }
    }

    func schedule(id: UUID, plan: TimerPlan) async throws {
        if let scheduleThrows { throw scheduleThrows }
        if let scheduleGate {
            lock.withLock { scheduling = true }
            await scheduleGate.wait()
        }
        lock.withLock {
            scheduled.append((id, plan))
            if case .after = plan.when { states[id] = .counting } else { states[id] = .set }
        }
    }
    /// What a list throws, where set.
    var alarmsThrow: (any Error)?
    func alarms() async throws -> [TimerStatus] {
        if let alarmsThrow { throw alarmsThrow }
        let read = read()
        if let alarmsGate {
            lock.withLock { listing = true }
            await alarmsGate.wait()
        }
        return read
    }
    private func read() -> [TimerStatus] {
        lock.withLock {
            scheduled.map { alarm in
                var when: TimerPlan.When?
                if case .after = alarm.plan.when {} else { when = alarm.plan.when }
                return TimerStatus(id: alarm.id, state: states[alarm.id] ?? .unknown, when: when, fires: fires[alarm.id], left: left[alarm.id])
            }
        }
    }
    private func act(_ act: TimerTool.Act, _ id: UUID, _ change: () -> Void) throws {
        if actFails { throw CocoaError(.featureUnsupported) }
        lock.withLock {
            acts.append((act, id))
            change()
        }
    }
    func pause(id: UUID) async throws { try act(.pause, id) { states[id] = .paused } }
    func resume(id: UUID) async throws { try act(.resume, id) { states[id] = .counting } }
    func again(id: UUID) async throws { try act(.again, id) { states[id] = .counting } }
    func stop(id: UUID) async throws { try act(.stop, id) { states[id] = .set } }
    func cancel(id: UUID) async throws { try act(.cancel, id) { scheduled.removeAll { $0.id == id } } }
}

@MainActor
final class TimerToolTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_793_000_000)

    private var root: URL!
    private var records: TimerRecords { TimerRecords(folder: root.appendingPathComponent("Timers")) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("timers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let utc = TimeZone(identifier: "UTC")!

    private func tool(_ alarms: FakeAlarms, state: AppState = AppState(.active), records: TimerRecords? = nil,
                      login: String? = "login-1", now: Date? = nil) -> TimerTool {
        let start = now ?? start
        let counter = Counter()
        var tool = TimerTool(scheduler: alarms, records: records ?? self.records, broker: PermissionBroker(), state: { state.value },
                             now: { start }, makeID: { counter.next() })
        tool.zone = Self.utc
        tool.login = { login }
        tool.hasSymbol = { !$0.hasPrefix("no.") }
        tool.sounds = TimerSounds(home: root.appendingPathComponent("home"), folder: root.appendingPathComponent("Sounds"))
        return tool
    }

    /// A second start made while the first one's prompt is up, with Topo inactive under it as a
    /// system alert leaves it, joins that prompt in the broker and waits on it.
    func testAStartUnderThePromptWaitsOnIt() async {
        let permission = AlarmPermission(.undetermined)
        let gate = Gate()
        permission.gate = gate
        let state = AppState(.active)
        let raised = Raised()
        permission.onPrompt = { @MainActor in state.value = .inactive; raised.up = true }
        let alarms = FakeAlarms(permission)
        let tool = tool(alarms, state: state)
        let done = Raised()
        let first = Task { await tool.run(["1m"]) }
        guard await within({ raised.up }) else { return XCTFail("no prompt went up") }
        let second = Task { @MainActor in
            let reply = await tool.run(["2m"])
            done.up = true
            return reply
        }
        // The second start has read the permission, so it is at the broker, under the prompt: it
        // sets nothing and is not answered until the prompt is.
        guard await within({ permission.reads >= 2 }) else { return XCTFail("the second start never read the permission") }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(done.up)
        XCTAssertEqual(alarms.count, 0)
        await gate.open()
        let replies = [await first.value, await second.value]
        XCTAssertEqual(replies.map(\.status), [ToolReply.ok, ToolReply.ok], replies.map(\.text).joined())
        XCTAssertEqual(permission.prompts, 1)
        XCTAssertEqual(alarms.count, 2)
    }

    /// Where a new prompt would be raised, Topo in the background asks nothing; under an alert
    /// (inactive) or in front it asks.
    func testOnScreenRaisesNoPromptInTheBackground() async {
        for (state, prompts) in [(UIApplication.State.background, 0), (.inactive, 1), (.active, 1)] {
            let permission = AlarmPermission(.undetermined)
            let asked = await TimerTool.OnScreen(alarms: permission, state: { state }, asked: TimerTool.Asked()).request()
            XCTAssertEqual(asked, prompts == 1, "\(state.rawValue)")
            XCTAssertEqual(permission.prompts, prompts, "\(state.rawValue)")
        }
        // Granted meanwhile by another call's prompt: a yes, asking nothing.
        let granted = AlarmPermission(.granted)
        let yes = await TimerTool.OnScreen(alarms: granted, state: { .background }, asked: TimerTool.Asked()).request()
        XCTAssertTrue(yes)
        XCTAssertEqual(granted.prompts, 0)
    }

    /// Starts in the background at once, some of which join another's declined prompt in the
    /// broker (how many is the scheduler's), are each told to open Topo, never sent to Settings.
    func testStartsInTheBackgroundAtOnceAreEachSaidAsOffScreen() async {
        for _ in 0..<50 {
            let permission = AlarmPermission(.undetermined)
            let tool = tool(FakeAlarms(permission), state: AppState(.background))
            async let a = tool.run(["1m"])
            async let b = tool.run(["2m"])
            async let c = tool.run(["3m"])
            let replies = await [a, b, c]
            XCTAssertEqual(replies, Array(repeating: TimerTool.offScreen, count: 3), replies.map(\.text).joined())
            XCTAssertEqual(permission.prompts, 0)
        }
    }

    /// Codex on #592, as Sam ruled it: a start asked for in front whose Topo went to the background
    /// before its prompt could go up asks nothing and says so, not as a refusal and not as a start
    /// made in the background.
    func testAStartBackgroundedBeforeItsPromptSaysSo() async {
        let permission = AlarmPermission(.undetermined)
        let state = AppState(.active)
        permission.onAccess = { @MainActor in state.value = .background }
        let alarms = FakeAlarms(permission)
        let reply = await tool(alarms, state: state).run(["1m"])
        XCTAssertEqual(reply, TimerTool.leftBeforeThePrompt, reply.text)
        XCTAssertEqual(permission.prompts, 0)
        XCTAssertEqual(alarms.count, 0)
    }

    /// Codex on #592: with Topo in front throughout, a request AlarmKit throws on is said as that
    /// failure, never as Topo having gone to the background, nor as a refusal.
    func testAPromptThatThrowsIsSaidAsItsFailure() async {
        let permission = AlarmPermission(.undetermined)
        permission.failure = CocoaError(.featureUnsupported)
        let alarms = FakeAlarms(permission)
        let reply = await tool(alarms).run(["1m"])
        XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
        XCTAssertTrue(reply.text.contains("request to allow alarms failed"), reply.text)
        XCTAssertTrue(reply.text.contains(CocoaError(.featureUnsupported).localizedDescription), reply.text)
        XCTAssertFalse(reply.text.contains("background"), reply.text)
        XCTAssertEqual(alarms.count, 0)
    }

    /// A request that returns the standing undetermined, with Topo in front throughout, is said as
    /// a prompt that kept no answer, never as the background or a refusal.
    func testAPromptThatKeepsNoAnswerIsSaidAsThat() async {
        let permission = AlarmPermission(.undetermined, answer: false)
        permission.keepsNothing = true
        let alarms = FakeAlarms(permission)
        let reply = await tool(alarms).run(["1m"])
        XCTAssertEqual(reply, TimerTool.promptUnanswered, reply.text)
        XCTAssertEqual(permission.prompts, 1)
        XCTAssertEqual(alarms.count, 0)
    }

    /// A refusal whose standing still reads undetermined after the prompt is the person's no, said
    /// as a refusal (status 5), never as a prompt that kept no answer.
    func testARefusalTheStandingLagsIsStillARefusal() async {
        let permission = AlarmPermission(.undetermined, answer: false)
        permission.lags = true
        let alarms = FakeAlarms(permission)
        let reply = await tool(alarms).run(["1m"])
        XCTAssertEqual(reply.status, ToolReply.denied, reply.text)
        XCTAssertTrue(reply.text.contains("Apps › Topo › Alarms"), reply.text)
        XCTAssertEqual(alarms.count, 0)
    }

    func testAScheduleFailureIsSaidAndNothingKept() async {
        let alarms = FakeAlarms(AlarmPermission(.granted))
        alarms.scheduleThrows = CocoaError(.featureUnsupported)
        let reply = await tool(alarms).run(["5m"])
        XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
        XCTAssertTrue(reply.text.contains("did not set it"), reply.text)
        XCTAssertNil(records.read(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
    }

    func testTheAlarmLimitIsSaidAndNothingKept() async {
        let alarms = FakeAlarms(AlarmPermission(.granted))
        alarms.scheduleThrows = AlarmLimit()
        let reply = await tool(alarms).run(["5m", "Tea"])
        XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
        XCTAssertTrue(reply.text.contains(AlarmLimit().reason), reply.text)
        XCTAssertEqual(alarms.count, 0)
        XCTAssertNil(records.read(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
    }

    /// A countdown drawn past its fire date is at zero, never a reversed range.
    func testTheCountdownRangeIsNeverReversed() {
        let now = start
        XCTAssertEqual(AlarmCountdown.range(now: now, fires: now.addingTimeInterval(-5)), now...now)
        XCTAssertEqual(AlarmCountdown.range(now: now, fires: now), now...now)
        XCTAssertEqual(AlarmCountdown.range(now: now, fires: now.addingTimeInterval(60)), now...now.addingTimeInterval(60))
    }

    func testACancelAlarmKitRefusesIsNotSaidAsNoSuchTimer() async {
        let alarms = FakeAlarms(AlarmPermission(.granted))
        let tool = tool(alarms)
        _ = await tool.run(["10m"])
        alarms.actFails = true
        let reply = await tool.run(["cancel", "00000000-0000-0000-0000-000000000001"])
        XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
        XCTAssertTrue(reply.text.contains("may still sound"), reply.text)
        XCTAssertEqual(alarms.count, 1)
    }

    /// The usage the mind reads names no iOS older than the one every install runs.
    func testUsageNamesNoOlderIOS() {
        let usage = tool(FakeAlarms(AlarmPermission(.granted))).usage
        XCTAssertTrue(usage.contains("status 5"), usage)
        XCTAssertFalse(usage.contains("iOS"), usage)
    }

    func testAWhitespaceLabelIsRefused() async {
        let alarms = FakeAlarms(AlarmPermission(.granted))
        let reply = await tool(alarms).run(["5m", "   "])
        XCTAssertEqual(reply.status, ToolReply.usage, reply.text)
        XCTAssertEqual(alarms.count, 0)
    }

    func testAGrantedStartSetsOneAlarmAndSaysWhenItSounds() async {
        let alarms = FakeAlarms(AlarmPermission(.granted))
        let reply = await tool(alarms).run(["15m", "Tea"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertEqual(alarms.count, 1)
        XCTAssertEqual(alarms.last?.label, "Tea")
        XCTAssertEqual(alarms.last?.when, .after(900))
        XCTAssertTrue(reply.text.hasPrefix("set: 00000000-0000-0000-0000-000000000001"), reply.text)
        XCTAssertTrue(reply.text.contains("sounds at " + ToolDates.write(start.addingTimeInterval(900), in: Self.utc)), reply.text)
    }

    func testANoLabelIsTimer() async {
        let alarms = FakeAlarms(AlarmPermission(.granted))
        _ = await tool(alarms).run(["90s"])
        XCTAssertEqual(alarms.last?.label, "Timer")
    }

    func testSpanBounds() async {
        let alarms = FakeAlarms(AlarmPermission(.granted))
        let tool = tool(alarms)
        for span in ["0s", "0.5s", "25h", "soon", "86401s"] {
            let reply = await tool.run([span])
            XCTAssertEqual(reply.status, ToolReply.usage, "\(span): \(reply.text)")
        }
        XCTAssertEqual(alarms.count, 0)
        for span in ["1s", "24h"] {
            let reply = await tool.run([span])
            XCTAssertEqual(reply.status, ToolReply.ok, "\(span): \(reply.text)")
        }
        XCTAssertEqual(alarms.count, 2)
    }

    /// Judged as written: a label that trimming or joining its lines would bring to 40 is still past it.
    func testALabelOver40IsRefusedNotCut() async {
        let alarms = FakeAlarms(AlarmPermission(.granted))
        let x40 = String(repeating: "x", count: 40)
        for label in [String(repeating: "x", count: 41), " " + x40, "x\n\n" + String(repeating: "x", count: 38)] {
            let reply = await tool(alarms).run(["5m", label])
            XCTAssertEqual(reply.status, ToolReply.usage, "\(label.debugDescription): \(reply.text)")
        }
        XCTAssertEqual(alarms.count, 0)
        for label in [x40, " " + String(repeating: "x", count: 39)] {
            let fits = await tool(alarms).run(["5m", label])
            XCTAssertEqual(fits.status, ToolReply.ok, fits.text)
        }
        XCTAssertEqual(alarms.last?.label, String(repeating: "x", count: 39))
    }

    func testAuthorisationIsAskedAtTheCallAndOnce() async {
        let permission = AlarmPermission(.undetermined)
        let alarms = FakeAlarms(permission)
        let tool = tool(alarms)
        async let first = tool.run(["1m"])
        async let second = tool.run(["2m"])
        let replies = await [first, second]
        XCTAssertEqual(replies.map(\.status), [ToolReply.ok, ToolReply.ok], replies.map(\.text).joined())
        XCTAssertEqual(permission.prompts, 1)
        XCTAssertEqual(alarms.count, 2)
    }

    func testAParseErrorAndListAndCancelAskNothing() async {
        let permission = AlarmPermission(.undetermined)
        let tool = tool(FakeAlarms(permission))
        _ = await tool.run(["soon"])
        _ = await tool.run(["list"])
        _ = await tool.run(["cancel", "00000000-0000-0000-0000-000000000009"])
        XCTAssertEqual(permission.prompts, 0)
    }

    func testUndeterminedOffScreenAsksNothingAndSaysToOpenTopo() async {
        let permission = AlarmPermission(.undetermined)
        let alarms = FakeAlarms(permission)
        let reply = await tool(alarms, state: AppState(.background)).run(["1m"])
        XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
        XCTAssertTrue(reply.text.contains("open Topo"), reply.text)
        XCTAssertEqual(permission.prompts, 0)
        XCTAssertEqual(alarms.count, 0)
        // Allowed already, a start off the screen sets its alarm.
        let allowed = FakeAlarms(AlarmPermission(.granted))
        let set = await tool(allowed, state: AppState(.background)).run(["1m"])
        XCTAssertEqual(set.status, ToolReply.ok, set.text)
        XCTAssertEqual(allowed.count, 1)
        XCTAssertEqual(allowed.last?.when, .after(60))
        XCTAssertEqual(allowed.last?.label, "Timer")
    }

    /// Refused at the prompt or before (AlarmKit has no restricted state), nothing is set and nothing stands in for it: the reply
    /// says where alarms are allowed.
    func testARefusalSetsNothingAndSaysWhereToAllowIt() async {
        let cases = [(AlarmPermission(.denied), AppState(.active)), (AlarmPermission(.undetermined, answer: false), AppState(.active)),
                     (AlarmPermission(.denied), AppState(.background))]
        for (permission, state) in cases {
            let alarms = FakeAlarms(permission)
            let reply = await tool(alarms, state: state).run(["1m"])
            XCTAssertEqual(reply.status, ToolReply.denied, reply.text)
            XCTAssertTrue(reply.text.contains("Apps › Topo › Alarms"), reply.text)
            XCTAssertFalse(reply.text.contains("sounds"), reply.text)
            XCTAssertEqual(alarms.count, 0)
        }
    }

    /// The label and the time are the record's, on disk, so a relaunch still lists them; the
    /// Live Activity's time wins where AlarmKit has one.
    func testListSaysLabelAndTimeAcrossARelaunch() async {
        let alarms = FakeAlarms(AlarmPermission(.granted))
        let tool = tool(alarms)
        _ = await tool.run(["10m", "Eggs"])
        _ = await tool.run(["2m", "Tea"])
        let list = await tool.run(["list"])
        XCTAssertEqual(list.status, ToolReply.ok, list.text)
        let lines = list.text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, list.text)
        XCTAssertTrue(lines[0].contains("Tea") && lines[1].contains("Eggs"), "soonest first: \(list.text)")
        XCTAssertTrue(lines[0].contains("a 2m timer"), list.text)
        XCTAssertTrue(lines[0].contains("counting, sounds at " + ToolDates.write(start.addingTimeInterval(120), in: Self.utc)), list.text)
        // A relaunch: a new store over the same folder.
        let after = await self.tool(alarms, records: TimerRecords(folder: root.appendingPathComponent("Timers"))).run(["list"])
        XCTAssertTrue(after.text.contains("Eggs"), after.text)
        // A pause from the lock screen: the activity's time left.
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        alarms.set(id, .paused)
        alarms.left[id] = 95
        let paused = await tool.run(["list"])
        XCTAssertTrue(paused.text.contains("paused, 1m35s left"), paused.text)
        let none = await self.tool(FakeAlarms(AlarmPermission(.granted))).run(["list"])
        XCTAssertTrue(none.text.contains("no timers"), none.text)
    }

    func testCancelTakesOneAndSaysWhenThereIsNone() async {
        let alarms = FakeAlarms(AlarmPermission(.granted))
        let tool = tool(alarms)
        _ = await tool.run(["10m"])
        let id = "00000000-0000-0000-0000-000000000001"
        let cancelled = await tool.run(["cancel", id])
        XCTAssertEqual(cancelled.status, ToolReply.ok, cancelled.text)
        XCTAssertEqual(alarms.count, 0)
        for other in [id, "topo-abc123", "not-an-id"] {
            let reply = await tool.run(["cancel", other])
            XCTAssertEqual(reply.status, ToolReply.failed, "\(other): \(reply.text)")
            XCTAssertTrue(reply.text.contains("no timer of Topo's"), reply.text)
        }
    }
}

/// The ids a tool mints, in order: 00000000-0000-0000-0000-000000000001, …02.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> UUID {
        lock.withLock {
            n += 1
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
        }
    }
}

/// Where the test puts the app: active, inactive under an alert, or in the background.
@MainActor
private final class AppState {
    var value: UIApplication.State
    init(_ value: UIApplication.State) { self.value = value }
}

@MainActor
private final class Raised {
    var up = false
}

/// Whether `condition` holds within 5 s.
@MainActor
private func within(_ condition: @MainActor () -> Bool) async -> Bool {
    let end = ContinuousClock.now + .seconds(5)
    while !condition() {
        if ContinuousClock.now > end { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// A prompt held up until the test opens it.
private actor Gate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        opened = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// Every control AlarmKit offers, as the mind composes it with `topo timer`'s options.
extension TimerToolTests {
    private var granted: FakeAlarms { FakeAlarms(AlarmPermission(.granted)) }
    private var first: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }

    private func plan(_ arguments: [String], _ alarms: FakeAlarms? = nil) async -> (ToolReply, TimerPlan?) {
        let alarms = alarms ?? granted
        let reply = await tool(alarms).run(arguments)
        return (reply, alarms.last)
    }

    func testEveryOptionReachesThePlan() async {
        let (reply, plan) = await plan(["3m", "Plank", "--title", "Switch sides", "--again", "same", "--tell", "next pose please",
                                        "--button-text", "Next", "--button-icon", "forward.fill", "--on-stop", "done for today",
                                        "--pause", "--pause-text", "Hold", "--resume-icon", "play.circle", "--paused-title", "Resting",
                                        "--cancel", "--cancel-text", "Skip", "--tint", "#112233/#445566", "--button-color", "text"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertEqual(plan, TimerPlan(when: .after(180), label: "Plank", title: "Switch sides",
                                       pause: .init(text: "Hold", icon: "pause.fill"), resume: .init(text: "Resume", icon: "play.circle"),
                                       pausedTitle: "Resting", cancel: .init(text: "Skip", icon: "xmark"),
                                       second: .init(text: "Next", icon: "forward.fill"), again: 180, tells: true, tellsOnStop: true,
                                       buttonColor: .token(.text), tint: .hex(light: "#112233", dark: "#445566")))
        let record = records.read(first)
        XCTAssertEqual(record?.tell, "next pose please")
        XCTAssertEqual(record?.onStop, "done for today")
        XCTAssertEqual(record?.login, "login-1")
        XCTAssertEqual(record?.second, "Next")
        XCTAssertEqual(record?.again, 180)
    }

    func testABareTimerHasNoButtonsAndTheThemesColours() async {
        let (_, plan) = await plan(["5m"])
        XCTAssertEqual(plan, TimerPlan(when: .after(300), label: "Timer", title: "Timer", pausedTitle: "Timer",
                                       buttonColor: .token(.onPrimary), tint: .token(.primary)))
        XCTAssertNil(plan?.second)
    }

    /// Again alone is AlarmKit's countdown; Tell alone a custom button; both a countdown that also tells.
    func testTheSecondButtonsShapes() async {
        let again = await plan(["90s", "--again", "45s"]).1
        XCTAssertEqual(again?.second, .init(text: "Again", icon: "repeat"))
        XCTAssertEqual(again?.again, 45)
        XCTAssertEqual(again?.tells, false)
        let tell = await plan(["90s", "--tell", "start the next one"]).1
        XCTAssertEqual(tell?.second, .init(text: "Tell Topo", icon: "bubble.left"))
        XCTAssertNil(tell?.again)
        XCTAssertEqual(tell?.tells, true)
        let snooze = await plan(["at", "07:30", "Wake", "--again", "9m"]).1
        XCTAssertEqual(snooze?.second, .init(text: "Snooze", icon: "zzz"))
        XCTAssertEqual(snooze?.countsDown, true)
    }

    func testAlarmsAtATimeAMomentAndOnDays() async {
        let now = start // 2026-10-26T07:33:20Z, a Monday
        let once = await plan(["at", "07:30", "Wake"])
        XCTAssertEqual(once.1?.when, .at(hour: 7, minute: 30, days: []))
        XCTAssertTrue(once.0.text.contains("sounds at 2026-10-27T07:30:00Z"), once.0.text)
        let days = await plan(["at", "6:05", "--every", "mon,wed,mon"])
        XCTAssertEqual(days.1?.when, .at(hour: 6, minute: 5, days: [.monday, .wednesday]))
        XCTAssertTrue(days.0.text.contains("at 06:05 every mon,wed, next 2026-10-28T06:05:00Z"), days.0.text)
        let daily = await plan(["at", "23:59", "--every", "daily"]).1
        XCTAssertEqual(daily?.when, .at(hour: 23, minute: 59, days: [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]))
        let weekends = await plan(["at", "09:00", "--every", "weekends"]).1
        XCTAssertEqual(weekends?.when, .at(hour: 9, minute: 0, days: [.saturday, .sunday]))
        let moment = await plan(["at", "2026-10-26T09:00:00Z", "Call"])
        XCTAssertEqual(moment.1?.when, .on(now.addingTimeInterval(5200)))
    }

    /// Each refusal names its condition, and nothing is set.
    func testRefusalsAreSaidAndSetNothing() async {
        let cases: [([String], String)] = [
            (["at", "24:00"], "not a time of day"),
            (["at", "7"], "not a time"),
            (["at", "2026-10-26T07:00:00Z"], "has passed"),
            (["at", "2026-10-27"], "not a time"),
            (["at", "2026-11-31T07:30"], "not a date and time that exists"),
            (["at", "2026-11-05T24:00"], "not a date and time that exists"),
            (["at", "2026-10-27T07:00:00Z", "--every", "daily"], "repeats a time of day"),
            (["at", "07:30", "--every", "mon,funday"], "funday is not a day"),
            (["5m", "--every", "daily"], "--every repeats an alarm"),
            (["at", "07:30", "--again", "same"], "an alarm has none"),
            (["5m", "--again", "0s"], "not a span"),
            (["at", "07:30", "--pause"], "--pause sits on a countdown"),
            (["at", "07:30", "--cancel-text", "No"], "--cancel sits on a countdown"),
            (["5m", "--button-text", "Go"], "which --again or --tell makes"),
            (["5m", "--pause", "--pause-icon", "no.such"], "not a symbol"),
            (["5m", "--tint", "teal"], "not a colour"),
            (["5m", "--pause", "--pause-text", String(repeating: "p", count: 21)], "past 20"),
            (["5m", "--tell", String(repeating: "w", count: 501)], "past 500"),
            (["5m", "--title", "  "], "--title is empty"),
            (["5m", "--sound", "/etc/alarm.caf"], "not under /home/topo"),
            (["5m", "--sound", "/home/topo/../x.caf"], "climbs"),
            (["5m", "--sound", "/home/topo/song.mp3"], "not a .caf"),
            (["list", "--pause"], "takes no --pause"),
            (["pause", "x", "--tint", "text"], "takes no --tint"),
            (["5m", "--snooze", "1m"], "no option --snooze"),
        ]
        for (arguments, words) in cases {
            let alarms = granted
            let reply = await tool(alarms).run(arguments)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(arguments): \(reply.text)")
            XCTAssertTrue(reply.text.contains(words), "\(arguments): \(reply.text)")
            XCTAssertEqual(alarms.count, 0, "\(arguments)")
        }
    }

    func testATurnButtonWhileSignedOutSetsNothing() async {
        for option in ["--tell", "--on-stop"] {
            let alarms = granted
            let reply = await tool(alarms, login: nil).run(["5m", option, "words"])
            XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
            XCTAssertTrue(reply.text.contains("signed out"), reply.text)
            XCTAssertEqual(alarms.count, 0)
        }
        let plain = granted
        let reply = await tool(plain, login: nil).run(["5m"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
    }

    /// Each act asks the list first, so the wrong state is said as that state and AlarmKit is not asked.
    func testActsAskTheStateFirst() async {
        let alarms = granted
        let tool = tool(alarms)
        _ = await tool.run(["5m", "Plank", "--pause"])
        let id = first.uuidString.lowercased()
        let early = await tool.run(["resume", id])
        XCTAssertEqual(early.status, ToolReply.failed)
        XCTAssertTrue(early.text.contains("is counting: only a paused timer resumes"), early.text)
        for (verb, said) in [("pause", "paused"), ("resume", "resumed")] {
            let reply = await tool.run([verb, id])
            XCTAssertEqual(reply.text, "\(said): \(id)\n")
        }
        let again = await tool.run(["again", id])
        XCTAssertTrue(again.text.contains("again starts the next countdown only while it sounds"), again.text)
        alarms.set(first, .sounding)
        let restarted = await tool.run(["again", id])
        XCTAssertEqual(restarted.text, "counting again: \(id)\n")
        alarms.set(first, .sounding)
        let stopped = await tool.run(["stop", id])
        XCTAssertEqual(stopped.text, "stopped: \(id)\n")
        XCTAssertEqual(alarms.acts.map(\.0), [.pause, .resume, .again, .stop])
        alarms.actFails = true
        alarms.set(first, .counting)
        let refused = await tool.run(["pause", id])
        XCTAssertTrue(refused.text.contains("AlarmKit did not pause"), refused.text)
        XCTAssertFalse(refused.text.contains("may still sound"), refused.text)
        let missing = await tool.run(["pause", "00000000-0000-0000-0000-000000000009"])
        XCTAssertTrue(missing.text.contains("no timer of Topo's"), missing.text)
    }

    /// A cancel takes the record and the sound with it; a list drops what AlarmKit no longer
    /// holds, a sound with no record included.
    func testRecordsAndSoundsGoWithTheirAlarms() async throws {
        let alarms = granted
        let tool = tool(alarms)
        _ = await tool.run(["5m", "--tell", "words"])
        XCTAssertNotNil(records.read(first))
        let sounds = root.appendingPathComponent("Sounds")
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        for name in ["topo-timer-\(first.uuidString.lowercased()).caf", "topo-timer-\(UUID().uuidString.lowercased()).wav",
                     ".partial-topo-timer-\(UUID().uuidString.lowercased()).caf", "someone-elses.caf"] {
            try Data("x".utf8).write(to: sounds.appendingPathComponent(name))
        }
        let gone = UUID()
        try records.write(.init(label: "gone"), for: gone)
        _ = await tool.run(["list"])
        XCTAssertNil(records.read(gone))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: sounds.path)),
                       ["topo-timer-\(first.uuidString.lowercased()).caf", "someone-elses.caf"])
        _ = await tool.run(["cancel", first.uuidString])
        XCTAssertNil(records.read(first))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sounds.path), ["someone-elses.caf"])
    }

    /// A list that begins while a start is scheduling waits for it, so it never sweeps the record
    /// of an alarm set beside it.
    func testAListBesideAStartKeepsItsRecord() async throws {
        let alarms = granted
        let scheduling = Gate(), listing = Gate()
        alarms.scheduleGate = scheduling
        alarms.alarmsGate = listing
        let tool = tool(alarms)
        let start = Task { await tool.run(["5m", "Plank", "--tell", "next"]) }
        let reached = await within { alarms.scheduling }
        XCTAssertTrue(reached)
        // Unordered, the list reads AlarmKit now, without the new alarm, and sweeps after the
        // start has written its record.
        let list = Task { await tool.run(["list"]) }
        try? await Task.sleep(for: .milliseconds(100))
        await scheduling.open()
        _ = await start.value
        await listing.open()
        let listed = await list.value
        XCTAssertEqual(records.read(first)?.tell, "next")
        XCTAssertTrue(listed.text.contains("Plank"), listed.text)
    }

    func testAgainOnAnAlarmWithNoAgainIsRefused() async {
        let alarms = granted
        let tool = tool(alarms)
        _ = await tool.run(["at", "07:30", "Wake"])
        alarms.set(first, .sounding)
        let reply = await tool.run(["again", first.uuidString])
        XCTAssertTrue(reply.text.contains("set with no --again"), reply.text)
        XCTAssertTrue(alarms.acts.isEmpty)
    }

    func testListSaysTheShapeOfEachAlarm() async {
        let alarms = granted
        let tool = tool(alarms)
        _ = await tool.run(["at", "06:00", "Run", "--every", "weekdays", "--again", "10m", "--tell", "go", "--button-text", "Later"])
        let list = await tool.run(["list"])
        XCTAssertTrue(list.text.contains("Run | at 06:00 every mon,tue,wed,thu,fri, next 2026-10-27T06:00:00Z | set | button \"Later\" starts 10m again and tells Topo"),
                      list.text)
    }
}

/// What Codex's first round on #607 found: records kept for a Stop on its way, cleanup on a cancel
/// of what AlarmKit already removed, a failed list, the copy of a sound and the bound.
extension TimerToolTests {
    func testListSaysEachButtonAcrossARelaunch() async {
        let alarms = granted
        _ = await tool(alarms).run(["5m", "Plank", "--pause", "--pause-text", "Hold", "--cancel", "--cancel-text", "Skip",
                                    "--again", "same", "--button-text", "Next"])
        let list = await tool(alarms, records: TimerRecords(folder: root.appendingPathComponent("Timers"))).run(["list"])
        XCTAssertTrue(list.text.contains(#"button "Hold" pauses | button "Resume" resumes | button "Skip" cancels | button "Next" starts 5m again"#),
                      list.text)
    }

    /// A Stop removes a one-shot alarm before its intent reads the words, so a list between the
    /// two keeps a record with words until the grace has passed.
    func testARecordWithWordsOutlivesItsAlarmByTheGrace() async throws {
        let alarms = granted
        let stopped = UUID(), plain = UUID()
        try records.write(.init(label: "Plank", onStop: "log it", login: "login-1"), for: stopped)
        try records.write(.init(label: "Plain"), for: plain)
        _ = await tool(alarms).run(["list"])
        XCTAssertEqual(records.read(stopped)?.onStop, "log it")
        XCTAssertEqual(records.read(stopped)?.gone, start)
        XCTAssertNil(records.read(plain))
        _ = await tool(alarms, now: start.addingTimeInterval(TimerRecords.grace - 1)).run(["list"])
        XCTAssertEqual(records.read(stopped)?.gone, start, "the first sweep's mark stands")
        _ = await tool(alarms, now: start.addingTimeInterval(TimerRecords.grace)).run(["list"])
        XCTAssertNil(records.read(stopped))
    }

    func testCancelOfAnAlarmAlreadyGoneTakesItsRecordAndSound() async throws {
        let alarms = granted
        let gone = UUID()
        try records.write(.init(label: "Gone", sound: "topo-timer-\(gone.uuidString.lowercased()).caf"), for: gone)
        let sounds = root.appendingPathComponent("Sounds")
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sounds.appendingPathComponent("topo-timer-\(gone.uuidString.lowercased()).caf"))
        let reply = await tool(alarms).run(["cancel", gone.uuidString])
        XCTAssertTrue(reply.text.contains("no timer of Topo's"), reply.text)
        XCTAssertNil(records.read(gone))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sounds.path), [])
    }

    /// Every act whose list read sweeps, not only cancel.
    func testAPauseSweepsWhatAlarmKitNoLongerHolds() async throws {
        let alarms = granted
        let tool = tool(alarms)
        _ = await tool.run(["5m", "Plank"])
        let gone = UUID()
        try records.write(.init(label: "Gone"), for: gone)
        let paused = await tool.run(["pause", first.uuidString])
        XCTAssertEqual(paused.status, ToolReply.ok, paused.text)
        XCTAssertNil(records.read(gone))
        XCTAssertNotNil(records.read(first))
    }

    /// A list AlarmKit fails is said as that, and drops no record or sound.
    func testAFailedListKeepsEveryRecordAndSound() async throws {
        let alarms = granted
        let tool = tool(alarms)
        _ = await tool.run(["5m", "Plank", "--tell", "next"])
        let sounds = root.appendingPathComponent("Sounds")
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        let sound = "topo-timer-\(first.uuidString.lowercased()).caf"
        try Data("x".utf8).write(to: sounds.appendingPathComponent(sound))
        alarms.alarmsThrow = CocoaError(.featureUnsupported)
        let list = await tool.run(["list"])
        XCTAssertEqual(list.status, ToolReply.failed)
        XCTAssertTrue(list.text.contains("AlarmKit did not list them"), list.text)
        for act in ["pause", "cancel"] {
            let reply = await tool.run([act, first.uuidString])
            XCTAssertTrue(reply.text.contains("AlarmKit did not list its alarms, so \(first.uuidString) was not asked to \(act)"), reply.text)
        }
        XCTAssertTrue(alarms.acts.isEmpty)
        XCTAssertEqual(records.read(first)?.tell, "next")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sounds.path), [sound])
    }

    /// A sound reaches the plan under the alarm's name, and the countdown is counted from after
    /// its copy, which is when AlarmKit starts it.
    func testASoundReachesThePlanAndTheCountdownStartsAfterItsCopy() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        try writeTone(root.appendingPathComponent("home/bell.caf"), seconds: 1)
        let alarms = granted
        let clock = LockedBox(start)
        var tool = tool(alarms)
        tool.now = { clock.with { $0 } }
        tool.copy = { sounds, path, id in
            clock.with { $0 = $0.addingTimeInterval(2) }
            return try await sounds.copy(path, for: id)
        }
        let reply = await tool.run(["10s", "Bell", "--sound", "/home/topo/bell.caf"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        let name = "topo-timer-\(first.uuidString.lowercased()).caf"
        XCTAssertEqual(alarms.last?.sound, name)
        XCTAssertEqual(records.read(first)?.sound, name)
        XCTAssertEqual(records.read(first)?.fires, start.addingTimeInterval(12))
        XCTAssertTrue(reply.text.contains("sounds at " + ToolDates.write(start.addingTimeInterval(12), in: Self.utc)), reply.text)
    }

    /// A call the service answered at its bound while the sound was copying sets nothing, and
    /// leaves no copy.
    func testACallCancelledDuringTheCopySetsNothing() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        try writeTone(root.appendingPathComponent("home/bell.caf"), seconds: 1)
        let alarms = granted
        let copying = Gate()
        let entered = Raised()
        var tool = tool(alarms)
        tool.copy = { sounds, path, id in
            await MainActor.run { entered.up = true }
            await copying.wait()
            return try await sounds.copy(path, for: id)
        }
        let call = Task { await tool.run(["10s", "Bell", "--sound", "/home/topo/bell.caf"]) }
        guard await within({ entered.up }) else { return XCTFail("the copy never began") }
        call.cancel()
        await copying.open()
        let reply = await call.value
        XCTAssertEqual(reply.status, ToolReply.timedOut, reply.text)
        XCTAssertEqual(alarms.count, 0)
        XCTAssertNil(records.read(first))
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sounds").path)) ?? []
        XCTAssertTrue(left.isEmpty, "\(left)")
    }
}

/// A press of a timer's button: one turn, under the login the timer was set under, with the mind's
/// words marked as the mind's.
@MainActor
final class TimerPressTests: XCTestCase {
    private var root: URL!
    private var records: TimerRecords { TimerRecords(folder: root.appendingPathComponent("Timers")) }
    private var store: ShareStore { ShareStore(folder: root.appendingPathComponent("Shares")) }
    private let id = UUID()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("presses-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func press(_ button: TimerButton, _ alarms: FakeAlarms, restarts: Bool = false) async -> TimerPresses.Outcome {
        await TimerPresses.press(id, button, restarts: restarts, records: records, scheduler: alarms, store: store, drain: nil, landed: nil,
                                 nonce: "00000000-0000-0000-0000-0000000000aa")
    }

    func testAPressKeepsOneMarkedTurnUnderItsLogin() async throws {
        try store.open(files: false)
        let login = try XCTUnwrap(store.door()?.login)
        try records.write(.init(label: "Plank", tell: "start the other side", onStop: "log the session",
                                second: "Next", login: login), for: id)
        let alarms = FakeAlarms(AlarmPermission(.granted))
        alarms.holds(id, .sounding)
        let outcome = await press(.second, alarms)
        XCTAssertEqual(outcome, .kept(nonce: "00000000-0000-0000-0000-0000000000aa"))
        let shares = store.shares()
        XCTAssertEqual(shares.count, 1)
        XCTAssertEqual(ShareInbox.text(shares[0], path: nil),
                       "[A press of the \"Plank\" timer's Next button, on the lock screen or in Topo; these are the words Topo kept for it when it set the timer]\nstart the other side")
        // `.custom` leaves the alarm sounding, so the press stops it.
        XCTAssertEqual(alarms.acts.map(\.0), [.stop])
        // The same press again is the same nonce: one turn.
        _ = await press(.second, alarms)
        XCTAssertEqual(store.shares().count, 1)
    }

    func testStopsWordsAndAButtonThatAlsoRestartsLeaveTheAlarmBe() async throws {
        try store.open(files: false)
        let login = try XCTUnwrap(store.door()?.login)
        try records.write(.init(label: "Plank", again: 60, tell: "next", onStop: "log it", second: "Again", login: login), for: id)
        let alarms = FakeAlarms(AlarmPermission(.granted))
        alarms.holds(id, .sounding)
        _ = await press(.second, alarms, restarts: true)
        XCTAssertTrue(alarms.acts.isEmpty)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Shares/00000000-0000-0000-0000-0000000000aa"))
        _ = await press(.stop, alarms)
        let text = store.shares().first.flatMap { ShareInbox.text($0, path: nil) }
        XCTAssertTrue(text?.contains("timer's Stop button") == true && text?.hasSuffix("\nlog it") == true, text ?? "nil")
    }

    func testAPressAfterASignOutOrAnotherLoginSendsNothing() async throws {
        try records.write(.init(label: "Plank", tell: "next", login: "old-login"), for: id)
        let alarms = FakeAlarms(AlarmPermission(.granted))
        alarms.holds(id, .sounding)
        let signedOut = await press(.second, alarms)
        XCTAssertEqual(signedOut, .refused(.signedOut))
        try store.open(files: false)
        alarms.holds(id, .sounding)
        let another = await press(.second, alarms)
        XCTAssertEqual(another, .refused(.signedOut))
        XCTAssertTrue(store.shares().isEmpty)
        // The alarm is stopped all the same: the person pressed it.
        XCTAssertEqual(alarms.acts.map(\.0), [.stop, .stop])
    }

    /// A press whose alarm is no longer sounding (AlarmKit restarted it, or the person stopped it) stops nothing.
    func testAPressStopsOnlyASoundingAlarm() async throws {
        let alarms = FakeAlarms(AlarmPermission(.granted))
        alarms.holds(id, .counting)
        _ = await press(.second, alarms)
        XCTAssertTrue(alarms.acts.isEmpty)
    }

    /// The app's own stop of a `.custom` press may set off Stop's intent: that is the press's turn,
    /// not a second one.
    func testStopsIntentAfterTheAppsOwnStopIsNoSecondTurn() async throws {
        try store.open(files: false)
        try records.write(.init(label: "Plank", tell: "next", onStop: "log it", login: store.door()?.login), for: id)
        let alarms = FakeAlarms(AlarmPermission(.granted))
        alarms.holds(id, .sounding)
        _ = await press(.second, alarms)
        let echo = await TimerPresses.press(id, .stop, records: records, scheduler: alarms, store: store, drain: nil, landed: nil,
                                            nonce: "00000000-0000-0000-0000-0000000000bb")
        XCTAssertEqual(echo, .echo)
        XCTAssertEqual(store.shares().count, 1)
    }

    /// A stop AlarmKit refused set off no Stop intent, so the person's own Stop within the
    /// window is their turn.
    func testAFailedStopLeavesThePersonsStopTheirs() async throws {
        try store.open(files: false)
        try records.write(.init(label: "Plank", tell: "next", onStop: "log it", login: store.door()?.login), for: id)
        let alarms = FakeAlarms(AlarmPermission(.granted))
        alarms.holds(id, .sounding)
        alarms.actFails = true
        _ = await press(.second, alarms)
        let stop = await TimerPresses.press(id, .stop, records: records, scheduler: alarms, store: store, drain: nil, landed: nil,
                                            nonce: "00000000-0000-0000-0000-0000000000cc")
        XCTAssertEqual(stop, .kept(nonce: "00000000-0000-0000-0000-0000000000cc"))
        XCTAssertEqual(store.shares().count, 2)
    }

    func testAPressWithNoWordsSendsNothing() async throws {
        try store.open(files: false)
        let alarms = FakeAlarms(AlarmPermission(.granted))
        let none = await press(.stop, alarms)
        XCTAssertEqual(none, .nothing)
        try records.write(.init(label: "Plank", tell: "next", login: store.door()?.login), for: id)
        let noStop = await press(.stop, alarms)
        XCTAssertEqual(noStop, .nothing)
        XCTAssertTrue(store.shares().isEmpty)
    }
}

/// A sound file from the guest's home, judged as the system plays it.
final class TimerSoundTests: XCTestCase {
    private var root: URL!
    private var sounds: TimerSounds { TimerSounds(home: root.appendingPathComponent("home"), folder: root.appendingPathComponent("Sounds")) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func tone(_ name: String, seconds: Double) throws {
        try writeTone(root.appendingPathComponent("home/\(name)"), seconds: seconds)
    }
}

/// A linear PCM file of `seconds` at `url`.
private func writeTone(_ url: URL, seconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let file = try AVAudioFile(forWriting: url,
                                   settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1,
                                              AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        let frames = AVAudioFrameCount(seconds * 8000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
}

extension TimerSoundTests {

    func testAShortPCMSoundIsCopiedUnderTheAlarmsName() async throws {
        try tone("bell.caf", seconds: 2)
        let id = UUID()
        let name = try await sounds.copy("/home/topo/bell.caf", for: id)
        XCTAssertEqual(name, "topo-timer-\(id.uuidString.lowercased()).caf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sounds/\(name)").path))
        sounds.remove(name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sounds/\(name)").path))
    }

    func testRefusals() async throws {
        try tone("long.wav", seconds: 31)
        try Data("not a sound".utf8).write(to: root.appendingPathComponent("home/fake.caf"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("home/link.caf").path,
                                                   withDestinationPath: root.appendingPathComponent("home/long.wav").path)
        for (path, words) in [("/home/topo/long.wav", "runs 31 seconds"), ("/home/topo/fake.caf", "not a sound the phone can read"),
                              ("/home/topo/link.caf", "goes through a link"), ("/home/topo/none.caf", "cannot be opened")] {
            do {
                _ = try await sounds.copy(path, for: UUID())
                XCTFail("\(path) was copied")
            } catch let failure as ToolFailure {
                XCTAssertTrue(failure.text.contains(words), "\(path): \(failure.text)")
            }
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sounds").path)) ?? []
        XCTAssertTrue(left.isEmpty, "\(left)")
    }
}

/// The plan as AlarmKit's attributes and timing, which the widget and the system draw from.
final class AlarmKitPlanTests: XCTestCase {
    private func plan(_ when: TimerPlan.When) -> TimerPlan {
        TimerPlan(when: when, label: "Plank", title: "Done", pausedTitle: "Held", buttonColor: .token(.text), tint: .token(.primary))
    }

    func testTheSecondButtonsBehaviour() {
        var plan = plan(.after(60))
        XCTAssertNil(AlarmKitScheduler.attributes(plan).presentation.alert.secondaryButtonBehavior)
        plan.second = .init(text: "Next", icon: "forward.fill")
        plan.tells = true
        XCTAssertEqual(AlarmKitScheduler.attributes(plan).presentation.alert.secondaryButtonBehavior, .custom)
        plan.again = 60
        XCTAssertEqual(AlarmKitScheduler.attributes(plan).presentation.alert.secondaryButtonBehavior, .countdown)
    }

    func testPresentationsFollowThePlan() {
        var plan = plan(.at(hour: 7, minute: 0, days: []))
        var presentation = AlarmKitScheduler.attributes(plan).presentation
        XCTAssertNil(presentation.countdown, "an alarm with no again never counts down")
        XCTAssertNil(presentation.paused)
        plan = self.plan(.after(60))
        plan.pause = .init(text: "Hold", icon: "pause.fill")
        plan.resume = .init(text: "Go", icon: "play.fill")
        plan.cancel = .init(text: "Skip", icon: "xmark")
        let attributes = AlarmKitScheduler.attributes(plan)
        presentation = attributes.presentation
        XCTAssertEqual(presentation.countdown?.pauseButton?.systemImageName, "pause.fill")
        XCTAssertEqual(presentation.paused?.resumeButton.systemImageName, "play.fill")
        XCTAssertEqual(String(localized: presentation.paused!.title), "Held")
        XCTAssertEqual(String(localized: presentation.alert.title), "Done")
        XCTAssertEqual(attributes.metadata?.cancel, .init(text: "Skip", icon: "xmark", colour: "text"))
    }

    /// What Stop and the second button run, and the sound, as the configuration is given them.
    func testIntentsAndSound() {
        let id = UUID()
        var plan = plan(.after(60))
        XCTAssertNil(AlarmKitScheduler.intents(id: id, plan: plan).stop)
        XCTAssertNil(AlarmKitScheduler.intents(id: id, plan: plan).second)
        XCTAssertEqual(AlarmKitScheduler.sound(plan), .default)
        plan.tells = true
        plan.tellsOnStop = true
        plan.sound = "topo-timer-x.caf"
        var intents = AlarmKitScheduler.intents(id: id, plan: plan)
        XCTAssertEqual(intents.stop?.alarm, id.uuidString)
        XCTAssertEqual(intents.stop?.button, "stop")
        XCTAssertEqual(intents.second?.alarm, id.uuidString)
        XCTAssertEqual(intents.second?.button, "second")
        XCTAssertEqual(intents.second?.restarts, false)
        XCTAssertEqual(AlarmKitScheduler.sound(plan), .named("topo-timer-x.caf"))
        plan.again = 30
        intents = AlarmKitScheduler.intents(id: id, plan: plan)
        XCTAssertEqual(intents.second?.restarts, true)
    }

    func testTiming() {
        var plan = plan(.after(90))
        XCTAssertEqual(AlarmKitScheduler.timing(plan).duration, .init(preAlert: 90, postAlert: nil))
        XCTAssertNil(AlarmKitScheduler.timing(plan).schedule)
        plan.again = 30
        XCTAssertEqual(AlarmKitScheduler.timing(plan).duration, .init(preAlert: 90, postAlert: 30))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        plan = self.plan(.on(date))
        XCTAssertNil(AlarmKitScheduler.timing(plan).duration)
        XCTAssertEqual(AlarmKitScheduler.timing(plan).schedule, .fixed(date))
        plan = self.plan(.at(hour: 6, minute: 5, days: [.monday]))
        plan.again = 540
        XCTAssertEqual(AlarmKitScheduler.timing(plan).duration, .init(preAlert: nil, postAlert: 540))
        XCTAssertEqual(AlarmKitScheduler.timing(plan).schedule, .relative(.init(time: .init(hour: 6, minute: 5), repeats: .weekly([.monday]))))
        XCTAssertEqual(AlarmKitScheduler.when(.relative(.init(time: .init(hour: 6, minute: 5), repeats: .weekly([.monday])))),
                       .at(hour: 6, minute: 5, days: [.monday]))
    }
}
