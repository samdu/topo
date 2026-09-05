#if os(iOS)
import Foundation
import Observation
import TopoAuth
import TopoCore
import TopoTurn

/// The phone harness as the UI sees it: the transcript, the model setting, and one turn at a time.
/// The log is the shared CloudKit log, on the person's own Apple ID.
@MainActor
@Observable
final class Harness {
    static let modelKey = "model"

    private(set) var turns: [Turn] = []
    private(set) var notice: String?
    private(set) var busy = false
    private(set) var error: String?
    /// Where the turn in flight is, in words, so a slow step is seen to be a step. Nil when idle.
    private(set) var status: String?
    /// Turns said and not yet settled, oldest first: the head is the one in flight or the one
    /// that stopped the line, the rest wait behind it.
    var waiting: [String] { pending.map(\.text) }
    let device: DeviceID

    private let database: RecordingDatabase
    private let log: TurnLog
    private let ensureZone: @Sendable () async throws -> Void
    private let tokens: TokenProvider
    private var runner: TurnRunner?
    private var lease: PrimaryLease?
    private var inFlight: Task<Bool, Never>?
    /// The last answer from the Messages API: status, when, how long it took.
    private var lastAPI: (status: Int, at: Date, seconds: TimeInterval)?

    /// What the person said that is not settled yet, oldest first, each under the nonce it was
    /// first attempted with and written to disk before any attempt. So a relaunch after a lost
    /// acknowledgement sends the same words under the same nonce and gets the turn already
    /// written, and a turn said behind a long one survives the app being killed during it.
    private struct Outgoing: Codable, Equatable {
        var text: String
        var nonce: String
    }
    private static let outboxKey = "topo.harness.outbox"
    private var pending: [Outgoing] = [] {
        didSet {
            if pending.isEmpty { UserDefaults.standard.removeObject(forKey: Self.outboxKey) }
            else { UserDefaults.standard.set(try? JSONEncoder().encode(pending), forKey: Self.outboxKey) }
        }
    }
    private var outgoing: Outgoing? { pending.first }

    init(database: any RecordDatabase, tokens: TokenProvider, device: DeviceID = DeviceIdentity.current,
         ensureZone: @escaping @Sendable () async throws -> Void = { try await TopoCloudKit.ensureZone() }) {
        self.database = RecordingDatabase(database)
        self.tokens = tokens
        self.device = device
        self.ensureZone = ensureZone
        log = TurnLog(database: self.database)
        if let data = UserDefaults.standard.data(forKey: Self.outboxKey),
           let saved = try? JSONDecoder().decode([Outgoing].self, from: data) {
            pending = saved
        }
        // The single unsent turn an earlier build kept under its own key heads the line.
        let singleKey = "topo.harness.outgoing"
        if let data = UserDefaults.standard.data(forKey: singleKey) {
            if let single = try? JSONDecoder().decode(Outgoing.self, from: data), !pending.contains(single) {
                pending.insert(single, at: 0)
            }
            UserDefaults.standard.removeObject(forKey: singleKey)
        }
    }

    /// The app's harness: the shared CloudKit log and the keychain's tokens.
    static func standard(store: TokenStore = KeychainTokenStore()) -> Harness {
        Harness(database: TopoCloudKit.database(), tokens: StoredTokenProvider(store: store))
    }

