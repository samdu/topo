import AVFoundation
import CallKit
import SwiftUI
import XCTest

@testable import Topo

/// The system behind the call, recorded: every transaction asked for with its completion held
/// for the test to answer, every report, every action fulfilled or failed, and a real provider
/// (no call is placed through it) whose identity the reset compares.
@MainActor
final class FakeCallSystem: CallSystem {
    private(set) var provider: CXProvider
    private(set) weak var delegate: CXProviderDelegate?
    private(set) var requests: [(transaction: CXTransaction, completion: @MainActor (Error?) -> Void)] = []
    private(set) var reports: [(call: UUID, update: CXCallUpdate)] = []
    private(set) var connected: [UUID] = []
    private(set) var fulfilled: [CXAction] = []
    private(set) var failed: [CXAction] = []
    private(set) var replaced = 0

    struct Refused: Error {}

    init() {
        provider = Self.makeProvider()
    }

    private static func makeProvider() -> CXProvider {
        let configuration = CXProviderConfiguration()
        configuration.supportedHandleTypes = [.generic]
        return CXProvider(configuration: configuration)
    }

    func setDelegate(_ delegate: CXProviderDelegate) { self.delegate = delegate }

    /// Records the request and, as CallKit does for the app's own end, performs its end action
    /// on the delegate before the completion is answered.
    func request(_ transaction: CXTransaction, completion: @escaping @MainActor (Error?) -> Void) {
        requests.append((transaction, completion))
        if let end = transaction.actions.first as? CXEndCallAction {
            delegate?.provider?(provider, perform: end)
        }
    }

    func report(_ call: UUID, update: CXCallUpdate) { reports.append((call, update)) }
    func connected(_ call: UUID) { connected.append(call) }
    func fulfill(_ action: CXAction) { fulfilled.append(action) }
    func fail(_ action: CXAction) { failed.append(action) }

    func replace(delegate: CXProviderDelegate) {
        replaced += 1
        provider = Self.makeProvider()
        self.delegate = delegate
    }

    /// The start and end actions asked for so far, in order.
    var starts: [CXStartCallAction] { requests.compactMap { $0.transaction.actions.first as? CXStartCallAction } }
    var ends: [CXEndCallAction] { requests.compactMap { $0.transaction.actions.first as? CXEndCallAction } }
    /// Answers the request at `index` as the system would once it has run it.
    func answer(_ index: Int, _ error: Error? = nil) { requests[index].completion(error) }
}

/// A sleep the test fires: each call waits until `fire()`, or throws when its task is cancelled.
final class ManualSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(id: UUID, duration: Duration, continuation: CheckedContinuation<Void, Error>)] = []
    /// Sleeps cancelled before their continuation was in `pending`.
    private var cancelled: Set<UUID> = []
    private(set) var asked: [Duration] = []

    var waiting: Int { lock.withLock { pending.count } }

    @Sendable
    func sleep(_ duration: Duration) async throws {
        // A task cancelled before it ran (a grace replaced before its sleep began) asks for nothing.
        try Task.checkCancellation()
        let id = UUID()
        lock.withLock { asked.append(duration) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let early = lock.withLock {
                    if cancelled.remove(id) != nil { return true }
                    pending.append((id, duration, continuation))
                    return false
                }
                if early { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiting = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard let index = pending.firstIndex(where: { $0.id == id }) else {
                    cancelled.insert(id)
                    return nil
                }
                return pending.remove(at: index).continuation
            }
            waiting?.resume(throwing: CancellationError())
        }
    }

    /// Ends the oldest sleep still waiting.
    func fire() {
        let next = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        next?.continuation.resume()
    }
}

/// `SpokenCall`'s state machine over the fake system, in Daphne's branches.
@MainActor
final class SpokenCallTests: XCTestCase {
    private var system = FakeCallSystem()
    private var sleep = ManualSleep()
    private var events: [String] = []

    private func call() -> SpokenCall {
        let call = SpokenCall(system: system, sleep: sleep.sleep)
        call.onStart = { [unowned self] in events.append("start") }
        call.onActive = { [unowned self] in events.append("active") }
        call.onInactive = { [unowned self] in events.append("inactive") }
        call.onHangUp = { [unowned self] in events.append("hang-up") }
        call.onOver = { [unowned self] in events.append("over") }
        call.onFailed = { [unowned self] why in events.append("failed: \(why)") }
        return call
    }

    private func tick() async { try? await Task.sleep(for: .milliseconds(20)) }

