import SwiftUI

/// Every value the interface draws with, in one place: colours, surfaces, radii, paddings, sizes
/// and type. A view reads it from the environment (`@Environment(\.look)`) and carries no literal
/// of its own — a number written inline is a number nothing outside the source can reach, and the
/// point of this type is that the interface is adjustable from outside the views. A view that
/// needs a value the look does not have adds a field here.
///
/// `Theme` is the palette these defaults are drawn from, so the colour rule is the same one: the
/// colour says who is on the other end and never says state.
///
/// The values differ by screen, because a watch, a phone and a television are different distances
/// from the eye; the fields do not, so one transcript view draws on all three. `Look()` is the
/// look of the screen it is compiled for, and `Look(.watch)`, `Look(.tv)` and `Look(.phone)` are
/// reachable from any of them — which is how one screen's transcript is drawn under another's
/// look, in a preview or in a render.
struct Look: Equatable, Sendable {
    var transcript: Transcript
    /// The person's own turn, which is enclosed.
    var bubble: Enclosure
    /// Topo's turn, which is not: the same fields set to nothing, so the words sit in the column
    /// as plain text. It is a field rather than a branch in the view, so a look that wants Topo's
    /// side drawn differently says so here and no view changes.
    var plain: Enclosure
    /// The glass a cabochon is cut from. One value, so the mark in the navigation bar and the
    /// microphone are poured from the same slab.
    var jewel: Jewel
    /// The mark at the trailing edge of the navigation bar.
    var badge: Badge
    /// The sheet the badge opens.
    var settings: Settings
    /// The lozenge under the transcript, and the microphone set into it.
    var composer: Composer
    /// The person's next turn, written at the end of the transcript.
    var draft: Draft

    init(_ screen: Screen = .current) {
        transcript = Transcript(screen)
        bubble = .bubble(screen)
        plain = .plain
        jewel = Jewel()
        badge = Badge()
        settings = Settings()
        composer = Composer()
        draft = Draft(screen)
    }

    /// The three screens the client is drawn on.
    enum Screen: String, Equatable, Sendable, CaseIterable {
        case phone, watch, tv

        /// The screen this build draws on. The iPad and the hub take the phone's.
        static var current: Screen {
            #if os(watchOS)
            .watch
            #elseif os(tvOS)
            .tv
            #else
            .phone
            #endif
        }
    }

    /// The column the turns are set in, and the type they are set in.
    struct Transcript: Equatable, Sendable {
        /// Between one turn and the next.
        var spacing: CGFloat
        /// Between a turn's words and its time.
        var captionSpacing: CGFloat
        /// From the column to the edge of the screen.
        var horizontalPadding: CGFloat
        /// How wide the column is allowed to become on a screen wider than it.
        var maximumLineWidth: CGFloat
        /// A turn's words.
        var bodyFont: Font
        /// A time.
        var labelFont: Font
        /// The line at the head of the transcript saying this screen is only watching.
        var noticeFont: Font
        /// A turn's words.
        var text: Color = Theme.text
        /// A time, and the notice.
        var caption: Color = Theme.textMuted

        init(_ screen: Screen = .current) {
            switch screen {
            case .watch:
                spacing = 8
                captionSpacing = 2
                horizontalPadding = 2
                maximumLineWidth = .infinity
                bodyFont = .system(.footnote)
                labelFont = .system(.caption2).weight(.semibold)
                noticeFont = .system(.caption2)
            case .tv:
                spacing = 24
                captionSpacing = 4
                horizontalPadding = 48
                maximumLineWidth = 1100
                bodyFont = .system(.title3)
                labelFont = .system(.caption).weight(.semibold)
                noticeFont = .system(.caption)
            case .phone:
                spacing = 14
                captionSpacing = 2
                horizontalPadding = 16
                maximumLineWidth = 672
                bodyFont = .system(.body)
                labelFont = .system(.caption).weight(.semibold)
                noticeFont = .system(.caption)
            }
        }
    }

    /// What a turn's words are drawn on. The person's is an outline in their side's colour over
    /// a faint tint of the same, so it reads as an enclosure rather than a block of colour;
    /// Topo's is nothing at all. One type, so which side a turn is on is all the view decides.
    struct Enclosure: Equatable, Sendable {
        /// The outline, and the tint under it.
        var accent: Color
        /// The tint's alpha. The fill is a wash under the outline rather than a block of colour.
        var fillOpacity: Double
        var strokeWidth: CGFloat
        var cornerRadius: CGFloat
        var horizontalPadding: CGFloat
        var verticalPadding: CGFloat
        /// What sits under the tint.
        var surface: Surface

