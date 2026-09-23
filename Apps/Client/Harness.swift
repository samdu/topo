#if os(iOS)
import Foundation
import Observation
import TopoAuth
import TopoCore
import TopoTurn

/// The phone harness as the UI sees it: the transcript, the model setting, and one turn at a time.
/// The log is the shared CloudKit log, on the person's own Apple ID. What answers is the brain the
/// harness is made with: in the app, Claude Code in the guest (`standard`, over `GuestBridge`).
@MainActor
@Observable
final class Harness {
    static let modelKey = "model"

    private(set) var turns: [Turn] = []
    private(set) var notice: String?
    private(set) var busy = false
    private(set) var error: String?
    /// Where the turn in flight is, in words, so a slow step is seen to be a step. Nil when idle.
    private(set) var status: String?
    /// The person's turn the guest was cut off answering, which is not asked again unless the
    /// person asks (`askAgain`). Nil when there is none.
    private(set) var unfinished: Turn?
    /// Told what the guest is doing while it answers: Topo on the glass follows it.
    var onGuest: (@MainActor (GuestActivity) -> Void)? {
        get { relay.handler }
        set { relay.handler = newValue }
    }
    private let relay: GuestRelay
    /// The tokens of context the last reply this phone asked for was written over, as the API
    /// counted them — input and both cache counts (`Reply.context`); nil until one has been answered here, and again after
    /// a sign-out, since the context was the last login's. A reply another primary wrote, or one found already in the log,
    /// says nothing of its context and leaves this as it was.
    private(set) var context: Int?
    /// Told about every reply the log has brought, however it arrived: one this device wrote, or
    /// one another primary wrote that a pass read. One decision point for reading a reply aloud,
    /// rather than a view's observer, because behind the lock nothing is drawn and whether a
    /// SwiftUI body is evaluated is the framework's to decide.
    ///
    /// It answers whether it is done with that reply. A reply it could not take — the speaker
    /// refused it, a call still holding the session — is not recorded, so the next pass offers it
    /// again; every other reply, read aloud or not this screen's to read, is recorded and offered
    /// once.
    var onReply: (@MainActor (Turn) -> Bool)? {
        didSet {
            guard onReply != nil else { return }
            // A reply can land between the screen's first read of the log and the handler being
            // installed — the relaunch that sends what was owed takes a whole turn in that gap —
            // and it is still the one to read aloud, so what arrived unheard is offered now. Of
            // more than one owed reply only the newest is: a person coming back is owed the
            // answer to the last thing they said, not a backlog read at them, and each reply
            // spoken cuts off the one before it anyway. The older ones are done with here.
            for turn in owedAloud.dropLast() {
                spokenTurn(answeredBy: turn).map(answeredAloud)
                offered.insert(turn.ref)
            }
            turns.forEach(seen)
        }
    }
    /// Told the nonce of a turn that ended in a failure rather than a reply, as it ends: no reply
    /// is coming for it, and the screen's error line is not a place to work out whose. Not called
    /// for a turn another primary is answering, whose reply is still on its way.
    var onTurnFailed: (@MainActor (String) -> Void)?
    /// The replies to spoken turns that no handler has taken, oldest first: what a relaunch finds
    /// owed, and what the install above reads the newest of.
    private var owedAloud: [Turn] {
        turns.filter { $0.role == .assistant && !offered.contains($0.ref) && spokenTurn(answeredBy: $0) != nil }
    }
    /// The refs a handler has taken, so a reply both paths see is offered once. Nothing is
    /// recorded while no handler stands, nor for a reply a handler could not take, which is what
    /// leaves those replies to be offered again.
    private var offered: Set<TurnRef> = []
    /// Turns said and not yet settled, oldest first: the head is the one in flight or the one
    /// that stopped the line, the rest wait behind it.
    var waiting: [String] { pending.map(\.text) }
    let device: DeviceID

