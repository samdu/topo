import ActivityKit
import Foundation
import TopoCore
import OSLog
import TopoTools

/// A running activity as the tool and the keeper see it.
struct ActivityRecord: Equatable, Sendable {
    var id: String
    var attributes: TopoActivityAttributes
    var state: ActivityState
    /// Ended by the app or the person, and still shown until the system takes it down.
    var ended: Bool
}

/// What a start or an update hands the system: the state, when it goes stale, how prominent.
struct ActivityNotice: Equatable, Sendable {
    var state: ActivityState
    var stale: Date?
    var relevance: Double?
}

enum ActivityDismissal: Equatable, Sendable {
    /// Taken off the lock screen at once.
    case now
    /// The system's own: it stays, ended, for a while.
    case standard
    /// Taken off at the date (the system caps it at four hours after the end).
    case at(Date)
}

/// Why the system would not start an activity, as the tool says it.
enum ActivityRefusal: Error, Equatable {
    /// Live Activities are off for Topo in Settings.
    case disabled
    /// ActivityKit starts one only while the app is on the screen.
    case notOnScreen
    case tooMany
    case tooLarge
    case other(String)
}

/// The system's Live Activities, as the tool and the keeper reach them, so a suite can stand a
/// fake in place of ActivityKit, which no test host can drive.
@MainActor
protocol ActivityHost: AnyObject {
    var enabled: Bool { get }
    func running() -> [ActivityRecord]
    func start(_ attributes: TopoActivityAttributes, _ notice: ActivityNotice) throws -> String
    /// False when the system has no such activity any more.
    @discardableResult func update(_ id: String, _ notice: ActivityNotice) async -> Bool
    @discardableResult func end(_ id: String, _ state: ActivityState?, dismissal: ActivityDismissal) async -> Bool
}

/// ActivityKit itself.
@MainActor
final class ActivityKitHost: ActivityHost {
    var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func running() -> [ActivityRecord] {
        Activity<TopoActivityAttributes>.activities.map { activity in
            ActivityRecord(id: activity.id, attributes: activity.attributes, state: activity.content.state,
                           ended: activity.activityState == .ended || activity.activityState == .dismissed)
        }
    }

    func start(_ attributes: TopoActivityAttributes, _ notice: ActivityNotice) throws -> String {
        do {
            let activity = try Activity.request(attributes: attributes, content: Self.content(notice))
            return activity.id
        } catch let error as ActivityAuthorizationError {
            switch error {
            case .denied: throw ActivityRefusal.disabled
            case .visibility: throw ActivityRefusal.notOnScreen
            case .globalMaximumExceeded, .targetMaximumExceeded: throw ActivityRefusal.tooMany
            case .attributesTooLarge: throw ActivityRefusal.tooLarge
            case .unsupported, .unsupportedTarget: throw ActivityRefusal.other("this device does not show Live Activities")
            case .unentitled: throw ActivityRefusal.other("this build of Topo does not declare Live Activities")
            case .persistenceFailure: throw ActivityRefusal.other("the system could not keep the activity; ask again")
            default: throw ActivityRefusal.other(error.localizedDescription)
            }
        } catch {
            throw ActivityRefusal.other(error.localizedDescription)
        }
    }

    // An `Activity` is not Sendable, so each is found and spoken to inside one task of its own
    // rather than carried across from the main actor.
    func update(_ id: String, _ notice: ActivityNotice) async -> Bool {
        let content = Self.content(notice)
        return await Task.detached {
            guard let activity = Self.activity(id) else { return false }
            await activity.update(content)
            return true
        }.value
    }

    /// Ends the activity. On one ended already and still on the lock screen, `.now` is meant to
    /// take it off, which is what `endAll`, a resume past `until` and the tool's take-down ask for
    /// what a default dismissal left shown, and a date at that date; whether
    /// ActivityKit honours a second end that way is the device box on the PR, not a suite's word.
    func end(_ id: String, _ state: ActivityState?, dismissal: ActivityDismissal) async -> Bool {
        let policy: ActivityUIDismissalPolicy = switch dismissal {
        case .now: .immediate
        case .standard: .default
        case .at(let date): .after(date)
        }
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        return await Task.detached {
            guard let activity = Self.activity(id) else { return false }
            await activity.end(content, dismissalPolicy: policy)
            return true
        }.value
    }

