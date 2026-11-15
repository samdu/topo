import Foundation
import os

/// What the proxy saw of the last few `/v1/messages` requests that went through it: when, how
/// many bytes, whether each was on a message thread (a create or a continue) or carried the whole
/// conversation, and the status it was answered with. It is how the mind can tell that message
/// threads work, from the requests themselves rather than from the setting that asks for them.
///
/// Nothing of the person's is kept: no text, no header value, no message or thread id. It lives
/// in memory only, and the app clears it when a login ends.
///
/// The body is read only for a request whose `anthropic-beta` header names the threads beta,
/// which Claude Code sends with every thread request and with none other; so a request on no
/// thread is never parsed outside a timed run; a continue is some 40 kB to parse, and only a
/// process's create carries the whole conversation.
public final class ThreadLog: Sendable {
    public enum Kind: String, Sendable, Equatable {
        /// No threads beta: the whole conversation in the request.
        case none
        /// A thread begun: the whole conversation, held on Anthropic's side from here.
        case create
        /// A thread continued: only the messages since the last request.
        case `continue`
        /// The threads beta with no thread the proxy could read.
        case unread
    }

    public struct Sent: Sendable, Equatable {
        public let at: Date
        public let bytes: Int
        public let kind: Kind
        /// The answer's status, nil until its head has come; 502 for one the upstream never answered.
        public var status: Int?

        public init(at: Date, bytes: Int, kind: Kind, status: Int? = nil) {
            self.at = at
            self.bytes = bytes
            self.kind = kind
            self.status = status
        }
    }

    /// The one the app's proxy keeps.
    public static let shared = ThreadLog()

    /// How many requests are kept, the newest last.
    public static let kept = 12

    /// The prefix of the beta Claude Code names on a thread request (`message-threads-2026-08-12`
    /// at its pin).
    public static let beta = "message-threads"

    private struct State {
        var sent: [(id: Int, entry: Sent)] = []
        var next = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    /// Notes a request about to go upstream, and returns what its answer is noted under.
    func sent(bytes: Int, kind: Kind) -> Int {
        let at = now()
        return state.withLock { state in
            let id = state.next
            state.next += 1
            state.sent.append((id, Sent(at: at, bytes: bytes, kind: kind)))
            if state.sent.count > Self.kept { state.sent.removeFirst(state.sent.count - Self.kept) }
            return id
        }
    }

    /// The answer's status for the request noted as `id`; nothing for one cleared since.
    func answered(_ id: Int, status: Int) {
        state.withLock { state in
            guard let index = state.sent.firstIndex(where: { $0.id == id }) else { return }
            state.sent[index].entry.status = status
        }
    }

    /// The requests kept, oldest first.
    public func recent() -> [Sent] { state.withLock { $0.sent.map(\.entry) } }

    /// Forgets every request: a login has ended.
    public func clear() { state.withLock { $0.sent.removeAll() } }

    /// What a request is, from its headers and, only under the threads beta, its body's top-level
    /// `thread.type`.
    static func kind(headers: [HTTPField], body: Data) -> Kind {
        let betas = headers.filter { $0.name.lowercased() == "anthropic-beta" }
            .flatMap { $0.value.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard betas.contains(where: { $0.hasPrefix(beta) }) else { return .none }
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let thread = object["thread"] as? [String: Any], let type = thread["type"] as? String else { return .unread }
        switch type {
        case "create": return .create
        case "continue": return .continue
        default: return .unread
        }
    }
}
