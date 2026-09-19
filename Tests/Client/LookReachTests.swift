import Foundation
import SwiftUI
import TopoAuth
import TopoCore
import TopoCoreTesting
import UIKit
import XCTest

@testable import Topo

/// Every field `look.json` can set, shown reaching the pixels.
///
/// The claim the document makes is that the interface is adjustable from outside the source, and
/// a field that decodes into a `Look` nothing draws with is that claim being false in a way no
/// decoding test can see. So each field of the full fixture is cut out into a document of its
/// own, decoded, and drawn: if no surface of the chat draws differently under it, the field is
/// not reaching the pixels and this fails, naming it.
///
/// Two renderers, cheapest first. `ImageRenderer` draws a row, a lozenge or the badge in
/// milliseconds and answers for most of the look. What it does not draw — the inside of a
/// `ScrollView`, a `containerRelativeFrame`, a `TextField`'s text, the system's own glass,
/// `.saturation` — goes to `LookStage`, which puts the whole chat in a window and takes the
/// picture off the render server. A field neither can show is named in `unshowable` with the
/// reason, and there is one.
@MainActor
final class LookReachTests: XCTestCase {

    // MARK: Every field of the document

    /// The fields of the look no still picture can be asked about, and why.
    static let unshowable: [String: String] = [
        "composer.duration": "is a time, and a still frame is the same either way",
        "composer.presenceDuration": "is a time, and a still frame is the same either way",
        "composer.presenceRise": "is the share of a rise the content has run under the pane, "
            + "and every still the suite has is at one end of it or the other — a pane whole "
            + "under a long transcript at any rise — so only a transcript ending inside the rise "
            + "itself would differ; `PanePresenceTests` holds the mapping",
    ]

    func testEveryFieldTheDocumentSetsReachesThePixels() throws {
        let fields = try LookFieldDocuments.all()
        XCTAssertEqual(fields.count, LookFixture.fields,
                       "the per-field documents do not add up to the fixture's own count")

        var missing: [String] = []
        for field in fields {
            let reading = LookDocument.read(field.document)
            XCTAssertEqual(reading.notes, [], "\(field.path): the cut-out document does not read")
            if Self.unshowable[field.path] != nil { continue }
            if try !draws(field.path) { missing.append(field.path) }
        }
        XCTAssertEqual(missing, [], "these fields of the document reach no pixel")
    }

    /// The exception list is a list of fields that really cannot be shown, not a place to put one
    /// that has stopped being drawn: a field named there that a renderer *can* see is a stale
    /// excuse, and this is what says so.
    func testTheUnshowableFieldsAreReallyUnshowable() throws {
        for field in try LookFieldDocuments.all() where Self.unshowable[field.path] != nil {
            XCTAssertFalse(try draws(field.path),
                           "\(field.path) is excused as \(Self.unshowable[field.path]!), and it draws")
        }
    }

    /// Whether any surface of the chat is drawn differently under the document that sets this
    /// field alone than without it. The surfaces are tried in the order the field's own section
    /// is most likely to show in, and the first difference is the answer, so a field costs one
    /// render and not a dozen.
    ///
    /// Both sides are drawn under the same companion, which is what makes a field of Topo's side
    /// answerable at all: `plain` ships as an enclosure set to nothing, so an outline colour with
    /// no outline to draw, or a radius with no shape to round, changes no pixel however faithfully
    /// the view reads it. The companion gives Topo's side something drawn; the field under test
    /// overrides its own part of it, and the two pictures then differ by that field alone.
    private func draws(_ path: String) throws -> Bool {
        let field = try XCTUnwrap(LookFieldDocuments.all().first { $0.path == path }, path)
        let look = LookDocument.read(field.document, onto: Self.companion(path)).look
        for surface in Surface.order(for: path) {
            if try surface.raster(look, path) != baseline(surface, path) { return true }
        }
        return false
    }

    private var baselines: [String: String] = [:]

    private func baseline(_ surface: Surface, _ path: String) throws -> String {
        let key = "\(surface.rawValue)|\(Surface.flattened(path))|\(Self.companioned(path))"
        if let kept = baselines[key] { return kept }
        let made = try surface.raster(Self.companion(path), path)
        baselines[key] = made
        return made
    }

