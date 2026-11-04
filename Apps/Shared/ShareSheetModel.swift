#if os(iOS)
import Foundation
import Observation

/// What the share sheet shows and does: the thing shared once it is read, why it was refused if
/// it was, and the note. One sheet is one share: its nonce is minted with the sheet, and once it
/// is kept a second Send keeps nothing. The composer's `+` puts up the same sheet over what the
/// person picked on this phone (`take`), kept as a share that came in by the composer under the
/// login the pick was made under: a door opened under another login since is a sign-out.
@MainActor
@Observable
final class ShareSheetModel {
    enum State: Equatable {
        case reading
        case ready(ShareIntake.Item)
        case refused(ShareRefusal)
        case sent
    }

    private(set) var state: State = .reading
    var note = ""
    /// A note over the limit is not sent and not cut: the sheet says so and Send waits.
    var noteTooLong: Bool { note.count > Share.noteLimit }
    private let store: ShareStore?
    /// Absent for the extension's share; only the composer's says where it came in.
    private let via: Share.Via?
    /// The login a pick on this phone was made under, which the door must still name when what
    /// was picked lands; nil for the extension's, whose sheet starts at the read.
    private let pickedUnder: String?
    private let nonce = UUID().uuidString
    private var login: String?
    private var scratch: URL?

    init(store: ShareStore? = ShareStore.shared(), via: Share.Via? = nil, pickedUnder: String? = nil) {
        self.store = store
        self.via = via
        self.pickedUnder = pickedUnder
    }

    /// The door, where it is open under the login this sheet's pick was made under.
    private func door(of store: ShareStore) -> ShareStore.Door? {
        guard let door = store.door(), pickedUnder.map({ $0 == door.login }) ?? true else { return nil }
        return door
    }

    /// Whether the sheet is over: cancelled, or its share kept. A read or a copy that lands
    /// after keeps nothing and takes its own scratch away.
    private var closed = false

    /// Something picked on this phone, read as the sheet reads a share (`read`), or a file
    /// already copied into a scratch folder of the store's (`take`): the door is read as it is
    /// for a share, so a pick while signed out or under another login than the pick's, or an
    /// image or a file where the guest is not, is refused with the scratch taken away. A copy landing on a sheet already cancelled is
    /// taken away too.
    func take(_ item: ShareIntake.Item, in scratch: URL) {
        guard !closed else { store?.discard(scratch); return }
        self.scratch = scratch
        guard let store, let door = door(of: store) else { return refuse(.signedOut) }
        login = door.login
        if item.kind == .image || item.kind == .file, !door.files { return refuse(.anotherPhone) }
        state = .ready(item)
    }

    /// Shown refused, with the scratch, if any, taken away.
    func refuse(_ refusal: ShareRefusal) {
        discard()
        state = .refused(refusal)
    }

    func read(_ providers: [NSItemProvider]) async {
        guard let store, let door = door(of: store) else { return state = .refused(.signedOut) }
        login = door.login
        guard let choice = ShareIntake.choice(among: providers) else { return state = .refused(.nothing) }
        if choice.kind == .image || choice.kind == .file, !door.files { return state = .refused(.anotherPhone) }
        do {
            let scratch = try store.scratch()
            self.scratch = scratch
            let item = try await ShareIntake.item(from: providers, into: scratch)
            // Cancelled while the read ran: what it read goes with the scratch.
            guard !closed else { store.discard(scratch); return }
            state = .ready(item)
        } catch let refusal as ShareRefusal {
            discard()
            state = .refused(refusal)
        } catch {
            discard()
            state = .refused(.failed)
        }
    }

    /// Keeps the share, and answers whether this call kept it; a refusal is shown in its place.
    func keep() -> Bool {
        guard let store, let login, case .ready(let item) = state, !noteTooLong else { return false }
        let share = Share(nonce: nonce, login: login, time: Date(), kind: item.kind, note: note,
                          text: item.text, file: item.file?.lastPathComponent, bytes: item.bytes, via: via)
        do {
            try store.keep(share, attachment: item.file)
        } catch {
            discard()
            state = .refused(error)
            return false
        }
        discard()
        state = .sent
        return true
    }

    /// Takes away a scratch folder that never became this sheet's.
    func discardScratch(_ scratch: URL) {
        store?.discard(scratch)
    }

    func discard() {
        closed = true
        if let scratch { store?.discard(scratch) }
        scratch = nil
    }
}
#endif
