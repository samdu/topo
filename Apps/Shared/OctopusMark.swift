import SwiftUI

/// The mark: a filled round head over eight curling arms, countable at icon
/// size. One mind, eight limbs, no two arms the same length.
///
/// The drawing is `Design/topo-mark.svg`, which is also what the app icons
/// are rendered from; the curves below are that file's, in the same 100×100
/// space. Change one and change the other — there is no way to link them,
/// since nothing on iOS draws an SVG and the icons are made at build time
/// on a Mac.
struct OctopusMark: View {
    var color: Color = Theme.teal

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            // The ink, not the box: the arms reach lower than the head is
            // tall, so centring the 100×100 square would sit the mark high.
            let scale = side / Self.ink.width
            let offset = CGSize(width: (geometry.size.width - Self.ink.width * scale) / 2 - Self.ink.minX * scale,
                                height: (geometry.size.height - Self.ink.height * scale) / 2 - Self.ink.minY * scale)
            ZStack(alignment: .topLeading) {
                Self.armsPath
                    .stroke(color, style: StrokeStyle(lineWidth: Self.strokeWidth, lineCap: .round, lineJoin: .round))
                Circle()
                    .fill(color)
                    .frame(width: Self.head.width, height: Self.head.height)
                    .offset(x: Self.head.minX, y: Self.head.minY)
            }
            .frame(width: 100, height: 100, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .offset(offset)
        }
        .accessibilityLabel("Topo")
    }

    private static let strokeWidth: CGFloat = 6
    private static let head = CGRect(x: 27.9, y: 14, width: 42.4, height: 42.4)
    /// What the mark actually covers once the arms are stroked, measured
    /// from the same curves.
    private static let ink = CGRect(x: 5, y: 14, width: 90, height: 82)

    /// Each arm: where it starts, then its cubic segments as
    /// (control, control, end).
    private static let arms: [(CGPoint, [(CGPoint, CGPoint, CGPoint)])] = [
        (CGPoint(x: 29.9, y: 48.3), [(CGPoint(x: 27.1, y: 59.5), CGPoint(x: 21.6, y: 65.1), CGPoint(x: 12.2, y: 65.1)),
                                     (CGPoint(x: 6.6, y: 65.1), CGPoint(x: 6.6, y: 57.6), CGPoint(x: 12.2, y: 57.6))]),
        (CGPoint(x: 36, y: 50.3), [(CGPoint(x: 34.2, y: 61.5), CGPoint(x: 27.6, y: 69), CGPoint(x: 20.2, y: 74.6)),
                                   (CGPoint(x: 15.5, y: 78.3), CGPoint(x: 19.2, y: 83.8), CGPoint(x: 23.9, y: 81))]),
        (CGPoint(x: 42.1, y: 52.4), [(CGPoint(x: 41.4, y: 60.9), CGPoint(x: 37.8, y: 67), CGPoint(x: 34.2, y: 73)),
                                     (CGPoint(x: 32.3, y: 76.1), CGPoint(x: 36, y: 78), CGPoint(x: 36.6, y: 74.9))]),
        (CGPoint(x: 47.1, y: 52.4), [(CGPoint(x: 48.1, y: 68.2), CGPoint(x: 44.2, y: 80.1), CGPoint(x: 42.2, y: 92.9))]),
        (CGPoint(x: 68.3, y: 48.3), [(CGPoint(x: 71.3, y: 60.4), CGPoint(x: 77.4, y: 66.5), CGPoint(x: 87.5, y: 66.5)),
                                     (CGPoint(x: 93.5, y: 66.5), CGPoint(x: 93.5, y: 58.4), CGPoint(x: 87.5, y: 58.4))]),
        (CGPoint(x: 62.2, y: 50.3), [(CGPoint(x: 63.8, y: 59.5), CGPoint(x: 69.1, y: 65.7), CGPoint(x: 75.3, y: 70.2)),
                                     (CGPoint(x: 79.1, y: 73.2), CGPoint(x: 76, y: 77.9), CGPoint(x: 72.2, y: 75.6))]),
        (CGPoint(x: 56.2, y: 52.4), [(CGPoint(x: 57, y: 64.1), CGPoint(x: 62, y: 72.3), CGPoint(x: 67, y: 80.7)),
                                     (CGPoint(x: 69.5, y: 84.8), CGPoint(x: 64.6, y: 87.4), CGPoint(x: 63.6, y: 83.2))]),
        (CGPoint(x: 51.1, y: 52.4), [(CGPoint(x: 50.4, y: 63.9), CGPoint(x: 53.3, y: 72.5), CGPoint(x: 54.8, y: 81.8))]),
    ]

    private static let armsPath = Path { path in
        for (start, curves) in arms {
            path.move(to: start)
            for (control1, control2, end) in curves {
                path.addCurve(to: end, control1: control1, control2: control2)
            }
        }
    }
}

#Preview {
    VStack(spacing: 24) {
        OctopusMark().frame(width: 120, height: 120)
        OctopusMark(color: .white).frame(width: 44, height: 44).padding(20).background(Theme.teal)
    }
    .padding()
}
