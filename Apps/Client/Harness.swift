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
    /// A read of the log has returned, with turns or with none: what the transcript draws is the
    /// log's rather than the empty page before the first read. A read that threw is not one, so a
    /// launch with no connection keeps this false until a read gets through.
    private(set) var hasRead = false
    private(set) var notice: String?
    private(set) var busy = false
    /// The last failure, in words: what the chat's notice says.
    var error: String? { failure?.words }
    /// The last failure and what it came from, so a read that gets through takes down a read's
    /// failure and no other, whatever the words.
    private(set) var failure: Failure?

    struct Failure: Equatable {
        /// `sync` is iCloud behind a turn the guest already has: nothing failed for the person.
        enum Source { case read, sync, other }
        var words: String
        var source: Source = .other
    }
    /// Where the turn in flight is, in words, so a slow step is seen to be a step. Nil when idle.
    private(set) var status: String?
    /// A turn this device sent is open: from the moment its attempt begins, before iCloud or the
    /// guest has answered anything, until its reply is shown, it failed, or its words went into
    /// the log for another device to answer. It is what Topo on the glass is at work for when the
    /// guest has nothing to show yet. A failure closes it as the failure is put up, before
    /// whatever reads follow; a line stopped on a failure is not an open turn.
    private(set) var turnOpen = false
    /// The reply the guest is writing now, as far as it has got, drawn under the transcript
    /// before it is whole and before it is in the log. It is not a turn: it goes when the reply
    /// lands in the transcript, when the guest starts another message, and when the turn fails.
    private(set) var writing: String?
    /// The guest's finished replies to words said on this device whose turns the log does not
    /// hold yet, by the person's nonce: iCloud is behind, and each is drawn under its words until
    /// the turn lands (`replies`).
    private(set) var unsaved: [String: String] = [:]
    /// The words the guest is on now that it was given ahead of their turn, by their nonce.
    private var hearing: String?
    /// The words given ahead whose guest turn has ended, and whether it ended in a reply.
    private var heardEnded: [String: Bool] = [:]
    /// Words given ahead that another device turned out to be the one to answer: what this
    /// device's guest wrote for them is not drawn, since the log's reply will be another's.
    private var answeredElsewhere: Set<String> = []
    /// The line being given to the guest ahead of its turns, entry after entry, in order.
    private var hearingLine: Task<Void, Never>?
    /// Every task giving the guest words ahead of their turn, cancelled when the lease says
    /// another device answers: words still on their way stop, and what the guest has stays its.
    private var givingAhead: [Task<Void, Never>] = []
    /// The lease last answered that another device holds it: nothing on the line is given ahead
    /// until a turn here is this device's to answer again.
    private var handedBack = false
    /// A launch's own giving of the words, before there is a runner (`reach`).
    private var reaching: Task<Bool, Never>?
    /// The spoken turn the guest is answering now, by its nonce, when it is one (`markSpoken`):
    /// whose reply the speaker may begin reading as it is written.
    private(set) var writingSpoken: String?
    /// The person's turn the guest was cut off answering, which is not asked again unless the
    /// person asks (`askAgain`). Nil when there is none.
    private(set) var unfinished: Turn?
    /// Told what the guest is doing while it answers: Topo on the glass follows it.
    var onGuest: (@MainActor (GuestActivity) -> Void)? {
        get { relay.handler }
        set { relay.handler = newValue }
    }
    private let relay: GuestRelay
    /// The tokens of context the last reply this phone asked for was written over, cached or not
    /// (`Reply.context`); nil until one has been answered here, and again after
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
    /// Told the reply to a spoken turn as the guest writes it: the message so far and the turn's
    /// nonce, then nil for the text once nothing more of it is coming — the reply landed (after
    /// `onReply` was offered it), or the turn failed.
    var onWriting: (@MainActor (String?, String) -> Void)?
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
    /// Told every reply the log has brought, each time a read or a landing brings it, whatever
    /// the screen: the app's default widget follows the newest (`DefaultSurface`).
    var onLanded: (@MainActor (Turn) -> Void)?
    /// Told the nonce of a turn that ended in a failure rather than a reply, as it ends: no reply
    /// is coming for it, and the screen's error line is not a place to work out whose. Told too
    /// of a turn the guest finished while iCloud had not taken it, its reply read as it was
    /// written: nothing more is coming to wait for. Not called for a turn another primary is
    /// answering, whose reply is still on its way.
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
    /// The answering passes running now, which a sign-out cancels as it cancels the turn in flight.
    private var passes: Set<Task<Void, Never>> = []
    /// Counts sign-outs and demotions. A pass or a loop begun under an earlier count belongs to a
    /// login that has gone: it shows nothing and writes nothing, and the loop ends.
    private var login = 0

    /// What the person said that is not settled yet, oldest first, each under the nonce it was
    /// first attempted with and written to disk before any attempt. So a relaunch after a lost
    /// acknowledgement sends the same words under the same nonce and gets the turn already
    /// written, and a turn said behind a long one survives the app being killed during it.
    private struct Outgoing: Codable, Equatable {
        var text: String
        var nonce: String
    }
    private static let outboxKey = "topo.harness.outbox"
    /// Where this device stood with the lease when it last asked (`TurnRunner.Standing`), kept
    /// across launches: a phone that was the one answering hears a turn the moment it is said,
    /// before this launch has asked the lease anything.
    private static let standingKey = "topo.harness.standing"
    private var standing: TurnRunner.Standing {
        get { defaults.string(forKey: Self.standingKey).flatMap(TurnRunner.Standing.init(rawValue:)) ?? .unknown }
        set { defaults.set(newValue.rawValue, forKey: Self.standingKey) }
    }
    /// True when this launch could not reach iCloud to make its runner: the lease cannot be
    /// asked, so the guest is given what is said directly until a runner is made.
    private var unreached = false
    /// How long iCloud is given to answer, before a turn said by a launch with no runner yet is
    /// given to the guest regardless: the lease's own patience with a request.
    private let patience: Duration
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

    /// The words on the line whose turn this device has not seen in the log, oldest first: each
    /// is a turn on its way, drawn as one until the log has it, however long the line has been
    /// stopped. The head can be missing from here while it is still on the line, when it landed
    /// and lost its acknowledgement.
    var unlanded: [(text: String, nonce: String)] {
        owed.filter { !said($0.nonce) }
    }

    /// How many of the answering loop's intervals of time the stopped line waits, from a failed
    /// attempt, before the loop sends it again, by how many of the loop's attempts in a row have
    /// failed: one interval after the first, then two, four and eight, and twelve — a minute at
    /// the chat's five seconds — from then on, until an attempt gets the line moving. Time and
    /// not passes, because a push's `wake()` runs a pass early and must not bring an attempt
    /// forward with it.
    static let retryBackoff = [1, 2, 4, 8, 12]
    /// The loop's attempts in a row that left the line stopped. Cleared when the line empties.
    private var failedRetries = 0
    /// The loop sends the stopped line again no sooner than this, in seconds on `now`. Nil when
    /// nothing has failed.
    private var retryNotBefore: TimeInterval?
    /// Elapsed time, for the backoff: `PrimaryLease.continuousUptime` in the app, which counts
    /// through sleep and is unmoved by a change to the phone's clock, so the wait is the time that
    /// passed and not what the clock says; a clock the test moves in the suites.
    private let now: @Sendable () -> TimeInterval

    /// `brain` is what answers, chosen here and nowhere else: never per turn, and never on a
    /// failure. `relay` is where the brain tells what the guest is doing, when it is the guest.
    init(database: any RecordDatabase, tokens: TokenProvider, device: DeviceID = DeviceIdentity.current,
         ensureZone: @escaping @Sendable () async throws -> Void = { try await TopoCloudKit.ensureZone() },
         defaults: UserDefaults = .standard,
         brain: any Brain, relay: GuestRelay = GuestRelay(),
         leaseSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping @Sendable () -> TimeInterval = PrimaryLease.continuousUptime,
         patience: Duration = .seconds(LeaseTiming.standard.patience)) {
        self.patience = patience
        self.database = RecordingDatabase(database)
        self.tokens = tokens
        self.device = device
        self.ensureZone = ensureZone
        self.defaults = defaults
        self.brain = brain
        self.relay = relay
        self.leaseSleep = leaseSleep
        self.pause = pause
        self.now = now
        log = TurnLog(database: self.database)
        relay.writing = { [weak self] in self?.follow($0) }
        relay.heard = { [weak self] in self?.follow($0) }
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
                                 observe: { activity in await relay.tell(activity) },
                                 heard: { heard in await relay.tell(heard) })
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

    /// Sign-out: the turn in flight and the answering pass in flight are cancelled and write
    /// nothing more, the answering loop ends, the runner and screen are cleared, and the next
    /// sign-in starts at the first question. Returns once the brain has forgotten the login's
    /// conversation, so what the guest kept of it is gone before the login is. The log itself
    /// stays where it is, in the person's own iCloud; the copy of the zone this device keeps to
    /// read it quickly (`ZoneMirror`) is removed.
    func forget() async {
        stopAnswering()
        runner = nil
        lease = nil
        writer = nil
        info = nil
        turns = []
        hasRead = false
        notice = nil
        failure = nil
        status = nil
        turnOpen = false
        dropWriting()
        forgetHeard()
        busy = false
        context = nil
        unfinished = nil
        pending = []
        spokenNonces = []
        failedRetries = 0
        retryNotBefore = nil
        UserDefaults.standard.removeObject(forKey: "firstRunAnswer")
        UserDefaults.standard.removeObject(forKey: "firstRunAnswered")
        // What the guest kept of the last login's conversation goes with it.
        await brain.forget()
        #if canImport(CloudKit)
        await CloudKitRecordDatabase.forgetMirrors()
        #endif
    }

    /// Ends everything under way for this login: the turn in flight, every answering pass and
    /// the loop's pause, each cancelled, and the count moved so none of them shows or writes
    /// anything once it wakes. The runner checks its task before each reply it appends.
    private func stopAnswering() {
        login += 1
        inFlight?.cancel()
        inFlight = nil
        passes.forEach { $0.cancel() }
        passes = []
        sleeping?.cancel()
    }

    /// The far end of a takeover: this device is a viewer now. The turn and the answering pass in
    /// flight are cancelled and the loop ends, as at a sign-out; what is waiting to be sent goes
    /// into the log as a limb's turns, in order, so nothing said is lost to the handover, and
    /// whichever device is primary answers it there. A turn that will not go stays on disk for the
    /// next launch. Then the harness is dropped as `forget` drops it, but the transcript stays on
    /// screen, and the brain forgets the conversation: a viewer holds no login, so it keeps none of
    /// the guest's session either.
    func demote() async {
        stopAnswering()
        // The guest is told to forget below, and what it says of its ending is not followed.
        dropWriting()
        forgetHeard()
        busy = false
        status = nil
        turnOpen = false
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
            failure = Failure(words: "Not everything said has reached the log yet: \(Self.describe(error))")
        }
        runner = nil
        lease = nil
        writer = nil
        info = nil
        await brain.forget()
    }

    /// A sign-out or a demotion: what the guest was given ahead of its turns went with the login.
    private func forgetHeard() {
        defaults.removeObject(forKey: Self.standingKey)
        unreached = false
        stopGivingAhead()
        handedBack = false
        unsaved = [:]
        hearing = nil
        heardEnded = [:]
        answeredElsewhere = []
    }

    /// The guest's replies to words said here that the log does not hold a reply to, by the
    /// person's nonce: the finished ones, and the one being written for words given ahead. The
    /// chat draws each under its words while iCloud is behind.
    var replies: [String: String] {
        var all = unsaved.filter { !answered($0.key) && !answeredElsewhere.contains($0.key) }
        if let hearing, let writing, !writing.isEmpty, !said(hearing) { all[hearing] = writing }
        return all
    }

    /// True while the reply being written is for words whose turn is not in the log: it is drawn
    /// under those words (`replies`) and not at the end of the log's turns.
    var writingAhead: Bool { hearing.map { !said($0) } ?? false }

    /// Reads from the guest which replies it holds for words given ahead: what a relaunch finds,
    /// and what a landing or a withdrawal took away.
    private func readUnsaved() async {
        guard let guest else { return }
        let login = self.login
        let held = await guest.unsaved()
        guard self.login == login else { return }
        unsaved = held
        let line = Set(pending.map(\.nonce))
        heardEnded = heardEnded.filter { held[$0.key] != nil || line.contains($0.key) }
    }

    /// Reads the log into the screen, and answers whether it read it: a log that is not there
    /// yet is read as empty and is an answer like any other, where a read that failed is not one.
    /// Only `withdraw` asks; everything else refreshes for the screen's sake.
    @discardableResult
    func refresh() async -> Bool {
        await readUnsaved()
        do {
            let transcript = try await log.read()
            let dropped = turns.filter { transcript[$0.ref] == nil }.count
            if dropped > 0 { Perf.mark("chat.refresh.dropped \(dropped)") }
            turns = transcript.ordered
            turns.forEach(seen)
            notice = TranscriptStore.notice(for: transcript)
            hasRead = true
            clearReadFailure()
            return true
        } catch {
            guard !TopoCloudKit.meansNoLogYet(error) else {
                turns = []
                hasRead = true
                clearReadFailure()
                return true
            }
            // The notice says what went wrong in the log's own words, which fit the two lines
            // the navigation bar holds (`ChatNotices.lines`); a prefix naming the read does not.
            failure = Failure(words: TranscriptStore.message(for: error), source: .read)
            return false
        }
    }

    /// A read got through, so a line saying the last one did not is no longer true. Any other
    /// failure stands until what it was about is tried again.
    private func clearReadFailure() {
        if failure?.source == .read { failure = nil }
        // Nothing is left for iCloud to catch up on.
        if failure?.source == .sync, pending.isEmpty, unsaved.isEmpty { failure = nil }
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

    /// Puts the words on the line under a nonce minted elsewhere — a widget's cue, recorded in the
    /// app group under it before the app ever saw it — unless that nonce is already on the line
    /// or already in the log, so a cue drained twice is one turn. Answers whether the nonce is on
    /// the line or in the log now, which is when its record may go. Only a harness that has read
    /// the log (`hasRead`) knows what the log holds.
    @discardableResult
    func willSend(_ text: String, nonce: String) -> Bool {
        if said(nonce) || pending.contains(where: { $0.nonce == nonce }) { return true }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        pending.append(Outgoing(text: text, nonce: nonce))
        return true
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

    /// Whether the turn said under `nonce` has a reply in the log, as this device knows it.
    func answered(_ nonce: String) -> Bool {
        guard let person = turns.first(where: { $0.role == .person && $0.nonce == nonce }) else { return false }
        return turns.contains { $0.role == .assistant && $0.parents.contains(person.ref) }
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
        // The guest may have the words already, and an answer to them: neither is the log's now.
        unsaved[nonce] = nil
        heardEnded[nonce] = nil
        await brain.withdrawn(nonce: nonce)
        return true
    }

    /// Sends the line from its head, after a turn that stopped it or a launch that found it.
    func retry() async {
        await drain()
    }

    /// True when a turn is waiting to go and none is in flight: the line stopped on a failure.
    var hasWaiting: Bool { !busy && !pending.isEmpty }

    private func drain() async {
        hearLine()
        guard !busy else { return }
        busy = true
        failure = nil
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
        if pending.isEmpty {
            failedRetries = 0
            retryNotBefore = nil
        }
    }

    /// Gives the guest every entry on the line it does not have yet, oldest first, ahead of the
    /// lease and the save: the device the person is typing on is the one that answers, so what
    /// was said is answered while iCloud is slow or away, a second message behind the first. Each
    /// call follows the one before, so the order is the line's. Nothing is given before the log
    /// has been read, since the read is what a fresh guest is told of the conversation.
    private func hearLine() {
        guard runner != nil || unreached, !pending.isEmpty else { return }
        let line = pending, login = self.login
        guard !handedBack else { return }
        let before = hearingLine
        givingAhead.removeAll { $0.isCancelled }
        let giving = Task { [weak self] in
            await before?.value
            for entry in line {
                guard !Task.isCancelled, let self, self.login == login,
                      self.pending.contains(entry), !self.said(entry.nonce) else { continue }
                if let runner = self.runner {
                    await runner.hear(entry.text, model: self.model, nonce: entry.nonce, known: self.known)
                } else if self.unreached {
                    _ = await self.brain.hear(entry.text, nonce: entry.nonce, context: self.known, model: self.model)
                }
            }
        }
        hearingLine = giving
        givingAhead.append(giving)
    }

    /// Stops every word still on its way to the guest ahead of its turn.
    private func stopGivingAhead() {
        givingAhead.forEach { $0.cancel() }
        givingAhead = []
        hearingLine = nil
        reaching?.cancel()
        reaching = nil
    }

    /// Keeps where the runner stands with the lease for the next launch, unless a sign-out or a
    /// demotion has cleared it meanwhile.
    private func keepStanding(of runner: TurnRunner, under login: Int) {
        Task { [weak self] in
            let standing = await runner.standing
            guard let self, self.login == login else { return }
            self.standing = standing
        }
    }

    /// The log as this device last read it, for a guest to be told of; nil before any read.
    private var known: [Turn]? { hasRead ? turns : nil }

    /// Makes the runner, which is the first thing a launch asks of iCloud. A launch that was the
    /// one answering gives the guest the words first; any other gives iCloud the lease's own
    /// patience, and the guest the words once that runs out or iCloud fails, since the lease
    /// cannot then be asked who holds it. Throws `unsaved` when the guest has the words and
    /// there is still no runner to save them.
    private func reach(for attempt: Outgoing) async throws -> TurnRunner {
        if let runner { return runner }
        let login = self.login
        // iCloud's patience, cut short when it fails outright.
        let waiting = Task { [patience, mine = standing == .mine] in
            if !mine { try? await Task.sleep(for: patience) }
        }
        let hearing = Task { [weak self] () -> Bool in
            await waiting.value
            guard let self, self.runner == nil, self.login == login else { return false }
            self.unreached = true
            return await self.brain.hear(attempt.text, nonce: attempt.nonce, context: self.known, model: self.model)
        }
        reaching = hearing
        do {
            try await ensureZone()
            let made = try await makeRunner()
            runner = made
            unreached = false
            // The wait ends finding a runner, unless the guest has the words already, which the
            // runner then finds.
            waiting.cancel()
            return made
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // iCloud failed inside its patience: the guest hears now rather than when it runs out.
            waiting.cancel()
            if await hearing.value { throw TurnRunnerError.unsaved(underlying: error) }
            throw error
        }
    }

    /// The answering loop's own attempt at a line that stopped on a failure. Nothing else sends a
    /// stopped line — a send, the button under the transcript, a launch — so without this a turn
    /// that failed on a bad minute waits for the person or the next launch, however soon iCloud
    /// comes back. It sends the line from its head under the nonces it already carries, which is
    /// the same retry the button makes, and backs off by `retryBackoff` intervals of time while it
    /// keeps failing. The loop calls it only after a read that got through: a pass that could not
    /// read the log is no attempt at sending, and does not count as a failed one.
    private func retryStoppedLine(every interval: Duration) async {
        guard hasWaiting else { return }
        if let retryNotBefore, now() < retryNotBefore { return }
        let login = self.login
        await drain()
        // A sign-out during the attempt emptied the line, and the counts went with it.
        guard self.login == login, hasWaiting else { return }
        let waits = Self.retryBackoff[min(failedRetries, Self.retryBackoff.count - 1)]
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        retryNotBefore = now() + seconds * Double(waits)
        failedRetries += 1
    }

    /// True when the turn is settled: answered, or at least in the log with only the reply owed.
    /// False leaves it as the unsent turn.
    @discardableResult
    private func run(_ attempt: Outgoing) async -> Bool {
        let generation = inFlight, login = self.login
        let text = attempt.text
        turnOpen = true
        // Every way out closes the turn, unless a sign-out or a demotion already has and the
        // flag is the next login's.
        defer { if inFlight == generation { turnOpen = false } }
        do {
            Perf.mark("turn.send")
            if runner == nil { status = "Reaching iCloud…" }
            let runner: TurnRunner
            do {
                runner = try await reach(for: attempt)
            } catch {
                // What is said behind this turn is given to the guest behind it all the same.
                hearLine()
                throw error
            }
            Perf.mark("turn.runner.made")
            // A line longer than this turn is given to the guest behind it.
            hearLine()
            defer { keepStanding(of: runner, under: login) }
            #if DEBUG
            await DebugRun.delayReply()
            #endif
            let result = try await runner.run(text, model: model, nonce: attempt.nonce, known: known) { [weak self] step in
                await self?.show(step, generation: generation)
            }
            // A sign-out during the turn cleared the screen; this result is not for it.
            guard inFlight == generation, !Task.isCancelled else { return false }
            handedBack = false
            show(result.person)
            show(result.assistant)
            Perf.mark("turn.reply.shown")
            if result.reply.context > 0 { context = result.reply.context }
            status = nil
            turnOpen = false
            await refreshUnfinished()
            // The reply is in the log, as it is at the end of a pass, and anything the turn
            // left in the memory goes out from the same place whoever's turn it was.
            await onPass?()
            Perf.mark("turn.pass.done")
            return true
        } catch is CancellationError {
            return false
        } catch TurnRunnerError.unsaved(let underlying) {
            // iCloud is behind and the guest has the words all the same: nothing failed for the
            // person. The row keeps the words, the reply is drawn as it is written and stays once
            // it is whole, and the line goes again, as any stopped line does, to save both.
            guard inFlight == generation else { return false }
            // The lease could not be asked, so this device answers: the line behind is given too,
            // and what the guest makes of these words is drawn again.
            if handedBack {
                handedBack = false
                hearLine()
            }
            answeredElsewhere.remove(attempt.nonce)
            failure = Failure(words: Self.behind(underlying), source: .sync)
            if let replied = heardEnded[attempt.nonce] { settleHeard(attempt.nonce, replied: replied) }
            status = nil
            return false
        } catch TurnRunnerError.replyFailed(_, let underlying) {
            if await keptUnsaved(attempt.nonce, underlying) {
                // The person's turn is in the log and the guest's reply is whole; only its save
                // failed, and the next pass writes it. It stays on screen meanwhile.
                guard inFlight == generation else { return false }
                turnOpen = false
                failure = Failure(words: Self.behind(underlying), source: .sync)
                settleHeard(attempt.nonce, replied: true)
                await refresh()
                status = nil
                return true
            }
            // The person's turn is in the log; only the reply is owed, and nothing is going to
            // bring it, so whatever is waiting on that turn hears so now.
            guard inFlight == generation else { return false }
            turnOpen = false
            // What was drawn of the reply is not in the log, and the log is what the screen shows.
            dropWriting()
            failure = Failure(words: Self.describe(underlying))
            onTurnFailed?(attempt.nonce)
            await refresh()
            await refreshUnfinished()
            status = nil
            return true
        } catch TurnRunnerError.notPrimary(let outcome) {
            guard inFlight == generation else { return false }
            // Whatever this device's guest makes of words it was given ahead is not the reply:
            // the device that holds the lease writes that.
            answeredElsewhere.insert(attempt.nonce)
            if hearing == attempt.nonce { dropWriting() }
            // Nor is anything on the line given to this device's guest from here: what is still
            // on its way stops. What the guest already has it keeps: should this device come to
            // answer the turn after all, that input is its answer.
            stopGivingAhead()
            handedBack = true
            // Not this device's turn to answer: the words go in the log as a limb's, and whichever
            // device is primary answers them there. Settled once they are in the log.
            do {
                status = "Saving what you said…"
                let transcript = try await log.read()
                // A sign-out during the read: the outbox went with it, and so do these words.
                guard inFlight == generation, !Task.isCancelled, let writer else { return false }
                let person = try await writer.append(.person, text, continuing: transcript, nonce: attempt.nonce)
                show(person)
                info = Self.limbInfo(outcome)
                status = nil
                return true
            } catch {
                guard inFlight == generation else { return false }
                turnOpen = false
                failure = Failure(words: Self.describe(error))
                onTurnFailed?(attempt.nonce)
            }
        } catch TokenProviderError.signedOut {
            guard inFlight == generation else { return false }
            turnOpen = false
            failure = Failure(words: "Signed out. Sign in again to continue.")
            onTurnFailed?(attempt.nonce)
        } catch {
            guard inFlight == generation else { return false }
            turnOpen = false
            failure = Failure(words: Self.describe(error))
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
        case .heard: status = "Asking \(model.displayName)…"
        case .takingLease: status = "Checking this device is primary…"
        case .saving: status = "Saving what you said…"
        case .asking(let person):
            show(person)
            status = "Asking \(model.displayName)…"
        case .savingReply: status = "Saving the reply…"
        }
    }

    /// iCloud being behind, in words that fit the notice's two lines.
    static func behind(_ error: any Error) -> String {
        "iCloud is behind; what was said here is saved when it is back."
    }

    /// Whether the reply to the turn said under `nonce` is one the guest finished and holds for
    /// the log, its save having failed for a reason of the database's and not a displacement.
    private func keptUnsaved(_ nonce: String, _ underlying: any Error) async -> Bool {
        if case TurnRunnerError.displaced = underlying { return false }
        guard underlying is RecordDatabaseError, let guest else { return false }
        let held = await guest.unsaved()
        guard let reply = held[nonce] else { return false }
        unsaved[nonce] = reply
        return true
    }

    /// The guest has finished with words whose turn or reply iCloud has not taken: nothing more
    /// of the reply is coming to read aloud, and nothing waits for it to land. A reply that was
    /// written was read as it was written, so its landing later is not read again.
    private func settleHeard(_ nonce: String, replied: Bool) {
        heardEnded[nonce] = nil
        if writingSpoken == nonce {
            // A line break settles the last sentence (`Speaker.settled`), so it is read too.
            if replied, let reply = unsaved[nonce] { onWriting?(reply + "\n", nonce) }
            onWriting?(nil, nonce)
            writingSpoken = nil
            // Read as it was written, so its landing is not read again.
            if replied { spokenNonces.removeAll { $0 == nonce } }
        }
        onTurnFailed?(nonce)
    }

    /// What became of words given to the guest ahead of their turn.
    private func follow(_ heard: GuestHeard) {
        switch heard {
        case .began(let nonce):
            hearing = nonce
        case .ended(let nonce, let reply):
            let drawn = !answeredElsewhere.contains(nonce) && !answered(nonce)
            if let reply, drawn { unsaved[nonce] = reply }
            if hearing == nonce {
                // The reply is whole and held by its nonce now, or there is none: either way
                // the row for what is being written is done with. The reader is told below.
                if reply != nil { writing = nil } else { dropWriting() }
                hearing = nil
            }
            // A turn still being run hears of its end from the runner. One that is not — its
            // save failed while the guest wrote, or it waits behind the line's head — ends here.
            if busy, pending.first?.nonce == nonce {
                heardEnded[nonce] = reply != nil
            } else if drawn {
                settleHeard(nonce, replied: reply != nil)
            }
        }
    }

    /// Keeps `writing` to what the guest has written of the message it is on.
    private func follow(_ activity: GuestActivity) {
        if case .update(.event(.writing)) = activity, let hearing, answeredElsewhere.contains(hearing) { return }
        switch activity {
        case .began(_, let answering):
            writing = nil
            if !answering.isEmpty { hearing = nil }
            writingSpoken = hearing.flatMap { spokenNonces.contains($0) ? $0 : nil }
                ?? turns.last { answering.contains($0.ref) && spokenNonces.contains($0.nonce) }?.nonce
        case .update(.event(.writingBegan)):
            // Empty rather than nil: the turn is still being answered, by a new message.
            writing = writing == nil ? nil : ""
            if let writing, let writingSpoken { onWriting?(writing, writingSpoken) }
        case .update(.event(.writing(let more))):
            if writing == nil { Perf.mark("turn.text.first") }
            writing = (writing ?? "") + more
            if let writingSpoken { onWriting?(writing, writingSpoken) }
        case .update(.ended(let end)):
            // A turn that ended with no reply leaves nothing to land; one that answered is
            // replaced by its turn when that is shown.
            if case .answered = end {} else { dropWriting() }
        case .update, .gone:
            break
        }
    }

    /// What was drawn of a reply goes, and whoever was reading it aloud is told no more comes.
    private func dropWriting() {
        writing = nil
        if let writingSpoken { onWriting?(nil, writingSpoken) }
        writingSpoken = nil
    }

    private func show(_ turn: Turn) {
        // The row gives way to the turn; the reader hears of the end after the reply was offered.
        if turn.role == .assistant { writing = nil }
        defer { if turn.role == .assistant { dropWriting() } }
        guard !turns.contains(where: { $0.ref == turn.ref }) else { return }
        turns.append(turn)
        // A reply in the log is drawn as the turn it is, and no longer as one iCloud is behind on.
        if turn.role == .assistant {
            for person in turns where person.role == .person && turn.parents.contains(person.ref) {
                unsaved[person.nonce] = nil
                heardEnded[person.nonce] = nil
            }
        }
        seen(turn)
    }

    /// A reply the handler has not been given. Offered once, whichever path brought it; with no
    /// handler installed it is left unoffered, for whichever one is installed next.
    private func seen(_ turn: Turn) {
        if turn.role == .assistant { onLanded?(turn) }
        guard turn.role == .assistant, let onReply, !offered.contains(turn.ref) else { return }
        if onReply(turn) { offered.insert(turn.ref) }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case TurnRunnerError.displaced:
            "Another device took over mid-reply. Your words are in the log."
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
    /// stays unanswered while a primary is awake. A line that stopped on a failure is sent again
    /// from here too, backing off while it keeps failing (`retryBackoff`), so a turn that did not
    /// go on a bad minute goes when the minute is over, with nobody pressing anything.
    ///
    /// `wake()` cuts the pause short: the next pass runs now rather than at the end of the
    /// interval. It never runs a pass of its own, so passes never overlap.
    func answering(every interval: Duration) async {
        let login = self.login
        answeringLoop = true
        defer {
            answeringLoop = false
            let left = wakers
            wakers = []
            left.forEach { $0.resume() }
        }
        // A sign-out ends the loop: whatever answers next is the next login's.
        while !Task.isCancelled, self.login == login {
            // A wake asked for before this pass began is served by it; one asked for during it
            // may have missed what this pass read, so it gets the next.
            woken = false
            let served = wakers
            wakers = []
            await onPass?()
            let read = await refresh()
            // A line that stopped on a failure goes again from here, on the loop's own time, once
            // the log can be read at all.
            if read { await retryStoppedLine(every: interval) }
            guard self.login == login else { return }
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
    /// The pass is a task of its own, so a sign-out can cancel it as it cancels a send; cancelling
    /// the caller cancels it too.
    func answerPending() async {
        guard !busy else { return }
        let login = self.login
        let pass = Task { await self.pass(under: login) }
        passes.insert(pass)
        await withTaskCancellationHandler { await pass.value } onCancel: { pass.cancel() }
        passes.remove(pass)
    }

    private func pass(under login: Int) async {
        do {
            if runner == nil {
                try await ensureZone()
                guard self.login == login else { return }
                runner = try await makeRunner()
            }
            guard let runner, self.login == login else { return }
            defer { keepStanding(of: runner, under: login) }
            let answered = try await runner.answerPending(model: model)
            // A sign-out during the pass: what it found is for a screen that has gone.
            guard self.login == login else { return }
            if let reply = answered {
                show(reply)
                failure = nil
                await refresh()
                // The reply is in the log, so anything the turn left in the memory goes out now.
                await onPass?()
            }
            await refreshUnfinished()
        } catch TurnRunnerError.notPrimary {
            // Another device holds the lease and this one has yielded to it; that device answers.
        } catch TurnRunnerError.displaced {
            // Another device took the lease as the reply was ready; it answers.
            dropWriting()
        } catch is CancellationError {
            return
        } catch {
            guard self.login == login else { return }
            dropWriting()
            failure = Failure(words: Self.describe(error))
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
        failure = nil
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
        return TurnRunner(log: log, writer: writer, lease: lease, brain: brain, standing: standing)
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

    /// What the chat says when a turn went into the log for another device's primary to answer:
    /// the words are saved, who answers them, and that the reply comes here. It is a notice in the
    /// navigation bar, so it is short enough for two lines beside the badge on the narrowest phone.
    static func limbInfo(_ outcome: LeaseOutcome) -> String {
        switch outcome {
        case .primary: "Saved. The reply will appear here."
        case .held(let by): "Saved. \(by.holder.rawValue) will answer here."
        case .unreachable(let lease): "Saved. \(lease.holder.rawValue) will answer; it's out of reach now."
        case .contended: "Saved. Another device will answer here."
        }
    }
}

/// Where the guest's activity goes on its way to the screen: the bridge is made before the harness,
/// so it tells this, and the harness hands it on to whoever set `onGuest`.
@MainActor
final class GuestRelay {
    var handler: (@MainActor (GuestActivity) -> Void)?
    /// The harness's own ear, for the reply as it is written (`Harness.writing`).
    var writing: (@MainActor (GuestActivity) -> Void)?
    /// And for what became of words given to the guest ahead of their turn.
    var heard: (@MainActor (GuestHeard) -> Void)?
    nonisolated init() {}
    func tell(_ what: GuestHeard) { heard?(what) }
    func tell(_ activity: GuestActivity) {
        writing?(activity)
        handler?(activity)
    }
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

    /// The base's bounded saves and fetches, noted here like the rest: the lease asks for
    /// these, and a wrapper that answered with itself would leave its requests unbounded.
    func answering(within seconds: TimeInterval) -> any RecordDatabase {
        Bounded(recording: self, base: base.answering(within: seconds))
    }

    private struct Bounded: RecordDatabase {
        let recording: RecordingDatabase
        let base: any RecordDatabase
        func save(_ records: [Record]) async throws -> [Record] { try await recording.noting { try await base.save(records) } }
        func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await recording.noting { try await base.fetch(ids) } }
        func query(_ query: RecordQuery) async throws -> [Record] { try await recording.query(query) }
        func records(ofType type: String) async throws -> [Record] { try await recording.records(ofType: type) }
        func answering(within seconds: TimeInterval) -> any RecordDatabase { recording.answering(within: seconds) }
    }

    fileprivate func noting<T>(_ call: () async throws -> T) async throws -> T {
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
