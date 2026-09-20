#if os(iOS)
import SwiftUI
import UIKit

/// The mark in the navigation bar, at the trailing edge where a back button is not: a cabochon
/// filling the control, with the octopus cut into it. A tap opens the settings; a hold, the
/// diagnostics.
///
/// It says what Topo is and not how it is. The badge has one state because nothing on this phone
/// measures standing: `RoleSelector` holds the role decided at launch and `PrimaryReader` reads a
/// lease's freshness, and neither is a measurement of whether the mind can be reached. A colour
/// for that waits on a reader that measures it; the glass is a parameter, so what arrives then is
/// another `Look.Jewel` and not another view.
struct TopoBadge: View {
    var openSettings: () -> Void = {}
    var openDiagnostics: () -> Void = {}
    @Environment(\.look) private var look
    /// True from the moment a press becomes a hold until the release that ends it, so the
    /// release opens nothing.
    @State private var heldOpen = false

    var body: some View {
        Button {
            // A press that became a hold has already opened the diagnostics; its release is not
            // also a tap. A button's action runs on every release whatever else recognised, so
            // the hold is what the action asks about rather than something beside it.
            if heldOpen { heldOpen = false } else { openSettings() }
        } label: {
            StainedGlass(glass: look.badge.jewel, diameter: look.badge.size)
                .overlay {
                    // The mark is a mask and nothing else here: what is drawn is the stone
                    // under it and the two walls of the cut, from `Look.press`.
                    OctopusMark()
                        .frame(width: look.badge.markSize, height: look.badge.markSize)
                        .pressed(look.press, into: look.badge.jewel, diameter: look.badge.size)
                }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture()
                // Every press starts as a tap, including one after a hold whose release the
                // button never saw — dragged off the badge, or interrupted. Without this the
                // mark left by that hold would swallow the next tap.
                .onChanged { _ in heldOpen = false }
                .onEnded { _ in
                    heldOpen = true
                    openDiagnostics()
                }
        )
        .accessibilityLabel("Topo")
        .accessibilityHint("Settings; hold for diagnostics")
    }
}

/// A cabochon cut from a photograph of a slice of agate: the stone itself, under whatever cast
/// the jewel names, inside a sheen, a jeweller's true-circle edge and a drop shadow. Every value
/// it draws with is the `Look.Jewel` it is handed, so a jewel of another colour is a value and
/// never a branch in here.
///
/// The stone is drawn as an `ImagePaint` filling the circle rather than as an image clipped to
/// one, because the light cut into the body (`bodyShade`, `bodyCatch`) is an inner shadow on the
/// fill, and a fill is the only thing that takes one. A paint is scaled to the shape it fills and
/// not to the space it is offered, so the diameter is handed over rather than read off a
/// `GeometryReader`: a reader resolves on a second layout pass, and a view that arrives on the
/// second pass is one the animation around it fades in over the composer's own duration.
struct StainedGlass: View {
    let glass: Look.Jewel
    /// How wide the stone is read at, which is what one copy of the photograph is scaled to.
    let diameter: CGFloat