    private func settle(file: StaticString = #filePath, line: UInt = #line,
                        until condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await tick()
        }
        XCTAssertTrue(condition(), "waited ten seconds", file: file, line: line)
    }

    /// Places the call and has the system perform and activate it.
    private func bringUp(_ call: SpokenCall) {
        call.start()
        call.provider(system.provider, perform: system.starts.last!)
        call.provider(system.provider, didActivate: AVAudioSession.sharedInstance())
    }

    func testPlacedThenActivatedIsUp() {
        let call = call()
        XCTAssertEqual(call.state, .idle)
        call.start()
        XCTAssertEqual(call.state, .starting)
        XCTAssertTrue(call.up)
        XCTAssertEqual(system.starts.count, 1)
        XCTAssertEqual(system.starts[0].handle.value, "Topo")
        let start = system.starts[0]
        call.provider(system.provider, perform: start)
        XCTAssertEqual(events, ["start"], "the category is set at the start action, before it is fulfilled")
        XCTAssertTrue(system.fulfilled.first === start)
        XCTAssertEqual(system.reports.count, 1)
        XCTAssertFalse(system.reports[0].update.hasVideo)
        XCTAssertTrue(system.reports[0].update.supportsHolding, "a phone call holds this one rather than ending it")
        XCTAssertEqual(system.connected, [start.callUUID], "placed is connected: there is no far end")
        XCTAssertFalse(call.active)
        call.provider(system.provider, didActivate: AVAudioSession.sharedInstance())
        XCTAssertEqual(call.state, .up)
        XCTAssertTrue(call.active)
        XCTAssertEqual(events, ["start", "active"])
        XCTAssertEqual(sleep.waiting, 0, "the activation grace is cancelled by the activation")
    }

    func testAStartWhileUpOrStartingIsNothing() {
        let call = call()
        call.start()
        call.start()
        XCTAssertEqual(system.starts.count, 1)
        call.provider(system.provider, perform: system.starts[0])
        call.provider(system.provider, didActivate: AVAudioSession.sharedInstance())
        call.start()
        XCTAssertEqual(system.starts.count, 1)
    }

    func testEndClosesAndTheDeactivationFinishes() {
        let call = call()
        bringUp(call)
        call.end()
        XCTAssertEqual(call.state, .closing)
        XCTAssertFalse(call.up)
        XCTAssertFalse(call.active)
        XCTAssertEqual(system.ends.count, 1)
        XCTAssertEqual(events, ["start", "active"], "nothing is over until the system says so")
        call.provider(system.provider, didDeactivate: AVAudioSession.sharedInstance())
        XCTAssertEqual(call.state, .idle)
        XCTAssertEqual(events, ["start", "active", "over"])
        XCTAssertEqual(sleep.waiting, 0, "the closing grace is cancelled by the finish")
    }

    func testAnEndRefusedFinishesAtOnce() {
        let call = call()
        bringUp(call)
        call.end()
        system.answer(1, FakeCallSystem.Refused())
        XCTAssertEqual(call.state, .idle)
        XCTAssertEqual(events, ["start", "active", "over"])
    }

    func testAnEndOnACallNeverActivatedFinishesAtTheClosingGrace() async {
        let call = call()
        call.start()
        call.provider(system.provider, perform: system.starts[0])
        call.end()
        XCTAssertEqual(call.state, .closing)
        await tick()
        XCTAssertEqual(sleep.asked.last, SpokenCall.closingGrace)
        sleep.fire()
        await tick()
        XCTAssertEqual(call.state, .idle)
        XCTAssertEqual(events, ["start", "over"])
    }

    func testNeverActivatedIsEndedAndFailedAtTheGrace() async {
        let call = call()
        call.start()
        call.provider(system.provider, perform: system.starts[0])
        await tick()
        XCTAssertEqual(sleep.asked, [SpokenCall.activationGrace])
        sleep.fire()
        await tick()
        XCTAssertEqual(system.ends.count, 1, "the system is told too, or its card outlives the exchange")
        XCTAssertEqual(call.state, .idle)
        XCTAssertEqual(events, ["start", "failed: never activated"])
    }

    /// A refused placing is tried again under a new id, twice; the third refusal fails the call.
    func testARefusedPlacingIsTriedAgainTwiceThenFails() async {
        let call = call()
        call.start()
        let first = system.starts[0].callUUID
        system.answer(0, FakeCallSystem.Refused())
        XCTAssertEqual(call.state, .starting, "the first refusal failed the call")
        XCTAssertEqual(events, [])
        await settle { self.sleep.waiting >= 1 }
        sleep.fire()
        await settle { self.system.starts.count == 2 }
        XCTAssertNotEqual(system.starts[1].callUUID, first, "the retry reused the refused id")
        system.answer(system.requests.count - 1, FakeCallSystem.Refused())
        await settle { self.sleep.waiting >= 1 }
        sleep.fire()
        await settle { self.system.starts.count == 3 }
        system.answer(system.requests.count - 1, FakeCallSystem.Refused())
        XCTAssertEqual(call.state, .idle)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].hasPrefix("failed: not placed after 3 attempts"), events[0])
        await tick()
        XCTAssertEqual(system.starts.count, 3, "a failed call was placed again")
    }

    func testAnEndDuringTheRetryPlacesNothingMore() async {
        let call = call()
        call.start()
        system.answer(0, FakeCallSystem.Refused())
        await settle { self.sleep.waiting >= 1 }
        call.end()
        sleep.fire()
        await tick()
        XCTAssertEqual(system.starts.count, 1, "a call ended during its retry was placed again")
    }

    func testAPlacingThatSucceedsOnItsRetryIsTheCall() async {
        let call = call()
        call.start()
        system.answer(0, FakeCallSystem.Refused())
        await settle { self.sleep.waiting >= 1 }
        sleep.fire()
        await settle { self.system.starts.count == 2 }
        call.provider(system.provider, perform: system.starts[1])
        XCTAssertEqual(events, ["start"])
        XCTAssertEqual(call.id, system.starts[1].callUUID)
    }

    func testAStartActionForACallNoLongerWantedIsFailed() {
        let call = call()
        call.start()
        call.end()
        let start = system.starts[0]
        call.provider(system.provider, perform: start)
        XCTAssertTrue(system.failed.first === start)
        XCTAssertEqual(events, [], "its category is not set either")
    }

    func testAHangUpFromTheCardClosesAndTheDeactivationFinishes() {
        let call = call()
        bringUp(call)
        let end = CXEndCallAction(call: call.id!)
        call.provider(system.provider, perform: end)
        XCTAssertTrue(system.fulfilled.contains { $0 === end })
        XCTAssertEqual(call.state, .closing)
        XCTAssertEqual(events, ["start", "active", "hang-up"])
        XCTAssertEqual(system.ends.count, 0, "the system ended it; it is not asked to again")
        call.provider(system.provider, didDeactivate: AVAudioSession.sharedInstance())
        XCTAssertEqual(events, ["start", "active", "hang-up", "over"])
    }

    func testADeactivationWithTheCallUpIsAHold() {
        let call = call()
        bringUp(call)
        call.provider(system.provider, didDeactivate: AVAudioSession.sharedInstance())
        XCTAssertEqual(call.state, .up)
        XCTAssertFalse(call.active)
        XCTAssertEqual(events, ["start", "active", "inactive"])
        call.provider(system.provider, didActivate: AVAudioSession.sharedInstance())
        XCTAssertTrue(call.active)
        XCTAssertEqual(events, ["start", "active", "inactive", "active"])
    }

    func testAProviderResetWithACallUpIsAFailureAndANewProvider() async {
        let call = call()
        bringUp(call)
        let old = system.provider
        call.providerDidReset(old)
        XCTAssertEqual(system.replaced, 1)
        XCTAssertTrue(system.delegate === call)
        XCTAssertEqual(events, ["start", "active"], "not from inside the callback")
        await tick()
        XCTAssertEqual(call.state, .idle)
        XCTAssertEqual(events, ["start", "active", "failed: provider reset: the system's call service restarted"])
        // A reset answered on a provider no longer in use replaces nothing.
        call.providerDidReset(old)
        XCTAssertEqual(system.replaced, 1)
    }

    func testAProviderResetWhileClosingFinishes() async {
        let call = call()
        bringUp(call)
        call.end()
        call.providerDidReset(system.provider)
        await tick()
        XCTAssertEqual(call.state, .idle)
        XCTAssertEqual(events, ["start", "active", "over"])
    }

    func testAStartWhileClosingIsPlacedWhenTheCallIsOver() {
        let call = call()
        bringUp(call)
        call.end()
        call.start()
        XCTAssertTrue(call.up, "wanted again")
        XCTAssertEqual(system.starts.count, 1, "not placed over one still closing")
        call.provider(system.provider, didDeactivate: AVAudioSession.sharedInstance())
        XCTAssertEqual(events, ["start", "active", "over"])
        XCTAssertEqual(system.starts.count, 2, "the finish places it")
        XCTAssertEqual(call.state, .starting)
    }

    func testAnEndWhileClosingForgetsTheCallWantedBehindIt() {
        let call = call()
        bringUp(call)
        call.end()
        call.start()
        call.end()
        call.provider(system.provider, didDeactivate: AVAudioSession.sharedInstance())
        XCTAssertEqual(system.starts.count, 1)
        XCTAssertEqual(call.state, .idle)
    }

    /// The mute is fulfilled and told to `onMute` (the conversation's microphone); the hold is
    /// fulfilled; neither changes the call.
    func testMuteAndHoldAreFulfilledAndTheMuteIsTold() {
        let call = call()
        var mutes: [Bool] = []
        call.onMute = { mutes.append($0) }
        bringUp(call)
        let mute = CXSetMutedCallAction(call: call.id!, muted: true)
        call.provider(system.provider, perform: mute)
        let held = CXSetHeldCallAction(call: call.id!, onHold: true)
        call.provider(system.provider, perform: held)
        XCTAssertTrue(system.fulfilled.contains { $0 === mute })
        XCTAssertTrue(system.fulfilled.contains { $0 === held })
        XCTAssertEqual(call.state, .up)
        XCTAssertEqual(events, ["start", "active"])
        XCTAssertEqual(mutes, [true], "the card's mute did not reach the conversation")
    }
}

