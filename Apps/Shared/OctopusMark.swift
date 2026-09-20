import SwiftUI

/// The mark: a filled silhouette, one round head over eight curling arms, countable at icon
/// size. One mind, eight limbs, no two arms the same length.
///
/// The drawing is `Design/topo-mark.svg`, bundled beside the app and read rather than copied
/// into Swift. The icon renderer and Womble read the same file, so there is one set of curves
/// and nothing to keep in step: an outline of this many segments held twice would go stale the
/// first time either copy was touched.
struct OctopusMark: View {
    var color: Color = Theme.teal

    var body: some View {
        MarkShape()
            .fill(color)
            .accessibilityLabel("Topo")
    }
}

/// The mark's outline, scaled to fill whatever it is given.
///
/// What is fitted is the ink and not the drawing's 100×100 box: the arms reach lower than the
/// head is tall, so fitting the square would sit the mark high and leave a margin nothing draws
/// in.
struct MarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let ink = Mark.ink
        guard ink.width > 0, ink.height > 0 else { return Path() }
        let scale = min(rect.width / ink.width, rect.height / ink.height)
        let size = CGSize(width: ink.width * scale, height: ink.height * scale)
        return Mark.path.applying(
            CGAffineTransform(translationX: rect.midX - size.width / 2 - ink.minX * scale,
                              y: rect.midY - size.height / 2 - ink.minY * scale)
                .scaledBy(x: scale, y: scale))
    }
}

/// The drawing, read once out of the bundle.
///
/// The file is a move and cubic segments and nothing else, which is why so little of SVG is
/// read here — Womble's `MarkView` and `Design/make-icons.swift` read it the same way.
enum Mark {
    static let path = parse(bundled())
    /// What the mark actually covers, which is the outline's own bounds.
    static let ink = path.boundingRect

    /// One `d` attribute: a move, then cubics, then the close that makes it a silhouette.
    static func parse(_ svg: String) -> Path {
        var path = Path()
        for d in matches("<path d=\"([^\"]+)\"", in: svg) {
            let numbers = d.split(whereSeparator: { " ,MCZ".contains($0) }).compactMap { Double($0) }
            guard numbers.count >= 8, (numbers.count - 2) % 6 == 0 else { continue }
            path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
            for start in stride(from: 2, to: numbers.count, by: 6) {
                path.addCurve(to: CGPoint(x: numbers[start + 4], y: numbers[start + 5]),
                              control1: CGPoint(x: numbers[start], y: numbers[start + 1]),
                              control2: CGPoint(x: numbers[start + 2], y: numbers[start + 3]))
            }
            path.closeSubpath()
        }
        return path
    }

    /// The drawing as it sits in the bundle. A build that did not carry it draws no mark at all,
    /// which is a resource missing from the target rather than anything a run can recover from.
    private static func bundled(in bundle: Bundle = .main) -> String {
        guard let url = bundle.url(forResource: "topo-mark", withExtension: "svg"),
              let svg = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("topo-mark.svg is not in this bundle: add Design/topo-mark.svg to the target")
        }
        return svg
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: whole).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
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
