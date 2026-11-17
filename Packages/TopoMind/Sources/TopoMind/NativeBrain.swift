import Foundation
import TopoCore
import TopoTurn

public enum NativeBrainError: Error, Equatable, CustomStringConvertible {
    /// Claude Code says it is not signed in (its login failed). Nothing of the turn is counted;
    /// once it is signed in, asking again sends it again.
    case notSignedIn(String)
    /// The process could not be started or did not come up within its bound; the reason is
    /// Claude Code's own where it gave one.
    case notStarted(String)
    /// The turn never reached the conversation, or it is not known that it did; the next
    /// request asks again.
    case failed(String)
    /// The conversation took the turn up and it ended with no answer: an error result, or the
    /// process gone mid-turn. It may have run tools, so it is not asked again by itself; the
    /// person asks again.
    case unresolved(String)
    /// The mind's record could not be read, so whether an input it records was received is not
    /// known; nothing is sent until it can be.
    case ledgerUnreadable(String)
    /// The turn was given up on: Claude Code wrote nothing for the silence bound, or the turn ran
    /// past the turn bound. A turn it had taken up is unresolved and is not asked again; one it
    /// had not is asked again by the next request. The process is not used again.
    case stalled(Stall)

    public enum Stall: Sendable, Equatable {
        /// No line on stdout for this long, the turn asked.
        case silent(Duration)
        /// The turn ran this long without ending.
        case tooLong(Duration)
    }

    public var description: String {
        switch self {
        case .notSignedIn(let why): "Claude Code on this Mac is not signed in: \(why)"
        case .notStarted(let why): "Claude Code on this Mac could not be started: \(why)"
        case .failed(let why): "The reply failed: \(why)"
        case .unresolved(let why): "Topo was cut off before answering (\(why)). Ask again when you want the answer."
        case .ledgerUnreadable(let why): "The mind's record could not be read (\(why)); nothing is sent until it can be."
        case .stalled(.silent(let bound)): "Claude Code on this Mac wrote nothing for \(bound) of a turn, so the turn was given up on."
        case .stalled(.tooLong(let bound)): "A turn on this Mac ran past \(bound), so it was given up on."
        }
    }
}

