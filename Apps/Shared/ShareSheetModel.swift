#if os(iOS)
import Foundation
import Observation

/// What the share sheet shows and does: the thing shared once it is read, why it was refused if
/// it was, and the note. One sheet is one share: its nonce is minted with the sheet, and once it
/// is kept a second Send keeps nothing.
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
    private let nonce = UUID().uuidString
    private var login: String?
    private var scratch: URL?

    init(store: ShareStore? = ShareStore.shared()) {
        self.store = store
    }

    func read(_ providers: [NSItemProvider]) async {
        guard let store, let door = store.door() else { return state = .refused(.signedOut) }
        login = door.login
        guard let choice = ShareIntake.choice(among: providers) else { return state = .refused(.nothing) }
        if choice.kind == .image || choice.kind == .file, !door.files { return state = .refused(.anotherPhone) }
        do {
            let scratch = try store.scratch()
            self.scratch = scratch
            state = .ready(try await ShareIntake.item(from: providers, into: scratch))
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
                          text: item.text, file: item.file?.lastPathComponent, bytes: item.bytes)
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

    func discard() {
        if let scratch { store?.discard(scratch) }
        scratch = nil
    }
}
#endif