    private let database: RecordingDatabase
    private let log: TurnLog
    private let ensureZone: @Sendable () async throws -> Void
    private let tokens: TokenProvider
    /// Where the unsettled turns and the model setting are kept.
    private let defaults: UserDefaults
    /// What answers: the runner asks it, and the harness asks it what is unresolved.
    let brain: any Brain
    /// How the lease this harness makes waits between heartbeats.
    private let leaseSleep: @Sendable (TimeInterval) async throws -> Void
    /// How the answering loop waits between passes.
    private let pause: @Sendable (Duration) async throws -> Void
    /// True while `answering(every:)` runs.
    private var answeringLoop = false
    /// The memory's mirror, where the loop is what drives it. Called at the top of every
    /// answering pass, before the log is read, so a revision written on another device reaches
    /// the folder within the interval with no push and no turn; and again after a reply is in
    /// the log, whoever's turn it answered — one this device typed or one a limb wrote — since
    /// that is where anything a turn leaves in the memory goes out from. Nil on a screen that is
    /// not answering.
    var onPass: (@MainActor () async -> Void)?
    /// Set by `wake()`: the loop skips or ends its pause and runs the next pass now.
    private var woken = false
    /// The loop's pause in progress, which `wake()` cancels.
    private var sleeping: Task<Void, any Error>?
    /// `wake()` callers waiting for their pass to finish.
    private var wakers: [CheckedContinuation<Void, Never>] = []
    private var runner: TurnRunner?
    private var lease: PrimaryLease?
    private var writer: TurnWriter?
    /// A line for something that went right but not the usual way: the words went to another
    /// device's primary and the reply is on its way. Cleared by the next send.
    private(set) var info: String?
    private var inFlight: Task<Bool, Never>?

    /// What the person said that is not settled yet, oldest first, each under the nonce it was
    /// first attempted with and written to disk before any attempt. So a relaunch after a lost
    /// acknowledgement sends the same words under the same nonce and gets the turn already
    /// written, and a turn said behind a long one survives the app being killed during it.
    private struct Outgoing: Codable, Equatable {
        var text: String
        var nonce: String
    }
    private static let outboxKey = "topo.harness.outbox"
    private static let spokenKey = "topo.harness.spoken"
    /// The most spoken turns kept waiting for a reply at once. A turn whose reply never comes
    /// would otherwise sit here for good; the oldest go first, and each is only a nonce.
    private static let spokenLimit = 20
    /// The nonces of turns said into the microphone whose replies have not been read aloud yet,
    /// oldest first. On disk, so a relaunch still knows that the reply to what was said before
    /// the app went away is an answer to something spoken: the words survive the relaunch in the
    /// outbox, and what makes them a spoken turn has to survive with them. Cleared per turn as
    /// its reply is read, and by a sign-out.
    private var spokenNonces: [String] = [] {
        didSet {
            if spokenNonces.isEmpty { defaults.removeObject(forKey: Self.spokenKey) }
            else { defaults.set(spokenNonces, forKey: Self.spokenKey) }
        }
    }
    private var pending: [Outgoing] = [] {
        didSet {
            if pending.isEmpty { defaults.removeObject(forKey: Self.outboxKey) }
            else { defaults.set(try? JSONEncoder().encode(pending), forKey: Self.outboxKey) }
        }
    }
    private var outgoing: Outgoing? { pending.first }

    /// The words on the line and the nonces they carry, oldest first. It is what the row at the
    /// end of the transcript takes back up when the chat appears: the line survives the app being
    /// killed, so the screen that comes back can draw the row the turn was sent from rather than
    /// an empty one. The whole line and not its head, because the head can be a turn that landed
    /// and lost its acknowledgement, with what was said behind it still owed.
    var owed: [(text: String, nonce: String)] {
        pending.map { ($0.text, $0.nonce) }
    }

    /// `brain` is what answers, chosen here and nowhere else: never per turn, and never on a
    /// failure. `relay` is where the brain tells what the guest is doing, when it is the guest.
    init(database: any RecordDatabase, tokens: TokenProvider, device: DeviceID = DeviceIdentity.current,
         ensureZone: @escaping @Sendable () async throws -> Void = { try await TopoCloudKit.ensureZone() },
         defaults: UserDefaults = .standard,
         brain: any Brain, relay: GuestRelay = GuestRelay(),
         leaseSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.database = RecordingDatabase(database)
        self.tokens = tokens
        self.device = device
        self.ensureZone = ensureZone
        self.defaults = defaults
        self.brain = brain
        self.relay = relay
        self.leaseSleep = leaseSleep
        self.pause = pause
        log = TurnLog(database: self.database)
        spokenNonces = defaults.stringArray(forKey: Self.spokenKey) ?? []
        if let data = defaults.data(forKey: Self.outboxKey),
           let saved = try? JSONDecoder().decode([Outgoing].self, from: data) {
            pending = saved
        }
        // The single unsent turn an earlier build kept under its own key heads the line.
        let singleKey = "topo.harness.outgoing"
        if let data = defaults.data(forKey: singleKey) {
            if let single = try? JSONDecoder().decode(Outgoing.self, from: data), !pending.contains(single) {
                pending.insert(single, at: 0)
            }
            defaults.removeObject(forKey: singleKey)
        }
    }

