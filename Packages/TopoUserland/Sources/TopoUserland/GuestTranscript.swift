import Foundation

/// Claude Code's own session transcript, read as the evidence of what became of one input.
///
/// Claude Code writes each session as `<home>/.claude/projects/<the working directory, flattened>/<session>.jsonl`
/// while it works, one JSON object per line: the input as a `user` entry whose `uuid` is the one
/// the input carried (`StreamJSON.userTurn(_:id:)`), then the assistant's messages, one entry per
/// content block, each carrying its message's `stop_reason`, with tool results between them as
/// `user` entries of their own. So after a crash, a teardown or an exit the app reads what happened
/// rather than guessing, and `verdict` is the whole of the reading.
public enum GuestTranscript {
    /// What became of an input.
    public enum Verdict: Sendable, Equatable {
        /// No entry carries the input's id: Claude Code never began it, so nothing it could do
        /// was done, and sending it is safe.
        case notReceived
        /// The input is there and the assistant finished a reply after it: the text of that
        /// reply's final message.
        case answered(String)
        /// The input is there and no finished reply follows it: it was cut off, or failed. It may
        /// have run tools, so sending it again could repeat what they did.
        case unresolved
    }

    /// The stop reasons that end a reply rather than wait on a tool's result.
    static let finished: Set<String> = ["end_turn", "stop_sequence", "max_tokens"]

    /// The verdict on the input `id` over a transcript's lines. Only what follows the input and
    /// comes before the next prompt counts: the reply is the last main-chain assistant message
    /// there, and it is finished when its stop reason is one that ends a turn and it holds text. An error Claude
    /// Code wrote in the model's place (`isApiErrorMessage`, or the `<synthetic>` model) is no
    /// reply. A line that is not a JSON object is skipped, since the last line of a transcript a
    /// process was killed while writing can be half a line.
    public static func verdict(for id: String, in lines: some Sequence<String>) -> Verdict {
        var received = false
        var last: (id: String?, stop: String?)?
        var texts: [(id: String?, text: String)] = []
        for line in lines {
            guard let entry = object(line) else { continue }
            let type = entry["type"] as? String
            if !received {
                if type == "user", entry["uuid"] as? String == id { received = true }
                continue
            }
            if type == "user", isPrompt(entry) { break }
            guard type == "assistant", entry["isSidechain"] as? Bool != true,
                  entry["isApiErrorMessage"] as? Bool != true,
                  let message = entry["message"] as? [String: Any],
                  message["model"] as? String != "<synthetic>" else { continue }
            let messageID = message["id"] as? String
            if last?.id != messageID { texts = [] }
            last = (messageID, message["stop_reason"] as? String)
            for case let block as [String: Any] in message["content"] as? [Any] ?? [] where block["type"] as? String == "text" {
                if let text = block["text"] as? String { texts.append((messageID, text)) }
            }
        }
        guard received else { return .notReceived }
        guard let last, let stop = last.stop, finished.contains(stop) else { return .unresolved }
        // Every block of the final message carries its stop reason, the thinking before the text
        // included, so a transcript cut between them ends on a finished message with no words
        // yet: no reply.
        let reply = texts.filter { $0.id == last.id }.map(\.text).joined()
        return reply.isEmpty ? .unresolved : .answered(reply)
    }

    /// The verdict on `id` from the transcripts under `home`: the session's own file first, then
    /// any other session file changed since `since` — an input sent while the session id was not
    /// yet known lands in whichever session the process began. Not received when no file holds it.
    public static func verdict(for id: String, home: URL, session: String?, since: Date) -> Verdict {
        for file in files(home: home, session: session, since: since) {
            guard let data = try? Data(contentsOf: file) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            // Cheap first: a file that does not mention the id has nothing to say about it.
            guard text.contains(id) else { continue }
            let verdict = verdict(for: id, in: text.split(separator: "\n").lazy.map(String.init))
            if verdict != .notReceived { return verdict }
        }
        return .notReceived
    }

    /// The session transcripts under `home`, the named session's first and then the rest changed
    /// since `since`, newest first.
    static func files(home: URL, session: String?, since: Date) -> [URL] {
        let projects = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        var named: [URL] = []
        var others: [(URL, Date)] = []
        for folder in folders {
            let entries = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in entries where file.pathExtension == "jsonl" {
                if let session, file.deletingPathExtension().lastPathComponent == session {
                    named.append(file)
                    continue
                }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if modified >= since.addingTimeInterval(-1) { others.append((file, modified)) }
            }
        }
        return named + others.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// A `user` entry that is a prompt rather than tool results coming back, or a note Claude Code
    /// adds for itself (`isMeta`): what starts the next turn.
    private static func isPrompt(_ entry: [String: Any]) -> Bool {
        guard entry["isMeta"] as? Bool != true, entry["isSidechain"] as? Bool != true,
              let message = entry["message"] as? [String: Any] else { return false }
        if message["content"] is String { return true }
        let blocks = (message["content"] as? [Any])?.compactMap { ($0 as? [String: Any])?["type"] as? String } ?? []
        return !blocks.isEmpty && !blocks.allSatisfy { $0 == "tool_result" }
    }

    private static func object(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any]
    }
}
