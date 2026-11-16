import Foundation

/// One event of Claude Code's `--output-format stream-json --verbose` output, as far as the Mac's
/// mind reads it. The rules are the phone's (`StreamJSON` in TopoUserland, which is iOS-only and so
/// not linked here): a sub-agent's line and a message Claude Code wrote in the model's place carry
/// none of the reply's words, and a turn is the app's from its input's echo
/// (`--replay-user-messages`) to its result.
enum MindEvent: Sendable, Equatable {
    /// `system`/`init`: the session and the model of the turn about to begin.
    case started(session: String, model: String)
    /// A text block of an assistant message of the turn's own, with the message's id.
    case text(String, message: String?)
    /// A message of the turn's own begun (`stream_event` `message_start`, from
    /// `--include-partial-messages`): the words `writing` gives next are its own.
    case writingBegan
    /// The next characters of a text block of the turn's own (`content_block_delta`, `text_delta`).
    case writing(String)
    /// A tool call begun in a message of the turn's own (`content_block_start` of a `tool_use`).
    case toolCallBegan
    /// An assistant line Claude Code wrote because the login failed (`error: authentication_failed`).
    case signedOut
    /// An assistant message's usage: context tokens (input and cache together) and output tokens.
    case usage(context: Int, output: Int)
    /// An input of the app's echoed as Claude Code takes it up, by its `uuid`.
    case received(id: String)
    /// A turn's end.
    case result(Result)
    /// The answer to a control request, by its id.
    case controlResponse(id: String)
    /// Anything else, named by its type.
    case other(String)
    /// A line that is not an event.
    case malformed

    struct Result: Sendable, Equatable {
        var isError: Bool
        var subtype: String
        var text: String?
        var session: String?
        /// The input the result ends (`user_message_uuid`), when Claude Code names it.
        var input: String?
        var errors: [String]
    }
}

enum MindStream {
    /// The model Claude Code names on a message it wrote itself.
    static let synthetic = "<synthetic>"

    static func events(in line: String) -> [MindEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any],
              let type = object["type"] as? String else { return [.malformed] }
        let subtype = object["subtype"] as? String
        let subagents = object["parent_tool_use_id"] is String
        switch (type, subtype) {
        case ("system", "init"):
            guard let session = object["session_id"] as? String else { return [.malformed] }
            return [.started(session: session, model: object["model"] as? String ?? "")]
        case ("assistant", _):
            guard !subagents, let message = object["message"] as? [String: Any] else { return [.other(type)] }
            if object["error"] as? String == "authentication_failed" { return [.signedOut] }
            var events: [MindEvent] = []
            let replies = object["isApiErrorMessage"] as? Bool != true && message["model"] as? String != synthetic
            if replies, let content = message["content"] as? [Any] {
                for case let block as [String: Any] in content where block["type"] as? String == "text" {
                    if let text = block["text"] as? String, !text.isEmpty {
                        events.append(.text(text, message: message["id"] as? String))
                    }
                }
            }
            if let usage = message["usage"] as? [String: Any] {
                let context = int(usage["input_tokens"]) + int(usage["cache_creation_input_tokens"])
                    + int(usage["cache_read_input_tokens"])
                events.append(.usage(context: context, output: int(usage["output_tokens"])))
            }
            return events
        case ("stream_event", _):
            // A sub-agent's message is written inside a tool call of the turn's: none of it is the
            // reply's words. The phone's rules (`StreamJSON`).
            guard !subagents, let event = object["event"] as? [String: Any] else { return [.other(type)] }
            switch event["type"] as? String {
            case "message_start":
                return [.writingBegan]
            case "content_block_start":
                guard (event["content_block"] as? [String: Any])?["type"] as? String == "tool_use" else { return [.other(type)] }
                return [.toolCallBegan]
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String, !text.isEmpty else { return [.other(type)] }
                return [.writing(text)]
            default:
                return [.other(type)]
            }
        case ("user", _) where object["isReplay"] as? Bool == true:
            guard let id = object["uuid"] as? String else { return [.other("user/replay")] }
            return [.received(id: id)]
        case ("control_response", _):
            guard let response = object["response"] as? [String: Any], let id = response["request_id"] as? String else {
                return [.other(type)]
            }
            return [.controlResponse(id: id)]
        case ("result", _):
            let subtype = subtype ?? ""
            return [.result(.init(isError: (object["is_error"] as? Bool) ?? (subtype != "success"), subtype: subtype,
                                  text: object["result"] as? String, session: object["session_id"] as? String,
                                  input: object["user_message_uuid"] as? String,
                                  errors: (object["errors"] as? [Any])?.compactMap { $0 as? String } ?? []))]
        default:
            return [.other(subtype.map { "\(type)/\($0)" } ?? type)]
        }
    }

    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

    /// The control request a launch writes first; Claude Code answers it once it reads its input.
    static func initialize(id: String) -> String {
        line(["type": "control_request", "request_id": id, "request": ["subtype": "initialize"]])
    }

    /// The input that asks for a turn, under `id`, which the echo and the result carry back.
    static func userTurn(_ text: String, id: String) -> String {
        line(["type": "user", "uuid": id, "message": ["role": "user", "content": text]])
    }

    private static func line(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

/// The words of one reply over the assistant messages of its turn, one message's from the next's
/// parted by a paragraph break: the phone's `ReplyWords`, for the same bytes on both.
struct MindWords: Sendable {
    private var messages: [String] = []
    private var open: String??

    mutating func append(_ text: String, of id: String?) {
        if open != .some(id) {
            messages.append("")
            open = .some(id)
        }
        messages[messages.count - 1] += text
    }

    var text: String { messages.filter { !$0.allSatisfy(\.isWhitespace) }.joined(separator: "\n\n") }
}
