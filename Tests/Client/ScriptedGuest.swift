import Foundation
import TopoCore
import TopoTurn
import TopoUserland
import XCTest

@testable import Topo

/// The far end of a scripted guest's model: a Messages request in, the API's status and body out.
protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The guest as a test scripts it: what each input comes to, played the way the resident Claude
/// Code plays it — the updates on the stream, and the session transcript written under `home` as
/// Claude Code writes it, input entry carrying the input's uuid and all — so the bridge reconciles
/// against a real file.
///
/// Its answers come from `script`, in order, or, with none left and a `transport`, from the
/// transport: each input goes out as one Messages request carrying it as the only message, which is
/// how the harness suites' scripted HTTP answers drive the guest too. A 200 is a reply; anything
/// else is a guest that failed before receiving the input.
final class ScriptedGuest: GuestConversation, @unchecked Sendable {
    enum Answer {
        /// Received and answered, with this usage.
        case reply(String, context: Int = 0, output: Int = 0, model: String = "claude-haiku-4-5-20251001")
        /// Never received: the process ended before it read the input.
        case notReceived(String)
        /// Received, and the process was ended before any reply: the turn is abandoned.
        case cutOff
        /// Received, and answered in the transcript, but the process ended before its result line.
        case answeredThenExited(String)
        /// Received, and then nothing: the stream never ends, as for an app killed mid-turn.
        case hang
        /// Received, and still being answered, with its transcript entry not written yet: the
        /// turn ends when `finishHanging` says.
        case hangUnwritten
        /// Received, and ended with an error result while the process lives on, before its
        /// transcript has the input on disk: a read now would say it never arrived.
        case errorResult(String)
    }

    let home: URL
    let transport: (any Transport)?
    private let lock = NSLock()
    private var script: [Answer]
    private var session: String?
    private var sessions = 0
    private var _inputs: [String] = []
    private var _ids: [String] = []
    private var _models: [String?] = []
    private var refusal: String?
    /// Turns the guest still has: `settle` waits for them, as the resident session does.
    private var hanging: [(continuation: AsyncStream<GuestSession.TurnUpdate>.Continuation, id: String, text: String,
                           session: String, written: Bool)] = []
    private var confirmed = true
    private var messages = 0
    private var holdingReady = false
    private var readyGate: CheckedContinuation<Void, Never>?

    init(home: URL, script: [Answer] = [], transport: (any Transport)? = nil, session: String? = "S1") {
        self.home = home
        self.script = script
        self.transport = transport
        self.session = session
    }

    /// The inputs sent, in order, and the uuid each carried.
    var inputs: [String] { lock.withLock { _inputs } }
    var ids: [String] { lock.withLock { _ids } }
    /// Each model `use(model:)` was told.
    var models: [String?] { lock.withLock { _models } }

    /// Refuses every turn as not ready, with `why`, until it is nil again.
    func refuse(_ why: String?) { lock.withLock { refusal = why } }

    /// Whether the ends of processes are confirmed, which `settle` reports.
    func confirmEnds(_ on: Bool) { lock.withLock { confirmed = on } }

    /// Ends every turn the guest still has with `reply`, written to the transcript after its
    /// input (written now if it was not yet) before the turn ends, as Claude Code writes its
    /// transcript before its result: `settle` returns only once it is on disk.
    func finishHanging(with reply: String) {
        let turns = lock.withLock { hanging }
        for turn in turns {
            if !turn.written { write(input: turn.text, id: turn.id, session: turn.session) }
            write(reply: reply, model: "claude-haiku-4-5-20251001", session: turn.session)
        }
        lock.withLock { hanging = [] }
        for turn in turns {
            turn.continuation.yield(.ended(.answered(.init(isError: false, subtype: "success", text: reply,
                                                           session: turn.session, duration: .milliseconds(10)))))
            turn.continuation.finish()
        }
    }

    /// Adds answers to the script.
    func then(_ answers: Answer...) { lock.withLock { script += answers } }

    /// The resume failed and the next process starts a fresh session: no session id until the
    /// next input begins one.
    func startFresh() { lock.withLock { session = nil } }

    // MARK: - GuestConversation

