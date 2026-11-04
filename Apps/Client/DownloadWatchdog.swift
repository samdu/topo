#if os(iOS)
import Foundation

/// Judges each download task's rate from what the session reports of it, and says which to
/// cancel and when to make each one's replacement. The Hub's CDN sometimes serves a connection
/// at tens of kilobytes a second for the whole of a transfer while its neighbours run at tens of
/// megabytes (brief-perf-first-run: 5 of 28 fresh ranges from buddybox, one held at 36 KB/s for
/// 24 minutes), and the same bytes asked for again come fast, though not always at once. So a
/// task that is slow for a `window` of samples is cancelled with its resume data and made again
/// from it: at once, then after each of `backoff`, and past those at once again but at most once
/// a `cooldown`, the task left running between. A key whose last replacement had no resume data
/// to carry on from is not cancelled again: a second start from nothing is a loss, not a retry.
///
/// Slow is under `floor` and, where another task is flowing beside it, under a `share` of the
/// fastest of them: six connections on one thin link are all slow by the floor and none by each
/// other, and a crawl beside a fast neighbour is the connection's own. A task flowing alone is
/// judged by the floor, since there is nothing to compare it with.
///
/// Pure over the instants it is handed: no session, no timer, no clock of its own. `ModelDownloads`
/// feeds it `didWriteData`, ticks it every `tick` while it is `active` and the app is in front,
/// and acts on what it answers. A background session carries on while the app is suspended and
/// no progress reaches the process meanwhile, so the watchdog is told the bytes each task was at
/// when the app resigned (`resigned`) and the bytes each is at on return (`probe`), judges that
/// span as one window, and drops every sample from before, anchoring each task left running that
/// has had a first byte at the bytes it is at on return: nothing more is judged until a window
/// has passed since. A cancel in flight and a replacement owed are kept across the time away, and
/// made on the first tick after the return.
///
/// Slowness is never a failure: a file is only ever cancelled to be made again.
@MainActor
final class DownloadWatchdog {
    typealias Instant = ContinuousClock.Instant

    /// Under this, a task is slow: bytes a second over the window.
    nonisolated static let floor: Int64 = 256 * 1024
    /// And under this share of the fastest task flowing beside it, when there is one.
    nonisolated static let share = 10
    /// How long a task is judged over. Nothing is judged of a task with less than this of samples.
    nonisolated static let window: Duration = .seconds(20)
    /// How often `ModelDownloads` asks.
    nonisolated static let tick: Duration = .seconds(5)
    /// How long after each cancel its replacement is made, by attempt; past these,
    /// `laterBackoff`.
    nonisolated static let backoff: [Duration] = [.zero, .seconds(15), .seconds(30), .seconds(60)]
    /// Past `backoff.count` attempts, a file is cancelled again no sooner than this after the last.
    nonisolated static let cooldown: Duration = .seconds(300)

    /// Past `backoff`, a replacement is made at once; the cooldown spaces the cancels.
    nonisolated static let laterBackoff: Duration = .zero

    /// A task to cancel: its key, the rate it was judged at, and which attempt this is (1-based).
    struct Cancel: Equatable, Sendable {
        let key: String
        let rate: Int64
        let attempt: Int
    }

    private struct Sample {
        let at: Instant
        let bytes: Int64
    }

    /// A window's worth of samples a key, plus the one before the window as the anchor.
    private var samples: [String: [Sample]] = [:]
    /// Cancels made a key, in this process, and when the last was.
    private var attempts: [String: (count: Int, last: Instant)] = [:]
    /// Keys whose cancel is asked for and whose `.restarting` has not arrived.
    private var cancelling: Set<String> = []
    /// Keys whose `.restarting` has arrived, by when their replacement is due.
    private var pending: [String: Instant] = [:]
    /// The bytes each key was at when the app resigned, and when; set while the app is away, when
    /// no sample is taken.
    private var resignedAt: (at: Instant, bytes: [String: Int64])?
    /// Keys whose last replacement carried no resume data: cancelled no more.
    private var unresumable: Set<String> = []
    /// Keys forgotten since the session was last asked for the bytes `probe` is handed, while
    /// that answer is owed: the answer may predate a forget, and is no word about those keys.
    private var forgottenSinceAsked: Set<String>?

