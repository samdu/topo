#if os(iOS) || os(watchOS)
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A widget as a document the mind writes: one slot's layout, a tree of stacks, text, glyphs,
/// images, gauges and controls per widget family, kept in the app group as
/// `Surfaces/<slot>.json` (`SurfaceStore`) and drawn by the widget extension (`WidgetNodeView`).
///
/// It is read the way `LookDocument` reads `look.json`: field by field rather than through
/// `Codable`, which is all or nothing. A node of a kind nothing reads is dropped alone; a field of
/// a kept node that is absent, of the wrong kind or outside its range falls back to that field's
/// default and the node, its words and its children stand; a tree past its depth or its node
/// count is cut at the budget. Every refusal is a note naming the field as the document writes
/// it, because the notes are the whole of what `topo widget set` says back to the mind.
///
/// Two lengths are cut rather than refused, because the value cut is still most of what was
/// meant: a text past its length is drawn to its length, and a gauge's value past its bounds is
/// drawn at the bound. Both are notes.
///
/// Nothing decoded here can trap in a view: every number is finite and in its range, every name
/// is one of an enum's cases, every symbol is one the system has, and every colour is a `Theme`
/// token or a hex pair `Theme.colour(light:dark:)` reads.
struct WidgetDocument: Equatable, Sendable {
    static let version = 1

    /// The slot's revision, the app's and never the mind's: assigned at `set`, one more than the
    /// slot's last, and carried by every control's tap so a tap on an old timeline is refused.
    var revision = 0
    /// A node tree per family. A family missing falls back to `default`, then to the app's own
    /// default widget.
    var families: [WidgetFamilyName: WidgetNode] = [:]
    var tint: WidgetColour?
    /// Past this the slot draws the app's default rather than a stale day.
    var until: Date?
    /// What a tap anywhere on the widget does, where no control takes it: a turn or opening
    /// Topo, since the whole widget's tap is a URL and hands on no intent.
    var tap: WidgetAction?
    /// How relevant the Smart Stack should take it to be, 0 to 1.
    var relevance: Double?

    /// The tree drawn for `family`: its own, or the document's `default`, its texts cut to the
    /// family's limit, since `default` is read with the home screen's.
    func tree(for family: WidgetFamilyName) -> WidgetNode? {
        if let own = families[family] { return own }
        guard let fallback = families[.default] else { return nil }
        return family.isAccessory ? fallback.cuttingTexts(to: family.textLimit) : fallback
    }

    /// The id a whole widget's tap is cued under, which no control's id can be.
    static let wholeTap = "_tap"


    /// Every control in the document, by id: what a tap's intent is looked up in.
    var controls: [String: WidgetControl] {
        var found: [String: WidgetControl] = [:]
        for family in WidgetFamilyName.allCases {
            families[family]?.walk { node in
                if let control = node.control { found[control.id] = control }
            }
        }
        return found
    }

    /// The words of the turn a tap on control `id` of `slot` sends, from this document: its
    /// `turn` action's `say`, or `tapped <id>`, a toggle's new state after it; `wholeTap` is the
    /// whole widget's own tap. Nil when the document has no turn by that id.
    func turn(slot: String, control id: String, turningOn: Bool?) -> String? {
        guard id != Self.wholeTap else {
            guard case .turn(let say)? = tap else { return nil }
            return "widget \(slot): " + (say ?? "tapped the widget")
        }
        if let control = controls[id] {
            guard case .turn(let say) = control.action else { return nil }
            var words = say ?? "tapped \(id)"
            if control.kind == .toggle { words += (turningOn ?? !control.on) ? " on" : " off" }
            return "widget \(slot): \(words)"
        }
        return nil
    }

    // MARK: Budgets

    static let byteLimit = 16 * 1024
    static let nodeLimit = 64
    static let depthLimit = 6
    static let imageLimit = 4
    static let controlLimit = 6
    static let slotLimit = 12
    static let textLimit = 200
    static let accessoryTextLimit = 60
    static let sayLimit = 200
    static let labelLimit = 60

    /// A slot's name and a control's id: `[a-z0-9-]{1,32}`.
    static func isName(_ text: String) -> Bool {
        (1...32).contains(text.count) && text.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
    }

    /// A slot the mind may write: a name that does not start with `_`, which is the app's own.
    static func isSlot(_ text: String) -> Bool { isName(text) }

    // MARK: Reading

    /// Who wrote the text being read. The mind never names a revision; the app's own copy, read
    /// back from the app group, always does.
    enum Source: Sendable { case mind, store }

    /// What a read found.
    enum State: Equatable, Sendable {
        /// The document was read, and this many nodes were kept.
        case read(nodes: Int)
        /// Nothing could be read, and this is why.
        case unreadable(String)
    }