    var model: ClaudeModel {
        get { UserDefaults.standard.string(forKey: Self.modelKey).flatMap(ClaudeModel.init(rawValue:)) ?? .default }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.modelKey) }
    }

    /// Sign-out: the turn in flight is cancelled and its result dropped, the runner and screen
    /// are cleared, and the next sign-in starts at the first question. The log itself stays where
    /// it is, in the person's own iCloud; nothing of it is on this device to remove.
    func forget() {
        inFlight?.cancel()
        inFlight = nil
        runner = nil
        lease = nil
        turns = []
        notice = nil
        error = nil
        status = nil
        busy = false
        pending = []
        UserDefaults.standard.removeObject(forKey: "firstRunAnswer")
        UserDefaults.standard.removeObject(forKey: "firstRunAnswered")
    }

    func refresh() async {
        do {
            let transcript = try await log.read()
            turns = transcript.ordered
            notice = TranscriptStore.notice(for: transcript)
        } catch {
            guard !TopoCloudKit.meansNoLogYet(error) else { turns = []; return }
            self.error = "Couldn't read the transcript: \(TranscriptStore.message(for: error))"
        }
    }

    /// One turn: the words go in the log, the reply comes back into it. Words said while a turn
    /// is in flight wait their turn and go next, in order, the same words twice being two turns;
    /// nothing said is dropped. A turn that never reached the log stops the line: it stays at the
    /// head and goes first next time, and what was said behind it waits.
    func send(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pending.append(Outgoing(text: text, nonce: UUID().uuidString))
        await drain()
    }

    /// Sends the line from its head, after a turn that stopped it or a launch that found it.
    func retry() async {
        await drain()
    }

    /// True when a turn is waiting to go and none is in flight: the line stopped on a failure.
    var hasWaiting: Bool { !busy && !pending.isEmpty }

    private func drain() async {
        guard !busy else { return }
        busy = true
        error = nil
        while let next = pending.first {
            let task = Task { await run(next) }
            inFlight = task
            let settled = await task.value
            // A sign-out cleared everything, this turn included; the line went with it.
            guard inFlight == task else { return }
            inFlight = nil
            guard settled else { break }
            if pending.first == next { pending.removeFirst() }
        }
        busy = false
        status = nil
    }

    /// True when the turn is settled: answered, or at least in the log with only the reply owed.
    /// False leaves it as the unsent turn.
    @discardableResult
    private func run(_ attempt: Outgoing) async -> Bool {
        let generation = inFlight
        let text = attempt.text
        do {
            if runner == nil {
                status = "Reaching iCloud…"
                try await ensureZone()
                runner = try await makeRunner()
            }
            guard let runner else { return false }
            let result = try await runner.run(text, model: model, nonce: attempt.nonce) { [weak self] step in
                await self?.show(step, generation: generation)
            }
            // A sign-out during the turn cleared the screen; this result is not for it.
            guard inFlight == generation, !Task.isCancelled else { return false }
            show(result.person)
            show(result.assistant)
            status = nil
            return true
        } catch is CancellationError {
            return false
        } catch TurnRunnerError.replyFailed(_, let underlying) {
            // The person's turn is in the log; only the reply is owed.
            guard inFlight == generation else { return false }
            error = Self.describe(underlying)
            await refresh()
            status = nil
            return true
        } catch TurnRunnerError.notPrimary(let outcome) {
            guard inFlight == generation else { return false }
            error = Self.describe(outcome)
            await refresh()
        } catch TokenProviderError.signedOut {
            guard inFlight == generation else { return false }
            error = "Signed out. Sign in again to continue."
        } catch {
            guard inFlight == generation else { return false }
            self.error = Self.describe(error)
            await refresh()
        }
        status = nil
        return false
    }

    /// A step of the turn in flight, as words on the screen. The person's turn shows the moment
    /// it is in the log, before the model has answered.
    private func show(_ step: TurnRunner.Progress, generation: Task<Bool, Never>?) {
        guard inFlight == generation else { return }
        switch step {
        case .takingLease: status = "Checking this device is primary…"
        case .saving: status = "Saving what you said…"
        case .asking(let person):
            show(person)
            status = "Asking \(model.displayName)…"
        case .savingReply: status = "Saving the reply…"
        }
    }

    private func show(_ turn: Turn) {
        guard !turns.contains(where: { $0.ref == turn.ref }) else { return }
        turns.append(turn)
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case TurnRunnerError.displaced:
            "Another device became primary while Claude was answering; it will answer."
        case MessagesAPIError.refused:
            "Claude declined that one."
        case MessagesAPIError.http(let status, let message):
            message ?? "Claude answered \(status)."
        case TokenProviderError.signedOut:
            "Signed out. Sign in again to continue."
        default:
            TranscriptStore.message(for: error)
        }
    }

    private func makeRunner() async throws -> TurnRunner {
        let writer = try await log.writer(for: device)
        let lease = PrimaryLease(database: database, device: device, endpoint: nil, probe: NoSocketProbe())
        self.lease = lease
        var api = MessagesAPI(tokens: tokens)
        api.onResponse = { [weak self] status, seconds in
            Task { @MainActor in self?.lastAPI = (status, Date(), seconds) }
        }
        return TurnRunner(log: log, writer: writer, lease: lease, api: api)
    }

    /// What the diagnostics screen shows: everything a failed or silent turn could be blamed on.
    struct Diagnostics {
        var rows: [(String, String)]
    }

    func diagnostics() async -> Diagnostics {
        var rows: [(String, String)] = []
        rows.append(("Device", device.rawValue))
        rows.append(("Container", TopoCloudKit.containerIdentifier))
        rows.append(("iCloud account", await TopoCloudKit.accountStatus()))
        rows.append(("Turn in flight", busy ? (status ?? "yes") : "none"))
        rows.append(("Waiting to send", pending.isEmpty ? "none" : pending.map(\.text).joined(separator: " | ")))
        rows.append(("Last error shown", error ?? "none"))
        if let lease {
            let primary = await lease.isPrimary()
            if let held = await lease.held {
                rows.append(("Lease", "\(held.holder.rawValue) epoch \(held.epoch), expires \(Self.clock(held.expiresAt))"))
            } else {
                rows.append(("Lease", "not held by this device"))
            }
            rows.append(("This device primary", primary ? "yes" : "no"))
        } else {
            rows.append(("Lease", "not yet claimed; no turn has run"))
        }
        if let record = try? await database.fetch(Lease.recordID), let server = Lease(record: record) {
            rows.append(("Lease record", "\(server.holder.rawValue) epoch \(server.epoch), expires \(Self.clock(server.expiresAt))"))
        } else {
            rows.append(("Lease record", database.lastError == nil ? "none" : "could not read"))
        }
        rows.append(("Last CloudKit error", database.lastError.map { "\(Self.clock($0.at)) \($0.message)" } ?? "none"))
        rows.append(("Last CloudKit success", database.lastSuccess.map(Self.clock) ?? "none"))
        rows.append(("Last API answer", lastAPI.map { "\($0.status) at \(Self.clock($0.at)), \(Int($0.seconds))s" } ?? "none"))
        rows.append(("Claude token", await Self.describeToken(tokens)))
        rows.append(("Model", model.displayName))
        rows.append(("Turns on screen", "\(turns.count)"))
        return Diagnostics(rows: rows)
    }

    private static func describeToken(_ tokens: TokenProvider) async -> String {
        guard let stored = tokens as? StoredTokenProvider else { return "test provider" }
        switch await stored.state() {
        case .signedOut: return "none: signed out"
        case .expired(let at): return "expired \(clock(at)); refreshes on the next turn"
        case .valid(until: let at): return "valid until \(clock(at))"
        }
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    static func describe(_ outcome: LeaseOutcome) -> String {
        switch outcome {
        case .primary: "This device is primary."
        case .held(let by): "\(by.holder.rawValue) is primary right now."
        case .unreachable(let lease): "\(lease.holder.rawValue) took over and can't be reached; try again shortly."
        case .contended: "Another device is claiming primary; try again."
        }
    }
}