/// When a call is wanted: the whole table.
final class CallWantTests: XCTestCase {
    /// A hold or a conversation in the background with the setting on places a call, and a call
    /// up is kept in front for as long as either stands or the microphone is open; a microphone
    /// alone places none.
    func testAHoldOrAConversationInTheBackgroundPlacesACallAndAnUpCallIsKeptInFront() {
        for holding in [false, true] {
            for conversing in [false, true] {
                for phase in [ScenePhase.active, .inactive, .background] {
                    for enabled in [false, true] {
                        for up in [false, true] {
                            for microphone in [false, true] {
                                let want = SpokenCallDriver.wants(holding: holding, conversing: conversing,
                                                                  phase: phase, enabled: enabled, up: up,
                                                                  microphone: microphone)
                                let exchange = holding || conversing
                                XCTAssertEqual(want, enabled && (exchange && phase == .background || up && (exchange || microphone)),
                                               "holding \(holding), conversing \(conversing), \(phase), enabled \(enabled), up \(up), microphone \(microphone)")
                            }
                        }
                    }
                }
            }
        }
    }

    @MainActor
    func testTheDriverPlacesAndEndsTheCallAsTheFactsChange() {
        let system = FakeCallSystem()
        let call = SpokenCall(system: system, sleep: ManualSleep().sleep)
        var enabled = true
        let driver = SpokenCallDriver(call: call, enabled: { enabled }, center: NotificationCenter(), initial: .active)
        driver.holdChanged(true)
        XCTAssertEqual(system.starts.count, 0, "in front")
        driver.scene(.inactive)
        XCTAssertEqual(system.starts.count, 0, "Control Center is not the background")
        driver.scene(.background)
        XCTAssertEqual(system.starts.count, 1)
        driver.holdChanged(true)
        XCTAssertEqual(system.starts.count, 1, "told again, placed once")
        driver.scene(.inactive)
        driver.scene(.active)
        XCTAssertEqual(system.ends.count, 0, "coming forward with the hold standing ended the exchange's call")
        driver.holdChanged(false)
        XCTAssertEqual(system.ends.count, 1, "the hold's end in front did not end the call")
        call.provider(system.provider, didDeactivate: AVAudioSession.sharedInstance())
        driver.holdChanged(true)
        XCTAssertEqual(system.starts.count, 1, "a hold in front placed a call")
        driver.holdChanged(false)
        enabled = false
        driver.scene(.background)
        XCTAssertEqual(system.starts.count, 1, "the setting off places none")
        enabled = true
        driver.holdChanged(false)
        driver.scene(.background)
        XCTAssertEqual(system.starts.count, 1, "nothing held places none")
    }

    @MainActor
    func testTheDriverFollowsUIKitsBackground() {
        let system = FakeCallSystem()
        let call = SpokenCall(system: system, sleep: ManualSleep().sleep)
        let center = NotificationCenter()
        let driver = SpokenCallDriver(call: call, enabled: { true }, center: center, initial: .active)
        driver.holdChanged(true)
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertEqual(system.starts.count, 0, "resigning active is not the background")
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertEqual(system.starts.count, 1, "the background places the call")
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(system.ends.count, 0, "coming forward with the hold standing ended the call")
        XCTAssertTrue(call.up)
        driver.holdChanged(false)
        XCTAssertEqual(system.ends.count, 1)
        call.provider(system.provider, didDeactivate: AVAudioSession.sharedInstance())
        driver.holdChanged(true)
        XCTAssertEqual(system.starts.count, 1, "active is not the background: no call is placed in front")
        XCTAssertFalse(call.up)
        withExtendedLifetime(driver) {}
    }

    /// A press in front under the kept call: the waits it ends drop the hold, and the open
    /// microphone keeps the call, so the session it opens on is not ended under it.
    @MainActor
    func testAnOpeningMicrophoneKeepsTheCallUpInFront() {
        let system = FakeCallSystem()
        let call = SpokenCall(system: system, sleep: ManualSleep().sleep)
        let driver = SpokenCallDriver(call: call, enabled: { true }, center: NotificationCenter(), initial: .background)
        driver.holdChanged(true)
        call.provider(system.provider, perform: system.starts[0])
        driver.scene(.active)
        driver.microphoneChanged(true)
        driver.holdChanged(false)
        XCTAssertEqual(system.ends.count, 0, "the press's ended wait ended the call under the microphone")
        driver.microphoneChanged(false)
        XCTAssertEqual(system.ends.count, 1, "the closed microphone with nothing held kept the call")
        driver.microphoneChanged(true)
        XCTAssertEqual(system.starts.count, 1, "a microphone in front placed a call")
    }

    /// A retry or a call wanted behind a closing one is not placed once the app is in front.
    @MainActor
    func testNothingIsPlacedInFront() async {
        let system = FakeCallSystem()
        let sleep = ManualSleep()
        let call = SpokenCall(system: system, sleep: sleep.sleep)
        let driver = SpokenCallDriver(call: call, enabled: { true }, center: NotificationCenter(), initial: .background)
        driver.holdChanged(true)
        system.answer(0, FakeCallSystem.Refused())
        for _ in 0..<100 where sleep.waiting == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        driver.scene(.active)
        sleep.fire()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(system.starts.count, 1, "the retry placed a call in front")
        XCTAssertFalse(call.up)

        // Behind the lock: the hold drops, the call closes, a hold comes back before the
        // deactivation, and the app comes forward before it lands.
        driver.scene(.background)
        driver.holdChanged(true)
        XCTAssertEqual(system.starts.count, 2)
        call.provider(system.provider, perform: system.starts[1])
        driver.holdChanged(false)
        driver.holdChanged(true)
        driver.scene(.active)
        call.provider(system.provider, didDeactivate: AVAudioSession.sharedInstance())
        XCTAssertEqual(system.starts.count, 2, "the call wanted behind the closing one was placed in front")
    }