    struct Reading: Equatable, Sendable {
        var document: WidgetDocument
        var state: State
        /// Every refusal, in the order the document was walked. Empty is a document taken whole.
        var notes: [String] = []

        var readable: Bool { if case .read = state { true } else { false } }
    }

    static func read(_ text: String, from source: Source = .mind) -> Reading {
        let empty = WidgetDocument()
        // The kept copy is the app's own writing of a document already judged, so only the
        // mind's is held to the byte budget; the node budgets bound both.
        guard source == .store || text.utf8.count <= byteLimit else {
            return Reading(document: empty, state: .unreadable("is \(text.utf8.count) bytes, over the \(byteLimit / 1024) KB a document holds"))
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
            return Reading(document: empty, state: .unreadable("is not JSON"))
        }
        guard let root = parsed as? [String: Any] else {
            return Reading(document: empty, state: .unreadable("is not a JSON object"))
        }
        if let version = root["version"] {
            guard let number = version as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(Self.version) else {
                return Reading(document: empty, state: .unreadable("is version \(version), and this app reads version \(Self.version)"))
            }
        }
        let reader = WidgetReader(source: source)
        let document = reader.document(root)
        guard !document.families.isEmpty else {
            return Reading(document: document, state: .unreadable("draws no family: \(reader.notes.first ?? "families is missing")"),
                           notes: reader.notes)
        }
        return Reading(document: document, state: .read(nodes: reader.nodes), notes: reader.notes)
    }
}

// MARK: The values

/// A family by the name WidgetKit gives it, and `default`, the tree a family without its own
/// takes. `accessoryCorner` is the watch's alone.
enum WidgetFamilyName: String, CaseIterable, Sendable {
    case systemSmall, systemMedium, systemLarge
    case accessoryCircular, accessoryRectangular, accessoryInline, accessoryCorner
    case `default`

    /// A family drawn on a lock screen or a watch face, where the phone may be locked.
    var isAccessory: Bool { rawValue.hasPrefix("accessory") }

    /// A family drawn on a lock screen or a watch face, and on its behalf `default`'s tree when
    /// it draws there.
    var textLimit: Int { isAccessory ? WidgetDocument.accessoryTextLimit : WidgetDocument.textLimit }
}

/// A colour a document names: one of `Theme`'s tokens, or a light and a dark hex.
enum WidgetColour: Equatable, Sendable {
    case token(Token)
    case hex(light: String, dark: String)

    enum Token: String, CaseIterable, Sendable {
        case primary, secondary, highlight, signal, onPrimary, onSecondary
        case background, surface, border, text, textMuted
    }

    var color: Color {
        switch self {
        case .token(let token):
            switch token {
            case .primary: Theme.primary
            case .secondary: Theme.secondary
            case .highlight: Theme.highlight
            case .signal: Theme.signal
            case .onPrimary: Theme.onPrimary
            case .onSecondary: Theme.onSecondary
            case .background: Theme.background
            case .surface: Theme.surface
            case .border: Theme.border
            case .text: Theme.text
            case .textMuted: Theme.textMuted
            }
        case .hex(let light, let dark):
            Theme.colour(light: light, dark: dark) ?? Theme.text
        }
    }

    /// As a document writes it.
    var json: Any {
        switch self {
        case .token(let token): token.rawValue
        case .hex(let light, let dark): light == dark ? light : [light, dark]
        }
    }

    init?(_ value: Any) {
        if let text = value as? String {
            if let token = Token(rawValue: text) { self = .token(token); return }
            guard Theme.colour(light: text, dark: text) != nil else { return nil }
            self = .hex(light: text, dark: text)
            return
        }
        guard let pair = value as? [Any], pair.count == 2,
              let light = pair[0] as? String, let dark = pair[1] as? String,
              Theme.colour(light: light, dark: dark) != nil else { return nil }
        self = .hex(light: light, dark: dark)
    }
}

/// What a control does when tapped, as the mind wired it.
enum WidgetAction: Equatable, Sendable {
    /// Cue a turn: `widget <slot>: <say>`, or `widget <slot>: tapped <id>` with nothing to say.
    case turn(say: String?)
    /// Bring the app forward, no turn.
    case open
    /// One `topo` call from the allowlist, run in the app with no turn.
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

    /// The `topo` calls a `run` action may make, and what of them is refused: a door lock's or a
    /// garage door's target state is never a widget's to set, however the characteristic is
    /// named (`WidgetTool` resolves a name or an id to the characteristic before this list is
    /// asked again). Widening it is a plan.
    static let allowed: [[String]] = [
        ["home", "scene"], ["home", "set"], ["notify"], ["reminders", "done"], ["reminders", "add"],
        ["look", "set"], ["look", "reset"],
    ]
    /// By the short names `topo home` gives them (`HomeNames`): a lock's target is `lock`.
    static let refusedCharacteristics: Set<String> = ["lock", "lock-target-state", "target-door-state"]

