import UIKit

/// Who to thank: the mark, the version, where the name comes from, and what
/// `THIRD-PARTY` says.
///
/// The list is read from the file in the bundle rather than written here, so
/// a licence added to the file is on this screen in the next build. A scroll
/// of labels rather than a table: it is a page to read, and every line of it
/// comes from the same place.
final class AboutViewController: UIViewController {
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let acknowledgements: Acknowledgements?

    init(acknowledgements: Acknowledgements? = Acknowledgements.bundled()) {
        self.acknowledgements = acknowledgements
        super.init(nibName: nil, bundle: nil)
        title = "About"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 10
        view.addSubview(scrollView)
        scrollView.addSubview(stack)

        let guide: UILayoutGuide
        if #available(iOS 11.0, *) { guide = view.safeAreaLayoutGuide } else { guide = view.layoutMarginsGuide }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40),
        ])

        let mark = MarkView()
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.heightAnchor.constraint(equalToConstant: 88).isActive = true
        stack.addArrangedSubview(mark)

        add(text: "Topo", style: .title2, color: Palette.text, centred: true)
        add(text: version, style: .footnote, color: Palette.secondaryText, centred: true)
        add(text: "A viewer for the devices the main app is too new for. Open source under the GPL, and not for profit.",
            style: .footnote, color: Palette.secondaryText, centred: true)

        add(text: "The name", style: .headline, color: Palette.text)
        add(text: "Topo is Aquaman's octopus sidekick, first seen in Adventure Comics #229 (1956), written by Jack Miller and drawn by Ramona Fradon. The product is the octopus: the mind is the head and every device is an arm.",
            style: .footnote, color: Palette.secondaryText)

        add(text: "Acknowledgements", style: .headline, color: Palette.text)
        guard let acknowledgements = acknowledgements else {
            add(text: "THIRD-PARTY is missing from this build.", style: .footnote, color: .red)
            return
        }
        for paragraph in acknowledgements.note {
            add(text: paragraph, style: .footnote, color: Palette.secondaryText)
        }
        for entry in acknowledgements.entries {
            add(text: entry.name, style: .subheadline, color: Palette.text)
            for field in entry.fields {
                add(text: field.key, style: .caption2, color: Palette.secondaryText)
                add(text: field.value, style: .footnote, color: Palette.text)
            }
        }
    }

    /// What the stack is made of, so every line is laid out the same way.
    @discardableResult
    private func add(text: String, style: UIFont.TextStyle, color: UIColor, centred: Bool = false) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        label.textAlignment = centred ? .center : .natural
        stack.addArrangedSubview(label)
        return label
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(marketing) (\(build))"
    }

    /// What is on the screen, in order: the tests read this rather than the
    /// view hierarchy's shape.
    var lines: [String] {
        return stack.arrangedSubviews.compactMap { ($0 as? UILabel)?.text }
    }
}
