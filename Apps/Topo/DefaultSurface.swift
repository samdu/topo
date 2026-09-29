import Foundation
import TopoAuth
import TopoCore

/// The app's own widget, `_default`: what every placed widget draws before the mind has written a
/// slot, or when the slot it shows is gone or past its `until`. It is rewritten after each reply
/// lands, and on launch once signed in.
///
/// The home-screen families carry the reply's first sentence, drawn redacted where the person's
/// settings say (`WidgetContext.privateText`). The lock-screen families carry Topo, the reply's
/// time and "Ask Topo", and no word of the reply, because a locked phone shows them to anyone
/// holding it whatever those settings say.
@MainActor
final class DefaultSurface {
    let store: @MainActor () -> SurfaceStore?
    let reloader: SurfaceReloader
    /// The reply the default was last written for, so a read that brings the same reply writes
    /// nothing.
    private var written: TurnRef?
    private var wroteEmpty = false

    init(store: @escaping @MainActor () -> SurfaceStore? = { SurfaceStore.shared() }, reloader: SurfaceReloader = .shared) {
        self.store = store
        self.reloader = reloader
    }

    /// A reply the log brought: the default follows it when it is the newest in `turns`.
    func landed(_ reply: Turn, in turns: [Turn]) {
        guard reply.ref == turns.last(where: { $0.role == .assistant })?.ref, reply.ref != written else { return }
        write(reply)
    }

    /// Launched signed in: the default for the newest reply, or none yet.
    func launched(latest reply: Turn?) {
        if let reply {
            guard reply.ref != written else { return }
        } else {
            guard written == nil, !wroteEmpty else { return }
        }
        write(reply)
    }

    /// The login's phase moving. Every way a login ends — the settings sheet, a demotion, a
    /// viewer's takeover — ends here too, and a signed-out phone keeps no surface; only a login
    /// ending: a launch that finds no token (the keychain unreadable before the first unlock
    /// included) takes nothing away. Signed in, the default is written for the newest reply.
    func follow(from was: SignIn.Phase, to phase: SignIn.Phase, latest reply: Turn?) {
        if was == .signedIn, phase != .signedIn {
            reloader.forget(store())
            forget()
        }
        if phase == .signedIn { launched(latest: reply) }
    }

    /// A login ended and the surfaces with it: the next sign-in writes the default afresh.
    func forget() {
        written = nil
        wroteEmpty = false
    }

    private func write(_ reply: Turn?) {
        guard let store = store() else { return }
        do {
            try store.writeDefault(Self.document(reply))
        } catch {
            return
        }
        written = reply?.ref
        wroteEmpty = reply == nil
        reloader.reload()
    }

    /// The default for `reply`, built as JSON and read through `WidgetDocument`'s reader like any
    /// document, so nothing reaches the extension unjudged.
    static func document(_ reply: Turn?) -> WidgetDocument {
        let sentence = reply.map { firstSentence($0.text) } ?? ""
        func when(_ style: String) -> [String: Any]? {
            guard let reply else { return nil }
            return ["kind": "text", "text": "", "date": WidgetReader.dates.string(from: reply.at), "dateStyle": "relative",
                    "style": style, "colour": "textMuted"]
        }
        let ask: [String: Any] = ["kind": "link", "id": "ask", "label": [["kind": "glyph", "symbol": "bubble.left.fill"], "Ask Topo"],
                                  "action": ["kind": "turn"]]
        func home(lines: Int, limit: Int) -> [String: Any] {
            var words: [[String: Any]] = []
            if !sentence.isEmpty {
                words.append(["kind": "text", "text": String(sentence.prefix(limit)), "style": "subheadline", "lines": lines])
            }
            let header: [String: Any] = ["kind": "hstack", "spacing": 6,
                                         "children": [["kind": "topo", "pose": "idle"]] + [when("caption")].compactMap { $0 } + [["kind": "spacer"]]]
            return ["kind": "vstack", "alignment": "leading", "spacing": 6,
                    "children": [header] + words + [["kind": "spacer"], ask]]
        }
        var families: [String: Any] = [
            "systemSmall": home(lines: 3, limit: 80),
            "systemMedium": home(lines: 3, limit: 140),
            "systemLarge": home(lines: 8, limit: WidgetDocument.textLimit),
            "accessoryCircular": ["kind": "topo", "pose": "idle"],
            "accessoryRectangular": ["kind": "hstack", "spacing": 6, "children": [
                ["kind": "topo", "pose": "idle"],
                ["kind": "vstack", "alignment": "leading", "children": [["kind": "text", "text": "Ask Topo", "style": "headline"]]
                    + [when("caption")].compactMap { $0 }],
            ]],
        ]
        families["accessoryInline"] = ["kind": "hstack", "children": [
            ["kind": "glyph", "symbol": "bubble.left.fill"],
            when("caption") ?? ["kind": "text", "text": "Ask Topo"],
        ]]
        let object: [String: Any] = ["version": WidgetDocument.version, "families": families, "tap": ["kind": "open"]]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return WidgetDocument() }
        return WidgetDocument.read(String(decoding: data, as: UTF8.self)).document
    }

    /// The reply's first sentence, on one line.
    static func firstSentence(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var end = flat.endIndex
        for mark in [". ", "! ", "? "] {
            if let range = flat.range(of: mark), range.lowerBound < end { end = flat.index(after: range.lowerBound) }
        }
        return String(flat[..<end]).trimmingCharacters(in: .whitespaces)
    }
}
