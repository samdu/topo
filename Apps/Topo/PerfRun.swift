import Foundation
import TopoCore

/// A timed run driven from a Mac, with nobody at the phone: `scripts/perf-run.sh` launches the
/// app with `TOPO_PERF_SEND` in its environment, and the app sends those questions itself, the
/// first as soon as the scene is up and each next once the last was answered, through the same
/// harness the composer uses. Every `Perf.mark` of the run is also written to `tmp/topo-perf.log`
/// in the app's container, which the script copies off and reads.
///
/// It is in a release build because a release build is what is timed. The variable reaches the
/// process only from a launch by `devicectl` or Xcode, which is a developer's Mac the phone
/// trusts; an ordinary launch has no such variable and none of this runs.
enum PerfRun {
    static let sendVariable = "TOPO_PERF_SEND"
    static let gapVariable = "TOPO_PERF_GAP"
    /// What separates the questions in `TOPO_PERF_SEND`.
    static let separator = "||"

    /// The questions the launch asks for, in order, blank ones dropped.
    static func questions(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        (environment[sendVariable] ?? "").components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Seconds left between a reply and the next question, 5 unless `TOPO_PERF_GAP` says.
    static func gap(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Double {
        environment[gapVariable].flatMap(Double.init) ?? 5
    }

    /// Before the launch's first mark: a run that was asked for writes its marks to the file.
    static func begin() {
        guard !questions().isEmpty else { return }
        Perf.record(to: FileManager.default.temporaryDirectory.appendingPathComponent("topo-perf.log"))
    }

    /// Sends the questions, then marks `perf.run.done`, which is what the script waits for.
    @MainActor
    static func run(with harness: Harness) async {
        let questions = questions()
        guard !questions.isEmpty else { return }
        for (index, question) in questions.enumerated() {
            if index > 0 { try? await Task.sleep(for: .seconds(gap())) }
            Perf.mark("perf.question \(index + 1)/\(questions.count)")
            await harness.send(question)
        }
        Perf.mark("perf.run.done")
    }
}
