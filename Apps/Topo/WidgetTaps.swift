import Foundation
import TopoTools

/// The app's side of a tap on one of the mind's widgets or controls, set as `WidgetIntents.handler`
/// at launch so an intent the system launched the app for finds it.
@MainActor
final class WidgetTaps: WidgetTapHandler {
    let cues: WidgetCues
    let actions: WidgetActions
    /// Whether a control's turn tap holds its intent open until the drain has sent the turn. Before
    /// iOS 26 the intent does not bring Topo forward, and a process launched in the background for
    /// it has nothing else keeping it alive once `perform` returns; from iOS 26 the app comes
    /// forward and the drain runs on there.
    let holdsForTheDrain: Bool
    /// How long a held tap waits on its drain: a read and a write of the log, inside the time the
    /// system gives an intent.
    static let drainBound: Duration = .seconds(20)
    let drainBound: Duration

    init(cues: WidgetCues, actions: WidgetActions, holdsForTheDrain: Bool = WidgetTaps.drainIsHeld,
         drainBound: Duration = WidgetTaps.drainBound) {
        self.cues = cues
        self.actions = actions
        self.holdsForTheDrain = holdsForTheDrain
        self.drainBound = drainBound
    }

    /// Returns when `task` ends or `bound` has passed, whichever is first, and leaves `task`
    /// running: a race on a continuation, since a task group waits for every child, and a child
    /// awaiting another task's value does not end when cancelled.
    static func wait(for task: Task<Void, Never>, atMost bound: Duration) async {
        let once = Once()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            once.set(continuation)
            let timer = Task {
                try? await Task.sleep(for: bound)
                once.resume()
            }
            Task {
                await task.value
                timer.cancel()
                once.resume()
            }
        }
    }

    /// A continuation resumed by the first of two racers and never again.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        func set(_ continuation: CheckedContinuation<Void, Never>) { lock.withLock { self.continuation = continuation } }
        func resume() {
            let taken = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { continuation = nil }
                return continuation
            }
            taken?.resume()
        }
    }

    static var drainIsHeld: Bool {
        if #available(iOS 26, *) { false } else { true }
    }

    /// The intent returns once the cue is recorded and the app is coming forward: the drain, and
    /// the turn it sends, run on without holding the intent open.
    func cued(_ cue: SurfaceStore.Cue, recorded: Bool) async {
        Task { await cues.drain() }
    }

    func run(slot: String, control: String, revision: Int, turningOn: Bool?) async {
        await actions.run(slot: slot, control: control, revision: revision, turningOn: turningOn)
    }

    /// A control's tap, as the slot's document at the tap's revision says: a turn's cue recorded
    /// (under a nonce minted here, once) and drained, then Topo in front; `open` in front; a `run`
    /// through `WidgetActions`, in the background. A slot holding no document is a signed-out
    /// phone's, whose tap opens Topo and records nothing; a tap on another revision is
    /// `WidgetActions`' to refuse, whatever either revision's action is.
    func controlTapped(slot: String, revision: Int, turningOn: Bool?) async -> ControlTap {
        guard ControlSlot.kind(of: slot) != nil, let store = cues.store(),
              let reading = store.readControl(slot: slot), reading.readable else { return .foreground }
        let stored = ControlSlot.stored(slot)
        let document = reading.document
        guard document.revision == revision else {
            await actions.run(slot: stored, control: ControlSlot.control, revision: revision, turningOn: turningOn)
            return .background
        }
        switch document.action {
        case .turn:
            let cue = SurfaceStore.Cue(nonce: UUID().uuidString, slot: stored, id: ControlSlot.control, revision: revision,
                                       turningOn: turningOn, time: Date())
            guard (try? store.recordCue(cue)) == true else { return .foreground }
            let draining = Task { await cues.drain() }
            if holdsForTheDrain { await Self.wait(for: draining, atMost: drainBound) }
            return .foreground
        case .open:
            return .foreground
        case .run, .request:
            await actions.run(slot: stored, control: ControlSlot.control, revision: revision, turningOn: turningOn)
            return .background
        }
    }
}

