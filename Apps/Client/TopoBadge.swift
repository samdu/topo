#if os(iOS)
import SwiftUI

/// The mark in the navigation bar, at the trailing edge where a back button is not: a small
/// cabochon carrying the octopus. A tap opens the settings; a hold, the diagnostics.
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
            StainedGlass(glass: look.jewel)
                .frame(width: look.badge.size, height: look.badge.size)
                .overlay {
                    OctopusMark(color: look.badge.markColor)
                        .frame(width: look.badge.markSize, height: look.badge.markSize)
                        .shadow(look.badge.markShadow)
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

/// A cabochon cut from a slab of poured glass: a domed body with a milky drift of paler glass
/// across it and a darker band on the diagonal, inside a jeweller's true-circle edge. Every value
/// it draws with is the `Look.Jewel` it is handed, so a jewel of another colour is a value and
/// never a branch in here.
struct StainedGlass: View {
    let glass: Look.Jewel

    var body: some View {
        Circle()
            .fill(
                // The body of the glass: paler where it is thinner, at the lower right.
                RadialGradient(colors: glass.bodyGlasses.map(glass.colour),
                               center: glass.bodyCenter, startRadius: 0,
                               endRadius: glass.bodyEndRadius)
                    .shadow(.inner(glass.bodyShade))
                    .shadow(.inner(glass.bodyCatch))
            )
            // The milky drift, an off-centre swirl of thinner glass.
            .overlay {
                Ellipse()
                    .fill(RadialGradient(colors: [glass.colour(glass.driftGlass).opacity(glass.driftOpacity),
                                                  glass.colour(glass.driftHaloGlass).opacity(glass.driftHaloOpacity),
                                                  .clear],
                                         center: .center, startRadius: 0,
                                         endRadius: glass.driftEndRadius))
                    .frame(width: glass.driftSize.width, height: glass.driftSize.height)
                    .rotationEffect(glass.driftAngle)
                    .offset(x: glass.driftOffset.width, y: glass.driftOffset.height)
                    .blur(radius: glass.driftBlur)
            }
            // The dark band across the diagonal.
            .overlay {
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, glass.colour(glass.bandGlass).opacity(glass.bandOpacity), .clear],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: glass.bandSize.width, height: glass.bandSize.height)
                    .rotationEffect(glass.bandAngle)
                    .offset(x: glass.bandOffset.width, y: glass.bandOffset.height)
                    .blur(radius: glass.bandBlur)
            }
            // The sheen off the top of the slab, and the shade off its foot.
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
