#if os(iOS)
import AVFoundation
import CallKit
import SwiftUI

/// The spoken exchange behind the lock as an outgoing CallKit call.
///
/// A call is the one thing iOS keeps an audio session running behind the lock screen for
/// without argument: the system activates the session itself, at a call's priority, from the
/// background, and holds it until the call ends, so the wait for a spoken turn's reply and the
/// reading of it are not bounded by the keeper's ceiling (`Speaker.ceiling`) while one is up.
/// The call UI is the receipt — the Lock Screen's call card, the green pill, the watch — and
/// hanging up from any of them ends the exchange: the reply is not read, then or on unlock
/// (`Speaker.hangUp`). A phone call that arrives holds this one, and the system hands the
/// session back when it is resumed.
///
/// No VoIP push: the call is only ever placed by the app, for itself, with a hold standing and
/// the scene in the background (`SpokenCallDriver`). The `voip` background mode is declared all
/// the same (`project.yml`), since the system refuses `CXStartCallAction` from an app without it.
///
/// The audio session is the system's for the call's life. This class never touches it:
/// `onStart` is where `AudioSession.callPlaced` sets the category and activates nothing,
/// `onActive` where `callActivated` takes the session as live, and nothing calls `setActive`
/// while the phase is the call's. Main actor only: the provider's delegate queue is main.
/// The shape is Daphne's `SessionCall` (samdu/daphne-assistant, `clients/ios`).
@MainActor
final class SpokenCall: NSObject {
    /// The call is being placed: set the category, activate nothing.
    var onStart: () -> Void = {}
    /// The system activated the session — at the start, and again coming back from hold.
    var onActive: () -> Void = {}
    /// The system took the session away with the call still up: on hold.
    var onInactive: () -> Void = {}
    /// Ended from outside the app: the call card, the Lock Screen, the watch.
    var onHangUp: () -> Void = {}
    /// The call is gone and the session is the app's again.
    var onOver: () -> Void = {}
    /// The call could not be placed, was never activated, or went with the system's call
    /// service restarting. The exchange carries on without one, on the keeper.
    var onFailed: (String) -> Void = { _ in }

    /// Who the call is with, as the card names it.
    static let name = "Topo"

    enum State { case idle, starting, up, closing }
    private(set) var state = State.idle
    private(set) var id: UUID?
    /// The session is activated for this call right now.
    private(set) var active = false
    /// A call wanted while the last one was still closing.
    private var again = false

    /// A call is up or on its way up.
    var up: Bool { state == .starting || state == .up || (state == .closing && again) }

    private let system: CallSystem
    private let sleep: CallSleep
    private var grace: Task<Void, Never>?

    /// How long a placed call may go without the system activating its session before the
    /// exchange carries on without it, and how long an ended one may go without the deactivation
    /// that normally closes it. Activation takes about a second on the phone's own speaker and
    /// has taken five with AirPods connected, so the wait is twice that.
    static let activationGrace: Duration = .seconds(10)
    static let closingGrace: Duration = .seconds(2)

    init(system: CallSystem = CallKitSystem(), sleep: @escaping CallSleep = { try await Task.sleep(for: $0) }) {
        self.system = system
        self.sleep = sleep
        super.init()
        system.setDelegate(self)
    }

    func start() {
        if state == .closing { again = true; return }
        guard state == .idle else { return }
        let call = UUID()
        id = call
        state = .starting
        active = false
        AudioLog.say("call: placing")
        let action = CXStartCallAction(call: call, handle: CXHandle(type: .generic, value: Self.name))
        system.request(CXTransaction(action: action)) { [weak self] error in
            guard let self, let error, self.id == call else { return }
            self.fail("not placed: \(error.localizedDescription)")
        }
        grace = Task { [sleep] in
            try? await sleep(Self.activationGrace)
            guard !Task.isCancelled, self.id == call, self.state == .starting else { return }
            // Failed first, so the end the system performs for this request finds no call of
            // ours and is not a hang-up; the system is told too, or its card outlives the
            // exchange's use of it.
            self.fail("never activated")
            self.system.request(CXTransaction(action: CXEndCallAction(call: call))) { _ in }
        }
    }

    func end() {
        again = false
        guard let call = id, state == .starting || state == .up else { return }
        AudioLog.say("call: ending")
        close(call)
        system.request(CXTransaction(action: CXEndCallAction(call: call))) { [weak self] error in
            // Refused, so no deactivation is coming to finish it.
            guard let self, let error, self.id == call else { return }
            AudioLog.say("call: end refused: \(error.localizedDescription)")
            self.finish()
        }
    }

