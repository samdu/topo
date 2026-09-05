import UIKit

/// The whole of Womble: the transcript, read-only.
///
/// It reads on appearing, on returning to the foreground, and on a pull. It
/// writes nothing: there is no composer, no microphone and no sign-in, and
/// the only thing it can do to the log is look at it.
final class TranscriptViewController: UIViewController {
    private let source: TranscriptSource
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let statusView = StatusView()
    private let bannerLabel = UILabel()
    private let refresh = UIRefreshControl()

    private var turns: [Turn] = []
    private var isReading = false

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    init(source: TranscriptSource) {
        self.source = source
        super.init(nibName: nil, bundle: nil)
        title = "Womble"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background

        bannerLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
        bannerLabel.adjustsFontForContentSizeCategory = true
        bannerLabel.textColor = Palette.secondaryText
        bannerLabel.numberOfLines = 0
        bannerLabel.textAlignment = .center
        bannerLabel.isHidden = true
        bannerLabel.preservesSuperviewLayoutMargins = true
        bannerLabel.translatesAutoresizingMaskIntoConstraints = false

        tableView.dataSource = self
        tableView.register(TurnCell.self, forCellReuseIdentifier: TurnCell.reuseIdentifier)
        tableView.backgroundColor = Palette.background
        tableView.separatorColor = Palette.separator
        tableView.separatorInset = .zero
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.backgroundView = statusView
        tableView.refreshControl = refresh
        tableView.translatesAutoresizingMaskIntoConstraints = false
        refresh.addTarget(self, action: #selector(pulled), for: .valueChanged)

        view.addSubview(bannerLabel)
        view.addSubview(tableView)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            bannerLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            bannerLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            bannerLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            tableView.topAnchor.constraint(equalTo: bannerLabel.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(willEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)

        statusView.showReading()
        read()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if turns.isEmpty { read() }
    }

    @objc private func willEnterForeground() { read() }

    @objc private func pulled() { read() }

    /// One read at a time: a pull during a read joins the one in flight
    /// rather than starting a second.
    private func read() {
        guard !isReading else { return }
        isReading = true
        source.read { [weak self] result in
            guard let self = self else { return }
            self.isReading = false
            self.refresh.endRefreshing()
            switch result {
            case .success(let transcript):
                self.show(transcript)
            case .failure(let error):
                self.show(error)
            }
        }
    }

    private func show(_ transcript: Transcript) {
        let wasAtBottom = isAtBottom
        turns = transcript.ordered
        tableView.reloadData()
        show(banner: notice(for: transcript))

        statusView.isHidden = !turns.isEmpty
        if turns.isEmpty {
            statusView.show(title: "No turns yet",
                            message: "This is a viewer. When something is said on another device, it appears here.")
        } else if wasAtBottom {
            scrollToBottom(animated: false)
        }
    }

    private func show(_ error: TranscriptError) {
        statusView.isHidden = !turns.isEmpty
        guard turns.isEmpty else {
            // A failed refresh must not throw away turns already on screen:
            // CloudKit is truth, and what was read is still what it said.
            show(banner: "Could not read just now. Showing the last read.")
            return
        }
        switch error {
        case .noAccount:
            statusView.show(title: "Not signed in to iCloud",
                            message: "Womble reads the transcript from this Apple ID's private iCloud. Sign in from Settings and come back.",
                            retry: { [weak self] in self?.reading() })
        case .noLog:
            statusView.show(title: "No transcript yet",
                            message: "Nothing has been written on this Apple ID. Womble shows it as soon as something is.",
                            retry: { [weak self] in self?.reading() })
        case .unavailable:
            statusView.show(title: "Can’t reach iCloud",
                            message: "Womble will try again when it can.",
                            retry: { [weak self] in self?.reading() })
        case .rejected(let underlying):
            statusView.show(title: "iCloud refused the read",
                            message: underlying.localizedDescription,
                            retry: { [weak self] in self?.reading() })
        }
    }

    private func reading() {
        statusView.showReading()
        read()
    }

    private func notice(for transcript: Transcript) -> String? {
        if !transcript.isComplete {
            return "Some turns are not here yet. What you can see is below."
        }
        if transcript.isForked {
            return "Two devices carried on from the same point. Both branches are below."
        }
        return nil
    }

    private func show(banner: String?) {
        bannerLabel.text = banner
        bannerLabel.isHidden = banner == nil
    }

    private var isAtBottom: Bool {
        guard turns.isEmpty == false else { return true }
        let offset = tableView.contentOffset.y + tableView.bounds.height - tableView.adjustedContentInset.bottom
        return offset >= tableView.contentSize.height - 40
    }

    private func scrollToBottom(animated: Bool) {
        guard turns.isEmpty == false else { return }
        tableView.scrollToRow(at: IndexPath(row: turns.count - 1, section: 0), at: .bottom, animated: animated)
    }
}

extension TranscriptViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return turns.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: TurnCell.reuseIdentifier, for: indexPath)
        let turn = turns[indexPath.row]
        (cell as? TurnCell)?.show(turn, at: timeFormatter.string(from: turn.at))
        return cell
    }
}
