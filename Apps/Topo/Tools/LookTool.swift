import Foundation
import TopoTools

/// `topo look`: the mind's hand on this phone's look. It shows what the phone is wearing, sets a
/// field of it and takes a field back, all through `Tuning`, so a change is worn at once, kept on
/// this device, and undone by the settings sheet's Reset as a slider's is. What it may set is
/// whatever `LookDocument` reads, judged by that reader before anything is kept.
struct LookTool: Tool {
    /// The look under this device's override: the vault's (in a debug build the launch's, where
    /// one was given), and the reading that made it, which knows which fields it set.
    let vault: @MainActor @Sendable () -> (look: Look, reading: LookDocument.Reading)
    var tuning: @MainActor @Sendable () -> Tuning = { .shared }

    let name = "look"
    let summary = "this phone's look: show it, set a field of it, take a field back"
    let usage = """
    topo look                                   what this phone is wearing: the fields most worth tuning, each with
                                                its value, its range and where the value came from; every other field
                                                set on this phone; and what the vault's look.json said about itself
    topo look set <part.field> <value> [<part.field> <value> …]
                                                set fields on this phone, at once; each is judged by the look's own
                                                reader and one it refuses changes nothing and says why
    topo look reset [<part.field> …]            take those fields back (all of them with none named): the vault's
                                                look is worn there again. A field is taken back whole: mascot.pin,
                                                not mascot.pin.x

    A value is JSON where it parses as JSON (24, 0.5, ["#101010", "#F0F0F0"], {"x": 0.5, "y": 0.2})
    and a plain word otherwise (glass, roam, #1E8C9E). Lengths are points.
    Examples: topo look set transcript.replyTrailingInset 24 transcript.personLeadingInset 24
              topo look set mascot.scale 1.5
              topo look reset mascot.scale
    """

    /// The fields `topo look` always shows, as the reader names and bounds them.
    struct Field: Sendable {
        let path: String
        let range: String
        let value: @Sendable (Look) -> String
    }

    static let fields: [Field] = {
        @Sendable func points(_ number: CGFloat) -> String { number.isFinite ? String(format: "%g pt", Double(number)) : "infinity" }
        return [
            Field(path: "transcript.horizontalPadding", range: "0–4000 pt") { points($0.transcript.horizontalPadding) },
            Field(path: "transcript.replyTrailingInset", range: "0–200 pt") { points($0.transcript.replyTrailingInset) },
            Field(path: "transcript.personLeadingInset", range: "0–200 pt") { points($0.transcript.personLeadingInset) },
            Field(path: "transcript.spacing", range: "0–4000 pt") { points($0.transcript.spacing) },
            Field(path: "transcript.maximumLineWidth", range: "0–20000 pt or \"infinity\"") { points($0.transcript.maximumLineWidth) },
            Field(path: "mascot.placement", range: Look.Mascot.Placement.allCases.map(\.rawValue).joined(separator: ", ")) { $0.mascot.placement.rawValue },
            Field(path: "mascot.scale", range: "0.25–4 pt a pixel") { String(format: "%g pt a pixel", Double($0.mascot.scale)) },
            Field(path: "mascot.clearance", range: "0–64 pt") { points($0.mascot.clearance) },
            Field(path: "mascot.roamSpeed", range: "10–400 pt a second") { String(format: "%g pt a second", Double($0.mascot.roamSpeed)) },
            Field(path: "mind.sonnet", range: "a name, 1–\(Look.Mind.longest) characters") { $0.mind.sonnet },
            Field(path: "mind.opus", range: "a name, 1–\(Look.Mind.longest) characters") { $0.mind.opus },
            Field(path: "mind.fable", range: "a name, 1–\(Look.Mind.longest) characters") { $0.mind.fable },
        ]
    }()

    func run(_ arguments: [String]) async -> ToolReply {
        await MainActor.run { answer(arguments) }
    }

