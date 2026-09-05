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
/// Hidden files are left alone in both directions — Obsidian's own
/// `.obsidian` folder, and this mirror's `.topo/mirror.json`, are local to
/// the machine they are on. So is anything at a path a vault cannot hold,
/// which is reported rather than written.
///
/// Conflict copies are the store's reading of a fork rather than files of
/// their own, so a person's answer to one is expressed against the file it
/// is a copy of: editing a conflict copy writes its text to that file and
/// resolves the fork, and deleting one resolves the fork the other way, in
/// favour of what the file already says.
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

    public let directory: URL
    private let store: MemoryStore
    private let device: DeviceID
    private let disk = FileManager.default
    private var writer: NoteWriter?
    /// What the last sync left on disk: the digest of each file's text, so
    /// an edit made since is told from a file this mirror wrote itself.
    private var synced: [VaultPath: String]?

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

        var vault = try await store.read()
        guard vault.isComplete else {
            throw MemoryError.incompleteVault(missing: vault.missing, unreadable: vault.unreadable)
        }

        var pushes: [(path: VaultPath, text: String, delete: Bool)] = []
        for (path, text) in onDisk {
            guard previous[path] != digest(text) else { continue }  // this mirror wrote it
            let file = vault.files[path]
            if file?.text == text { continue }                       // the store already agrees
            if let file, file.isConflictCopy {
                // An edited copy is an answer to the fork, not a file.
                pushes.append((file.origin, text, false))
            } else {
                pushes.append((path, text, false))
            }
        }
        for (path, _) in previous where onDisk[path] == nil {
            guard let file = vault.files[path] else { continue }
            if file.isConflictCopy {
                // Dropping a copy settles the fork on what the file says.
                if let kept = vault.files[file.origin] {
                    pushes.append((file.origin, kept.text, false))
                } else {
                    pushes.append((file.origin, "", true))
                }
            } else {
                pushes.append((path, "", true))
            }
        }

        if !pushes.isEmpty {
            let writer: NoteWriter
            if let existing = self.writer {
                writer = existing
            } else {
                writer = try await store.writer(for: device)
                self.writer = writer
            }
            // One path at a time and in path order, so a directory holding
            // two answers to the same fork writes them in a stable order.
            for push in pushes.sorted(by: { $0.path < $1.path }) {
                vault = try await store.read()
                guard vault.isComplete else {
                    throw MemoryError.incompleteVault(missing: vault.missing, unreadable: vault.unreadable)
                }
                if push.delete {
                    guard vault.files[push.path] != nil || !vault.heads(of: push.path).isEmpty else { continue }
                    try await writer.delete(push.path, continuing: vault, at: now)
                    report.deleted.append(push.path)
                } else {
                    guard vault.files[push.path]?.text != push.text || vault.isForked(push.path) else { continue }
                    try await writer.write(push.text, to: push.path, continuing: vault, at: now)
                    report.pushed.append(push.path)
                }
            }
            vault = try await store.read()
            guard vault.isComplete else {
                throw MemoryError.incompleteVault(missing: vault.missing, unreadable: vault.unreadable)
            }
        }

        var state: [VaultPath: String] = [:]
        for file in vault.ordered {
            state[file.path] = digest(file.text)
            guard onDisk[file.path] != file.text else { continue }
            let url = url(of: file.path)
            try disk.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.text.utf8).write(to: url, options: .atomic)
            report.written.append(file.path)
        }
        for (path, _) in onDisk where vault.files[path] == nil {
            try disk.removeItem(at: url(of: path))
            report.removed.append(path)
        }

        synced = state
        try save(state)
        report.written.sort()
        report.removed.sort()
        report.pushed.sort()
        report.deleted.sort()
        return report
    }

    private func url(of path: VaultPath) -> URL {
        path.components.reduce(directory) { $0.appendingPathComponent($1) }
    }

    /// Every readable file in the directory, by vault path. A file whose
    /// path a vault cannot hold, or whose bytes are not text, is reported
    /// as skipped and otherwise untouched.
    private func scan() throws -> (files: [VaultPath: String], skipped: [String]) {
        var found: [VaultPath: String] = [:]
        var skipped: [String] = []
        let root = directory.standardizedFileURL.path
        guard let walk = disk.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                          options: [.skipsHiddenFiles]) else {
            return (found, skipped)
        }
        for case let url as URL in walk {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(root + "/") else { continue }
            let relative = String(full.dropFirst(root.count + 1))
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
        return (found, skipped)
    }

    private var stateURL: URL {
        directory.appendingPathComponent(".topo").appendingPathComponent("mirror.json")
    }

    private func loadState() throws -> [VaultPath: String] {
        guard let data = try? Data(contentsOf: stateURL) else { return [:] }
        let stored = try? JSONDecoder().decode([String: String].self, from: data)
        var state: [VaultPath: String] = [:]
        for (name, digest) in stored ?? [:] {
            if let path = VaultPath(name) { state[path] = digest }
        }
        return state
    }

    private func save(_ state: [VaultPath: String]) throws {
        var stored: [String: String] = [:]
        for (path, digest) in state { stored[path.string] = digest }
        let data = try JSONEncoder().encode(stored)
        try disk.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: stateURL, options: .atomic)
    }

    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
