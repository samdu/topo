import Foundation
import TopoUserland

/// The bytes of an image a reply names, read as the guest reads them.
///
/// A reply names a picture as Claude Code would: by a path in the guest, absolute (`/tmp/x.png`,
/// `/home/topo/x.png`) or from its home, and through whatever mounts and links the guest has. So
/// the guest is asked (`Guest.contents(ofFile:from:limit:)`), and the app opens nothing of its
/// own: what can be read is exactly what a program in the guest can read, a file in the memory
/// through the vault's filesystem and its coordination included, and nothing is added to what
/// the guest reaches. Only a regular file is read, and only up to `limit` bytes.
///
/// The read is one short program in the guest, so what it returned is kept for a while by path:
/// a row the transcript makes again as it scrolls draws from that at once, and asks the guest
/// again only when what is kept is older than `fresh`. That there was no file to read is kept
/// the same way, so a reply naming one that is not there does not start a program a row.
enum GuestImages {
    /// The most bytes an image file may be. A chart or a photograph is well under it; past it
    /// the file is not drawn.
    static let limit = 8 * 1024 * 1024
    /// How long what was read stands for the file, in seconds, before the guest is asked again.
    static let fresh: TimeInterval = 30

    /// The reader the chat hands its replies (`EnvironmentValues.replyImages`), at `epoch`
    /// (`Mounts`), which a row reads again at each change of.
    static func reader(epoch: Int) -> ReplyImages {
        ReplyImages(kept: { kept.data(for: $0) }, read: { await line.read($0) }, epoch: epoch)
    }

    /// Counts the changes in what the guest can read, for the chat to watch: a row drawn before
    /// the home or the memory was mounted asks again once it is.
    @MainActor @Observable final class Mounts {
        static let shared = Mounts()
        private(set) var epoch = 0
        fileprivate func changed() { epoch += 1 }
    }

    /// What the guest can read has changed — its home mounted, the memory mounted, or, with
    /// `forgetting`, a sign-out: a "no such file" answered before is no longer the answer, and
    /// at a sign-out nothing that was read is kept.
    static func changed(forgetting: Bool = false) {
        kept.drop(everything: forgetting)
        Task { @MainActor in Mounts.shared.changed() }
    }

    /// The file at `path` as the guest reads it now, or nil: no guest yet, no such file,
    /// something that is not a regular file, one over the limit, or a read the guest did not
    /// finish. A path from `~` is from the guest's home, as a relative one is.
    static func bytes(at path: String) async -> Data? {
        if let held = kept.entry(for: path), Date().timeIntervalSince(held.read) < fresh { return held.data }
        guard Guest.shared.kernels > 0 else { return nil }
        let home = ClaudeLauncher.home
        let named = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path
        let data = (try? await Guest.shared.contents(ofFile: named, from: home, limit: limit)) ?? nil
        kept.set(data, for: path)
        return data
    }

    private static let line = Line()

    /// The reads, one at a time, and one for a path however many rows ask for it at once. A
    /// read holds a thread of the system's shared queue until its program ends, and a reply
    /// can name any number of images, so a read for each at once would leave that queue with
    /// no thread to finish any of them on.
    private actor Line {
        private var asking: [String: Task<Data?, Never>] = [:]
        private var last: Task<Data?, Never>?

        func read(_ path: String) async -> Data? {
            if let already = asking[path] { return await already.value }
            let before = last
            let task = Task<Data?, Never> {
                _ = await before?.value
                return await GuestImages.bytes(at: path)
            }
            asking[path] = task
            last = task
            let data = await task.value
            if asking[path] == task { asking[path] = nil }
            if last == task { last = nil }
            return data
        }
    }

    private static let kept = Kept()

    /// What the guest last answered, by path — a file's bytes, or that there was none to read —
    /// within a bound of bytes.
    private final class Kept: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (data: Data?, read: Date)] = [:]
        private static let bytes = 32 * 1024 * 1024

        func entry(for path: String) -> (data: Data?, read: Date)? { lock.withLock { entries[path] } }
        func data(for path: String) -> Data? { entry(for: path)?.data }

        func drop(everything: Bool) {
            lock.withLock { entries = everything ? [:] : entries.filter { $0.value.data != nil } }
        }

        func set(_ data: Data?, for path: String) {
            lock.withLock {
                entries[path] = (data, Date())
                // The oldest go first once what is kept is more than it may be.
                while entries.values.reduce(0, { $0 + ($1.data?.count ?? 0) }) > Self.bytes || entries.count > 256,
                      let oldest = entries.min(by: { $0.value.read < $1.value.read })?.key {
                    entries[oldest] = nil
                }
            }
        }
    }
}
