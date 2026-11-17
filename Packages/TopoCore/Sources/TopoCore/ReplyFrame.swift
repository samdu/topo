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
    /// The mind's answer on the reply ended without one (it threw): its process exited, it
    /// stalled, the turn failed, or the mind stopped or slept under it. What was streamed is no
    /// reply, and goes; the turn may still be answered later, in the log, by a pass that asks it
    /// again, the turn heard again at a wake, or the phone once the lease lapses. A reply the mind
    /// finished and could not save is owed, and comes in the log: no `cut`.
    case cut

    /// The frame as one line of JSON with its newline: a reply's words carry newlines of their own.
    public var line: Data {
        let object: [String: Any] = switch self {
        case .turn(let refs): ["k": "turn", "refs": refs.map(\.description)]
        case .message: ["k": "message"]
        case .text(let text): ["k": "text", "t": text]
        case .tool: ["k": "tool"]
        case .cut: ["k": "cut"]
        }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// The frame as lines of no more than `maximum` bytes each, newline included: words whose line
    /// would be longer go as several `text` frames, split between characters, which run together
    /// into the same words. A single character whose line is longer still goes whole.
    public func lines(within maximum: Int) -> [Data] {
        let whole = line
        guard whole.count > maximum, case .text(let text) = self, text.count > 1 else { return [whole] }
        let half = text.index(text.startIndex, offsetBy: text.count / 2)
        return ReplyFrame.text(String(text[..<half])).lines(within: maximum)
            + ReplyFrame.text(String(text[half...])).lines(within: maximum)
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
        case "cut": self = .cut
        default: return nil
        }
    }
}
