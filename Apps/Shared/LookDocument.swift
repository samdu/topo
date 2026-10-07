import Foundation
import SwiftUI

/// The look as a document the mind can write: `look.json` in the vault's root, decoded field by
/// field onto the compiled `Look`.
///
/// The vault is the one channel the mind already has into the phone, and a note is not what this
/// is, so it is JSON rather than markdown. It is decoded field by field rather than through
/// `Codable`, which is all or nothing: a field that is absent, misspelt, of the wrong kind or
/// outside the range its field is read in falls back to the compiled default **for that field
/// alone**, every other override stands, and the reason is written down. What is written down is
/// the diagnostics screen's `look` row, which is the whole of what a document says back to
/// whoever wrote it — including a key nothing reads, since a misspelt field is otherwise silence,
/// and silence is the one answer a document cannot act on.
///
/// Colours are hex pairs — `["#RRGGBB", "#RRGGBB"]`, light then dark, as `Theme` writes them,
/// with an alpha as `#RRGGBBAA` and one string standing for both appearances. Materials are named
/// (`glass`, `material`, `flat`). Numbers are points, degrees or seconds, each read in a range
/// named where it is read: a length is not a fraction, an alpha is not a length, and a value
/// outside its range is refused rather than clamped, because a clamped value is a document
/// quietly saying something other than what it says.
///
/// Nothing decoded here can trap: every number is finite and in its range before it reaches a
/// view, every name is one of an enum's cases, and a file that is not an object at all is one
/// note and the compiled look. The lengths of what has to be pressed or read — the microphone
/// and its well, the badge and its mark, the send control, the row — are bounded below as well
/// as above, so no document puts them out of reach. What a document *can* do is name colours
/// nobody can read: that is the palette's whole point, and deleting the file is the way back.
enum LookDocument {
    /// Where the document lives, in the vault's root beside the notes.
    static let name = "look.json"

    /// What the last read of the document found.
    enum State: Equatable, Sendable {
        /// No file. The look is the compiled one and there is nothing to report.
        case absent
        /// A file was read, and this many fields of the look came from it.
        case read(fields: Int)
        /// Something is at the path and this is why nothing was read from it: not an object,
        /// not JSON, not text at all.
        case unreadable(String)
    }

    /// One read of the document: the look it makes, and what it had to say about itself.
    struct Reading: Equatable, Sendable {
        var look: Look
        var state: State = .absent
        /// Every field the document named and did not get, in the order they were read, each
        /// saying which field and why. Empty is a document that was taken whole.
        var notes: [String] = []
        /// Every field the document was taken for, by its path (`transcript.spacing`,
        /// `mascot.pin`): where a value in the look came from the document, and not the base.
        var fields: Set<String> = []

        /// The diagnostics `look` row. A count alone is a device run that has to be repeated to
        /// learn anything, so the first few reasons are named and the rest are counted.
        var summary: String {
            var parts: [String]
            switch state {
            case .absent:
                parts = ["no \(LookDocument.name); the compiled look"]
            case .read(let fields):
                parts = ["\(LookDocument.name): \(fields) field\(fields == 1 ? "" : "s")"]
            case .unreadable(let why):
                parts = ["\(LookDocument.name) \(why)"]
            }
            parts.append(contentsOf: notes.prefix(Self.noted))
            if notes.count > Self.noted { parts.append("and \(notes.count - Self.noted) more") }
            return parts.joined(separator: "; ")
        }

        private static let noted = 5
    }

