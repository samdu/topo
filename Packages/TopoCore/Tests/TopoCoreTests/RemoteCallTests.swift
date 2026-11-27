import Foundation
import Testing
@testable import TopoCore
import TopoCoreTesting

@Suite struct RemoteCallTests {
    let hub = DeviceID("mac-1")
    let phone = DeviceID("ios-1")

    @Test func aCallIsClaimedRunAndAnsweredOnce() async throws {
        let database = InMemoryRecordDatabase()
        let ran = Counter()
        let asking = Task {
            try await RemoteCalls.call(["timer", "start", "5m"], on: phone, from: hub, in: database, interval: 0.02, wake: { _ in
                // Two wakes for one call: one runs it.
                async let first = RemoteCalls.serve(phone, in: database, evidence: { _ in "via=test" }) { argv in
                    await ran.add(); return (0, argv.joined(separator: " "))
                }
                async let second = RemoteCalls.serve(phone, in: database) { _ in await ran.add(); return (0, "twice") }
                _ = await (first, second)
            })
        }
        let answer = try await asking.value
        #expect(answer.state == .done)
        #expect(answer.status == 0)
        #expect(await ran.value == 1)
        #expect(answer.text == "timer start 5m" || answer.text == "twice")
    }

    @Test func aCallNobodyClaimsIsCancelledAndNeverRuns() async throws {
        let database = InMemoryRecordDatabase()
        await #expect(throws: RemoteCalls.Failure.unclaimed) {
            try await RemoteCalls.call(["notify", "late"], on: phone, from: hub, in: database, claimWithin: 0.05, interval: 0.02)
        }
        let ran = await RemoteCalls.serve(phone, in: database) { _ in (0, "ran") }
        #expect(ran == nil)
    }

    @Test func aCallPastItsTimeIsNotClaimed() async throws {
        let database = InMemoryRecordDatabase()
        let call = RemoteCall(target: phone, caller: hub, argv: ["timer"], askedAt: Date(timeIntervalSinceNow: -600),
                              expiresAt: Date(timeIntervalSinceNow: -555))
        _ = try await database.save(call.record)
        #expect(await RemoteCalls.serve(phone, in: database) { _ in (0, "ran") } == nil)
    }

    @Test func anotherDevicesSlotIsNotServed() async throws {
        let database = InMemoryRecordDatabase()
        let call = RemoteCall(target: phone, caller: hub, argv: ["timer"], expiresAt: Date(timeIntervalSinceNow: 30))
        _ = try await database.save(call.record)
        #expect(await RemoteCalls.serve(DeviceID("ios-2"), in: database) { _ in (0, "ran") } == nil)
    }

    @Test func aStandingCallHoldsTheSlot() async throws {
        let database = InMemoryRecordDatabase()
        let call = RemoteCall(target: phone, caller: hub, argv: ["timer"], expiresAt: Date(timeIntervalSinceNow: 30))
        _ = try await database.save(call.record)
        await #expect(throws: RemoteCalls.Failure.busy) {
            try await RemoteCalls.call(["notify"], on: phone, from: hub, in: database, interval: 0.02)
        }
    }

    @Test func anAnswerPastTheLimitIsCut() {
        var call = RemoteCall(target: phone, caller: hub, argv: ["log"], expiresAt: Date())
        call.text = String(repeating: "a", count: RemoteCall.textLimit + 10)
        #expect(call.record.string("text")?.count == RemoteCall.textLimit)
    }
}

private actor Counter {
    var value = 0
    func add() { value += 1 }
}

@Suite struct ReplyFrameActivityTests {
    @Test func activityFramesRoundTrip() {
        for frame in [ReplyFrame.thinking, .using(name: "Write", path: "/a b/c.md"), .using(name: "Bash", path: nil), .used] {
            let line = String(decoding: frame.line, as: UTF8.self).trimmingCharacters(in: .newlines)
            #expect(ReplyFrame(line: line) == frame)
        }
    }
}
