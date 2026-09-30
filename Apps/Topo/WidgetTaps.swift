import Foundation
import TopoTools

/// The app's side of a tap on one of the mind's widgets or controls, set as `WidgetIntents.handler`
/// at launch so an intent the system launched the app for finds it.
@MainActor
final class WidgetTaps: WidgetTapHandler {
    let cues: WidgetCues
    let actions: WidgetActions

    init(cues: WidgetCues, actions: WidgetActions) {
        self.cues = cues
        self.actions = actions
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
            if (try? store.recordCue(cue)) == true { Task { await cues.drain() } }
            return .foreground
        case .open:
            return .foreground
        case .run:
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
    /// A turn's words, given the state a toggle is turning to; nil when the action is no turn.
    var turn: (Bool?) -> String?
    /// Asks for what shows the slot to be drawn again.
    var reload: @MainActor (SurfaceReloader) -> Void

    /// The tapped control `id` of the document in `slot`, as `read` or the store holds it now.
    @MainActor
    static func find(_ store: SurfaceStore, slot: String, id: String,
                     read: (SurfaceStore, String) -> WidgetDocument?) -> Tapped? {
        if let control = ControlSlot.slot(stored: slot) {
            guard id == ControlSlot.control, let document = store.readControl(slot: control)?.document else { return nil }
            return Tapped(revision: document.revision, isControl: true, isToggle: document.kind == .toggle, on: document.on,
                          argv: { document.argv(turningOn: $0) }, turn: { document.turn(slot: control, turningOn: $0) },
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
/// one turn. It waits for the harness's first read of the log, since before it the harness
/// cannot know what the log holds. A cue carries no words: they are the slot's document's.
@MainActor
final class WidgetCues {
    let harness: Harness
    let store: @MainActor () -> SurfaceStore?
    let reloader: SurfaceReloader

    init(harness: Harness, store: @escaping @MainActor () -> SurfaceStore? = { SurfaceStore.shared() },
         reloader: SurfaceReloader = .shared) {
        self.harness = harness
        self.store = store
        self.reloader = reloader
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

    func drain() async {
        guard harness.hasRead, let store = store() else { return }
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
/// same, read from its `ControlDocument` and reloading its control kind.
@MainActor
final class WidgetActions {
    let table: ToolTable
    let store: @MainActor () -> SurfaceStore?
    let reloader: SurfaceReloader
    let bound: Duration
    /// The slot's document as the tap finds it: the store's, read through the reader. A suite
    /// hands one the reader would not keep, to hold the tap's own allowlist check.
    let read: @MainActor (SurfaceStore, String) -> WidgetDocument?
    /// Each control's last run, which its next waits on, so a control's effects land in the
    /// order its taps were handled.
    private var chains: [String: Task<Void, Never>] = [:]
    /// Every run in flight, the ones a chain waits behind included, which a sign-out cancels.
    private var running: [UUID: Task<Void, Never>] = [:]
    /// Each toggle's confirmed state at a revision: the last its run succeeded at, or the stored
    /// one before its chain began. A failed run puts the toggle back to it, not to the state the
    /// failed tap flipped from, which another failed tap may have flipped already.
    private var confirmed: [String: Bool] = [:]

    init(table: ToolTable, store: @escaping @MainActor () -> SurfaceStore? = { SurfaceStore.shared() },
         reloader: SurfaceReloader = .shared, bound: Duration = ToolService.defaultBound,
         read: @escaping @MainActor (SurfaceStore, String) -> WidgetDocument? = { $0.read(slot: $1)?.document }) {
        self.table = table
        self.store = store
        self.reloader = reloader
        self.bound = bound
        self.read = read
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
        if chains[key] != nil { confirmed["\(key)/\(revision)"] = on }
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
        func record(_ status: String) {
            try? store.appendTap(SurfaceStore.Tap(time: Date(), slot: slot, id: id, revision: revision, kind: "run", status: status))
            reload()
        }
        guard let tapped = find(), tapped.revision == revision, tapped.isControl else {
            // A tap drawn in an earlier login — a widget still showing after a sign-out — is
            // recorded nowhere, so nothing of it reaches the next login's taps.
            if store.isEarlierLogin(revision) { return reload() }
            return record("stale")
        }
        // The kept copy is read through the reader again, which takes a run off the allowlist
        // back to `open`; the allowlist is asked again here all the same.
        guard tapped.argv(true).map({ WidgetAction.refusal($0) == nil }) == true,
              tapped.argv(false).map({ WidgetAction.refusal($0) == nil }) == true else {
            return record(String(ToolReply.refused))
        }
        // A widget's toggle turns to the opposite of its stored state, flipped as the tap is
        // handled, not of the state the tapped entry drew; a control's to the state the person
        // asked for. A run that fails puts it back to its confirmed one.
        let key = "\(slot)/\(id)"
        let state = "\(key)/\(revision)"
        var was: Bool?
        var now: Bool?
        if tapped.isToggle {
            let control = ControlSlot.slot(stored: slot)
            let stored: Bool?
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
            if chains[key] == nil { confirmed[state] = stored }
        }
        guard let argv = tapped.argv(now) else { return record(String(ToolReply.refused)) }
        // After the control's last run, whatever it answered, so two quick taps' writes land in
        // the order they were flipped and a failed one holds up none after it.
        let previous = chains[key]
        let (table, bound) = (table, bound)
        let task = Task { @MainActor in
            await previous?.value
            let reply = await ToolService.bounded(argv, table: table, until: .now + bound, bound: bound)
            // A run that outlived its slot's document at this revision — a sign-out cleared it, or
            // the slot was written anew — writes nothing, so the next login sees no tap of this
            // one's controls.
            guard !Task.isCancelled, find()?.revision == revision else { return }
            if let was, let now {
                if reply.status == 0 {
                    confirmed[state] = now
                } else {
                    try? store.setOn(confirmed[state] ?? was, slot: slot, control: id, revision: revision)
                }
            }
            record(String(reply.status))
        }
        chains[key] = task
        let token = UUID()
        running[token] = task
        await task.value
        running[token] = nil
        if chains[key] == task {
            chains[key] = nil
            confirmed[state] = nil
        }
    }
}
