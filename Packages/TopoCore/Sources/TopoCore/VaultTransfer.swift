import CryptoKit
import Foundation

/// What a conflict copy is called. One rule, in one place, because two things derive the name:
/// the vault, reading a fork in the store, and a transfer, finding a file already standing where
/// one it is carrying goes.
///
/// `Meeting notes (Conflicted copy hub 202609051930).md`, beside the file it is a copy of: what
/// Obsidian Sync names one, so a vault full of them reads the way its own do. The stamp is UTC,
/// since every device derives this name and they agree on no other clock.
///
/// A name already in use is somebody's file, and a copy never takes a name off a file that is
/// really there, so it keeps looking: `discriminator` first when the caller has one that is
/// stable — a revision's sequence number — and then a count.
public enum ConflictCopy {
    public static func path(of origin: VaultPath, device: DeviceID, at date: Date,
                            discriminator: String = "",
                            avoiding taken: some Collection<VaultPath>) -> VaultPath {
        // A name differing only in case is the same name on the ordinary Mac disk, so it counts
        // as taken.
        let held = Set(taken.map { $0.string.lowercased() })
        func free(_ path: VaultPath) -> Bool { !held.contains(path.string.lowercased()) }
        let (stem, ext) = origin.stemAndExtension
        let name = "\(stem) (Conflicted copy \(device.rawValue) \(stamp(date))"
        var candidate = origin.sibling(named: name + ")" + ext)
        if free(candidate) { return candidate }
        let tail = discriminator.isEmpty ? "" : " " + discriminator
        candidate = origin.sibling(named: "\(name)\(tail))\(ext)")
        var count = 2
        while !free(candidate) {
            candidate = origin.sibling(named: "\(name)\(tail) \(count))\(ext)")
            count += 1
        }
        return candidate
    }

    static func stamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d%02d%02d%02d%02d", parts.year ?? 0, parts.month ?? 0,
                      parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// Carrying the vault's files from one folder to another, and saying whether every one of them
/// arrived.
///
/// This is the middle of the move and none of its edges: the coordination, the security scope and
/// the commit are the caller's, and this runs inside them, over the two folders it is handed. It
/// copies and verifies; it removes nothing. So a transfer that throws has changed the destination
/// and nothing else, which is what lets the caller leave the home where it was and try again.
///
/// The mirror's baseline travels with the files. `.topo/mirror.json` is what the folder has been
/// shown, so a move that left it behind would make every file in the new folder read as a local
/// edit and re-parent the lot; carried, an edit made on another device while the move ran is still
/// concurrent and a deletion the folder knew is still known.
///
/// A file already in the destination is the person's and is kept: an identical one is nothing to
/// do, and a different one keeps its name while the file being carried lands beside it under a
/// conflict copy's name. Nothing in the destination is overwritten, except the baseline, which
/// describes the files being carried and not the ones that were there.
public enum VaultTransfer {
    /// What a transfer did, as paths relative to the destination.
    public struct Outcome: Sendable, Equatable {
        /// Files written at the path they had in the source.
        public var copied: [String] = []
        /// Files that landed under a conflict copy's name, because the destination already held
        /// a different file at theirs: the source's path and the name it took.
        public var conflicted: [String: String] = [:]
        /// Files the destination already held, byte for byte. Nothing was written for these.
        public var identical: [String] = []
        /// Names in the source this did not carry: a link, a folder that is not on the way to a
        /// file, anything hidden that is not the baseline, a path a vault cannot hold.
        public var skipped: [String] = []
        /// Whether `.topo/mirror.json` was carried. False when the source had none.
        public var baseline = false
    }

    /// Why a transfer stopped. Each one leaves the destination holding whatever had already been
    /// written and the source untouched.
    public enum Failure: Error, Equatable {
        /// A file in the source could not be read.
        case unreadable(String)
        /// A file could not be written into the destination.
        case unwritable(String)
        /// A file was written and read back as something else. The one failure that is not about
        /// permission or space: it says the bytes did not arrive, which is the whole reason the
        /// commit waits for this.
        case unverified(String)
    }

    /// The baseline, which is carried and is not a vault path.
    public static let baselineName = ".topo/mirror.json"