/// A slot's document as a tap reads it: a widget's control, or a control slot's own document,
/// chosen by the slot's store name (`ControlSlot.prefix`). This choice is the whole of what the
/// cues and the runs change for a control.
private struct Tapped {
    var revision: Int
    /// Whether the id names a control of the document; a widget's whole tap names none.
    var isControl: Bool
    var isToggle: Bool
    var on: Bool
    /// The call a tap makes, given the state a toggle is turning to.
    var argv: (Bool?) -> [String]?
    /// A control's request, given the state a toggle is turning to; nil when the action is no request.
    var request: (Bool?) -> ControlRequest.Form? = { _ in nil }
    /// A turn's words, given the state a toggle is turning to; nil when the action is no turn.
    var turn: (Bool?) -> String?
    /// Asks for what shows the slot to be drawn again.
    var reload: @MainActor (SurfaceReloader) -> Void

    /// What a toggle's taps act on: its calls for on and for off. Two revisions of a slot with
    /// the same target act on the same device; a rewrite that changes it points the toggle at
    /// another.
    struct Target: Hashable {
        var on: [String]?
        var off: [String]?
        var requestOn: ControlRequest.Form?
        var requestOff: ControlRequest.Form?
    }
    var target: Target { Target(on: argv(true), off: argv(false), requestOn: request(true), requestOff: request(false)) }

    /// The tapped control `id` of the document in `slot`, as `read` or the store holds it now.
    @MainActor
    static func find(_ store: SurfaceStore, slot: String, id: String,
                     read: (SurfaceStore, String) -> WidgetDocument?) -> Tapped? {
        if let control = ControlSlot.slot(stored: slot) {
            guard id == ControlSlot.control, let document = store.readControl(slot: control)?.document else { return nil }
            return Tapped(revision: document.revision, isControl: true, isToggle: document.kind == .toggle, on: document.on,
                          argv: { document.argv(turningOn: $0) }, request: { document.request(turningOn: $0) },
                          turn: { document.turn(slot: control, turningOn: $0) },
                          reload: { $0.reloadControls(kind: document.kind.controlKind) })
        }
        guard let document = read(store, slot) else { return nil }
        let reload: @MainActor (SurfaceReloader) -> Void = { $0.reload() }
        guard let control = document.controls[id] else {
            return Tapped(revision: document.revision, isControl: false, isToggle: false, on: false, argv: { _ in nil },
                          turn: { _ in document.turn(slot: slot, control: id, turningOn: nil) }, reload: reload)
        }
        return Tapped(revision: document.revision, isControl: true, isToggle: control.kind == .toggle, on: control.on,
                      argv: { control.argv(turningOn: $0) }, turn: { document.turn(slot: slot, control: id, turningOn: $0) },
                      reload: reload)
    }

    /// What a slot that holds nothing now shows is drawn again.
    @MainActor
    static func reloadGone(_ reloader: SurfaceReloader, slot: String) {
        if let control = ControlSlot.slot(stored: slot), let kind = ControlSlot.kind(of: control) {
            reloader.reloadControls(kind: kind.controlKind)
        } else {
            reloader.reload()
        }
    }
}

/// The cues a `turn` control's tap recorded in the app group, put on the harness's line — the
/// row's one path to the outbox — each under the nonce the intent minted with it. A record goes
/// only once its nonce is on the line or in the log, and `Harness.willSend(_:nonce:)` does
/// nothing for a nonce already there, so a drain run twice (before a removal, after a crash) is
/// one turn. A harness that has not read the log reads it first, since before it the harness
/// cannot know what the log holds. A cue carries no words: they are the slot's document's.
@MainActor
final class WidgetCues {
    let harness: Harness
    let store: @MainActor () -> SurfaceStore?
    let reloader: SurfaceReloader
    /// The slot's record owed a save: a toggle's state is part of its document.
    let changed: @MainActor (String) -> Void

    init(harness: Harness, store: @escaping @MainActor () -> SurfaceStore? = { SurfaceStore.shared() },
         reloader: SurfaceReloader = .shared, changed: @escaping @MainActor (String) -> Void = { SurfaceSync.shared.changed(slot: $0) }) {
        self.harness = harness
        self.store = store
        self.reloader = reloader
        self.changed = changed
    }

