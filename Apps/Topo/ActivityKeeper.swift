import ActivityKit
import Foundation
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
    func update(_ id: String, _ notice: ActivityNotice) async
    func end(_ id: String, _ state: ActivityState?, dismissal: ActivityDismissal) async
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
            default: throw ActivityRefusal.other(error.localizedDescription)
            }
        } catch {
            throw ActivityRefusal.other(error.localizedDescription)
        }
    }

    // An `Activity` is not Sendable, so each is found and spoken to inside one task of its own
    // rather than carried across from the main actor.
    func update(_ id: String, _ notice: ActivityNotice) async {
        let content = Self.content(notice)
        await Task.detached { await Self.activity(id)?.update(content) }.value
    }

    func end(_ id: String, _ state: ActivityState?, dismissal: ActivityDismissal) async {
        let policy: ActivityUIDismissalPolicy = switch dismissal {
        case .now: .immediate
        case .standard: .default
        case .at(let date): .after(date)
        }
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        await Task.detached { await Self.activity(id)?.end(content, dismissalPolicy: policy) }.value
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
    private let log = Logger(subsystem: "zone.hexagon.topo", category: "activity")

    init(host: ActivityHost, fetcher: TrackerFetcher = URLTrackerFetcher(),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.host = host
        self.fetcher = fetcher
        self.sleep = sleep
        self.now = now
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

    /// At launch and on every return to the screen: ends what is past its `until`, and keeps the
    /// rest, since a process that was ended kept nothing.
    func resume() async {
        for record in host.running() where !record.ended {
            if let until = record.state.until, until <= now() {
                await host.end(record.id, nil, dismissal: .now)
                forget(record.id)
                log.info("activity \(record.id, privacy: .public) ended at its until")
                continue
            }
            keep(record.id)
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
                await host.end(id, nil, dismissal: .now)
                forget(id)
                log.info("activity \(id, privacy: .public) ended at its until")
            }
        }
    }

    /// Stops an activity's tasks; what the host shows is the caller's to end.
    func forget(_ id: String) {
        polls[id]?.cancel()
        polls[id] = nil
        ends[id]?.cancel()
        ends[id] = nil
    }

    /// A sign-out, a takeover or a viewer's arrival: the activities are the login's.
    func endAll() async {
        for record in host.running() where !record.ended {
            forget(record.id)
            await host.end(record.id, nil, dismissal: .now)
        }
        log.info("every activity ended with the login")
    }

    private func poll(_ id: String, _ url: URL) async {
        while !Task.isCancelled {
            try? await sleep(Self.interval)
            guard !Task.isCancelled else { return }
            guard let record = host.running().first(where: { $0.id == id }), !record.ended else {
                forget(id)
                return
            }
            guard let data = await fetcher.fetch(url), let tracker = ProgressTracker.read(data, now: now()).tracker else {
                log.info("activity \(id, privacy: .public) poll gave no tracker")
                continue
            }
            var state = record.state
            state.card = TrackerCard(tracker)
            guard let fitted = ActivityPayload.fit(state, with: record.attributes).state else {
                log.info("activity \(id, privacy: .public) poll gave a tracker over the payload budget")
                continue
            }
            if tracker.isRunning {
                guard fitted.card != record.state.card else { continue }
                await host.update(id, notice(fitted, polled: true))
            } else {
                forget(id)
                await host.end(id, fitted, dismissal: .standard)
                log.info("activity \(id, privacy: .public) ended with its tracker")
                return
            }
        }
    }
}
