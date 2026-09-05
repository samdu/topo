import UIKit

/// One turn: who said it, when, and what. Self-sizing, so a long turn is as
/// tall as it needs to be at every text size and on every screen.
final class TurnCell: UITableViewCell {
    static let reuseIdentifier = "TurnCell"
    /// Points. Roughly the width at which a line of body text stops being
    /// comfortable to read, which is what `readableContentGuide` aims at.
    static let maximumLineWidth: CGFloat = 672

    private let whoLabel = UILabel()
    private let whenLabel = UILabel()
    private let bodyLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        selectionStyle = .none
        backgroundColor = .clear

        whoLabel.font = TurnCell.scaled(.caption1, size: 12, weight: .semibold)
        whoLabel.adjustsFontForContentSizeCategory = true
        whoLabel.setContentHuggingPriority(.required, for: .horizontal)

        whenLabel.font = TurnCell.scaled(.caption1, size: 12, weight: .regular)
        whenLabel.adjustsFontForContentSizeCategory = true
        whenLabel.textColor = Palette.secondaryText
        whenLabel.textAlignment = .right
        whenLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        bodyLabel.font = UIFont.preferredFont(forTextStyle: .body)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.textColor = Palette.text
        bodyLabel.numberOfLines = 0

        let heading = UIStackView(arrangedSubviews: [whoLabel, whenLabel])
        heading.axis = .horizontal
        heading.spacing = 8

        let stack = UIStackView(arrangedSubviews: [heading, bodyLabel])
        stack.axis = .vertical
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        // A turn is centred, within the margins, and never wider than a
        // line anyone wants to read back: on an iPad or a phone held
        // sideways the text stops well short of the edges. A constant
        // rather than `readableContentGuide`, which falls back to the plain
        // margins when the trait collection has no content size category
        // and so cannot be relied on to cap anything.
        let margins = contentView.layoutMarginsGuide
        let width = stack.widthAnchor.constraint(lessThanOrEqualToConstant: TurnCell.maximumLineWidth)
        width.priority = .required
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: margins.trailingAnchor),
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            width,
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ turn: Turn, at when: String) {
        whoLabel.text = turn.role == .assistant ? "TOPO" : "YOU"
        whoLabel.textColor = turn.role == .assistant ? Palette.accent : Palette.secondaryText
        whenLabel.text = when
        bodyLabel.text = turn.text
        accessibilityLabel = "\(turn.role == .assistant ? "Topo" : "You"), \(when). \(turn.text)"
        isAccessibilityElement = true
    }

    /// A system font at `size`, scaled for the user's text size. Scaling
    /// `preferredFont`'s point size instead would scale it twice.
    private static func scaled(_ style: UIFont.TextStyle, size: CGFloat, weight: UIFont.Weight) -> UIFont {
        return UIFontMetrics(forTextStyle: style).scaledFont(for: UIFont.systemFont(ofSize: size, weight: weight))
    }
}
