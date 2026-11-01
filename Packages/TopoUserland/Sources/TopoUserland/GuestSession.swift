import Foundation
import TopoCore

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

/// What starts the resident process: resuming a session by its id, or starting a fresh one, asking
/// every turn of `model` (nil leaves the model to Claude Code), and telling it whether its memory
/// is mounted (`memory`; nil tells it nothing), and with `note`, what became of the process before
/// it when the way out cut that one short (`GuestSession.Cut`).
public protocol ResidentLauncher: Sendable {
    func launch(resume session: String?, model: String?, memory: Bool?, compactAt: Int?, note: String?) async throws -> any ResidentProcess
}

/// How an idle resident is kept across a background rather than ended: every guest task stopped
/// on the way out, and on the way back the listeners it was launched toward taken back on the very
/// ports it was told, then every task continued. The app's (`GuestResident`); a test's double.
public protocol GuestFreezer: Sendable {
    /// Stops the guest; true once every task is parked at the stop. A false is a guest that may
    /// still run one more step on the way back, which is never continued: the session ends it.
    func stop() async -> Bool
    /// Takes back the ports the resident was launched toward and brings the forwarder up, sending
    /// nothing to the guest; false when a port could not be taken back or the phone has changed
    /// time zone since the launch.
    func prepare() async -> Bool
    /// Sends the continue to every guest task, and does not wait for it to land. The session calls
    /// it on its own actor inside the gate that judges the process still wanted, so a sign-out or a
    /// login never begins between that judgement and the continue: it takes the kernel's task and
    /// signal locks, which no guest path holds across a wait, and nothing more. False when it could
    /// not be sent.
    func continueNow() -> Bool
    /// True once no guest task is parked at the stop; false at its bound with one still parked.
    func confirm() async -> Bool
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

/// What the way out cut short, kept on disk beside the session id until a process told of it has
/// begun: the next one is told, in its system prompt, since nothing of a process ended outside a
/// turn reaches the conversation any other way.
public struct CutFile: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> GuestSession.Cut? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GuestSession.Cut.self, from: data)
    }

    public func save(_ cut: GuestSession.Cut) {
        guard let data = try? JSONEncoder().encode(cut) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
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
///
/// The model the process asks is the session's (`use(model:)`), and so is what it is told of its
/// memory (`use(memory:)`) and whether the next process resumes the kept conversation
/// (`forgetSession(then:)`). Any of them changing makes the resident process stale. A change of model
/// or of the memory replaces it at the next idle moment: at once when no turn is in flight, and
/// otherwise once the turn has ended, never in the middle of one. A forgotten conversation — a
/// sign-out — ends it at once, abandoning a turn in flight.
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
        /// finished in the background, or abandoned at the teardown point; nil when none was.
        case ended(turn: TurnFate?, termination: GuestProcess.Termination)
        /// The idle process was frozen rather than ended, to be continued on the way back.
        case frozen
        /// iOS's background time ran out before the teardown answered; the background task was
        /// ended with it still running (`GuestLifecycle`, never the session).
        case outOfTime
        /// The continued-processing task carrying the way out expired, and the grace took it over.
        case handedToGrace
        /// The continued-processing task carrying the way out expired and iOS refused the grace:
        /// the process is ended at once.
        case graceRefused
        /// The continued-processing task carrying the way out expired, and a tick later the grace
        /// iOS answered an identifier for was still not to be read: the process is ended at once.
        case graceUnread
    }

    public enum TurnFate: Sendable, Equatable {
        case finished
        case abandoned
    }

    /// A process the way out ended with something of its own still running: a turn it had not
    /// answered, or tasks it had started in the background, which went with it.
    public struct Cut: Codable, Sendable, Equatable {
        /// When the app went behind another app, and when the way out decided to end the process.
        public let left: Date
        public let ended: Date
        /// Whether a turn was in flight, abandoned at the teardown point.
        public let turn: Bool
        /// How many background tasks Claude Code said it had running.
        public let backgroundTasks: Int
        /// Whether the process was frozen at `ended` rather than ended: a cut kept then is read
        /// only when iOS ended the app while it was away, since the way back clears it.
        public let frozen: Bool?

        public init(left: Date, ended: Date, turn: Bool, backgroundTasks: Int, frozen: Bool? = nil) {
            self.left = left
            self.ended = ended
            self.turn = turn
            self.backgroundTasks = backgroundTasks
            self.frozen = frozen
        }

        /// What the next process is told: when, how long after the app left, and what went.
        public var words: String {
            let at = left.formatted(Date.ISO8601FormatStyle().year().month().day().dateSeparator(.dash)
                .time(includingFractionalSeconds: false).timeSeparator(.colon))
            let after = max(Int(ended.timeIntervalSince(left).rounded()), 0)
            var went: [String] = []
            if turn { went.append("the turn you were answering, which the person will be asked about again") }
            if backgroundTasks > 0 {
                went.append(backgroundTasks == 1 ? "a background task you had started"
                                                 : "\(backgroundTasks) background tasks you had started")
            }
            // A turn cut is the time behind another app ending, which iOS's allowance running out
            // and the person stopping it from the pill both are, and nothing here tells them apart;
            // with none in flight the process was ended as every one is once its reply is done and
            // Topo is off the screen.
            if frozen == true {
                let tasks = backgroundTasks == 1 ? "a background task you had started" : "\(backgroundTasks) background tasks you had started"
                return "Your last process was cut short. Topo went behind another app at \(at) UTC, \(after) seconds later "
                    + "your process was frozen with \(tasks) still running, and iOS ended the app while it was away. "
                    + "Whatever those were doing did not finish; check before relying on anything they were to write, "
                    + "and tell the person what did not get done."
            }
            let why = turn ? "the time Topo had behind another app ended (iOS's allowance ran out, or the person stopped it) and the process was ended"
                           : "the process was ended, as every one is once its reply is done and Topo is not on the screen"
            return "Your last process was cut short. Topo went behind another app at \(at) UTC, and \(after) seconds "
                + "later \(why). Ended with it: \(went.joined(separator: "; ")). "
                + "Whatever those were doing did not finish; check before relying on anything they were to write, "
                + "and tell the person what did not get done."
        }
    }

    /// Where the session stands, for a test or a log line.
    public enum Phase: Sendable, Equatable {
        case idle
        case starting
        case resident
        /// Kept across a background, stopped: no turn goes to it until it is continued.
        case frozen
        case stopping
    }

    /// How long a turn may go with nothing at all from the process before it is ended with an
    /// error and the process restarted: three minutes, since a long answer arrives as one message.
    public static let defaultTurnBound: Duration = .seconds(180)

    private let launcher: any ResidentLauncher
    /// Keeps an idle process across a background; nil ends it there instead.
    private let freezer: (any GuestFreezer)?
    /// The stop under way, which a continue waits out.
    private var freezing: Task<Bool, Never>?
    /// The continue under way, which a way out waits out.
    private var thawing: Task<Void, Never>?
    /// The cut kept as the process was frozen, cleared if it is continued.
    private var frozenCut: Cut?
    /// The frozen process whose continue has been sent and is not yet confirmed: it runs, so a way
    /// out, a sign-out or a login waits for the thaw and ends it as the running process it is.
    private var continuedThaw: Resident?
    /// Whether Claude Code's login is still there: a frozen process is continued only while it is.
    private let signedIn: @Sendable () -> Bool
    private let store: SessionFile
    private let cuts: CutFile
    /// The session's clock, which the lifecycle reads for the moment the app left.
    public nonisolated let now: @Sendable () -> Date
    /// The model every process is started with.
    private var model: String?
    /// What every process is told of its memory: mounted, not, or nothing.
    private var memory: Bool?
    /// The share of the window every process is told to compact at, or nil for Claude Code's own.
    private var compactAt: Int?
    /// Counts `forgetSession(then:)`: a process started under an older count holds a conversation
    /// that has been forgotten.
    private var conversation = 0
    /// The next process starts a fresh session rather than resuming the kept one.
    private var freshNext = false
    /// Sign-outs and logins under way: while any is, no process starts (`forgetSession(then:)`,
    /// `withoutResident(_:)`).
    private var holds = 0
    private let sleep: Sleep
    private let turnBound: Duration
    private let log: @Sendable (String) -> Void
    /// The id of the `initialize` request each launch writes first, whose answer marks the process
    /// ready.
    static let readyRequest = "topo-ready"
    /// How the line a kept cut is logged with begins; the app keeps that line on disk (`GuestResident.log`).
    public static let cutLine = "the way out cut short"

    private var phase: State = .idle
    private var inForeground = false
    private var generation = 0
    private var startTask: Task<Void, Never>?
    /// The ending of a process under way, which a background call waits out before it answers.
    private var teardown: Task<GuestProcess.Termination, Never>?
    /// How the last teardown ended. Every teardown signals every guest task, so the newest
    /// says whether anything of any process ended before it may still be running.
    private var lastTermination: GuestProcess.Termination?
    private var readiness: [CheckedContinuation<Void, Error>] = []
    private var backgroundWait: CheckedContinuation<Wake, Never>?
    private var backgroundTimer: Task<Void, Never>?
    /// iOS's expiration handler has fired for this background: whatever waits stops waiting, and
    /// a teardown begun from here on is bounded by what the handler leaves.
    private var expired = false
    /// The deadline a background with no budget of its own was given since (`limit`), for the
    /// background of `limitGeneration`.
    private var limited: Duration?
    private var limitGeneration: Int?

    private enum State {
        case idle
        case starting
        case resident(Resident)
        case frozen(Resident)
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
        /// The model it was started with, what it was told of its memory, and the conversation
        /// count it was started under.
        let model: String?
        let memory: Bool?
        let compactAt: Int?
        let conversation: Int
        var reader: Task<Void, Never>?
        var turn: Turn?
        /// Whether it ever began a turn (`system/init`), which a resume that failed never does.
        var began = false
        /// A result that arrived with no turn in flight — what a failed resume writes before it exits.
        var strayResult: StreamEvent.TurnResult?
        /// How many background tasks it last said it had running.
        var backgroundTasks = 0
        /// The cut it was told of at its launch, cleared from disk once it has begun.
        var told: Cut?
        /// Whether it has answered the launch's `initialize`.
        var ready = false

        init(process: any ResidentProcess, resumed: String?, model: String?, memory: Bool?, compactAt: Int?, conversation: Int) {
            self.compactAt = compactAt
            self.process = process
            self.resumed = resumed
            self.model = model
            self.memory = memory
            self.conversation = conversation
        }
    }

    /// A turn in flight, on the actor alone as `Resident` is.
    private final class Turn: @unchecked Sendable {
        let continuation: AsyncStream<TurnUpdate>.Continuation
        /// The uuid the input was written with, which Claude Code echoes as the turn that answers
        /// it begins (`StreamEvent.received`).
        let id: String
        /// Whether that echo has come. Until it has, what Claude Code writes is a turn of its own
        /// (`held`), and a result ends that turn, not this one.
        var begun = false
        /// What has come since the last `system/init` while the turn has not begun: handed to the
        /// turn at its echo, which comes after its own init, and dropped at a result.
        var held: [StreamEvent] = []
        /// Counts every line while the turn is in flight, so the watchdog can tell silence.
        var ticks = 0
        var watchdog: Task<Void, Never>?
        /// Callers of `settle()` waiting for the turn to end, whoever is listening to it.
        var settling: [CheckedContinuation<Void, Never>] = []

        init(continuation: AsyncStream<TurnUpdate>.Continuation, id: String) {
            self.continuation = continuation
            self.id = id
        }
    }

    /// `cuts` is where a cut is kept for the next process, beside `store` unless given.
    public init(launcher: any ResidentLauncher, store: SessionFile, cuts: CutFile? = nil, freezer: (any GuestFreezer)? = nil,
                model: String? = nil, memory: Bool? = nil,
                compactAt: Int? = nil, now: @escaping @Sendable () -> Date = Date.init,
                turnBound: Duration = GuestSession.defaultTurnBound,
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
                signedIn: @escaping @Sendable () -> Bool = { true },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.launcher = launcher
        self.freezer = freezer
        self.signedIn = signedIn
        self.store = store
        self.cuts = cuts ?? CutFile(url: store.url.deletingLastPathComponent().appendingPathComponent(".guest-cut.json"))
        self.now = now
        self.model = model
        self.memory = memory
        self.compactAt = compactAt
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
        case .frozen: .frozen
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

    /// The model processes are started with.
    public var currentModel: String? { model }

    /// What processes are told of their memory.
    public var currentMemory: Bool? { memory }

    // MARK: - What the process is started with

    /// Every process from here on asks `model`. A resident process started with another is
    /// replaced at the next idle moment: now if no turn is in flight, otherwise once it ends.
    public func use(model: String?) {
        guard model != self.model else { return }
        self.model = model
        log("the model is now \(model ?? "Claude Code's own"); the resident process is replaced once idle")
        renewIfStale()
    }

    /// What processes are told to compact at.
    public var currentCompactAt: Int? { compactAt }

    /// Every process from here on compacts at `compactAt` percent of its window, or at Claude
    /// Code's own threshold for nil. It is told once, in its environment at its launch, so a
    /// resident process told otherwise is replaced as a change of model replaces it: at the next
    /// idle moment, never under a turn.
    public func use(compactAt: Int?) {
        guard compactAt != self.compactAt else { return }
        self.compactAt = compactAt
        log("the compaction threshold is now \(compactAt.map { "\($0)%" } ?? "Claude Code's own"); the resident process is replaced once idle")
        renewIfStale()
    }

    /// Every process from here on is told `memory` of its memory: whether the vault is mounted,
    /// which it is told once, at its launch. A resident process told otherwise is replaced as a
    /// change of model replaces it, so a turn never goes to a process told the memory is where it
    /// is not, or cannot be reached when it can.
    public func use(memory: Bool?) {
        guard memory != self.memory else { return }
        self.memory = memory
        log("the memory is now \(memory.map { $0 ? "mounted" : "not mounted" } ?? "unsaid"); the resident process is replaced once idle")
        renewIfStale()
    }

    /// Forgets the conversation (sign-out): the kept session id is cleared, the next process
    /// starts a fresh session, and a resident process holding the old one is ended now, a turn in
    /// flight abandoned — unlike a change of model, which waits for the turn. What it holds is the
    /// login that went: its token is in its environment, and a turn left running would run its
    /// tools and go on writing that session's transcript for nobody.
    ///
    /// No process starts from the call until `takeAway` has returned: the one that held the old
    /// conversation — resident, being ended, or still starting, which is ended as it lands — is
    /// ended with no replacement, its end is awaited, and then `takeAway` runs, so what it held (a
    /// file in the vault, its working directory) is let go and nothing new holds it when the mount
    /// is taken away. A `ready()` meanwhile waits, and its process starts once `takeAway` is done;
    /// with nobody waiting none starts, and the next `ready()` starts one, reading its environment
    /// afresh. Returns how the old process's end went; nil when there was none.
    @discardableResult
    public func forgetSession(then takeAway: @Sendable () async -> Void = {}) async -> GuestProcess.Termination? {
        store.clear()
        cuts.clear()
        freshNext = true
        conversation += 1
        holds += 1
        log("the conversation is forgotten; nothing starts until the sign-out has taken away what it held")
        let termination = await endForgotten()
        // A stop still sending SIGSTOP would stop whatever the sign-out runs in the guest next.
        if let freezing { _ = await freezing.value }
        await takeAway()
        holds -= 1
        if !readiness.isEmpty { startResident() }
        return termination
    }

    /// Runs `body` with no resident process, for Claude Code's own login and logout: they and the
    /// resident are two `claude` processes over one credentials file, and a resident reads its
    /// login once, as it starts. The process there is ended — a turn in flight abandoned, a start
    /// still pending ended as it lands — and none starts until `body` returns, as under a sign-out,
    /// but the conversation is kept: the next process resumes it. A `ready()` meanwhile waits, and
    /// its process starts once `body` is done.
    public func withoutResident<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        holds += 1
        log("the resident is ended; nothing starts until Claude Code's login has finished")
        await endResident()
        // A stop still sending SIGSTOP would stop the login's own `claude`, which nothing continues.
        if let freezing { _ = await freezing.value }
        let value = await body()
        holds -= 1
        if !readiness.isEmpty { startResident() }
        return value
    }

    /// Ends whatever process there is, with no replacement, and waits for it.
    private func endResident() async {
        if let startTask { await startTask.value }
        // A frozen process is ended stopped unless its continue was sent before this began; the
        // gate then reads the phase and sends none.
        if case .frozen(let resident) = phase, continuedThaw !== resident {
            unfreezeCut()
            _ = await end(resident, reason: "Claude Code's login, frozen", restart: false).value
            return
        }
        if let thawing { await thawing.value }
        switch phase {
        case .resident(let resident):
            if let turn = resident.turn { finish(turn, of: resident, with: .abandoned) }
            _ = await end(resident, reason: "Claude Code's login", restart: false).value
        case .frozen(let resident):
            unfreezeCut()
            _ = await end(resident, reason: "Claude Code's login, frozen", restart: false).value
        case .stopping:
            _ = await teardown?.value
        case .idle, .starting:
            break
        }
    }

    /// Ends the process holding a forgotten conversation, with no replacement, and waits for it.
    private func endForgotten() async -> GuestProcess.Termination? {
        if let startTask {
            // It lands stale (`launched`), and is ended there.
            await startTask.value
        }
        // A frozen process of the login that went is ended stopped, unless its continue was sent
        // before the sign-out began: the end makes the phase stopping at once, and the gate that
        // sends a continue reads the phase on this actor, so none is sent after.
        if case .frozen(let resident) = phase, resident.conversation != conversation, continuedThaw !== resident {
            return await end(resident, reason: "a forgotten conversation, frozen", restart: false).value
        }
        if let thawing { await thawing.value }
        switch phase {
        case .resident(let resident) where resident.conversation != conversation:
            if let turn = resident.turn { finish(turn, of: resident, with: .abandoned) }
            return await end(resident, reason: "a forgotten conversation", restart: false).value
        case .frozen(let resident) where resident.conversation != conversation:
            // A stopped process holds the login that went as a running one does; SIGKILL ends it
            // stopped, so it is never continued first.
            return await end(resident, reason: "a forgotten conversation, frozen", restart: false).value
        case .stopping:
            return await teardown?.value
        case .idle, .starting, .resident, .frozen:
            return nil
        }
    }

    // MARK: - The lifecycle

    /// The app came to the foreground: the resident process starts, or — when the app is back
    /// before a teardown began — the one still there is kept. `generation` orders this against the
    /// lifecycle's other calls; nil takes the next one.
    public func foreground(generation given: Int? = nil) {
        guard admit(given) else { return }
        inForeground = true
        expired = false
        wakeBackground(.foreground)
        switch phase {
        case .idle: startResident()
        case .frozen(let resident): thaw(resident)
        default: break
        }
    }

    /// The app went to the background with `budget` of grace to spend: a turn in flight is given
    /// until then to finish, and the process is ended when it does, at the budget, or at once
    /// when no turn is in flight; a startup still pending is ended as it lands. A nil budget is a
    /// turn held up by something other than the grace (a continued-processing task): it is waited
    /// for with no deadline until `limit` gives one or `expire` ends the wait. Returns once
    /// nothing is resident, with what that came to — or at once with `kept` when the app came back
    /// before the teardown began, or when this call is older than one already seen. `left` is when
    /// the app went behind another app, read by the lifecycle at that moment (`now`), since the
    /// way out is called a tick later; this call's own time when not given.
    public func background(budget: Duration?, generation given: Int? = nil, left leftAt: Date? = nil) async -> BackgroundOutcome {
        let left = leftAt ?? now()
        guard admit(given) else { return .kept }
        let mine = generation
        inForeground = false
        // A start still pending ends what it made as it lands; a teardown already under way (a
        // restart, a process that died) is waited out, so nothing is resident when this answers.
        if let startTask { await startTask.value }
        if let thawing { await thawing.value }
        if let teardown { _ = await teardown.value }
        guard generation == mine, !inForeground else { return .kept }
        if case .frozen = phase { return .frozen }
        guard case .resident(let resident) = phase else { return .nothingResident }
        var fate: TurnFate?
        if resident.turn != nil {
            fate = .finished
            let wake = await waitForTurn(budget: budget ?? limitFor(mine))
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
        let running = still.backgroundTasks
        if fate == nil || fate == .finished, let freezer {
            return await freeze(still, with: freezer, left: left, running: running, turn: fate, generation: mine)
        }
        // The note is kept before the teardown, which is where iOS is likeliest to suspend the app.
        if fate == .abandoned || running > 0 {
            let cut = Cut(left: left, ended: now(), turn: fate == .abandoned, backgroundTasks: running)
            // A process of a forgotten conversation leaves nothing for the next login's.
            if still.conversation == conversation { cuts.save(cut) }
            log("\(Self.cutLine) \(fate == .abandoned ? "a turn" : "no turn") and \(running) background task\(running == 1 ? "" : "s"); the next process is told")
        }
        let termination = await end(still, reason: fate == .abandoned ? "the teardown point, turn abandoned" : "the background",
                                    restart: true).value
        return .ended(turn: fate, termination: termination)
    }

    /// A background begun with no budget is given `budget` from now: what holds the turn up has
    /// gone, and the grace is what is left. A wait already standing starts its deadline now; one
    /// not yet begun starts it when it begins. Nothing for a background that is over, or one that
    /// had a budget of its own.
    public func limit(budget: Duration, generation given: Int) {
        guard given == generation, !inForeground else { return }
        limited = budget
        limitGeneration = given
        if backgroundWait != nil, backgroundTimer == nil { startDeadline(budget) }
    }

    private func limitFor(_ generation: Int) -> Duration? {
        limitGeneration == generation ? limited : nil
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
        case .starting, .stopping, .frozen:
            guard inForeground else { throw Refusal.notResident }
        }
        try await withCheckedThrowingContinuation { readiness.append($0) }
    }

    /// Returns once nothing the resident is doing can still write about an input: no turn in
    /// flight — one whose caller stopped listening included — and no process being ended. Answers
    /// whether the last process ended was confirmed gone, so that what it wrote is final; true
    /// when none has been ended.
    public func settle() async -> Bool {
        while true {
            if case .resident(let resident) = phase, let turn = resident.turn {
                await withCheckedContinuation { turn.settling.append($0) }
            } else if let teardown {
                _ = await teardown.value
            } else {
                return lastTermination?.confirmed ?? true
            }
        }
    }

    /// Sends the person's `text` as a turn. Refused while another turn is in flight and while
    /// nothing is resident; otherwise the turn's events arrive on the stream, then how it ended.
    /// `id` is the input's uuid, which Claude Code keeps on the transcript entry it writes for it
    /// and echoes as the turn that answers it begins; one is made when none is given. The turn's
    /// events are the ones from that turn alone: a turn Claude Code runs of its own meanwhile, to
    /// answer a background task's notice, is not this one, and its result does not end it.
    /// A turn never goes to a process started with a model, memory or conversation the session no longer
    /// says: an idle stale process is replaced first, and one being replaced is waited for.
    public func send(_ text: String, id: String? = nil) async throws -> AsyncStream<TurnUpdate> {
        let resident = try await current()
        guard resident.turn == nil else { throw Refusal.turnInFlight }
        let id = id ?? UUID().uuidString.lowercased()
        let (stream, continuation) = AsyncStream<TurnUpdate>.makeStream()
        let turn = Turn(continuation: continuation, id: id)
        resident.turn = turn
        turn.watchdog = watch(turn, of: resident)
        do {
            Perf.mark("turn.guest.write")
            try await resident.process.write(StreamJSON.userTurn(text, id: id))
        } catch {
            if resident.turn === turn {
                finish(turn, of: resident, with: .failed(.input(String(describing: error))))
                restart(resident, reason: "a turn could not be written")
            }
        }
        return stream
    }

    // MARK: - Inside

    /// The resident process a turn goes to. A stale one with no turn in flight is replaced now
    /// rather than at the change's own idle moment, which may not have come yet; a process
    /// starting or being ended in the foreground is waited for. Nothing resident, or the
    /// background, is refused.
    private func current() async throws -> Resident {
        while true {
            switch phase {
            case .resident(let resident):
                guard resident.turn == nil, inForeground, isStale(resident) else { return resident }
                renewIfStale()
            case .idle:
                throw Refusal.notResident
            case .starting, .stopping, .frozen:
                // A frozen process takes nothing until it is continued, which only the foreground does.
                guard inForeground else { throw Refusal.notResident }
            }
            try await withCheckedThrowingContinuation { readiness.append($0) }
        }
    }

    /// Whether a lifecycle call is current: no older than the newest seen. A call with no
    /// generation takes the next one.
    private func admit(_ given: Int?) -> Bool {
        let next = given ?? generation + 1
        guard next > generation else { return false }
        generation = next
        return true
    }

    private func startResident() {
        guard case .idle = phase, inForeground, holds == 0 else { return }
        if freshNext {
            store.clear()
            freshNext = false
        }
        let resume = store.load()
        let cut = cuts.load()
        phase = .starting
        Perf.mark(resume == nil ? "resident.launch.begin fresh" : "resident.launch.begin resume")
        log(resume.map { "starting Claude Code, resuming \($0)" } ?? "starting Claude Code, a fresh session")
        let launcher = launcher, model = model, memory = memory, compactAt = compactAt, conversation = conversation
        // A stop still sending SIGSTOP to every guest task would stop this process too: it is
        // waited out first. It is the only one, since a way out waits for the thaw, which waits
        // for the stop, before it freezes again; and it is bounded (`GuestFreezer.stop`).
        let stopping = freezing
        // So is a thaw of a process ended meanwhile, which may be taking back the ports this
        // launch is about to be told.
        let obsolete = thawing
        startTask = Task {
            if let stopping { _ = await stopping.value }
            if let obsolete { await obsolete.value }
            let result: Result<any ResidentProcess, Error>
            do {
                result = .success(try await launcher.launch(resume: resume, model: model, memory: memory, compactAt: compactAt,
                                                            note: cut?.words))
            } catch {
                result = .failure(error)
            }
            if case .success(let process) = result {
                Perf.mark("resident.spawned cpu=\(Perf.cpu())")
                // Written before the process is the session's, so it is the first line Claude Code
                // reads, ahead of any turn; its answer is the `resident.ready` mark. A write that
                // fails is a process that has gone, which its reader finds; it costs only the mark.
                do {
                    try await process.write(StreamJSON.initialize(id: GuestSession.readyRequest))
                } catch {
                    self.log("the initialize was not written (\(error)); no resident.ready for this process")
                }
            } else {
                Perf.mark("resident.launch.failed")
            }
            await self.launched(result, resume: resume, model: model, memory: memory, compactAt: compactAt, conversation: conversation,
                                told: cut)
        }
    }

    /// Whether `resident` was started with what the session now says: its model, what it was told
    /// of its memory, and the conversation that has not been forgotten since.
    private func isStale(_ resident: Resident) -> Bool {
        resident.model != model || resident.memory != memory || resident.compactAt != compactAt
            || resident.conversation != conversation
    }

    /// Replaces a stale resident process, but only while it is idle and the app is in front: a
    /// turn in flight finishes first (`finish` asks again once it has), and in the background
    /// the process is being ended anyway.
    private func renewIfStale() {
        guard inForeground, case .resident(let resident) = phase, resident.turn == nil, isStale(resident) else { return }
        _ = end(resident, reason: "a change of model, memory, threshold or conversation", restart: true)
    }

    private func launched(_ result: Result<any ResidentProcess, Error>, resume: String?, model: String?,
                          memory: Bool?, compactAt: Int?, conversation: Int, told: Cut?) async {
        startTask = nil
        switch result {
        case .failure(let error):
            phase = .idle
            log("Claude Code did not start: \(error)")
            settleReadiness(.failure(error))
        case .success(let process):
            let resident = Resident(process: process, resumed: resume, model: model, memory: memory,
                                    compactAt: compactAt, conversation: conversation)
            resident.told = told
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
            // What changed while it was starting replaces it before any turn goes to it; whoever
            // is waiting for a process waits for the replacement.
            if isStale(resident) {
                _ = end(resident, reason: "a change of model, memory, threshold or conversation while it started", restart: true)
                return
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
        // One frozen is still the resident: what it wrote before it stopped is read.
        guard owns(resident) else { return }
        let events = StreamJSON.events(in: line)
        // The app's own control answers are no turn's line: they neither take its first-line mark
        // nor count as the process speaking while a turn waits.
        let control = !events.isEmpty && events.allSatisfy {
            if case .controlResponse = $0 { true } else { false }
        }
        if !control {
            resident.turn?.ticks += 1
            if resident.turn?.ticks == 1 { Perf.mark("turn.guest.firstLine") }
        }
        for event in events {
            // A turn's marks are its own: lines of a turn Claude Code runs of its own, before the
            // input's echo or with no turn in flight, are marked apart.
            let own = resident.turn?.begun == true
            switch event {
            case .text where own: Perf.mark("turn.guest.text")
            case .toolUse where own: Perf.mark("turn.guest.toolUse")
            case .result(let result) where own:
                Perf.mark("turn.guest.result")
                if Perf.recording, let timing = result.timing { Perf.mark("turn.guest.timing \(timing.words)") }
            case .result: Perf.mark("turn.guest.result.other")
            default: break
            }
            // An answer to a control request is the app's own and no turn's.
            if case .controlResponse(let id) = event {
                if id == Self.readyRequest, !resident.ready {
                    resident.ready = true
                    Perf.mark("resident.ready \(resident.resumed == nil ? "fresh" : "resume") cpu=\(Perf.cpu())")
                }
                continue
            }
            switch event {
            case .started(let session, _):
                Perf.mark("turn.guest.init")
                resident.began = true
                keep(session, of: resident)
                // Told, so the next process is not: unless a newer cut has been kept since. The
                // hook that tells it has run by `init`, and its output goes into the conversation
                // with the first input this process is given.
                if let told = resident.told, cuts.load() == told { cuts.clear() }
                resident.told = nil
            case .backgroundTasks(let count):
                resident.backgroundTasks = count
            case .result(let result):
                if let session = result.session, resident.began { keep(session, of: resident) }
            default:
                break
            }
            guard let turn = resident.turn else {
                if case .result(let result) = event { resident.strayResult = result }
                continue
            }
            // Another input's echo is no event of this turn's.
            if case .received(let id) = event, id != turn.id { continue }
            if !turn.begun {
                switch event {
                case .received(let id) where id == turn.id:
                    // The turn's own begins: what came since its init is its own.
                    turn.begun = true
                    let held = turn.held
                    turn.held = []
                    held.forEach { turn.continuation.yield(.event($0)) }
                case .started:
                    turn.held = [event]
                case .result(let result):
                    // A turn of Claude Code's own ended, before this one began.
                    resident.strayResult = result
                    turn.held = []
                    log("a turn of Claude Code's own ended before the input it was sent was taken up; its result is not this turn's")
                default:
                    turn.held.append(event)
                }
                continue
            }
            turn.continuation.yield(.event(event))
            if case .result(let result) = event {
                finish(turn, of: resident, with: result.isError ? .failed(.result(result)) : .answered(result))
            }
        }
    }

    /// Keeps the session `resident` names as the one the next process resumes — unless its
    /// conversation has been forgotten since it started: a process started before a sign-out goes
    /// on naming the session that went with it, and writing that back would have the next launch
    /// resume it.
    private func keep(_ session: String, of resident: Resident) {
        guard resident.conversation == conversation else { return }
        if store.load() != session { store.save(session) }
    }

    /// Whether `resident` is the session's process, running or frozen.
    private func owns(_ resident: Resident) -> Bool {
        switch phase {
        case .resident(let current), .frozen(let current): current === resident
        default: false
        }
    }

    /// The process let go of stdout: it has exited, or is about to.
    private func closed(_ resident: Resident) async {
        guard owns(resident) else { return }
        // A process that exits while frozen was not ended by iOS with the app: its cut says so.
        if case .frozen = phase { unfreezeCut() }
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

    /// Freezes the idle `resident` for the way out: the cut kept first when it has tasks running in
    /// the background, since iOS may end the app while it is away and nothing else tells the next
    /// process; then every guest task stopped. A stop not confirmed ends it, as the way out did
    /// before, because a task that has not parked may take one more step on the way back.
    private func freeze(_ resident: Resident, with freezer: any GuestFreezer, left: Date, running: Int,
                        turn fate: TurnFate?, generation mine: Int) async -> BackgroundOutcome {
        if running > 0, resident.conversation == conversation {
            let cut = Cut(left: left, ended: now(), turn: false, backgroundTasks: running, frozen: true)
            cuts.save(cut)
            frozenCut = cut
        }
        phase = .frozen(resident)
        Perf.mark("resident.freeze.begin")
        let stopping = Task { await freezer.stop() }
        freezing = stopping
        let stopped = await stopping.value
        if freezing == stopping { freezing = nil }
        // Back in front meanwhile: the way back continues it, stopped or not.
        guard generation == mine, !inForeground else { return .kept }
        guard case .frozen(let still) = phase, still === resident else {
            unfreezeCut()
            return .nothingResident
        }
        guard stopped else {
            log("the guest did not stop; ending the process rather than freezing it")
            unfreezeCut()
            return .ended(turn: fate, termination: await end(resident, reason: "a freeze that did not stop", restart: true).value)
        }
        Perf.mark("resident.frozen")
        log("frozen: the idle process is kept, stopped, for the way back")
        return .frozen
    }

    /// Continues a frozen `resident` on the way back, once its stop has landed and was confirmed:
    /// its ports taken back, then the gate (`continueIfStill`) on this actor, then the continue
    /// confirmed. Any refusal ends the process and starts a fresh one, the cold start a jetsam
    /// would have left.
    private func thaw(_ resident: Resident) {
        guard thawing == nil, let freezer else { return }
        let stopping = freezing
        Perf.mark("resident.thaw.begin")
        thawing = Task {
            // A stop not confirmed may have a task still taking a step: it is never continued.
            if let stopping, await stopping.value == false {
                return await self.thawed(resident, resumed: false, why: "its stop was not confirmed")
            }
            // A process ended while its stop landed takes nothing back: the next launch is
            // binding the listeners afresh.
            guard await self.owns(resident) else { return await self.thawed(resident, resumed: false, why: "it was ended meanwhile") }
            guard await freezer.prepare() else {
                return await self.thawed(resident, resumed: false, why: "it could not be prepared: a port it was told, or the zone it started in")
            }
            if let refused = await self.continueIfStill(resident, with: freezer) {
                return await self.thawed(resident, resumed: false, why: refused)
            }
            let confirmed = await freezer.confirm()
            await self.thawed(resident, resumed: confirmed, why: "a task stayed stopped after the continue")
        }
    }

    /// The gate a continue passes, and the continue itself, in one step on this actor: the process
    /// is still the session's frozen one, its conversation is not forgotten (no sign-out since the
    /// freeze), no sign-out or login is under way, and Claude Code is still signed in. Nil once
    /// the continue is sent; otherwise why not, with nothing sent.
    private func continueIfStill(_ resident: Resident, with freezer: any GuestFreezer) -> String? {
        guard case .frozen(let current) = phase, current === resident else { return "it was ended meanwhile" }
        guard resident.conversation == conversation else { return "its conversation was forgotten" }
        guard holds == 0 else { return "a sign-out or a login is under way" }
        guard signedIn() else { return "Claude Code is signed out" }
        guard freezer.continueNow() else { return "the continue could not be sent" }
        continuedThaw = resident
        return nil
    }

    private func thawed(_ resident: Resident, resumed: Bool, why: String) {
        thawing = nil
        if continuedThaw === resident { continuedThaw = nil }
        guard case .frozen(let current) = phase, current === resident else { return }
        guard resumed else {
            Perf.mark("resident.thaw.cold")
            log("the frozen process could not be continued (\(why)); starting a fresh process")
            unfreezeCut()
            _ = end(resident, reason: "a thaw that could not continue it", restart: true)
            return
        }
        phase = .resident(resident)
        Perf.mark("resident.thaw.continued")
        if let cut = frozenCut, cuts.load() == cut { cuts.clear() }
        frozenCut = nil
        log("continued: the frozen process is resident again")
        settleReadiness(.success(()))
        renewIfStale()
    }

    /// A frozen process is being ended after all: the cut kept for it says so rather than that iOS
    /// ended the app.
    private func unfreezeCut() {
        if let cut = frozenCut, cuts.load() == cut {
            cuts.save(Cut(left: cut.left, ended: now(), turn: false, backgroundTasks: cut.backgroundTasks))
        }
        frozenCut = nil
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
        lastTermination = termination
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
        turn.settling.forEach { $0.resume() }
        turn.settling = []
        wakeBackground(.turnEnded)
        // A change that waited for the turn is made now that it has ended — on the actor's next
        // turn, so a path ending the process itself (an exit, the way out) has done so first.
        Task { await self.renewIfStale() }
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

    /// Waits for the turn to end, the app to come back, or the deadline: `budget` from now, or
    /// none until `limit` gives one.
    private func waitForTurn(budget: Duration?) async -> Wake {
        if expired { return .deadline }
        if let budget { startDeadline(budget) }
        let wake = await withCheckedContinuation { backgroundWait = $0 }
        backgroundTimer?.cancel()
        backgroundTimer = nil
        return wake
    }

    private func startDeadline(_ budget: Duration) {
        let sleep = sleep
        backgroundTimer = Task { [weak self] in
            do { try await sleep(budget) } catch { return }
            await self?.wakeBackground(.deadline)
        }
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
        case .frozen: return "frozen: the idle process is kept, stopped, for the way back"
        case .ended(let turn, let termination):
            let fate = switch turn {
            case .finished: "the turn in flight finished in the background"
            case .abandoned: "the turn in flight was abandoned at the teardown point"
            case nil: "no turn in flight"
            }
            let confirmed = termination.confirmed ? "confirmed" : "NOT confirmed"
            return "ended, \(fate); termination \(confirmed): \(termination)"
        case .handedToGrace:
            return "the continued-processing task expired; the grace has the turn"
        case .graceRefused:
            return "the continued-processing task expired and iOS refused the grace; the process is ended now"
        case .graceUnread:
            return "the continued-processing task expired and no grace could be read a tick later; the process is ended now"
        case .outOfTime:
            return "background time ran out before the termination answered; the background task was ended with the teardown still running"
        }
    }
}
