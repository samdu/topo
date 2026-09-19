#if os(iOS)
import Foundation

/// Asking iCloud Drive for the files it has taken off this device, before the mirror looks at
/// them.
///
/// A folder in iCloud Drive holds files whose bytes are not on the phone: iCloud Drive evicts what
/// has not been opened lately and leaves the name behind. The mirror reads bytes, and a file it
/// cannot read is one it reports as unreadable and acts on in no direction — which is right, and
/// is also a file of the person's memory that never syncs. So every pass over an iCloud Drive home
/// asks for what is not downloaded and waits for it, with a bound, and what has not arrived by
/// then is left for the next pass.
///
/// Only a regular file whose status is `.notDownloaded` is asked for, because that is the one
/// status that says the bytes are not here. A folder in iCloud Drive has a downloading status of
/// its own and is never bytes to wait for. A file with no status at all is not a ubiquitous item —
/// a note just written on this phone, before iCloud has taken it up — and asking for one throws;
/// `.downloaded` is a local copy that is merely out of date, which reads as text either way and
/// which the next pass sees the newer of. Waiting on any of those is a wait that answers nothing
/// about a file that is perfectly readable.
enum VaultDownloads {
    /// How long the files a pass asked for are waited for. A bound, because the wait is a pass of
    /// the mirror not running and the next cue is seconds away.
    static let timeout: Duration = .seconds(20)
    /// How often the statuses are read while waiting.
    static let interval: Duration = .milliseconds(250)

    /// What one warm-up did, for the diagnostics row.
    struct Report: Equatable {
        /// Files that were not downloaded when the pass began.
        var asked: [String] = []
        /// Of those, the ones iCloud Drive had delivered before the bound.
        var arrived: [String] = []
        /// Files iCloud Drive refused to download, and what it said.
        var refused: [String: String] = [:]

        var waiting: [String] { asked.filter { !arrived.contains($0) && refused[$0] == nil }.sorted() }

        var isEmpty: Bool { asked.isEmpty }

        /// What the `memory` row says about it, or nothing when there was nothing to ask for.
        var summary: String? {
            guard !isEmpty else { return nil }
            var parts = ["downloaded \(arrived.count) of \(asked.count)"]
            if !waiting.isEmpty { parts.append("still waiting for \(waiting.count)") }
            if !refused.isEmpty { parts.append("refused \(refused.count)") }
            return parts.joined(separator: ", ")
        }
    }

    /// Every regular file under `folder` whose bytes iCloud Drive does not have on this device,
    /// as paths relative to it.
    ///
    /// The walk is the same shape as the mirror's: hidden names are somebody else's business and
    /// are not descended into, and what is at a name is read from its own resource values rather
    /// than assumed from the walk.
    static func pending(in folder: URL,
                        status: @Sendable (URL) -> URLUbiquitousItemDownloadingStatus? = Self.status) -> [String] {
        var out: [String] = []
        let base = plainPath(folder)
        guard let walk = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []) else { return [] }
        for case let found as URL in walk {
            let name = found.lastPathComponent
            let values = try? found.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if name.hasPrefix(".") {
                if values?.isDirectory == true { walk.skipDescendants() }
                continue
            }
            // A folder is a way down, never bytes to wait for, and anything that is not a plain
            // file is not this folder's file either.
            guard values?.isDirectory != true, values?.isRegularFile == true else { continue }
            guard status(found) == .notDownloaded else { continue }
            let full = plainPath(found)
            guard full.hasPrefix(base + "/") else { continue }
            out.append(String(full.dropFirst(base.count + 1)))
        }
        return out.sorted()
    }

    /// Asks iCloud Drive for everything `pending` found and waits for it, up to the bound.
    static func warm(_ folder: URL, timeout: Duration = Self.timeout,
                     status: @escaping @Sendable (URL) -> URLUbiquitousItemDownloadingStatus? = Self.status,
                     startDownload: @Sendable (URL) throws -> Void = { try FileManager.default.startDownloadingUbiquitousItem(at: $0) },
                     now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
                     sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) async -> Report {
        var report = Report()
        report.asked = pending(in: folder, status: status)
        guard !report.asked.isEmpty else { return report }
        var outstanding: [String: URL] = [:]
        for relative in report.asked {
            let url = relative.split(separator: "/").reduce(folder) { $0.appendingPathComponent(String($1)) }
            do {
                try startDownload(url)
                outstanding[relative] = url
            } catch {
                report.refused[relative] = "\(error)"
            }
        }
        let deadline = now() + timeout
        while !outstanding.isEmpty, now() < deadline {
            // Anything but `.notDownloaded` is bytes the scan can read: `.current`, and
            // `.downloaded`, which is here with a newer copy known elsewhere. Waiting on
            // `.current` alone spends the whole bound on a file that has already landed.
            for (relative, url) in outstanding where status(url) != .notDownloaded {
                report.arrived.append(relative)
                outstanding[relative] = nil
            }
            guard !outstanding.isEmpty else { break }
            await sleep(interval)
        }
        report.arrived.sort()
        return report
    }

    static let status: @Sendable (URL) -> URLUbiquitousItemDownloadingStatus? = { url in
        try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
    }

    private static func plainPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
#endif
