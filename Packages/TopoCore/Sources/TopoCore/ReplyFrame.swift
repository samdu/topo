import Foundation

/// One piece of a reply as a hub's mind writes it, for a phone that asked for its turn's reply to
/// be streamed over the nudge's connection (`HubNudge`, `HubMind.nudge`). The reply's words and
/// where its messages and tool calls begin, nothing else: no tool's name, input or output, and
/// nothing a sub-agent wrote. The log's reply, written under the same nonce, is the truth; this
/// is what the phone draws and reads aloud while it waits for it.
public enum ReplyFrame: Sendable, Equatable {
    /// The mind is answering these person turns, in one reply continuing them all: every frame
    /// after this one, until the next, is that reply's.
    case turn([TurnRef])
    /// A message of the reply begun (`StreamEvent.writingBegan`).
    case message
    /// The next characters of the message's words (`StreamEvent.writing`).
    case text(String)
    /// A tool call begun in the message: its words so far are whole (`StreamEvent.toolCallBegan`).
    case tool

    /// The frame as one line of JSON with its newline: a reply's words carry newlines of their own.
    public var line: Data {
        let object: [String: Any] = switch self {
        case .turn(let refs): ["k": "turn", "refs": refs.map(\.description)]
        case .message: ["k": "message"]
        case .text(let text): ["k": "text", "t": text]
        case .tool: ["k": "tool"]
        }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// The frame a line holds, or nil for a line that is not one.
    public init?(line: String) {
        guard line.hasPrefix("{"),
              let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let kind = object["k"] as? String else { return nil }
        switch kind {
        case "turn":
            guard let refs = (object["refs"] as? [String])?.compactMap(TurnRef.init(parsing:)), !refs.isEmpty else { return nil }
            self = .turn(refs)
        case "message": self = .message
        case "text":
            guard let text = object["t"] as? String else { return nil }
            self = .text(text)
        case "tool": self = .tool
        default: return nil
        }
    }
}
