import Foundation
import TopoTools
import XCTest

@testable import Topo

/// AlarmKit's permission where the test puts it, counting its prompts.
private final class AlarmPermission: Authorizer, @unchecked Sendable {
    let name = "Alarms"
    private let lock = NSLock()
    private var standing: Access
    private let answer: Bool
    private var _prompts = 0

    init(_ standing: Access, answer: Bool = true) {
        self.standing = standing
        self.answer = answer
    }

    var prompts: Int { lock.withLock { _prompts } }
    func access() async -> Access { lock.withLock { standing } }
    func request() async -> Bool {
        // A prompt stays up a moment, so a second call made meanwhile finds it up.
        try? await Task.sleep(for: .milliseconds(50))
        return lock.withLock {
            _prompts += 1
            standing = answer ? .granted : .denied
            return answer
        }
    }
}

private final class FakeAlarms: AlarmScheduler, @unchecked Sendable {
    private let lock = NSLock()
    let permission: AlarmPermission?
    private var scheduled: [(id: UUID, label: String, duration: TimeInterval)] = []

    init(_ permission: AlarmPermission?) { self.permission = permission }

    var authorizer: (any Authorizer)? { permission }
    var count: Int { lock.withLock { scheduled.count } }
    var last: (id: UUID, label: String, duration: TimeInterval)? { lock.withLock { scheduled.last } }

    func schedule(id: UUID, label: String, duration: TimeInterval) async throws {
        lock.withLock { scheduled.append((id, label, duration)) }
    }
    func alarms() async throws -> [(id: UUID, state: String)] { lock.withLock { scheduled.map { ($0.id, "counting") } } }
    func cancel(id: UUID) async -> Bool {
        lock.withLock {
            let before = scheduled.count
            scheduled.removeAll { $0.id == id }
            return scheduled.count < before
        }
    }
}

@MainActor
final class TimerToolTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_793_000_000)

    private func tool(_ alarms: FakeAlarms, onScreen: Bool = true, book: TimerBook = TimerBook()) -> TimerTool {
        let start = start
        let counter = Counter()
        return TimerTool(scheduler: alarms, book: { book }, broker: PermissionBroker(), onScreen: { onScreen },
                         now: { start }, makeID: { counter.next() })
    }

    func testAGrantedStartSetsOneAlarmAndSaysWhenItSounds() async {
        let alarms = FakeAlarms(AlarmPermission(.granted))
        let reply = await tool(alarms).run(["15m", "Tea"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertEqual(alarms.count, 1)
        XCTAssertEqual(alarms.last?.label, "Tea")
        XCTAssertEqual(alarms.last?.duration, 900)
        XCTAssertTrue(reply.text.hasPrefix("set: 00000000-0000-0000-0000-000000000001"), reply.text)
        XCTAssertTrue(reply.text.contains("sounds at"), reply.text)
    }

    func testANoLabelIsTimer() async {
        let alarms = FakeAlarms(AlarmPermission(.granted))
        _ = await tool(alarms).run(["90s"])
        XCTAssertEqual(alarms.last?.label, "Timer")
    }

    func testSpanBounds() async {
        let alarms = FakeAlarms(AlarmPermission(.granted))
        let tool = tool(alarms)
        for span in ["0s", "25h", "soon", "86401s"] {
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

    func testALabelOver40IsRefusedNotCut() async {
        let alarms = FakeAlarms(AlarmPermission(.granted))
        let reply = await tool(alarms).run(["5m", String(repeating: "x", count: 41)])
        XCTAssertEqual(reply.status, ToolReply.usage, reply.text)
        XCTAssertEqual(alarms.count, 0)
        let fits = await tool(alarms).run(["5m", String(repeating: "x", count: 40)])
        XCTAssertEqual(fits.status, ToolReply.ok, fits.text)
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
        let reply = await tool(alarms, onScreen: false).run(["1m"])
        XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
        XCTAssertTrue(reply.text.contains("open Topo"), reply.text)
        XCTAssertEqual(permission.prompts, 0)
        XCTAssertEqual(alarms.count, 0)
        // Allowed already, a start off the screen sets its alarm.
        let allowed = FakeAlarms(AlarmPermission(.granted))
        let set = await tool(allowed, onScreen: false).run(["1m"])
        XCTAssertEqual(set.status, ToolReply.ok, set.text)
    }

    /// Refused at the prompt or before, nothing is set and nothing stands in for it: the reply
    /// says where alarms are allowed, which is not what a phone without AlarmKit says.
    func testARefusalSetsNothingAndSaysWhereToAllowIt() async {
        for permission in [AlarmPermission(.denied), AlarmPermission(.undetermined, answer: false)] {
            let alarms = FakeAlarms(permission)
            let reply = await tool(alarms).run(["1m"])
            XCTAssertEqual(reply.status, ToolReply.denied, reply.text)
            XCTAssertTrue(reply.text.contains("Apps › Topo › Alarms"), reply.text)
            XCTAssertFalse(reply.text.contains("sounds"), reply.text)
            XCTAssertEqual(alarms.count, 0)
        }
        let restricted = FakeAlarms(AlarmPermission(.restricted))
        let reply = await tool(restricted).run(["1m"])
        XCTAssertEqual(reply.status, ToolReply.denied, reply.text)
        XCTAssertTrue(reply.text.contains("restricted"), reply.text)
        XCTAssertEqual(restricted.count, 0)
    }

    func testAPhoneWithoutAlarmKitSetsNothingAndSaysWhy() async {
        let reply = await tool(FakeAlarms(nil)).run(["1m"])
        XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
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