    /// Why `argv` is not a call a `run` action may make, or nil when it is on the allowlist.
    static func refusal(_ argv: [String]) -> String? {
        guard !argv.isEmpty else { return "names no topo call" }
        guard allowed.contains(where: { argv.starts(with: $0) }) else {
            return "is topo \(argv.prefix(2).joined(separator: " ")), which a widget may not run; it may run "
                + allowed.map { "topo " + $0.joined(separator: " ") }.joined(separator: ", ")
        }
        if argv.starts(with: ["home", "set"]), argv.count > 3, refusedCharacteristics.contains(argv[3].lowercased()) {
            return "sets \(argv[3]), which a widget may not set; a lock or a door goes through a turn"
        }
        return nil
    }
}

/// A button, a toggle or a link: an id the mind names, a label, and what it does.
struct WidgetControl: Equatable, Sendable {
    enum Kind: String, Sendable { case button, toggle, link }
    var kind: Kind
    var id: String
    /// Text and glyphs only.
    var label: [WidgetNode]
    var action: WidgetAction
    /// The state a toggle draws; a toggle's `run` gets `on` or `off`, the new state, appended.
    var on = false

    /// The argv a tap runs: a toggle's with the new state appended.
    func argv(turningOn: Bool? = nil) -> [String]? {
        guard case .run(let argv) = action else { return nil }
        guard kind == .toggle else { return argv }
        return argv + [(turningOn ?? !on) ? "on" : "off"]
    }
}

indirect enum WidgetNode: Equatable, Sendable {
    case stack(Stack)
    case text(Text)
    case glyph(Glyph)
    case image(Image)
    case gauge(Gauge)
    case progress(Progress)
    case topo(Pose)
    case spacer(min: Double)
    case divider
    case control(WidgetControl)

    struct Stack: Equatable, Sendable {
        enum Axis: String, Sendable { case vstack, hstack, zstack }
        var axis: Axis
        var children: [WidgetNode] = []
        var spacing: Double?
        var alignment: String = "center"

        static func alignments(_ axis: Axis) -> [String] {
            switch axis {
            case .vstack: ["leading", "center", "trailing"]
            case .hstack: ["top", "center", "bottom", "firstTextBaseline", "lastTextBaseline"]
            case .zstack: ["topLeading", "top", "topTrailing", "leading", "center", "trailing",
                           "bottomLeading", "bottom", "bottomTrailing"]
            }
        }
    }

    struct Text: Equatable, Sendable {
        enum Style: String, CaseIterable, Sendable {
            case largeTitle, title, title2, title3, headline, body, callout, subheadline, footnote, caption, caption2
        }
        enum Weight: String, CaseIterable, Sendable {
            case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
        }
        enum Design: String, CaseIterable, Sendable { case `default`, rounded, monospaced, serif }
        enum DateStyle: String, CaseIterable, Sendable { case relative, timer, time, date }

        var text = ""
        var style: Style = .body
        var weight: Weight?
        var design: Design = .default
        var colour: WidgetColour?
        var lines: Int?
        var date: Date?
        var dateStyle: DateStyle = .relative
    }

    struct Glyph: Equatable, Sendable {
        var symbol: String
        var colour: WidgetColour?
        var size: Double = 17
    }

    struct Image: Equatable, Sendable {
        enum Fit: String, CaseIterable, Sendable { case fill, fit }
        var name: String
        var fit: Fit = .fit
        var corner: Double = 0
    }

    struct Gauge: Equatable, Sendable {
        enum Style: String, CaseIterable, Sendable { case linear, circular, circularCapacity }
        var value: Double
        var min: Double = 0
        var max: Double = 1
        var label: String?
        var style: Style = .circular
        var colour: WidgetColour?
    }

    struct Progress: Equatable, Sendable {
        var value: Double
        var colour: WidgetColour?
    }

    /// Topo himself, in one of the poses the engine draws for work, and idle.
    enum Pose: String, CaseIterable, Sendable {
        case idle, thinking, searching, building, writing, calendar
    }

    var kind: String {
        switch self {
        case .stack(let stack): stack.axis.rawValue
        case .text: "text"
        case .glyph: "glyph"
        case .image: "image"
        case .gauge: "gauge"
        case .progress: "progress"
        case .topo: "topo"
        case .spacer: "spacer"
        case .divider: "divider"
        case .control(let control): control.kind.rawValue
        }
    }

    var control: WidgetControl? { if case .control(let control) = self { control } else { nil } }

    /// Every node of the tree, this one first, then its children and a control's label in order.
    /// This tree with every text, a control's label's included, cut to `limit` characters.
    func cuttingTexts(to limit: Int) -> WidgetNode {
        switch self {
        case .stack(var stack):
            stack.children = stack.children.map { $0.cuttingTexts(to: limit) }
            return .stack(stack)
        case .text(var text):
            text.text = String(text.text.prefix(limit))
            return .text(text)
        case .control(var control):
            control.label = control.label.map { $0.cuttingTexts(to: limit) }
            return .control(control)
        default:
            return self
        }
    }

    func walk(_ visit: (WidgetNode) -> Void) {
        visit(self)
        switch self {
        case .stack(let stack): stack.children.forEach { $0.walk(visit) }
        case .control(let control): control.label.forEach { $0.walk(visit) }
        default: break
        }
    }
}

