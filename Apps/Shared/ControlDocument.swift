#if os(iOS)
import Foundation
import SwiftUI

/// Topo's controls: two kinds the person places once — in Control Center, a lock-screen slot or
/// the Action button — each pointed at one of six numbered slots, whose document the mind writes.
/// A kind is fixed where it is placed, so the slots are two namespaces of six.
enum ControlSlot {
    enum Kind: String, CaseIterable, Sendable {
        case button, toggle

        /// The kind the system knows a placed control by: a contract, since a placed control is
        /// lost if it changes.
        var controlKind: String { "zone.hexagon.topo.control.\(rawValue)" }
    }

    static let count = 6
    /// A control slot's name in `SurfaceStore`: the `_` makes it a store file no widget slot can
    /// name, so A's slot rules and `removeEverything` cover it.
    static let prefix = "_control-"
    /// The control id a control's tap and cue carry, which no widget control can have.
    static let control = "_control"

    static func names(_ kind: Kind) -> [String] { (1...count).map { "\(kind.rawValue)-\($0)" } }
    static let all = Kind.allCases.flatMap(names)

    /// The kind of `slot` (`button-3`), or nil when it is not one of the twelve.
    static func kind(of slot: String) -> Kind? {
        Kind.allCases.first { names($0).contains(slot) }
    }

    /// `button-3` as the store names it, `_control-button-3`.
    static func stored(_ slot: String) -> String { prefix + slot }

    /// The slot a store name holds, or nil when it is not a control's.
    static func slot(stored name: String) -> String? {
        guard name.hasPrefix(prefix) else { return nil }
        let slot = String(name.dropFirst(prefix.count))
        return kind(of: slot) == nil ? nil : slot
    }
}

/// What a control's tap does, as the mind wired it.
enum ControlAction: Equatable, Sendable {
    /// Cue a turn: `control <slot>: <say>`, or `control <slot>: tapped`.
    case turn(say: String?)
    /// Bring the app forward, no turn.
    case open
    /// One `topo` call from the widgets' allowlist, run in the app with no turn; a toggle's gets
    /// `on` or `off` appended.
    case run([String])

    var kind: String {
        switch self {
        case .turn: "turn"
        case .open: "open"
        case .run: "run"
        }
    }

    var json: [String: Any] {
        switch self {
        case .turn(let say): say.map { ["kind": "turn", "say": $0] } ?? ["kind": "turn"]
        case .open: ["kind": "open"]
        case .run(let argv): ["kind": "run", "topo": argv]
        }
    }
}

/// One control slot's document: what the system draws for a placed control — symbol, title, a
/// second line, tint, a toggle's state — and what a tap does. Kept in the app group as
/// `Surfaces/_control-<slot>.json` (`SurfaceStore`), read by the controls' value provider.
///
/// It is read as `WidgetDocument` is, field by field: a field that is absent, of the wrong kind or
/// past its length falls back to its default with a note and the rest stands; an action refused
/// becomes the default's (a turn naming the slot), the title and symbol standing. A document of
/// the other kind than its slot is refused whole, since a placed control's kind is fixed.
struct ControlDocument: Equatable, Sendable {
    static let version = 1
    static let byteLimit = 16 * 1024
    static let titleLimit = 32
    static let subtitleLimit = 32
    static let stateTextLimit = 16
    static let hintLimit = 32
    /// What a default draws, and what a symbol the system lacks falls back to.
    static let defaultSymbol = "circle.hexagongrid"
    static let defaultTitle = "Topo"

    var kind: ControlSlot.Kind
    /// The slot's revision, the app's and never the mind's, carried by every tap so a tap on a
    /// value drawn before a rewrite is refused.
    var revision = 0
    /// The app's own document for a slot the mind has not written, which the mind cannot write.
    var isDefault = false
    var title = ControlDocument.defaultTitle
    /// A button's second line.
    var subtitle: String?
    /// A toggle's value line in each state.
    var onText: String?
    var offText: String?
    var symbol = ControlDocument.defaultSymbol
    var onSymbol: String?
    var offSymbol: String?
    var tint: WidgetColour?
    /// What the Action button says when pressed.
    var hint: String?
    /// A toggle's drawn state, which the mind sets and every run's outcome keeps.
    var on = false
    var action = ControlAction.turn(say: nil)