    nonisolated private static func activity(_ id: String) -> Activity<TopoActivityAttributes>? {
        Activity<TopoActivityAttributes>.activities.first { $0.id == id }
    }

    private static func content(_ notice: ActivityNotice) -> ActivityContent<ActivityState> {
        ActivityContent(state: notice.state, staleDate: notice.stale, relevanceScore: notice.relevance ?? 0)
    }
}

/// Fetches a tracker's JSON from where `poll` names: one request on an ephemeral session under an
/// absolute deadline, no redirect followed, the body read no further than the cap. The URL, the
/// body and why a fetch failed go nowhere: not a log line, not an answer.
protocol TrackerFetcher: Sendable {
    /// The body of a 2xx within the cap, or nil.
    func fetch(_ url: URL) async -> Data?
}

struct URLTrackerFetcher: TrackerFetcher {
    static let deadline: Duration = .seconds(10)
    static let cap = 64 * 1024

    var deadline = URLTrackerFetcher.deadline
    var cap = URLTrackerFetcher.cap

    func fetch(_ url: URL) async -> Data? {
        await Self.fetch(url, deadline: deadline, cap: cap)
    }

    private static func fetch(_ url: URL, deadline: Duration, cap: Int) async -> Data? {
        let request: URLRequest = {
            var made = URLRequest(url: url)
            made.httpMethod = "GET"
            made.setValue("application/json", forHTTPHeaderField: "Accept")
            return made
        }()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        let seconds = Double(deadline.components.seconds) + Double(deadline.components.attoseconds) / 1e18
        configuration.timeoutIntervalForRequest = seconds
        configuration.timeoutIntervalForResource = seconds
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return await withTaskGroup(of: Data??.self) { group in
            group.addTask {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { return .some(nil) }
                    if let length = (response as? HTTPURLResponse)?.expectedContentLength, length > Int64(cap) { return .some(nil) }
                    var body = Data()
                    body.reserveCapacity(min(Int(response.expectedContentLength.clamped), cap))
                    for try await byte in bytes {
                        body.append(byte)
                        if body.count > cap { return .some(nil) }
                    }
                    return .some(body)
                } catch {
                    return Task.isCancelled ? nil : .some(nil)
                }
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return Task.isCancelled ? nil : .some(nil)
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }

    /// A 3xx is the answer: the redirect is declined.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }
}

private extension Int64 {
    /// An expected length as a count to reserve: unknown (-1) and absurd ones as 0.
    var clamped: Int64 { (0...Int64(URLTrackerFetcher.cap)).contains(self) ? self : 0 }
}

/// Keeps the activities while Topo runs: polls each one's tracker and updates it, ends it when its
/// tracker ends or its `until` comes, and ends every one at sign-out. Nothing here runs while the
/// process is suspended, which is why a polled activity goes stale `staleAfter` past its last
/// update and the help says so.
@MainActor
final class ActivityKeeper {
    static let shared = ActivityKeeper(host: ActivityKitHost())
    nonisolated static let interval: Duration = .seconds(20)
    /// How long a polled activity reads as current past its last update.
    nonisolated static let staleAfter: TimeInterval = 60

    let host: ActivityHost
    let fetcher: TrackerFetcher
    /// Waits `Duration`: the app's is a task's sleep, a suite's a clock it moves.
    let sleep: @Sendable (Duration) async throws -> Void
    let now: @Sendable () -> Date
    private var polls: [String: Task<Void, Never>] = [:]
    private var ends: [String: Task<Void, Never>] = [:]
    /// Slots a start holds while it fetches its tracker, so two starts of one slot make one activity.
    private var reserved: Set<String> = []
    /// The login the activities are kept under: a call that read the activities before an await
    /// takes its `epoch` and checks it after, since the login may have ended in between and
    /// nothing from before that may start or keep anything.
    let login: LoginLife
    /// Counts the tool's updates of each activity: a poll that read the count before its fetch
    /// and finds it moved when its turn at the gate comes leaves that round to the next.
    private var revisions: [String: Int] = [:]
    private var resuming = false
    /// The gate every change to an activity passes, one at a time: an update, an end, a resume's
    /// or a sign-out's. Each reads the activity again inside it, so none acts on what the host
    /// held before another's call to it returned, and none of them overtakes another in the host.
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Activities this process took off the lock screen at once (`end` with `.now`): a resume
    /// sends them nothing more. A sign-out ends every one again, and the tool's take-down is asked
    /// for by name; both stand.
    private var takenDown: Set<String> = []
    private let log = TopoLog(.activity)

