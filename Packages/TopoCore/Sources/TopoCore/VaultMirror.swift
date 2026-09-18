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
/// Cancellation is honoured before the store is written and again before the
/// disk is: a sync outliving what asked for it — a sign-out, most of all —
/// leaves the folder exactly as it found it.
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

        // The folder is shared, and the scan above is only as current as the store read
        // that followed it was quick. Every file about to be written or taken away is
        // read again here; text that is not what the scan saw is somebody's edit, and an
        // edit becomes a revision rather than something to overwrite. A round of that can
        // itself be overtaken, so it is a bounded loop rather than a single look.
        for _ in 0..<4 {
            let late = try lateEdits(onDisk: onDisk, vault: vault)
            guard !late.isEmpty else { break }
            for (path, text) in late { onDisk[path] = text }
            wanted = resolutions(onDisk: onDisk, previous: previous, vault: vault, only: Set(late.keys))
            guard !wanted.isEmpty else { break }
            let push = try await push(wanted, seen: seen, at: now)
            (vault, seen) = (push.vault, push.seen)
            report.pushed += push.pushed
            report.deleted += push.deleted
        }

        // The last thing before the disk is touched. What the store holds is already in
        // it, so a sync abandoned here loses nothing.
        try Task.checkCancellation()

        var state = State()
        for path in vault.knownPaths { state.heads[path] = vault.heads(of: path) }
        // Taking away what has gone comes first: a file the store no longer
        // holds may be standing exactly where a folder is now needed.
        for (path, _) in onDisk.sorted(by: { $0.key < $1.key }) where vault.files[path] == nil {
            try remove(at: url(of: path))
            report.removed.append(path)
        }
        for file in vault.ordered {
            if onDisk[file.path] == file.text {
                state.files[file.path] = digest(file.text)
                continue
            }
            let url = url(of: file.path)
            // A link where a file should be is somebody else's business,
            // and writing to it writes wherever it points — as does a link
            // anywhere above it, which is why the folder this goes in has
            // to resolve back inside the vault before anything is written.
            // Leave it, and leave the path out of the state so the next
            // sync tries again.
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
                || !isInsideVault(url.deletingLastPathComponent()) {
                report.skipped.append(file.path.string)
                continue
            }
            // A folder left where this file goes, emptied by the removals
            // above or by a sync that had it as a folder, is cleared away;
            // one with anything of the person's still in it is not.
            var isFolder: ObjCBool = false
            if disk.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                guard (try? disk.contentsOfDirectory(atPath: url.path))?.isEmpty == true else {
                    report.skipped.append(file.path.string)
                    continue
                }
                try remove(at: url)
            }
            try disk.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try coordinatedWrite(url, options: .forReplacing) { url in
                try Data(file.text.utf8).write(to: url, options: .atomic)
            }
            state.files[file.path] = digest(file.text)
            report.written.append(file.path)
        }

        synced = state
        try save(state)
        // A link both scanned and written to is one thing in the way.
        report.skipped = Array(Set(report.skipped)).sorted()
        report.written.sort()
        report.removed.sort()
        report.pushed.sort()
        report.deleted.sort()
        return report
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

    /// Every file the write-back is about to change, read again: what is not
    /// what the scan saw was written by somebody else while the store was
    /// being read. A file that has gone from disk in that window is left out
    /// — there is nothing of the person's to keep there, and the next sync's
    /// scan is what judges a removal.
    private func lateEdits(onDisk: [VaultPath: String], vault: Vault) throws -> [VaultPath: String] {
        var atRisk: Set<VaultPath> = []
        for (path, _) in onDisk where vault.files[path] == nil { atRisk.insert(path) }
        for file in vault.ordered where onDisk[file.path] != file.text { atRisk.insert(file.path) }
        var late: [VaultPath: String] = [:]
        for path in atRisk {
            guard let text = try currentText(at: url(of: path)), text != onDisk[path] else { continue }
            late[path] = text
        }
        return late
    }

    /// One file as it stands on disk right now, or nil when it is not there,
    /// is a link, or is not text. Coordinated, so a save half-written by
    /// another app is waited out rather than read.
    ///
    /// Only what is really in this folder counts, checked exactly as the scan
    /// checks it: neither the file nor any folder above it may be a link, or
    /// this second look would carry a file from wherever the link points into
    /// the memory — the leak the scan refuses at the front door.
    private func currentText(at url: URL) throws -> String? {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
              isInsideVault(url.deletingLastPathComponent()),
              url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(realRoot + "/") else { return nil }
        return try coordinatedRead(url) { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    private func remove(at url: URL) throws {
        try coordinatedWrite(url, options: .forDeleting) { url in
            try disk.removeItem(at: url)
        }
    }

    /// The folder is shared with every other app that can reach a document
    /// folder, so nothing here reads or writes it uncoordinated: a read waits
    /// out a save in progress rather than seeing half of one, and a write is
    /// announced to whoever has the file open.
    private func coordinatedRead<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        try coordinated(url, reading: true, options: 0, body: body)
    }

    private func coordinatedWrite(_ url: URL, options: NSFileCoordinator.WritingOptions,
                                  _ body: (URL) throws -> Void) throws {
        _ = try coordinated(url, reading: false, options: options.rawValue) { url -> Bool in
            try body(url)
            return true
        }
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
