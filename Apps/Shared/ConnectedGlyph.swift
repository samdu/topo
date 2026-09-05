import SwiftUI

/// The connected indicator: a circle with eight radiating strokes, hub and
/// limbs. Not the app icon — that is the octopus — this is the glyph a
/// screen shows to say it is joined to something.
struct ConnectedGlyph: View {
    /// Dimmed when nothing is primary: the limbs are there, the head is not.
    var isConnected = true

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                ForEach(0..<8, id: \.self) { i in
                    Path { p in
                        let a = Double(i) / 8 * 2 * .pi
                        p.move(to: CGPoint(x: c.x + cos(a) * s * 0.26, y: c.y + sin(a) * s * 0.26))
                        p.addLine(to: CGPoint(x: c.x + cos(a) * s * 0.5, y: c.y + sin(a) * s * 0.5))
                    }
                    .stroke(Theme.teal.opacity(isConnected ? 1 : 0.35),
                            style: StrokeStyle(lineWidth: s * 0.07, lineCap: .round))
                }
                Circle()
                    .fill(Theme.teal.opacity(isConnected ? 1 : 0.35))
                    .frame(width: s * 0.34, height: s * 0.34)
                    .position(c)
            }
        }
        .accessibilityHidden(true)
    }
}