    /// A `topo://cue` URL, which a `link` hands on in place of an intent: recorded as the intent
    /// records its cue, then drained, if it names a turn of a document the store holds now at its
    /// revision. Any page may open one, and one opened signed out, when the store holds nothing,
    /// is not kept for the next login's drain.
    func open(_ url: URL) async {
        guard let cue = WidgetURL.cue(from: url), let store = store(),
              let document = store.read(slot: cue.slot)?.document, document.revision == cue.revision,
              document.turn(slot: cue.slot, control: cue.id, turningOn: cue.turningOn) != nil else { return }
        try? store.appendCue(cue)
        await drain()
    }

    /// Puts every cue on the harness's line and sends it. A harness that has not read the log —
    /// the app launched in the background for the intent, with no screen to have read it — reads
    /// it first, since only then does it know which nonces the log already holds; a read that
    /// fails leaves the cues for the next drain.
    func drain() async {
        guard let store = store() else { return }
        if !harness.hasRead {
            guard !store.cues().isEmpty, await harness.refresh() else { return }
        }
        var queued = false
        for cue in store.cues() {
            func record(_ status: String) {
                try? store.appendTap(SurfaceStore.Tap(time: cue.time, slot: cue.slot, id: cue.id, revision: cue.revision,
                                                     kind: "turn", status: status))
            }
            // The words are the document's at the revision the tap was drawn from, the app's
            // default included: a tap on an old timeline, or on a control the document does not
            // hold as a turn, sends nothing.
            // A cue outlives no layout: one whose slot holds no document at its revision (a
            // sign-out, an earlier login's, a slot written anew) is dropped with no record, the
            // rule the intent keeps it by (`SurfaceStore.recordCue`).
            guard let tapped = Tapped.find(store, slot: cue.slot, id: cue.id, read: { $0.read(slot: $1)?.document }),
                  tapped.revision == cue.revision else {
                try? store.removeCue(nonce: cue.nonce)
                Tapped.reloadGone(reloader, slot: cue.slot)
                continue
            }
            guard tapped.turn(nil) != nil else {
                record(String(ToolReply.refused))
                try? store.removeCue(nonce: cue.nonce)
                continue
            }
            // A toggle's new state is resolved once and written into the cue before the toggle
            // is set to it, so a drain after a crash anywhere here sets and says the same state;
            // a cue already sent sets nothing. A widget's toggle turns to the opposite of its
            // stored state; a control's to the state the person asked for, which Control Center
            // has already drawn.
            var turningOn: Bool?
            let sent = harness.said(cue.nonce) || harness.owed.contains { $0.nonce == cue.nonce }
            if !sent, tapped.isToggle {
                let asked = ControlSlot.slot(stored: cue.slot) == nil ? nil : cue.turningOn
                let resolved = cue.resolved ?? asked ?? !tapped.on
                do {
                    if cue.resolved == nil { try store.resolveCue(nonce: cue.nonce, resolved) }
                    // Owed before the write, in this job, so no pass reads the slot between them.
                    if ControlSlot.slot(stored: cue.slot) == nil { changed(cue.slot) }
                    try store.setOn(resolved, slot: cue.slot, control: cue.id, revision: cue.revision)
                } catch {
                    continue
                }
                turningOn = resolved
                tapped.reload(reloader)
            }
            guard let words = tapped.turn(turningOn), harness.willSend(words, nonce: cue.nonce) else { continue }
            record("cued")
            try? store.removeCue(nonce: cue.nonce)
            queued = true
        }
        if queued { await harness.retry() }
    }
}