    /// Resigning active on the way forward (`willEnterForeground` before `didBecomeActive`) is
    /// in front too: a retry landing then places nothing.
    @MainActor
    func testNothingIsPlacedOnTheWayToTheFront() async {
        let system = FakeCallSystem()
        let sleep = ManualSleep()
        let call = SpokenCall(system: system, sleep: sleep.sleep)
        let driver = SpokenCallDriver(call: call, enabled: { true }, center: NotificationCenter(), initial: .background)
        driver.holdChanged(true)
        system.answer(0, FakeCallSystem.Refused())
        for _ in 0..<100 where sleep.waiting == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        driver.scene(.inactive)
        sleep.fire()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(system.starts.count, 1, "the retry placed a call on the way to the front")
        XCTAssertFalse(call.up)
    }

    /// The card's hang-up with the microphone flag still standing (a decode running past the
    /// hang-up) and the hang-up's own effects asking for the call (the hold's drop, then the
    /// conversation's end): no call is placed behind the one hung up.
    @MainActor
    func testAHangUpPlacesNoCallBehindIt() {
        let system = FakeCallSystem()
        let call = SpokenCall(system: system, sleep: ManualSleep().sleep)
        let driver = SpokenCallDriver(call: call, enabled: { true }, center: NotificationCenter(), initial: .background)
        driver.holdChanged(true)
        call.provider(system.provider, perform: system.starts[0])
        call.provider(system.provider, didActivate: AVAudioSession.sharedInstance())
        driver.conversingChanged(true)
        driver.microphoneChanged(true)
        call.onHangUp = {
            driver.holdChanged(false)
            driver.conversingChanged(false)
        }
        call.provider(system.provider, perform: CXEndCallAction(call: call.id!))
        call.provider(system.provider, didDeactivate: AVAudioSession.sharedInstance())
        XCTAssertEqual(system.starts.count, 1, "a call was placed behind the one hung up")
        driver.microphoneChanged(false)
        XCTAssertEqual(system.starts.count, 1)
    }

    @MainActor
    func testADriverMadeInTheBackgroundPlacesTheCallAtTheFirstHold() {
        let system = FakeCallSystem()
        let call = SpokenCall(system: system, sleep: ManualSleep().sleep)
        let driver = SpokenCallDriver(call: call, enabled: { true }, center: NotificationCenter(), initial: .background)
        driver.holdChanged(true)
        XCTAssertEqual(system.starts.count, 1, "a launch into the background is the background")
    }
}

/// The session's call phase and the hand-back, over the seams.
@MainActor
final class AudioSessionCallTests: XCTestCase {
    private var active = true

    private func audio(_ seams: Seams) -> AudioSession {
        AudioSession(center: NotificationCenter(), configure: seams.configure, setCategory: seams.setCategory,
                     deactivate: seams.deactivate, isActive: { [unowned self] in active })
    }

    /// CallKit routes an activated call to the earpiece: the activation overrides it to the
    /// speaker, and the call's end clears the override. A route of headphones is left alone.
    func testTheCallsEarpieceIsOverriddenToTheSpeakerAndClearedAtTheEnd() {
        let seams = Seams()
        var route: [AVAudioSession.Port] = [.builtInReceiver]
        var overrides: [Bool] = []
        let audio = AudioSession(center: NotificationCenter(), configure: seams.configure, setCategory: seams.setCategory,
                                 deactivate: seams.deactivate, isActive: { [unowned self] in active },
                                 outputs: { route }, speakerOverride: { overrides.append($0) })
        active = false
        audio.callPlaced()
        audio.callActivated()
        XCTAssertEqual(overrides, [true], "the call's earpiece was left as the route")
        audio.callOver()
        XCTAssertEqual(overrides, [true, false], "the override outlived the call")

        // Over an open microphone the clear waits: a route change under its tap is the change
        // the session is kept from.
        audio.callPlaced()
        audio.callActivated()
        XCTAssertEqual(overrides, [true, false, true])
        audio.microphone(open: true)
        audio.callOver()
        XCTAssertEqual(overrides, [true, false, true], "the override was cleared under the open microphone")
        audio.microphone(open: false)
        XCTAssertEqual(overrides, [true, false, true, false])

        route = [.bluetoothHFP]
        audio.callPlaced()
        audio.callActivated()
        audio.callOver()
        XCTAssertEqual(overrides, [true, false, true, false], "AirPods were overridden to the speaker")
    }

    /// An ended call's session is still active until the system deactivates it, and nothing
    /// new goes on it: `closing` refuses every path and is changing hands until the call is over.
    /// A call that never took the session has nothing to close.
    func testAClosingCallsSessionRefusesEveryPathUntilItIsOver() {
        let seams = Seams()
        let audio = audio(seams)
        audio.callClosing()
        XCTAssertEqual(audio.call, .none, "a call that never took the session closed one")
        audio.callPlaced()
        audio.callActivated()
        XCTAssertNoThrow(try audio.ensureLive())
        audio.callClosing()
        XCTAssertEqual(audio.call, .closing)
        XCTAssertTrue(audio.callChangingHands)
        XCTAssertThrowsError(try audio.ensureActive())
        XCTAssertThrowsError(try audio.ensureLive(), "a cue was let onto a closing session")
        audio.callOver()
        XCTAssertEqual(audio.call, .none)
        XCTAssertFalse(audio.callChangingHands)
        XCTAssertNoThrow(try audio.ensureActive())
    }

    func testACallsConfigureActivatesNothing() {
        let seams = Seams()
        let audio = audio(seams)
        audio.wantRecord(true, for: .warm)
        audio.wantVoiceProcessing(true)
        seams.forget()
        active = false
        audio.callPlaced()
        XCTAssertEqual(seams.lines, ["category set"])
        XCTAssertEqual(seams.categories.map { [$0.record, $0.processed] }, [[true, true]])
        XCTAssertEqual(audio.call, .placed)
        XCTAssertThrowsError(try audio.ensureActive()) { error in
            XCTAssertTrue(error is AudioSession.CallNotActive, "\(error)")
        }
        XCTAssertEqual(seams.lines, ["category set"], "a path under the placed call activates nothing")
        audio.callActivated()
        XCTAssertNoThrow(try audio.ensureActive())
        XCTAssertEqual(seams.lines, ["category set"], "the system activated; nothing here does")
        XCTAssertEqual(seams.deactivations, [])
    }

    /// A change of voice processing asked for while a hold keeps the session waits for it, and
    /// the call placed meanwhile sets the mode the session is in, not the one wanted: the wanted
    /// one is applied when the call is over and nothing keeps the session.
    func testACallIsPlacedWithTheModeAppliedNotTheOneWaiting() {
        let seams = Seams()
        let audio = audio(seams)
        audio.wantRecord(true, for: .warm)
        audio.wantAlive(true, for: .awaitingReply("turn"))
        audio.wantVoiceProcessing(true)
        seams.forget()
        audio.callPlaced()
        XCTAssertEqual(seams.categories.map { [$0.record, $0.processed] }, [[true, false]],
                       "the call applied the voice processing that was waiting for the hold")
        XCTAssertFalse(audio.voiceProcessed)
        audio.callActivated()
        audio.wantAlive(false, for: .awaitingReply("turn"))
        audio.callOver()
        XCTAssertEqual(seams.modes.last, true, "what waited was not applied once the call was over")
        XCTAssertTrue(audio.voiceProcessed)
    }

