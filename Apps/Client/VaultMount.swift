#if os(iOS)
import Foundation

/// The memory's folder as the guest reaches it: mounted at `ClaudeLauncher.vault` and linked from
/// the home as `memory`, so an edit Claude Code makes there is an edit of the folder the mirror
/// keeps, and a revision on its next pass.
///
/// The home can change under a live process — a move, a sign-out and a sign-in, a pick after a
/// lost home — and a folder can be taken away and made again at the same path, which the mount
/// (a descriptor on the directory it was made from) would never see. So the mount is not made once:
/// `reconcile` is asked at every launch of the resident and before every turn, and compares the
/// folder by its identity on disk, not its path. What it does to the guest and to the grant goes
/// through `Seam`, so the rule is held by a test with no guest in it.
@MainActor
final class VaultMount {
    /// A folder on disk, as the file system names it: a folder removed and made again at the same
    /// path is another folder.
    struct Identity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    /// What is mounted now.
    struct Standing: Equatable {
        let folder: URL
        /// Nil once the mount is known to be stale: the next reconcile takes it away first.
        var identity: Identity?
        /// The URL the grant is on, whose access the mount holds; nil for the app's own folder.
        var scope: URL?
    }

    /// What the mount does to the guest and to the grant.
    struct Seam {
        var mount: @MainActor (URL) throws -> Void
        var unmount: @MainActor () throws -> Void
        /// The home's `memory` link to the mount point.
        var link: @MainActor () throws -> Void
        var startAccess: @MainActor (URL) -> Bool
        var stopAccess: @MainActor (URL) -> Void
        var identity: @MainActor (URL) -> Identity?
        var makeFolder: @MainActor (URL) throws -> Void
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        /// The mount standing could not be taken away, so the guest would be told a folder it no
        /// longer reaches.
        case busy(String)
        /// The home's folder could not be mounted.
        case mount(String)

        var description: String {
            switch self {
            case .busy(let why): "the memory's folder moved and the guest still holds the old one: \(why)"
            case .mount(let why): "the memory's folder could not be mounted in the guest: \(why)"
            }
        }
    }

    private let seam: Seam
    private(set) var standing: Standing?

    init(seam: Seam) {
        self.seam = seam
    }

    /// Brings the mount into line with `home`, and answers whether the memory is mounted. `local`
    /// is the app's own folder (`Memory.localDirectory`), made when it is not there yet, as the
    /// mirror makes it; a lost home, or an iCloud Drive folder that is not there, mounts nothing.
    /// Throws when the standing mount cannot be taken away or the new one cannot be made; nothing
    /// is then mounted that the guest could take for the memory.
    func reconcile(home: Memory.Home, local: URL) throws -> Bool {
        let target: URL?
        let scope: URL?
        switch home {
        case .local:
            try? seam.makeFolder(local)
            target = local
            scope = nil
        case .iCloudDrive(let picked, let folder):
            target = folder
            scope = picked
        case .lost:
            target = nil
            scope = nil
        }

        if let standing, let target, standing.folder == target, let identity = standing.identity,
           seam.identity(target) == identity {
            try? seam.link()
            return true
        }
        try takeAway()
        guard let target else { return false }

        if let scope, !seam.startAccess(scope) {
            return false
        }
        guard let identity = seam.identity(target) else {
            if let scope { seam.stopAccess(scope) }
            return false
        }
        do {
            try seam.mount(target)
        } catch {
            if let scope { seam.stopAccess(scope) }
            throw Failure.mount("\(error)")
        }
        standing = Standing(folder: target, identity: identity, scope: scope)
        do {
            try seam.link()
        } catch {
            // The mount stands; the mind is told the path through the link, so a link that could
            // not be made is a memory it cannot find, and the next reconcile makes it again.
            throw Failure.mount("the home's memory link: \(error)")
        }
        return true
    }

    /// Sign-out: after the resident has been ended, the mount goes and then the grant it held. A
    /// mount still held (a teardown that did not confirm) is left marked stale, so the next
    /// reconcile takes it away before anything else; the grant goes either way.
    func forget() {
        guard var standing else { return }
        do {
            try seam.unmount()
            self.standing = nil
        } catch {
            standing.identity = nil
            if let scope = standing.scope { seam.stopAccess(scope) }
            standing.scope = nil
            self.standing = standing
            return
        }
        if let scope = standing.scope { seam.stopAccess(scope) }
    }

    private func takeAway() throws {
        guard let standing else { return }
        do {
            try seam.unmount()
        } catch {
            throw Failure.busy("\(error)")
        }
        self.standing = nil
        if let scope = standing.scope { seam.stopAccess(scope) }
    }
}

extension VaultMount.Identity {
    /// The folder's identity on disk, or nil when there is nothing there to mount.
    static func of(_ url: URL) -> VaultMount.Identity? {
        var info = stat()
        let found = url.withUnsafeFileSystemRepresentation { path in
            path.map { stat($0, &info) == 0 } ?? false
        }
        guard found, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return VaultMount.Identity(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))
    }
}
#endif
