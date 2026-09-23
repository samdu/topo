import Foundation

/// A process the session talks to: the resident Claude Code in the guest, or a test's scripted one.
public protocol ResidentProcess: AnyObject, Sendable {
    /// Its pid in the guest, which names this process among the ones a session starts.
    var pid: Int32 { get }
    /// stdout, line by line, finishing when the process has let go of it.
    var lines: AsyncStream<String> { get }
    /// The end of what it wrote to stderr.
    var errors: String { get }
    /// Writes one line to its stdin.
    func write(_ line: String) async throws
    /// Ends it and everything it started, and says whether that was confirmed within `bound`.
    func end(within bound: Duration) async -> GuestProcess.Termination
}

extension GuestProcess: ResidentProcess {
    /// The resident Claude Code is the only program the guest runs, so its end is every guest
    /// task's but init's: what it started is ended whatever became of the parent links between
    /// them.
    public func end(within bound: Duration) async -> Termination { await terminate(within: bound) }
}

/// What starts the resident process: resuming a session by its id, or starting a fresh one.
public protocol ResidentLauncher: Sendable {
    func launch(resume session: String?) async throws -> any ResidentProcess
}

/// The one session id kept on disk: the id of the conversation the next process resumes. A file of
/// its own beside the guest's home, so it survives the app being ended in the background.
public struct SessionFile: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let id = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    public func save(_ id: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(id.utf8).write(to: url, options: .atomic)
    }

    public func clear() { try? FileManager.default.removeItem(at: url) }
}

/// What a sleep is: `Task.sleep` in the app, a clock a test advances by hand in the suite.
public typealias Sleep = @Sendable (Duration) async throws -> Void