/// A `run` control's tap: the revision judged, the call judged against the allowlist again, then
/// run through `ToolService.bounded` over the widgets' own tool table — the guest's tools, the
/// same bound, cancellation and permission broker, with `home` refusing a lock's and a door's
/// target — and its status, never its words, written to `taps.jsonl`. A control slot's run is the
/// same, read from its `ControlDocument` and reloading its control kind; a control's `request` takes
/// the same path up to the call, where `ControlRequest.perform` takes the place of the tool table,
/// and records its status with the HTTP code.
@MainActor
final class WidgetActions {
    let table: ToolTable
    let store: @MainActor () -> SurfaceStore?
    let reloader: SurfaceReloader
    let bound: Duration
    /// Makes a control's request (`ControlRequest.perform`); a suite hands one of its own secrets.
    let perform: @Sendable (ControlRequest.Form) async -> ControlRequest.Answer
    /// The slot's document as the tap finds it: the store's, read through the reader. A suite
    /// hands one the reader would not keep, to hold the tap's own allowlist check.
    let read: @MainActor (SurfaceStore, String) -> WidgetDocument?
    /// The slot's record owed a save: a toggle's state is part of its document.
    let changed: @MainActor (String) -> Void
    /// Each control's last run, which its next waits on, so a control's effects land in the
    /// order its taps were handled.
    private var chains: [String: Task<Void, Never>] = [:]
    /// Every run in flight, the ones a chain waits behind included, which a sign-out cancels.
    private var running: [UUID: Task<Void, Never>] = [:]
    /// Each toggle's state as its device took it last while its runs are chained, kept per target,
    /// since a rewrite can point the toggle at another device: the last run that succeeded on it,
    /// whatever revision drew it, or the mind's word about it since (`confirm`).
    private var settled: [String: [Tapped.Target: Bool]] = [:]
    /// Each toggle's stored state at a revision before that revision's first tap: what a failure
    /// goes back to when no run has taken.
    private var baseline: [String: Bool] = [:]
    /// Each tap's number, and each control's latest, so a failed run knows whether a later tap
    /// stands to settle the toggle.
    private var sequence = 0
    private var latest: [String: Int] = [:]

    init(table: ToolTable, store: @escaping @MainActor () -> SurfaceStore? = { SurfaceStore.shared() },
         reloader: SurfaceReloader = .shared, bound: Duration = ToolService.defaultBound,
         perform: @escaping @Sendable (ControlRequest.Form) async -> ControlRequest.Answer = {
             await ControlRequest.perform($0, secrets: ControlSecrets())
         },
         read: @escaping @MainActor (SurfaceStore, String) -> WidgetDocument? = { $0.read(slot: $1)?.document },
         changed: @escaping @MainActor (String) -> Void = { SurfaceSync.shared.changed(slot: $0) }) {
        self.table = table
        self.store = store
        self.reloader = reloader
        self.bound = bound
        self.perform = perform
        self.read = read
        self.changed = changed
        reloader.onForget { [weak self] in self?.cancelAll() }
    }

    /// A sign-out: every run in flight is cancelled, so none takes its effect after the login
    /// has ended, and each one's record is dropped (`run`).
    func cancelAll() {
        running.values.forEach { $0.cancel() }
    }

    /// The mind has set a toggle's state itself (`topo control state`): while its runs are
    /// chained, a run failing after this puts the toggle back to what the mind said, not to what
    /// it was before.
    func confirm(_ on: Bool, slot: String, control id: String, revision: Int) {
        let key = "\(slot)/\(id)"
        // A state written at a stale revision wrote nothing, and settles nothing.
        guard chains[key] != nil, let store = store(),
              let current = Tapped.find(store, slot: slot, id: id, read: read), current.revision == revision else { return }
        settled[key, default: [:]][current.target] = on
    }

    /// The widgets' tool table: the guest's tools, with `home` refusing a lock's and a door's
    /// target, and any scene that sets one (`HomeTool.widgetRefused`).
    static func table(_ tools: [any Tool]) -> ToolTable {
        ToolTable(tools.map { tool in
            guard var home = tool as? HomeTool else { return tool }
            home.refusing = HomeTool.widgetRefused
            return home
        })
    }