    init(kind: ControlSlot.Kind) {
        self.kind = kind
    }

    /// The app's default for `slot`: the mark, "Topo", the slot's name, and a turn naming the slot.
    static func standard(slot: String) -> ControlDocument {
        var document = ControlDocument(kind: ControlSlot.kind(of: slot) ?? .button)
        document.isDefault = true
        switch document.kind {
        case .button: document.subtitle = slot
        case .toggle: (document.onText, document.offText) = (slot, slot)
        }
        return document
    }

    /// The call a `run` tap makes: a toggle's with the state asked for appended, or the opposite of
    /// its stored one when none was.
    func argv(turningOn: Bool?) -> [String]? {
        guard case .run(let argv) = action else { return nil }
        guard kind == .toggle else { return argv }
        return argv + [(turningOn ?? !on) ? "on" : "off"]
    }

    /// The words of the turn a tap on `slot` sends: `control <slot>: <say>`, `tapped` with nothing
    /// to say, `tapped, not set` for the default, a toggle's new state after it. Nil when the
    /// document's action is not a turn.
    func turn(slot: String, turningOn: Bool?) -> String? {
        guard case .turn(let say) = action else { return nil }
        var words = isDefault ? "tapped, not set" : (say ?? "tapped")
        if kind == .toggle { words += (turningOn ?? !on) ? " on" : " off" }
        return "control \(slot): \(words)"
    }

    // MARK: Reading

    enum State: Equatable, Sendable {
        case read
        case unreadable(String)
    }

    struct Reading: Equatable, Sendable {
        var document: ControlDocument
        var state: State
        /// Every refusal, in the order the document was read. Empty is a document taken whole.
        var notes: [String] = []

        var readable: Bool { state == .read }
    }

    /// `text` read as the document of `slot`, whose kind it must be.
    static func read(_ text: String, slot: String, from source: WidgetDocument.Source = .mind) -> Reading {
        let kind = ControlSlot.kind(of: slot) ?? .button
        func unreadable(_ why: String) -> Reading { Reading(document: ControlDocument(kind: kind), state: .unreadable(why)) }
        guard source == .store || text.utf8.count <= byteLimit else {
            return unreadable("is \(text.utf8.count) bytes, over the \(byteLimit / 1024) KB a control's document holds")
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return unreadable("is not JSON") }
        guard let root = parsed as? [String: Any] else { return unreadable("is not a JSON object") }
        if let version = root["version"] {
            guard let number = version as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(Self.version) else {
                return unreadable("is version \(version), and this app reads version \(Self.version)")
            }
        }
        if let why = ControlReader.otherKind(root, slot: slot, kind: kind) { return unreadable(why) }
        let reader = ControlReader(source: source, slot: slot, kind: kind)
        let document = reader.document(root)
        return Reading(document: document, state: .read, notes: reader.notes)
    }
}

// MARK: Writing back

extension ControlDocument {
    /// The document as JSON, as the app keeps it: what was read, and nothing refused.
    var json: [String: Any] {
        var object: [String: Any] = ["version": Self.version, "kind": kind.rawValue, "revision": revision,
                                     "title": title, "symbol": symbol, "action": action.json]
        if isDefault { object["default"] = true }
        if let subtitle { object["subtitle"] = subtitle }
        if let onText { object["onText"] = onText }
        if let offText { object["offText"] = offText }
        if let onSymbol { object["onSymbol"] = onSymbol }
        if let offSymbol { object["offSymbol"] = offSymbol }
        if let tint { object["tint"] = tint.json }
        if let hint { object["hint"] = hint }
        if kind == .toggle { object["on"] = on }
        return object
    }

