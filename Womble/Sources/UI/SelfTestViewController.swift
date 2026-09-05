import UIKit

/// The screen behind five taps on the title: what the app can and cannot do
/// with this Apple ID, on this device, against the real containers.
///
/// It exists because the failures that matter are invisible from a
/// simulator — an entitlement that was never granted, a schema that was
/// never promoted, a zone that is not there — and they all look the same
/// from the transcript, which says the log could not be read. This turns
/// that into the step that failed and what CloudKit said about it.
final class SelfTestViewController: UIViewController {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let runButton = UIButton(type: .system)
    private let footer = UILabel()
    private let makeSteps: () -> [SelfTestStep]
    private var test: SelfTest
    private var running = false

    /// The steps are made afresh for every run, not once for the screen: a
    /// run writes records under a device ID and into a zone of its own, and
    /// running again has to be a new one of each. Reusing them would mean
    /// the second run writing a record the first one already wrote, which
    /// is refused — the self-test would fail at itself.
    init(steps: @escaping () -> [SelfTestStep] = { CloudKitSelfTest.steps() }) {
        self.makeSteps = steps
        self.test = SelfTest(steps: steps())
        super.init(nibName: nil, bundle: nil)
        title = "Self-test"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorColor = Palette.separator
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.register(StepCell.self, forCellReuseIdentifier: StepCell.reuseIdentifier)
        tableView.translatesAutoresizingMaskIntoConstraints = false

        runButton.setTitle("Run", for: .normal)
        runButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        runButton.tintColor = Palette.accent
        runButton.addTarget(self, action: #selector(run), for: .touchUpInside)
        runButton.translatesAutoresizingMaskIntoConstraints = false

        footer.text = "Writes into a zone of its own, under a device ID nothing else uses, and deletes it afterwards. The transcript and the board are not touched."
        footer.font = UIFont.preferredFont(forTextStyle: .caption1)
        footer.adjustsFontForContentSizeCategory = true
        footer.textColor = Palette.secondaryText
        footer.numberOfLines = 0
        footer.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(tableView)
        view.addSubview(footer)
        view.addSubview(runButton)

        let guide: UILayoutGuide
        if #available(iOS 11.0, *) { guide = view.safeAreaLayoutGuide } else { guide = view.layoutMarginsGuide }
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.topAnchor.constraint(equalTo: tableView.bottomAnchor, constant: 12),
            footer.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            runButton.topAnchor.constraint(equalTo: footer.bottomAnchor, constant: 8),
            runButton.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            runButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Somebody who found this screen wants the answer, not another tap.
        if !running, test.outcomes.allSatisfy({ if case .waiting = $0.state { return true } else { return false } }) {
            run()
        }
    }

    @objc private func run() {
        guard !running else { return }
        running = true
        runButton.isEnabled = false
        runButton.setTitle("Running…", for: .normal)
        test = SelfTest(steps: makeSteps())
        tableView.reloadData()
        test.run(changed: { [weak self] in
            self?.tableView.reloadData()
        }, finished: { [weak self] in
            guard let self = self else { return }
            self.running = false
            self.runButton.isEnabled = true
            self.runButton.setTitle("Run again", for: .normal)
        })
    }
}

extension SelfTestViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return test.outcomes.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: StepCell.reuseIdentifier, for: indexPath)
        if let cell = cell as? StepCell { cell.show(test.outcomes[indexPath.row]) }
        return cell
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        return nil
    }
}

/// One step: what it was, how it went, and how long it took.
final class StepCell: UITableViewCell {
    static let reuseIdentifier = "step"

    private let markLabel = UILabel()
    private let nameLabel = UILabel()
    private let noteLabel = UILabel()
    private let timeLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        markLabel.font = UIFont.preferredFont(forTextStyle: .body)
        markLabel.setContentHuggingPriority(.required, for: .horizontal)
        nameLabel.font = UIFont.preferredFont(forTextStyle: .body)
        nameLabel.textColor = Palette.text
        nameLabel.numberOfLines = 0
        noteLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        noteLabel.textColor = Palette.secondaryText
        noteLabel.numberOfLines = 0
        timeLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
        timeLabel.textColor = Palette.secondaryText
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        for label in [markLabel, nameLabel, noteLabel, timeLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(label)
        }

        NSLayoutConstraint.activate([
            markLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            markLabel.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            nameLabel.topAnchor.constraint(equalTo: markLabel.topAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: markLabel.trailingAnchor, constant: 8),
            timeLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
            timeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
            timeLabel.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            noteLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            noteLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            noteLabel.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            noteLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ outcome: SelfTestOutcome) {
        nameLabel.text = outcome.name
        switch outcome.state {
        case .waiting:
            markLabel.text = "·"
            markLabel.textColor = Palette.secondaryText
            noteLabel.text = nil
        case .running:
            markLabel.text = "…"
            markLabel.textColor = Palette.accent
            noteLabel.text = nil
        case .passed(let note):
            markLabel.text = "✓"
            markLabel.textColor = Palette.accent
            noteLabel.text = note
        case .failed(let why):
            markLabel.text = "✗"
            markLabel.textColor = .systemRed
            noteLabel.text = why
        case .skipped:
            markLabel.text = "·"
            markLabel.textColor = Palette.secondaryText
            noteLabel.text = "not tried"
        }
        if let seconds = outcome.seconds {
            timeLabel.text = String(format: "%.0f ms", seconds * 1000)
        } else {
            timeLabel.text = nil
        }
    }
}
