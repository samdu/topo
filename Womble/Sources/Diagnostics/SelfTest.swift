import Foundation

/// One thing the self-test does, and what happened when it did.
struct SelfTestStep {
    let name: String
    /// True for a step that runs whatever went before it: tidying up, which
    /// matters most in the runs that failed, since those are the ones that
    /// left something behind.
    let always: Bool
    /// Runs it. The completion may arrive on any queue; the runner hops to
    /// the main queue itself.
    let run: (@escaping (Result<String, Error>) -> Void) -> Void

    init(name: String, always: Bool = false,
         run: @escaping (@escaping (Result<String, Error>) -> Void) -> Void) {
        self.name = name
        self.always = always
        self.run = run
    }
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

/// The self-test: the steps in order, stopping at the first failure, except
/// for the ones that always run.
///
/// It stops because the steps depend on each other — there is no point
/// reading back a turn that was never written — and because the first
/// failure is the answer. "It reads nothing" becomes "the account is fine,
/// the zone was made, the write was refused, and here is what CloudKit
/// said", which is a line somebody can act on.
///
/// Tidying up is not one of those. A run that failed is the run that most
/// needs it: the failures worth investigating happen after the zone exists,
/// and skipping the cleanup on the way out would leave one behind every
/// time somebody looked into a problem.
final class SelfTest {
    private(set) var outcomes: [SelfTestOutcome]
    private let steps: [SelfTestStep]
    private var index = 0
    private var started: Date?
    /// Something has already failed, so only the steps that always run do.
    private(set) var hasFailed = false

    init(steps: [SelfTestStep]) {
        self.steps = steps
        self.outcomes = steps.map { SelfTestOutcome(name: $0.name, state: .waiting, seconds: nil) }
    }

    var isFinished: Bool { return index >= steps.count }

    /// Runs from the beginning. `changed` is called on the main queue after
    /// every change, so a screen can redraw; `finished` once, at the end.
    func run(changed: @escaping () -> Void, finished: @escaping () -> Void) {
        index = 0
        hasFailed = false
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
        if hasFailed, !step.always {
            outcomes[index].state = .skipped
            index += 1
            next(changed: changed, finished: finished)
            return
        }
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
                    // Everything after this was going to depend on it, so
                    // the rest is not tried — but the tidying still is.
                    self.hasFailed = true
                    self.index += 1
                    self.next(changed: changed, finished: finished)
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