/// The database with a memory: the last error any call raised and the last time one worked,
/// for the diagnostics screen. Everything else passes straight through.
final class RecordingDatabase: RecordDatabase, @unchecked Sendable {
    struct Failure { var at: Date; var message: String }

    private let base: any RecordDatabase
    private let lock = NSLock()
    private var _lastError: Failure?
    private var _lastSuccess: Date?

    init(_ base: any RecordDatabase) { self.base = base }

    var lastError: Failure? { lock.withLock { _lastError } }
    var lastSuccess: Date? { lock.withLock { _lastSuccess } }

    func save(_ records: [Record]) async throws -> [Record] { try await noting { try await base.save(records) } }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await noting { try await base.fetch(ids) } }
    func query(_ query: RecordQuery) async throws -> [Record] { try await noting { try await base.query(query) } }

    private func noting<T>(_ call: () async throws -> T) async throws -> T {
        do {
            let value = try await call()
            lock.withLock { _lastSuccess = Date() }
            return value
        } catch {
            // A compare-and-set that lost is the protocol working, not a fault.
            switch error {
            case RecordDatabaseError.serverRecordChanged, RecordDatabaseError.unknownItem: break
            default: lock.withLock { _lastError = Failure(at: Date(), message: Self.describe(error)) }
            }
            throw error
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case RecordDatabaseError.unavailable(let underlying): "unavailable: \(underlying)"
        case RecordDatabaseError.rejected(let underlying): "rejected: \(underlying)"
        default: "\(error)"
        }
    }
}
#endif