/// The Mac's mind: a `Brain` that answers through one resident native Claude Code process,
/// `claude -p` reading turns as stream-json on stdin and writing its events as stream-json on
/// stdout, in a config directory and working directory of the caller's.
///
/// The process keeps its own conversation, so it is told only what it has not seen: the person's
/// words, after any turns of the log it was never given (answered on the phone while the Mac
/// slept) as a "meanwhile" block, or, for a conversation with nothing seen, the last
/// `contextLimit` turns. What it has seen is the ledger's (`MindLedger`, `mind.json` in the state
/// directory), advanced only once the reply to an input is in the log (`landed`). The session id
/// is kept there too and resumed (`--resume`) by every later process.
///
/// Before an input is written the ledger records it under a uuid the input carries; the echo of
/// that uuid (`--replay-user-messages`) marks it received, and its result answers it. Everything
/// the process writes before the echo, and any result naming another input, is no part of the
/// turn. One turn at a time is asked.
public actor NativeBrain: Brain {
    public struct Configuration: Sendable {
        /// The process's working directory. Claude Code reads a CLAUDE.md and `.claude/` from
        /// here and from every directory above it, so it is one with none of Sam's above it, and
        /// it stays the same across launches.
        public var workingDirectory: URL
        /// Claude Code's home (`CLAUDE_CONFIG_DIR`): its settings, login, sessions. Nil leaves the
        /// variable unset, which is the user's own `~/.claude` and its login: for a manual live
        /// check only.
        public var configDirectory: URL?
        /// Where the mind's ledger is kept: the config directory unless given.
        public var stateDirectory: URL
        /// The `claude` executable.
        public var claude: URL
        /// `--permission-mode`. Not bypass by default: this process is not sandboxed and runs
        /// in a person's real account.
        public var permissionMode: String
        /// Variables added to the process's environment, over the few it takes from this one.
        public var environment: [String: String]
        /// How long a process is given to start and answer its `initialize`.
        public var startBound: Duration
        /// How long a turn may go with no line at all on stdout before it is given up on
        /// (`NativeBrainError.stalled`). Every line counts, whatever it is.
        public var silenceBound: Duration
        /// How long one turn may run, however much it writes, before it is given up on.
        public var turnBound: Duration

        public static let defaultClaude = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".local/bin/claude")

        public init(workingDirectory: URL, configDirectory: URL?, stateDirectory: URL? = nil,
                    claude: URL = Configuration.defaultClaude, permissionMode: String = "auto",
                    environment: [String: String] = [:], startBound: Duration = .seconds(60),
                    silenceBound: Duration = NativeBrain.standardSilence, turnBound: Duration = NativeBrain.standardTurn) {
            precondition(configDirectory != nil || stateDirectory != nil, "the ledger needs a directory")
            self.workingDirectory = workingDirectory
            self.configDirectory = configDirectory
            self.stateDirectory = (stateDirectory ?? configDirectory)!
            self.claude = claude
            self.permissionMode = permissionMode
            self.environment = environment
            self.startBound = startBound
            self.silenceBound = silenceBound
            self.turnBound = turnBound
        }
    }

    /// How many turns of the log a conversation that has seen nothing is told; the older ones are
    /// counted seen without being told.
    public static let contextLimit = 40

    /// Three minutes. With `--include-partial-messages` Claude Code writes a line for every piece
    /// of a reply or a tool call's input as the model makes it, `system/thinking_tokens` while it
    /// thinks, `system/status` and `system/api_retry` while it waits on the API, and a
    /// `tool_progress` heartbeat every 30 s while a tool runs (2.1.325). Its longest quiet in
    /// a working turn is the wait for a request's first token. Three minutes of nothing is a
    /// process that has stopped: wedged, or its event loop stuck.
    public static let standardSilence: Duration = .seconds(180)

    /// Thirty minutes: many times a working turn, and past any single Bash call, which Claude Code
    /// ends at its timeout. A tool that never returns heartbeats all the while, so this is what
    /// bounds it.
    public static let standardTurn: Duration = .seconds(1800)

    /// The variables of this process the resident inherits; nothing else of this environment is
    /// passed, so a hub (or a test run) started by Claude Code leaks none of its variables.
    static let inherited = ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "SHELL", "PATH"]

    private struct Resident {
        let process: MindProcess
        let model: String
        /// The inputs written to this process.
        var sent: Set<String> = []
        /// A turn on it was given up on: it is torn down and never asked again.
        var stalled = false
    }

    private let configuration: Configuration
    private let file: URL
    private var ledger = MindLedger()
    private var loaded = false
    private var unread: String?
    private var resident: Resident?
    private var lastFailure: String?
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []
    /// Moves at every `forget`: an answer begun before it records nothing and returns nothing.
    private var epoch = 0
    private var wanted = ClaudeModel.default
    /// Told each piece of a turn's reply as Claude Code writes it, once the turn is its own: a
    /// message begun, its words, a tool call begun (`ReplyCast`). Never a tool's name or input.
    private var writes: (@Sendable (ReplyFrame) -> Void)?
    /// Told where a turn asked of this brain stands with Claude Code: its input written to stdin,
    /// and its input's echo. For the hub's pass marks; nothing of the turn.
    private var stages: (@Sendable (Stage) -> Void)?

    /// Where a turn asked of the brain stands with the process (`stages(to:)`).
    public enum Stage: Sendable, Equatable {
        /// The input is written to Claude Code's stdin.
        case written
        /// Claude Code echoed the input, which 2.1.326 does as the API's first event for the turn
        /// arrives, a few milliseconds before the reply's first message begins: well after it sent
        /// the request.
        case received
    }

    public init(_ configuration: Configuration) {
        self.configuration = configuration
        file = configuration.stateDirectory.appending(path: "mind.json")
        do {
            ledger = try MindLedger.load(file)
            loaded = true
        } catch {
            unread = String(describing: error)
        }
    }

    // MARK: - Brain

    public func answer(_ request: BrainRequest) async throws -> Reply {
        let epoch = self.epoch
        await take()
        defer { release() }
        try current(epoch)
        guard readLedger() else { throw NativeBrainError.ledgerUnreadable(unread ?? "unknown") }
        let model = ClaudeModel.effective(request.model).rawValue

        // The input outstanding is reconciled first.
        if let pending = ledger.pending {
            if pending.nonce == request.nonce {
                switch pending.state {
                case .answered:
                    // Answered and not yet in the log: the same words, not asked again.
                    return Reply(text: pending.text ?? "", model: model, context: 0, outputTokens: 0)
                case .unresolved:
                    throw NativeBrainError.unresolved("this turn was cut off earlier")
                case .sent, .received:
                    if let resident, !resident.stalled, !resident.process.hasExited, resident.sent.contains(pending.input) {
                        // Still with the process that has it: listened to again, not sent again.
                        return try await listen(pending.input, begun: pending.state == .received, to: resident.process,
                                                epoch: epoch, model: model)
                    }
                    if pending.state == .received {
                        ledger.pending?.state = .unresolved
                        try? save()
                        throw NativeBrainError.unresolved("the process that had this turn is gone")
                    }
                    // Never echoed by a process that is gone: not taken up, asked again below.
                    ledger.pending = nil
                    try save()
                }
            } else {
                switch pending.state {
                case .answered:
                    // The runner writes an owed reply before it asks (`owed`); one still here is a
                    // write that did not happen, and the next attempt makes it.
                    throw NativeBrainError.failed("a reply this mind finished is still to be written to the log")
                case .received, .unresolved:
                    // The log has moved past an input the conversation took up: what it told is seen.
                    count(pending)
                    ledger.pending = nil
                    try save()
                case .sent:
                    // Not known to be taken up: what it carried is told again rather than never.
                    ledger.pending = nil
                    try save()
                }
            }
        }

        let process = try await running(model: model, epoch: epoch)
        let fresh = ledger.session == nil
        let unseen = request.context.filter { !ledger.seen.contains($0.ref) }
        let told = fresh ? Array(unseen.suffix(Self.contextLimit)) : unseen
        let input = Self.render(unseen: told, answering: request.answering, fresh: fresh)
        var covers = MindCoverage(told.map(\.ref) + request.answering.map(\.ref))
        if fresh { covers.insert(request.context.map(\.ref)) }
        let id = UUID().uuidString.lowercased()
        // Recorded before it is written: after a crash this is what says the input may have gone.
        ledger.pending = .init(input: id, nonce: request.nonce, parents: request.parents,
                               answering: request.answering.map(\.ref), covers: covers,
                               session: ledger.session, sentAt: Date(), state: .sent)
        try save()
        do {
            try await process.write(MindStream.userTurn(input, id: id))
        } catch {
            if self.epoch == epoch, ledger.pending?.input == id { ledger.pending = nil; try? save() }
            throw NativeBrainError.failed(String(describing: error))
        }
        stages?(.written)
        try current(epoch)
        resident?.sent.insert(id)
        return try await listen(id, begun: false, to: process, epoch: epoch, model: model)
    }

    public func landed(_ reply: Turn, nonce: String) async {
        guard readLedger(), let pending = ledger.pending, pending.nonce == nonce else { return }
        // Another device's reply under the nonce, for an input never known taken up, counts nothing.
        if pending.state != .sent { count(pending) }
        if pending.state == .answered, pending.text == reply.text { ledger.seen.insert([reply.ref]) }
        ledger.pending = nil
        try? save()
    }

    public func unresolved() async -> Set<TurnRef> {
        guard readLedger(), let pending = ledger.pending, pending.state == .unresolved else { return [] }
        return Set(pending.answering)
    }

    public func owed() async -> OwedReply? {
        guard readLedger(), let pending = ledger.pending, pending.state == .answered, let text = pending.text else { return nil }
        return OwedReply(parents: pending.parents, nonce: pending.nonce, text: text)
    }

    /// Where the pieces of each reply go as they are written (`writes`); nil for nowhere.
    public func writes(to hand: (@Sendable (ReplyFrame) -> Void)?) {
        writes = hand
    }

    /// Where each turn's stages go (`Stage`); nil for nowhere.
    public func stages(to hand: (@Sendable (Stage) -> Void)?) {
        stages = hand
    }

    /// Recorded for `start()`; every request carries its own model, and a process asked with a
    /// model other than its own is replaced before the turn is written.
    public func use(model: ClaudeModel) async {
        wanted = model
    }

    public func forget() async {
        epoch += 1
        let gone = resident
        resident = nil
        ledger = MindLedger()
        loaded = true
        unread = nil
        lastFailure = nil
        try? FileManager.default.removeItem(at: file)
        if let gone { _ = await gone.process.terminate() }
    }

    public func describe() async -> String { describe(reasons: true) }

    /// The line `describe()` gives, or without `reasons` the same with no reason a start or a read
    /// of the ledger failed for: those are Claude Code's stderr and the file system's words.
    public func describe(reasons: Bool) -> String {
        var parts: [String] = []
        if let resident, resident.stalled {
            parts.append("Claude Code on this Mac, pid \(resident.process.pid), stalled on a turn")
        } else if let resident, !resident.process.hasExited {
            parts.append("Claude Code on this Mac, pid \(resident.process.pid), model \(resident.model)")
        } else {
            let failure = reasons ? lastFailure.map { " (last start: \($0))" } : lastFailure.map { _ in " (the last start failed)" }
            parts.append("Claude Code on this Mac, not running" + (failure ?? ""))
        }
        if let unread {
            parts.append("the ledger could not be read" + (reasons ? " (\(unread))" : "") + "; nothing is sent until it can be")
            return parts.joined(separator: "; ")
        }
        parts.append("told \(ledger.seen.count) turns" + (ledger.session.map { " of session \($0)" } ?? ", no session yet"))
        switch ledger.pending?.state {
        case .sent?, .received?: parts.append("a turn with the process")
        case .answered?: parts.append("a reply still to be written to the log")
        case .unresolved?: parts.append("a turn cut off, waiting for the person to ask again")
        case nil: break
        }
        return parts.joined(separator: "; ")
    }

    // MARK: - Beyond Brain

    /// Starts the process now, if it is not running, with the model last given to `use(model:)`,
    /// so the first turn does not wait for it.
    public func start() async throws {
        let epoch = self.epoch
        await take()
        defer { release() }
        try current(epoch)
        guard readLedger() else { throw NativeBrainError.ledgerUnreadable(unread ?? "unknown") }
        _ = try await running(model: ClaudeModel.effective(wanted).rawValue, epoch: epoch)
    }

    /// Ends the process and everything it started, and returns once it is reaped: true when
    /// nothing of it is left. A turn in flight ends as cut off. The conversation is kept, and the
    /// next request resumes it.
    @discardableResult
    public func shutdown() async -> Bool {
        guard let gone = resident else { return true }
        resident = nil
        let confirmed = await gone.process.terminate().confirmed
        if confirmed { forgetResident(gone.process.pid) }
        return confirmed
    }

    /// The resident process's pid, for the hub's diagnostics and the suites.
    public var pid: Int32? { resident.flatMap { $0.process.hasExited ? nil : $0.process.pid } }

    /// The resident's watcher's pid, for the suites.
    var watcherPID: Int32? { resident?.process.watcherPID }

    // MARK: - Inside

    /// Claude Code's arguments: stream-json both ways (`--verbose` is what stream-json output
    /// requires), each input echoed as its turn begins (`--replay-user-messages`), the
    /// permission mode, nothing that would prompt left to wait on a host (`--permission-prompts
    /// none` denies it), the reply's pieces as they are made (`--include-partial-messages`, so a
    /// working turn is never quiet for long: `standardSilence`), the model, and the session to
    /// resume when there is one.
    static func arguments(model: String, resume: String?, permissionMode: String) -> [String] {
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--replay-user-messages", "--permission-mode", permissionMode, "--permission-prompts", "none",
                         "--include-partial-messages", "--model", model]
        if let resume { arguments += ["--resume", resume] }
        return arguments
    }

    /// The process's whole environment: the few variables of this one in `inherited`, the
    /// configuration's own, and `CLAUDE_CONFIG_DIR` last.
    static func environment(for configuration: Configuration,
                            parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = parent.filter { inherited.contains($0.key) }
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        environment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment.merge(configuration.environment) { _, new in new }
        environment["CLAUDE_CONFIG_DIR"] = configuration.configDirectory?.path
        return environment
    }

    /// The input: the turns the conversation has not seen, oldest first, then the person's words.
    /// The phone's form (`GuestBridge.render`), so a conversation moved between the two reads alike.
    static func render(unseen: [Turn], answering: [Turn], fresh: Bool) -> String {
        let words = answering.map(\.text).joined(separator: "\n\n")
        guard !unseen.isEmpty else { return words }
        let header = fresh
            ? "[The conversation so far, from the log on their devices — the last \(unseen.count) turns, oldest first:]"
            : "[Meanwhile, on their other devices — turns of this conversation you have not seen, oldest first:]"
        let lines = unseen.map { turn in
            (turn.role == .person ? "Them: " : "You, answering on another device: ") + turn.text
        }
        return ([header] + lines + ["[They now say:]", words]).joined(separator: "\n\n")
    }

    /// What an input the conversation took up told it, counted seen. A conversation other than the
    /// ledger's has seen only that.
    private func count(_ pending: MindLedger.Pending) {
        if let session = pending.session, session != ledger.session {
            ledger.session = session
            ledger.seen = pending.covers
        } else {
            ledger.seen.formUnion(pending.covers)
        }
    }

    /// The resident process asking `model`, started (resuming the ledger's session) when there is
    /// none, it has exited, or it asks another model.
    private func running(model: String, epoch: Int) async throws -> MindProcess {
        if let resident, !resident.stalled, !resident.process.hasExited, resident.model == model { return resident.process }
        // What a start costs, a model's change among them: the old process ended, and a new one
        // resuming the session until it answers `initialize`.
        let began = ContinuousClock.now
        let replacing = resident.map { $0.model == model ? "exited" : "model" } ?? "none"
        defer {
            if resident?.model == model {
                Perf.mark("hub.mind.started \(model) replaced=\(replacing) ms=\(Int((ContinuousClock.now - began) / .milliseconds(1)))")
            }
        }
        if let gone = resident {
            resident = nil
            if await gone.process.terminate().confirmed { forgetResident(gone.process.pid) }
            try current(epoch)
        }
        await reapLeftover()
        try current(epoch)
        for _ in 0..<2 {
            let session = ledger.session
            let process: MindProcess
            do {
                process = try MindProcess(executable: configuration.claude.path,
                                          arguments: Self.arguments(model: model, resume: session,
                                                                    permissionMode: configuration.permissionMode),
                                          environment: Self.environment(for: configuration),
                                          directory: configuration.workingDirectory.path, lifeline: true)
            } catch {
                lastFailure = String(describing: error)
                throw NativeBrainError.notStarted(String(describing: error))
            }
            recordResident(process.pid)
            let outcome = await Self.ready(process, within: configuration.startBound)
            guard self.epoch == epoch else {
                _ = await process.terminate()
                throw CancellationError()
            }
            switch outcome {
            case .ready:
                resident = Resident(process: process, model: model)
                lastFailure = nil
                return process
            case .noConversation where session != nil:
                // The session is not in this config directory any more: a fresh one has seen nothing.
                _ = await process.terminate()
                ledger.session = nil
                ledger.seen = MindCoverage()
                try save()
                continue
            case .noConversation, .ended, .timedOut:
                _ = await process.terminate()
                let why: String
                switch outcome {
                case .timedOut: why = "no answer to initialize within \(configuration.startBound)"
                default: why = "it exited: " + String(process.stderrTail.suffix(400)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                lastFailure = why
                throw NativeBrainError.notStarted(why)
            }
        }
        throw NativeBrainError.notStarted("the session could not be resumed or begun")
    }

    private enum Readiness: Sendable { case ready, noConversation, ended, timedOut }

    /// Writes `initialize` and waits for its answer, which Claude Code gives once it reads stdin.
    private static func ready(_ process: MindProcess, within bound: Duration) async -> Readiness {
        let id = "init-" + UUID().uuidString.lowercased()
        do { try await process.write(MindStream.initialize(id: id)) } catch { return .ended }
        return await withTaskGroup(of: Readiness?.self) { group in
            group.addTask {
                while true {
                    switch await process.stdout.next() {
                    case .cancelled, .timedOut: return nil
                    case .end: return .ended
                    case .line(let line):
                        for event in MindStream.events(in: line) {
                            switch event {
                            case .controlResponse(id): return .ready
                            case .result(let result) where result.errors.contains(where: { $0.contains("No conversation found") }):
                                return .noConversation
                            default: continue
                            }
                        }
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: bound)
                return Task.isCancelled ? nil : .timedOut
            }
            var outcome: Readiness = .timedOut
            for await answer in group {
                if let answer { outcome = answer; break }
            }
            group.cancelAll()
            return outcome
        }
    }

    /// Reads the process's events for the input `id` to its result. Nothing before the input's
    /// echo is the turn's (a turn Claude Code ran of its own, a cancelled turn's end), and a result
    /// that names another input is not its end.
    ///
    /// Bounded twice, from when this listen began: no line at all for `silenceBound`, or no
    /// result within `turnBound`, and the turn is given up on (`stall`). Every line resets the
    /// silence, whatever it is, the turn's own or not, since any line is the process at work.
    private func listen(_ id: String, begun: Bool, to process: MindProcess, epoch: Int, model: String) async throws -> Reply {
        var begun = begun
        var words = MindWords()
        var answeredWith: String?
        var usage: (context: Int, output: Int)?
        var signedOut = false
        let deadline = ContinuousClock.now + configuration.turnBound
        while true {
            let left = deadline - ContinuousClock.now
            guard left > .zero else { throw stall(id, .tooLong(configuration.turnBound), begun: begun, process: process, epoch: epoch) }
            switch await process.stdout.next(within: min(configuration.silenceBound, left)) {
            case .timedOut:
                let stall: NativeBrainError.Stall = ContinuousClock.now >= deadline
                    ? .tooLong(configuration.turnBound) : .silent(configuration.silenceBound)
                throw self.stall(id, stall, begun: begun, process: process, epoch: epoch)
            case .cancelled:
                // The record stays as it is; a retry under the same nonce listens again.
                throw CancellationError()
            case .end:
                _ = await process.exited()
                if resident?.process === process { resident = nil }
                try current(epoch)
                guard ledger.pending?.input == id else { throw NativeBrainError.failed("the record moved while the turn ran") }
                if begun {
                    ledger.pending?.state = .unresolved
                    try? save()
                    throw NativeBrainError.unresolved("the process exited mid-turn")
                }
                ledger.pending = nil
                try? save()
                throw NativeBrainError.failed("Claude Code exited before it took the turn up")
            case .line(let line):
                for event in MindStream.events(in: line) {
                    guard begun else {
                        if case .received(id) = event {
                            begun = true
                            stages?(.received)
                            if self.epoch == epoch, ledger.pending?.input == id {
                                ledger.pending?.state = .received
                                try? save()
                            }
                        }
                        continue
                    }
                    switch event {
                    case .started(_, let started):
                        answeredWith = started
                    case .text(let text, let message):
                        words.append(text, of: message)
                    case .writingBegan:
                        writes?(.message)
                    case .writing(let more):
                        writes?(.text(more))
                    case .toolCallBegan:
                        writes?(.tool)
                    case .signedOut:
                        signedOut = true
                    case .usage(let context, let output):
                        usage = (context, output)
                    case .result(let result):
                        if let input = result.input, input != id { continue }
                        if signedOut, resident?.process === process {
                            // A login made since is read by a process started after it.
                            resident = nil
                            _ = await process.terminate()
                        }
                        return try finish(id, result, words: words, signedOut: signedOut, epoch: epoch,
                                          model: answeredWith ?? model, usage: usage)
                    default:
                        continue
                    }
                }
            }
        }
    }

    /// The turn given up on: the process is marked never to be asked again (`shutdown` or the next
    /// start tears it down), and the record says what the next request does. A turn the
    /// conversation took up may have run tools, so it is unresolved, as a process gone mid-turn
    /// leaves it; one never echoed is cleared, and the next request asks it again.
    private func stall(_ id: String, _ stall: NativeBrainError.Stall, begun: Bool, process: MindProcess,
                       epoch: Int) -> any Error {
        if resident?.process === process { resident?.stalled = true }
        guard self.epoch == epoch else { return CancellationError() }
        if ledger.pending?.input == id {
            if begun { ledger.pending?.state = .unresolved } else { ledger.pending = nil }
            try? save()
        }
        return NativeBrainError.stalled(stall)
    }

    // MARK: - A resident left behind

    /// Where the resident's pid and start time are kept while it runs: a hub that ended without
    /// tearing it down (killed, crashed) finds it at its next start, and reaps it first.
    private var residentFile: URL { configuration.stateDirectory.appending(path: "resident.json") }

    private struct ResidentRecord: Codable {
        var pid: Int32
        var started: String
    }

    private func recordResident(_ pid: pid_t) {
        guard let started = MindProcess.startTime(of: pid),
              let data = try? JSONEncoder().encode(ResidentRecord(pid: pid, started: started)) else { return }
        try? data.write(to: residentFile, options: .atomic)
    }

    private func forgetResident(_ pid: pid_t) {
        guard let data = try? Data(contentsOf: residentFile),
              let record = try? JSONDecoder().decode(ResidentRecord.self, from: data), record.pid == pid else { return }
        try? FileManager.default.removeItem(at: residentFile)
    }

    /// Kills the process the record names, its group and its descendants, when it is the one the
    /// record was written for (the same pid, started at the same moment) and not this brain's.
    private func reapLeftover() async {
        guard let data = try? Data(contentsOf: residentFile),
              let record = try? JSONDecoder().decode(ResidentRecord.self, from: data) else { return }
        if resident?.process.pid == record.pid { return }
        if MindProcess.startTime(of: record.pid) == record.started {
            await MindProcess.reap(left: record.pid)
        }
        try? FileManager.default.removeItem(at: residentFile)
    }

    private func finish(_ id: String, _ result: MindEvent.Result, words: MindWords, signedOut: Bool, epoch: Int,
                        model: String, usage: (context: Int, output: Int)?) throws -> Reply {
        try current(epoch)
        guard ledger.pending?.input == id else { throw NativeBrainError.failed("the record moved while the turn ran") }
        if signedOut {
            // Not counted: once signed in, the turn and what it carried are told again.
            ledger.pending = nil
            try? save()
            throw NativeBrainError.notSignedIn(result.text ?? "Claude Code's login failed")
        }
        if result.isError {
            ledger.pending?.state = .unresolved
            ledger.pending?.session = result.session ?? ledger.pending?.session
            try? save()
            throw NativeBrainError.unresolved("Claude Code ended the turn with an error (\(result.subtype))")
        }
        let text = words.text.isEmpty ? result.text ?? "" : words.text
        ledger.pending?.state = .answered
        ledger.pending?.text = text
        ledger.pending?.session = result.session ?? ledger.pending?.session
        try save()
        return Reply(text: text, model: model, context: usage?.context ?? 0, outputTokens: usage?.output ?? 0)
    }

    private func current(_ epoch: Int) throws {
        guard epoch == self.epoch else { throw CancellationError() }
        try Task.checkCancellation()
    }

    @discardableResult
    private func readLedger() -> Bool {
        guard !loaded else { return true }
        do {
            ledger = try MindLedger.load(file)
            unread = nil
            loaded = true
            return true
        } catch {
            unread = String(describing: error)
            return false
        }
    }

    private func save() throws { try ledger.save(file) }

    private func take() async {
        if busy { await withCheckedContinuation { queue.append($0) } } else { busy = true }
    }

    private func release() {
        if queue.isEmpty { busy = false } else { queue.removeFirst().resume() }
    }
}
