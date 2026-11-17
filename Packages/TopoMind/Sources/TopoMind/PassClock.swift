import Foundation
import TopoCore
import TopoTurn

/// The stages of one answering pass, as `Perf` marks: `hub.pass.trigger <source>` when the pass
/// begins, then each stage once, with the milliseconds since the trigger — `hub.pass.read` (the
/// zone's change feed answered), `hub.pass.probed` (the fetch by ID of the log's newest turns
/// answered, which a pass makes only when the feed shows something to do), `hub.pass.lease` (the
/// lease's word this pass heard before the brain is asked: `age=` how long before the ask, and
/// `ms=` when it came), `hub.pass.asked` (the brain asked, with
/// `turn=` the milliseconds since the newest turn it answers was said), `hub.pass.written` (the
/// input on Claude Code's stdin), `hub.pass.received` (its echo, which Claude Code writes as the API's first event for the
/// turn arrives, so not the moment it sent the request),
/// `hub.pass.begun` (the reply's first message begun, the API's first event), `hub.pass.words`
/// (the reply's first words), `hub.pass.answered`, `hub.pass.saved` (the reply's batch answered)
/// — and `hub.pass.end <outcome>`. A pass with nothing to answer marks the trigger, the read and
/// its end. A pass a heads-up began marks each wait for its turn, `hub.pass.waited` with `ms=` as
/// it ended, `waited=` how long it took and what ended it, so the stages after it are read from
/// that mark's `ms=`.
///
/// The runner's stages are not its own marks, so they are read off the calls it makes: the log's
/// read and the writes through the database it is given (`TimedDatabase`), the brain's calls
/// (`TimedBrain`), and what the brain says of the process (`NativeBrain.Stage`, `ReplyFrame`). One
/// pass runs at a time, so one clock serves them. A mark carries a stage's name, a trigger's
/// source, an outcome's kind and times, never a word of a turn.
final class PassClock: @unchecked Sendable {
    private let lock = NSLock()
    private var began: ContinuousClock.Instant?
    private var marked: Set<String> = []

    func begin(_ source: String) {
        lock.withLock {
            began = .now
            marked = []
        }
        Perf.mark("hub.pass.trigger \(source)")
    }

    func end(_ outcome: String) {
        let ms = lock.withLock { () -> Int? in
            defer { began = nil }
            return began.map(Self.ms)
        }
        guard let ms else { return }
        Perf.mark("hub.pass.end \(outcome) ms=\(ms)")
    }

    /// The stage's mark, the first time it is reached in the pass. Nothing outside a pass.
    func reached(_ stage: String, detail: String = "") {
        let ms = lock.withLock { () -> Int? in
            guard let began, !marked.contains(stage) else { return nil }
            marked.insert(stage)
            return Self.ms(since: began)
        }
        guard let ms else { return }
        Perf.mark("hub.pass.\(stage) ms=\(ms)\(detail)")
    }

    /// A wait for a heads-up's turn ended, with what ended it; `since` is when it began.
    func waited(_ heard: TurnRunner.Coming, since: ContinuousClock.Instant) {
        let ms = lock.withLock { began.map(Self.ms) }
        guard let ms else { return }
        let how = switch heard {
        case .saved: "saved"
        case .other: "other"
        case .gone: "gone"
        }
        Perf.mark("hub.pass.waited ms=\(ms) waited=\(Self.ms(since: since)) \(how)")
    }

    /// A fetch by ID naming a turn answered: in a pass, the first is the log read's second half.
    func probed() { reached("probed") }

    /// Where the process has the turn the brain was asked: only the first of each in a pass.
    func brain(_ stage: NativeBrain.Stage) {
        switch stage {
        case .written: reached("written")
        case .received: reached("received")
        }
    }

    /// A piece of the reply as the brain hands it: its first message begun and its first words.
    func wrote(_ frame: ReplyFrame) {
        switch frame {
        case .message: reached("begun")
        case .text: reached("words")
        default: break
        }
    }

    /// The brain is asked, `leaseAge` seconds after the lease's word this pass heard: the lease's
    /// stage is marked first, then the ask.
    func asked(turnAge: Int?, leaseAge: TimeInterval?) {
        let lease = lock.withLock { () -> (ms: Int, age: Int)? in
            guard let began, let leaseAge, !marked.contains("lease") else { return nil }
            marked.insert("lease")
            let age = Int(leaseAge * 1000)
            return (Self.ms(since: began) - age, age)
        }
        if let lease { Perf.mark("hub.pass.lease ms=\(lease.ms) age=\(lease.age)") }
        reached("asked", detail: turnAge.map { " turn=\($0)" } ?? "")
    }

    private static func ms(since began: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - began
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// The hub's database as the runner sees it: every call forwarded, the bound of
/// `answering(within:)` included, with the pass's stages read off what comes back.
struct TimedDatabase: RecordDatabase {
    let base: any RecordDatabase
    let clock: PassClock

    func save(_ records: [Record]) async throws -> [Record] {
        let saved = try await base.save(records)
        if records.contains(where: { $0.type == Turn.recordType }) { clock.reached("saved") }
        return saved
    }

    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] {
        let fetched = try await base.fetch(ids)
        if ids.contains(where: { Turn.ref(ofRecordNamed: $0.name) != nil }) { clock.probed() }
        return fetched
    }
    func query(_ query: RecordQuery) async throws -> [Record] { try await base.query(query) }

    func records(ofType type: String) async throws -> [Record] {
        let records = try await base.records(ofType: type)
        if type == Turn.recordType { clock.reached("read") }
        return records
    }

    func answering(within seconds: TimeInterval) -> any RecordDatabase {
        TimedDatabase(base: base.answering(within: seconds), clock: clock)
    }
}

/// The mind as the runner sees it: every call forwarded to the `NativeBrain`, with the ask and
/// the answer marked, and the reply's turn named to the cast while it is written.
struct TimedBrain: Brain {
    let inner: NativeBrain
    let clock: PassClock
    /// Where the reply being written is handed to the phones that follow its turn.
    let cast: ReplyCast

    func answer(_ request: BrainRequest) async throws -> Reply {
        let newest = request.answering.map(\.at).max()
        clock.asked(turnAge: newest.map { Int(Date().timeIntervalSince($0) * 1000) }, leaseAge: request.leaseAge)
        cast.begin(request.answering)
        defer { cast.end() }
        let reply: Reply
        do {
            reply = try await inner.answer(request)
        } catch {
            // No reply is to come of this turn: what the phones were handed of it goes.
            cast.cut()
            throw error
        }
        clock.reached("answered")
        return reply
    }

    func hear(_ words: String, nonce: String, context: [Turn]?, model: ClaudeModel) async -> Bool {
        await inner.hear(words, nonce: nonce, context: context, model: model)
    }
    func bind(nonce: String, person: Turn, reply: String) async { await inner.bind(nonce: nonce, person: person, reply: reply) }
    func withdrawn(nonce: String) async { await inner.withdrawn(nonce: nonce) }
    func stopHearing(nonce: String) async { await inner.stopHearing(nonce: nonce) }
    func landed(_ reply: Turn, nonce: String) async { await inner.landed(reply, nonce: nonce) }
    func unresolved() async -> Set<TurnRef> { await inner.unresolved() }
    func owed() async -> OwedReply? { await inner.owed() }
    func use(model: ClaudeModel) async { await inner.use(model: model) }
    func use(compaction: Compaction.Setting) async { await inner.use(compaction: compaction) }
    func use(threads: MessageThreads.Setting) async { await inner.use(threads: threads) }
    func forget() async { await inner.forget() }
    func describe() async -> String { await inner.describe() }
}
