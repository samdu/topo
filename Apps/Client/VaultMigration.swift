#if os(iOS)
import Foundation
import TopoCore

/// Moving the vault's folder from one home to the other.
///
/// One coordinated operation with one commit point. The source is held under a coordinated write
/// from before the first file is read until after the home has moved, so no editor changes it
/// under the copy; every file and the mirror's `.topo/mirror.json` baseline are carried into the
/// destination and read back by digest; and the commit — the write of the home, which is the
/// caller's, and the only thing that says where the vault now is — happens after that and inside
/// the same coordination. Nothing before the commit has changed the source or the old home, so a
/// failure anywhere in it leaves the home where it was and the destination holding whatever
/// partial copy was made, which the next attempt writes over file by file.
///
/// After the commit the source is emptied of what was carried, as cleanup. A removal that will not
/// go is reported and never rolled back: the home has moved, and the old copy standing is
/// something for the person to be told about rather than a reason to put their memory back.
///
/// What is taken away is what this carried, name by name, and then the folders under the source
/// that are left empty — never anything this did not put there. The source folder itself goes only
/// when the caller says it is the app's own and it ends up empty: on the way back the source is a
/// folder in the person's iCloud Drive that they made and picked, with their Obsidian settings in
/// it, and a move is not a reason to take that away.
enum VaultMigration {
    struct Outcome: Sendable {
        var transfer: VaultTransfer.Outcome
        /// Files the cleanup carried and could not take away. Empty is the ordinary end.
        ///
        /// Only those: a name the transfer skipped on purpose — Obsidian's `.obsidian`, a link,
        /// anything hidden that is not the baseline — was never the memory's to move and is not
        /// something left behind. Reported as left behind it would say the old copy is still
        /// there when the memory has entirely gone, and the control offered for it would be a
        /// control that deletes the person's own files.
        var left: [String] = []
        /// Whether the source folder itself is gone.
        var sourceRemoved = false
    }

    /// Carries the vault from `source` to `destination` and commits the home in between.
    ///
    /// `commit` is what makes the move real and is called once, after every file has been
    /// verified: it throws, and the move is off, with the home where it was.
    static func move(from source: URL, to destination: URL, device: DeviceID, at now: Date,
                     removingSourceFolder: Bool,
                     commit: @escaping @Sendable () throws -> Void) async throws -> Outcome {
        try await coordinated(source: source, destination: destination) { source, destination in
            let transfer = try VaultTransfer.copy(from: source, to: destination, device: device, at: now)
            // The commit. Everything above can be done again; nothing above has changed the
            // source or said where the vault is.
            try commit()
            var outcome = Outcome(transfer: transfer)
            (outcome.left, outcome.sourceRemoved) = empty(source, of: carried(transfer),
                                                          removingFolder: removingSourceFolder)
            return outcome
        }
    }

    /// The names a transfer carried, which are the only names a cleanup takes away.
    static func carried(_ transfer: VaultTransfer.Outcome) -> [String] {
        var names = Set(transfer.copied + transfer.identical + transfer.conflicted.keys)
        if transfer.baseline { names.insert(VaultTransfer.baselineName) }
        return names.sorted()
    }

    /// Takes away the names a transfer carried, then the folders that are now empty, then the
    /// source folder itself if it is empty and the caller says it is the app's own. Answers which
    /// of those names are still there.
    ///
    /// The same call the retry makes, so what "Remove the old copy" does is exactly what the move
    /// did and no more: it never takes away a name this did not put there.
    static func empty(_ source: URL, of names: [String],
                      removingFolder: Bool) -> (left: [String], removed: Bool) {
        let disk = FileManager.default
        for relative in names {
            let file = relative.split(separator: "/").reduce(source) { $0.appendingPathComponent(String($1)) }
            try? disk.removeItem(at: file)
        }
        // Deepest first, so a folder emptied by the one below it goes too. `removeItem` on a
        // folder takes everything in it, so the empty ones are asked for by hand.
        let folders = (disk.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey],
                                       options: [])?.compactMap { $0 as? URL } ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.pathComponents.count > $1.pathComponents.count }
        for folder in folders where (try? disk.contentsOfDirectory(atPath: folder.path(percentEncoded: false)))?.isEmpty == true {
            try? disk.removeItem(at: folder)
        }
        // What is still there of what was carried — never what was skipped, which was the
        // person's or nobody's and is not this move's to account for.
        let left = names.filter {
            let file = $0.split(separator: "/").reduce(source) { $0.appendingPathComponent(String($1)) }
            return disk.fileExists(atPath: file.path(percentEncoded: false))
        }.sorted()
        var removed = false
        if left.isEmpty, removingFolder,
           ((try? disk.contentsOfDirectory(atPath: source.path(percentEncoded: false))) ?? []).isEmpty {
            removed = (try? disk.removeItem(at: source)) != nil
        }
        return (left, removed)
    }

    /// The retry behind "Remove the old copy": the same cleanup, coordinated on the folder it
    /// touches, and never a rollback — the home moved at the commit and this is only what the
    /// move could not take away going.
    static func emptyAgain(_ source: URL, of names: [String],
                           removingFolder: Bool) async throws -> (left: [String], removed: Bool) {
        try await coordinatedWrite(source) { source in
            empty(source, of: names, removingFolder: removingFolder)
        }
    }

    private static func coordinatedWrite<T: Sendable>(
        _ url: URL, body: @escaping @Sendable (URL) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            coordinating.async {
                continuation.resume(with: Result {
                    var outcome: Result<T, any Error>?
                    var failure: NSError?
                    NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting,
                                                   error: &failure) { url in
                        outcome = Result { try body(url) }
                    }
                    if let failure { throw failure }
                    guard let outcome else { throw CocoaError(.fileWriteUnknown) }
                    return try outcome.get()
                })
            }
        }
    }

    /// One coordinated write over both folders, taken together, so the source is shut for as long
    /// as the copy, the verification, the commit and the cleanup take.
    ///
    /// `NSFileCoordinator.coordinate` blocks the thread it is called on until every other accessor
    /// of either folder has let go, and the threads a Swift task runs on are a handful the process
    /// shares, so the wait is spent on a queue of this type's own and the caller is suspended for
    /// it — the same reason `VaultMirror` has one.
    private static func coordinated<T: Sendable>(
        source: URL, destination: URL,
        body: @escaping @Sendable (URL, URL) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            coordinating.async {
                continuation.resume(with: Result {
                    var outcome: Result<T, any Error>?
                    var failure: NSError?
                    NSFileCoordinator().coordinate(writingItemAt: source, options: [],
                                                   writingItemAt: destination,
                                                   options: .forMerging, error: &failure) { source, destination in
                        outcome = Result { try body(source, destination) }
                    }
                    if let failure { throw failure }
                    guard let outcome else { throw CocoaError(.fileWriteUnknown) }
                    return try outcome.get()
                })
            }
        }
    }

    private static let coordinating = DispatchQueue(label: "zone.hexagon.topo.vault-migration",
                                                    qos: .userInitiated)
}
#endif
