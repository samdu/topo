import UIKit

/// What the screen shows when there are no turns to show: reading, empty,
/// or the reason the read did not work. It never stands in front of a
/// transcript — the table's background is where it lives.
final class StatusView: UIView {
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let spinner: UIActivityIndicatorView
    private let retryButton = UIButton(type: .system)
    private var onRetry: (() -> Void)?

    override init(frame: CGRect) {
        if #available(iOS 13.0, *) {
            spinner = UIActivityIndicatorView(style: .medium)
        } else {
            spinner = UIActivityIndicatorView(style: .gray)
        }
        super.init(frame: frame)

        titleLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Palette.text
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        messageLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = Palette.secondaryText
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        retryButton.setTitleColor(Palette.accent, for: .normal)
        retryButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .callout)
        retryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        retryButton.setTitle("Try again", for: .normal)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [spinner, titleLabel, messageLabel, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: layoutMarginsGuide.topAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showReading() {
        spinner.startAnimating()
        spinner.isHidden = false
        titleLabel.text = nil
        messageLabel.text = "Reading the transcript…"
        retryButton.isHidden = true
    }

    func show(title: String, message: String, retry: (() -> Void)? = nil) {
        spinner.stopAnimating()
        spinner.isHidden = true
        titleLabel.text = title
        messageLabel.text = message
        onRetry = retry
        retryButton.isHidden = retry == nil
    }

    @objc private func retryTapped() { onRetry?() }
}
