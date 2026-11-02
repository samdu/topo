import Foundation
import XCTest

@testable import Topo

/// ActivityKit as the suites stand it in: what the tool and the keeper asked of it, in order, and
/// the activities it would then show.
@MainActor
final class FakeActivityHost: ActivityHost {
    enum Call: Equatable {
        case start(slot: String, poll: URL?, state: ActivityState, stale: Date?)
        case update(id: String, state: ActivityState, stale: Date?)
        case end(id: String, state: ActivityState?, dismissal: ActivityDismissal)
    }

    var enabled = true
    /// What `start` throws next, when set.
    var refusal: ActivityRefusal?
    private(set) var calls: [Call] = []
    var records: [ActivityRecord] = []
    private var next = 1

    func running() -> [ActivityRecord] { records }

    func start(_ attributes: TopoActivityAttributes, _ notice: ActivityNotice) throws -> String {
        calls.append(.start(slot: attributes.slot, poll: attributes.poll, state: notice.state, stale: notice.stale))
        if let refusal { throw refusal }
        let id = "A\(next)"
        next += 1
        records.append(ActivityRecord(id: id, attributes: attributes, state: notice.state, ended: false))
        return id
    }

    func update(_ id: String, _ notice: ActivityNotice) async {
        calls.append(.update(id: id, state: notice.state, stale: notice.stale))
        if let index = records.firstIndex(where: { $0.id == id }) { records[index].state = notice.state }
    }

    func end(_ id: String, _ state: ActivityState?, dismissal: ActivityDismissal) async {
        calls.append(.end(id: id, state: state, dismissal: dismissal))
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index].ended = true
            if let state { records[index].state = state }
        }
    }

    var starts: Int { calls.filter { if case .start = $0 { true } else { false } }.count }
    var updates: Int { calls.filter { if case .update = $0 { true } else { false } }.count }
    var ends: [Call] { calls.filter { if case .end = $0 { true } else { false } } }
}

/// A tracker's JSON handed back in turn, one answer a fetch; nil is a fetch that failed.
final class FakeTrackerFetcher: TrackerFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Data?]
    private(set) var fetched: [URL] = []

    init(_ answers: [String?]) {
        self.answers = answers.map { $0.map { Data($0.utf8) } }
    }

    func fetch(_ url: URL) async -> Data? {
        lock.withLock {
            fetched.append(url)
            guard !answers.isEmpty else { return nil }
            return answers.removeFirst()
        }
    }
}

/// A clock the suites move: every sleep waits until `advance` passes it.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: TimeInterval = 0
    private var waiting: [(id: Int, until: TimeInterval, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextSleep = 0

    var date: Date { Date(timeIntervalSince1970: 1_793_580_000 + lock.withLock { now }) }

    func sleep(_ duration: Duration) async throws {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let id = lock.withLock { nextSleep += 1; return nextSleep }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if seconds <= 0 { continuation.resume(); return }
                    waiting.append((id, now + seconds, continuation))
                }
            }
        } onCancel: {
            // Only this sleep: a cancelled task wakes nobody else's wait.
            let cancelled = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard let index = waiting.firstIndex(where: { $0.id == id }) else { return nil }
                return waiting.remove(at: index).continuation
            }
            cancelled?.resume(throwing: CancellationError())
        }
    }

    /// Moves time on, waking every sleep that has run out.
    func advance(_ seconds: TimeInterval) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            now += seconds
            let ready = waiting.filter { $0.until <= now }
            waiting.removeAll { $0.until <= now }
            return ready.map(\.continuation)
        }
        due.forEach { $0.resume() }
    }

    var sleepers: Int { lock.withLock { waiting.count } }
}

enum TrackerFixtures {
    /// The wiki's example, two steps in.
    static let wiki = """
    {"id": "b36e250e", "kind": "progress", "title": "macOS update on buddybox",
     "steps": [{"label": "Check for update", "state": "done", "note": "26.1 → 26.2 available", "at": 1793580000.0},
               {"label": "Download", "state": "running", "note": "", "at": 1793580060.0},
               {"label": "Install and restart", "state": "waiting", "note": "", "at": null}],
     "current": 1, "state": "running", "eta": 1793590200.0,
     "started": 1793580000.0, "updated": 1793580060.0, "ended": null,
     "owner": {"session": "mac-update", "address": "buddybox", "link": "https://claude.ai/code/x"},
     "history": [{"event": "posted"}], "delivery": {"status": "none"}}
    """

    static func tracker(steps: [(String, String)], current: Int = 0, state: String = "running", ended: Bool = false) -> String {
        let list = steps.map { #"{"label": "\#($0.0)", "state": "\#($0.1)", "note": "", "at": 1793580000.0}"# }.joined(separator: ",")
        return #"{"id": "t1", "title": "A tracker", "steps": [\#(list)], "current": \#(current), "state": "\#(state)", "eta": null, "started": 1793580000.0, "updated": 1793580100.0, "ended": \#(ended ? "1793580100.0" : "null"), "owner": {"session": "s", "address": "a", "link": ""}}"#
    }
}