    /// The app's harness: the shared CloudKit log, the keychain's tokens through the one provider
    /// the app makes for them, and Claude Code in the guest as the brain — the only one the app
    /// composes. Until the userland is on the phone and the resident process is up, a turn is not
    /// answered: the person's words stand in the log, the chat says why, and the answering loop
    /// answers them once the guest is ready.
    /// `database` is the suites' seam; the app passes nothing.
    static func standard(tokens: StoredTokenProvider,
                         database: @autoclosure () -> any RecordDatabase = TopoCloudKit.database()) -> Harness {
        let (bridge, relay) = guestBrain(ResidentConversation(tokens: tokens), ledger: GuestResident.ledgerFile)
        return Harness(database: database(), tokens: tokens, brain: bridge, relay: relay)
    }

    /// The guest as the brain, and the relay its activity reaches `onGuest` through.
    static func guestBrain(_ conversation: any GuestConversation, ledger: URL) -> (GuestBridge, GuestRelay) {
        let relay = GuestRelay()
        let bridge = GuestBridge(conversation: conversation, ledger: ledger,
                                 observe: { activity in await relay.tell(activity) })
        return (bridge, relay)
    }

    /// The guest, when it is what answers.
    var guest: GuestBridge? { brain as? GuestBridge }

    /// The model setting. A change reaches the brain at once, which for the guest replaces the
    /// resident process at its next idle moment, never in the middle of a turn.
    var model: ClaudeModel {
        get { defaults.string(forKey: Self.modelKey).flatMap(ClaudeModel.init(rawValue:)) ?? .default }
        set {
            defaults.set(newValue.rawValue, forKey: Self.modelKey)
            let brain = brain
            Task { await brain.use(model: newValue) }
        }
    }

    /// Sign-out: the turn in flight is cancelled and its result dropped, the runner and screen
    /// are cleared, and the next sign-in starts at the first question. The log itself stays where
    /// it is, in the person's own iCloud; nothing of it is on this device to remove.
    func forget() {
        inFlight?.cancel()
        inFlight = nil
        runner = nil
        lease = nil
        writer = nil
        info = nil
        turns = []
        notice = nil
        error = nil
        status = nil
        busy = false
        context = nil
        unfinished = nil
        pending = []
        spokenNonces = []
        // What the guest kept of the last login's conversation goes with it.
        let brain = brain
        Task { await brain.forget() }
        UserDefaults.standard.removeObject(forKey: "firstRunAnswer")
        UserDefaults.standard.removeObject(forKey: "firstRunAnswered")
    }

    /// The far end of a takeover: this device is a viewer now. The turn in flight is cancelled;
    /// what is waiting to be sent goes into the log as a limb's turns, in order, so nothing said
    /// is lost to the handover, and whichever device is primary answers it there. A turn that
    /// will not go stays on disk for the next launch. Then the harness is dropped as `forget`
    /// drops it, but the transcript stays on screen.
    func demote() async {
        inFlight?.cancel()
        inFlight = nil
        busy = false
        status = nil
        do {
            let writer: TurnWriter
            if let existing = self.writer { writer = existing } else { writer = try await log.writer(for: device) }
            while let next = pending.first {
                let transcript = try await log.read()
                let person = try await writer.append(.person, next.text, continuing: transcript, nonce: next.nonce)
                show(person)
                if pending.first == next { pending.removeFirst() }
            }
        } catch {
            self.error = "Not everything said has reached the log yet: \(Self.describe(error))"
        }
        runner = nil
        lease = nil
        writer = nil
        info = nil
    }

    /// Reads the log into the screen, and answers whether it read it: a log that is not there
    /// yet is read as empty and is an answer like any other, where a read that failed is not one.
    /// Only `withdraw` asks; everything else refreshes for the screen's sake.
    @discardableResult
    func refresh() async -> Bool {
        do {
            let transcript = try await log.read()
            turns = transcript.ordered
            turns.forEach(seen)
            notice = TranscriptStore.notice(for: transcript)
            return true
        } catch {
            guard !TopoCloudKit.meansNoLogYet(error) else { turns = []; return true }
            self.error = "Couldn't read the transcript: \(TranscriptStore.message(for: error))"
            return false
        }
    }