    /// Reads a document onto a look. `nil` is no file at all, which is the compiled look and no
    /// note: a vault holding no document is not a phone with something wrong with it.
    static func read(_ text: String?, onto base: Look = Look()) -> Reading {
        guard let text else { return Reading(look: base) }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
            return Reading(look: base, state: .unreadable("is not JSON"))
        }
        guard let root = parsed as? [String: Any] else {
            return Reading(look: base, state: .unreadable("is not a JSON object"))
        }
        let reader = Reader()
        var look = base
        reader.into(root, "") { r in parts(r, &look) }
        return Reading(look: look, state: .read(fields: reader.applied), notes: reader.notes, fields: Set(reader.taken))
    }

    /// What a path names in a look.json.
    enum Place: Equatable {
        /// A part, which holds fields: `transcript`, `composer.well`.
        case part
        /// A field, set and taken back whole, a compound (`mascot.pin`) included.
        case field
        /// Something inside this compound field, which is not set or taken back alone.
        case inside(String)
        /// Nothing the reader knows.
        case unknown
    }

    /// Where `path` is, asked of the reader itself: a document holding `null` at `path` is read,
    /// and the reader says which keys it walked into as parts and which it asked for as fields;
    /// one holding an empty object there says whether `path` is itself a part.
    static func place(of path: [String]) -> Place {
        guard !path.isEmpty, path.allSatisfy({ !$0.isEmpty }) else { return .unknown }
        let reader = probe(path, NSNull())
        for count in 1..<path.count where !reader.parts.contains(path.prefix(count).joined(separator: ".")) {
            let outer = Array(path.prefix(count))
            return place(of: outer) == .field ? .inside(outer.joined(separator: ".")) : .unknown
        }
        let name = path.joined(separator: ".")
        if probe(path, [String: Any]()).parts.contains(name) { return .part }
        return reader.notes.contains("\(name) is null") ? .field : .unknown
    }

    /// Whether the compound field at `path` reads an object onto what it already holds, so that
    /// an object naming some of its keys keeps the rest (a shadow, a point), rather than replacing
    /// it whole (a font, a pin). Asked of the reader itself.
    static func merges(_ path: [String]) -> Bool {
        guard !path.isEmpty, path.allSatisfy({ !$0.isEmpty }) else { return false }
        return probe(path, [String: Any]()).merging.contains(path.joined(separator: "."))
    }

    /// A reader that has read a document holding `leaf` at `path` and nothing else.
    private static func probe(_ path: [String], _ leaf: Any) -> Reader {
        var object: [String: Any] = [path[path.count - 1]: leaf]
        for key in path.dropLast().reversed() { object = [key: object] }
        let reader = Reader()
        var scratch = Look()
        reader.into(object, "") { r in parts(r, &scratch) }
        return reader
    }

    /// The document's top level: each part, read where it is named.
    private static func parts(_ r: Reader, _ look: inout Look) {
        r.object("transcript") { transcript(&look.transcript, $0) }
        r.object("markdown") { markdown(&look.markdown, $0) }
        r.object("bubble") { enclosure(&look.bubble, $0) }
        r.object("plain") { enclosure(&look.plain, $0) }
        r.object("draft") { draft(&look.draft, $0) }
        r.object("jewel") { jewel(&look.jewel, $0) }
        r.object("press") { press(&look.press, $0) }
        r.object("badge") { badge(&look.badge, $0) }
        r.object("settings") { settings(&look.settings, $0) }
        r.object("composer") { composer(&look.composer, $0) }
        r.object("mascot") { mascot(&look.mascot, $0) }
        r.object("mind") { mind(&look.mind, $0) }
    }

    private static func mind(_ value: inout Look.Mind, _ r: Reader) {
        r.title("sonnet", &value.sonnet)
        r.title("opus", &value.opus)
        r.title("fable", &value.fable)
    }

    // MARK: The parts of a look, each read where it is named

    private static func transcript(_ value: inout Look.Transcript, _ r: Reader) {
        r.length("spacing", &value.spacing)
        r.length("captionSpacing", &value.captionSpacing)
        r.length("horizontalPadding", &value.horizontalPadding)
        r.width("maximumLineWidth", &value.maximumLineWidth)
        r.inset("replyTrailingInset", &value.replyTrailingInset)
        r.inset("personLeadingInset", &value.personLeadingInset)
        r.font("bodyFont", &value.bodyFont)
        r.font("labelFont", &value.labelFont)
        r.font("noticeFont", &value.noticeFont, largest: Look.Transcript.largestNotice)
        r.colour("text", &value.text)
        r.colour("caption", &value.caption)
        r.colour("trouble", &value.trouble)
    }

    private static func markdown(_ value: inout Look.Markdown, _ r: Reader) {
        r.indent("blockSpacing", &value.blockSpacing)
        r.indent("listIndent", &value.listIndent)
        r.indent("markerSpacing", &value.markerSpacing)
        r.font("heading1Font", &value.heading1Font)
        r.font("heading2Font", &value.heading2Font)
        r.font("heading3Font", &value.heading3Font)
        r.font("codeFont", &value.codeFont)
        r.colour("codeInk", &value.codeInk)
        r.object("codeBlock") { enclosure(&value.codeBlock, $0) }
        r.codeOverflow("codeOverflow", &value.codeOverflow)
        r.colour("quoteBar", &value.quoteBar)
        r.indent("quoteBarWidth", &value.quoteBarWidth)
        r.indent("quoteIndent", &value.quoteIndent)
        r.colour("quoteText", &value.quoteText)
        r.colour("marker", &value.marker)
        r.indent("ruleWidth", &value.ruleWidth)
        r.object("codePulse") { pulse(&value.codePulse, $0) }
    }

    private static func pulse(_ value: inout Look.Markdown.Pulse, _ r: Reader) {
        r.colour("accent", &value.accent)
        r.outline("width", &value.width)
        r.alpha("opacity", &value.opacity)
        r.breath("cycle", &value.cycle)
    }

    private static func enclosure(_ value: inout Look.Enclosure, _ r: Reader) {
        r.colour("accent", &value.accent)
        r.alpha("fillOpacity", &value.fillOpacity)
        r.length("strokeWidth", &value.strokeWidth)
        r.length("cornerRadius", &value.cornerRadius)
        r.length("horizontalPadding", &value.horizontalPadding)
        r.length("verticalPadding", &value.verticalPadding)
        r.surface("surface", &value.surface)
    }

    private static func draft(_ value: inout Look.Draft, _ r: Reader) {
        r.object("written") { enclosure(&value.written, $0) }
        r.object("sending") { enclosure(&value.sending, $0) }
        r.reach("minimumWidth", &value.minimumWidth)
        r.length("spacing", &value.spacing)
        r.reach("slot", &value.slot)
        r.font("sendFont", &value.sendFont)
        r.colour("sendInk", &value.sendInk)
        r.alpha("sendRestingOpacity", &value.sendRestingOpacity)
    }

    private static func badge(_ value: inout Look.Badge, _ r: Reader) {
        r.reach("size", &value.size)
        r.reach("markSize", &value.markSize)
        r.object("jewel") { jewel(&value.jewel, $0) }
    }

    private static func press(_ value: inout Look.Press, _ r: Reader) {
        r.fractionOfOne("wall", &value.wall)
        r.colour("shade", &value.shade)
        r.colour("catchLight", &value.catchLight)
        r.alpha("soften", &value.soften)
        r.alpha("floor", &value.floor)
    }

    private static func settings(_ value: inout Look.Settings, _ r: Reader) {
        r.colour("tint", &value.tint)
        r.font("codeFont", &value.codeFont)
    }

    private static func jewel(_ value: inout Look.Jewel, _ r: Reader) {
        r.asset("stone", &value.stone)
        r.colour("cast", &value.cast)
        r.alpha("castOpacity", &value.castOpacity)
        r.blend("castBlend", &value.castBlend)
        r.shadow("bodyShade", &value.bodyShade)
        r.shadow("bodyCatch", &value.bodyCatch)
        r.colour("sheenColor", &value.sheenColor)
        r.colour("sheenShadeColor", &value.sheenShadeColor)
        r.alpha("sheenOpacity", &value.sheenOpacity)
        r.alpha("sheenShadeOpacity", &value.sheenShadeOpacity)
        r.point("sheenStart", &value.sheenStart)
        r.point("sheenEnd", &value.sheenEnd)
        r.colour("bevelColor", &value.bevelColor)
        r.colour("bevelShadeColor", &value.bevelShadeColor)
        r.length("bevelWidth", &value.bevelWidth)
        r.alpha("bevelHighlightOpacity", &value.bevelHighlightOpacity)
        r.alpha("bevelMidOpacity", &value.bevelMidOpacity)
        r.alpha("bevelShadeOpacity", &value.bevelShadeOpacity)
        r.shadow("dropShadow", &value.dropShadow)
    }

    private static func composer(_ value: inout Look.Composer, _ r: Reader) {
        r.fraction("widthFraction", &value.widthFraction)
        r.length("bottomPadding", &value.bottomPadding)
        r.length("horizontalInset", &value.horizontalInset)
        r.length("verticalInset", &value.verticalInset)
        r.length("cornerRadius", &value.cornerRadius)
        r.length("spacing", &value.spacing)
        r.surface("surface", &value.surface)
        r.colour("tint", &value.tint)
        r.alpha("tintOpacity", &value.tintOpacity)
        r.shadow("glow", &value.glow)
        r.seconds("duration", &value.duration)
        r.length("presenceRise", &value.presenceRise)
        r.seconds("presenceDuration", &value.presenceDuration)
        r.compactShare("compactShare", &value.compactShare)
        r.object("flank") { flank(&value.flank, $0) }
        r.object("models") { models(&value.models, $0) }
        r.object("well") { well(&value.well, $0) }
        r.object("glyph") { glyph(&value.glyph, $0) }
        r.object("openJewel") { jewel(&value.openJewel, $0) }
        r.saturation("dimmedSaturation", &value.dimmedSaturation)
        r.alpha("dimmedOpacity", &value.dimmedOpacity)
    }

    private static func mascot(_ value: inout Look.Mascot, _ r: Reader) {
        r.pixelScale("scale", &value.scale)
        r.clearance("clearance", &value.clearance)
        r.roamSpeed("roamSpeed", &value.roamSpeed)
        r.roamSpeed("swimSpeed", &value.swimSpeed)
        r.hurry("hurry", &value.hurry)
        r.roamSettle("roamSettle", &value.roamSettle)
        r.frameInterval("frameInterval", &value.frameInterval)
        r.placement("placement", &value.placement)
        r.pin("pin", &value.pin)
        r.object("debug") { mascotDebug(&value.debug, $0) }
    }

    private static func mascotDebug(_ value: inout Look.Mascot.Debug, _ r: Reader) {
        r.colour("box", &value.box)
        r.colour("reach", &value.reach)
        r.colour("room", &value.room)
        r.colour("candidate", &value.candidate)
        r.colour("clearing", &value.clearing)
        r.colour("chosen", &value.chosen)
        r.colour("words", &value.words)
        r.outline("lineWidth", &value.lineWidth)
        r.outline("hairline", &value.hairline)
    }

    private static func flank(_ value: inout Look.Composer.Flank, _ r: Reader) {
        r.font("font", &value.font)
        r.colour("ink", &value.ink)
        r.colour("openInk", &value.openInk)
        r.alpha("etchOpacity", &value.etchOpacity)
        r.shadow("etchLight", &value.etchLight)
        r.shadow("etchShade", &value.etchShade)
        r.alpha("heldOpacity", &value.heldOpacity)
        r.length("spacing", &value.spacing)
        r.symbol("keyboard", &value.keyboard)
        r.symbol("keyboardDown", &value.keyboardDown)
        r.symbol("speaking", &value.speaking)
        r.symbol("muted", &value.muted)
        r.symbol("models", &value.models)
        r.symbol("modelsOpen", &value.modelsOpen)
    }

    private static func models(_ value: inout Look.Composer.Models, _ r: Reader) {
        r.length("inset", &value.inset)
        r.reach("height", &value.height)
        r.length("spacing", &value.spacing)
        r.outline("track", &value.track)
        r.length("stop", &value.stop)
        r.length("knob", &value.knob)
        r.alpha("restOpacity", &value.restOpacity)
        r.font("labelFont", &value.labelFont)
        r.length("labelSpacing", &value.labelSpacing)
    }

    private static func well(_ value: inout Look.Composer.Well, _ r: Reader) {
        r.reach("size", &value.size)
        r.reach("jewelSize", &value.jewelSize)
        r.colour("floor", &value.floor)
        r.shadow("bore", &value.bore)
        r.shadow("lip", &value.lip)
        r.shadow("catchLight", &value.catchLight)
        r.colours("edgeColors", &value.edgeColors)
        r.length("edgeWidth", &value.edgeWidth)
    }

    private static func glyph(_ value: inout Look.Composer.Glyph, _ r: Reader) {
        r.reach("size", &value.size)
        r.weight("weight", &value.weight)
        r.colour("openCast", &value.openCast)
    }

    // MARK: Reading one object

    /// One object of the document being read, and the notes the whole read is gathering.
    ///
    /// A reader is scoped to one JSON object and one path, so a note names the field the way the
    /// document writes it (`composer.well.edgeWidth`). Every field is written straight into the
    /// look it is read onto, and a field that is refused leaves what was already there — which
    /// is the compiled default, or, for a compound, the part of it the document did not name.
    final class Reader {
        private(set) var notes: [String] = []
        /// How many fields the document was taken for. A compound — a shadow, a size, a font —
        /// counts once, as one field of the look.
        private(set) var applied = 0
        /// The path of every field taken, in the order the document is walked.
        private(set) var taken: [String] = []
        /// The path of every part walked into.
        private(set) var parts: Set<String> = []
        /// The path of every compound field that reads an object onto what it already holds.
        private(set) var merging: Set<String> = []
        private var here: [String: Any] = [:]
        private var path = ""
        private var asked: Set<String> = []

        /// Reads `object` at `path` with `body`, then reports every key in it `body` never asked
        /// about. The reader is not made again for a nested object, so one read's notes and
        /// count are one list in the order the document is walked.
        func into(_ object: [String: Any], _ path: String, _ body: (Reader) -> Void) {
            let outer = (here, self.path, asked)
            (here, self.path, asked) = (object, path, [])
            body(self)
            for key in object.keys.sorted() where !asked.contains(key) {
                note(key, "is not a field of the look")
            }
            (here, self.path, asked) = outer
        }

        /// A nested object: `composer`, `well`, a jewel. A key that is there and is not an object
        /// is a note, and nothing under it is read.
        func object(_ key: String, _ body: (Reader) -> Void) {
            guard let value = take(key) else { return }
            guard let object = value as? [String: Any] else { return note(key, "is not an object") }
            parts.insert(name(key))
            into(object, name(key), body)
        }

        /// The field at `key` was taken.
        private func took(_ key: String) {
            applied += 1
            taken.append(name(key))
        }

        private func take(_ key: String) -> Any? {
            asked.insert(key)
            guard let value = here[key] else { return nil }
            if value is NSNull { note(key, "is null"); return nil }
            return value
        }

        private func name(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }

        private func note(_ key: String, _ why: String) { notes.append("\(name(key)) \(why)") }

        // MARK: Numbers, each in the range its own field is read in

        /// A length in points: a padding, a radius, a stroke, a blur. Never negative — a negative
        /// length is a value no view is promised to survive — and bounded well above any screen.
        func length(_ key: String, _ value: inout CGFloat) {
            if let number = amount(key, in: 0...4000, "a length in points") {
                took(key)
                value = CGFloat(number)
            }
        }

        /// A length that has to stay big enough to press or to read: the well, the jewel in it,
        /// the badge and its mark, the send control's slot, the row's own width. Bounded below as
        /// well as above, because a document may restyle the microphone and may not put it out of
        /// the person's reach.
        func reach(_ key: String, _ value: inout CGFloat) {
            if let number = amount(key, in: 8...4000, "a length in points, at least 8") {
                took(key)
                value = CGFloat(number)
            }
        }

        /// How much of the screen's width something takes, bounded below for the same reason.
        func fraction(_ key: String, _ value: inout CGFloat) {
            if let number = amount(key, in: 0.1...1, "a share of the width between 0.1 and 1") {
                took(key)
                value = CGFloat(number)
            }
        }

        /// A share of a length rather than of the screen: how wide the wall of a cut is as a
        /// part of the jewel it is cut into. Bounded well under a half, because a wall wider
        /// than the stroke it walls is a mark with no floor left in it.
        func fractionOfOne(_ key: String, _ value: inout CGFloat) {
            if let number = amount(key, in: 0...0.25, "a share between 0 and 0.25") {
                took(key)
                value = CGFloat(number)
            }
        }

        /// How much of its resting height the pane keeps under the keyboard. Bounded below at a
        /// half, so the microphone drawn at that share is still one to press; the well has a
        /// floor of its own besides (`Look.Composer.Well.pressable`).
        func compactShare(_ key: String, _ value: inout CGFloat) {
            if let number = amount(key, in: 0.5...1, "a share of the resting height between 0.5 and 1") {
                took(key)
                value = CGFloat(number)
            }
        }

        /// Room inside a reply, between its blocks, before a list's words or after a quote's bar,
        /// and the width of a quote's bar or a rule: none to 64 points, since a list indents by it
        /// once for every list it is inside and the words have to stay in the column.
        func indent(_ key: String, _ value: inout CGFloat) {
            if let number = amount(key, in: 0...64, "a length in points between 0 and 64") {
                took(key)
                value = CGFloat(number)
            }
        }

        /// The room Topo keeps from every word, in points: none to 64. Past that a phone has no
        /// gap wide enough for him and he is always on the glass.
        /// Room kept clear beside a column of words: at most 200 points, so a reply on a
        /// 320-point phone keeps a column of words 88 points wide or more.
        func inset(_ key: String, _ value: inout CGFloat) {
            if let number = amount(key, in: 0...200, "a length in points between 0 and 200") {
                took(key)
                value = CGFloat(number)
            }
        }

        func clearance(_ key: String, _ value: inout CGFloat) {
            if let number = amount(key, in: 0...64, "a length in points between 0 and 64") {
                took(key)
                value = CGFloat(number)
            }
        }

        /// How fast Topo strolls, in points a second: at least 10, so a move across the screen
        /// ends in under a minute rather than never, and at most 400, past which it is a jump.
        func roamSpeed(_ key: String, _ value: inout CGFloat) {
            if let number = amount(key, in: 10...400, "a speed in points a second between 10 and 400") {
                took(key)
                value = CGFloat(number)
            }
        }

        /// How many times his stroll Topo goes while something is over him: 1, no hurry at all, to
        /// 20, past which a move out from under a turn is a jump.
        func hurry(_ key: String, _ value: inout CGFloat) {
            if let number = amount(key, in: 1...20, "a multiple of the roam speed between 1 and 20") {
                took(key)
                value = CGFloat(number)
            }
        }

        /// How long the chat holds still before Topo picks a new roost: a tenth of a second to
        /// five. Under a tenth he answers every frame of a scroll; over five he is left standing
        /// where he no longer fits.
        func roamSettle(_ key: String, _ value: inout Double) {
            if let number = amount(key, in: 0.1...5, "a time in seconds between 0.1 and 5") {
                took(key)
                value = number
            }
        }

        /// The width of an outline drawn over the chat to show something rather than to be it:
        /// from a tenth of a point, the finest a screen shows, to 8, past which an outline covers
        /// what it outlines.
        func outline(_ key: String, _ value: inout CGFloat) {
            if let number = amount(key, in: 0.1...8, "a width in points between 0.1 and 8") {
                took(key)
                value = CGFloat(number)
            }
        }

        /// An alpha, or anything else that is a share of one.
        func alpha(_ key: String, _ value: inout Double) {
            if let number = amount(key, in: 0...1, "a number between 0 and 1") {
                took(key)
                value = number
            }
        }

        /// How much colour is left in something. Over 1 is more than it started with, which is a
        /// thing to ask for; the bound is where it stops meaning anything.
        func saturation(_ key: String, _ value: inout Double) {
            if let number = amount(key, in: 0...4, "a number between 0 and 4") {
                took(key)
                value = number
            }
        }

        /// Points to a pixel of a picture drawn in pixels: a quarter of a point to four. Under a
        /// quarter nothing of a pixel is left to see; over four one pixel is a block.
        func pixelScale(_ key: String, _ value: inout CGFloat) {
            if let number = amount(key, in: 0.25...4, "a number of points to a pixel between 0.25 and 4") {
                took(key)
                value = CGFloat(number)
            }
        }

        /// How long a frame of an animation stays up: from a hundred-and-twentieth of a second,
        /// the fastest display, to one. Never nothing, since a frame that lasts no time is a
        /// clock asked to tick without end.
        func frameInterval(_ key: String, _ value: inout Double) {
            if let number = amount(key, in: (1.0 / 120)...1, "a time in seconds between 1/120 and 1") {
                took(key)
                value = number
            }
        }

        /// One breath of a pulse: from a third of a second, under which a breath is a flash, to 5,
        /// past which it is too slow to be seen as one.
        func breath(_ key: String, _ value: inout Double) {
            if let number = amount(key, in: 0.3...5, "a time in seconds between 0.3 and 5") {
                took(key)
                value = number
            }
        }

        func seconds(_ key: String, _ value: inout Double) {
            if let number = amount(key, in: 0...10, "a time in seconds, up to 10") {
                took(key)
                value = number
            }
        }

        func degrees(_ key: String, _ value: inout Angle) {
            if let number = amount(key, in: -3600...3600, "an angle in degrees") {
                took(key)
                value = .degrees(number)
            }
        }

        /// A width a column is allowed to become, which may be no bound at all.
        func width(_ key: String, _ value: inout CGFloat) {
            guard let raw = take(key) else { return }
            if let text = raw as? String {
                guard text == "infinity" else {
                    return note(key, "is not a length in points or \"infinity\"")
                }
                took(key)
                value = .infinity
                return
            }
            guard let number = finite(raw), (0...20000).contains(number) else {
                return note(key, "is not a length in points between 0 and 20000, or \"infinity\"")
            }
            took(key)
            value = CGFloat(number)
        }

        /// One number of the document, in the range the field that asked for it is read in, or
        /// nothing at all with the reason written down. It counts nothing of its own: a field is
        /// counted where it is set, so a compound of several numbers counts once.
        private func amount(_ key: String, in range: ClosedRange<Double>, _ what: String) -> Double? {
            guard let raw = take(key) else { return nil }
            guard let number = finite(raw) else {
                note(key, "is not \(what)")
                return nil
            }
            guard range.contains(number) else {
                note(key, "is \(number), and \(what) is read from \(range.lowerBound) to \(range.upperBound)")
                return nil
            }
            return number
        }

        /// JSON hands back numbers as `NSNumber`, and a `Bool` is one of those. `value is Bool`
        /// is not the way to tell them apart: the bridge answers true for a number whose value
        /// happens to be 0 or 1, so every `1` in a document would be thrown away as a boolean.
        /// What a boolean actually is, is a `CFBoolean`, which is what is asked here.
        ///
        /// Nothing infinite gets through either. JSON has no spelling for one, but a number too
        /// big for a `Double` becomes one, and a view handed an infinity is a view nothing
        /// promises to survive.
        private func finite(_ value: Any) -> Double? {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }

        // MARK: Colours

        /// A colour as `Theme` writes one: a light value and a dark one. `"#RRGGBB"`, with
        /// `"#RRGGBBAA"` for an alpha and the `#` optional; one string on its own is the same
        /// colour in both appearances, which is what a jewel's own glass wants.
        func colour(_ key: String, _ value: inout Color) {
            if let colour = paint(key) {
                took(key)
                value = colour
            }
        }

        private func paint(_ key: String) -> Color? {
            guard let raw = take(key) else { return nil }
            guard let colour = Self.colour(raw) else {
                note(key, "is not \"#RRGGBB\" or \"#RRGGBBAA\", or a pair of them for light and dark")
                return nil
            }
            return colour
        }

        /// The cut edge of the well, which is a gradient and so a list of them.
        func colours(_ key: String, _ value: inout [Color]) {
            guard let raw = take(key) else { return }
            guard let list = raw as? [Any], (1...8).contains(list.count) else {
                return note(key, "is not a list of 1 to 8 colours")
            }
            var colours: [Color] = []
            for entry in list {
                guard let colour = Self.colour(entry) else {
                    return note(key, "holds something that is not a colour")
                }
                colours.append(colour)
            }
            took(key)
            value = colours
        }

        static func colour(_ value: Any) -> Color? {
            if let text = value as? String { return Theme.colour(light: text, dark: text) }
            guard let pair = value as? [Any], pair.count == 2,
                  let light = pair[0] as? String, let dark = pair[1] as? String else { return nil }
            return Theme.colour(light: light, dark: dark)
        }

        // MARK: Names

        /// What something is called: a line of text with something in it besides space, no longer
        /// than `Look.Mind.longest` characters and with no control character, a newline among
        /// them, since it is drawn on one line of the notice and of the slider.
        func title(_ key: String, _ value: inout String) {
            guard let raw = take(key) else { return }
            guard let text = raw as? String else { return note(key, "is not a name") }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.count <= Look.Mind.longest,
                  !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) })
            else { return note(key, "is not a name of 1 to \(Look.Mind.longest) characters on one line") }
            took(key)
            value = trimmed
        }

        func surface(_ key: String, _ value: inout Look.Surface) { named(key, &value) }
        func codeOverflow(_ key: String, _ value: inout Look.Markdown.CodeOverflow) { named(key, &value) }

        /// Where Topo sits: `"roam"`, `"glass"` or `"pinned"`.
        func placement(_ key: String, _ value: inout Look.Mascot.Placement) { named(key, &value) }

        /// Where a pinned Topo's centre is put: an object naming an `x` and a `y`, each a fraction
        /// from 0 to 1 of the transcript's frame carried down to the pane's foot. It is one place and not two numbers, so it is
        /// taken whole or refused whole: a pin with one half out of range, or missing, is not a
        /// place the person put him, and the compiled pin stands.
        func pin(_ key: String, _ value: inout CGPoint) {
            guard let raw = take(key) else { return }
            guard let object = raw as? [String: Any] else {
                return note(key, "is not an object naming an x and a y")
            }
            var x: Double?, y: Double?
            let before = notes.count
            into(object, name(key)) { r in
                x = r.amount("x", in: 0...1, "a fraction across the chat between 0 and 1")
                y = r.amount("y", in: 0...1, "a fraction down the chat, from the transcript's top to the glass's foot, between 0 and 1")
            }
            guard let x, let y else {
                if notes.count == before { note(key, "needs both an x and a y") }
                return
            }
            took(key)
            value = CGPoint(x: x, y: y)
        }

        /// The name of a picture in the app's asset catalogue. What names are in there is not
        /// something this can be asked — the catalogue is the app's and this type is every
        /// platform's — so a name that is not one of them is a jewel with no stone in it, which
        /// is the same answer the palette gives to a colour nobody can read.
        func asset(_ key: String, _ value: inout String) {
            guard let raw = take(key) else { return }
            guard let text = raw as? String, (1...200).contains(text.count) else {
                return note(key, "is not the name of a picture in the app")
            }
            took(key)
            value = text
        }

        /// A mark on a control, by its SF Symbol name: one the system has, since a control whose
        /// mark is a name nothing draws is a control nobody can see to press.
        func symbol(_ key: String, _ value: inout String) {
            guard let raw = take(key) else { return }
            guard let text = raw as? String, (1...200).contains(text.count), Self.isSymbol(text) else {
                return note(key, "is not the name of a symbol the system has")
            }
            took(key)
            value = text
        }

        private static func isSymbol(_ name: String) -> Bool {
            #if canImport(UIKit)
            UIImage(systemName: name) != nil
            #elseif canImport(AppKit)
            NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
            #else
            false
            #endif
        }

        /// How a colour laid over a picture meets it, by the name SwiftUI gives it.
        func blend(_ key: String, _ value: inout BlendMode) {
            guard let raw = take(key) else { return }
            guard let text = raw as? String, let mode = Self.blends[text] else {
                return note(key, "is not one of \(Self.listed(Self.blends.keys))")
            }
            took(key)
            value = mode
        }

        static let blends: [String: BlendMode] = [
            "normal": .normal, "hue": .hue, "color": .color, "saturation": .saturation,
            "luminosity": .luminosity, "multiply": .multiply, "screen": .screen,
            "overlay": .overlay, "softLight": .softLight, "hardLight": .hardLight,
            "lighten": .lighten, "darken": .darken,
        ]

        private func named<T: RawRepresentable & CaseIterable>(_ key: String, _ value: inout T)
        where T.RawValue == String {
            guard let raw = take(key) else { return }
            guard let text = raw as? String, let one = T(rawValue: text) else {
                return note(key, "is not one of \(Self.cases(T.self))")
            }
            took(key)
            value = one
        }

        private static func cases<T: RawRepresentable & CaseIterable>(_ type: T.Type) -> String
        where T.RawValue == String {
            T.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        }

        /// A weight of type, by the name SwiftUI gives it.
        func weight(_ key: String, _ value: inout Font.Weight) {
            if let weight = weighed(key) {
                took(key)
                value = weight
            }
        }

        private func weighed(_ key: String) -> Font.Weight? {
            guard let raw = take(key) else { return nil }
            guard let text = raw as? String, let weight = Self.weights[text] else {
                note(key, "is not one of \(Self.listed(Self.weights.keys))")
                return nil
            }
            return weight
        }

        private func styled(_ key: String) -> Font.TextStyle? {
            guard let raw = take(key) else { return nil }
            guard let text = raw as? String, let style = Self.styles[text] else {
                note(key, "is not one of \(Self.listed(Self.styles.keys))")
                return nil
            }
            return style
        }

        static let weights: [String: Font.Weight] = [
            "ultraLight": .ultraLight, "thin": .thin, "light": .light, "regular": .regular,
            "medium": .medium, "semibold": .semibold, "bold": .bold, "heavy": .heavy,
            "black": .black,
        ]

        static let styles: [String: Font.TextStyle] = [
            "largeTitle": .largeTitle, "title": .title, "title2": .title2, "title3": .title3,
            "headline": .headline, "subheadline": .subheadline, "body": .body,
            "callout": .callout, "footnote": .footnote, "caption": .caption, "caption2": .caption2,
        ]

        /// Each style's size in points at the default text setting, which is what a field's
        /// `largest` is held against: the person's own setting scales every style alike.
        static let styleSizes: [Font.TextStyle: Double] = [
            .largeTitle: 34, .title: 28, .title2: 22, .title3: 20, .headline: 17, .body: 17,
            .callout: 16, .subheadline: 15, .footnote: 13, .caption: 12, .caption2: 11,
        ]

        private func fits(_ style: Font.TextStyle, _ largest: Double) -> Bool {
            (Self.styleSizes[style] ?? 0) <= largest
        }

        private static func listed(_ keys: some Collection<String>) -> String {
            keys.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
        }

        // MARK: Compounds

        /// Type: one of the system's own sizes by name (`"body"`, `"caption2"`), which follows
        /// the person's text-size setting, or a fixed size in points, either of them at a weight.
        /// A bare `"body"` is the short way to say the first.
        ///
        /// A font cannot be read back out of SwiftUI, so this one is replaced rather than merged:
        /// an object naming a weight and neither a style nor a size is a note and the compiled
        /// font, since a weight alone has nothing to weigh.
        ///
        /// `largest` is the biggest the field's place can draw, in points: a fixed size above it
        /// is drawn at it, and a style whose size at the default text setting is above it is a
        /// note and the compiled font, since a style's size cannot be pinned without losing what
        /// makes it a style.
        func font(_ key: String, _ value: inout Font, largest: Double = 400) {
            guard let raw = take(key) else { return }
            if let text = raw as? String {
                guard let style = Self.styles[text] else {
                    return note(key, "is not one of \(Self.listed(Self.styles.keys))")
                }
                guard fits(style, largest) else {
                    return note(key, "is \(text), larger than the \(Int(largest)) points it is drawn at most")
                }
                took(key)
                value = .system(style)
                return
            }
            guard let object = raw as? [String: Any] else {
                return note(key, "is not a type style's name, or an object naming a style or a size")
            }
            var made: Font?
            var weight: Font.Weight?
            var tooLarge: Font.TextStyle?
            var clamped: Double?
            into(object, name(key)) { r in
                if let style = r.styled("style") {
                    if r.fits(style, largest) { made = .system(style) } else { tooLarge = style }
                }
                if let size = r.amount("size", in: 4...400, "a size in points") {
                    if size > largest { clamped = size }
                    made = .system(size: CGFloat(min(size, largest)))
                }
                weight = r.weighed("weight")
            }
            if let clamped {
                note(key, "is \(clamped) points, drawn at \(Int(largest)), the most its place holds")
            }
            if let tooLarge {
                // The style is refused whatever else the object says; a size beside it still sets.
                note(key, "is \(tooLarge), larger than the \(Int(largest)) points it is drawn at most")
                if made == nil { return }
            }
            guard var font = made else {
                if object["style"] == nil, object["size"] == nil {
                    note(key, "names neither a style nor a size")
                }
                return
            }
            if let weight { font = font.weight(weight) }
            took(key)
            value = font
        }

        /// A shadow, cast or cut: a colour and three lengths, of which the last two may be
        /// negative because they are offsets. What the document does not name keeps what the
        /// compiled shadow says, so `{"radius": 9}` is the same shadow, further out.
        func shadow(_ key: String, _ value: inout Look.Shadow) {
            guard let raw = take(key) else { return }
            guard let object = raw as? [String: Any] else {
                return note(key, "is not an object naming a colour, a radius and an offset")
            }
            merging.insert(name(key))
            var shadow = value
            var named = false
            into(object, name(key)) { r in
                if let colour = r.paint("color") { shadow.color = colour; named = true }
                if let radius = r.amount("radius", in: 0...400, "a length in points") {
                    shadow.radius = CGFloat(radius)
                    named = true
                }
                if let x = r.amount("x", in: -400...400, "a length in points") {
                    shadow.x = CGFloat(x)
                    named = true
                }
                if let y = r.amount("y", in: -400...400, "a length in points") {
                    shadow.y = CGFloat(y)
                    named = true
                }
            }
            guard named else { return }
            took(key)
            value = shadow
        }

        /// A place in a unit square: the centre of a gradient, the end of a sheen. Outside the
        /// square is a real answer — a gradient centred off the shape it fills — so the range is
        /// wider than the square rather than being the square.
        func point(_ key: String, _ value: inout UnitPoint) {
            guard let raw = take(key) else { return }
            guard let object = raw as? [String: Any] else {
                return note(key, "is not an object naming an x and a y")
            }
            merging.insert(name(key))
            var point = value
            var named = false
            into(object, name(key)) { r in
                if let x = r.amount("x", in: -10...10, "a place between -10 and 10") {
                    point.x = CGFloat(x)
                    named = true
                }
                if let y = r.amount("y", in: -10...10, "a place between -10 and 10") {
                    point.y = CGFloat(y)
                    named = true
                }
            }
            guard named else { return }
            took(key)
            value = point
        }
    }
}

#if os(iOS)
extension View {
    /// What this subtree draws with: the look the memory read out of the vault, which is the
    /// compiled one until a document says otherwise and again the moment a sign-out takes the
    /// folder away.
    ///
    /// It is a modifier rather than a line inside the app's scene because a `Scene` body is not
    /// something a test can host: this is the one join between the document and every view drawn
    /// from it, and a join nothing can hold is a document that decodes perfectly and is never
    /// worn.
    func wearing(_ memory: Memory) -> some View {
        wearing(memory, tuning: .shared)
    }

    /// The vault's look — in a debug build the launch's look in its place where one was given —
    /// with this device's override worn over it (`Tuning`): the pin a drag left and the placement
    /// chosen in the settings sheet, and a debug build's sliders.
    func wearing(_ memory: Memory, tuning: Tuning) -> some View {
        #if DEBUG
        environment(\.look, tuning.worn(over: DebugRun.look ?? memory.look))
        #else
        environment(\.look, tuning.worn(over: memory.look))
        #endif
    }
}
#endif
