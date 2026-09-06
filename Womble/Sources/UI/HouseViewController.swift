import UIKit

/// The whole screen: the transcript, and the house board beside it.
///
/// Which way round depends on the shape of the screen rather than on a
/// setting. A wide screen puts them side by side, the transcript given the
/// greater share because it is the longer read; a tall one stacks them,
/// board above so the thing a room needs at a glance is at eye height. A
/// drawer iPad on a shelf spends its life in one orientation and its
/// owner's hands in the other, so this follows the device rather than
/// asking.
final class HouseViewController: UIViewController {
    private let transcript: TranscriptViewController
    private let board: BoardViewController
    private let stack = UIStackView()
    private var boardSizeConstraint: NSLayoutConstraint?

    init(transcript: TranscriptViewController, board: BoardViewController) {
        self.transcript = transcript
        self.board = board
        super.init(nibName: nil, bundle: nil)
        title = transcript.title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background
        installTitleTap()

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.distribution = .fill
        stack.alignment = .fill
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // The board first in the stack: above in portrait, left in
        // landscape reads as a sidebar, so it goes second there. `arrange`
        // puts them in the order the shape wants.
        for child in [board, transcript] {
            addChild(child)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            child.didMove(toParent: self)
        }
        arrange(for: view.bounds.size)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.arrange(for: size) })
    }

    /// Lays the two out for a screen of this shape.
    func arrange(for size: CGSize) {
        let sideBySide = size.width > size.height
        let order = sideBySide ? [transcript, board] : [board, transcript]
        guard stack.axis != (sideBySide ? .horizontal : .vertical)
                || stack.arrangedSubviews.count != order.count else { return }
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        stack.axis = sideBySide ? .horizontal : .vertical
        for child in order { stack.addArrangedSubview(child.view) }

        boardSizeConstraint?.isActive = false
        // The board takes a third of a wide screen and a third of a tall
        // one; the transcript fills what is left.
        let constraint = sideBySide
            ? board.view.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.34)
            : board.view.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.34)
        constraint.isActive = true
        boardSizeConstraint = constraint
    }

    /// Five taps on the title opens the self-test. Hidden because nobody
    /// looking at a wall wants a diagnostics button on it, and reachable
    /// without a cable because the failures it finds only happen on a real
    /// device with a real Apple ID.
    private func installTitleTap() {
        let label = UILabel()
        label.text = title
        label.font = UIFont.preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Palette.text
        label.isUserInteractionEnabled = true
        label.sizeToFit()
        let tap = UITapGestureRecognizer(target: self, action: #selector(openSelfTest))
        tap.numberOfTapsRequired = 5
        label.addGestureRecognizer(tap)
        navigationItem.titleView = label
    }

    @objc private func openSelfTest() {
        navigationController?.pushViewController(SelfTestViewController(), animated: true)
    }

    /// Which way the two are laid out right now.
    var layoutAxis: NSLayoutConstraint.Axis { return stack.axis }
    /// Top to bottom, or leading to trailing.
    var layoutOrder: [UIViewController] {
        return stack.arrangedSubviews.compactMap { subview in
            children.first { $0.view === subview }
        }
    }

    /// Reads both again: what the pull on the transcript already does, plus
    /// the board, which has no gesture of its own.
    func read() {
        board.read()
    }
}