    /// Whether there is anything to tick for: a key with samples, or a restart owed.
    var active: Bool { !samples.isEmpty || !pending.isEmpty }

    /// Whether `key` is between its cancel and its replacement, when `enqueue` leaves it alone.
    func restarting(_ key: String) -> Bool { cancelling.contains(key) || pending[key] != nil }

    /// The cancels made a key so far.
    func attempts(_ key: String) -> Int { attempts[key]?.count ?? 0 }

    /// How many samples a key holds: a window's worth and the anchor, however long it flows.
    func kept(_ key: String) -> Int { samples[key]?.count ?? 0 }

    /// The marks, which name the model, the manifest's path, bytes and a count, and nothing else
    /// (`docs/perf.md`).
    nonisolated static func slowMark(id: String, path: String, rate: Int64, attempt: Int) -> String {
        "download.slow \(id) \(path) rate=\(rate) attempt=\(attempt)"
    }

    nonisolated static func restartedMark(id: String, path: String, at bytes: Int64, resumed: Bool) -> String {
        "download.restarted \(id) \(path) at=\(bytes) resumed=\(resumed ? 1 : 0)"
    }

    nonisolated static func resumedMark(id: String, path: String, from offset: Int64) -> String {
        "download.resumedAt \(id) \(path) from=\(offset)"
    }

    /// `didWriteData` for a task: the bytes written so far, at `now`. Ignored for a key that is
    /// restarting, and while the app is away.
    func observe(_ key: String, bytes: Int64, at now: Instant) {
        guard !restarting(key), resignedAt == nil else { return }
        var kept = samples[key] ?? []
        kept.append(Sample(at: now, bytes: bytes))
        samples[key] = Self.pruned(kept, at: now)
    }

    /// The task is done with, one way or another: verifying, verified or failed.
    func forget(_ key: String) {
        forgottenSinceAsked?.insert(key)
        samples[key] = nil
        cancelling.remove(key)
        pending[key] = nil
        unresumable.remove(key)
    }

    /// The replacement for `key` is made, with or without resume data: without, the key is not
    /// cancelled again.
    func restarted(_ key: String, resumed: Bool) {
        if !resumed { unresumable.insert(key) }
    }

    /// The app is leaving the foreground: the bytes each flowing task is at, for `probe`. No
    /// sample is taken until `probe`; a cancel in flight and a replacement owed are kept.
    func resigned(at now: Instant) {
        var bytes: [String: Int64] = [:]
        for (key, kept) in samples {
            if let newest = kept.last { bytes[key] = newest.bytes }
        }
        resignedAt = (now, bytes)
        samples = [:]
    }

    /// The session is being asked for the bytes the next `probe` is handed: a key forgotten from
    /// here until that probe is left out of it, since the session's answer may have been taken
    /// before the task finished.
    func asking() {
        forgottenSinceAsked = []
    }

    /// The app is in front again, with the bytes the session says each task is at now: the span
    /// since `resigned` is judged as one window where it is at least a window long, and the
    /// crawls in it are cancelled at once. Every sample from before is dropped, and each task
    /// left running that has had a first byte is anchored at the bytes it is at now, so one that
    /// stalls on the return with no progress after is judged by that silence a window on. A key
    /// not in `received` is gone (finished, or the session no longer holds it), and so is a key
    /// forgotten since `asking`: neither anchored nor judged, nor a rate the others are judged
    /// against.
    func probe(_ answered: [String: Int64], at now: Instant) -> [Cancel] {
        let forgotten = forgottenSinceAsked ?? []
        forgottenSinceAsked = nil
        let received = answered.filter { !forgotten.contains($0.key) }
        defer { resignedAt = nil }
        samples = [:]
        for (key, bytes) in received where bytes > 0 && !restarting(key) { samples[key] = [Sample(at: now, bytes: bytes)] }
        guard let resignedAt, now - resignedAt.at >= Self.window else { return [] }
        let elapsed = Self.seconds(now - resignedAt.at)
        var rates: [String: Int64] = [:]
        for (key, bytes) in received where !restarting(key) {
            // A task with no sample at the resign (made just before it, its first byte not yet
            // in) has no baseline: the span is not judged, since its rate is the comparison the
            // others are judged against. A count below the sample's is a counter the progress
            // did not sample (Foundation's agree, offset included; a guard, not a stall): not
            // judged either. Both are judged a window after the anchor the probe leaves them.
            guard let before = resignedAt.bytes[key] else { return [] }
            guard bytes >= before else { continue }
            rates[key] = Int64((Double(bytes - before) / elapsed).rounded(.down))
        }
        return cancels(rates, at: now)
    }

