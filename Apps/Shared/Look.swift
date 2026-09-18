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
    var bubble: Bubble

    init(_ screen: Screen = .current) {
        transcript = Transcript(screen)
        bubble = Bubble(screen)
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

    /// The person's own turn. Topo's turns are drawn as plain text with none of this: one side of
    /// the transcript is enclosed and the other is not, which is what says who said what now that
    /// no caption does.
    struct Bubble: Equatable, Sendable {
        /// The outline, and the tint under it. `secondary` is the person's side of the palette.
        var accent: Color = Theme.secondary
        /// The tint's alpha. The fill is a wash under the outline rather than a block of colour.
        var fillOpacity: Double = 0.12
        var strokeWidth: CGFloat = 1.5
        var cornerRadius: CGFloat = 18
        var horizontalPadding: CGFloat
        var verticalPadding: CGFloat
        /// What sits under the tint.
        var surface: Surface = .flat

        init(_ screen: Screen = .current) {
            switch screen {
            case .watch:
                horizontalPadding = 8
                verticalPadding = 6
            case .tv:
                horizontalPadding = 20
                verticalPadding = 14
            case .phone:
                horizontalPadding = 14
                verticalPadding = 10
            }
        }
    }

    /// What a surface is made of. `flat` is the tint alone over whatever is behind it; the other
    /// two put one of the system's backdrops under it, `material` the thicker and `glass` the
    /// thinnest.
    enum Surface: String, Equatable, Sendable, CaseIterable {
        case glass, material, flat
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
