import SwiftUI

/// The mark: a filled round head over eight curling arms, countable at icon size.
struct OctopusMark: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.42)
            ZStack {
                ForEach(0..<8, id: \.self) { i in
                    Path { p in
                        let a = Double(i) / 8 * 2 * .pi + .pi / 8
                        let start = CGPoint(x: c.x + cos(a) * s * 0.28, y: c.y + sin(a) * s * 0.28)
                        let end = CGPoint(x: c.x + cos(a + 0.6) * s * 0.5, y: c.y + sin(a + 0.6) * s * 0.5)
                        let ctrl = CGPoint(x: c.x + cos(a - 0.2) * s * 0.45, y: c.y + sin(a - 0.2) * s * 0.45)
                        p.move(to: start)
                        p.addQuadCurve(to: end, control: ctrl)
                    }
                    .stroke(Theme.teal, style: StrokeStyle(lineWidth: s * 0.06, lineCap: .round))
                }
                Circle().fill(Theme.teal).frame(width: s * 0.56, height: s * 0.56).position(c)
            }
        }
    }
}