// MARK: Writing back

extension WidgetDocument {
    /// The document as JSON, which is what the app keeps: what was read, and nothing refused, so
    /// the extension's read of the kept copy is a read with no notes.
    var json: [String: Any] {
        var object: [String: Any] = ["version": Self.version, "revision": revision]
        var trees: [String: Any] = [:]
        for (family, node) in families { trees[family.rawValue] = node.json }
        object["families"] = trees
        if let tint { object["tint"] = tint.json }
        if let until { object["until"] = WidgetReader.dates.string(from: until) }
        if let tap { object["tap"] = tap.json }
        if let relevance { object["relevance"] = relevance }
        return object
    }

    var text: String {
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

extension WidgetNode {
    var json: [String: Any] {
        var object: [String: Any] = ["kind": kind]
        switch self {
        case .stack(let stack):
            object["children"] = stack.children.map(\.json)
            if let spacing = stack.spacing { object["spacing"] = spacing }
            object["alignment"] = stack.alignment
        case .text(let text):
            object["text"] = text.text
            object["style"] = text.style.rawValue
            if let weight = text.weight { object["weight"] = weight.rawValue }
            object["design"] = text.design.rawValue
            if let colour = text.colour { object["colour"] = colour.json }
            if let lines = text.lines { object["lines"] = lines }
            if let date = text.date {
                object["date"] = WidgetReader.dates.string(from: date)
                object["dateStyle"] = text.dateStyle.rawValue
            }
        case .glyph(let glyph):
            object["symbol"] = glyph.symbol
            if let colour = glyph.colour { object["colour"] = colour.json }
            object["size"] = glyph.size
        case .image(let image):
            object["name"] = image.name
            object["fit"] = image.fit.rawValue
            object["corner"] = image.corner
        case .gauge(let gauge):
            object["value"] = gauge.value
            object["min"] = gauge.min
            object["max"] = gauge.max
            if let label = gauge.label { object["label"] = label }
            object["style"] = gauge.style.rawValue
            if let colour = gauge.colour { object["colour"] = colour.json }
        case .progress(let progress):
            object["value"] = progress.value
            if let colour = progress.colour { object["colour"] = colour.json }
        case .topo(let pose):
            object["pose"] = pose.rawValue
        case .spacer(let min):
            object["min"] = min
        case .divider:
            break
        case .control(let control):
            object["id"] = control.id
            object["label"] = control.label.map(\.json)
            object["action"] = control.action.json
            if control.kind == .toggle { object["on"] = control.on }
        }
        return object
    }
}

// MARK: The reader

/// One read of one document: the notes and the counts it gathers as it walks.
final class WidgetReader {
    private(set) var notes: [String] = []
    /// Nodes kept across the whole document, which the node budget is held against.
    private(set) var nodes = 0
    private let source: WidgetDocument.Source
    private var family: WidgetFamilyName = .default
    private var controls = 0
    private var images = 0
    /// Every control id kept, with its action, so an id reused in another family names the same
    /// control and nothing else.
    private var ids: [String: WidgetControl] = [:]
    private var idsInFamily: Set<String> = []

    init(source: WidgetDocument.Source) {
        self.source = source
    }

    nonisolated(unsafe) static let dates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    nonisolated(unsafe) private static let fractionalDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func note(_ path: String, _ why: String) { notes.append("\(path) \(why)") }

    // MARK: The top level

    func document(_ root: [String: Any]) -> WidgetDocument {
        var document = WidgetDocument()
        let known: Set<String> = ["version", "revision", "families", "tint", "until", "tap", "relevance"]
        for key in root.keys.sorted() where !known.contains(key) { note(key, "is not a field of a widget") }
        if let revision = root["revision"] {
            switch source {
            case .mind: note("revision", "is the app's to write, and was not read")
            case .store:
                if let number = integer(revision), number >= 0 { document.revision = number }
                else { note("revision", "is not a whole number") }
            }
        }
        if let tint = root["tint"] {
            if let colour = WidgetColour(tint) { document.tint = colour } else { note("tint", Self.notAColour) }
        }
        if let until = root["until"] {
            if let date = date(until) { document.until = date } else { note("until", Self.notADate) }
        }
        if let tap = root["tap"] {
            // The whole widget's tap is a URL the system opens, which carries no intent.
            document.tap = action(tap, "tap", allowing: ["turn", "open"])
        }
        if let relevance = root["relevance"] {
            if let number = finite(relevance), (0...1).contains(number) { document.relevance = number }
            else { note("relevance", "is not a number between 0 and 1") }
        }
        guard let trees = root["families"] else { note("families", "is missing"); return document }
        guard let object = trees as? [String: Any] else { note("families", "is not an object"); return document }
        // The default first, so a family written after it counts against the same budget in a
        // fixed order however the object was written.
        let order = WidgetFamilyName.allCases.filter { object[$0.rawValue] != nil }
        for key in object.keys.sorted() where WidgetFamilyName(rawValue: key) == nil {
            note("families.\(key)", "is not a family; the families are \(WidgetFamilyName.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        for family in order.sorted(by: { $0 == .default && $1 != .default }) {
            self.family = family
            controls = 0
            idsInFamily = []
            let path = "families.\(family.rawValue)"
            guard let tree = object[family.rawValue] as? [String: Any] else {
                note(path, "is not a node")
                continue
            }
            guard var node = self.node(tree, path, depth: 1) else { continue }
            if family == .accessoryInline { node = inline(node, path) }
            document.families[family] = node
        }
        // `default` is read with the home screen's limit and cut to the lock screen's where it
        // draws there, which is said here since the cut is made at the draw.
        let lockScreen = WidgetFamilyName.allCases.filter { $0.isAccessory && $0 != .accessoryCorner }
        if source == .mind, let fallback = document.families[.default], let missing = lockScreen.first(where: { document.families[$0] == nil }) {
            var longest = 0
            fallback.walk { if case .text(let text) = $0 { longest = max(longest, text.text.count) } }
            if longest > WidgetDocument.accessoryTextLimit {
                note("families.default", "has a text of \(longest) characters, and draws on \(missing.rawValue), a lock-screen family, cut to \(WidgetDocument.accessoryTextLimit)")
            }
        }
        // `accessoryInline` draws one line whichever tree it is given, so the default is kept
        // for it as that line.
        if let fallback = document.families[.default], document.families[.accessoryInline] == nil {
            document.families[.accessoryInline] = inline(fallback.cuttingTexts(to: WidgetDocument.accessoryTextLimit), "families.default, on accessoryInline,")
        }
        return document
    }

    /// `accessoryInline` draws one line: one text and one glyph, and nothing else.
    private func inline(_ node: WidgetNode, _ path: String) -> WidgetNode {
        var text: WidgetNode?
        var glyph: WidgetNode?
        var dropped: [String] = []
        node.walk { each in
            switch each {
            case .text where text == nil: text = each
            case .glyph where glyph == nil: glyph = each
            case .stack where each == node: break
            default: dropped.append(each.kind)
            }
        }
        if !dropped.isEmpty {
            note(path, "draws one text and one glyph on one line, so its \(dropped.joined(separator: ", ")) were dropped")
        }
        return .stack(.init(axis: .hstack, children: [glyph, text].compactMap { $0 }))
    }

    // MARK: A node

    private static let kinds = ["vstack", "hstack", "zstack", "text", "glyph", "image", "gauge", "progress",
                                "topo", "spacer", "divider", "button", "toggle", "link"]

    /// One node at `path`, or nil when it is dropped: a kind nothing reads, a control past the
    /// family's budget or with no id, or a node past the depth or the count.
    private func node(_ object: [String: Any], _ path: String, depth: Int, labelOnly: Bool = false) -> WidgetNode? {
        guard let kind = object["kind"] as? String else {
            note(path, "names no kind, and was dropped")
            return nil
        }
        guard Self.kinds.contains(kind) else {
            note(path, "is a \(kind), which is not a kind of node, and was dropped; the kinds are \(Self.kinds.joined(separator: ", "))")
            return nil
        }
        if labelOnly, kind != "text", kind != "glyph" {
            note(path, "is a \(kind), and a control's label holds only text and glyphs, so it was dropped")
            return nil
        }
        guard depth <= WidgetDocument.depthLimit else {
            note(path, "is deeper than \(WidgetDocument.depthLimit) nodes, and was cut")
            return nil
        }
        guard nodes < WidgetDocument.nodeLimit else {
            note(path, "is past the \(WidgetDocument.nodeLimit) nodes a document holds, and was cut")
            return nil
        }
        let fields = Fields(object, path, self)
        let made: WidgetNode?
        switch kind {
        case "vstack", "hstack", "zstack": made = stack(.init(rawValue: kind)!, fields, depth: depth)
        case "text": made = .text(text(fields))
        case "glyph": made = glyph(fields)
        case "image": made = image(fields)
        case "gauge": made = .gauge(gauge(fields))
        case "progress": made = .progress(progress(fields))
        case "topo": made = .topo(fields.named("pose", WidgetNode.Pose.self) ?? .idle)
        case "spacer": made = .spacer(min: fields.number("min", in: 0...64, "a length in points between 0 and 64") ?? 0)
        case "divider": made = .divider
        default: made = control(.init(rawValue: kind)!, fields, depth: depth)
        }
        fields.finish()
        if made != nil { nodes += 1 }
        return made
    }

    private func stack(_ axis: WidgetNode.Stack.Axis, _ fields: Fields, depth: Int) -> WidgetNode {
        var stack = WidgetNode.Stack(axis: axis)
        stack.spacing = fields.number("spacing", in: 0...32, "a length in points between 0 and 32")
        if let alignment = fields.string("alignment") {
            let cases = WidgetNode.Stack.alignments(axis)
            if cases.contains(alignment) { stack.alignment = alignment }
            else { fields.note("alignment", "is not one of \(cases.joined(separator: ", "))") }
        }
        // The stack counts before its children, so a tree cut at the budget keeps its outer
        // nodes and loses the ones furthest in.
        nodes += 1
        defer { nodes -= 1 }
        if let children = fields.list("children") {
            for (index, child) in children.enumerated() {
                let path = "\(fields.path).children[\(index)]"
                guard let object = child as? [String: Any] else {
                    note(path, "is not a node, and was dropped")
                    continue
                }
                if let node = node(object, path, depth: depth + 1) { stack.children.append(node) }
            }
        }
        return .stack(stack)
    }

    private func text(_ fields: Fields) -> WidgetNode.Text {
        var text = WidgetNode.Text()
        if let words = fields.string("text") {
            let limit = family.textLimit
            if words.count > limit {
                fields.note("text", "is \(words.count) characters, and a \(family.isAccessory ? "lock-screen" : "home-screen") text holds \(limit), so it was cut")
                text.text = String(words.prefix(limit))
            } else {
                text.text = words
            }
        }
        text.style = fields.named("style", WidgetNode.Text.Style.self) ?? .body
        text.weight = fields.named("weight", WidgetNode.Text.Weight.self)
        text.design = fields.named("design", WidgetNode.Text.Design.self) ?? .default
        text.colour = fields.colour("colour")
        text.lines = fields.number("lines", in: 1...8, "a whole number of lines from 1 to 8", whole: true).map { Int($0) }
        if let raw = fields.take("date") {
            if let date = date(raw) { text.date = date } else { fields.note("date", Self.notADate) }
        }
        text.dateStyle = fields.named("dateStyle", WidgetNode.Text.DateStyle.self) ?? .relative
        return text
    }

    private func glyph(_ fields: Fields) -> WidgetNode? {
        var symbol = "questionmark"
        if let named = fields.string("symbol") {
            if Self.isSymbol(named) { symbol = named }
            else { fields.note("symbol", "is not an SF Symbol this system has") }
        } else {
            fields.note("symbol", "is missing")
        }
        return .glyph(.init(symbol: symbol, colour: fields.colour("colour"),
                            size: fields.number("size", in: 8...64, "a size in points between 8 and 64") ?? 17))
    }

    static func isSymbol(_ name: String) -> Bool {
        #if canImport(UIKit)
        UIImage(systemName: name) != nil
        #else
        false
        #endif
    }

    private func image(_ fields: Fields) -> WidgetNode? {
        guard let name = fields.string("name"), WidgetDocument.isName(name) else {
            fields.note("name", "is not the name of an image topo widget image put in this slot, and the image was dropped")
            return nil
        }
        guard images < WidgetDocument.imageLimit else {
            fields.note("name", "is \(name), past the \(WidgetDocument.imageLimit) images a document holds, and the image was dropped")
            fields.skip(["fit", "corner"])
            return nil
        }
        images += 1
        return .image(.init(name: name, fit: fields.named("fit", WidgetNode.Image.Fit.self) ?? .fit,
                            corner: fields.number("corner", in: 0...32, "a length in points between 0 and 32") ?? 0))
    }

    private func gauge(_ fields: Fields) -> WidgetNode.Gauge {
        var gauge = WidgetNode.Gauge(value: 0)
        var low = fields.number("min", in: -1e9...1e9, "a number") ?? 0
        var high = fields.number("max", in: -1e9...1e9, "a number") ?? 1
        if !(low < high) {
            fields.note("max", "is not above min, so the gauge runs from 0 to 1")
            (low, high) = (0, 1)
        }
        gauge.min = low
        gauge.max = high
        if let value = fields.number("value", in: -1e9...1e9, "a number") {
            gauge.value = Self.clamp(value, low, high, fields, "value")
        } else {
            gauge.value = low
        }
        gauge.label = fields.label("label")
        gauge.style = fields.named("style", WidgetNode.Gauge.Style.self) ?? .circular
        gauge.colour = fields.colour("colour")
        return gauge
    }

    private func progress(_ fields: Fields) -> WidgetNode.Progress {
        let value = fields.number("value", in: -1e9...1e9, "a number").map { Self.clamp($0, 0, 1, fields, "value") } ?? 0
        return .init(value: value, colour: fields.colour("colour"))
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double, _ fields: Fields, _ key: String) -> Double {
        guard value < low || value > high else { return value }
        let drawn = min(max(value, low), high)
        fields.note(key, "is \(value), outside \(low) to \(high), and is drawn at \(drawn)")
        return drawn
    }

    // MARK: Controls

    private func control(_ kind: WidgetControl.Kind, _ fields: Fields, depth: Int) -> WidgetNode? {
        guard let id = fields.string("id"), WidgetDocument.isName(id) else {
            fields.note("id", "is not a control id ([a-z0-9-], 1 to 32 characters), and the \(kind.rawValue) was dropped")
            fields.skip(["label", "action", "on"])
            return nil
        }
        guard !idsInFamily.contains(id) else {
            fields.note("id", "is \(id), which another control in this family has, and the \(kind.rawValue) was dropped")
            fields.skip(["label", "action", "on"])
            return nil
        }
        guard controls < WidgetDocument.controlLimit else {
            fields.note("id", "is \(id), past the \(WidgetDocument.controlLimit) controls a family holds, and the \(kind.rawValue) was dropped")
            fields.skip(["label", "action", "on"])
            return nil
        }
        // The control counts before its label, as a stack before its children, and each word of
        // the label is a node against the same budget.
        nodes += 1
        defer { nodes -= 1 }
        var label: [WidgetNode] = []
        if let raw = fields.take("label") {
            let entries = (raw as? [Any]) ?? [raw]
            for (index, entry) in entries.enumerated() {
                let path = "\(fields.path).label[\(index)]"
                if let words = entry as? String {
                    guard nodes < WidgetDocument.nodeLimit else {
                        note(path, "is past the \(WidgetDocument.nodeLimit) nodes a document holds, and was cut")
                        continue
                    }
                    nodes += 1
                    if words.count > WidgetDocument.labelLimit {
                        note(path, "is \(words.count) characters, and a label holds \(WidgetDocument.labelLimit), so it was cut")
                    }
                    label.append(.text(.init(text: String(words.prefix(WidgetDocument.labelLimit)))))
                } else if let object = entry as? [String: Any], let node = node(object, path, depth: depth + 1, labelOnly: true) {
                    label.append(node)
                } else if !(entry is [String: Any]) {
                    note(path, "is not text or a node, and was dropped")
                }
            }
        }
        if label.isEmpty { fields.note("label", "draws nothing, so the control is labelled with its id"); label = [.text(.init(text: id))] }
        let allowing: Set<String> = kind == .link ? ["turn", "open"] : ["turn", "open", "run"]
        var action = WidgetAction.open
        if let raw = fields.take("action") {
            action = self.action(raw, "\(fields.path).action", allowing: allowing)
        } else {
            fields.note("action", "is missing, so a tap opens Topo")
        }
        var control = WidgetControl(kind: kind, id: id, label: label, action: action)
        if kind == .toggle {
            control.on = fields.bool("on") ?? false
            if case .run(let argv) = action {
                // Judged in both completed forms: the state is appended at the tap.
                for state in ["on", "off"] {
                    if let why = WidgetAction.refusal(argv + [state]) {
                        note("\(fields.path).action", "with \(state) appended \(why), so a tap opens Topo")
                        control.action = .open
                        break
                    }
                }
            }
        } else {
            fields.skip(["on"])
        }
        if let earlier = ids[id], earlier != control {
            fields.note("id", "is \(id), which another family uses for a different control, and the \(kind.rawValue) was dropped")
            return nil
        }
        ids[id] = control
        idsInFamily.insert(id)
        controls += 1
        return .control(control)
    }

    /// An action, or `open` with a note: a tap on a control whose action was refused brings Topo
    /// forward and does nothing else.
    private func action(_ raw: Any, _ path: String, allowing: Set<String>) -> WidgetAction {
        guard let object = raw as? [String: Any] else {
            note(path, "is not an object naming a kind, so a tap opens Topo")
            return .open
        }
        let fields = Fields(object, path, self)
        defer { fields.finish() }
        guard let kind = fields.string("kind"), ["turn", "open", "run"].contains(kind) else {
            fields.note("kind", "is not turn, open or run, so a tap opens Topo")
            fields.skip(["say", "topo"])
            return .open
        }
        guard allowing.contains(kind) else {
            fields.note("kind", "is \(kind), which this takes no \(kind) of, so a tap opens Topo")
            fields.skip(["say", "topo"])
            return .open
        }
        switch kind {
        case "turn":
            fields.skip(["topo"])
            guard let say = fields.string("say") else { return .turn(say: nil) }
            guard (1...WidgetDocument.sayLimit).contains(say.count) else {
                fields.note("say", "is \(say.count) characters, and a turn says 1 to \(WidgetDocument.sayLimit), so it says it was tapped")
                return .turn(say: nil)
            }
            return .turn(say: say)
        case "run":
            fields.skip(["say"])
            guard let list = fields.take("topo") as? [Any], let argv = list as? [String] else {
                fields.note("topo", "is not a list of the words after topo, so a tap opens Topo")
                return .open
            }
            if let why = WidgetAction.refusal(argv) {
                fields.note("topo", "\(why), so a tap opens Topo")
                return .open
            }
            return .run(argv)
        default:
            fields.skip(["say", "topo"])
            return .open
        }
    }

    // MARK: Values

    static let notAColour = "is not a colour: a Theme token (\(WidgetColour.Token.allCases.map(\.rawValue).joined(separator: ", "))), \"#RRGGBB\", or a pair of them for light and dark"
    static let notADate = "is not an ISO 8601 date and time"

    fileprivate func date(_ raw: Any) -> Date? {
        guard let text = raw as? String else { return nil }
        return Self.dates.date(from: text) ?? Self.fractionalDates.date(from: text)
    }

    fileprivate func finite(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    fileprivate func integer(_ value: Any) -> Int? {
        guard let number = finite(value), number == number.rounded(), abs(number) < 1e15 else { return nil }
        return Int(number)
    }

    /// The fields of one object, read one key at a time, and every key nobody asked for noted.
    fileprivate final class Fields {
        let path: String
        private let object: [String: Any]
        private let reader: WidgetReader
        private var asked: Set<String> = ["kind"]

        init(_ object: [String: Any], _ path: String, _ reader: WidgetReader) {
            self.object = object
            self.path = path
            self.reader = reader
        }

        func note(_ key: String, _ why: String) { reader.note("\(path).\(key)", why) }

        func take(_ key: String) -> Any? {
            asked.insert(key)
            guard let value = object[key] else { return nil }
            if value is NSNull { note(key, "is null"); return nil }
            return value
        }

        /// Keys a dropped node or action would have read, so they are not noted again as unknown.
        func skip(_ keys: [String]) { asked.formUnion(keys) }

        func finish() {
            for key in object.keys.sorted() where !asked.contains(key) {
                note(key, "is not a field of this node")
            }
        }

        func string(_ key: String) -> String? {
            guard let raw = take(key) else { return nil }
            guard let text = raw as? String else { note(key, "is not text"); return nil }
            return text
        }

        func label(_ key: String) -> String? {
            guard let text = string(key) else { return nil }
            guard text.count <= WidgetDocument.labelLimit else {
                note(key, "is \(text.count) characters, and a label holds \(WidgetDocument.labelLimit), so it was cut")
                return String(text.prefix(WidgetDocument.labelLimit))
            }
            return text
        }

        func list(_ key: String) -> [Any]? {
            guard let raw = take(key) else { return nil }
            guard let list = raw as? [Any] else { note(key, "is not a list"); return nil }
            return list
        }

        func bool(_ key: String) -> Bool? {
            guard let raw = take(key) else { return nil }
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                note(key, "is not true or false"); return nil
            }
            return number.boolValue
        }

        func number(_ key: String, in range: ClosedRange<Double>, _ what: String, whole: Bool = false) -> Double? {
            guard let raw = take(key) else { return nil }
            guard let number = reader.finite(raw), !whole || number == number.rounded() else {
                note(key, "is not \(what)"); return nil
            }
            guard range.contains(number) else {
                note(key, "is \(number), and is read as \(what)"); return nil
            }
            return number
        }

        func named<T: RawRepresentable & CaseIterable>(_ key: String, _ type: T.Type) -> T? where T.RawValue == String {
            guard let raw = take(key) else { return nil }
            guard let text = raw as? String, let value = T(rawValue: text) else {
                note(key, "is not one of \(T.allCases.map(\.rawValue).joined(separator: ", "))"); return nil
            }
            return value
        }

        func colour(_ key: String) -> WidgetColour? {
            guard let raw = take(key) else { return nil }
            guard let colour = WidgetColour(raw) else { note(key, WidgetReader.notAColour); return nil }
            return colour
        }
    }
}
#endif
