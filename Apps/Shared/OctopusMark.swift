import SwiftUI

/// The mark: a filled round head over eight curling arms, countable at icon
/// size. One mind, eight limbs.
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
    private static let head = CGRect(x: 29, y: 14, width: 42, height: 42)
    /// What the mark actually covers once the arms are stroked, measured
    /// from the same curves.
    private static let ink = CGRect(x: 4.5, y: 14, width: 91, height: 82)

    /// Each arm: where it starts, then its cubic segments as
    /// (control, control, end).
    private static let arms: [(CGPoint, [(CGPoint, CGPoint, CGPoint)])] = [
        (CGPoint(x: 31, y: 48), [(CGPoint(x: 28, y: 60), CGPoint(x: 22, y: 66), CGPoint(x: 12, y: 66)),
                                 (CGPoint(x: 6, y: 66), CGPoint(x: 6, y: 58), CGPoint(x: 12, y: 58))]),
        (CGPoint(x: 37, y: 50), [(CGPoint(x: 35, y: 62), CGPoint(x: 28, y: 70), CGPoint(x: 20, y: 76)),
                                 (CGPoint(x: 15, y: 80), CGPoint(x: 19, y: 86), CGPoint(x: 24, y: 83))]),
        (CGPoint(x: 43, y: 52), [(CGPoint(x: 42, y: 66), CGPoint(x: 36, y: 76), CGPoint(x: 30, y: 86)),
                                 (CGPoint(x: 27, y: 91), CGPoint(x: 33, y: 94), CGPoint(x: 34, y: 89))]),
        (CGPoint(x: 48, y: 52), [(CGPoint(x: 49, y: 68), CGPoint(x: 45, y: 80), CGPoint(x: 43, y: 93))]),
        (CGPoint(x: 69, y: 48), [(CGPoint(x: 72, y: 60), CGPoint(x: 78, y: 66), CGPoint(x: 88, y: 66)),
                                 (CGPoint(x: 94, y: 66), CGPoint(x: 94, y: 58), CGPoint(x: 88, y: 58))]),
        (CGPoint(x: 63, y: 50), [(CGPoint(x: 65, y: 62), CGPoint(x: 72, y: 70), CGPoint(x: 80, y: 76)),
                                 (CGPoint(x: 85, y: 80), CGPoint(x: 81, y: 86), CGPoint(x: 76, y: 83))]),
        (CGPoint(x: 57, y: 52), [(CGPoint(x: 58, y: 66), CGPoint(x: 64, y: 76), CGPoint(x: 70, y: 86)),
                                 (CGPoint(x: 73, y: 91), CGPoint(x: 67, y: 94), CGPoint(x: 66, y: 89))]),
        (CGPoint(x: 52, y: 52), [(CGPoint(x: 51, y: 68), CGPoint(x: 55, y: 80), CGPoint(x: 57, y: 93))]),
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