    @MainActor
    private func answer(_ arguments: [String]) -> ToolReply {
        let tuning = tuning()
        let (look, reading) = vault()
        switch arguments.first {
        case nil, "show":
            return .ok(show(worn: tuning.worn(over: look), tuning: tuning, reading: reading))
        case "set":
            let pairs = Array(arguments.dropFirst())
            guard !pairs.isEmpty, pairs.count.isMultiple(of: 2) else {
                return .usage("topo look set takes a field and a value, as many pairs as you like\n\n\(usage)\n")
            }
            var lines: [String] = []
            var (kept, refused) = (0, 0)
            for index in stride(from: 0, to: pairs.count, by: 2) {
                let (field, text) = (pairs[index], pairs[index + 1])
                let answer = tuning.set(Self.path(field), to: Self.value(text), over: tuning.worn(over: look))
                if answer.refused.isEmpty {
                    lines.append("set: \(field) \(text)")
                } else {
                    lines += answer.kept.map { "set: \($0)" }
                    lines += answer.refused.map { "refused: \($0)" }
                }
                kept += answer.kept.count
                refused += answer.refused.count
            }
            if kept > 0 {
                lines.append("Worn now on this phone; Settings › Reset, or topo look reset, takes it back.")
            }
            return ToolReply(status: refused == 0 ? ToolReply.ok : ToolReply.refused, text: lines.joined(separator: "\n") + "\n")
        case "reset":
            let named = Array(arguments.dropFirst())
            if named.isEmpty {
                let had = !tuning.isEmpty
                tuning.reset()
                return .ok(had ? "reset: everything this phone had set; the vault's look is worn again\n"
                               : "reset: nothing was set on this phone\n")
            }
            let taken = tuning.reset(named.map(Self.path))
            var refused = false
            let lines = zip(named, taken).map { name, taken in
                switch taken {
                case .reset: return "reset: \(name)"
                case .unset: return "unchanged: \(name) was not set on this phone"
                case .refused(let why): refused = true; return "refused: \(why)"
                }
            }
            return ToolReply(status: refused ? ToolReply.refused : ToolReply.ok, text: lines.joined(separator: "\n") + "\n")
        case let other?:
            return .usage("topo look: no \(other)\n\n\(usage)\n")
        }
    }

    @MainActor
    private func show(worn: Look, tuning: Tuning, reading: LookDocument.Reading) -> String {
        var lines: [String] = []
        for field in Self.fields {
            let source: String
            if tuning.sets(Self.path(field.path)) {
                source = "this phone"
            } else if reading.fields.contains(field.path) {
                source = "look.json"
            } else {
                source = "the compiled look"
            }
            lines.append("\(field.path) \(field.value(worn)) (\(field.range)) from \(source)")
        }
        let shown = Set(Self.fields.map(\.path))
        let others = Self.leaves(of: tuning.document).filter { !shown.contains($0.path) }
        if !others.isEmpty {
            lines.append("")
            lines.append("Also set on this phone:")
            lines += others.map { "\($0.path) \($0.value)" }
        }
        lines.append("")
        lines.append(reading.summary)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Every field a document sets, by path, its value as JSON. A compound field (`mascot.pin`,
    /// `composer.glow`) is one field, as the reader reads it: only a part is walked into.
    private static func leaves(of document: String?) -> [(path: String, value: String)] {
        guard let data = document?.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var found: [(String, String)] = []
        func walk(_ object: [String: Any], _ prefix: String) {
            for key in object.keys.sorted() {
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                if let inner = object[key] as? [String: Any], LookDocument.place(of: Self.path(path)) == .part {
                    walk(inner, path)
                } else {
                    found.append((path, json(object[key] as Any)))
                }
            }
        }
        walk(root, "")
        return found
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Why a `set` or `reset` call would refuse something, judged by the look's own reader with
    /// nothing set: nil when it would take the whole call.
    static func refusal(_ arguments: [String]) -> String? {
        switch arguments.first {
        case "set":
            let pairs = Array(arguments.dropFirst())
            guard !pairs.isEmpty, pairs.count.isMultiple(of: 2) else { return "topo look set takes a field and a value, as many pairs as you like" }
            for index in stride(from: 0, to: pairs.count, by: 2) {
                let path = Self.path(pairs[index])
                guard LookDocument.place(of: path) == .field else { return "\(pairs[index]) is not a field of the look" }
                var object: [String: Any] = [path[path.count - 1]: value(pairs[index + 1])]
                for key in path.dropLast().reversed() { object = [key: object] }
                guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "\(pairs[index]) cannot be written" }
                let reading = LookDocument.read(String(decoding: data, as: UTF8.self))
                if let note = reading.notes.first { return note }
            }
            return nil
        case "reset":
            for field in arguments.dropFirst() where ![.field, .part].contains(LookDocument.place(of: Self.path(field))) {
                return "\(field) is not a field or a part of the look"
            }
            return nil
        default:
            return "topo look takes set or reset in a widget"
        }
    }

    static func path(_ field: String) -> [String] {
        field.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }

    /// A value as the person or the mind wrote it: JSON when it parses as JSON, a plain word
    /// otherwise, so `glass` and `#1E8C9E` need no quotes.
    static func value(_ text: String) -> Any {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) ?? text
    }
}
