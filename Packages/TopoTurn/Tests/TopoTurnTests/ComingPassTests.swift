import Foundation
import Testing
import TopoCore
import TopoCoreTesting
@testable import TopoTurn

/// A pass told a turn is on its way (a phone's heads-up as its save begins): it renews the lease
/// while it waits, reads the turn by ID once told it is saved, and asks the brain only on a word
/// from the lease this pass heard within `askWithin`.
@Suite struct ComingPassTests {
    /// The phone's limb turn, saved now, which the feed is behind on.
    private func phoneSays(_ words: String, in store: InMemoryRecordDatabase, hiddenFrom feed: FeedBehind? = nil) async throws -> Turn {
        let log = TurnLog(database: store)
        let turn = try await log.writer(for: DeviceID("phone")).append(.person, words, continuing: try await log.read())
        feed?.hide(turn.ref)
        return turn
    }

    private func held(_ runner: TurnRunner, _ lease: PrimaryLease) async throws {
        guard case .primary = try await lease.acquire() else { throw CancellationError() }
    }

    @Test func aTurnToldSavedIsAskedOnceAfterTheRenewalThisPassSent() async throws {
        let store = InMemoryRecordDatabase()
        let feed = FeedBehind(store)
        let brain = ScriptedBrain(.success("hello"))
        let clock = Elapsed()
        let (runner, lease) = try await makeRunner(database: feed, device: "mac-hub", brain: brain, clock: clock)
        try await held(runner, lease)
        let before = feed.leaseWrites
        let renewedBeforeTheTurn = Box<Int>()
        let reply = try await runner.answerPending(since: nil, choosingFrom: { $0 ?? .sonnet }, coming: {
            // The save lands while the pass waits, the renewal sent as it began answered by then.
            for _ in 0..<200 where feed.leaseWrites == before { try? await Task.sleep(for: .milliseconds(5)) }
            renewedBeforeTheTurn.set(feed.leaseWrites - before)
            return .saved(try! await phoneSays("hi", in: store, hiddenFrom: feed).ref)
        })
        #expect(reply?.text == "hello")
        // Mutant: no renewal sent as the pass begins, so none before the turn.
        #expect(renewedBeforeTheTurn.value == 1)
        #expect(brain.requests.count == 1)
        #expect(brain.requests.first?.answering.map(\.text) == ["hi"])
        // The one renewal, answered no longer than `askWithin` before the ask.
        #expect(feed.leaseWrites - before == 1)
        let age = try #require(brain.requests.first?.leaseAge)
        #expect(age <= TurnRunner.askWithin(lease.timing))
        #expect(try await TurnLog(database: store).read().ordered.map(\.text) == ["hi", "hello"])
    }

    @Test func aTurnThatNeverComesAsksNothingAndWritesOnlyTheRenewal() async throws {
        let store = InMemoryRecordDatabase()
        let feed = FeedBehind(store)
        let brain = ScriptedBrain(.success("never"))
        let (runner, lease) = try await makeRunner(database: feed, device: "mac-hub", brain: brain)
        try await held(runner, lease)
        let before = feed.leaseWrites
        let writes = try await store.records(ofType: Turn.recordType).count
        #expect(try await runner.answerPending(since: nil, choosingFrom: { $0 ?? .sonnet }, coming: { .gone }) == nil)
        #expect(brain.requests.isEmpty)
        #expect(feed.leaseWrites - before == 1)
        #expect(try await store.records(ofType: Turn.recordType).count == writes)
    }

