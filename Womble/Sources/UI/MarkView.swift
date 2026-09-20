import UIKit

/// The Topo mark, drawn from `Design/topo-mark.svg` in the bundle.
///
/// Every client reads that file — this one, `Apps/Shared/OctopusMark.swift`
/// and `Design/make-icons.swift` — so none of them holds a copy of the curves
/// and the mark cannot go stale. The file is a move and cubic segments and
/// nothing else, which is why so little of SVG is read here.
final class MarkView: UIView {
    /// The drawing's own space; every coordinate in the file is in it.
    private static let side: CGFloat = 100

    private let outline: UIBezierPath?

    init(svg: String? = MarkView.bundledSVG()) {
        outline = MarkView.outline(in: svg ?? "")
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        accessibilityLabel = "Topo"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// True when the drawing was there and read.
    var isDrawn: Bool { return outline != nil }

    override func draw(_ rect: CGRect) {
        let scale = min(bounds.width, bounds.height) / MarkView.side
        guard scale > 0, let outline = outline else { return }
        var transform = CGAffineTransform(translationX: (bounds.width - MarkView.side * scale) / 2,
                                          y: (bounds.height - MarkView.side * scale) / 2)
            .scaledBy(x: scale, y: scale)
        guard let scaled = outline.cgPath.copy(using: &transform) else { return }
        Palette.accent.setFill()
        UIBezierPath(cgPath: scaled).fill()
    }

    static func bundledSVG(in bundle: Bundle = Bundle.main) -> String? {
        guard let url = bundle.url(forResource: "topo-mark", withExtension: "svg") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The one `d` attribute: a move, then cubic segments, then the close that makes the
    /// outline a silhouette.
    static func outline(in svg: String) -> UIBezierPath? {
        guard let d = matches("<path d=\"([^\"]+)\"", in: svg).first else { return nil }
        let numbers = d.split(whereSeparator: { " ,MCZ".contains($0) }).compactMap { Double($0) }
        guard numbers.count >= 8, (numbers.count - 2) % 6 == 0 else { return nil }
        let path = UIBezierPath()
        path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
        for start in stride(from: 2, to: numbers.count, by: 6) {
            path.addCurve(to: CGPoint(x: numbers[start + 4], y: numbers[start + 5]),
                          controlPoint1: CGPoint(x: numbers[start], y: numbers[start + 1]),
                          controlPoint2: CGPoint(x: numbers[start + 2], y: numbers[start + 3]))
        }
        path.close()
        return path
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { range in String(text[range]) }
        }
    }
}