    /// Closing: the deactivation finishes it, and a call that never held the session (on hold,
    /// or not yet activated) gets none, so the grace does.
    private func close(_ call: UUID) {
        state = .closing
        active = false
        grace?.cancel()
        grace = Task { [sleep] in
            try? await sleep(Self.closingGrace)
            guard !Task.isCancelled, self.id == call, self.state == .closing else { return }
            self.finish()
        }
    }

    private func finish() {
        grace?.cancel()
        id = nil
        state = .idle
        active = false
        AudioLog.say("call: over")
        onOver()
        if again { again = false; start() }
    }

    private func fail(_ why: String) {
        grace?.cancel()
        id = nil
        state = .idle
        active = false
        again = false
        AudioLog.say("call: \(why)")
        onFailed(why)
    }

    private func report(_ call: UUID) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: Self.name)
        update.localizedCallerName = Self.name
        update.hasVideo = false
        update.supportsDTMF = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        // A phone call that arrives holds this one rather than ending it.
        update.supportsHolding = true
        system.report(call, update: update)
    }

    // MARK: The provider's callbacks, on the main queue

    /// The system's call daemon restarted and took every call with it. Nobody hung up: the
    /// exchange carries on without a call, as it does when one cannot be placed. A call that was
    /// already closing is over, and one wanted behind it keeps its `again`: the finish places it.
    fileprivate func reset(_ provider: CXProvider) {
        // Only the provider in use: invalidating one can itself be answered with a reset (iOS 26's
        // CallKit does), which would otherwise replace the replacement without end.
        guard provider === system.provider else { return }
        // A provider that has been through a reset is not asked again: the calls placed on one
        // after it were never activated.
        system.replace(delegate: self)
        guard let call = id else { return AudioLog.say("call: provider reset with no call up") }
        // Not from inside the callback: the system holds the old provider for as long as it
        // runs, and what ends a call here is audio work that takes a while.
        Task { @MainActor [weak self] in
            guard let self, self.id == call else { return }
            if self.state == .closing {
                AudioLog.say("call: provider reset while closing")
                self.finish()
            } else {
                self.fail("provider reset: the system's call service restarted")
            }
        }
    }

    fileprivate func perform(start action: CXStartCallAction, on provider: CXProvider) {
        // Only a call still wanted: one ended before the system got to it must not come up
        // behind the exchange that asked for it.
        guard action.callUUID == id, state == .starting else { return system.fail(action) }
        onStart()
        system.fulfill(action)
        report(action.callUUID)
        // There is no far end to wait on: placed is connected.
        system.connected(action.callUUID)
        AudioLog.say("call: placed")
    }

    fileprivate func activated() {
        guard id != nil, state == .starting || state == .up else { return }
        state = .up
        active = true
        grace?.cancel()
        AudioLog.say("call: session activated")
        onActive()
    }

    fileprivate func deactivated() {
        active = false
        guard id != nil else { return }
        if state == .closing { return finish() }
        AudioLog.say("call: session deactivated with the call up")
        onInactive()
    }

    fileprivate func perform(end action: CXEndCallAction) {
        system.fulfill(action)
        guard action.callUUID == id, state == .starting || state == .up else { return }
        // Not ours: `end` moves to closing before it asks.
        AudioLog.say("call: hung up from the card")
        close(action.callUUID)
        onHangUp()
    }

    /// The card's mute. Topo holds no microphone open between turns, so there is nothing to
    /// mute; the action is fulfilled, so the card stays consistent, and changes nothing. The
    /// hang-up is the control.
    fileprivate func perform(mute action: CXSetMutedCallAction) {
        AudioLog.say("call: \(action.isMuted ? "muted" : "unmuted") from the card; nothing to mute")
        system.fulfill(action)
    }

    fileprivate func perform(held action: CXSetHeldCallAction) {
        AudioLog.say("call: \(action.isOnHold ? "on hold" : "off hold")")
        system.fulfill(action)
    }
}