    /// Holds the next `ready` until `releaseReady`, as a userland still downloading does.
    func holdReady() { lock.withLock { holdingReady = true } }
    var readyHeld: Bool { lock.withLock { readyGate != nil } }
    func releaseReady() {
        let gate = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            holdingReady = false
            defer { readyGate = nil }
            return readyGate
        }
        gate?.resume()
    }

    func ready() async throws {
        if lock.withLock({ holdingReady }) {
            await withCheckedContinuation { continuation in
                let open = lock.withLock { () -> Bool in
                    guard holdingReady else { return true }
                    readyGate = continuation
                    return false
                }
                if open { continuation.resume() }
            }
        }
        if let why = lock.withLock({ refusal }) { throw GuestBridgeError.notReady(why) }
    }

    func warm() async {}

    func use(model: String?) async { lock.withLock { _models.append(model) } }

    func sessionID() async -> String? { lock.withLock { session } }

    func residentPID() async -> Int32? { 7 }

    func send(_ text: String, id: String) async throws -> AsyncStream<GuestSession.TurnUpdate> {
        if let why = lock.withLock({ refusal }) { throw GuestBridgeError.notReady(why) }
        lock.withLock {
            _inputs.append(text)
            _ids.append(id)
        }
        let answer = try await next(for: text)
        let session = lock.withLock { () -> String in
            if let current = self.session { return current }
            sessions += 1
            let fresh = "S-fresh-\(sessions)"
            self.session = fresh
            return fresh
        }
        let (stream, continuation) = AsyncStream<GuestSession.TurnUpdate>.makeStream()
        switch answer {
        case .reply(let reply, let context, let output, let model):
            write(input: text, id: id, session: session)
            write(reply: reply, model: model, session: session)
            continuation.yield(.event(.started(session: session, model: model)))
            continuation.yield(.event(.text(reply)))
            continuation.yield(.event(.usage(.init(model: model, context: context, output: output))))
            continuation.yield(.ended(.answered(.init(isError: false, subtype: "success", text: reply, session: session,
                                                      duration: .milliseconds(10)))))
            continuation.finish()
        case .notReceived(let why):
            continuation.yield(.ended(.failed(.exited(why))))
            continuation.finish()
        case .cutOff:
            write(input: text, id: id, session: session)
            continuation.yield(.event(.started(session: session, model: "claude-haiku-4-5-20251001")))
            continuation.yield(.event(.toolUse(name: "Bash")))
            continuation.yield(.ended(.abandoned))
            continuation.finish()
        case .answeredThenExited(let reply):
            write(input: text, id: id, session: session)
            write(reply: reply, model: "claude-haiku-4-5-20251001", session: session)
            continuation.yield(.event(.started(session: session, model: "claude-haiku-4-5-20251001")))
            continuation.yield(.ended(.failed(.exited(""))))
            continuation.finish()
        case .errorResult(let why):
            continuation.yield(.event(.started(session: session, model: "claude-haiku-4-5-20251001")))
            continuation.yield(.ended(.failed(.result(.init(isError: true, subtype: "error_during_execution", text: why,
                                                            session: session, duration: .milliseconds(10))))))
            continuation.finish()
        case .hang:
            write(input: text, id: id, session: session)
            continuation.yield(.event(.started(session: session, model: "claude-haiku-4-5-20251001")))
            lock.withLock { hanging.append((continuation, id, text, session, true)) }
        case .hangUnwritten:
            continuation.yield(.event(.started(session: session, model: "claude-haiku-4-5-20251001")))
            lock.withLock { hanging.append((continuation, id, text, session, false)) }
        }
        return stream
    }

    func settle() async -> Bool {
        while lock.withLock({ !hanging.isEmpty }) { try? await Task.sleep(for: .milliseconds(5)) }
        return lock.withLock { confirmed }
    }

    func forget() async { lock.withLock { session = nil } }

    func status() async -> String { "scripted" }

    // MARK: - Inside

    private func next(for text: String) async throws -> Answer {
        if let scripted = lock.withLock({ script.isEmpty ? nil : script.removeFirst() }) { return scripted }
        guard let transport else { return .notReceived("nothing scripted") }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["messages": [["role": "user", "content": text]]])
        let (data, response) = try await transport.send(request)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard response.statusCode == 200, let body else {
            let message = ((body?["error"] as? [String: Any])?["message"] as? String) ?? "status \(response.statusCode)"
            return .notReceived(message)
        }
        let reply = ((body["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
        let usage = body["usage"] as? [String: Any] ?? [:]
        let count = { (key: String) in (usage[key] as? NSNumber)?.intValue ?? 0 }
        return .reply(reply, context: count("input_tokens") + count("cache_read_input_tokens") + count("cache_creation_input_tokens"),
                      output: count("output_tokens"), model: body["model"] as? String ?? "claude-haiku-4-5-20251001")
    }

    private func file(_ session: String) -> URL {
        home.appendingPathComponent(".claude/projects/-home-topo/\(session).jsonl")
    }

    private func append(_ object: [String: Any], session: String) {
        let url = file(session)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var line = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    private func write(input text: String, id: String, session: String) {
        append(["type": "user", "uuid": id, "sessionId": session, "message": ["role": "user", "content": text]], session: session)
    }

    private func write(reply text: String, model: String, session: String) {
        let id = lock.withLock { () -> Int in messages += 1; return messages }
        append(["type": "assistant", "uuid": UUID().uuidString, "sessionId": session,
                "message": ["id": "msg-\(id)", "model": model, "role": "assistant", "stop_reason": "end_turn",
                            "content": [["type": "text", "text": text]]]], session: session)
    }
}

extension XCTestCase {
    /// The guest as a harness's brain, answering from `transport`: a `GuestBridge` over a
    /// `ScriptedGuest` with a home and a ledger of its own, removed when the test ends.
    func guestBrain(over transport: any Transport) -> any Brain {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guest-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let guest = ScriptedGuest(home: directory.appendingPathComponent("home"), transport: transport)
        return GuestBridge(conversation: guest, ledger: directory.appendingPathComponent("ledger.json"))
    }
}
