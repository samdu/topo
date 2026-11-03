import Foundation

/// A Messages API request body made into what the on-device model can take: Topo's own short
/// instructions, the conversation's words, and the last thing the person said as the prompt.
///
/// Claude Code's own request is several times the model's window (its system prompt and its tool
/// definitions alone are ~14 K tokens), so none of it is passed through: its `system` blocks, its
/// tools and its `system`-role messages are dropped, `<system-reminder>` spans are cut out of the
/// words, and thinking, tool calls and tool results are dropped, a turn that was nothing else
/// with them. No stand-in for a tool is written into the history: a model this small copies the
/// last pattern it sees, and given `[used Bash]` lines it answers with one (measured on a phone,
/// build 441914). An image or a document is a bracketed line in the prompt only, so the model
/// knows one was sent, and nothing in the history. What is left is trimmed from the oldest turn
/// until it fits (`fit`).
public struct MessagesTranslation: Sendable, Equatable {
    public var history: [LocalTurn]
    public var prompt: String
    /// Whether the request asked for a stream.
    public var stream: Bool

    /// What the on-device model is told it is. It is not Claude Code's prompt, which is mostly
    /// about tools it is not given.
    public static let instructions = """
        You are Topo, a friendly assistant that lives on this person's iPhone. Right now you are \
        running on Apple's on-device model, entirely on the phone: you have no tools, you cannot \
        read or write the person's memory, and you cannot reach the internet. Answer briefly and \
        plainly. When asked for something that needs tools, the memory or the internet, say you \
        can't do that on the on-device model, and that the person can choose a Claude model on \
        the slider when they are signed in with Claude.
        """

    /// The tokens kept free for the reply.
    public static let replyReserve = 1024

    public enum Failure: Error, Equatable {
        /// The body is not a Messages API request: the words say what is wrong with it.
        case unreadable(String)
    }

    /// The request in `body`, translated. A conversation with no words of the person's in it
    /// becomes an empty prompt rather than a refusal: Claude Code asks such a thing of the model
    /// only for its own purposes, and an empty answer serves them.
    public static func translate(_ body: Data) throws -> MessagesTranslation {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw Failure.unreadable("the body is not a JSON object")
        }
        guard let messages = object["messages"] as? [[String: Any]] else { throw Failure.unreadable("no messages") }
        var turns: [LocalTurn] = []
        let last = messages.lastIndex { ($0["role"] as? String).flatMap(LocalTurn.Role.init(rawValue:)) != nil }
        for (index, message) in messages.enumerated() {
            guard let role = (message["role"] as? String).flatMap(LocalTurn.Role.init(rawValue:)) else { continue }
            let text = words(of: message["content"], attachments: index == last && role == .user)
            guard !text.isEmpty else { continue }
            // Two turns of one side in a row are one turn: the model's transcript alternates.
            if let last = turns.last, last.role == role {
                turns[turns.count - 1].text += "\n\n" + text
            } else {
                turns.append(LocalTurn(role, text))
            }
        }
        var prompt = ""
        if let last = turns.last, last.role == .user {
            prompt = last.text
            turns.removeLast()
        }
        return MessagesTranslation(history: turns, prompt: prompt, stream: object["stream"] as? Bool ?? false)
    }

    /// The words of a message's `content`: a string, or the text of its blocks, with an image or a
    /// document said as a bracketed line only where `attachments` (the prompt).
    static func words(of content: Any?, attachments: Bool = false) -> String {
        if let text = content as? String { return withoutReminders(text) }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            switch block["type"] as? String {
            case "text": return (block["text"] as? String).map(withoutReminders)
            case "image": return attachments ? "[image]" : nil
            case "document": return attachments ? "[document]" : nil
            default: return nil
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// `text` with every `<system-reminder>…</system-reminder>` span cut out, an unclosed one to
    /// the end, and trimmed.
    static func withoutReminders(_ text: String) -> String {
        var rest = Substring(text)
        var kept = ""
        while let open = rest.range(of: "<system-reminder>") {
            kept += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "</system-reminder>") else { rest = ""; break }
            rest = rest[close.upperBound...]
        }
        kept += rest
        return kept.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The marker put where the start of a prompt too long for the window was cut.
    public static let cutMarker = "[…the start of this message was too long for the on-device model and was left out]\n\n"

    /// This translation made to fit `model`'s window with `replyReserve` left over: the oldest
    /// turns go first, a pair at a time so the history still begins with the person, and a prompt
    /// that does not fit alone is cut from its start. Answers the fitted translation, its count,
    /// and how many turns were left out.
    public func fit(_ model: any LocalModel) async throws -> (MessagesTranslation, tokens: Int, dropped: Int) {
        let window = await model.contextSize()
        // A window the model did not say is not one a message is too long for.
        guard window > 0 else { throw LocalModelError.unavailable("Apple's on-device model didn't say how much it can read.") }
        let budget = window - Self.replyReserve
        guard budget > 0 else { throw LocalModelError.tooLong }
        var fitted = self
        var dropped = 0
        var count = try await model.tokenCount(instructions: Self.instructions, history: fitted.history, prompt: fitted.prompt)
        while count > budget, !fitted.history.isEmpty {
            let pair = fitted.history.count >= 2 && fitted.history[0].role == .user ? 2 : 1
            fitted.history.removeFirst(pair)
            dropped += pair
            count = try await model.tokenCount(instructions: Self.instructions, history: fitted.history, prompt: fitted.prompt)
        }
        // A prompt too long alone keeps its end, which is what was said last. Each pass keeps the
        // share of it the budget allows, less a tenth, so a handful of passes at most.
        var passes = 0
        while count > budget, passes < 8 {
            passes += 1
            let body = fitted.prompt.hasPrefix(Self.cutMarker) ? String(fitted.prompt.dropFirst(Self.cutMarker.count)) : fitted.prompt
            let keep = max(0, Int(Double(body.count) * Double(budget) / Double(count) * 0.9))
            guard keep > 0 else { throw LocalModelError.tooLong }
            fitted.prompt = Self.cutMarker + String(body.suffix(keep))
            count = try await model.tokenCount(instructions: Self.instructions, history: fitted.history, prompt: fitted.prompt)
        }
        guard count <= budget else { throw LocalModelError.tooLong }
        return (fitted, count, dropped)
    }
}
