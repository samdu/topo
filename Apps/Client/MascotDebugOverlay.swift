#if DEBUG && os(iOS)
import SwiftUI

/// Topo's field drawn over the chat, in a debug build with the settings sheet's `Show his field`
/// on: why he stands where he stands. It draws the roam's last decision (`MascotRoost.Decision`,
/// carried whole on his report) — the words as he read them, the room his box may stand in,
/// every place weighed, the ones that clear the words filled as one shape, and the one chosen —
/// and his box where it is now with, fainter, his reach round it. Nothing is worked out here:
/// the decision is the roam's own value, and the box is the report's frame.
///
/// It is laid in `MascotLayer`'s own stack, so it takes no touch and is nothing to accessibility,
/// as he is not, and its colours and widths are `look.mascot.debug`.
struct MascotFieldOverlay: View {
    /// The defaults key the settings sheet's switch writes; off when absent. A launch sets it for
    /// one run with the argument `-topo.debug.mascotField YES`.
    static let key = "topo.debug.mascotField"

    let report: MascotRoam.Report?
    let reach: MascotSprite.Reach
    @Environment(\.look) private var look

    var body: some View {
        ZStack {
            if let decision = report?.decision?.whole {
                MascotDecisionDrawing(decision: decision, debug: look.mascot.debug)
                    .equatable()
            }
            if let frame = report?.frame, frame.count == 4 {
                MascotBoxDrawing(box: CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]), reach: reach,
                                 debug: look.mascot.debug)
            }
        }
    }
}

/// One decision, drawn: a view of its own so it is drawn again only when the decision changes,
/// not on every frame of a glide.
private struct MascotDecisionDrawing: View, Equatable {
    let decision: MascotRoost.Decision
    let debug: Look.Mascot.Debug

    var body: some View {
        Canvas { context, _ in
            var words = Path()
            for word in decision.field.words { words.addRect(word) }
            context.fill(words, with: .color(debug.words))

            var clearing = Path()
            var every = Path()
            for candidate in decision.candidates {
                every.addRect(candidate.frame)
                if candidate.clears { clearing.addRect(candidate.frame) }
            }
            // One path each, filled and stroked once, so where places overlap is no darker.
            context.fill(clearing, with: .color(debug.clearing))
            context.stroke(every, with: .color(debug.candidate), lineWidth: debug.hairline)

            context.stroke(Path(decision.room), with: .color(debug.room), lineWidth: debug.lineWidth)
            if let choice = decision.choice {
                context.stroke(Path(choice.frame), with: .color(debug.chosen), lineWidth: debug.lineWidth)
            }
        }
    }
}

/// His box where he is now, and his reach round it.
private struct MascotBoxDrawing: View {
    let box: CGRect
    let reach: MascotSprite.Reach
    let debug: Look.Mascot.Debug

    var body: some View {
        Canvas { context, _ in
            context.stroke(Path(reach.around(box)), with: .color(debug.reach), lineWidth: debug.hairline)
            context.stroke(Path(box), with: .color(debug.box), lineWidth: debug.lineWidth)
        }
    }
}
#endif