    func run(slot: String, control id: String, revision: Int, turningOn: Bool?) async {
        guard let store = store() else { return }
        let read = read
        func find() -> Tapped? { Tapped.find(store, slot: slot, id: id, read: read) }
        func reload() { Tapped.reloadGone(reloader, slot: slot) }
        func record(_ status: String, kind: String = "run", code: Int? = nil) {
            try? store.appendTap(SurfaceStore.Tap(time: Date(), slot: slot, id: id, revision: revision, kind: kind, status: status,
                                                  code: code))
            reload()
        }
        guard let tapped = find(), tapped.revision == revision, tapped.isControl else {
            // A tap drawn in an earlier login — a widget still showing after a sign-out — is
            // recorded nowhere, so nothing of it reaches the next login's taps.
            if store.isEarlierLogin(revision) { return reload() }
            return record("stale")
        }
        // The kept copy is read through the reader again, which takes a run off the allowlist
        // back to `open`; the allowlist is asked again here all the same. A request was judged by
        // the same reader, and has no allowlist to ask.
        let isRequest = tapped.request(nil) != nil
        guard isRequest || (tapped.argv(true).map({ WidgetAction.refusal($0) == nil }) == true
                            && tapped.argv(false).map({ WidgetAction.refusal($0) == nil }) == true) else {
            return record(String(ToolReply.refused))
        }
        // A widget's toggle turns to the opposite of its stored state, flipped as the tap is
        // handled, not of the state the tapped entry drew; a control's to the state the person
        // asked for. The last tap's run settles it at the state the device took last.
        let key = "\(slot)/\(id)"
        let state = "\(key)/\(revision)"
        var was: Bool?
        var now: Bool?
        if tapped.isToggle {
            let control = ControlSlot.slot(stored: slot)
            let stored: Bool?
            // A widget slot's record is owed before the write, in this job, so no pass reads the
            // slot between them; a control's slot has no record.
            if control == nil { changed(slot) }
            do {
                if let control {
                    stored = try store.setControl(turningOn, slot: control, revision: revision)
                } else {
                    stored = try store.flip(slot: slot, control: id, revision: revision)
                }
            } catch {
                return record("stale")
            }
            guard let stored else { return record("stale") }
            was = stored
            now = (control == nil ? nil : turningOn) ?? !stored
            // The state before the first tap at this revision, whatever chain an older revision's
            // tap left running.
            if baseline[state] == nil { baseline[state] = stored }
        }
        let argv = tapped.argv(now)
        let form = tapped.request(now)
        let target = tapped.target
        guard argv != nil || form != nil else { return record(String(ToolReply.refused)) }
        // After the control's last run, whatever it answered, so two quick taps' writes land in
        // the order they were flipped and a failed one holds up none after it.
        // Numbered only once the tap has a run, so a tap refused above never stands as the latest.
        sequence += 1
        let tap = sequence
        latest[key] = tap
        let previous = chains[key]
        let (table, bound, perform) = (table, bound, perform)
        let task = Task { @MainActor in
            await previous?.value
            let status: Int32
            var code: Int?
            if let form {
                let answer = await perform(form)
                (status, code) = (answer.status, answer.code)
            } else {
                status = await ToolService.bounded(argv ?? [], table: table, until: .now + bound, bound: bound).status
            }
            // A run that outlived its slot's document — a sign-out cleared it — writes nothing, so
            // the next login sees no tap of this one's controls.
            guard !Task.isCancelled, let current = find() else { return }
            // The runs end in the taps' order, so the device is in the state of the last one that
            // took, whatever revision drew it, or the mind's word since. Only the last tap writes
            // the toggle, at the revision the slot holds now, since a later tap drew its own state
            // and its run settles it: at that state, or, when no run has taken, at the state before
            // its revision's first tap — and a slot written anew since, with nothing taken, keeps
            // the state the rewrite gave it.
            // A success settles the target the tap's document named, which is the device the run
            // touched; the slot draws what its own target took, so a rewrite that points the
            // toggle at another device draws nothing of the old one's.
            if let was, let now {
                if status == 0 { settled[key, default: [:]][target] = now }
                if latest[key] == tap {
                    let own = current.revision == revision ? baseline[state] ?? was : nil
                    if let on = settled[key]?[current.target] ?? own {
                        if ControlSlot.slot(stored: slot) == nil { changed(slot) }
                        try? store.setOn(on, slot: slot, control: id, revision: current.revision)
                    }
                }
            }
            // A slot written anew since keeps no tap of the revision it replaced.
            guard current.revision == revision else { return reload() }
            record(String(status), kind: form == nil ? "run" : "request", code: code)
        }
        chains[key] = task
        let token = UUID()
        running[token] = task
        await task.value
        running[token] = nil
        if chains[key] == task {
            chains[key] = nil
            settled[key] = nil
            baseline = baseline.filter { !$0.key.hasPrefix(key + "/") }
            latest[key] = nil
        }
    }
}
