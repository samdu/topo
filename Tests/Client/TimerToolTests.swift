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
    /// Where set, a no at the prompt leaves the standing undetermined.
    var keepsNothing = false

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
            if answer || !keepsNothing { standing = answer ? .granted : .denied }
            return answer
        }
    }
    func prompt() async throws -> Bool {
        if let failure {
            lock.withLock { _prompts += 1 }
            throw failure
        }
        return await request()
    }
}

private final class FakeAlarms: AlarmScheduler, @unchecked Sendable {
    private let lock = NSLock()
    let permission: AlarmPermission?
    private var scheduled: [(id: UUID, label: String, duration: TimeInterval)] = []
    /// A cancel AlarmKit refuses.
    var cancelFails = false
    /// What a schedule throws, where set.
    var scheduleThrows: (any Error)?

    init(_ permission: AlarmPermission?) { self.permission = permission }

    var authorizer: (any Authorizer)? { permission }
    var count: Int { lock.withLock { scheduled.count } }
    var last: (id: UUID, label: String, duration: TimeInterval)? { lock.withLock { scheduled.last } }

    func schedule(id: UUID, label: String, duration: TimeInterval) async throws {
        if let scheduleThrows { throw scheduleThrows }
        lock.withLock { scheduled.append((id, label, duration)) }
    }
    func alarms() async throws -> [(id: UUID, state: String)] { lock.withLock { scheduled.map { ($0.id, "counting") } } }
    func cancel(id: UUID) async throws {
        if cancelFails { throw CocoaError(.featureUnsupported) }
        lock.withLock { scheduled.removeAll { $0.id == id } }
    }
}

@MainActor
final class TimerToolTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_793_000_000)

    private func tool(_ alarms: FakeAlarms, state: AppState = AppState(.active), book: TimerBook = TimerBook()) -> TimerTool {
        let start = start
        let counter = Counter()
        return TimerTool(scheduler: alarms, book: { book }, broker: PermissionBroker(), state: { state.value },
                         now: { start }, makeID: { counter.next() })
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

    /// A no that leaves the standing undetermined, with Topo in front throughout, is said as a
    /// prompt that kept no answer, never as the background or a refusal.
    func testAPromptThatKeepsNoAnswerIsSaidAsThat() async {
        let permission = AlarmPermission(.undetermined, answer: false)
        permission.keepsNothing = true
        let alarms = FakeAlarms(permission)
        let reply = await tool(alarms).run(["1m"])
        XCTAssertEqual(reply, TimerTool.promptUnanswered, reply.text)
        XCTAssertEqual(permission.prompts, 1)
        XCTAssertEqual(alarms.count, 0)
    }

    func testAScheduleFailureIsSaidAndNothingKept() async {
        let alarms = FakeAlarms(AlarmPermission(.granted))
        alarms.scheduleThrows = CocoaError(.featureUnsupported)
        let book = TimerBook()
        let reply = await tool(alarms, book: book).run(["5m"])
        XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
        XCTAssertTrue(reply.text.contains("did not set the timer"), reply.text)
        XCTAssertNil(book.entry(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
    }

    func testTheAlarmLimitIsSaidAndNothingKept() async {
        let alarms = FakeAlarms(AlarmPermission(.granted))
        alarms.scheduleThrows = AlarmLimit()
        let book = TimerBook()
        let reply = await tool(alarms, book: book).run(["5m", "Tea"])
        XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
        XCTAssertTrue(reply.text.contains(AlarmLimit().reason), reply.text)
        XCTAssertEqual(alarms.count, 0)
        XCTAssertNil(book.entry(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
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
        alarms.cancelFails = true
        let reply = await tool.run(["cancel", "00000000-0000-0000-0000-000000000001"])
        XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
        XCTAssertTrue(reply.text.contains("may still sound"), reply.text)
        XCTAssertEqual(alarms.count, 1)
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
        XCTAssertEqual(alarms.last?.duration, 900)
        XCTAssertTrue(reply.text.hasPrefix("set: 00000000-0000-0000-0000-000000000001"), reply.text)
        XCTAssertTrue(reply.text.contains("sounds at " + ToolDates.write(start.addingTimeInterval(900))), reply.text)
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
        XCTAssertEqual(allowed.last?.duration, 60)
        XCTAssertEqual(allowed.last?.label, "Timer")
    }

    /// Refused at the prompt or before (AlarmKit has no restricted state), nothing is set and nothing stands in for it: the reply
    /// says where alarms are allowed, which is not what a phone without AlarmKit says.
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

    func testAPhoneWithoutAlarmKitSetsNothingAndSaysWhy() async {
        let alarms = FakeAlarms(nil)
        let reply = await tool(alarms).run(["1m"])
        XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
        XCTAssertEqual(alarms.count, 0)
        XCTAssertTrue(reply.text.contains("iOS 26"), reply.text)
        XCTAssertFalse(reply.text.contains("Settings"), reply.text)
    }

    func testListSaysLabelAndTimeWhileTopoRunsAndTheIdAfter() async {
        let alarms = FakeAlarms(AlarmPermission(.granted))
        let book = TimerBook()
        let tool = tool(alarms, book: book)
        _ = await tool.run(["10m", "Eggs"])
        _ = await tool.run(["2m", "Tea"])
        let list = await tool.run(["list"])
        XCTAssertEqual(list.status, ToolReply.ok, list.text)
        let lines = list.text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, list.text)
        XCTAssertTrue(lines[0].contains("Tea") && lines[1].contains("Eggs"), "soonest first: \(list.text)")
        XCTAssertTrue(lines[0].contains("sounds at " + ToolDates.write(start.addingTimeInterval(120))), list.text)
        XCTAssertTrue(lines[1].contains("sounds at " + ToolDates.write(start.addingTimeInterval(600))), list.text)
        // A relaunch: a new book knows nothing, and the alarm is listed by id and state.
        let after = await self.tool(alarms, book: TimerBook()).run(["list"])
        XCTAssertTrue(after.text.contains("00000000-0000-0000-0000-000000000001"), after.text)
        XCTAssertFalse(after.text.contains("Eggs"), after.text)
        XCTAssertTrue(after.text.contains("counting"), after.text)
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
