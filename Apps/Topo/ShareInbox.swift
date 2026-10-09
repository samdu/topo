import Foundation
import TopoAuth
import TopoUserland

/// The line a share's turn is put on: the harness, or a suite's own.
@MainActor
protocol ShareLine: AnyObject {
    var hasRead: Bool { get }
    func refresh() async -> Bool
    func willSend(_ text: String, nonce: String) -> Bool
    func retry() async
}

extension Harness: ShareLine {}

/// What the person shared from another app's share sheet (`ShareStore`, written by the share
/// extension), made into turns: each share is put on the harness's line under the nonce the
/// extension minted, and nothing for a nonce already there, so a drain run twice (before a
/// removal, after a crash) is one turn. A harness that has not read the log reads it first, since
/// before it the harness cannot know what the log holds.
///
/// The extension cannot bring Topo forward, so a share waits in the app group until the app next
/// comes to the front, which is when this drains. The turn's text is written here, never by the
/// extension: the person's note as they wrote it, then what was shared under a line that says it
/// was shared, so nothing another app handed over reads as the person's own words. An image or a
/// file is put in the guest's home first (`HomeFile`), under `shared/<the share's nonce>/`,
/// and the turn names its path; a share whose file cannot be put there stays for the next drain.
@MainActor
final class ShareInbox {
    let line: any ShareLine
    let store: @MainActor () -> ShareStore?
    let home: @Sendable () -> URL
    /// Puts a share's file in the home (`place`); a suite hands one that lets a sign-out land
    /// while it does.
    let placing: @Sendable (Share, ShareStore, URL) async -> String?

    /// The home's folder shared images and files are kept under.
    nonisolated static let folder = "shared"
    /// What a sheet that was killed left half made is taken away once it is this old.
    static let unfinished: TimeInterval = 60 * 60

    init(line: any ShareLine, store: @escaping @MainActor () -> ShareStore? = { ShareStore.shared() },
         home: @escaping @Sendable () -> URL = { GuestResident.homeDirectory },
         placing: @escaping @Sendable (Share, ShareStore, URL) async -> String? = { await ShareInbox.place($0, from: $1, under: $2) }) {
        self.line = line
        self.store = store
        self.home = home
        self.placing = placing
    }

    /// The login's phase or this phone's role moving: signed in, shares are taken, images and
    /// files where the guest lives; a login ending takes away what was shared and not yet sent.
    /// Only a login ending does: a launch that finds no token takes nothing away. A login beginning
    /// clears the folder before it opens it, so a share a sheet was still writing as the last
    /// login ended is not there for this one; a launch already signed in is no beginning (`SignIn` reads the keychain as it is made, so that
    /// launch's first phase is signed in).
    func follow(from was: SignIn.Phase, to phase: SignIn.Phase, guestIsHere: Bool) {
        if phase == .signedIn {
            if was != .signedIn { store()?.close() }
            try? store()?.open(files: guestIsHere)
        } else if was == .signedIn {
            store()?.close()
        }
    }

    /// Puts every share of this login on the line and sends it. The login is judged again after
    /// every wait: a sign-out shuts the door before it forgets the harness (`SignOut`), so a
    /// drain that waited across one puts nothing on the line after it, and takes back the file it
    /// put in the home. A share made under another login is removed unsent.
    func drain() async {
        guard let store = store(), let door = store.door() else { return }
        store.clearUnfinished(olderThan: Self.unfinished)
        for share in store.shares() where share.login != door.login { store.remove(nonce: share.nonce) }
        guard !store.shares().isEmpty else { return }
        if !line.hasRead {
            guard await line.refresh(), store.door() == door else { return }
        }
        var queued = false
        for share in store.shares() where share.login == door.login {
            var path: String?
            if share.kind == .image || share.kind == .file {
                // Kept while the guest was here and not sent before it left: it waits for it.
                guard door.files else { continue }
                guard let placed = await placing(share, store, home()) else { continue }
                guard store.door() == door else {
                    Self.unplace(share, under: home())
                    break
                }
                path = placed
            }
            guard let text = Self.text(share, path: path), line.willSend(text, nonce: share.nonce) else { continue }
            store.remove(nonce: share.nonce)
            queued = true
        }
        if queued { await line.retry() }
    }

    /// Takes a share's file back out of the home.
    nonisolated static func unplace(_ share: Share, under home: URL) {
        guard let name = share.file else { return }
        HomeFile.remove(named: name, in: [folder, share.nonce.lowercased()], under: home)
    }

    /// The share's image or file in the guest's home, and its path there; nil when it could not
    /// be put there. A file already at the name is the one an earlier drain put there.
    nonisolated static func place(_ share: Share, from store: ShareStore, under home: URL) async -> String? {
        guard let source = store.attachment(of: share), let name = share.file else { return nil }
        let folders = [folder, share.nonce.lowercased()]
        let placed = await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let data = try? Data(contentsOf: source, options: .mappedIfSafe), data.count <= Share.fileLimit else { return false }
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            return (try? HomeFile.create(data, named: name, in: folders, under: home)) != nil
        }.value
        return placed ? ([ClaudeLauncher.home] + folders + [name]).joined(separator: "/") : nil
    }

    /// The turn a share is: the person's note, then what was shared under a line saying so. Nil
    /// for a share that holds nothing to say.
    nonisolated static func text(_ share: Share, path: String?) -> String? {
        let shared: String
        switch share.kind {
        case .text:
            guard let text = share.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            shared = "[Shared with Topo from another app: text]\n\(text)"
        case .link:
            guard let link = share.text?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty else { return nil }
            shared = "[Shared with Topo from another app: a link]\n\(link)"
        case .image, .file:
            guard let path else { return nil }
            let what = share.kind == .image ? "an image" : "a file"
            shared = "[Shared with Topo from another app: \(what), kept at \(path) (\(share.bytes ?? 0) bytes)]"
        }
        let note = share.note.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? shared : "\(note)\n\n\(shared)"
    }
}