extension SpokenCall: CXProviderDelegate {
    // The delegate's queue is main (`CallSystem.setDelegate`), so each callback is on the actor.
    // The provider and the actions are not `Sendable`; they are the system's objects handed over
    // on the actor's own queue, so each is carried in as such.
    nonisolated func providerDidReset(_ provider: CXProvider) {
        nonisolated(unsafe) let provider = provider
        MainActor.assumeIsolated { reset(provider) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        nonisolated(unsafe) let action = action
        nonisolated(unsafe) let provider = provider
        MainActor.assumeIsolated { perform(start: action, on: provider) }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { activated() }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { deactivated() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        nonisolated(unsafe) let action = action
        MainActor.assumeIsolated { perform(end: action) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        nonisolated(unsafe) let action = action
        MainActor.assumeIsolated { perform(mute: action) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        nonisolated(unsafe) let action = action
        MainActor.assumeIsolated { perform(held: action) }
    }

    nonisolated func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        AudioLog.say("call: timed out performing \(type(of: action))")
    }
}

typealias CallSleep = @Sendable (Duration) async throws -> Void

/// What the call reaches of the system — the provider and the controller — behind one seam, so
/// the suite drives the state machine with a fake that never places a call.
@MainActor
protocol CallSystem: AnyObject {
    /// The provider whose callbacks are the call's, compared by identity on a reset.
    var provider: CXProvider { get }
    func setDelegate(_ delegate: CXProviderDelegate)
    func request(_ transaction: CXTransaction, completion: @escaping @MainActor (Error?) -> Void)
    func report(_ call: UUID, update: CXCallUpdate)
    /// Reports the outgoing call connecting and connected, at once.
    func connected(_ call: UUID)
    func fulfill(_ action: CXAction)
    func fail(_ action: CXAction)
    /// Replaces the provider and the controller after a reset, the old provider invalidated.
    func replace(delegate: CXProviderDelegate)
}

@MainActor
final class CallKitSystem: CallSystem {
    private(set) var provider: CXProvider
    private var controller = CXCallController()

    init() {
        provider = Self.makeProvider()
    }

    private static func makeProvider() -> CXProvider {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        // An exchange is not somebody who rang: nothing for Recents to keep.
        configuration.includesCallsInRecents = false
        return CXProvider(configuration: configuration)
    }

    func setDelegate(_ delegate: CXProviderDelegate) {
        provider.setDelegate(delegate, queue: nil)
    }

    func request(_ transaction: CXTransaction, completion: @escaping @MainActor (Error?) -> Void) {
        controller.request(transaction) { error in
            Task { @MainActor in completion(error) }
        }
    }

    func report(_ call: UUID, update: CXCallUpdate) {
        provider.reportCall(with: call, updated: update)
    }

    func connected(_ call: UUID) {
        provider.reportOutgoingCall(with: call, startedConnectingAt: nil)
        provider.reportOutgoingCall(with: call, connectedAt: nil)
    }

    func fulfill(_ action: CXAction) { action.fulfill() }
    func fail(_ action: CXAction) { action.fail() }

    func replace(delegate: CXProviderDelegate) {
        provider.setDelegate(nil, queue: nil)
        provider.invalidate()
        provider = Self.makeProvider()
        provider.setDelegate(delegate, queue: nil)
        controller = CXCallController()
    }
}

/// Whether a spoken exchange behind the lock is a call: Settings' toggle, kept in this device's
/// defaults, read as each decision is made. On unless turned off.
enum SpokenCallSetting {
    static let key = "callForSpokenReplies"

    static func enabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }
}

/// Places the call and ends it: a call is wanted while a hold stands (`AudioSession.holding`,
/// told through `Speaker.onHold` after the speaker has dealt with the keeper), the scene is in
/// the background and the setting is on. In front the keeper's path is the proven one and the
/// card would be noise over the chat, so the app coming forward ends the call and the keeper
/// takes over; `.inactive` — Control Center, a notification pulled down, the app switcher — is
/// not the background, and places none.
@MainActor
final class SpokenCallDriver {
    private let call: SpokenCall
    private let enabled: () -> Bool
    private var holding = false
    private var phase: ScenePhase = .active

    init(call: SpokenCall, enabled: @escaping () -> Bool = { SpokenCallSetting.enabled() }) {
        self.call = call
        self.enabled = enabled
    }

    /// The whole rule, as a function of the three facts.
    nonisolated static func wants(holding: Bool, phase: ScenePhase, enabled: Bool) -> Bool {
        holding && phase == .background && enabled
    }

    func holdChanged(_ holding: Bool) {
        self.holding = holding
        decide()
    }

    func scene(_ phase: ScenePhase) {
        self.phase = phase
        decide()
    }

    private func decide() {
        let enabled = enabled()
        let wanted = Self.wants(holding: holding, phase: phase, enabled: enabled)
        // Each decision with the three facts, so a run says why a lock placed no call.
        if wanted != call.up {
            AudioLog.say("call driver: \(wanted ? "placing" : "ending") (hold \(holding), scene \(phase), setting \(enabled))")
        } else if holding, !wanted {
            AudioLog.say("call driver: no call (scene \(phase), setting \(enabled))")
        }
        if wanted { call.start() } else { call.end() }
    }
}
#endif
