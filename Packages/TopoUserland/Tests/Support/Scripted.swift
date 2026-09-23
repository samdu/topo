import Foundation
import XCTest
import os
@testable import TopoUserland

/// A clock the test moves by hand: every sleep waits until `advance` passes its deadline, and a
/// cancelled sleep throws, as `Task.sleep` does.
actor ManualClock {
    private var now: Duration = .zero
    private var sleepers: [UUID: (deadline: Duration, continuation: CheckedContinuation<Void, Error>)] = [:]

    nonisolated var sleep: Sleep { { [self] duration in try await self.sleep(for: duration) } }

    /// How many sleeps are waiting.
    var pending: Int { sleepers.count }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        let deadline = now + duration
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers[id] = (deadline, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    func advance(by duration: Duration) {
        now += duration
        for (id, sleeper) in sleepers where sleeper.deadline <= now {
            sleepers.removeValue(forKey: id)
            sleeper.continuation.resume()
        }
    }
}

/// A resident process the test scripts: what it was sent, the lines it writes when the test says,
/// and a termination that can be held open to play a teardown that is still running.
final class ScriptedProcess: ResidentProcess, @unchecked Sendable {
    let lines: AsyncStream<String>
    let pid: Int32
    private static let pids = OSAllocatedUnfairLock(initialState: Int32(100))
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var sent: [String] = []
    private var ended = false
    private var gate: CheckedContinuation<Void, Never>?
    private var holdTermination = false
    var errors: String = ""
    private var asked: [Duration] = []
    private var answer: GuestProcess.Termination?
    /// What the next end answers instead of a confirmed one: an end the bound ran out on.
    func answerNextEnd(with termination: GuestProcess.Termination) { lock.withLock { answer = termination } }
    /// The bound each termination was asked for.
    var bounds: [Duration] { lock.withLock { asked } }

    init() {
        (lines, continuation) = AsyncStream<String>.makeStream()
        pid = Self.pids.withLock { $0 += 1; return $0 }
    }

    /// The turns written to it, as the text of each `user` message.
    var turns: [String] {
        lock.withLock { sent }.compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = object["message"] as? [String: Any] else { return nil }
            return message["content"] as? String
        }
    }

    var terminated: Bool { lock.withLock { ended } }

    func write(_ line: String) async throws {
        try lock.withLock {
            if ended { throw GuestProcess.Failure.inputClosed }
            sent.append(line)
        }
    }

    func emit(_ line: String) { continuation.yield(line) }

    /// The process lets go of stdout, as one that exited does.
    func close() { continuation.finish() }

    /// The next termination waits for `release`.
    func holdNextTermination() { lock.withLock { holdTermination = true } }

    func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            holdTermination = false
            defer { gate = nil }
            return gate
        }
        waiting?.resume()
    }

    var terminationHeld: Bool { lock.withLock { gate != nil } }

    func end(within bound: Duration) async -> GuestProcess.Termination {
        lock.withLock { asked.append(bound) }
        let hold = lock.withLock { holdTermination }
        if hold {
            await withCheckedContinuation { continuation in
                let released = lock.withLock { () -> Bool in
                    if !holdTermination { return true }
                    gate = continuation
                    return false
                }
                if released { continuation.resume() }
            }
        }
        lock.withLock { ended = true }
        continuation.finish()
        let scripted = lock.withLock { () -> GuestProcess.Termination? in defer { answer = nil }; return answer }
        return scripted ?? .init(status: 137, signalled: 1, running: 0, pipesClosed: true)
    }
}

/// A launcher that hands out a fresh `ScriptedProcess` per launch and remembers what each was asked
/// to resume; a launch can be held open to play a start that is still pending.
final class ScriptedLauncher: ResidentLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var made: [ScriptedProcess] = []
    private var resumes: [String?] = []
    private var holdNext = false
    private var gate: CheckedContinuation<Void, Never>?

    var processes: [ScriptedProcess] { lock.withLock { made } }
    var resumed: [String?] { lock.withLock { resumes } }
    var last: ScriptedProcess? { processes.last }

    func holdNextLaunch() { lock.withLock { holdNext = true } }

    var launchHeld: Bool { lock.withLock { gate != nil } }

    func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            holdNext = false
            defer { gate = nil }
            return gate
        }
        waiting?.resume()
    }

    func launch(resume session: String?) async throws -> any ResidentProcess {
        let hold = lock.withLock { () -> Bool in
            resumes.append(session)
            return holdNext
        }
        if hold {
            await withCheckedContinuation { continuation in
                let released = lock.withLock { () -> Bool in
                    if !holdNext { return true }
                    gate = continuation
                    return false
                }
                if released { continuation.resume() }
            }
        }
        let process = ScriptedProcess()
        lock.withLock { made.append(process) }
        return process
    }
}

/// Waits, in real time, for `condition` to hold: the session's own tasks run between the checks.
func eventually(_ what: String, within seconds: Double = 5, file: StaticString = #filePath, line: UInt = #line,
                isolation: isolated (any Actor)? = #isolation, _ condition: () async -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("never: \(what)", file: file, line: line)
}

/// Lines of stream-json as Claude Code writes them, for a scripted process to emit.
enum Lines {
    static func `init`(_ session: String, model: String = "claude-haiku-4-5-20251001") -> String {
        #"{"type":"system","subtype":"init","session_id":"\#(session)","model":"\#(model)","cwd":"/home/topo","tools":["Read"]}"#
    }

    static func text(_ text: String) -> String {
        #"{"type":"assistant","message":{"model":"claude-haiku-4-5-20251001","content":[{"type":"text","text":"\#(text)"}],"usage":{"input_tokens":3,"cache_creation_input_tokens":10,"cache_read_input_tokens":100,"output_tokens":5}},"session_id":"s"}"#
    }

    static func result(_ text: String, session: String, error: Bool = false) -> String {
        #"{"type":"result","subtype":"\#(error ? "error_during_execution" : "success")","is_error":\#(error),"result":"\#(text)","session_id":"\#(session)","duration_ms":1200,"duration_api_ms":900}"#
    }
}

/// The stream-json recordings under `Tests/StreamJSON`, read from the repository.
enum Recording {
    static func lines(_ name: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StreamJSON/\(name).jsonl")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).filter { !$0.isEmpty }
    }
}
