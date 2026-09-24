import Foundation

/// One event of Claude Code's `--output-format stream-json --verbose` output, as far as the app
/// reads it: what a turn said, that it thought, which tools it called and the file a writing tool
/// names, what each tool's result said and whether it was an error, the model and how much
/// context it holds, and how it ended. Everything else in a line is
/// left unread.
public enum StreamEvent: Sendable, Equatable {
    /// `system`/`init`: the session and the model the process answers with. Claude Code writes it
    /// once the first input arrives, not at start, and again before every turn after that.
    case started(session: String, model: String)
    /// A text block of an assistant message.
    case text(String)
    /// A tool the assistant called, by name. For a tool that writes a file — `Write`, `Edit`,
    /// `MultiEdit`, `NotebookEdit` (`StreamJSON.fileTools`) — `path` is the file it names, which is
    /// what says whether the turn is writing code, prose or the memory; nothing else of a tool's
    /// input is read, and every other tool's path is nil.
    case toolUse(name: String, path: String? = nil)
    /// A tool's result coming back, in a `user` message: whether Claude Code marked it an error
    /// (`is_error`), and its text — the result's string, or its text blocks joined by newlines.
    /// It names the call it answers only by `tool_use_id`, which is not read: calls made one at a
    /// time come back in the order they were made (`Tests/StreamJSON/tool-turn.jsonl`).
    case toolResult(isError: Bool, text: String)
    /// A thinking block of an assistant message: that the model thought, and nothing of what.
    case thinking
    /// An assistant message's usage.
    case usage(Usage)
    /// The turn's end, answered or failed.
    case result(TurnResult)
    /// A well-formed event of a kind the app does not read — a hook's lines, a rate-limit notice,
    /// a `user` message carrying no tool result — named by its `type` and `subtype`.
    case other(String)
    /// A line that is not an event: not JSON, not an object, or an object with no `type`. It is
    /// reported and never read as anything.
    case malformed(String)

    /// An assistant message's usage: the model that wrote it, the tokens of context it was
    /// written over (input, cache written and cache read together) and the tokens it wrote.
    public struct Usage: Sendable, Equatable {
        public let model: String
        public let context: Int
        public let output: Int

        public init(model: String, context: Int, output: Int) {
            self.model = model
            self.context = context
            self.output = output
        }
    }

    /// A turn's `result` line. `duration` is that turn's own (`duration_ms`); `duration_api_ms` is
    /// not read, since it is a running total over the session rather than the turn's.
    public struct TurnResult: Sendable, Equatable {
        public let isError: Bool
        public let subtype: String
        /// The reply's text, or the error's where Claude Code put one there.
        public let text: String?
        public let session: String?
        public let duration: Duration?
        /// What an error result listed under `errors`, if anything.
        public let errors: [String]

        public init(isError: Bool, subtype: String, text: String?, session: String?, duration: Duration?,
                    errors: [String] = []) {
            self.isError = isError
            self.subtype = subtype
            self.text = text
            self.session = session
            self.duration = duration
            self.errors = errors
        }
    }
}

/// The parser: a pure function from one line of stdout to the events in it.
public enum StreamJSON {
    /// The events one line holds, in order: one for most lines, several for an assistant message
    /// carrying text and tool calls, none for an empty line.
    public static func events(in line: String) -> [StreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] else {
            return [.malformed(clip(trimmed))]
        }
        guard let type = object["type"] as? String else { return [.malformed(clip(trimmed))] }
        let subtype = object["subtype"] as? String
        switch (type, subtype) {
        case ("system", "init"):
            guard let session = object["session_id"] as? String, let model = object["model"] as? String else {
                return [.malformed(clip(trimmed))]
            }
            return [.started(session: session, model: model)]
        case ("assistant", _):
            return assistant(object) ?? [.malformed(clip(trimmed))]
        case ("user", _):
            let results = toolResults(object)
            return results.isEmpty ? [.other(subtype.map { "\(type)/\($0)" } ?? type)] : results
        case ("result", _):
            return [.result(result(object, subtype: subtype))]
        default:
            return [.other(subtype.map { "\(type)/\($0)" } ?? type)]
        }
    }

    private static func assistant(_ object: [String: Any]) -> [StreamEvent]? {
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [Any] else { return nil }
        var events: [StreamEvent] = []
        for case let block as [String: Any] in content {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty { events.append(.text(text)) }
            case "tool_use":
                if let name = block["name"] as? String {
                    events.append(.toolUse(name: name, path: fileTools[name].flatMap { key in
                        (block["input"] as? [String: Any])?[key] as? String
                    }))
                }
            case "thinking", "redacted_thinking":
                events.append(.thinking)
            default:
                break
            }
        }
        if let usage = message["usage"] as? [String: Any] {
            let context = int(usage["input_tokens"]) + int(usage["cache_creation_input_tokens"])
                + int(usage["cache_read_input_tokens"])
            events.append(.usage(.init(model: message["model"] as? String ?? "", context: context,
                                       output: int(usage["output_tokens"]))))
        }
        return events
    }

    /// The `tool_result` blocks of a `user` message, in order.
    private static func toolResults(_ object: [String: Any]) -> [StreamEvent] {
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [Any] else { return [] }
        return content.compactMap { item -> StreamEvent? in
            guard let block = item as? [String: Any], block["type"] as? String == "tool_result" else { return nil }
            let text: String
            switch block["content"] {
            case let string as String:
                text = string
            case let parts as [Any]:
                text = parts.compactMap { part in
                    guard let part = part as? [String: Any], part["type"] as? String == "text" else { return nil }
                    return part["text"] as? String
                }.joined(separator: "\n")
            default:
                text = ""
            }
            return .toolResult(isError: (block["is_error"] as? Bool) ?? false, text: text)
        }
    }

    /// The tools that write a file, and the key of their input that names it. The one thing read
    /// from any tool's input.
    public static let fileTools: [String: String] = [
        "Write": "file_path", "Edit": "file_path", "MultiEdit": "file_path", "NotebookEdit": "notebook_path",
    ]

    private static func result(_ object: [String: Any], subtype: String?) -> StreamEvent.TurnResult {
        let subtype = subtype ?? ""
        let isError = (object["is_error"] as? Bool) ?? (subtype != "success")
        let duration = (object["duration_ms"] as? NSNumber).map { Duration.milliseconds($0.int64Value) }
        let errors = (object["errors"] as? [Any])?.compactMap { $0 as? String } ?? []
        return .init(isError: isError, subtype: subtype, text: object["result"] as? String,
                     session: object["session_id"] as? String, duration: duration, errors: errors)
    }

    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

    /// A malformed line as it is reported: its start, since it may be anything.
    private static func clip(_ line: String) -> String {
        line.count <= 200 ? line : String(line.prefix(200)) + "…"
    }

    /// The input line that asks Claude Code for a turn: a `user` message carrying `text`. `id`,
    /// when given, is the message's `uuid`, which Claude Code keeps as the uuid of the entry it
    /// writes for the input in its session transcript — how the app finds, after the fact,
    /// whether that input was received and answered (`GuestTranscript`).
    public static func userTurn(_ text: String, id: String? = nil) -> String {
        var object: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        if let id { object["uuid"] = id }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
