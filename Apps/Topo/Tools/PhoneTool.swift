import Foundation
import os
import TopoTools

/// What a phone tool's store throws when it cannot do what it was asked: the sentence the call
/// answers with.
struct ToolFailure: Error, Equatable {
    let text: String
    var status: Int32 = ToolReply.failed
    init(_ text: String, status: Int32 = ToolReply.failed) {
        self.text = text
        self.status = status
    }
}

/// A call that is not one the tool takes, said with the tool's usage after it.
struct Misuse: Error {
    let text: String
    init(_ text: String) { self.text = text }
}

/// The run every phone tool shares: the arguments read into a call first, so a call the tool does
/// not take is answered without asking anything; then the permission (asked on this call if it
/// never has been, `PermissionBroker`); then the store. A failure of the store is the tool's own
/// sentence, and anything else it throws is said as it is.
enum PhoneTool {
    static func run<Call>(_ authorizer: any Authorizer, broker: PermissionBroker, usage: String,
                          parse: () throws -> Call, perform: (Call) async throws -> ToolReply) async -> ToolReply {
        let call: Call
        do {
            call = try parse()
        } catch {
            return reply(to: error, usage: usage)
        }
        if let refusal = await broker.admit(authorizer) { return refusal }
        // Cancelled is the service's bound passed while the prompt was up: the caller has been
        // told the call timed out, so it does nothing now, whatever the person chose. The choice
        // stands for the next call.
        guard !Task.isCancelled else { return late }
        do {
            return try await perform(call)
        } catch {
            return reply(to: error, usage: usage)
        }
    }

    /// What a cancelled call answers. Nobody reads it: the service answered status 4 at its bound.
    static let late = ToolReply(status: ToolReply.timedOut, text: "topo: cancelled at the bound; nothing was done\n")

    private static func reply(to error: any Error, usage: String) -> ToolReply {
        switch error {
        case let refusal as Arguments.Refusal: .usage("topo: \(refusal)\n\n\(usage)\n")
        case let misuse as Misuse: .usage("topo: \(misuse.text)\n\n\(usage)\n")
        case let failure as ToolFailure: ToolReply(status: failure.status, text: "topo: \(failure.text)\n")
        case is CancellationError: late
        default: .failed("topo: \(error.localizedDescription)\n")
        }
    }

    /// A date option, or a usage error naming it.
    static func date(_ text: String?, _ option: String) throws -> ToolDates.Reading? {
        guard let text else { return nil }
        guard let reading = ToolDates.read(text) else {
            throw ToolFailure("\(option) \(text) is not a date; write it as 2026-09-27, 2026-09-27T14:30 or 2026-09-27T14:30:00-07:00", status: ToolReply.usage)
        }
        return reading
    }

    /// One record a line, fields apart by ` | `, nothing where a field is empty.
    static func line(_ fields: [String?]) -> String {
        fields.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " | ")
    }

    /// What `work` answers if it answers within `bound`, and nil at the bound otherwise, without
    /// waiting for a `work` that does not stop when it is no longer wanted.
    static func within<T: Sendable>(_ bound: Duration, _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let answered = OSAllocatedUnfairLock(initialState: false)
            let answer: @Sendable (T?) -> Void = { value in
                let first = answered.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            Task { answer(await work()) }
            Task {
                try? await Task.sleep(for: bound)
                answer(nil)
            }
        }
    }

    static func lines(_ lines: [String], none: String) -> String {
        lines.isEmpty ? none + "\n" : lines.joined(separator: "\n") + "\n"
    }
}

/// A framework object whose calls block — EventKit's fetches and saves, Contacts' fetches —
/// reachable only through this, whose closures run on a serial queue of its own and never on the
/// cooperative pool.
final class Confined<Value>: @unchecked Sendable {
    let queue: DispatchQueue
    private let value: Value

    init(_ value: Value, label: String) {
        self.value = value
        queue = DispatchQueue(label: label)
    }

    /// `work` on the queue. A call cancelled before the queue reaches it never runs `work`;
    /// `work` calls `cancellation.check()` right before it changes anything, so a call cancelled
    /// while it waited changes nothing. A save already under way when the call is cancelled
    /// finishes.
    func run<T: Sendable>(_ work: @escaping @Sendable (Value, Cancellation) throws -> T) async throws -> T {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        try cancellation.check()
                        return try work(self.value, cancellation)
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// `body` on the queue, for the framework's calls that answer on a block of their own (a
    /// fetch, a permission prompt) rather than returning.
    func async(_ body: @escaping @Sendable (Value) -> Void) {
        queue.async { body(self.value) }
    }
}

/// Whether the call a `Confined` closure runs for has been cancelled.
final class Cancellation: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    func cancel() { cancelled.withLock { $0 = true } }

    /// Throws `CancellationError` once the call is cancelled.
    func check() throws {
        if cancelled.withLock({ $0 }) { throw CancellationError() }
    }
}