    /// Topo's side is the one part of the look that draws nothing at all by default, so a field
    /// of it is shown against a companion that draws.
    private static func companion(_ path: String) -> Look {
        var look = Look()
        guard companioned(path) else { return look }
        look.plain = Look.Enclosure(accent: Color(red: 0.1, green: 0.7, blue: 0.4),
                                    fillOpacity: 0.5, strokeWidth: 3, cornerRadius: 4,
                                    horizontalPadding: 10, verticalPadding: 6, surface: .flat)
        return look
    }

    private static func companioned(_ path: String) -> Bool { path.hasPrefix("plain.") }

    /// The surfaces a field can show on. The first ten are `ImageRenderer`'s; the last three put
    /// the chat in a window and go through the render server.
    @MainActor
    enum Surface: String, CaseIterable {
        case turnPerson, turnTopo, draftWriting, draftInFlight, draftEmpty
        case composerIdle, composerHeld, composerHandsFree, composerDimmed
        case badge, settings
        case canvas, canvasDimmed, canvasNotice, canvasWide

        /// Which surfaces to try, in order, for a field at this path.
        static func order(for path: String) -> [Surface] {
            let staged: [Surface] = [.canvas, .canvasNotice, .canvasDimmed]
            switch path.split(separator: ".").first.map(String.init) ?? "" {
            case "transcript": return [.turnPerson, .turnTopo, .draftWriting, .canvasWide] + staged
            case "bubble": return [.turnPerson, .draftWriting] + staged
            case "plain": return [.turnTopo] + staged
            case "draft": return [.draftWriting, .draftEmpty, .draftInFlight] + staged
            case "badge": return [.badge] + staged
            case "jewel": return [.badge, .composerIdle] + staged
            case "settings": return [.settings]
            case "composer" where path.hasPrefix("composer.openJewel"):
                return [.composerHeld, .composerHandsFree] + staged
            case "composer":
                return [.composerIdle, .composerHeld, .composerHandsFree, .composerDimmed] + staged
            default: return allCases
            }
        }

        /// The composer's own surface is one of the system's backdrops, which `ImageRenderer`
        /// does not draw, so every composer render here is flattened — except the one asking
        /// about that very field, which is what the staged surfaces are for.
        static func flattened(_ path: String) -> String { path == "composer.surface" ? path : "flat" }

        func raster(_ look: Look, _ path: String) throws -> String {
            var look = look
            if path != "composer.surface" { look.composer.surface = .flat }
            switch self {
            case .turnPerson: return try Self.drawn(TurnRow(turn: Fixtures.person), look)
            case .turnTopo: return try Self.drawn(TurnRow(turn: Fixtures.topo), look)
            case .draftWriting: return try Self.drawn(DraftRow(draft: Fixtures.writing), look)
            case .draftInFlight: return try Self.drawn(DraftRow(draft: Fixtures.inFlight), look)
            case .draftEmpty: return try Self.drawn(DraftRow(draft: Fixtures.empty), look)
            case .composerIdle: return try Self.drawn(Fixtures.composer(.init()), look, 340, 170)
            case .composerHeld: return try Self.drawn(Fixtures.composer(Fixtures.held), look, 340, 170)
            case .composerHandsFree: return try Self.drawn(Fixtures.composer(Fixtures.handsFree), look, 340, 170)
            case .composerDimmed:
                return try Self.drawn(Fixtures.composer(.init(canListen: false)), look, 340, 170)
            case .badge: return try Self.drawn(TopoBadge(), look, 80, 80)
            case .settings:
                return try LookStage.raster(SettingsView(signOut: SignOut()).environment(Fixtures.harness()),
                                            look: look)
            case .canvas: return try LookStage.raster(ChatCanvas(row: .writing), look: look)
            case .canvasDimmed:
                return try LookStage.raster(ChatCanvas(mic: .init(canListen: false)), look: look)
            case .canvasNotice:
                return try LookStage.raster(ChatCanvas(notice: "Topo is on another device."),
                                            look: look)
            // A column wider than the widest the look lets it be, which is the one way a bound
            // on that width is a bound on anything.
            case .canvasWide:
                return try LookStage.raster(ChatCanvas(row: .writing), look: look,
                                            size: CGSize(width: 900, height: 700))
            }
        }