    /// `login`: every way a login ends reaches the keeper through its `onEnd`; every activity is
    /// the login's.
    init(host: ActivityHost, fetcher: TrackerFetcher = URLTrackerFetcher(),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping @Sendable () -> Date = { Date() }, login: LoginLife = .shared) {
        self.host = host
        self.fetcher = fetcher
        self.sleep = sleep
        self.now = now
        self.login = login
        login.onEnd(awaiting: { [weak self] in await self?.endAll() })
    }

    /// The stale date a notice carries: `until`, and for a polled activity no later than
    /// `staleAfter` from now.
    func staleDate(until: Date?, polled: Bool) -> Date? {
        let fromPoll = polled ? now().addingTimeInterval(Self.staleAfter) : nil
        return [until, fromPoll].compactMap { $0 }.min()
    }

    func notice(_ state: ActivityState, polled: Bool) -> ActivityNotice {
        ActivityNotice(state: state, stale: staleDate(until: state.until, polled: polled), relevance: state.relevance)
    }

    /// The tasks standing: what a suite counts after `endAll`.
    var tasks: Int { polls.count + ends.count }

    /// The tool is updating the activity: counted, inside the gate, before the host is asked.
    func touch(_ id: String) { revisions[id, default: 0] += 1 }
    func revision(_ id: String) -> Int { revisions[id] ?? 0 }

    /// A slot held for a start that is still fetching; false when it is held already.
    func reserve(_ slot: String) -> Bool { reserved.insert(slot).inserted }
    func release(_ slot: String) { reserved.remove(slot) }
    func isReserved(_ slot: String) -> Bool { reserved.contains(slot) }

    /// Runs `work` on the activity as the host holds it when the gate opens to it, alone among
    /// the keeper's changes; nil when the host has no such activity, or it is ended and
    /// `ended` was not asked for.
    @discardableResult
    func changing<T>(_ id: String, ended: Bool = false, _ work: (ActivityRecord) async -> T) async -> T? {
        await enter()
        defer { leave() }
        guard let record = host.running().first(where: { $0.id == id }), ended || !record.ended else { return nil }
        return await work(record)
    }

    /// Ends the activity in the host, and notes one taken off at once. Called inside the gate.
    @discardableResult
    func end(_ id: String, _ state: ActivityState?, dismissal: ActivityDismissal) async -> Bool {
        if dismissal == .now { takenDown.insert(id) }
        return await host.end(id, state, dismissal: dismissal)
    }

    private func enter() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the gate to the next change waiting, which finds it still busy, or opens it.
    private func leave() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    /// At launch and on every return to the screen: ends what is past its `until`, an ended one
    /// still shown included, and keeps the rest, since a process that was ended kept nothing.
    /// Each is judged as the host holds it at its turn at the gate, not as it was listed: an
    /// update may have moved its `until`, or something else ended it, meanwhile. Two returns at
    /// once resume once.
    func resume() async {
        guard !resuming else { return }
        resuming = true
        defer { resuming = false }
        let epoch = login.epoch
        for id in host.running().map(\.id) {
            await changing(id, ended: true) { record in
                if let until = record.state.until, until <= now() {
                    guard !takenDown.contains(id) else { return }
                    forget(id)
                    await end(id, nil, dismissal: .now)
                    log.info("activity \(id) ended at its until")
                } else if !record.ended, epoch.isCurrent {
                    // Kept only under the login that resumed: a sign-out queued behind this turn
                    // has already moved the epoch, and its end follows.
                    keep(id)
                }
            }
        }
    }

