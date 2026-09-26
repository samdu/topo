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

/// The run every phone tool shares: the permission first (asked on this call if it never has
/// been, `PermissionBroker`), then the arguments parsed, then the store; a failure of the store is
/// the tool's own sentence, and anything else it throws is said as it is.
enum PhoneTool {
    static func run(_ authorizer: any Authorizer, broker: PermissionBroker, usage: String,
                    _ body: () async throws -> ToolReply) async -> ToolReply {
        if let refusal = await broker.admit(authorizer) { return refusal }
        do {
            return try await body()
        } catch let refusal as Arguments.Refusal {
            return .usage("topo: \(refusal)\n\n\(usage)\n")
        } catch let failure as ToolFailure {
            return ToolReply(status: failure.status, text: "topo: \(failure.text)\n")
        } catch {
            return .failed("topo: \(error.localizedDescription)\n")
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