    var text: String {
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: The reader

/// One read of one control document: the notes it gathers as it walks. It shares the widgets'
/// colour, symbol and allowlist readers (`WidgetColour`, `WidgetReader.isSymbol`,
/// `WidgetAction.refusal`), so a control is judged as a widget's control is.
final class ControlReader {
    private(set) var notes: [String] = []
    private let source: WidgetDocument.Source
    private let slot: String
    private let kind: ControlSlot.Kind
    private var asked: Set<String> = []
    private var root: [String: Any] = [:]

    static let buttonOnly: Set<String> = ["subtitle"]
    static let toggleOnly: Set<String> = ["on", "onText", "offText", "onSymbol", "offSymbol"]
    static let refused = ", so a tap tells Topo it was tapped"

    init(source: WidgetDocument.Source, slot: String, kind: ControlSlot.Kind) {
        self.source = source
        self.slot = slot
        self.kind = kind
    }

    /// Why `root` is the document of the other kind than `slot`'s, or nil when it is not.
    static func otherKind(_ root: [String: Any], slot: String, kind: ControlSlot.Kind) -> String? {
        if let named = root["kind"] {
            guard let text = named as? String, let other = ControlSlot.Kind(rawValue: text) else {
                return "names kind \(named), and a control is a button or a toggle"
            }
            if other != kind { return "is a \(other.rawValue)'s document, and \(slot) is a \(kind.rawValue)" }
        }
        let foreign = kind == .button ? toggleOnly : buttonOnly
        if let key = foreign.sorted().first(where: { root[$0] != nil }) {
            return "has \(key), which only a \(kind == .button ? "toggle" : "button") has, and \(slot) is a \(kind.rawValue)"
        }
        return nil
    }

    func note(_ key: String, _ why: String) { notes.append("\(key) \(why)") }

    private func take(_ key: String) -> Any? {
        asked.insert(key)
        guard let value = root[key] else { return nil }
        if value is NSNull { note(key, "is null"); return nil }
        return value
    }

    /// Text of at most `limit` characters on one line, or nil with a note: a field past its length
    /// falls back to its default rather than being cut, since a cut title can say something else.
    private func text(_ key: String, limit: Int) -> String? {
        guard let raw = take(key) else { return nil }
        guard let text = raw as? String else { note(key, "is not text, and was not read"); return nil }
        guard (1...limit).contains(text.count) else {
            note(key, "is \(text.count) characters, and it holds 1 to \(limit), so it was not read")
            return nil
        }
        guard !text.contains(where: \.isNewline) else { note(key, "holds a line break, and was not read"); return nil }
        return text
    }

    private func symbol(_ key: String) -> String? {
        guard let raw = take(key) else { return nil }
        guard let name = raw as? String, WidgetReader.isSymbol(name) else {
            note(key, "is not an SF Symbol this system has, and was not read")
            return nil
        }
        return name
    }

    func document(_ root: [String: Any]) -> ControlDocument {
        self.root = root
        asked = ["version", "kind"]
        var document = ControlDocument(kind: kind)
        if let revision = take("revision") {
            switch source {
            case .mind: note("revision", "is the app's to write, and was not read")
            case .store:
                if let number = revision as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                   number.doubleValue >= 0, number.doubleValue < 1e15, number.doubleValue == number.doubleValue.rounded() {
                    document.revision = number.intValue
                } else {
                    note("revision", "is not a whole number")
                }
            }
        }
        if let marker = take("default") {
            switch source {
            case .mind: note("default", "is the app's to write, and was not read")
            case .store:
                document.isDefault = (marker as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
            }
        }
        document.title = text("title", limit: ControlDocument.titleLimit) ?? ControlDocument.defaultTitle
        document.symbol = symbol("symbol") ?? ControlDocument.defaultSymbol
        if let tint = take("tint") {
            if let colour = WidgetColour(tint) { document.tint = colour } else { note("tint", WidgetReader.notAColour + ", and was not read") }
        }
        document.hint = text("hint", limit: ControlDocument.hintLimit)
        switch kind {
        case .button:
            document.subtitle = text("subtitle", limit: ControlDocument.subtitleLimit)
        case .toggle:
            document.onText = text("onText", limit: ControlDocument.stateTextLimit)
            document.offText = text("offText", limit: ControlDocument.stateTextLimit)
            document.onSymbol = symbol("onSymbol")
            document.offSymbol = symbol("offSymbol")
            if let raw = take("on") {
                if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { document.on = number.boolValue }
                else { note("on", "is not true or false, and was not read") }
            }
        }
        if let raw = take("action") {
            document.action = action(raw) ?? ControlDocument.standard(slot: slot).action
        } else if source == .mind {
            note("action", "is missing" + Self.refused)
        }
        for key in root.keys.sorted() where !asked.contains(key) { note(key, "is not a field of a control") }
        return document
    }

    /// The action, or nil with a note, which the document takes as the default's.
    private func action(_ raw: Any) -> ControlAction? {
        guard let object = raw as? [String: Any] else { note("action", "is not an object naming a kind" + Self.refused); return nil }
        let kinds = ["turn", "open", "run"]
        guard let kind = object["kind"] as? String, kinds.contains(kind) else {
            note("action.kind", "is not one of \(kinds.joined(separator: ", "))" + Self.refused)
            return nil
        }
        let fields: Set<String>
        let made: ControlAction?
        switch kind {
        case "turn":
            fields = ["kind", "say"]
            if let say = object["say"] {
                if let words = say as? String, (1...WidgetDocument.sayLimit).contains(words.count) {
                    made = .turn(say: words)
                } else {
                    note("action.say", "is not 1 to \(WidgetDocument.sayLimit) characters of text, so it says it was tapped")
                    made = .turn(say: nil)
                }
            } else {
                made = .turn(say: nil)
            }
        case "open":
            fields = ["kind"]
            made = .open
        default:
            fields = ["kind", "topo"]
            made = run(object["topo"])
        }
        for key in object.keys.sorted() where !fields.contains(key) { note("action.\(key)", "is not a field of a \(kind) action") }
        return made
    }

    /// A `run`, judged against the widgets' allowlist, a toggle's in both of the forms a tap can
    /// give it.
    private func run(_ raw: Any?) -> ControlAction? {
        guard let list = raw as? [Any], let argv = list as? [String] else {
            note("action.topo", "is not a list of the words after topo" + Self.refused)
            return nil
        }
        let forms = kind == .toggle ? [argv + ["on"], argv + ["off"]] : [argv]
        for form in forms {
            if let why = WidgetAction.refusal(form) {
                note("action.topo", (kind == .toggle ? "with \(form.last!) appended " : "") + why + Self.refused)
                return nil
            }
        }
        return .run(argv)
    }
}

// MARK: The value

/// What a placed control draws, as the value provider hands it to the template: every field
/// already judged by the reader, so nothing here can trap in the system's drawing. It carries the
/// slot and the revision it was read at, which the tap's intent carries back.
struct ControlValue: Equatable, Sendable {
    var slot: String
    var revision: Int
    var isDefault: Bool
    var signedOut: Bool
    var title: String
    var subtitle: String?
    var onText: String
    var offText: String
    var symbol: String
    var onSymbol: String
    var offSymbol: String
    var tint: WidgetColour?
    var hint: String?
    var on: Bool

    init(slot: String, document: ControlDocument, signedOut: Bool = false) {
        self.slot = slot
        revision = document.revision
        isDefault = document.isDefault
        self.signedOut = signedOut
        title = document.title
        subtitle = document.subtitle
        onText = document.onText ?? "On"
        offText = document.offText ?? "Off"
        symbol = document.symbol
        onSymbol = document.onSymbol ?? document.symbol
        offSymbol = document.offSymbol ?? document.symbol
        tint = document.tint
        hint = document.hint
        on = document.on
    }

    /// A phone with no login holds no control documents: the mark and "Sign in", a tap opening Topo.
    static func signedOut(slot: String) -> ControlValue {
        var document = ControlDocument(kind: ControlSlot.kind(of: slot) ?? .button)
        document.title = "Sign in"
        document.action = .open
        return ControlValue(slot: slot, document: document, signedOut: true)
    }

    /// The slot as the store holds it now, read at the moment the system asks; signed out when it
    /// holds none, since every slot holds a document while signed in (`ControlDefaults`).
    static func read(slot: String, store: SurfaceStore?) -> ControlValue {
        guard let reading = store?.readControl(slot: slot), reading.readable else { return signedOut(slot: slot) }
        return ControlValue(slot: slot, document: reading.document)
    }
}
#endif