    /// One turn: the words go in the log, the reply comes back into it. Words said while a turn
    /// is in flight wait their turn and go next, in order, the same words twice being two turns;
    /// nothing said is dropped. A turn that never reached the log stops the line: it stays at the
    /// head and goes first next time, and what was said behind it waits.
    func send(_ text: String) async {
        willSend(text)
        await drain()
    }

    /// Puts the words on the line without sending yet, and returns the nonce the turn will carry,
    /// which is how a caller recognises the turn once it is in the log. `retry()` sends.
    @discardableResult
    func willSend(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoing = Outgoing(text: text, nonce: UUID().uuidString)
        guard !text.isEmpty else { return outgoing.nonce }
        pending.append(outgoing)
        return outgoing.nonce
    }

    /// That turn was said into the microphone and its reply is one to read aloud, which is what
    /// makes it spoken; the mark outlives the screen, so the reply to what was said before a
    /// relaunch is still an answer to something spoken.
    func markSpoken(_ nonce: String) {
        guard !spokenNonces.contains(nonce) else { return }
        spokenNonces.append(nonce)
        if spokenNonces.count > Self.spokenLimit {
            spokenNonces.removeFirst(spokenNonces.count - Self.spokenLimit)
        }
    }

    /// The spoken turn `reply` answers, or nil when it answers none. Spoken-ness is the harness's
    /// because it outlives the screen: the reply to what was said before a relaunch lands on a
    /// fresh view with no memory of the press.
    func spokenTurn(answeredBy reply: Turn) -> String? {
        ReadAloud.spokenTurn(answeredBy: reply, in: turns, spoken: Set(spokenNonces))
    }

    /// That turn's reply has been read aloud; it is owed no other.
    func answeredAloud(_ nonce: String) {
        spokenNonces.removeAll { $0 == nonce }
    }


    /// Whether the person's turn said under `nonce` is in the log, as this device knows it. It
    /// is what the row at the end of the transcript watches: the words are said once it is true,
    /// whatever became of the reply, and a second send would be a second turn.
    func said(_ nonce: String) -> Bool {
        turns.contains { $0.role == .person && $0.nonce == nonce }
    }

    /// Whether the words said under `nonce` can be taken back: they are still owed on this
    /// device, nothing is attempting them — an attempt is a write that may be landing as this is
    /// asked — and no turn of theirs is known to be in the log. It is what decides whether the
    /// row offers a way back; `withdraw` asks the log itself before it acts on the answer.
    func canWithdraw(_ nonce: String) -> Bool {
        !busy && !said(nonce) && pending.contains { $0.nonce == nonce }
    }

    /// Takes the words said under `nonce` off the line, so they can be changed and said again as
    /// one turn rather than two, and answers whether it did.
    ///
    /// What is in the log is said: a second send would be a second turn, so the log is read
    /// first and the withdrawal is refused if the turn is there — which is also how a write
    /// whose acknowledgement was lost is found, since the screen then shows the turn it did not
    /// know had landed. A read that failed is not an answer either, and refuses too: the words
    /// stay owed and the retry that is already the line's way forward sends them under this same
    /// nonce.
    @discardableResult
    func withdraw(_ nonce: String) async -> Bool {
        guard canWithdraw(nonce) else { return false }
        guard await refresh() else { return false }
        guard canWithdraw(nonce) else { return false }
        pending.removeAll { $0.nonce == nonce }
        spokenNonces.removeAll { $0 == nonce }
        return true
    }

    /// Sends the line from its head, after a turn that stopped it or a launch that found it.
    func retry() async {
        await drain()
    }

    /// True when a turn is waiting to go and none is in flight: the line stopped on a failure.
    var hasWaiting: Bool { !busy && !pending.isEmpty }

    private func drain() async {
        guard !busy else { return }
        busy = true
        error = nil
        info = nil
        while let next = pending.first {
            let task = Task { await run(next) }
            inFlight = task
            let settled = await task.value
            // A sign-out cleared everything, this turn included; the line went with it.
            guard inFlight == task else { return }
            inFlight = nil
            guard settled else { break }
            if pending.first == next { pending.removeFirst() }
        }
        busy = false
        status = nil
    }

