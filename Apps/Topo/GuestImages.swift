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
enum GuestImages {
    /// The most bytes an image file may be. A chart or a photograph is well under it; past it
    /// the file is not drawn.
    static let limit = 8 * 1024 * 1024

    /// What the chat's replies are read through: the guest's own answers, kept.
    static let store = GuestImageStore { path in
        guard Guest.shared.kernels > 0 else { return nil }
        let home = ClaudeLauncher.home
        // A path from `~` is from the guest's home, as a relative one is.
        let named = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path
        return .some((try? await Guest.shared.contents(ofFile: named, from: home, limit: limit)) ?? nil)
    }

    /// The reader the chat hands its replies (`EnvironmentValues.replyImages`), at `epoch`
    /// (`Mounts`), which a row reads again at each change of.
    static func reader(epoch: Int) -> ReplyImages {
        ReplyImages(kept: { store.kept($0) }, read: { await store.read($0) }, epoch: epoch)
    }

    /// Counts the changes in what the guest can read, for the chat to watch: a row drawn before
    /// the home or the memory was mounted asks again once it is. `home` is whether the guest's
    /// home has been mounted, which is when there is a guest to read from at all.
    @MainActor @Observable final class Mounts {
        static let shared = Mounts()
        private(set) var epoch = 0
        private(set) var home = false
        fileprivate func changed(home mounted: Bool) {
            epoch += 1
            if mounted { home = true }
        }
    }

    /// What the guest can read has changed — its home mounted (`home`), the memory mounted or
    /// changed for another folder, a sign-out: nothing answered before is the answer now, so
    /// nothing read before is kept, and no read still under way is kept when it lands.
    static func changed(home: Bool = false) {
        store.forget()
        Task { @MainActor in Mounts.shared.changed(home: home) }
    }
}

/// What was read of the guest's files for the chat, kept for a while by path.
///
/// A read is one short program in the guest, so its answer — a file's bytes, or that there was
/// none to read — stands for the path for `fresh` seconds: a row the transcript makes again as
/// it scrolls draws from that at once, and a reply naming a file that is not there does not
/// start a program a row. The reads are made one at a time, and one for a path however many
/// rows ask for it at once: a read holds a thread of the system's shared queue until its
/// program ends, and a reply can name any number of images, so a read for each at once would
/// leave that queue with no thread to finish any of them on.
///
/// `forget()` ends an age: what the guest can read has changed — a mount, another vault, a
/// sign-out — so everything kept goes, and a read begun before it is neither kept nor
/// answered when it lands, since what it read is the last age's.
final class GuestImageStore: Sendable {
    /// The guest's answer for a path: the bytes, nil for no file that can be read, or no
    /// answer at all (`.none`) where there is no guest to ask, which is not kept.
    typealias Ask = @Sendable (String) async -> Data??

    /// How long an answer stands for its path, in seconds.
    let fresh: TimeInterval
    private let ask: Ask
    private let kept = Kept()
    private let line = Line()

    init(fresh: TimeInterval = 30, ask: @escaping Ask) {
        self.fresh = fresh
        self.ask = ask
    }

    /// The bytes last read for `path`, with no waiting: what a row draws in its first frame.
    func kept(_ path: String) -> Data? { kept.entry(for: path)?.data }

    /// The file at `path` as the guest reads it, or nil: no guest, no such file, a read the
    /// guest did not finish, or one that an age ended under.
    func read(_ path: String) async -> Data? {
        await line.read(path) { [self] in
            if let held = kept.entry(for: path), Date().timeIntervalSince(held.read) < fresh { return held.data }
            let age = kept.age
            guard let answer = await ask(path) else { return nil }
            return kept.set(answer, for: path, in: age) ? answer : nil
        }
    }

    func forget() { kept.forget() }

    /// The reads, one at a time, and one for a path however many ask at once.
    private actor Line {
        private var asking: [String: Task<Data?, Never>] = [:]
        private var last: Task<Data?, Never>?

        func read(_ path: String, _ work: @escaping @Sendable () async -> Data?) async -> Data? {
            if let already = asking[path] { return await already.value }
            let before = last
            let task = Task<Data?, Never> {
                _ = await before?.value
                return await work()
            }
            asking[path] = task
            last = task
            let data = await task.value
            if asking[path] == task { asking[path] = nil }
            if last == task { last = nil }
            return data
        }
    }

    /// The answers of this age, by path, within a bound of bytes and of entries.
    private final class Kept: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (data: Data?, read: Date)] = [:]
        private var current = 0
        private static let bytes = 32 * 1024 * 1024
        private static let count = 256

        var age: Int { lock.withLock { current } }
        func entry(for path: String) -> (data: Data?, read: Date)? { lock.withLock { entries[path] } }

        func forget() {
            lock.withLock {
                current += 1
                entries = [:]
            }
        }

        /// Keeps an answer read in `age`, unless that age has ended; whether it was kept.
        func set(_ data: Data?, for path: String, in age: Int) -> Bool {
            lock.withLock {
                guard age == current else { return false }
                entries[path] = (data, Date())
                // The oldest go first once what is kept is more than it may be.
                while entries.values.reduce(0, { $0 + ($1.data?.count ?? 0) }) > Self.bytes || entries.count > Self.count,
                      let oldest = entries.min(by: { $0.value.read < $1.value.read })?.key {
                    entries[oldest] = nil
                }
                return true
            }
        }
    }
}
