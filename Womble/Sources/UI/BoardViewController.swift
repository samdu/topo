import UIKit

/// The house board: the cards the household has posted, on a screen in a
/// room, read-only.
///
/// It shows what is still asking for something. A ticked or dismissed card
/// is not deleted — it is a revision like any other — but a noticeboard is
/// for what is open, and the transcript beside it is where the day's
/// history belongs.
final class BoardViewController: UIViewController {
    private let source: BoardSource
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private let titleLabel = UILabel()
    private var cards: [Card] = []
    private var isReading = false

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    init(source: BoardSource) {
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background

        titleLabel.text = "The house"
        titleLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Palette.secondaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.text = "Nothing on the board."
        emptyLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = Palette.secondaryText
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorColor = Palette.separator
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.register(CardCell.self, forCellReuseIdentifier: CardCell.reuseIdentifier)
        tableView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(titleLabel)
        view.addSubview(tableView)
        view.addSubview(emptyLabel)

        let guide: UILayoutGuide
        if #available(iOS 11.0, *) { guide = view.safeAreaLayoutGuide } else { guide = view.layoutMarginsGuide }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            tableView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        read()
    }

    /// Reads the board. A failure keeps the cards already on screen: what
    /// the house last posted is still what it posted.
    func read() {
        guard !isReading else { return }
        isReading = true
        source.read { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isReading = false
                switch result {
                case .success(let board):
                    self.cards = board.open
                    self.tableView.reloadData()
                    self.emptyLabel.text = "Nothing on the board."
                case .failure:
                    if self.cards.isEmpty { self.emptyLabel.text = "The board could not be read." }
                }
                self.emptyLabel.isHidden = !self.cards.isEmpty
            }
        }
    }
}

extension BoardViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return cards.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: CardCell.reuseIdentifier, for: indexPath)
        if let cell = cell as? CardCell {
            let card = cards[indexPath.row]
            cell.show(card, posted: timeFormatter.string(from: card.postedAt))
        }
        return cell
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        // A Womble takes no taps: it has no login to write one with.
        return nil
    }
}

/// One card: what it says, and who put it there.
final class CardCell: UITableViewCell {
    static let reuseIdentifier = "card"

    private let bodyLabel = UILabel()
    private let ownerLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        bodyLabel.font = UIFont.preferredFont(forTextStyle: .body)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.textColor = Palette.text
        bodyLabel.numberOfLines = 0
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        ownerLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
        ownerLabel.adjustsFontForContentSizeCategory = true
        ownerLabel.textColor = Palette.secondaryText
        ownerLabel.numberOfLines = 1
        ownerLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(bodyLabel)
        contentView.addSubview(ownerLabel)
        NSLayoutConstraint.activate([
            bodyLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            bodyLabel.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            ownerLabel.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 2),
            ownerLabel.leadingAnchor.constraint(equalTo: bodyLabel.leadingAnchor),
            ownerLabel.trailingAnchor.constraint(equalTo: bodyLabel.trailingAnchor),
            ownerLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ card: Card, posted: String) {
        bodyLabel.text = card.body
        ownerLabel.text = "\(card.owner) · \(posted)"
    }
}
