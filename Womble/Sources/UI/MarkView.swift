import UIKit

/// The Topo mark, drawn from `Design/topo-mark.svg` in the bundle.
///
/// The client holds the same curves as Swift (`Apps/Shared/OctopusMark.swift`)
/// and has to be changed alongside the drawing; this reads the drawing itself,
/// so Womble is one place the mark cannot go stale. The file uses a move and
/// cubic segments and nothing else, which is why so little of SVG is read
/// here — `Design/make-icons.swift` reads it the same way.
final class MarkView: UIView {
    /// The drawing's own space; every coordinate in the file is in it.
    private static let side: CGFloat = 100
    private static let strokeWidth: CGFloat = 6

    private let arms: [UIBezierPath]
    private let head: UIBezierPath?

    init(svg: String? = MarkView.bundledSVG()) {
        let drawing = svg ?? ""
        arms = MarkView.arms(in: drawing)
        head = MarkView.head(in: drawing)
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        accessibilityLabel = "Topo"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// True when the drawing was there and read: eight arms and a head.
    var isDrawn: Bool { return arms.count == 8 && head != nil }

    override func draw(_ rect: CGRect) {
        let scale = min(bounds.width, bounds.height) / MarkView.side
        guard scale > 0 else { return }
        let transform = CGAffineTransform(translationX: (bounds.width - MarkView.side * scale) / 2,
                                          y: (bounds.height - MarkView.side * scale) / 2)
            .scaledBy(x: scale, y: scale)
        Palette.accent.setStroke()
        Palette.accent.setFill()
        for arm in arms {
            let path = UIBezierPath(cgPath: arm.cgPath.copy(using: [transform]) ?? arm.cgPath)
            path.lineWidth = MarkView.strokeWidth * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
        if let head = head, let scaled = head.cgPath.copy(using: [transform]) {
            UIBezierPath(cgPath: scaled).fill()
        }
    }

    static func bundledSVG(in bundle: Bundle = Bundle.main) -> String? {
        guard let url = bundle.url(forResource: "topo-mark", withExtension: "svg") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// One `d` attribute: a move, then cubic segments.
    static func arms(in svg: String) -> [UIBezierPath] {
        return matches("<path d=\"([^\"]+)\"", in: svg).compactMap { d in
            let numbers = d.split(whereSeparator: { " ,MC".contains($0) }).compactMap { Double($0) }
            guard numbers.count >= 8, (numbers.count - 2) % 6 == 0 else { return nil }
            let path = UIBezierPath()
            path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
            for start in stride(from: 2, to: numbers.count, by: 6) {
                path.addCurve(to: CGPoint(x: numbers[start + 4], y: numbers[start + 5]),
                              controlPoint1: CGPoint(x: numbers[start], y: numbers[start + 1]),
                              controlPoint2: CGPoint(x: numbers[start + 2], y: numbers[start + 3]))
            }
            return path
        }
    }

    static func head(in svg: String) -> UIBezierPath? {
        guard let cx = number("cx=\"([0-9.]+)\"", in: svg),
              let cy = number("cy=\"([0-9.]+)\"", in: svg),
              let r = number(" r=\"([0-9.]+)\"", in: svg) else { return nil }
        return UIBezierPath(ovalIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
    }

    private static func number(_ pattern: String, in svg: String) -> CGFloat? {
        guard let text = matches(pattern, in: svg).first, let value = Double(text) else { return nil }
        return CGFloat(value)
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { range in String(text[range]) }
        }
    }
}