    /// True when the turn is settled: answered, or at least in the log with only the reply owed.
    /// False leaves it as the unsent turn.
    @discardableResult
    private func run(_ attempt: Outgoing) async -> Bool {
        let generation = inFlight
        let text = attempt.text
        do {
            if runner == nil {
                status = "Reaching iCloud…"
                try await ensureZone()
                runner = try await makeRunner()
            }
            guard let runner else { return false }
            #if DEBUG
            await DebugRun.delayReply()
            #endif
            let result = try await runner.run(text, model: model, nonce: attempt.nonce) { [weak self] step in
                await self?.show(step, generation: generation)
            }
            // A sign-out during the turn cleared the screen; this result is not for it.
            guard inFlight == generation, !Task.isCancelled else { return false }
            show(result.person)
            show(result.assistant)
            if result.reply.context > 0 { context = result.reply.context }
            status = nil
            await refreshUnfinished()
            // The reply is in the log, as it is at the end of a pass, and anything the turn
            // left in the memory goes out from the same place whoever's turn it was.
            await onPass?()
            return true
        } catch is CancellationError {
            return false
        } catch TurnRunnerError.replyFailed(_, let underlying) {
            // The person's turn is in the log; only the reply is owed, and nothing is going to
            // bring it, so whatever is waiting on that turn hears so now.
            guard inFlight == generation else { return false }
            error = Self.describe(underlying)
            onTurnFailed?(attempt.nonce)
            await refresh()
            await refreshUnfinished()
            status = nil
            return true
        } catch TurnRunnerError.notPrimary(let outcome) {
            guard inFlight == generation else { return false }
            // Not this device's turn to answer: the words go in the log as a limb's, and whichever
            // device is primary answers them there. Settled once they are in the log.
            do {
                status = "Saving what you said…"
                let transcript = try await log.read()
                guard let writer else { return false }
                let person = try await writer.append(.person, text, continuing: transcript, nonce: attempt.nonce)
                show(person)
                info = Self.describe(outcome) + " What you said is in the log; the reply will appear here."
                status = nil
                return true
            } catch {
                self.error = Self.describe(error)
                onTurnFailed?(attempt.nonce)
            }
        } catch TokenProviderError.signedOut {
            guard inFlight == generation else { return false }
            error = "Signed out. Sign in again to continue."
            onTurnFailed?(attempt.nonce)
        } catch {
            guard inFlight == generation else { return false }
            self.error = Self.describe(error)
            onTurnFailed?(attempt.nonce)
            await refresh()
        }
        status = nil
        return false
    }

    /// A step of the turn in flight, as words on the screen. The person's turn shows the moment
    /// it is in the log, before the model has answered.
    private func show(_ step: TurnRunner.Progress, generation: Task<Bool, Never>?) {
        guard inFlight == generation else { return }
        switch step {
        case .takingLease: status = "Checking this device is primary…"
        case .saving: status = "Saving what you said…"
        case .asking(let person):
            show(person)
            status = "Asking \(model.displayName)…"
        case .savingReply: status = "Saving the reply…"
        }
    }

    private func show(_ turn: Turn) {
        guard !turns.contains(where: { $0.ref == turn.ref }) else { return }
        turns.append(turn)
        seen(turn)
    }