        /// The person's side. `primary` is the person's colour in the palette, the same one
        /// Topo's own voice wears; `secondary` is reserved for a turn a process put into the
        /// transcript.
        static func bubble(_ screen: Screen) -> Enclosure {
            let padding: (CGFloat, CGFloat)
            switch screen {
            case .watch: padding = (8, 6)
            case .tv: padding = (20, 14)
            case .phone: padding = (14, 10)
            }
            return Enclosure(accent: Theme.primary, fillOpacity: 0.12, strokeWidth: 1.5,
                             cornerRadius: 18, horizontalPadding: padding.0,
                             verticalPadding: padding.1, surface: .flat)
        }

        /// The draft's, which is the person's bubble in a colour of its own: the accent alone
        /// differs, so the row keeps its shape as the turn lands and only the colour changes.
        static func draft(_ screen: Screen, accent: Color) -> Enclosure {
            var enclosure = bubble(screen)
            enclosure.accent = accent
            return enclosure
        }

        /// Topo's side: no outline, no tint, no room taken around the words. The same on every
        /// screen, because there is nothing of it to size.
        static let plain = Enclosure(accent: .clear, fillOpacity: 0, strokeWidth: 0,
                                     cornerRadius: 0, horizontalPadding: 0, verticalPadding: 0,
                                     surface: .flat)
    }

    /// What a surface is made of. `flat` is the tint alone over whatever is behind it; the other
    /// two put one of the system's backdrops under it, `material` the thicker and `glass` the
    /// thinnest.
    enum Surface: String, Equatable, Sendable, CaseIterable {
        case glass, material, flat
    }

    /// A shadow, cast or cut: the same four values whichever way `StainedGlass` uses it.
    struct Shadow: Equatable, Sendable {
        var color: Color
        var radius: CGFloat
        var x: CGFloat = 0
        var y: CGFloat = 0
    }

    /// A cabochon cut from a slab of poured glass: a domed body paler where the glass is thinner,
    /// a milky drift across it, a darker band on the diagonal, a sheen off the top and a
    /// jeweller's bevel around a true circle. The whole slab is these values, so a jewel of
    /// another colour is another `Jewel` and not another view.
    ///
    /// The lengths are the ones the glass is poured at rather than fractions of the disc it is
    /// drawn in, so the same slab read at 30pt and at 64pt is a different part of the same pour.
    struct Jewel: Equatable, Sendable {
        /// The four glasses, darkest first.
        var deep = Color(red: 0.05, green: 0.24, blue: 0.36)
        var mid = Color(red: 0.08, green: 0.42, blue: 0.53)
        var pale = Color(red: 0.55, green: 0.80, blue: 0.84)
        var milk = Color(red: 0.80, green: 0.92, blue: 0.93)

        /// Which of the four a part of the slab is poured from. The parts name a glass rather
        /// than a colour, so a slab of another colour is the four values and the rest follows —
        /// and so a jewel lit from behind is the same four read in another order.
        enum Glass: String, Equatable, Sendable, CaseIterable { case deep, mid, pale, milk }

        func colour(_ glass: Glass) -> Color {
            switch glass {
            case .deep: deep
            case .mid: mid
            case .pale: pale
            case .milk: milk
            }
        }

        /// The body: a radial gradient centred low and right, where the glass is thinnest.
        /// Its stops run from that thin centre outwards.
        var bodyGlasses: [Glass] = [.mid, .deep, .deep]
        var bodyCenter = UnitPoint(x: 0.62, y: 0.72)
        var bodyEndRadius: CGFloat = 46
        /// Cut into the body from the top, and the light caught under its lower edge.
        var bodyShade = Shadow(color: .black.opacity(0.45), radius: 5, y: 3)
        var bodyCatch = Shadow(color: .white.opacity(0.3), radius: 2, y: -2)

        /// The milky drift, an off-centre swirl of thinner glass: a core and the halo round it.
        var driftGlass: Glass = .milk
        var driftHaloGlass: Glass = .pale
        var driftSize = CGSize(width: 44, height: 30)
        var driftEndRadius: CGFloat = 22
        var driftOpacity = 0.55
        var driftHaloOpacity = 0.25
        var driftAngle = Angle.degrees(-28)
        var driftOffset = CGSize(width: 6, height: 8)
        var driftBlur: CGFloat = 2

