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

    init(_ screen: Screen = .current) {
        transcript = Transcript(screen)
        bubble = .bubble(screen)
        plain = .plain
        jewel = Jewel()
        badge = Badge()
        settings = Settings()
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

        /// The person's side. `secondary` is the person's colour in the palette.
        static func bubble(_ screen: Screen) -> Enclosure {
            let padding: (CGFloat, CGFloat)
            switch screen {
            case .watch: padding = (8, 6)
            case .tv: padding = (20, 14)
            case .phone: padding = (14, 10)
            }
            return Enclosure(accent: Theme.secondary, fillOpacity: 0.12, strokeWidth: 1.5,
                             cornerRadius: 18, horizontalPadding: padding.0,
                             verticalPadding: padding.1, surface: .flat)
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

        /// The body: a radial gradient centred low and right, where the glass is thinnest.
        var bodyCenter = UnitPoint(x: 0.62, y: 0.72)
        var bodyEndRadius: CGFloat = 46
        /// Cut into the body from the top, and the light caught under its lower edge.
        var bodyShade = Shadow(color: .black.opacity(0.45), radius: 5, y: 3)
        var bodyCatch = Shadow(color: .white.opacity(0.3), radius: 2, y: -2)

        /// The milky drift, an off-centre swirl of thinner glass.
        var driftSize = CGSize(width: 44, height: 30)
        var driftEndRadius: CGFloat = 22
        var driftOpacity = 0.55
        var driftHaloOpacity = 0.25
        var driftAngle = Angle.degrees(-28)
        var driftOffset = CGSize(width: 6, height: 8)
        var driftBlur: CGFloat = 2

        /// The dark band across the diagonal.
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
