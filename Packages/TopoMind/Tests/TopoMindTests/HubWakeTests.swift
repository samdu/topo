import Foundation
import Testing
import TopoCore
import TopoCoreTesting
import TopoTurn
@testable import TopoMind

/// The probe the hub runs with, as far as a phone is concerned: a lease that names no endpoint
/// is never confirmed (`SocketLeaseProbe` has nowhere to ask), so `acquire()` claims over a
/// phone's fresh lease, and a hold that let a pass run would show it.
struct EndpointOnly: LeaseProbe {
    func confirms(_ lease: Lease) async -> Bool { lease.endpoint != nil }
}

extension HubRig {
    func waking(bound: Duration, check: Duration = .milliseconds(100)) -> HubMind {
        let configuration = self.configuration
        return HubMind(database: db, device: hubID, endpoint: "127.0.0.1:1", probe: EndpointOnly(),
                       brain: brain, login: { await MindLogin.check(configuration) },
                       model: { .sonnet }, timing: fast, poll: .milliseconds(100),
                       holdBound: bound, holdCheck: check)
    }

    /// The phone's reply to `person`, written as the phone's runner writes it: in one batch with
    /// its lease's heartbeat.
    func phoneReplies(to person: Turn, under lease: PrimaryLease) async throws -> Turn? {
        let log = TurnLog(database: db)
        let writer = try await log.writer(for: phoneID)
        return try await writer.append(.assistant, "the phone's answer", parents: [person.ref],
                                       nonce: TurnRunner.replyNonce(for: [person.ref]), renewing: lease)
    }
}

/// A Mac that wakes, or is switched on, while a phone holds a fresh lease and is answering the
/// person's turn: the takeover waits for the phone's reply, its lapse, or the bound.
@Suite(.serialized) struct HubWakeTests {
    @Test func aWakeOverAPhoneMidAnswerRunsNoSecondAnswer() async throws {
        let h = try HubRig()
        let phone = try await h.phoneHoldingLease()
        let person = try await h.phoneSays("hello")
        let hub = h.waking(bound: .seconds(60))
        await hub.turnOn()
        #expect(await eventually { await hub.snapshot().phase == .deferring })
        // Past several lease durations of the phone renewing: the hub claims nothing and asks nothing.
        try await Task.sleep(for: .seconds(2))
        #expect(await h.lease()?.holder == h.phoneID)
        #expect(await hub.snapshot().takeovers == 0)
        #expect(!h.rig.inputs.contains("hello"))

        // The phone's reply lands: the hub takes over, with nothing left to answer.
        #expect(try await h.phoneReplies(to: person, under: phone) != nil)
        #expect(await eventually { await h.lease()?.holder == h.hubID })
        #expect(await hub.snapshot().takeovers == 1)
        try await Task.sleep(for: .seconds(0.5))
        #expect(try await h.replies().count == 1)
        #expect(try await h.replies().first?.ref.device == h.phoneID)
        #expect(!h.rig.inputs.contains("hello"))

        // The next turn is the hub's.
        try await h.phoneSays("again")
        #expect(try await eventually { try await h.replies().count == 2 })
        #expect(try await h.replies().last?.ref.device == h.hubID)
        await phone.abandon()
        await hub.turnOff()
    }

    @Test func aWakeOverAPhoneThatNeverAnswersTakesOverAtTheBound() async throws {
        let h = try HubRig()
        let phone = try await h.phoneHoldingLease()
        try await h.phoneSays("hello")
        let bound = Duration.seconds(2)
        let hub = h.waking(bound: bound)
        let started = ContinuousClock.now
        await hub.turnOn()
        #expect(await eventually { await hub.snapshot().phase == .deferring })
        #expect(await eventually { await h.lease()?.holder == h.hubID })
        #expect(ContinuousClock.now - started >= .milliseconds(1900))
        #expect(try await eventually { try await h.replies().count == 1 })
        #expect(try await h.replies().first?.ref.device == h.hubID)
        await phone.abandon()
        await hub.turnOff()
    }

    @Test func aPhoneThatStopsRenewingIsTakenOverAtItsLapseNotTheBound() async throws {
        let h = try HubRig()
        let phone = try await h.phoneHoldingLease()
        try await h.phoneSays("hello")
        let hub = h.waking(bound: .seconds(60))
        await hub.turnOn()
        #expect(await eventually { await hub.snapshot().phase == .deferring })
        // The phone goes (killed, suspended): its lease lapses one duration after its last renewal.
        await phone.abandon()
        let gone = ContinuousClock.now
        #expect(await eventually { await h.lease()?.holder == h.hubID })
        #expect(ContinuousClock.now - gone < .seconds(5))
        #expect(try await eventually { try await h.replies().count == 1 })
        #expect(try await h.replies().first?.ref.device == h.hubID)
        await hub.turnOff()
    }

    @Test func aWakeOverAnIdlePhoneTakesOverAtOnce() async throws {
        let h = try HubRig()
        let phone = try await h.phoneHoldingLease()
        let person = try await h.phoneSays("hello")
        #expect(try await h.phoneReplies(to: person, under: phone) != nil)
        let hub = h.waking(bound: .seconds(60))
        await hub.turnOn()
        #expect(await eventually(3) { await h.lease()?.holder == h.hubID })
        #expect(await hub.snapshot().takeovers == 1)
        await phone.abandon()
        await hub.turnOff()
    }

    @Test func theVerdict() {
        let me = DeviceID("mac-" + UUID().uuidString.lowercased())
        let phone = DeviceID("ios-1a2b3c4d")
        let now = Date()
        let fresh = Lease(holder: phone, endpoint: nil, epoch: 3, expiresAt: now + 5)
        let said = Turn(ref: TurnRef(device: phone, sequence: 1), parents: [], role: .person, text: "x", at: now - 30)
        let log = Transcript(turns: [said])
        func verdict(_ lease: Lease?, _ t: Transcript?, read: Bool = true, began: Date = now, holding: Bool = false) -> HubMind.HoldOff {
            HubMind.holdOff(lease: lease, leaseRead: read, transcript: t, device: me, now: now, began: began,
                            bound: 600, holding: holding)
        }
        #expect(verdict(fresh, log) == .hold(said.ref))
        #expect(verdict(fresh, Transcript(turns: [])) == .go("none"))
        #expect(verdict(fresh, Transcript(turns: []), holding: true) == .go("replied"))
        let lapsed = Lease(holder: phone, endpoint: nil, epoch: 3, expiresAt: now - 1)
        #expect(verdict(lapsed, log, holding: true) == .go("lapsed"))
        let hub = Lease(holder: DeviceID("mac-" + UUID().uuidString), endpoint: "x:1", epoch: 3, expiresAt: now + 5)
        #expect(verdict(hub, log) == .go("none"))
        #expect(verdict(nil, log, holding: true) == .go("holder"))
        // An old turn, or a hold past its bound.
        let old = Turn(ref: TurnRef(device: phone, sequence: 1), parents: [], role: .person, text: "x", at: now - 601)
        #expect(verdict(fresh, Transcript(turns: [old]), holding: true) == .go("bound"))
        #expect(verdict(fresh, nil, began: now - 601, holding: true) == .go("bound"))
        // A read that failed holds, within the bound.
        #expect(verdict(fresh, nil) == .hold(nil))
        #expect(verdict(nil, nil, read: false) == .hold(nil))
    }
}
