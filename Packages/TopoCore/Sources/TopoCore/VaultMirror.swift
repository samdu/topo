import CryptoKit
import Foundation

/// A directory on disk holding the vault's files, kept in step with the
/// store both ways: what the store gains appears on disk, and what changes
/// on disk becomes a revision.
///
/// The point of it is that the memory is an ordinary folder of markdown.
/// Obsidian opens it as a vault, the hub's Claude reads and edits it as
/// files, and neither knows about CloudKit; a sync is what carries their
/// work to the other devices and brings back what those devices did.
///
/// A local change continues from the revisions the last sync left in this
/// folder, never from whatever the store holds at the moment of the push.
/// The person edited what they could see, so a revision written on another
/// device since then is concurrent with their edit and has to stay that
/// way: naming it as a parent would say this edit replaces it, and it would
/// go without ever having been read. That is what makes a conflict here a
/// copy in the folder rather than something quietly lost.
///
/// Hidden files are left alone in both directions — Obsidian's own
/// `.obsidian` folder, and this mirror's `.topo/mirror.json`, are local to
/// the machine they are on. So is anything at a path a vault cannot hold,
/// which is reported rather than written.
///
/// Conflict copies are the store's reading of a fork rather than files of
/// their own, so a person's answer to one is expressed against the file it
/// is a copy of: editing a conflict copy writes its text to that file and
/// resolves the fork, and deleting one resolves the fork the other way, in
/// favour of what the file already says. A folder holding several answers
/// for one file writes one revision of it, the most particular of them.
///
/// The folder belongs to whoever else can reach it — Files, an editor that
/// opened it in place, the hub's Claude — so every touch of it goes through
/// `NSFileCoordinator`, and a sync that has just spent a network round trip
/// reading the store reads each file it is about to change again before it
/// changes it. Text that is not what the scan saw is an edit made meanwhile:
/// it becomes a revision continuing from the heads this folder has seen, and
/// what the store holds lands beside it as a conflict copy or as the file, by
/// the ordinary rule. Nothing a person wrote is overwritten by a download.
///
/// Cancellation is honoured before every mutation, not at a fence or two: before
/// each revision written to the store, before each file written or taken off disk,
/// and before the state is saved. A sync outliving what asked for it — a sign-out,
/// most of all — stops at the last thing it did rather than finishing the round.
public actor VaultMirror {
    public struct Report: Sendable, Equatable {
        /// Files created or changed on disk from the store.
        public var written: [VaultPath] = []
        /// Files taken off disk because the store no longer has them.
        public var removed: [VaultPath] = []
        /// Local edits and additions written to the store.
        public var pushed: [VaultPath] = []
        /// Local removals written to the store.
        public var deleted: [VaultPath] = []
        /// Things in the directory a vault cannot hold, left where they are.
        public var skipped: [String] = []

        public var isEmpty: Bool {
            written.isEmpty && removed.isEmpty && pushed.isEmpty && deleted.isEmpty
        }
    }

    /// What one sync left behind: the digest of every file it wrote, so an
    /// edit made since is told from a file this mirror put there, and the
    /// heads each path stood at, which is what the next sync's local
    /// changes continue from.
    private struct State: Sendable {
        var files: [VaultPath: String] = [:]
        var heads: [VaultPath: [NoteRef]] = [:]
    }

    /// What the folder is asking for one file to become. The order is what
    /// happens when it holds more than one answer for the same file: text
    /// a person wrote beats text they left alone, the file itself beats a
    /// copy of it, and either beats an answer about whether the file is
    /// there at all.
    private enum Resolution: Comparable {
        case edited(String)         // the file itself was written
        case editedCopy(String)     // a copy of it was written
        case removed                // the file itself was taken away
        case copyRemoved(String?)   // a copy was taken away; keep what the file says

        var rank: Int {
            switch self {
            case .edited: 0
            case .editedCopy: 1
            case .removed: 2
            case .copyRemoved: 3
            }
        }

        static func < (a: Resolution, b: Resolution) -> Bool { a.rank < b.rank }
    }

    public let directory: URL
    private let store: MemoryStore
    private let device: DeviceID
    private let disk = FileManager.default
    private var writer: NoteWriter?
    private var synced: State?

    public init(directory: URL, store: MemoryStore, device: DeviceID) {
        self.directory = directory
        self.store = store
        self.device = device
    }

    /// Pushes what changed on disk, then writes back what the store holds.
    ///
    /// Throws `incompleteVault` rather than act on a read with holes: a
    /// path whose revisions are not all visible could be forked by a write
    /// that never saw them, and a file could be removed from disk that the
    /// store does hold. Sync again once the read is whole.
    @discardableResult
    public func sync(at now: Date = Date()) async throws -> Report {
        // Before the folder is made, because making it is already a change to the person's
        // device: a sync cancelled before it ran — a sign-out between the cue and the pass —
        // leaves a phone with no folder rather than an empty one nothing will fill.
        try Task.checkCancellation()
        try disk.createDirectory(at: directory, withIntermediateDirectories: true)
        var report = Report()
        let (scanned, skipped) = try scan()
        report.skipped = skipped
        let previous = try synced ?? loadState()
        var onDisk = scanned
        // The heads this folder has been shown, which is what a local change continues
        // from. A push of its own moves them on: the revision it just wrote from them
        // is where this folder now stands.
        var seen = previous.heads

        var vault = try await read()
        // Nothing has been written yet, and after a cancellation nothing will be.
        try Task.checkCancellation()
        var wanted = resolutions(onDisk: onDisk, previous: previous, vault: vault)
        if !wanted.isEmpty {
            let push = try await push(wanted, seen: seen, at: now)
            (vault, seen) = (push.vault, push.seen)
            report.pushed += push.pushed
            report.deleted += push.deleted
        }

        // Writing the store back is where somebody else's save is lost, so the check that
        // the folder still holds what the scan saw is made inside the same coordinated
        // write that would replace it, never before it: a save landing between a look and
        // a write is exactly the case, and only the coordinator can hold that window shut.
        // What the write finds instead is somebody's edit — or their deletion — and both
        // are theirs to keep, so the round is spent making a revision of it and the next
        // one writes the store back around it.
        var state = State()
        for round in 0...4 {
            let applied = try applyToDisk(vault: vault, onDisk: onDisk)
            onDisk = applied.onDisk
            state = applied.state
            report.written += applied.written
            report.removed += applied.removed
            report.skipped += applied.skipped
            let late = Set(applied.lateEdits.keys).union(applied.lateRemovals)
            guard round < 4, !late.isEmpty else { break }
            for (path, text) in applied.lateEdits { onDisk[path] = text }
            for path in applied.lateRemovals { onDisk[path] = nil }
            wanted = resolutions(onDisk: onDisk, previous: previous, vault: vault, only: late)
            guard !wanted.isEmpty else { break }
            let push = try await push(wanted, seen: seen, at: now)
            (vault, seen) = (push.vault, push.seen)
            report.pushed += push.pushed
            report.deleted += push.deleted
        }

        synced = state
        try Task.checkCancellation()
        try save(state)
        // A link both scanned and written to is one thing in the way, and a file a round
        // wrote and the round after left alone is one thing written.
        report.skipped = Array(Set(report.skipped)).sorted()
        report.written = Array(Set(report.written)).sorted()
        report.removed = Array(Set(report.removed)).sorted()
        report.pushed = Array(Set(report.pushed)).sorted()
        report.deleted = Array(Set(report.deleted)).sorted()
        return report
    }

    /// One pass over the disk: what the store holds written into the folder, what it no
    /// longer holds taken out, and what somebody else did to the folder meanwhile found
    /// rather than flattened.
    private struct Applied {
        var state = State()
        var onDisk: [VaultPath: String]
        var written: [VaultPath] = []
        var removed: [VaultPath] = []
        var skipped: [String] = []
        /// Text found where the scan's text should have been.
        var lateEdits: [VaultPath: String] = [:]
        /// Files somebody took away while this sync was running.
        var lateRemovals: [VaultPath] = []
    }

    private func applyToDisk(vault: Vault, onDisk startingDisk: [VaultPath: String]) throws -> Applied {
        var out = Applied(onDisk: startingDisk)
        for path in vault.knownPaths { out.state.heads[path] = vault.heads(of: path) }

        // Taking away what has gone comes first: a file the store no longer
        // holds may be standing exactly where a folder is now needed.
        for (path, _) in startingDisk.sorted(by: { $0.key < $1.key }) where vault.files[path] == nil {
            try Task.checkCancellation()
            let url = url(of: path)
            // A link anywhere above this file would carry the removal out of the vault, and
            // no open can refuse that for us. A link *at* the path is refused by the read
            // inside the coordination, which is the only place it can be refused honestly.
            guard isInsideVault(url.deletingLastPathComponent()) else {
                out.skipped.append(path.string)
                continue
            }
            switch try coordinatedRemove(url, expecting: out.onDisk[path]) {
            case .done:
                out.onDisk[path] = nil
                out.removed.append(path)
            case .gone:
                out.onDisk[path] = nil
            case .different(let text):
                out.lateEdits[path] = text
            case .blocked:
                out.skipped.append(path.string)
            }
        }

        for file in vault.ordered {
            if out.onDisk[file.path] == file.text {
                out.state.files[file.path] = digest(file.text)
                continue
            }
            let url = url(of: file.path)
            // A link anywhere above this file writes wherever it points, and the folder it
            // goes in has to resolve back inside the vault before anything is written. A
            // link standing at the path itself is refused by the read inside the coordinated
            // write rather than here: a look taken now is a look at a path the write opens
            // again, and what stands there can change in between. Either way the path is
            // left out of the state, so the next sync looks again.
            if !isInsideVault(url.deletingLastPathComponent()) {
                out.skipped.append(file.path.string)
                continue
            }
            // A folder left where this file goes, emptied by the removals
            // above or by a sync that had it as a folder, is cleared away;
            // one with anything of the person's still in it is not.
            var isFolder: ObjCBool = false
            if disk.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                guard (try? disk.contentsOfDirectory(atPath: url.path))?.isEmpty == true else {
                    out.skipped.append(file.path.string)
                    continue
                }
                try Task.checkCancellation()
                try removeItem(at: url)
            }
            try Task.checkCancellation()
            try disk.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch try coordinatedReplace(url, expecting: out.onDisk[file.path], with: file.text) {
            case .done:
                out.onDisk[file.path] = file.text
                out.state.files[file.path] = digest(file.text)
                out.written.append(file.path)
            case .gone:
                // Nothing was there and nothing is: the write was refused by the guard
                // above only in the cases it names, so this is somebody's deletion.
                out.onDisk[file.path] = nil
                out.lateRemovals.append(file.path)
            case .different(let text):
                out.onDisk[file.path] = text
                out.lateEdits[file.path] = text
            case .blocked:
                // A link, or bytes nobody can read as text, standing where this file goes.
                // Somebody else's business, left alone and left out of the state.
                out.skipped.append(file.path.string)
            }
        }
        return out
    }

    /// What a coordinated mutation found where the scan had left something.
    private enum DiskOutcome {
        /// The folder held what the scan saw, so the mutation was made.
        case done
        /// The file is not there at all.
        case gone
        /// Somebody else's text is there.
        case different(String)
        /// Something that is not this vault's file to act on: a link, or bytes that are
        /// not text. Left exactly as it is, and left out of the state, so the next sync
        /// looks again.
        case blocked
    }

    /// Replaces a file with what the store holds — but only if the folder still holds what
    /// the scan saw. The comparison is made inside the coordinated write, so an editor's
    /// save either lands before this block and is found by it, or waits behind it and is
    /// what the next sync reads. Cancellation is judged in there too, next to the write
    /// itself: the wait for the coordinator is unbounded, and a sign-out during it is the
    /// case the check exists for.
    ///
    /// Everything in the block is done through a descriptor for the folder the file goes
    /// in, opened with no link resolved anywhere under the vault, so the comparison, the
    /// write and the file it lands as are all the same folder — the one that stood there
    /// when the block opened it, not whatever a path lookup would find each time.
    private func coordinatedReplace(_ url: URL, expecting: String?, with text: String) throws -> DiskOutcome {
        try coordinated(url, reading: false, options: NSFileCoordinator.WritingOptions.forReplacing.rawValue) { url in
            guard let folder = self.openFolder(of: url) else { return DiskOutcome.blocked }
            defer { close(folder) }
            let name = url.lastPathComponent
            switch self.reading(name, in: folder) {
            case .blocked:
                return DiskOutcome.blocked
            case .missing where expecting != nil:
                return DiskOutcome.gone
            case .missing:
                break
            case .text(let current) where current != expecting:
                return DiskOutcome.different(current)
            case .text:
                break
            }
            // Inside the coordination, with the bytes about to go down: waiting for another
            // app's access can take as long as that app likes, and a sync abandoned during
            // that wait has no business writing when its turn comes.
            try Task.checkCancellation()
            guard self.place(text, as: name, in: folder) else { return DiskOutcome.blocked }
            return DiskOutcome.done
        }
    }

    /// Takes a file away, on the same terms: what is there has to be what the scan saw,
    /// and the name is taken out of the folder this block opened rather than off a path.
    private func coordinatedRemove(_ url: URL, expecting: String?) throws -> DiskOutcome {
        try coordinated(url, reading: false, options: NSFileCoordinator.WritingOptions.forDeleting.rawValue) { url in
            guard let folder = self.openFolder(of: url) else { return DiskOutcome.blocked }
            defer { close(folder) }
            let name = url.lastPathComponent
            switch self.reading(name, in: folder) {
            case .blocked: return DiskOutcome.blocked
            case .missing: return DiskOutcome.gone
            case .text(let current) where current != expecting: return DiskOutcome.different(current)
            case .text: break
            }
            try Task.checkCancellation()
            guard unlinkat(folder, name, 0) == 0 else { return DiskOutcome.blocked }
            return DiskOutcome.done
        }
    }

    /// A descriptor for the folder a file goes in, opened from the vault root with
    /// `O_NOFOLLOW_ANY`, which refuses a link at any component of the way down — not only
    /// at the last one. A folder swapped for a link above the file is the way out of the
    /// vault that an open of the file alone cannot refuse, and a path checked before the
    /// coordination is a path looked up again by every call after it; a descriptor is the
    /// folder itself, so what the block compares, writes and lands in cannot change under
    /// it. The root is opened by its own path — the way to it is the app's, and on a Mac
    /// it runs through links of the system's own — but never through a link standing where
    /// the vault goes. `nil` is a way down that is not the vault's, and the caller leaves
    /// the path alone.
    private func openFolder(of url: URL) -> Int32? {
        let root = open(directory.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { return nil }
        guard let relative = wayDown(to: url.deletingLastPathComponent()) else {
            close(root)
            return nil
        }
        guard !relative.isEmpty else { return root }
        let folder = openat(root, relative, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY)
        close(root)
        return folder >= 0 ? folder : nil
    }

    /// The way from the vault root down to a folder, as the names to open one after another,
    /// or `nil` for a folder that is not under the root at all. The names are taken as they
    /// are written, never as they resolve, since resolving is exactly what the open below
    /// refuses to do; only when a path does not read as the vault's at all are both resolved
    /// and compared, because the coordinator can hand the same folder back under another
    /// name — `/private/var` for `/var` — and that is not a link anybody put there.
    private func wayDown(to folder: URL) -> String? {
        func under(_ inside: String, _ root: String) -> String? {
            if inside == root { return "" }
            guard inside.hasPrefix(root + "/") else { return nil }
            return String(inside.dropFirst(root.count + 1))
        }
        if let plain = under(plainPath(folder), plainPath(directory)) { return plain }
        return under(plainPath(folder.resolvingSymlinksInPath()),
                     plainPath(directory.resolvingSymlinksInPath()))
    }

    /// A URL's path with nothing dressing it up: no percent escapes, no trailing slash a
    /// directory URL carries, so one path is a prefix of another exactly when its folder
    /// holds the other.
    private func plainPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The text as a file of that name in that folder, landed the way an editor's save is:
    /// written whole beside it and renamed over it, so nobody ever reads half of it. Both
    /// steps are made through the folder's descriptor, so no part of the way to the file is
    /// resolved again at the moment it is written.
    private func place(_ text: String, as name: String, in folder: Int32) -> Bool {
        let temporary = ".topo-writing-\(UUID().uuidString)"
        let descriptor = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return false }
        var bytes = Array(text.utf8)
        var written = 0
        var wrote = true
        while written < bytes.count && wrote {
            let count = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return write(descriptor, base.advanced(by: written), buffer.count - written)
            }
            if count > 0 { written += count } else { wrote = false }
        }
        if wrote { wrote = fsync(descriptor) == 0 }
        close(descriptor)
        guard wrote, renameat(folder, temporary, folder, name) == 0 else {
            _ = unlinkat(folder, temporary, 0)
            return false
        }
        return true
    }

    /// What is at a path right now.
    private enum Reading {
        case text(String)
        case missing
        /// A link, or bytes that are not text.
        case blocked
    }

    /// A file's text as it stands, read inside a coordination this actor already holds —
    /// which is why it coordinates nothing of its own: a second coordination of the same
    /// item from inside the first is a deadlock.
    ///
    /// Opened from the folder's own descriptor with `O_NOFOLLOW`, and that is the whole
    /// point of it: the guard the scan makes is made again here, in the same breath as
    /// opening the file, and the way down to it was refused a link of its own when the
    /// folder was opened. A link swapped in where the scan saw a file is refused by this
    /// open, so a file from wherever it points can never be read as this folder's and
    /// written into the memory — which a check made before the coordination, on a path
    /// every call after it looks up again, cannot promise.
    private func reading(_ name: String, in folder: Int32) -> Reading {
        let descriptor = openat(folder, name, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            // ELOOP is the link; ENOENT and ENOTDIR are nothing there. Anything else — no
            // permission, a device that has gone — is not this folder's file either.
            return errno == ENOENT || errno == ENOTDIR ? .missing : .blocked
        }
        defer { close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.readToEnd() else { return .blocked }
        guard let text = String(data: data, encoding: .utf8) else { return .blocked }
        return .text(text)
    }

    /// What the folder is asking the store for, by path: an edit, an answer
    /// to a fork, or a removal. `only`, when given, keeps it to those paths,
    /// which is what a revalidation round asks about.
    private func resolutions(onDisk: [VaultPath: String], previous: State, vault: Vault,
                             only: Set<VaultPath>? = nil) -> [VaultPath: Resolution] {
        var wanted: [VaultPath: Resolution] = [:]
        // The filter is on the file that changed, not on the path a change is proposed
        // for: an edited conflict copy is an answer about the file it is a copy of.
        func propose(_ path: VaultPath, _ resolution: Resolution) {
            if let standing = wanted[path], standing <= resolution { return }
            wanted[path] = resolution
        }

        for (path, text) in onDisk.sorted(by: { $0.key < $1.key }) {
            if let only, !only.contains(path) { continue }
            guard previous.files[path] != digest(text) else { continue }  // this mirror wrote it
            let file = vault.files[path]
            if file?.text == text { continue }                            // the store already says this
            // Only a copy this folder was actually given is an answer to a
            // fork; a file the person made that happens to sit where one
            // would go is a file, and becomes a revision of its own.
            if let file, file.isConflictCopy, previous.files[path] != nil {
                propose(file.origin, .editedCopy(text))
            } else {
                propose(path, .edited(text))
            }
        }
        for path in previous.files.keys.sorted() where onDisk[path] == nil {
            if let only, !only.contains(path) { continue }
            guard let file = vault.files[path] else { continue }
            if file.isConflictCopy {
                propose(file.origin, .copyRemoved(vault.files[file.origin]?.text))
            } else {
                propose(path, .removed)
            }
        }
        return wanted
    }

    /// What one round of pushing left: the store as it stands after it, the
    /// heads this folder has now seen, and what was written.
    private struct Push {
        var vault: Vault
        var seen: [VaultPath: [NoteRef]]
        var pushed: [VaultPath] = []
        var deleted: [VaultPath] = []
    }

    private func push(_ wanted: [VaultPath: Resolution], seen: [VaultPath: [NoteRef]],
                      at now: Date) async throws -> Push {
        let writer = try await noteWriter()
        var vault = try await read()
        var out = Push(vault: vault, seen: seen)
        for path in wanted.keys.sorted() {
            // The heads this folder was shown, not the heads the store holds
            // now: anything written elsewhere since is concurrent with what
            // the person did here.
            let parents = out.seen[path] ?? []
            vault = try await read()
            // Before each write of its own, not once for the lot: a sync abandoned
            // between two revisions writes only the ones it had already written.
            try Task.checkCancellation()
            switch wanted[path]! {
            case .edited(let text), .editedCopy(let text), .copyRemoved(.some(let text)):
                // A revision that says what the store already says, from
                // where it already is, and settles no fork, is nothing.
                if vault.files[path]?.text == text, !vault.isForked(path),
                   Set(parents) == Set(vault.heads(of: path)) { continue }
                let note = try await writer.write(text, to: path, after: parents, continuing: vault, at: now)
                out.seen[path] = [note.ref]
                out.pushed.append(path)
            case .removed, .copyRemoved(.none):
                guard !vault.heads(of: path).isEmpty else { continue }
                let note = try await writer.delete(path, after: parents, continuing: vault, at: now)
                out.seen[path] = [note.ref]
                out.deleted.append(path)
            }
        }
        out.vault = try await read()
        return out
    }

    /// A folder standing where a file has to go, taken away under coordination like
    /// anything else in the folder.
    private func removeItem(at url: URL) throws {
        _ = try coordinated(url, reading: false,
                            options: NSFileCoordinator.WritingOptions.forDeleting.rawValue) { url -> Bool in
            try disk.removeItem(at: url)
            return true
        }
    }

    /// The folder is shared with every other app that can reach a document
    /// folder, so nothing here reads or writes it uncoordinated: a read waits
    /// out a save in progress rather than seeing half of one, and a write is
    /// announced to whoever has the file open.
    private func coordinatedRead<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        try coordinated(url, reading: true, options: 0, body: body)
    }

    private func coordinated<T>(_ url: URL, reading: Bool, options: UInt, body: (URL) throws -> T) throws -> T {
        var outcome: Result<T, any Error>?
        var failure: NSError?
        let coordinator = NSFileCoordinator()
        if reading {
            coordinator.coordinate(readingItemAt: url, options: NSFileCoordinator.ReadingOptions(rawValue: options),
                                   error: &failure) { url in
                outcome = Result { try body(url) }
            }
        } else {
            coordinator.coordinate(writingItemAt: url, options: NSFileCoordinator.WritingOptions(rawValue: options),
                                   error: &failure) { url in
                outcome = Result { try body(url) }
            }
        }
        if let failure { throw failure }
        guard let outcome else { throw CocoaError(.fileReadUnknown) }
        return try outcome.get()
    }

    private func read() async throws -> Vault {
        let vault = try await store.read()
        guard vault.isComplete else {
            throw MemoryError.incompleteVault(missing: vault.missing, unreadable: vault.unreadable)
        }
        return vault
    }

    private func noteWriter() async throws -> NoteWriter {
        if let writer { return writer }
        let made = try await store.writer(for: device)
        writer = made
        return made
    }

    private func url(of path: VaultPath) -> URL {
        path.components.reduce(directory) { $0.appendingPathComponent($1) }
    }

    /// The vault root with every link in it followed: what a path has to
    /// still be under to be the vault's.
    private var realRoot: String {
        directory.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// True when a folder, following every link on the way to it, is the
    /// vault root or inside it. A folder that does not exist yet resolves
    /// as far as it does exist, which is the part that could be a link.
    private func isInsideVault(_ folder: URL) -> Bool {
        let resolved = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let root = realRoot
        return resolved == root || resolved.hasPrefix(root + "/")
    }

    /// Every readable file in the directory, by vault path. A file whose
    /// path a vault cannot hold, or whose bytes are not text, is reported
    /// as skipped and otherwise untouched.
    ///
    /// So is a symbolic link, and that one is not a nicety: a link inside
    /// the vault can point anywhere the app can read, and following one
    /// would copy a file the person never put in their memory into
    /// CloudKit. Only what is really in this folder is the vault's, which
    /// is checked twice — the link itself is refused, and every file's
    /// resolved path has to still be under the vault root.
    private func scan() throws -> (files: [VaultPath: String], skipped: [String]) {
        try coordinatedRead(directory) { _ in try walkTree() }
    }

    private func walkTree() throws -> (files: [VaultPath: String], skipped: [String]) {
        var found: [VaultPath: String] = [:]
        var skipped: [String] = []
        let root = directory.standardizedFileURL.path
        let realRoot = self.realRoot
        guard let walk = disk.enumerator(at: directory,
                                         includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                         options: [.skipsHiddenFiles]) else {
            return (found, skipped)
        }
        for case let url as URL in walk {
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(root + "/") else { continue }
            let relative = String(full.dropFirst(root.count + 1))
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                skipped.append(relative)
                continue
            }
            guard values.isRegularFile == true else { continue }
            guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(realRoot + "/") else {
                skipped.append(relative)
                continue
            }
            guard let path = VaultPath(relative) else {
                skipped.append(relative)
                continue
            }
            guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
                skipped.append(relative)
                continue
            }
            found[path] = text
        }
        skipped.sort()
        return (found, skipped)
    }

    private var stateURL: URL {
        directory.appendingPathComponent(".topo").appendingPathComponent("mirror.json")
    }

    /// The shape on disk. A state this cannot read is an empty one, which
    /// costs a conflict copy for anything edited since rather than an edit.
    private struct StoredState: Codable {
        var version: Int
        var files: [String: String]
        var heads: [String: [String]]
    }

    private func loadState() throws -> State {
        guard let data = try? Data(contentsOf: stateURL),
              let stored = try? JSONDecoder().decode(StoredState.self, from: data),
              stored.version == 1 else { return State() }
        var state = State()
        for (name, digest) in stored.files {
            if let path = VaultPath(name) { state.files[path] = digest }
        }
        for (name, refs) in stored.heads {
            if let path = VaultPath(name) { state.heads[path] = refs.compactMap(NoteRef.init(parsing:)) }
        }
        return state
    }

    private func save(_ state: State) throws {
        var stored = StoredState(version: 1, files: [:], heads: [:])
        for (path, digest) in state.files { stored.files[path.string] = digest }
        for (path, heads) in state.heads { stored.heads[path.string] = heads.map(\.description) }
        let data = try JSONEncoder().encode(stored)
        try disk.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: stateURL, options: .atomic)
    }

    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