    /// Starts the tasks an activity needs: a poll where its attributes name one, an end at its
    /// `until`. Called after a start and after an update, since an update may move `until`.
    func keep(_ id: String) {
        guard let record = host.running().first(where: { $0.id == id }), !record.ended else { return }
        if let url = record.attributes.poll, polls[id] == nil {
            polls[id] = Task { [weak self] in await self?.poll(id, url) }
        }
        ends[id]?.cancel()
        ends[id] = nil
        if let until = record.state.until {
            ends[id] = Task { [weak self] in
                guard let self else { return }
                // Until the clock says so, not until a sleep returns: a wait that ends early sleeps on.
                while now() < until {
                    try? await sleep(.seconds(until.timeIntervalSince(now())))
                    guard !Task.isCancelled else { return }
                }
                // Read again at the gate: the person may have ended it, or an update moved its
                // `until` (which replaces this task), while the task slept or waited.
                let ended = await changing(id) { record -> Bool in
                    guard !Task.isCancelled, let current = record.state.until, current <= now() else { return false }
                    forget(id)
                    await end(id, nil, dismissal: .now)
                    return true
                }
                if ended == true { log.info("activity \(id) ended at its until") }
                if ended == nil { forget(id) }
            }
        }
    }

    /// Stops an activity's tasks; what the host shows is the caller's to end.
    func forget(_ id: String) {
        polls[id]?.cancel()
        polls[id] = nil
        ends[id]?.cancel()
        ends[id] = nil
        revisions[id] = nil
    }

    /// A sign-out, a takeover or a viewer's arrival: the activities are the login's, the ones
    /// ended and still on the lock screen included, since a default dismissal leaves one shown
    /// for hours. A start or an update in flight finds the epoch moved and does nothing; the
    /// epoch has moved before this runs, since it is a teardown (`LoginLife`).
    func endAll() async {
        reserved = []
        for id in host.running().map(\.id) {
            forget(id)
            await changing(id, ended: true) { _ in await end(id, nil, dismissal: .now) }
        }
        log.info("every activity ended with the login")
    }

    /// How a tracker that finished is taken down: at its `until` when that is still ahead (the
    /// system takes it down four hours after the end at the latest), at once when it has passed,
    /// and the system's own way when it has none.
    func finished(_ state: ActivityState) -> ActivityDismissal {
        guard let until = state.until else { return .standard }
        return until > now() ? .at(until) : .now
    }

    private func poll(_ id: String, _ url: URL) async {
        while !Task.isCancelled {
            try? await sleep(Self.interval)
            guard !Task.isCancelled else { return }
            guard host.running().contains(where: { $0.id == id && !$0.ended }) else {
                forget(id)
                return
            }
            let epoch = login.epoch
            let revision = revision(id)
            let fetched = await fetcher.fetch(url)
            guard !Task.isCancelled, epoch.isCurrent else {
                forget(id)
                return
            }
            guard let data = fetched, let tracker = ProgressTracker.read(data, now: now()).tracker else {
                log.info("activity \(id) poll gave no tracker")
                continue
            }
            enum Round { case kept, gone, finished }
            // Read again at the gate: the activity may be ended, updated, or the login's gone.
            let round = await changing(id) { record -> Round in
                guard !Task.isCancelled, epoch.isCurrent else { return .gone }
                // An update of the tool's since the fetch began has passed the gate before this
                // round, or is the host's now: this round is left to the next, which reads it.
                guard revision == self.revision(id) else { return .kept }
                var state = record.state
                state.card = TrackerCard(tracker)
                guard let fitted = ActivityPayload.fit(state, with: record.attributes).state else {
                    log.info("activity \(id) poll gave a tracker over the payload budget")
                    return .kept
                }
                if tracker.isRunning {
                    // Every fetch that answers moves the stale date, whether or not the card moved:
                    // a step longer than a minute is not a tracker gone quiet.
                    await host.update(id, notice(fitted, polled: true))
                    return .kept
                }
                forget(id)
                await end(id, fitted, dismissal: finished(fitted))
                return .finished
            }
            switch round {
            case .kept?: continue
            case .finished?: log.info("activity \(id) ended with its tracker"); return
            case .gone?, nil: forget(id); return
            }
        }
    }
}
