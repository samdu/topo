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
    /// A text block of an assistant message of the turn's own, and the id of the message it is
    /// a block of, which is what tells one message's words from the next's (`ReplyWords`). A
    /// sub-agent's message, and one Claude Code wrote in the model's place, make none: their
    /// words are no part of the reply.
    case text(String, message: String? = nil)
    /// The next few characters of a text block, as the model writes it (`--include-partial-messages`):
    /// what the screen draws before the message is whole. The whole block still comes as `text`.
    case writing(String)
    /// A message of the turn's own begun: what `writing` gives next is its words, not the last
    /// message's.
    case writingBegan
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
    /// `system`/`compact_boundary`: the conversation was compacted, by `/compact` or by Claude
    /// Code itself at its threshold, from `pre` tokens of context to `post`.
    case compacted(Compacted)
    /// `system`/`status` saying a compaction was tried and failed, with Claude Code's reason.
    case compactFailed(String)
    /// `system`/`background_tasks_changed`: how many tasks Claude Code has running in the
    /// background now (a `run_in_background` command, a background agent). Nothing of what they
    /// are is read: a task's description is the model's words and can carry the person's.
    case backgroundTasks(Int)
    /// An input of the app's echoed back as Claude Code takes it up (`--replay-user-messages`):
    /// a `user` line marked `isReplay`, carrying the `uuid` the input was written with. It comes
    /// after the `system/init` of the turn that answers that input and before any of that turn's
    /// messages, so it is what says which turn is whose: Claude Code also runs turns of its own,
    /// answering a background task's notice, whose lines and result come between an input being
    /// written and its turn beginning.
    case received(id: String)
    /// The turn's end, answered or failed.
    case result(TurnResult)
    /// Claude Code's answer to a control request of the app's, by the request's id: the answer to
    /// `StreamJSON.initialize` comes once it reads stdin, which is when it is ready for a turn.
    case controlResponse(id: String)
    /// A well-formed event of a kind the app does not read — a hook's lines, a rate-limit notice,
    /// a `user` message carrying no tool result — named by its `type` and `subtype`.
    case other(String)
    /// A line that is not an event: not JSON, not an object, or an object with no `type`. It is
    /// reported and never read as anything.
    case malformed(String)

    /// A compaction as Claude Code reports it.
    public struct Compacted: Sendable, Equatable {
        /// `manual` for `/compact`, `auto` for the threshold; whatever else Claude Code names.
        public let trigger: String
        public let pre: Int
        public let post: Int

        public init(trigger: String, pre: Int, post: Int) {
            self.trigger = trigger
            self.pre = pre
            self.post = post
        }
    }

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
        /// The context window of the model that answered, as Claude Code reports it
        /// (`modelUsage.<model>.contextWindow`, the largest where it names several); nil when it
        /// names none.
        public let window: Int?
        /// How long Claude Code took to send the turn's first request, when it says
        /// (`CLAUDE_CODE_EMIT_STARTUP_TIMING`, set only in a timed run).
        public let timing: Timing?

        public init(isError: Bool, subtype: String, text: String?, session: String?, duration: Duration?,
                    errors: [String] = [], window: Int? = nil, timing: Timing? = nil) {
            self.window = window
            self.timing = timing
            self.isError = isError
            self.subtype = subtype
            self.text = text
            self.session = session
            self.duration = duration
            self.errors = errors
        }
    }
}

extension StreamEvent.TurnResult {
    /// Claude Code's own account of the time from a turn's start to its first model request:
    /// numbers and the names of its phases, nothing of what was said.
    public struct Timing: Sendable, Equatable {
        /// `time_to_request_ms`: from the turn's start to its first request.
        public let toRequest: Int
        /// `time_to_request_cpu_ms`: the CPU the process spent in that window.
        public let cpu: Int?
        /// `time_to_request_from_spawn_ms`: from the process's spawn to that request, on a
        /// process's first turn.
        public let fromSpawn: Int?
        /// `time_to_request_phases_ms`: the window by phase, in milliseconds.
        public let phases: [String: Int]

        public init(toRequest: Int, cpu: Int? = nil, fromSpawn: Int? = nil, phases: [String: Int] = [:]) {
            self.toRequest = toRequest
            self.cpu = cpu
            self.fromSpawn = fromSpawn
            self.phases = phases
        }