    /// A reply the handler has not been given. Offered once, whichever path brought it; with no
    /// handler installed it is left unoffered, for whichever one is installed next.
    private func seen(_ turn: Turn) {
        guard turn.role == .assistant, let onReply, !offered.contains(turn.ref) else { return }
        if onReply(turn) { offered.insert(turn.ref) }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case TurnRunnerError.displaced:
            "Another device became primary while Claude was answering. What you said is in the log; the reply will appear here."
        case MessagesAPIError.refused:
            "Claude declined that one."
        case MessagesAPIError.http(let status, let message):
            message ?? "Claude answered \(status)."
        case let error as GuestBridgeError:
            error.description
        case TokenProviderError.signedOut:
            "Signed out. Sign in again to continue."
        default:
            TranscriptStore.message(for: error)
        }
    }

    /// Keeps the screen current and answers what waits in the log, until the calling task is
    /// cancelled. The log's own path for a limb's words: a watch, a pad or a second phone appends
    /// the person's turn, and this device, as primary, answers it here. A reply that failed
    /// earlier, on this device or any other, is answered on the next pass too, so nothing said
    /// stays unanswered while a primary is awake.
    ///
    /// `wake()` cuts the pause short: the next pass runs now rather than at the end of the
    /// interval. It never runs a pass of its own, so passes never overlap.
    func answering(every interval: Duration) async {
        answeringLoop = true
        defer {
            answeringLoop = false
            let left = wakers
            wakers = []
            left.forEach { $0.resume() }
        }
        while !Task.isCancelled {
            // A wake asked for before this pass began is served by it; one asked for during it
            // may have missed what this pass read, so it gets the next.
            woken = false
            let served = wakers
            wakers = []
            await onPass?()
            await refresh()
            // The guest is warmed as the chat runs, so it is up by the time the words are; this
            // waits for nothing.
            if let guest { Task { await guest.warm() } }
            await answerPending()
            served.forEach { $0.resume() }
            if woken { continue }
            let pausing = Task { [pause] in try await pause(interval) }
            sleeping = pausing
            let slept = await withTaskCancellationHandler { await pausing.result } onCancel: { pausing.cancel() }
            sleeping = nil
            if case .failure = slept, !woken { return }
        }
    }

    /// Asks the answering loop for a pass now, and returns once that pass has run: a silent push
    /// saying the log moved lands here. Returns at once when no loop is running, since nothing is
    /// answering to wake.
    func wake() async {
        guard answeringLoop else { return }
        woken = true
        sleeping?.cancel()
        await withCheckedContinuation { wakers.append($0) }
    }

    /// One pass: if the log's newest turns are the person's with no reply, answer them as primary.
    func answerPending() async {
        guard !busy else { return }
        do {
            if runner == nil {
                try await ensureZone()
                runner = try await makeRunner()
            }
            guard let runner else { return }
            if let reply = try await runner.answerPending(model: model) {
                show(reply)
                error = nil
                await refresh()
                // The reply is in the log, so anything the turn left in the memory goes out now.
                await onPass?()
            }
            await refreshUnfinished()
        } catch TurnRunnerError.notPrimary {
            // Another device holds the lease and this one has yielded to it; that device answers.
        } catch TurnRunnerError.displaced {
            // Another device took the lease as the reply was ready; it answers.
        } catch is CancellationError {
            return
        } catch {
            self.error = Self.describe(error)
            await refreshUnfinished()
        }
    }

    /// Reads which of the log's turns the brain holds as cut off, for the control that asks again.
    private func refreshUnfinished() async {
        let refs = await brain.unresolved()
        unfinished = refs.isEmpty ? nil : turns.last { refs.contains($0.ref) }
    }

    /// The person chose to ask again the turn the guest was cut off answering: it is sent once
    /// more, now, by the answering pass. This is the only way such a turn is sent a second time.
    func askAgain() async {
        guard unfinished != nil, let guest else { return }
        await guest.askAgain()
        unfinished = nil
        error = nil
        if answeringLoop { await wake() } else { await answerPending() }
    }

    /// Takes a lease another part of the app claimed for this device (the deliberate takeover),
    /// so the harness runs on that claim's epoch rather than making a second claim the displaced
    /// device never yielded to.
    func adopt(_ lease: PrimaryLease) {
        self.lease = lease
    }

    private func makeRunner() async throws -> TurnRunner {
        let writer = try await log.writer(for: device)
        self.writer = writer
        let lease = self.lease ?? PrimaryLease(database: database, device: device, endpoint: nil, probe: NoSocketProbe(),
                                               sleep: leaseSleep)
        self.lease = lease
        return TurnRunner(log: log, writer: writer, lease: lease, brain: brain)
    }

    /// What the diagnostics screen shows: everything a failed or silent turn could be blamed on.
    struct Diagnostics {
        var rows: [(String, String)]
    }

    func diagnostics() async -> Diagnostics {
        var rows: [(String, String)] = []
        rows.append(("Device", device.rawValue))
        rows.append(("Role", UserDefaults.standard.string(forKey: "topo.role") ?? "undecided"))
        rows.append(("Container", TopoCloudKit.containerIdentifier))
        rows.append(("iCloud account", await TopoCloudKit.accountStatus()))
        rows.append(("Turn in flight", busy ? (status ?? "yes") : "none"))
        rows.append(("Waiting to send", pending.isEmpty ? "none" : pending.map(\.text).joined(separator: " | ")))
        rows.append(("Last error shown", error ?? "none"))
        if let lease {
            let primary = await lease.isPrimary()
            if let held = await lease.held {
                rows.append(("Lease", "\(held.holder.rawValue) epoch \(held.epoch), expires \(Self.clock(held.expiresAt))"))
            } else {
                rows.append(("Lease", "not held by this device"))
            }
            rows.append(("This device primary", primary ? "yes" : "no"))
        } else {
            rows.append(("Lease", "not yet claimed; no turn has run"))
        }
        if let record = try? await database.fetch(Lease.recordID), let server = Lease(record: record) {
            rows.append(("Lease record", "\(server.holder.rawValue) epoch \(server.epoch), expires \(Self.clock(server.expiresAt))"))
        } else {
            rows.append(("Lease record", database.lastError == nil ? "none" : "could not read"))
        }
        rows.append(("Last CloudKit error", database.lastError.map { "\(Self.clock($0.at)) \($0.message)" } ?? "none"))
        rows.append(("Last CloudKit success", database.lastSuccess.map(Self.clock) ?? "none"))
        rows.append(("Brain", await brain.describe()))
        rows.append(("Unfinished turn", unfinished.map { "\($0.ref): \($0.text)" } ?? "none"))
        rows.append(("Claude token", await Self.describeToken(tokens)))
        rows.append(("Model", model.displayName))
        rows.append(("Turns on screen", "\(turns.count)"))
        return Diagnostics(rows: rows)
    }

    private static func describeToken(_ tokens: TokenProvider) async -> String {
        guard let stored = tokens as? StoredTokenProvider else { return "test provider" }
        switch await stored.state() {
        case .signedOut: return "none: signed out"
        case .expired(let at): return "expired \(clock(at)); refreshes on the next turn"
        case .valid(until: let at): return "valid until \(clock(at))"
        }
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    static func describe(_ outcome: LeaseOutcome) -> String {
        switch outcome {
        case .primary: "This device is primary."
        case .held(let by): "\(by.holder.rawValue) is primary right now."
        case .unreachable(let lease): "\(lease.holder.rawValue) took over and can't be reached from here."
        case .contended: "Another device is claiming primary."
        }
    }
}

