import Foundation

/// One thing the self-test does, and what happened when it did.
struct SelfTestStep {
    let name: String
    /// Runs it. The completion may arrive on any queue; the runner hops to
    /// the main queue itself.
    let run: (@escaping (Result<String, Error>) -> Void) -> Void
}

struct SelfTestOutcome {
    enum State {
        case waiting
        case running
        case passed(String)
        case failed(String)
        /// Not attempted, because something before it failed.
        case skipped
    }

    let name: String
    var state: State
    /// How long it took, once it has been.
    var seconds: TimeInterval?
}

/// The self-test: the steps in order, stopping at the first failure.
///
/// It stops because the steps depend on each other — there is no point
/// reading back a turn that was never written — and because the first
/// failure is the answer. "It reads nothing" becomes "the account is fine,
/// the zone was made, the write was refused, and here is what CloudKit
/// said", which is a line somebody can act on.
final class SelfTest {
    private(set) var outcomes: [SelfTestOutcome]
    private let steps: [SelfTestStep]
    private var index = 0
    private var started: Date?

    init(steps: [SelfTestStep]) {
        self.steps = steps
        self.outcomes = steps.map { SelfTestOutcome(name: $0.name, state: .waiting, seconds: nil) }
    }

    var isFinished: Bool { return index >= steps.count }

    /// Runs from the beginning. `changed` is called on the main queue after
    /// every change, so a screen can redraw; `finished` once, at the end.
    func run(changed: @escaping () -> Void, finished: @escaping () -> Void) {
        index = 0
        outcomes = steps.map { SelfTestOutcome(name: $0.name, state: .waiting, seconds: nil) }
        next(changed: changed, finished: finished)
    }

    private func next(changed: @escaping () -> Void, finished: @escaping () -> Void) {
        guard index < steps.count else {
            changed()
            finished()
            return
        }
        let step = steps[index]
        outcomes[index].state = .running
        started = Date()
        changed()

        step.run { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let took = self.started.map { Date().timeIntervalSince($0) }
                self.outcomes[self.index].seconds = took
                switch result {
                case .success(let note):
                    self.outcomes[self.index].state = .passed(note)
                    self.index += 1
                    self.next(changed: changed, finished: finished)
                case .failure(let error):
                    self.outcomes[self.index].state = .failed(SelfTest.describe(error))
                    // Everything after this was going to depend on it.
                    for later in (self.index + 1)..<self.outcomes.count {
                        self.outcomes[later].state = .skipped
                    }
                    self.index = self.steps.count
                    changed()
                    finished()
                }
            }
        }
    }

    /// What to put on the screen for an error. CloudKit's own descriptions
    /// name the thing that went wrong, which is the whole point of running
    /// this on the device rather than guessing from a simulator.
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "CKErrorDomain" {
            return "CloudKit \(nsError.code): \(nsError.localizedDescription)"
        }
        return nsError.localizedDescription
    }
}