    /// Two presses waiting on a closing call, each with its own bound: the first bound running
    /// out answers the first alone, and the second waits on for the call's end.
    func testEachSettlingWaitEndsAtItsOwnBound() async {
        let seams = Seams()
        let audio = audio(seams)
        audio.wantRecord(true, for: .warm)
        audio.callPlaced()
        audio.callActivated()
        audio.callClosing()
        let first = ManualSleep(), second = ManualSleep()
        var answers: [String: Bool] = [:]
        let a = Task { @MainActor in answers["first"] = await audio.settled(within: .seconds(1), sleep: first.sleep) }
        let b = Task { @MainActor in answers["second"] = await audio.settled(within: .seconds(3), sleep: second.sleep) }
        for _ in 0..<200 where first.waiting + second.waiting < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(first.waiting + second.waiting, 2, "the two waits did not start")
        first.fire()
        await a.value
        XCTAssertEqual(answers["first"], false, "the first bound answered as settled")
        await Task.yield()
        XCTAssertNil(answers["second"], "the first bound ended the second wait too")
        audio.callOver()
        await b.value
        XCTAssertEqual(answers["second"], true)
    }

    func testTheSessionIsLiveUnderAnActiveCallWhateverInvalidatedIt() {
        let seams = Seams()
        let audio = audio(seams)
        audio.callPlaced()
        audio.callActivated()
        // The `.began` iOS posts at the lock screen marks the session invalid; under the call it
        // is the system's and live.
        audio.invalidate()
        XCTAssertNoThrow(try audio.ensureActive())
        XCTAssertEqual(seams.records, [], "and nothing is configured beside the call")
        audio.callDeactivated()
        XCTAssertThrowsError(try audio.ensureActive())
        audio.callActivated()
        XCTAssertNoThrow(try audio.ensureActive())
    }

    func testTheSessionStaysLiveUnderAnActiveCallWhateverInvalidatesIt() {
        let seams = Seams()
        let audio = audio(seams)
        audio.callPlaced()
        XCTAssertThrowsError(try audio.ensureLive(), "placed and not yet activated: not live")
        audio.callActivated()
        // The `.began` iOS posts at the lock screen, or as the call takes the session, and a
        // queue that found its engine dead: neither is the call's session gone.
        audio.invalidate()
        XCTAssertNoThrow(try audio.ensureLive(), "a cue after the reply under the call is played")
        audio.callDeactivated()
        XCTAssertThrowsError(try audio.ensureLive(), "taken with the call standing: not live")
        audio.callActivated()
        audio.callOver()
        XCTAssertThrowsError(try audio.ensureLive(), "the call over: the session is no longer the system's")
        XCTAssertEqual(seams.records, [], "and nothing was configured for any of it")
    }

    func testTheWarmClaimLeavesAnotherAppPlayingAlone() {
        let seams = Seams()
        var playing = true
        let audio = AudioSession(center: NotificationCenter(), configure: seams.configure, setCategory: seams.setCategory,
                                 deactivate: seams.deactivate, isActive: { true },
                                 otherAudioPlaying: { playing }, recordPermitted: { true })
        audio.warmRecord(true)
        XCTAssertEqual(seams.records, [], "a podcast playing as Topo comes forward is not paused by it")
        XCTAssertEqual(seams.deactivations, [])
        audio.warmRecord(false)
        XCTAssertEqual(seams.records, [], "and nothing was taken to give back")
        playing = false
        audio.warmRecord(true)
        XCTAssertEqual(seams.records, [true], "with nothing else playing the record configuration is warmed")
    }

    func testAnExchangeBegunOverAnotherAppKeepsTheRecordConfigurationUntilTopoLeavesTheFront() {
        let seams = Seams()
        let audio = AudioSession(center: NotificationCenter(), configure: seams.configure, setCategory: seams.setCategory,
                                 deactivate: seams.deactivate, isActive: { true },
                                 otherAudioPlaying: { true }, recordPermitted: { true })
        audio.warmRecord(true)
        XCTAssertEqual(seams.records, [])
        // The press: the record configuration is taken, which is where the podcast pauses.
        audio.wantRecord(true, for: .chat)
        audio.microphone(open: true)
        XCTAssertEqual(seams.records, [true])
        // The release: the press's claim goes as the microphone closes, before the wait's hold.
        audio.wantRecord(false, for: .chat)
        audio.microphone(open: false)
        XCTAssertEqual(seams.records, [true], "the session went back to the quiet configuration between the release and the wait")
        XCTAssertEqual(seams.deactivations, [], "and the podcast was told to resume under the reply")
        audio.wantAlive(true, for: .awaitingReply("n"))
        audio.wantAlive(false, for: .awaitingReply("n"))
        XCTAssertEqual(seams.records, [true], "the reply's end in front keeps it, as the warm claim does")
        // Topo leaves the front: the quiet configuration, the podcast told to resume first.
        audio.warmRecord(false)
        XCTAssertEqual(seams.records, [true, false])
        XCTAssertEqual(seams.deactivations, [true])
    }

    func testTheWarmClaimWaitsForThePermission() {
        let seams = Seams()
        let audio = AudioSession(center: NotificationCenter(), configure: seams.configure, setCategory: seams.setCategory,
                                 deactivate: seams.deactivate, isActive: { true },
                                 otherAudioPlaying: { false }, recordPermitted: { false })
        audio.warmRecord(true)
        XCTAssertEqual(seams.records, [])
    }

    func testTheClaimsWaitUnderTheCallAndApplyWhenItIsOverInFront() {
        let seams = Seams()
        let audio = audio(seams)
        audio.wantRecord(true, for: .chat)
        seams.forget()
        audio.callPlaced()
        audio.callActivated()
        audio.wantRecord(false, for: .chat)
        XCTAssertEqual(seams.records, [], "a claim under the call configures nothing")
        audio.callOver()
        XCTAssertEqual(audio.call, .none)
        XCTAssertEqual(seams.records, [false], "what waited is applied, in front")
        XCTAssertEqual(seams.lines, ["category set", "handed back", "activate ok"],
                       "leaving the record configuration tells other audio first")
    }

    func testNothingIsHandedBackWhileTheCallStands() {
        let seams = Seams()
        let audio = audio(seams)
        audio.wantRecord(true, for: .warm)
        audio.wantAlive(true, for: .awaitingReply("n"))
        active = false
        audio.wantRecord(false, for: .warm)
        seams.forget()
        audio.callPlaced()
        audio.callActivated()
        audio.wantAlive(false, for: .awaitingReply("n"))
        XCTAssertEqual(seams.deactivations, [], "the session is the system's until the call is over")
        XCTAssertEqual(seams.records, [])
        audio.callOver()
        XCTAssertEqual(seams.deactivations, [true])
        XCTAssertEqual(seams.lines, ["category set", "handed back"])
        XCTAssertEqual(seams.records, [], "the claims wait for the next audio path")
        active = true
        XCTAssertNoThrow(try audio.ensureActive())
        XCTAssertEqual(seams.records, [false], "which configures for the claims as they stand")
    }

