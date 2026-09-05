import UIKit

/// The question a registration puts to the room.
///
/// Anyone on the network can ask this screen to answer for their agent;
/// nobody but a person standing in front of it can say yes. That is the
/// whole of the rule, and this is where it is asked: one alert at a time,
/// in the order the requests arrived, naming who is asking.
final class RegistrationPrompt {
    private let roster: SurfaceRoster
    private weak var presenter: UIViewController?
    private var asking = false

    init(roster: SurfaceRoster, presenting presenter: UIViewController) {
        self.roster = roster
        self.presenter = presenter
    }

    /// Asks about the oldest waiting registration, if there is one and the
    /// screen is not already asking about another.
    func askIfNeeded() {
        guard !asking, let token = roster.pending.first, let presenter = presenter,
              presenter.view.window != nil, presenter.presentedViewController == nil else { return }
        asking = true
        let alert = UIAlertController(
            title: "Register \(token.name)?",
            message: "It is asking this screen to answer for its agent. Anyone on this network can ask; only you can say yes.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Not now", style: .cancel) { [weak self] _ in
            self?.finish { $0.decline(token.device) }
        })
        alert.addAction(UIAlertAction(title: "Register", style: .default) { [weak self] _ in
            self?.finish { $0.accept(token.device) }
        })
        presenter.present(alert, animated: true)
    }

    private func finish(_ answer: (SurfaceRoster) -> Void) {
        asking = false
        answer(roster)
        // Another may have arrived while this one was on screen.
        askIfNeeded()
    }
}