    /// The keys slow at `now`, each marked as cancelling and its samples dropped, so the
    /// replacement is judged on its own. Nothing while the app is away, and nothing while a task
    /// flowing beside the others has samples but no window yet: its rate is the comparison the
    /// others are judged against, and it is a tick or so away.
    func decisions(at now: Instant) -> [Cancel] {
        guard resignedAt == nil else { return [] }
        var rates: [String: Int64] = [:]
        for (key, kept) in samples where !restarting(key) {
            guard let rate = Self.rate(kept, at: now) else { return [] }
            rates[key] = rate
        }
        return cancels(rates, at: now)
    }

    /// The cancels among keys with a rate: under the floor, under a share of the fastest other
    /// rate where there is another, not within the cooldown of the last past the bound, and not
    /// a key whose last replacement had nothing to carry on from.
    private func cancels(_ rates: [String: Int64], at now: Instant) -> [Cancel] {
        var cancels: [Cancel] = []
        for key in rates.keys.sorted() where !unresumable.contains(key) {
            let rate = rates[key]!
            guard Self.slow(rate, among: rates.filter { $0.key != key }.values) else { continue }
            if let made = attempts[key], made.count >= Self.backoff.count, now - made.last < Self.cooldown { continue }
            let attempt = attempts(key) + 1
            attempts[key] = (attempt, now)
            samples[key] = nil
            cancelling.insert(key)
            cancels.append(Cancel(key: key, rate: rate, attempt: attempt))
        }
        return cancels
    }

    /// Whether a rate is slow: under the floor, and under a share of the fastest of the others
    /// when there are any.
    nonisolated static func slow<Others: Collection>(_ rate: Int64, among others: Others) -> Bool where Others.Element == Int64 {
        guard rate < floor else { return false }
        guard let fastest = others.max() else { return true }
        return rate < fastest / Int64(share)
    }

    /// The relay says the cancel is complete and the resume data, if any, is on disk: the
    /// replacement is owed after this attempt's backoff. False for a key not cancelling, which is
    /// a late word about a cancel `forget` has already let go of.
    @discardableResult
    func cancelled(_ key: String, at now: Instant) -> Bool {
        guard cancelling.remove(key) != nil else { return false }
        let attempt = attempts(key)
        pending[key] = now + (attempt <= Self.backoff.count ? Self.backoff[max(attempt, 1) - 1] : Self.laterBackoff)
        return true
    }

    /// The keys whose replacement is due at `now`, taken: each is made once.
    func restartsDue(at now: Instant) -> [String] {
        guard resignedAt == nil else { return [] }
        let due = pending.filter { $0.value <= now }.keys.sorted()
        for key in due { pending[key] = nil }
        return due
    }

    /// The samples worth keeping at `now`: every one inside the window, and the newest one at or
    /// before its edge, which anchors the rate.
    nonisolated private static func pruned(_ samples: [Sample], at now: Instant) -> [Sample] {
        let edge = now - window
        guard let anchor = samples.lastIndex(where: { $0.at <= edge }) else { return samples }
        return Array(samples[anchor...])
    }

    /// Bytes a second over the window ending at `now`, or nil for a task with no sample at or
    /// before the window's edge: the newest bytes against the anchor's, over the time since the
    /// anchor, so a task that stopped reporting is judged by the silence too.
    nonisolated private static func rate(_ samples: [Sample], at now: Instant) -> Int64? {
        let edge = now - window
        guard let anchor = samples.last(where: { $0.at <= edge }), let newest = samples.last else { return nil }
        let elapsed = seconds(now - anchor.at)
        guard elapsed > 0 else { return nil }
        return max(0, Int64((Double(newest.bytes - anchor.bytes) / elapsed).rounded(.down)))
    }

    nonisolated private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
#endif
