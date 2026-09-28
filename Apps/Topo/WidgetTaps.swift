import Foundation
import TopoTools

/// The app's side of a tap on one of the mind's widgets, set as `WidgetIntents.handler` at launch
/// so an intent the system launched the app for finds it.
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
}

/// The cues a `turn` control's tap recorded in the app group, put on the harness's line — the
/// row's one path to the outbox — each under the nonce the intent minted with it. A record goes
/// only once its nonce is on the line or in the log, and `Harness.willSend(_:nonce:)` does
/// nothing for a nonce already there, so a drain run twice (before a removal, after a crash) is
/// one turn. It waits for the harness's first read of the log, since before it the harness
/// cannot know what the log holds.
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
    /// records its cue, then drained.
    func open(_ url: URL) async {
        guard let cue = WidgetURL.cue(from: url), let store = store() else { return }
        try? store.appendCue(cue)
        await drain()
    }

    func drain() async {
        guard harness.hasRead, let store = store() else { return }
        var queued = false
        for cue in store.cues() {
            // A tap on an old timeline is not what the slot says now. The app's own default is
            // rewritten after every reply, and its one control means the same at every revision.
            if cue.slot != SurfaceStore.defaultSlot, cue.revision != store.revision(slot: cue.slot) {
                try? store.appendTap(SurfaceStore.Tap(time: cue.time, slot: cue.slot, id: cue.id, revision: cue.revision,
                                                     kind: "turn", status: "stale"))
                try? store.removeCue(nonce: cue.nonce)
                reloader.reload()
                continue
            }
            guard harness.willSend(cue.words, nonce: cue.nonce) else { continue }
            try? store.appendTap(SurfaceStore.Tap(time: cue.time, slot: cue.slot, id: cue.id, revision: cue.revision,
                                                 kind: "turn", status: "cued"))
            try? store.removeCue(nonce: cue.nonce)
            queued = true
        }
        if queued { await harness.retry() }
    }
}

/// A `run` control's tap: the revision judged, the call judged against the allowlist again, then
/// run through `ToolService.bounded` over the widgets' own tool table — the guest's tools, the
/// same bound, cancellation and permission broker, with `home` refusing a lock's and a door's
/// target — and its status, never its words, written to `taps.jsonl`.
@MainActor
final class WidgetActions {
    let table: ToolTable
    let store: @MainActor () -> SurfaceStore?
    let reloader: SurfaceReloader
    let bound: Duration

    init(table: ToolTable, store: @escaping @MainActor () -> SurfaceStore? = { SurfaceStore.shared() },
         reloader: SurfaceReloader = .shared, bound: Duration = ToolService.defaultBound) {
        self.table = table
        self.store = store
        self.reloader = reloader
        self.bound = bound
    }

    func run(slot: String, control id: String, revision: Int, turningOn: Bool?) async {
        guard let store = store() else { return }
        func record(_ status: String) {
            try? store.appendTap(SurfaceStore.Tap(time: Date(), slot: slot, id: id, revision: revision, kind: "run", status: status))
            reloader.reload()
        }
        guard let document = store.read(slot: slot)?.document, document.revision == revision,
              let control = document.controls[id] else {
            return record("stale")
        }
        // The kept copy is read through the reader again, which takes a run off the allowlist
        // back to `open`; the allowlist is asked again here all the same.
        guard let argv = control.argv(turningOn: turningOn), WidgetAction.refusal(argv) == nil else {
            return record(String(ToolReply.refused))
        }
        let reply = await ToolService.bounded(argv, table: table, until: .now + bound, bound: bound)
        record(String(reply.status))
    }
}