    @Test func aTurnAlreadyWaitingIsAnsweredWithoutWaiting() async throws {
        let store = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("hello"))
        let (runner, lease) = try await makeRunner(database: store, device: "mac-hub", brain: brain)
        try await held(runner, lease)
        _ = try await phoneSays("hi", in: store)
        let waits = Box<Int>()
        let reply = try await runner.answerPending(since: nil, choosingFrom: { $0 ?? .sonnet }, coming: {
            waits.set((waits.value ?? 0) + 1)
            return .gone
        })
        #expect(reply?.text == "hello")
        #expect(waits.value == nil)
    }

    @Test func anotherTriggerReadsTheLogAgainAndAnswersWhatWaitsThere() async throws {
        let store = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("to the pad"))
        let (runner, lease) = try await makeRunner(database: store, device: "mac-hub", brain: brain)
        try await held(runner, lease)
        let waits = Box<Int>()
        let reply = try await runner.answerPending(since: nil, choosingFrom: { $0 ?? .sonnet }, coming: {
            waits.set((waits.value ?? 0) + 1)
            // Another device's turn lands, and its push asks for a pass.
            let log = TurnLog(database: store)
            _ = try! await log.writer(for: DeviceID("pad")).append(.person, "from the pad", continuing: try! await log.read())
            return .other
        })
        // Mutant: `other` taken as `gone`, which leaves the pad's turn for the next pass.
        #expect(reply?.text == "to the pad")
        #expect(waits.value == 1)
    }

    @Test func aRenewalOlderThanHalfTheBoundIsSentAgainBesideTheFetch() async throws {
        let store = InMemoryRecordDatabase()
        let feed = FeedBehind(store)
        let brain = ScriptedBrain(.success("hello"))
        let clock = Elapsed()
        let (runner, lease) = try await makeRunner(database: feed, device: "mac-hub", brain: brain, clock: clock)
        try await held(runner, lease)
        let within = TurnRunner.askWithin(lease.timing)
        let before = feed.leaseWrites
        let reply = try await runner.answerPending(since: nil, choosingFrom: { $0 ?? .sonnet }, coming: {
            // Waited past half the bound since the renewal answered.
            try? await Task.sleep(for: .milliseconds(50))
            clock.advance(within * 0.6)
            return .saved(try! await phoneSays("hi", in: store, hiddenFrom: feed).ref)
        })
        #expect(reply?.text == "hello")
        // Mutant: a pass that renewed as it began never renews again.
        #expect(feed.leaseWrites - before == 2)
        #expect((brain.requests.first?.leaseAge ?? .infinity) <= within)
    }

    @Test func aWordOfTheLeaseOlderThanTheBoundAtTheAskIsRenewedFirst() async throws {
        let store = InMemoryRecordDatabase()
        let feed = FeedBehind(store)
        let brain = ScriptedBrain(.success("hello"))
        let clock = Elapsed()
        let (runner, lease) = try await makeRunner(database: feed, device: "mac-hub", brain: brain, clock: clock)
        try await held(runner, lease)
        let within = TurnRunner.askWithin(lease.timing)
        let before = feed.leaseWrites
        let reply = try await runner.answerPending(since: nil, choosingFrom: { $0 ?? .sonnet }, coming: {
            try? await Task.sleep(for: .milliseconds(50))
            let ref = try! await phoneSays("hi", in: store, hiddenFrom: feed).ref
            // The fetch by ID is slow: the renewal is past the bound by the ask.
            feed.beforeFetch = { clock.advance(within + 0.1) }
            return .saved(ref)
        })
        feed.beforeFetch = nil
        #expect(reply?.text == "hello")
        // Mutant: the age not judged at the ask, so the brain is asked on the old word.
        #expect(feed.leaseWrites - before == 2)
        #expect((brain.requests.first?.leaseAge ?? .infinity) <= within)
    }

    @Test func aLeaseFoundTakenDuringTheWaitAsksTheBrainNothing() async throws {
        let store = InMemoryRecordDatabase()
        let feed = FeedBehind(store)
        let brain = ScriptedBrain(.success("never"))
        let (runner, lease) = try await makeRunner(database: feed, device: "mac-hub", brain: brain, probe: AlwaysConfirms())
        try await held(runner, lease)
        do {
            _ = try await runner.answerPending(since: nil, choosingFrom: { $0 ?? .sonnet }, coming: {
                try? await Task.sleep(for: .milliseconds(50))
                let ref = try! await phoneSays("hi", in: store, hiddenFrom: feed).ref
                // While the turn is fetched, after the renewal answered: a phone takes the lease,
                // and the hub's heartbeat meets the claim.
                feed.beforeFetch = {
                    feed.beforeFetch = nil
                    let phone = PrimaryLease(database: store, device: DeviceID("phone"), endpoint: nil, probe: NoSocketProbe(),
                                             sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
                    _ = try! await phone.takeOver()
                    _ = try? await lease.heartbeat()
                }
                return .saved(ref)
            })
            Issue.record("the pass answered")
        } catch TurnRunnerError.notPrimary {
        }
        // Mutant: the ask judged on the renewal's answer alone, not on what the lease knows since.
        #expect(brain.requests.isEmpty)
    }

    /// Inside the bound and before any heartbeat: a claim landed since the renewal answered is not
    /// known, so the brain is asked, and the reply's batch, a compare-and-set over the version
    /// held, is refused with nothing written.
    @Test func aClaimInsideTheBoundIsAskedAndItsReplyRefused() async throws {
        let store = InMemoryRecordDatabase()
        let feed = FeedBehind(store)
        let brain = ScriptedBrain(.success("refused"))
        let (runner, lease) = try await makeRunner(database: feed, device: "mac-hub", brain: brain, probe: AlwaysConfirms())
        try await held(runner, lease)
        do {
            _ = try await runner.answerPending(since: nil, choosingFrom: { $0 ?? .sonnet }, coming: {
                try? await Task.sleep(for: .milliseconds(50))
                let phone = PrimaryLease(database: store, device: DeviceID("phone"), endpoint: nil, probe: NoSocketProbe(),
                                         sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
                _ = try! await phone.takeOver()
                return .saved(try! await phoneSays("hi", in: store, hiddenFrom: feed).ref)
            })
            Issue.record("the pass wrote a reply")
        } catch TurnRunnerError.displaced {
        }
        #expect(brain.requests.count == 1)
        #expect(try await TurnLog(database: store).read().ordered.map(\.text) == ["hi"])
    }

    @Test func aPassOnALeaseNotHeldSendsNoRenewalAsItBegins() async throws {
        let store = InMemoryRecordDatabase()
        let feed = FeedBehind(store)
        let brain = ScriptedBrain(.success("hello"))
        let (runner, _) = try await makeRunner(database: feed, device: "mac-hub", brain: brain)
        let wrote = Box<Int>()
        let reply = try await runner.answerPending(since: nil, choosingFrom: { $0 ?? .sonnet }, coming: {
            wrote.set(feed.leaseWrites)
            return .saved(try! await phoneSays("hi", in: store, hiddenFrom: feed).ref)
        })
        // The lease is asked for the long way once the turn is read, as any pass with no lease does.
        #expect(wrote.value == 0)
        #expect(reply?.text == "hello")
    }
}

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? { lock.withLock { _value } }
    func set(_ v: T) { lock.withLock { _value = v } }
}
