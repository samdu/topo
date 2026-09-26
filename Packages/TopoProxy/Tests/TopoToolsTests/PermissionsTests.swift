import Foundation
import Testing
@testable import TopoTools

/// A permission whose standing and prompt the test sets, counting the prompts.
final class FakeAuthorizer: Authorizer, @unchecked Sendable {
    let name = "Reminders"
    private let lock = NSLock()
    private var standing: Access
    private let answer: Bool
    private let delay: Duration
    private var _prompts = 0

    init(_ standing: Access, answer: Bool = true, delay: Duration = .zero) {
        self.standing = standing
        self.answer = answer
        self.delay = delay
    }

    var prompts: Int { lock.withLock { _prompts } }

    func access() async -> Access { lock.withLock { standing } }

    func request() async -> Bool {
        lock.withLock { _prompts += 1 }
        try? await Task.sleep(for: delay)
        lock.withLock { standing = answer ? .granted : .denied }
        return answer
    }
}

@Suite struct PermissionBrokerTests {
    @Test func grantedGoesAheadWithNoPrompt() async {
        let fake = FakeAuthorizer(.granted)
        #expect(await PermissionBroker().admit(fake) == nil)
        #expect(fake.prompts == 0)
    }

    /// Review focus 12: a refusal is a refusal, with where to allow it, and asks nothing.
    @Test func deniedAndRestrictedAreRefusalsAndPromptNothing() async throws {
        for standing in [Access.denied, .restricted] {
            let fake = FakeAuthorizer(standing)
            let reply = try #require(await PermissionBroker().admit(fake))
            #expect(reply.status == ToolReply.denied)
            #expect(reply.text.contains("Reminders"))
            #expect(fake.prompts == 0)
        }
        let reply = try #require(await PermissionBroker().admit(FakeAuthorizer(.denied)))
        #expect(reply.text.contains("Settings"))
    }

    @Test func undeterminedAsksOnceAndFollowsTheAnswer() async throws {
        let yes = FakeAuthorizer(.undetermined, answer: true)
        let broker = PermissionBroker()
        #expect(await broker.admit(yes) == nil)
        #expect(await broker.admit(yes) == nil)
        #expect(yes.prompts == 1)
        let no = FakeAuthorizer(.undetermined, answer: false)
        #expect(try #require(await broker.admit(no)).status == ToolReply.denied)
        #expect(try #require(await broker.admit(no)).status == ToolReply.denied)
        #expect(no.prompts == 1)
    }

    /// Review focus 11: calls at the same moment share one prompt.
    @Test func concurrentCallsShareOnePrompt() async {
        let fake = FakeAuthorizer(.undetermined, answer: true, delay: .milliseconds(200))
        let broker = PermissionBroker()
        await withTaskGroup(of: ToolReply?.self) { group in
            for _ in 0..<5 { group.addTask { await broker.admit(fake) } }
            for await reply in group { #expect(reply == nil) }
        }
        #expect(fake.prompts == 1)
    }
}

@Suite struct ArgumentsTests {
    @Test func wordsOptionsAndFlags() throws {
        let parsed = try Arguments(["add", "Buy milk", "--list", "Home", "--due=2026-09-27", "--done", "--", "--literal"],
                                   options: ["list", "due"], flags: ["done"])
        #expect(parsed.words == ["add", "Buy milk", "--literal"])
        #expect(parsed.options == ["list": "Home", "due": "2026-09-27"])
        #expect(parsed.flags == ["done"])
        #expect(throws: Arguments.Refusal.unknown("--nope")) { try Arguments(["--nope"]) }
        #expect(throws: Arguments.Refusal.missingValue("--list")) { try Arguments(["--list"], options: ["list"]) }
    }
}

@Suite struct ToolDatesTests {
    let zone = TimeZone(identifier: "America/Los_Angeles")!

    @Test func readsOffsetsLocalTimesAndDays() throws {
        let utc = try #require(ToolDates.read("2026-09-26T21:30:00Z", in: zone))
        #expect(utc.hasTime && ToolDates.write(utc.date, in: zone) == "2026-09-26T14:30:00-07:00")
        let local = try #require(ToolDates.read("2026-09-26T14:30", in: zone))
        #expect(local.date == utc.date)
        let day = try #require(ToolDates.read("2026-09-27", in: zone))
        #expect(!day.hasTime && ToolDates.day(day.date, in: zone) == "2026-09-27")
        #expect(ToolDates.read("tomorrow", in: zone) == nil)
        #expect(ToolDates.read("2026-13-40", in: zone) == nil)
    }

    @Test func durations() {
        #expect(ToolDates.duration("90s") == 90)
        #expect(ToolDates.duration("15m") == 900)
        #expect(ToolDates.duration("2h") == 7200)
        #expect(ToolDates.duration("1d") == 86400)
        #expect(ToolDates.duration("30") == 30)
        #expect(ToolDates.duration("-5m") == nil)
        #expect(ToolDates.duration("soon") == nil)
    }
}
