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
        let (onDisk, skipped) = try scan()
        report.skipped = skipped
        let previous = try synced ?? loadState()

        var vault = try await read()
        var wanted: [VaultPath: Resolution] = [:]
        func propose(_ path: VaultPath, _ resolution: Resolution) {
            if let standing = wanted[path], standing <= resolution { return }
            wanted[path] = resolution
        }

        for (path, text) in onDisk.sorted(by: { $0.key < $1.key }) {
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
            guard let file = vault.files[path] else { continue }
            if file.isConflictCopy {
                propose(file.origin, .copyRemoved(vault.files[file.origin]?.text))
            } else {
                propose(path, .removed)
            }
        }

        if !wanted.isEmpty {
            let writer = try await noteWriter()
            for path in wanted.keys.sorted() {
                // The heads this folder was last shown, not the heads the
                // store holds now: anything written elsewhere since is
                // concurrent with what the person did here.
                let parents = previous.heads[path] ?? []
                vault = try await read()
                switch wanted[path]! {
                case .edited(let text), .editedCopy(let text), .copyRemoved(.some(let text)):
                    // A revision that says what the store already says, from
                    // where it already is, and settles no fork, is nothing.
                    if vault.files[path]?.text == text, !vault.isForked(path),
                       Set(parents) == Set(vault.heads(of: path)) { continue }
                    try await writer.write(text, to: path, after: parents, continuing: vault, at: now)
                    report.pushed.append(path)
                case .removed, .copyRemoved(.none):
                    guard !vault.heads(of: path).isEmpty else { continue }
                    try await writer.delete(path, after: parents, continuing: vault, at: now)
                    report.deleted.append(path)
                }
            }
            vault = try await read()
        }

        var state = State()
        for path in vault.knownPaths { state.heads[path] = vault.heads(of: path) }
        // Taking away what has gone comes first: a file the store no longer
        // holds may be standing exactly where a folder is now needed.
        for (path, _) in onDisk.sorted(by: { $0.key < $1.key }) where vault.files[path] == nil {
            try disk.removeItem(at: url(of: path))
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
                try disk.removeItem(at: url)
            }
            try disk.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.text.utf8).write(to: url, options: .atomic)
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