/// Where the guest's activity goes on its way to the screen: the bridge is made before the harness,
/// so it tells this, and the harness hands it on to whoever set `onGuest`.
@MainActor
final class GuestRelay {
    var handler: (@MainActor (GuestActivity) -> Void)?
    nonisolated init() {}
    func tell(_ activity: GuestActivity) { handler?(activity) }
}

/// The database with a memory: the last error any call raised and the last time one worked,
/// for the diagnostics screen. Everything else passes straight through.
final class RecordingDatabase: RecordDatabase, @unchecked Sendable {
    struct Failure { var at: Date; var message: String }

    private let base: any RecordDatabase
    private let lock = NSLock()
    private var _lastError: Failure?
    private var _lastSuccess: Date?

    init(_ base: any RecordDatabase) { self.base = base }

    var lastError: Failure? { lock.withLock { _lastError } }
    var lastSuccess: Date? { lock.withLock { _lastSuccess } }

    func save(_ records: [Record]) async throws -> [Record] { try await noting { try await base.save(records) } }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await noting { try await base.fetch(ids) } }
    func query(_ query: RecordQuery) async throws -> [Record] { try await noting { try await base.query(query) } }
    func records(ofType type: String) async throws -> [Record] { try await noting { try await base.records(ofType: type) } }

    private func noting<T>(_ call: () async throws -> T) async throws -> T {
        do {
            let value = try await call()
            lock.withLock { _lastSuccess = Date() }
            return value
        } catch {
            // A compare-and-set that lost is the protocol working, not a fault.
            switch error {
            case RecordDatabaseError.serverRecordChanged, RecordDatabaseError.unknownItem: break
            default: lock.withLock { _lastError = Failure(at: Date(), message: Self.describe(error)) }
            }
            throw error
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case RecordDatabaseError.unavailable(let underlying): "unavailable: \(underlying)"
        case RecordDatabaseError.rejected(let underlying): "rejected: \(underlying)"
        default: "\(error)"
        }
    }
}
#endif