        /// The dark band across the diagonal.
        var bandGlass: Glass = .deep
        var bandSize = CGSize(width: 14, height: 90)
        var bandOpacity = 0.6
        var bandAngle = Angle.degrees(24)
        var bandOffset = CGSize(width: 4, height: -4)
        var bandBlur: CGFloat = 1.5

        /// The sheen off the top of the slab, and the shade off its foot.
        var sheenColor = Color.white
        var sheenShadeColor = Color.black
        var sheenOpacity = 0.35
        var sheenShadeOpacity = 0.15
        var sheenStart = UnitPoint(x: 0.3, y: 0)
        var sheenEnd = UnitPoint(x: 0.7, y: 1)

        /// The cut: a true circle with a bright bevel at the top and a dark one at the foot.
        /// The lit side of the edge is one colour at two opacities; the foot is the other.
        var bevelColor = Color.white
        var bevelShadeColor = Color.black
        var bevelWidth: CGFloat = 1.5
        var bevelHighlightOpacity = 0.8
        var bevelMidOpacity = 0.15
        var bevelShadeOpacity = 0.35

        /// What the jewel casts on what is behind it.
        var dropShadow = Shadow(color: .black.opacity(0.5), radius: 4, y: 3)
    }

    /// The mark at the trailing edge of the navigation bar: a small cabochon carrying the
    /// octopus, which is the way to the settings and, held, to the diagnostics.
    struct Badge: Equatable, Sendable {
        var size: CGFloat = 30
        var markSize: CGFloat = 19
        /// The mark is white on the glass whatever the appearance, because the glass it sits on
        /// is the same colour in both.
        var markColor = Color.white
        var markShadow = Shadow(color: .black.opacity(0.3), radius: 1, y: 1)
    }

    /// The sheet the badge opens.
    struct Settings: Equatable, Sendable {
        /// Its controls address Topo, so they take Topo's colour.
        var tint = Theme.primary
    }
    /// The lozenge under the transcript: a floating pane of glass carrying two flanks and, set
    /// into the middle of it, the microphone in its well.
    ///
    /// The glass is what says the microphone is open, because the thumb that opened it covers
    /// the jewel: the pane takes the colour, the jewel goes pale, and the glow spills onto the
    /// transcript behind. So the open state is two values here — a tint and another `Jewel` —
    /// rather than a branch in the view.
    struct Composer: Equatable, Sendable {
        /// The share of the screen's width the glass takes, and how far off the bottom it floats.
        var widthFraction: CGFloat = 0.8
        var bottomPadding: CGFloat = 8
        /// The room inside the glass, and its corners.
        var horizontalInset: CGFloat = 16
        var verticalInset: CGFloat = 4
        var cornerRadius: CGFloat = 32
        /// Between a flank and the well.
        var spacing: CGFloat = 25
        /// What the pane is made of: the system's glass where there is any, a material below it.
        var surface: Surface = .glass
        /// The colour the pane takes while the microphone is open, and the alpha it takes it at.
        /// Clear otherwise: the same value at nothing, so the change is an animation and not a
        /// swap of one view for another.
        var tint = Theme.primary
        var tintOpacity = 0.55
        /// What the open glass spills onto the transcript behind it.
        var glow = Shadow(color: Theme.primary.opacity(0.7), radius: 28, y: 4)
        /// How long the pane takes to take the colour, and the flanks to go.
        var duration = 0.2

        /// How much of a pane the pane is: clear over the empty end of the transcript, glass
        /// where turns run under it. How far the content runs under the pane before it is a
        /// pane whole, and how long that takes.
        var presenceRise: CGFloat = 48
        var presenceDuration = 0.2

        var flank = Flank()
        var well = Well()
        var glyph = Glyph()

        /// The jewel while the microphone is open: the same slab read from its pale end, lit
        /// from behind, with less shade cut into it and a fainter band.
        var openJewel: Jewel = {
            var jewel = Jewel()
            jewel.bodyGlasses = [.milk, .pale, .mid]
            jewel.bodyShade = Shadow(color: .black.opacity(0.2), radius: 5, y: 3)
            jewel.driftOpacity = 0.9
            jewel.bandOpacity = 0.25
            return jewel
        }()