    func testTheLastHoldGoneAwayHandsBackAfterTheKeeperIsTold() {
        let seams = Seams()
        let audio = audio(seams)
        var toldBeforeHandBack: Bool?
        audio.onHoldChanged = { held in
            if !held { toldBeforeHandBack = seams.deactivations.isEmpty }
        }
        audio.wantRecord(true, for: .warm)
        audio.wantAlive(true, for: .awaitingReply("n"))
        active = false
        seams.forget()
        audio.wantAlive(false, for: .awaitingReply("n"))
        XCTAssertEqual(seams.deactivations, [true])
        XCTAssertEqual(toldBeforeHandBack, true, "the speaker stops its engine before the session is let go")
        XCTAssertEqual(seams.records, [], "nothing is activated from the background")
    }

    func testTheLastHoldGoneInFrontHandsNothingBack() {
        let seams = Seams()
        let audio = audio(seams)
        audio.wantRecord(true, for: .warm)
        audio.wantAlive(true, for: .awaitingReply("n"))
        seams.forget()
        audio.wantAlive(false, for: .awaitingReply("n"))
        XCTAssertEqual(seams.deactivations, [], "in front the warm claim keeps the session")
        XCTAssertEqual(seams.records, [])
    }

    func testEnteringTheQuietConfigurationHandsBackFirst() {
        let seams = Seams()
        let audio = audio(seams)
        audio.wantRecord(true, for: .chat)
        audio.wantRecord(false, for: .chat)
        XCTAssertEqual(seams.lines, ["activate ok", "handed back", "activate ok"])
        XCTAssertEqual(seams.records, [true, false])
        XCTAssertEqual(seams.deactivations, [true])
        seams.forget()
        audio.wantRecord(true, for: .chat)
        XCTAssertEqual(seams.deactivations, [], "taking the record configuration hands nothing back")
    }

    func testAHandBackRefusedIsLoggedAndTheSessionStillConfigures() {
        let seams = Seams()
        let audio = audio(seams)
        audio.wantRecord(true, for: .chat)
        seams.deactivationError = Seams.Refused()
        audio.wantRecord(false, for: .chat)
        XCTAssertEqual(seams.lines, ["activate ok", "deactivate failed", "activate ok"])
        XCTAssertNoThrow(try audio.ensureActive())
        seams.forget()
        audio.wantAlive(true, for: .awaitingReply("n"))
        active = false
        audio.wantAlive(false, for: .awaitingReply("n"))
        XCTAssertEqual(seams.lines, ["deactivate failed"])
        active = true
        XCTAssertNoThrow(try audio.ensureActive())
        XCTAssertEqual(seams.lines, ["deactivate failed", "activate ok"], "the session is marked and configured afresh")
    }

    func testAHandBackLeavesNoClaimToApplyLater() {
        let seams = Seams()
        let audio = audio(seams)
        audio.wantRecord(true, for: .warm)
        audio.wantAlive(true, for: .awaitingReply("n"))
        active = false
        audio.wantRecord(false, for: .warm)
        audio.wantAlive(false, for: .awaitingReply("n"))
        XCTAssertEqual(seams.deactivations, [true])
        seams.forget()
        active = true
        audio.wantRecord(true, for: .warm)
        XCTAssertEqual(seams.records, [true], "the foreground configures from the claims as they stand")
        audio.wantAlive(true, for: .awaitingReply("n2"))
        audio.wantAlive(false, for: .awaitingReply("n2"))
        XCTAssertEqual(seams.records, [true], "and a hold dropped in front has nothing left over to apply")
    }

    func testACategoryThatWillNotSetLeavesTheCallToGoOn() {
        let seams = Seams()
        let audio = audio(seams)
        seams.categoryError = Seams.Refused()
        audio.callPlaced()
        XCTAssertEqual(audio.call, .placed)
        XCTAssertEqual(seams.lines, ["category failed"])
        audio.callActivated()
        XCTAssertNoThrow(try audio.ensureActive())
    }
}

/// The speaker with a call attached: the queue, the keeper, the ceiling and the hang-up.
@MainActor
final class SpokenCallSpeakerTests: XCTestCase {
    private var active = true
    private var seams = Seams()
    private var center = NotificationCenter()
    private var system = FakeCallSystem()
    private var sleep = ManualSleep()
    private var settled: [String] = []

