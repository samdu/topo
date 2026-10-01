import Foundation
import TopoAuth

/// The app's own document for every control slot the mind has not written, so every slot holds a
/// document while signed in and a default's tap is A's cue under a revision like any other. It is
/// written into each slot holding none when the phone becomes signed in — never over a written
/// slot, so a relaunch keeps every slot and its revision — and back into a slot `topo control
/// clear` clears. A new login — the phase coming to signed in from anything else — writes the
/// default over every slot, so no document an earlier login wrote is kept. A sign-out, a takeover
/// and a viewer's arrival take every control document with the surfaces (`SurfaceReloader.forget`);
/// the control secrets go with the connections (`Connections.forget`).
@MainActor
final class ControlDefaults {
    let store: @MainActor () -> SurfaceStore?
    let reloader: SurfaceReloader

    init(store: @escaping @MainActor () -> SurfaceStore? = { SurfaceStore.shared() }, reloader: SurfaceReloader = .shared) {
        self.store = store
        self.reloader = reloader
    }

    /// The login's phase moving, as `DefaultSurface.follow` sees it: signed in, the missing
    /// defaults are written and their kinds reloaded; a new login's, every default, over whatever
    /// a slot held. A launch already signed in (`was` equal to `phase`) is not a new login.
    func follow(from was: SignIn.Phase, to phase: SignIn.Phase) {
        guard phase == .signedIn, let store = store() else { return }
        let kinds = Set(Self.fill(store, replacing: was != .signedIn).compactMap(ControlSlot.kind(of:)))
        for kind in kinds { reloader.reloadControls(kind: kind.controlKind) }
    }

    nonisolated static func write(slot: String, store: SurfaceStore) throws {
        try store.writeControl(ControlDocument.standard(slot: slot), slot: slot)
        try store.writeNotes([], slot: ControlSlot.stored(slot))
    }

    /// Every slot holding no readable document gets its default, and with `replacing` every slot
    /// does; answers the slots written. A slot a new login could not write its default over is
    /// taken away, so an earlier login's document is never drawn or run under the new one.
    @discardableResult
    nonisolated static func fill(_ store: SurfaceStore, replacing: Bool = false) -> [String] {
        ControlSlot.all.filter { slot in
            guard replacing || store.readControl(slot: slot)?.readable != true else { return false }
            if (try? write(slot: slot, store: store)) != nil { return true }
            if replacing { try? store.remove(slot: ControlSlot.stored(slot)) }
            return false
        }
    }
}