    /// Copies every file of the vault from `source` into `destination` and reads each one back.
    /// Throws at the first file that cannot be read, written or verified.
    public static func copy(from source: URL, to destination: URL, device: DeviceID,
                            at now: Date) throws -> Outcome {
        var outcome = Outcome()
        let disk = FileManager.default
        try disk.createDirectory(at: destination, withIntermediateDirectories: true)

        // What the destination already holds, so a name in use is known before anything is
        // written and a second conflict copy does not take the first one's name.
        var taken = Set(vaultPaths(in: destination))

        let found = entries(in: source)
        outcome.skipped = found.skipped
        for relative in found.files {
            let from = url(of: relative, under: source)
            guard let data = disk.contents(atPath: from.path(percentEncoded: false)) else {
                throw Failure.unreadable(relative)
            }
            if relative == baselineName {
                try place(data, at: baselineName, under: destination)
                outcome.baseline = true
                continue
            }
            guard let path = VaultPath(relative) else {
                outcome.skipped.append(relative)
                continue
            }
            var landing = path
            let standing = url(of: relative, under: destination)
            if let there = disk.contents(atPath: standing.path(percentEncoded: false)) {
                if there == data {
                    outcome.identical.append(relative)
                    continue
                }
                landing = ConflictCopy.path(of: path, device: device, at: now, avoiding: taken)
                outcome.conflicted[relative] = landing.string
            }
            taken.insert(landing)
            try place(data, at: landing.string, under: destination)
            if landing == path { outcome.copied.append(relative) }
        }
        outcome.skipped.sort()
        outcome.copied.sort()
        outcome.identical.sort()
        return outcome
    }

    /// Writes one file and reads it back, so the bytes that are there are the bytes that were
    /// meant. `Data.write` reports what the file system accepted, which is not the same as what a
    /// later read of an iCloud Drive folder returns.
    private static func place(_ data: Data, at relative: String, under root: URL) throws {
        let file = url(of: relative, under: root)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            throw Failure.unwritable(relative)
        }
        guard let back = FileManager.default.contents(atPath: file.path(percentEncoded: false)),
              digest(back) == digest(data) else {
            throw Failure.unverified(relative)
        }
    }

    /// What one folder holds: the files to carry, and the names left alone.
    ///
    /// Only a regular file is carried. A symbolic link is refused rather than followed — one
    /// inside a vault can point anywhere the app can read, and copying through it would carry a
    /// file the person never put in their memory into the folder their memory now lives in — and
    /// so is anything else that is not a plain file. A hidden name is somebody else's business,
    /// Obsidian's `.obsidian` most of all, and the one exception is this mirror's own baseline.
    static func entries(in root: URL) -> (files: [String], skipped: [String]) {
        var files: [String] = []
        var skipped: [String] = []
        let base = plainPath(root)
        guard let walk = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []) else { return ([], []) }
        for case let found as URL in walk {
            let full = plainPath(found)
            guard full.hasPrefix(base + "/") else { continue }
            let relative = String(full.dropFirst(base.count + 1))
            let values = try? found.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey,
                                                             .isSymbolicLinkKey])
            let name = found.lastPathComponent
            if name.hasPrefix(".") {
                if values?.isDirectory == true, name != ".topo" { walk.skipDescendants() }
                if relative != baselineName, values?.isDirectory != true { skipped.append(relative) }
                continue
            }
            if values?.isDirectory == true { continue }
            // Not a folder and not a plain file: a link, a socket, a device. The walk said where
            // to look; what is there is the resource values' to say.
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                skipped.append(relative)
                continue
            }
            files.append(relative)
        }
        return (files.sorted(), skipped)
    }

    /// Every vault path the folder already holds, which is what a conflict copy avoids.
    static func vaultPaths(in root: URL) -> [VaultPath] {
        entries(in: root).files.compactMap(VaultPath.init)
    }

    /// A URL's path with nothing dressing it up: no percent escapes, no trailing slash a
    /// directory URL carries, so one path is a prefix of another exactly when its folder holds
    /// the other.
    private static func plainPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func url(of relative: String, under root: URL) -> URL {
        relative.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