/// The resident Claude Code, owned by one actor: started on the foreground, a turn at a time over
/// stream-json, given the grace iOS allows on the way out and then ended deliberately, and resumed
/// by its session id on the next foreground.
///
/// Every lifecycle call carries a generation, the lifecycle's count of foregrounds and
/// backgrounds, and a call older than one already seen is stale and changes nothing — so a
/// background that reaches the actor after the foreground that followed it cannot end the
/// process that foreground wants. A startup still pending when the app goes to the background
/// ends the process it made the moment it lands; a teardown still running when the app comes back
/// ends only the process it was started for, and the replacement starts once it is done.
public actor GuestSession {
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        /// A turn is in flight; turns are never interleaved.
        case turnInFlight
        /// Nothing is resident to take the turn: the app is in the background, or the process is
        /// starting, stopping or failed to start.
        case notResident

        public var description: String {
            switch self {
            case .turnInFlight: "a turn is already in flight"
            case .notResident: "Claude Code is not resident"
            }
        }
    }

    /// How a turn ended.
    public enum TurnEnd: Sendable, Equatable {
        /// Its result arrived and was not an error.
        case answered(StreamEvent.TurnResult)
        /// It ended without an answer.
        case failed(TurnFailure)
        /// The app went to the background and the process was ended before its result arrived.
        /// Nothing sends it again; whoever sent it decides.
        case abandoned
    }

    public enum TurnFailure: Sendable, Equatable, CustomStringConvertible {
        /// Claude Code ended the turn with an error result.
        case result(StreamEvent.TurnResult)
        /// The process let go of its stdout before the turn's result, with the end of its stderr.
        case exited(String)
        /// Nothing arrived for this long, so the turn was ended and the process restarted.
        case silent(Duration)
        /// The turn could not be written to the process.
        case input(String)

        public var description: String {
            switch self {
            case .result(let result):
                let why = result.text ?? result.errors.joined(separator: "; ")
                return "error result (\(result.subtype)): \(why)"
            case .exited(let errors):
                let tail = errors.trimmingCharacters(in: .whitespacesAndNewlines)
                return "the process ended mid-turn" + (tail.isEmpty ? "" : ": \(tail.suffix(300))")
            case .silent(let bound): return "nothing from the process for \(bound)"
            case .input(let why): return "the turn could not be written: \(why)"
            }
        }
    }

    /// One turn as it happens: its events, then its end, then the stream finishes.
    public enum TurnUpdate: Sendable, Equatable {
        case event(StreamEvent)
        case ended(TurnEnd)
    }

    /// What the way out came to.
    public enum BackgroundOutcome: Sendable, Equatable {
        /// Nothing was resident, and nothing was started.
        case nothingResident
        /// The app came back before the teardown began, so the process stayed.
        case kept
        /// The process was ended. `turn` is what became of a turn in flight when the app left:
        /// finished inside the grace, or abandoned at the teardown point; nil when none was.
        case ended(turn: TurnFate?, termination: GuestProcess.Termination)
        /// iOS's background time ran out before the teardown answered; the background task was
        /// ended with it still running (`GuestLifecycle`, never the session).
        case outOfTime
    }

    public enum TurnFate: Sendable, Equatable {
        case finished
        case abandoned
    }

    /// Where the session stands, for a test or a log line.
    public enum Phase: Sendable, Equatable {
        case idle
        case starting
        case resident
        case stopping
    }

    /// How long a turn may go with nothing at all from the process before it is ended with an
    /// error and the process restarted: three minutes, since a long answer arrives as one message.
    public static let defaultTurnBound: Duration = .seconds(180)

    private let launcher: any ResidentLauncher
    private let store: SessionFile
    private let sleep: Sleep
    private let turnBound: Duration
    private let log: @Sendable (String) -> Void

    private var phase: State = .idle
    private var inForeground = false
    private var generation = 0
    private var startTask: Task<Void, Never>?
    /// The ending of a process under way, which a background call waits out before it answers.
    private var teardown: Task<GuestProcess.Termination, Never>?
    private var readiness: [CheckedContinuation<Void, Error>] = []
    private var backgroundWait: CheckedContinuation<Wake, Never>?
    private var backgroundTimer: Task<Void, Never>?
    /// iOS's expiration handler has fired for this background: whatever waits stops waiting, and
    /// a teardown begun from here on is bounded by what the handler leaves.
    private var expired = false

    private enum State {
        case idle
        case starting
        case resident(Resident)
        case stopping
    }

    private enum Wake {
        case turnEnded
        case deadline
        case foreground
    }

    /// The resident process and what the session knows of it. Read and written on the actor
    /// alone; the tasks that hold one only hand it back to the actor, which compares it by identity.
    private final class Resident: @unchecked Sendable {
        let process: any ResidentProcess
        /// The session id it was started to resume, nil for a fresh one.
        let resumed: String?
        var reader: Task<Void, Never>?
        var turn: Turn?
        /// Whether it ever began a turn (`system/init`), which a resume that failed never does.
        var began = false
        /// A result that arrived with no turn in flight — what a failed resume writes before it exits.
        var strayResult: StreamEvent.TurnResult?

        init(process: any ResidentProcess, resumed: String?) {
            self.process = process
            self.resumed = resumed
        }
    }

    /// A turn in flight, on the actor alone as `Resident` is.
    private final class Turn: @unchecked Sendable {
        let continuation: AsyncStream<TurnUpdate>.Continuation
        /// Counts every line while the turn is in flight, so the watchdog can tell silence.
        var ticks = 0
        var watchdog: Task<Void, Never>?

        init(continuation: AsyncStream<TurnUpdate>.Continuation) { self.continuation = continuation }
    }

    public init(launcher: any ResidentLauncher, store: SessionFile,
                turnBound: Duration = GuestSession.defaultTurnBound,
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.launcher = launcher
        self.store = store
        self.turnBound = turnBound
        self.sleep = sleep
        self.log = log
    }

    // MARK: - What the caller sees

    public var currentPhase: Phase {
        switch phase {
        case .idle: .idle
        case .starting: .starting
        case .resident: .resident
        case .stopping: .stopping
        }
    }

    /// The pid of the resident process, nil when none is resident.
    public var residentPID: Int32? {
        if case .resident(let resident) = phase { return resident.process.pid }
        return nil
    }

    /// Whether a turn is in flight.
    public var turnInFlight: Bool {
        if case .resident(let resident) = phase { return resident.turn != nil }
        return false
    }

    /// The session id the next process resumes, as kept on disk.
    public var sessionID: String? { store.load() }

    // MARK: - The lifecycle

    /// The app came to the foreground: the resident process starts, or — when the app is back
    /// before a teardown began — the one still there is kept. `generation` orders this against the
    /// lifecycle's other calls; nil takes the next one.
    public func foreground(generation given: Int? = nil) {
        guard admit(given) else { return }
        inForeground = true
        expired = false
        wakeBackground(.foreground)
        if case .idle = phase { startResident() }
    }

    /// The app went to the background with `budget` of grace to spend: a turn in flight is given
    /// until then to finish, and the process is ended when it does, at the budget, or at once
    /// when no turn is in flight; a startup still pending is ended as it lands. Returns once
    /// nothing is resident, with what that came to — or at once with `kept` when the app came back
    /// before the teardown began, or when this call is older than one already seen.
    public func background(budget: Duration, generation given: Int? = nil) async -> BackgroundOutcome {
        guard admit(given) else { return .kept }
        let mine = generation
        inForeground = false
        // A start still pending ends what it made as it lands; a teardown already under way (a
        // restart, a process that died) is waited out, so nothing is resident when this answers.
        if let startTask { await startTask.value }
        if let teardown { _ = await teardown.value }
        guard generation == mine, !inForeground else { return .kept }
        guard case .resident(let resident) = phase else { return .nothingResident }
        var fate: TurnFate?
        if resident.turn != nil {
            fate = .finished
            let wake = await waitForTurn(budget: budget)
            if wake == .foreground || generation != mine || inForeground { return .kept }
        }
        if case .stopping = phase, let teardown {
            // The turn ended in a failure that is already restarting the process: that teardown
            // is this one, and with the app away it starts nothing after.
            return .ended(turn: fate, termination: await teardown.value)
        }
        guard case .resident(let still) = phase, still === resident else { return .nothingResident }
        if let turn = still.turn {
            fate = .abandoned
            finish(turn, of: still, with: .abandoned)
        }
        let termination = await end(still, reason: fate == .abandoned ? "the teardown point, turn abandoned" : "the background",
                                    restart: true).value
        return .ended(turn: fate, termination: termination)
    }

    /// The grace is ending now (iOS's expiration handler): a teardown waiting on a turn stops
    /// waiting and ends the process, and any teardown from here on is bounded by what the handler
    /// leaves. The lifecycle holds the background task until the teardown answers.
    public func expire(generation given: Int? = nil) {
        // An expiry older than a foreground already seen belongs to a background that is over.
        guard (given ?? generation) >= generation else { return }
        expired = true
        wakeBackground(.deadline)
    }

    /// Returns once the resident process is up, starting it if the app is in the foreground and
    /// nothing is; throws what the start failed with, or `notResident` in the background.
    public func ready() async throws {
        switch phase {
        case .resident: return
        case .idle:
            guard inForeground else { throw Refusal.notResident }
            startResident()
        case .starting, .stopping:
            guard inForeground else { throw Refusal.notResident }
        }
        try await withCheckedThrowingContinuation { readiness.append($0) }
    }

    /// Sends the person's `text` as a turn. Refused while another turn is in flight and while
    /// nothing is resident; otherwise the turn's events arrive on the stream, then how it ended.
    public func send(_ text: String) async throws -> AsyncStream<TurnUpdate> {
        guard case .resident(let resident) = phase else { throw Refusal.notResident }
        guard resident.turn == nil else { throw Refusal.turnInFlight }
        let (stream, continuation) = AsyncStream<TurnUpdate>.makeStream()
        let turn = Turn(continuation: continuation)
        resident.turn = turn
        turn.watchdog = watch(turn, of: resident)
        do {
            try await resident.process.write(StreamJSON.userTurn(text))
        } catch {
            if resident.turn === turn {
                finish(turn, of: resident, with: .failed(.input(String(describing: error))))
                restart(resident, reason: "a turn could not be written")
            }
        }
        return stream
    }

    // MARK: - Inside

    /// Whether a lifecycle call is current: no older than the newest seen. A call with no
    /// generation takes the next one.
    private func admit(_ given: Int?) -> Bool {
        let next = given ?? generation + 1
        guard next > generation else { return false }
        generation = next
        return true
    }

    private func startResident() {
        guard case .idle = phase, inForeground else { return }
        let resume = store.load()
        phase = .starting
        log(resume.map { "starting Claude Code, resuming \($0)" } ?? "starting Claude Code, a fresh session")
        let launcher = launcher
        startTask = Task {
            let result: Result<any ResidentProcess, Error>
            do { result = .success(try await launcher.launch(resume: resume)) } catch { result = .failure(error) }
            await self.launched(result, resume: resume)
        }
    }

    private func launched(_ result: Result<any ResidentProcess, Error>, resume: String?) async {
        startTask = nil
        switch result {
        case .failure(let error):
            phase = .idle
            log("Claude Code did not start: \(error)")
            settleReadiness(.failure(error))
        case .success(let process):
            let resident = Resident(process: process, resumed: resume)
            guard inForeground else {
                // The app left while the start was pending: nothing may stay resident.
                settleReadiness(.failure(Refusal.notResident))
                _ = await end(resident, reason: "a start that landed in the background", restart: true).value
                return
            }
            phase = .resident(resident)
            resident.reader = Task { [weak self] in
                for await line in process.lines {
                    await self?.received(line, from: resident)
                }
                await self?.closed(resident)
            }
            settleReadiness(.success(()))
        }
    }

    private func settleReadiness(_ result: Result<Void, Error>) {
        let waiting = readiness
        readiness = []
        waiting.forEach { $0.resume(with: result) }
    }

    private func received(_ line: String, from resident: Resident) {
        // A process that is no longer the resident one — ended, or being ended — speaks to nobody.
        guard case .resident(let current) = phase, current === resident else { return }
        resident.turn?.ticks += 1
        for event in StreamJSON.events(in: line) {
            switch event {
            case .started(let session, _):
                resident.began = true
                keep(session)
            case .result(let result):
                if let session = result.session, resident.began { keep(session) }
            default:
                break
            }
            guard let turn = resident.turn else {
                if case .result(let result) = event { resident.strayResult = result }
                continue
            }
            turn.continuation.yield(.event(event))
            if case .result(let result) = event {
                finish(turn, of: resident, with: result.isError ? .failed(.result(result)) : .answered(result))
            }
        }
    }

    private func keep(_ session: String) {
        if store.load() != session { store.save(session) }
    }

    /// The process let go of stdout: it has exited, or is about to.
    private func closed(_ resident: Resident) async {
        guard case .resident(let current) = phase, current === resident else { return }
        let errors = resident.process.errors
        let midTurn = resident.turn != nil
        if let turn = resident.turn {
            finish(turn, of: resident, with: .failed(.exited(errors)))
        }
        if let resumed = resident.resumed, !resident.began {
            // A resume that failed exits before it begins anything, having said why.
            let why = resident.strayResult.map { ($0.errors + [$0.text ?? ""]).joined(separator: " ") } ?? ""
            let reason = [why, errors].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "it exited before beginning"
            log("the resume of \(resumed) failed (\(reason.prefix(300))); starting a fresh session")
            if store.load() == resumed { store.clear() }
            restart(resident, reason: "a resume that failed")
            return
        }
        log("Claude Code exited\(errors.isEmpty ? "" : ": \(errors.suffix(300))")")
        // One that died under a turn is replaced, resuming what it began, so the next turn has a
        // process to go to; one that died idle is not started again unless something is waiting
        // for it, so a process that dies at every start does not loop — the next `ready` starts it.
        _ = end(resident, reason: midTurn ? "an exit mid-turn" : "an exit", restart: midTurn)
    }

    /// Ends `resident` and starts a replacement if the app is in the foreground.
    private func restart(_ resident: Resident, reason: String) {
        guard case .resident(let current) = phase, current === resident else { return }
        _ = end(resident, reason: reason, restart: true)
    }

    /// Ends `resident`, confirming it, as the one teardown under way. Once it is done the session
    /// is idle, and a replacement starts if the app is in the foreground and `restart` says so, or
    /// if a caller is waiting for one. Whatever the app did meanwhile, this ends only `resident`.
    private func end(_ resident: Resident, reason: String, restart: Bool) -> Task<GuestProcess.Termination, Never> {
        phase = .stopping
        let bound = expired ? GraceBudget.expiredTeardownBound : GraceBudget.teardownBound
        let task = Task {
            let termination = await resident.process.end(within: bound)
            await self.ended(termination, reason: reason, restart: restart)
            return termination
        }
        teardown = task
        return task
    }

    private func ended(_ termination: GuestProcess.Termination, reason: String, restart: Bool) {
        log("ended after \(reason): \(termination)")
        teardown = nil
        phase = .idle
        if inForeground && (restart || !readiness.isEmpty) { startResident() }
    }

    private func finish(_ turn: Turn, of resident: Resident, with end: TurnEnd) {
        guard resident.turn === turn else { return }
        resident.turn = nil
        turn.watchdog?.cancel()
        turn.continuation.yield(.ended(end))
        turn.continuation.finish()
        wakeBackground(.turnEnded)
    }

    /// Ends the turn with an error, and restarts the process, once nothing has arrived for the
    /// turn's bound.
    private func watch(_ turn: Turn, of resident: Resident) -> Task<Void, Never> {
        let bound = turnBound, sleep = sleep
        return Task { [weak self] in
            while true {
                guard let seen = await self?.ticks(of: turn, in: resident) else { return }
                do { try await sleep(bound) } catch { return }
                guard let self, await self.silent(turn, in: resident, since: seen) else { continue }
                return
            }
        }
    }

    private func ticks(of turn: Turn, in resident: Resident) -> Int? {
        resident.turn === turn ? turn.ticks : nil
    }

    /// Whether `turn` heard nothing since `seen`; if so it is ended and the process restarted.
    private func silent(_ turn: Turn, in resident: Resident, since seen: Int) -> Bool {
        guard resident.turn === turn else { return true }
        guard turn.ticks == seen else { return false }
        log("turn silent for \(turnBound); restarting Claude Code")
        finish(turn, of: resident, with: .failed(.silent(turnBound)))
        restart(resident, reason: "a silent turn")
        return true
    }

    private func waitForTurn(budget: Duration) async -> Wake {
        if expired { return .deadline }
        let sleep = sleep
        backgroundTimer = Task { [weak self] in
            do { try await sleep(budget) } catch { return }
            await self?.wakeBackground(.deadline)
        }
        let wake = await withCheckedContinuation { backgroundWait = $0 }
        backgroundTimer?.cancel()
        backgroundTimer = nil
        return wake
    }

    private func wakeBackground(_ wake: Wake) {
        guard let waiting = backgroundWait else { return }
        backgroundWait = nil
        waiting.resume(returning: wake)
    }
}

extension GuestSession.BackgroundOutcome: CustomStringConvertible {
    /// The line the app logs for the way out. An unconfirmed termination says NOT confirmed and
    /// carries the termination's own account of what stayed.
    public var description: String {
        switch self {
        case .nothingResident: return "nothing resident"
        case .kept: return "kept: the app came back before the teardown"
        case .ended(let turn, let termination):
            let fate = switch turn {
            case .finished: "the turn in flight finished inside the grace"
            case .abandoned: "the turn in flight was abandoned at the teardown point"
            case nil: "no turn in flight"
            }
            let confirmed = termination.confirmed ? "confirmed" : "NOT confirmed"
            return "ended, \(fate); termination \(confirmed): \(termination)"
        case .outOfTime:
            return "background time ran out before the termination answered; the background task was ended with the teardown still running"
        }
    }
}