        /// The jewel while a press would be refused: the colour drained out of it and the whole
        /// slab faded. The diagnostics `speech` row is what says why.
        var dimmedSaturation = 0.0
        var dimmedOpacity = 0.5

        /// A control at one end of the glass. Etched rather than drawn on: the glyph a shade
        /// under its ink, with a light catch below its lower edges and a dark one above, as a
        /// cut into the surface would have.
        struct Flank: Equatable, Sendable {
            var font: Font = .title2
            /// Topo's colour on clear glass; white once the glass itself has taken that colour,
            /// so a live control does not read as a dimmed one.
            var ink = Theme.primary
            var openInk = Color.white
            var etchOpacity = 0.9
            var etchLight = Shadow(color: .white.opacity(0.45), radius: 0.5, y: 0.8)
            var etchShade = Shadow(color: .black.opacity(0.35), radius: 0.5, y: -0.6)
            /// While the thumb is on the microphone the flanks go, keeping their space so the
            /// glass never changes size.
            var heldOpacity = 0.0
        }

        /// The bore the jewel is set into: a dark floor, a deep shadow thrown from the lip, the
        /// hard line of the lip itself and the light caught under its far edge, inside a cut
        /// edge that runs dark at the top to bright at the foot.
        struct Well: Equatable, Sendable {
            var size: CGFloat = 72
            /// The jewel set into it.
            var jewelSize: CGFloat = 64
            var floor = Color.black.opacity(0.28)
            var bore = Shadow(color: .black.opacity(0.7), radius: 7, y: 5)
            var lip = Shadow(color: .black.opacity(0.4), radius: 1, y: 1)
            var catchLight = Shadow(color: .white.opacity(0.18), radius: 2, y: -2)
            var edgeColors: [Color] = [.black.opacity(0.55), .black.opacity(0.1), .white.opacity(0.55)]
            var edgeWidth: CGFloat = 1
        }

        /// The mark on the jewel. It sits over the glass rather than being cut into it, so it
        /// is white on the dark slab and Topo's colour on the pale one.
        struct Glyph: Equatable, Sendable {
            var size: CGFloat = 26
            var weight: Font.Weight = .medium
            var ink = Color.white
            var openInk = Theme.primary
            var shadow = Shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            /// Nothing under the thumb needs a shadow of its own.
            var openShadowOpacity = 0.0
        }
    }

    /// The person's next turn, written at the end of the transcript rather than in the glass.
    /// It is set in the transcript's own type (`transcript.bodyFont`) and drawn at the size the
    /// landed turn will be, because it is that turn before it is said: what is here is only what
    /// the row has of its own.
    ///
    /// It is not a turn yet, and its two enclosures say so. A turn a process puts into the
    /// transcript is `secondary`, and so is the person's own turn while it is still being
    /// written; a turn on its way is `signal`, which is the palette's measured liveness. The
    /// draft becomes a turn of the person's, in `bubble`'s primary, by landing in the log.
    struct Draft: Equatable, Sendable {
        /// What the words are drawn on while they are being written, and while the turn is on
        /// its way. Both are `bubble`'s enclosure with an accent of their own, so a look that
        /// changes the person's landed bubble leaves the draft alone and one that changes the
        /// draft leaves the bubble — and the row keeps its shape as the turn lands.
        var written: Enclosure
        var sending: Enclosure
        /// How wide the row is with nothing written in it, so the caret has somewhere to sit.
        var minimumWidth: CGFloat = 160
        /// Between the bubble and the control beside it.
        var spacing: CGFloat = 8
        /// The control that sends what is written, and the spinner that stands in its place
        /// while the turn is on its way: one slot, so the row does not move as one becomes the
        /// other.
        var slot: CGFloat = 36
        var sendFont: Font = .title2
        var sendInk = Theme.primary
        /// What the send control fades to with nothing to send, so an empty row's control says
        /// it is not to be pressed rather than being pressed and doing nothing.
        var sendRestingOpacity = 0.35

        init(_ screen: Screen = .current) {
            written = .draft(screen, accent: Theme.secondary)
            sending = .draft(screen, accent: Theme.signal)
        }
    }
}

private struct LookKey: EnvironmentKey {
    static var defaultValue: Look { Look() }
}

extension EnvironmentValues {
    /// The values every view draws with. Set it on a subtree to draw that subtree differently.
    var look: Look {
        get { self[LookKey.self] }
        set { self[LookKey.self] = newValue }
    }
}