        /// `ImageRenderer` over one piece of the chat, on white so a digest has something to be
        /// a digest of.
        private static func drawn(_ view: some View, _ look: Look,
                                  _ width: CGFloat = 320, _ height: CGFloat? = nil) throws -> String {
            let sized = view
                .environment(\.look, look)
                .frame(width: width, height: height)
                .background(Color.white)
            let renderer = ImageRenderer(content: sized)
            renderer.scale = 2
            return try LookStage.digest(try XCTUnwrap(renderer.uiImage, "the surface rendered to nothing"))
        }
    }
}

/// The fixture's fields, one document each. A field of the look is one JSON leaf, except for the
/// four compounds — a shadow, a size, a place, a font — which the reader takes as one field and
/// which are therefore cut out whole.
enum LookFieldDocuments {
    struct Field {
        let path: String
        let document: String
    }

    static func all() throws -> [Field] {
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(LookFixture.full.utf8)) as? [String: Any],
            "the fixture is not a JSON object")
        return try leaves(root, "").map { path, value in
            var node: Any = value
            for key in path.split(separator: ".").map(String.init).reversed() { node = [key: node] }
            let data = try JSONSerialization.data(withJSONObject: node)
            return Field(path: path, document: String(decoding: data, as: UTF8.self))
        }
    }

    private static func leaves(_ object: [String: Any], _ path: String) -> [(String, Any)] {
        var found: [(String, Any)] = []
        for (key, value) in object.sorted(by: { $0.key < $1.key }) {
            let here = path.isEmpty ? key : "\(path).\(key)"
            if let nested = value as? [String: Any], !isCompound(nested) {
                found += leaves(nested, here)
            } else {
                found.append((here, value))
            }
        }
        return found
    }

    /// An object the reader takes as one field rather than walking into: the four shapes a
    /// compound is written in.
    private static func isCompound(_ object: [String: Any]) -> Bool {
        let keys = Set(object.keys)
        return keys.isSubset(of: ["color", "radius", "x", "y"])
            || keys.isSubset(of: ["width", "height"])
            || keys.isSubset(of: ["style", "size", "weight"])
    }
}

/// What the surfaces are drawn with.
@MainActor
enum Fixtures {
    static let person = turn(.person, "Remind me to pick up Daphne's food.")
    static let topo = turn(.assistant, "Paris.")

    static func turn(_ role: TurnRole, _ text: String) -> Turn {
        Turn(ref: TurnRef(device: DeviceID("phone"), sequence: role == .person ? 1 : 2),
             parents: [], role: role, text: text,
             at: Date(timeIntervalSince1970: 1_700_000_000))
    }

    static var writing: Draft {
        Draft(text: .constant("Remind me to pick up Daphne's food"), typing: .constant(false))
    }

    /// Nothing written: the row is at the width it holds for a caret, and its send control is
    /// at the alpha that says there is nothing to press it for.
    static var empty: Draft {
        Draft(text: .constant(""), typing: .constant(true))
    }

    static var inFlight: Draft {
        Draft(text: .constant("Remind me to pick up Daphne's food"), typing: .constant(false),
              sending: true)
    }

    static let held = Composer.MicState(canListen: true, listening: true, owner: .chat, handsFree: false)
    static let handsFree = Composer.MicState(canListen: true, listening: true, owner: .chat, handsFree: true)

    static func composer(_ mic: Composer.MicState) -> some View {
        Composer(typing: .constant(false), mic: mic)
    }

    /// The settings sheet needs a mind to pick a model from, and nothing else of the app.
    static func harness() -> Harness {
        Harness(database: InMemoryRecordDatabase(), tokens: NoToken(), device: DeviceID("phone"),
                ensureZone: {}, defaults: defaults())
    }

    private static func defaults() -> UserDefaults {
        let suite = "topo-look-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
    }
}

private struct NoToken: TokenProvider {
    func accessToken() async throws -> String { throw TokenProviderError.signedOut }
}