    private func settle(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                        until condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<600 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "waited six seconds for \(what)", file: file, line: line)
    }

    private func tick() async { try? await Task.sleep(for: .milliseconds(20)) }

    private func fixture(ceiling: Duration = .seconds(120)) async -> (Speaker, SpokenCall, AudioSession) {
        let audio = AudioSession(center: center, configure: seams.configure, setCategory: seams.setCategory,
                                 deactivate: seams.deactivate, isActive: { [unowned self] in active })
        let voice = Voice(engine: ScriptedVoice())
        voice.load(base: URL(fileURLWithPath: "/dev/null"))
        await settle("the voice to load") { voice.state == .ready }
        let speaker = Speaker(audio: audio, voice: voice, center: center,
                              makeEngine: { [seams] in seams.makePlayEngine(rate: Voice.rate) }, ceiling: ceiling)
        speaker.settled = { [unowned self] nonce in settled.append(nonce) }
        let call = SpokenCall(system: system, sleep: sleep.sleep)
        speaker.attach(call)
        // The warm claim in front, then the lock drops it under the hold, as the app does.
        audio.wantRecord(true, for: .warm)
        return (speaker, call, audio)
    }

    /// The phone locks with the wait standing: the warm claim goes, deferred, and the call is placed.
    private func lock(_ audio: AudioSession, _ call: SpokenCall) {
        active = false
        audio.wantRecord(false, for: .warm)
        call.start()
        call.provider(system.provider, perform: system.starts.last!)
    }

    private func activate(_ call: SpokenCall) {
        call.provider(system.provider, didActivate: AVAudioSession.sharedInstance())
    }

    func testTheQueueStaysDeadUntilTheCallActivates() async {
        let (speaker, call, audio) = await fixture()
        speaker.awaitReply("n", readAloud: true)
        XCTAssertTrue(speaker.keeping)
        lock(audio, call)
        XCTAssertEqual(audio.call, .placed)
        XCTAssertTrue(speaker.dead, "the engine is dead from the placing: nothing is scheduled on a session the system is taking")
        XCTAssertFalse(speaker.running)
        // The system's activation reconfigures the hardware; a rebuild asked for now is refused.
        center.post(name: .AVAudioEngineConfigurationChange, object: seams.engines.last)
        await settle("the rebuild to be refused") { speaker.dead }
        XCTAssertFalse(speaker.keeping, "no keeper on a session the system has not activated")
        XCTAssertTrue(speaker.holding, "the hold stands")
        XCTAssertFalse(seams.lines.suffix(from: 2).contains("activate ok"), "\(seams.lines)")
        activate(call)
        XCTAssertFalse(speaker.dead)
        XCTAssertTrue(speaker.keeping, "the keeper is back on the call's session")
        XCTAssertFalse(seams.lines.contains("activate ok") && seams.records.count > 1, "and nothing here activated it: \(seams.lines)")
        speaker.stop()
    }

    func testTheKeeperComesBackWhenTheCallIsOverWithAHoldStanding() async {
        let (speaker, call, audio) = await fixture()
        speaker.awaitReply("n", readAloud: true)
        lock(audio, call)
        center.post(name: .AVAudioEngineConfigurationChange, object: seams.engines.last)
        await settle("the rebuild to be refused") { speaker.dead }
        activate(call)
        XCTAssertTrue(speaker.keeping)
        // Unlocked: the app comes forward, takes its warm claim (deferred under the hold) and
        // ends the call; the keeper takes over in front.
        active = true
        seams.forget()
        audio.wantRecord(true, for: .warm)
        call.end()
        call.provider(system.provider, didDeactivate: AVAudioSession.sharedInstance())
        XCTAssertEqual(audio.call, .none)
        XCTAssertTrue(speaker.holding)
        XCTAssertTrue(speaker.keeping, "the keeper is back on a session activated in front")
        XCTAssertEqual(seams.lines.filter { $0 == "activate ok" }.count, 1, "\(seams.lines)")
        XCTAssertEqual(seams.deactivations, [], "nothing is handed back with a hold standing")
        speaker.stop()
    }

    func testNothingRunsOnceTheCallIsOverAndNothingIsHeld() async {
        let (speaker, call, audio) = await fixture()
        speaker.awaitReply("n", readAloud: true)
        lock(audio, call)
        activate(call)
        XCTAssertTrue(speaker.running)
        call.provider(system.provider, perform: CXEndCallAction(call: call.id!))
        XCTAssertEqual(audio.call, .closing, "the card's hang-up left the session open to new paths")
        XCTAssertFalse(speaker.holding, "the hang-up ends the wait")
        XCTAssertFalse(speaker.running, "and the engine with it")
        XCTAssertEqual(seams.deactivations, [], "not yet: the call is closing")
        call.provider(system.provider, didDeactivate: AVAudioSession.sharedInstance())
        XCTAssertEqual(audio.call, .none)
        XCTAssertFalse(speaker.running)
        XCTAssertEqual(seams.deactivations, [true], "the podcast is told it may resume")
    }

    func testTheWaitIsNotCappedWhileACallIsUp() async {
        let (speaker, call, audio) = await fixture(ceiling: .milliseconds(40))
        speaker.awaitReply("n", readAloud: true)
        lock(audio, call)
        activate(call)
        XCTAssertEqual(speaker.capped("n"), "the ceiling passed under the call; the wait stands")
        XCTAssertEqual(speaker.awaiting, ["n"])
        XCTAssertTrue(speaker.holding)
        active = true
        call.end()
        call.provider(system.provider, didDeactivate: AVAudioSession.sharedInstance())
        XCTAssertTrue(speaker.capped("n").hasPrefix("capped at"), "with the call over the ceiling caps")
        XCTAssertEqual(speaker.awaiting, [])
        XCTAssertFalse(speaker.holding)
    }

    func testAHangUpFromTheCardIsAMute() async {
        let (speaker, call, audio) = await fixture()
        speaker.awaitReply("n1", readAloud: true)
        speaker.awaitReply("n2", readAloud: true)
        lock(audio, call)
        activate(call)
        call.provider(system.provider, perform: CXEndCallAction(call: call.id!))
        XCTAssertEqual(settled, ["n1", "n2"], "every awaited turn's mark is cleared, as a muted reply's is")
        XCTAssertEqual(speaker.awaiting, [])
        XCTAssertFalse(speaker.holding)
        XCTAssertFalse(speaker.speaking)
        // The reply that lands now is offered to a speaker with no wait for it: `speak` would
        // read it in front, so the mark is what keeps it unread, and the mark is gone.
    }

    func testAReplyLandingWhileTheCallsSessionChangesHandsWaitsForTheActivation() async {
        let (speaker, call, audio) = await fixture()
        speaker.awaitReply("n", readAloud: true)
        lock(audio, call)
        XCTAssertTrue(audio.callChangingHands)
        XCTAssertTrue(speaker.speak("Hello there.", answering: "n"), "taken, to be read at the activation")
        XCTAssertTrue(speaker.waitingForMicrophone)
        XCTAssertFalse(speaker.speaking)
        XCTAssertEqual(speaker.awaiting, ["n"], "its wait stands")
        XCTAssertEqual(settled, [], "and its turn stays marked")
        activate(call)
        await settle("the reply to be read") { speaker.report.started }
        XCTAssertEqual(settled, ["n"])
        XCTAssertEqual(speaker.awaiting, [])
        XCTAssertFalse(speaker.waitingForMicrophone)
        speaker.stop()
    }

    func testWhatTheGuestWritesAfterAHangUpIsNotRead() async {
        let (speaker, call, audio) = await fixture()
        speaker.awaitReply("n", readAloud: true)
        lock(audio, call)
        activate(call)
        call.provider(system.provider, perform: CXEndCallAction(call: call.id!))
        XCTAssertEqual(settled, ["n"])
        call.provider(system.provider, didDeactivate: AVAudioSession.sharedInstance())
        active = true
        speaker.speak(writing: "Hello there. And more", answering: "n")
        XCTAssertFalse(speaker.speaking, "the turn hung up on is not begun from what the guest writes next")
        XCTAssertEqual(speaker.report.speaks, 0)
        speaker.writingEnded("n")
        speaker.speak(writing: "Hello again. And more", answering: "n2")
        XCTAssertTrue(speaker.speaking, "the next turn's writing is read")
        speaker.stop()
    }

    /// A reply landing as the call closes is read on the session after it, not on the one the
    /// system is about to deactivate.
    func testAReplyLandingWhileTheCallClosesWaitsForItsEnd() async {
        let (speaker, call, audio) = await fixture()
        speaker.awaitReply("n", readAloud: true)
        lock(audio, call)
        activate(call)
        active = true
        speaker.awaitReply("m", readAloud: true)
        call.end()
        XCTAssertEqual(audio.call, .closing)
        XCTAssertTrue(speaker.speak("Hello there.", answering: "m"), "taken, to be read at the call's end")
        XCTAssertFalse(speaker.speaking, "read onto the closing call's session")
        call.provider(system.provider, didDeactivate: AVAudioSession.sharedInstance())
        await settle("the reply to be read") { speaker.report.started }
        speaker.stop()
    }

    func testAReplyThatWaitedForAnActivationThatNeverCameIsReadWhenTheCallIsOver() async {
        let (speaker, call, audio) = await fixture()
        speaker.awaitReply("n", readAloud: true)
        lock(audio, call)
        XCTAssertTrue(speaker.speak("Hello there.", answering: "n"))
        XCTAssertTrue(speaker.waitingForMicrophone)
        // Unlocked at once: the app comes forward and ends the call before the system activated it.
        active = true
        audio.wantRecord(true, for: .warm)
        call.end()
        await tick()
        sleep.fire()
        await settle("the call to be over") { call.state == .idle }
        await settle("the reply to be read") { speaker.report.started }
        XCTAssertFalse(speaker.waitingForMicrophone)
        XCTAssertEqual(settled, ["n"])
        XCTAssertEqual(speaker.awaiting, [])
        speaker.stop()
    }

    func testAHangUpWhileTheReplyIsBeingReadClearsItsMarkToo() async {
        let (speaker, call, audio) = await fixture()
        speaker.awaitReply("n", readAloud: true)
        lock(audio, call)
        activate(call)
        speaker.speak(writing: "Hello there. And", answering: "n")
        await settle("the reading to begin") { speaker.report.started }
        XCTAssertEqual(speaker.awaiting, [], "a reply being read has no wait left")
        call.provider(system.provider, perform: CXEndCallAction(call: call.id!))
        XCTAssertEqual(settled, ["n"], "the turn being read is settled, so a relaunch does not read it")
        XCTAssertFalse(speaker.speaking)
        call.provider(system.provider, didDeactivate: AVAudioSession.sharedInstance())
        active = true
        speaker.speak(writing: "Hello there. And more.", answering: "n")
        XCTAssertFalse(speaker.speaking, "nor is what the guest writes of it next")
    }

    func testAHangUpWhileAReplyIsReadStopsItAndNothingReadsItAgain() async {
        let (speaker, call, audio) = await fixture()
        speaker.awaitReply("n", readAloud: true)
        lock(audio, call)
        activate(call)
        XCTAssertTrue(speaker.speak("Hello there. And more. And more again.", answering: "n"))
        await settle("the reading to begin") { speaker.report.started }
        XCTAssertTrue(speaker.speaking)
        call.provider(system.provider, perform: CXEndCallAction(call: call.id!))
        XCTAssertFalse(speaker.speaking, "the reading stops at the hang-up")
        XCTAssertFalse(speaker.holding)
        call.provider(system.provider, didDeactivate: AVAudioSession.sharedInstance())
        XCTAssertEqual(call.state, .idle)
        let speaks = speaker.report.speaks
        // Unlocked: the app comes forward, and nothing it holds reads the reply again.
        active = true
        audio.wantRecord(true, for: .warm)
        await tick()
        XCTAssertFalse(speaker.speaking, "nothing is read on unlock")
        XCTAssertFalse(speaker.waitingForMicrophone)
        XCTAssertEqual(speaker.report.speaks, speaks)
    }

    func testAHangUpWithAReplyWaitingForTheActivationSettlesItUnread() async {
        let (speaker, call, audio) = await fixture()
        speaker.awaitReply("n", readAloud: true)
        lock(audio, call)
        XCTAssertTrue(speaker.speak("Hello there.", answering: "n"))
        XCTAssertTrue(speaker.waitingForMicrophone, "the reply waits for the activation")
        call.provider(system.provider, perform: CXEndCallAction(call: call.id!))
        XCTAssertEqual(settled, ["n"], "its turn's mark goes, so a relaunch does not read it")
        XCTAssertFalse(speaker.waitingForMicrophone)
        await tick()
        sleep.fire()
        await settle("the call to be over") { call.state == .idle }
        active = true
        audio.wantRecord(true, for: .warm)
        await tick()
        XCTAssertFalse(speaker.speaking, "the reply that waited is not read when the call is over")
        XCTAssertFalse(speaker.report.started)
        speaker.speak(writing: "Hello there. And more", answering: "n")
        XCTAssertFalse(speaker.speaking, "nor is what the guest writes of the turn hung up on")
    }

    func testTheAppsOwnEndIsNotAHangUp() async {
        let (speaker, call, audio) = await fixture()
        speaker.awaitReply("n", readAloud: true)
        lock(audio, call)
        activate(call)
        active = true
        audio.wantRecord(true, for: .warm)
        call.end()
        XCTAssertEqual(system.fulfilled.compactMap { $0 as? CXEndCallAction }.count, 1, "the system performed the end")
        XCTAssertEqual(settled, [], "and it is not a hang-up: the mark stands")
        XCTAssertEqual(speaker.awaiting, ["n"])
        call.provider(system.provider, didDeactivate: AVAudioSession.sharedInstance())
        XCTAssertTrue(speaker.holding)
        XCTAssertTrue(speaker.keeping, "the keeper carries the wait on in front")
        speaker.stop()
    }

    func testTheHoldIsToldToWhoeverListensAfterTheKeeper() async {
        let (speaker, _, _) = await fixture()
        var told: [(held: Bool, keeping: Bool)] = []
        speaker.onHold = { [unowned speaker] held in told.append((held, speaker.keeping)) }
        speaker.awaitReply("n", readAloud: true)
        speaker.endAwaiting("n", "done")
        XCTAssertEqual(told.map(\.held), [true, false])
        XCTAssertEqual(told.map(\.keeping), [true, false], "the keeper is dealt with before the listener hears")
    }

    func testACallThatFailsLeavesTheHoldStandingAndTheKeeperDownBehindTheLock() async {
        let (speaker, call, audio) = await fixture()
        speaker.awaitReply("n", readAloud: true)
        lock(audio, call)
        center.post(name: .AVAudioEngineConfigurationChange, object: seams.engines.last)
        await settle("the rebuild to be refused") { speaker.dead }
        // Behind the lock an activation of the non-mixable session is refused.
        seams.activationError = Seams.Refused()
        // Refused at every attempt: placed again after each refusal until the last.
        for attempt in 0..<SpokenCall.placeAttempts {
            system.answer(attempt, FakeCallSystem.Refused())
            guard attempt < SpokenCall.placeAttempts - 1 else { break }
            await settle("the retry's wait") { self.sleep.waiting > 0 }
            sleep.fire()
            await settle("the retry") { self.system.requests.count == attempt + 2 }
        }
        XCTAssertEqual(audio.call, .none)
        XCTAssertTrue(speaker.holding, "the hold stands")
        XCTAssertFalse(speaker.keeping, "and the keeper could not be restarted from the background")
        XCTAssertTrue(seams.lines.contains("activate failed"), "\(seams.lines)")
        // In front, the next path activates and the keeper comes back.
        seams.activationError = nil
        active = true
        speaker.awaitReply("n2", readAloud: true)
        XCTAssertTrue(speaker.keeping)
        speaker.stop()
    }
}