    var body: some View {
        Circle()
            .fill(
                Stone.paint(glass.stone, across: diameter)
                    .shadow(.inner(glass.bodyShade))
                    .shadow(.inner(glass.bodyCatch))
            )
            // The cast: the stone under another colour, at the alpha and in the manner the
            // jewel names, so a stone of another colour is two values and not a second
            // photograph.
            .overlay {
                Circle()
                    .fill(glass.cast.opacity(glass.castOpacity))
                    .blendMode(glass.castBlend)
            }
            .compositingGroup()
            // The sheen off the top of the stone, and the shade off its foot.
            .overlay {
                Circle().fill(
                    LinearGradient(colors: [glass.sheenColor.opacity(glass.sheenOpacity), .clear, .clear,
                                            glass.sheenShadeColor.opacity(glass.sheenShadeOpacity)],
                                   startPoint: glass.sheenStart, endPoint: glass.sheenEnd))
            }
            // The cut: a jeweller's edge, a true circle with a bright bevel.
            .overlay {
                Circle().strokeBorder(
                    LinearGradient(colors: [glass.bevelColor.opacity(glass.bevelHighlightOpacity),
                                            glass.bevelColor.opacity(glass.bevelMidOpacity),
                                            glass.bevelShadeColor.opacity(glass.bevelShadeOpacity)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: glass.bevelWidth)
            }
            .clipShape(Circle())
            .shadow(glass.dropShadow)
            .frame(width: diameter, height: diameter)
    }
}

/// The stone a cabochon and the floor of a cut are both drawn from: one photograph, read at
/// whatever size it is being drawn across.
enum Stone {
    /// The disc as a fill, scaled so one copy of it covers `side` points. It is a paint rather
    /// than an image so that a shape filled with it can take an inner shadow, and so that the
    /// floor of a pressed mark is the same stone in the same place as the body under it.
    ///
    /// The asset's own size is asked of it rather than written down: the stone is a photograph
    /// and the look names it, so a document naming another one is another size.
    static func paint(_ name: String, across side: CGFloat) -> ImagePaint {
        let natural = UIImage(named: name)?.size.width ?? side
        return ImagePaint(image: Image(name), scale: natural > 0 ? side / natural : 1)
    }
}

/// A mark pressed into the stone: the mark's own shape filled with the stone a shade under the
/// stone around it, the wall at the top of every stroke dark where it faces away from the light,
/// and the wall at its foot catching it.
///
/// What it is handed is a view of the mark, and only that view's alpha is read — the octopus is
/// a drawing and the microphone is a symbol, and neither's colour is drawn. `diameter` is the
/// jewel the mark is cut into: it is what the wall's width is a share of, and what the floor's
/// stone is aligned to, so the floor is the part of the stone that was already there.
struct Pressed: ViewModifier {
    let press: Look.Press
    let glass: Look.Jewel
    let diameter: CGFloat
    /// What the open state casts over the floor of the cut. Nothing at rest.
    var cast: Color = .clear

    private var wall: CGFloat { press.wall * diameter }

    func body(content: Content) -> some View {
        // The mark holds the space and draws nothing: every layer over it is drawn through it.
        // It is faded out rather than hidden, because `hidden()` takes a view out of the
        // accessibility tree as well as out of the picture, and the microphone is the element
        // both UI suites find — by its label, among the app's images.
        content
            .opacity(0)
            .overlay { floor(content) }
            .overlay { side(press.shade, by: wall, content) }
            .overlay { side(press.catchLight, by: -wall, content) }
    }

    /// The floor of the cut: the jewel's own stone, aligned to the jewel because it is drawn at
    /// the jewel's diameter centred on the mark, under the shade that sets it below the surface
    /// and whatever the open state casts on it.
    private func floor(_ content: Content) -> some View {
        Circle()
            .fill(Stone.paint(glass.stone, across: diameter))
            .overlay { glass.cast.opacity(glass.castOpacity).blendMode(glass.castBlend) }
            .overlay { press.shade.opacity(press.floor) }
            .overlay { cast }
            .compositingGroup()
            .frame(width: diameter, height: diameter)
            .mask { content }
    }

    /// One wall of the cut: the mark, less the mark moved by the wall's width, which is the band
    /// along one side of every stroke. Moved down, that is the side facing away from the light;
    /// moved up, the side that catches it.
    private func side(_ colour: Color, by dy: CGFloat, _ content: Content) -> some View {
        colour.mask {
            content
                .overlay { content.offset(y: dy).blendMode(.destinationOut) }
                .compositingGroup()
                .blur(radius: wall * press.soften)
        }
    }
}

extension View {
    /// The mark cut into the stone, at the one treatment both marks are cut at.
    func pressed(_ press: Look.Press, into glass: Look.Jewel, diameter: CGFloat,
                 cast: Color = .clear) -> some View {
        modifier(Pressed(press: press, glass: glass, diameter: diameter, cast: cast))
    }
}

extension View {
    /// A shadow cast from a `Look.Shadow`, so a view names the field and never the four numbers.
    func shadow(_ shadow: Look.Shadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }
}

extension ShadowStyle {
    /// The same values cut into a fill rather than cast from it.
    static func inner(_ shadow: Look.Shadow) -> ShadowStyle {
        .inner(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }
}

#if DEBUG
#Preview("Badge") {
    NavigationStack {
        TranscriptView(turns: PreviewTurns.long)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { TopoBadge() } }
    }
}
#endif
#endif