        /// The mark's words: `request=<ms> cpu=<ms> spawn=<ms> phases=<name>:<ms>,…`, the phases
        /// largest first, and a phase name that is not a plain identifier left out.
        public var words: String {
            var words = ["request=\(toRequest)"]
            if let cpu { words.append("cpu=\(cpu)") }
            if let fromSpawn { words.append("spawn=\(fromSpawn)") }
            let named = phases.filter { $0.key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            if !named.isEmpty { words.append("phases=" + named.map { "\($0.key):\($0.value)" }.joined(separator: ",")) }
            return words.joined(separator: " ")
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
        case ("system", "compact_boundary"):
            guard let metadata = object["compact_metadata"] as? [String: Any],
                  let pre = metadata["pre_tokens"] as? NSNumber, let post = metadata["post_tokens"] as? NSNumber else {
                return [.other("system/compact_boundary")]
            }
            return [.compacted(.init(trigger: metadata["trigger"] as? String ?? "", pre: pre.intValue, post: post.intValue))]
        case ("system", "background_tasks_changed"):
            guard let tasks = object["tasks"] as? [Any] else { return [.other("system/background_tasks_changed")] }
            return [.backgroundTasks(tasks.count)]
        case ("system", "status") where object["compact_result"] as? String == "failed":
            return [.compactFailed(clip(object["compact_error"] as? String ?? "no reason given"))]
        case ("assistant", _):
            return assistant(object) ?? [.malformed(clip(trimmed))]
        case ("user", _) where object["isReplay"] as? Bool == true:
            // An echo has no tool result to read; one with no uuid names no input of the app's.
            guard let id = object["uuid"] as? String else { return [.other("user/replay")] }
            return [.received(id: id)]
        case ("user", _):
            let results = toolResults(object)
            return results.isEmpty ? [.other(subtype.map { "\(type)/\($0)" } ?? type)] : results
        case ("control_response", _):
            guard let response = object["response"] as? [String: Any], let id = response["request_id"] as? String else {
                return [.other("control_response")]
            }
            return [.controlResponse(id: id)]
        case ("result", _):
            return [.result(result(object, subtype: subtype))]
        case ("stream_event", _):
            // A sub-agent's message is written inside a tool call of the turn's: none of it is
            // the reply's words.
            guard !isSubagents(object), let event = object["event"] as? [String: Any] else { return [.other(type)] }
            switch event["type"] as? String {
            case "message_start":
                return [.writingBegan]
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String, !text.isEmpty else { return [.other(type)] }
                return [.writing(text)]
            default:
                return [.other(type)]
            }
        default:
            return [.other(subtype.map { "\(type)/\($0)" } ?? type)]
        }
    }

    private static func assistant(_ object: [String: Any]) -> [StreamEvent]? {
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [Any] else { return nil }
        // The same messages `GuestTranscript` reads a reply from: the turn's own, and the
        // model's — not a sub-agent's, and not an error Claude Code wrote in the model's place.
        let replies = !isSubagents(object) && object["isApiErrorMessage"] as? Bool != true
            && message["model"] as? String != synthetic
        var events: [StreamEvent] = []
        for case let block as [String: Any] in content {
            switch block["type"] as? String {
            case "text":
                if replies, let text = block["text"] as? String, !text.isEmpty {
                    events.append(.text(text, message: message["id"] as? String))
                }
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

    /// The model Claude Code names on a message it wrote itself: an API error, a notice.
    static let synthetic = "<synthetic>"

    /// Whether a line is a sub-agent's: one written inside a tool call (`parent_tool_use_id`),
    /// which Claude Code's transcript keeps as a sidechain. `GuestTranscript` reads an entry of
    /// the transcript by the same rule, so a recovered reply holds the words the live one did.
    static func isSubagents(_ object: [String: Any]) -> Bool {
        object["parent_tool_use_id"] is String
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
        let windows = (object["modelUsage"] as? [String: Any])?.values
            .compactMap { ($0 as? [String: Any])?["contextWindow"] as? NSNumber }.map(\.intValue).filter { $0 > 0 }
        return .init(isError: isError, subtype: subtype, text: object["result"] as? String,
                     session: object["session_id"] as? String, duration: duration, errors: errors,
                     window: windows?.max(), timing: timing(object))
    }

    private static func timing(_ object: [String: Any]) -> StreamEvent.TurnResult.Timing? {
        guard let toRequest = (object["time_to_request_ms"] as? NSNumber)?.intValue else { return nil }
        let phases = (object["time_to_request_phases_ms"] as? [String: Any])?
            .compactMapValues { ($0 as? NSNumber)?.intValue } ?? [:]
        return .init(toRequest: toRequest, cpu: (object["time_to_request_cpu_ms"] as? NSNumber)?.intValue,
                     fromSpawn: (object["time_to_request_from_spawn_ms"] as? NSNumber)?.intValue, phases: phases)
    }

    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

    /// A malformed line as it is reported: its start, since it may be anything.
    private static func clip(_ line: String) -> String {
        line.count <= 200 ? line : String(line.prefix(200)) + "…"
    }

    /// The control request a launch writes first: `initialize`, carrying nothing, which Claude Code
    /// answers (`controlResponse`) once it is reading its input, so its answer is the moment the
    /// process is ready for a turn.
    public static func initialize(id: String) -> String {
        let object: [String: Any] = ["type": "control_request", "request_id": id, "request": ["subtype": "initialize"]]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
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
