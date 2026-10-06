import CryptoKit
import Foundation

/// What a timed run's marks say of a `/v1/messages` request and its answer: sizes, counts, where
/// the request asks for a cache breakpoint, a digest of each part so a part that changed between
/// two requests shows as one, and the token counts the API answered with. Nothing of the person's:
/// no text of the prompt, the tools, the conversation or the reply.
extension Forwarder {
    /// The body's parts: `system=<bytes>:<digest>,…` a block each, `tools=<count>:<bytes>:<digest>`,
    /// `messages=<count>:<bytes>`, `head=<digest>` of the first message, and `marks=` each
    /// `cache_control` by where it sits (`s` a system block, `t` a tool, `m` a message, by index)
    /// with its `ttl` when it names one. Nil when the body is not a JSON object.
    static func shapeForMark(_ body: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        func encoded(_ value: Any) -> Data {
            (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
        }
        func digest(_ data: Data) -> String {
            SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
        }
        var marks: [String] = []
        func note(_ block: Any, _ place: String) {
            guard let control = (block as? [String: Any])?["cache_control"] as? [String: Any] else { return }
            let ttl = (control["ttl"] as? String).flatMap { $0.wholeMatch(of: /[0-9]{1,3}[smh]/) == nil ? nil : "/\($0)" }
            marks.append(place + (ttl ?? ""))
        }
        let system: [Any] = (object["system"] as? [Any]) ?? (object["system"].map { [$0] } ?? [])
        let tools = (object["tools"] as? [Any]) ?? []
        let messages = (object["messages"] as? [Any]) ?? []
        for (index, block) in system.enumerated() { note(block, "s\(index)") }
        for (index, tool) in tools.enumerated() { note(tool, "t\(index)") }
        for (index, message) in messages.enumerated() {
            for block in ((message as? [String: Any])?["content"] as? [Any]) ?? [] { note(block, "m\(index)") }
        }
        func sized(_ value: Any) -> String {
            let data = encoded(value)
            return "\(data.count):\(digest(data))"
        }
        let systemPart: String = system.map(sized).joined(separator: ",")
        let headPart: String = messages.first.map { digest(encoded($0)) } ?? "-"
        let marksPart: String = marks.isEmpty ? "-" : marks.joined(separator: ",")
        return "system=\(systemPart) tools=\(tools.count):\(sized(tools)) messages=\(messages.count):\(encoded(messages).count)"
            + " head=\(headPart) marks=\(marksPart)"
    }

    /// The input a streamed answer's `message_start` counts, from the first bytes of the stream:
    /// `in=` uncached, `cacheRead=`, `cacheWrite=`. Nil until all three have arrived.
    static func usageForMark(_ head: Data) -> String? {
        let text = String(decoding: head, as: UTF8.self)
        guard let fresh = count("input_tokens", in: text), let read = count("cache_read_input_tokens", in: text),
              let written = count("cache_creation_input_tokens", in: text) else { return nil }
        return "in=\(fresh) cacheRead=\(read) cacheWrite=\(written)"
    }

    /// The last `"<field>":<n>` in `text`.
    static func count(_ field: String, in text: String) -> Int? {
        guard let name = text.range(of: "\"\(field)\":", options: .backwards) else { return nil }
        return Int(text[name.upperBound...].drop { $0 == " " }.prefix { $0.isNumber })
    }
}
