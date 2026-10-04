import Foundation
import TopoCore

/// A timed run driven from a Mac, with nobody at the phone: `scripts/perf-run.sh` launches the
/// app with `TOPO_PERF_SEND` in its environment, and the app sends those questions itself, the
/// first as soon as the scene is up and each next once the last turn is over, through the same
/// harness the composer uses. Every `Perf.mark` of the run is also written to `tmp/topo-perf.log`
/// in the app's container, which the script copies off and reads.
///
/// It is in a release build because a release build is what is timed. The variable reaches the
/// process only from a launch by `devicectl` or Xcode, which is a developer's Mac the phone
/// trusts; an ordinary launch has no such variable and none of this runs.
enum PerfRun {
    static let sendVariable = "TOPO_PERF_SEND"
    static let gapVariable = "TOPO_PERF_GAP"
    /// `TOPO_PERF_SPOKEN=1`: the questions are sent as spoken turns, so their replies are read
    /// aloud and the voice's marks (`speak.begin`, `speak.firstFrame`) are in the run.
    static let spokenVariable = "TOPO_PERF_SPOKEN"

    /// The questions the launch asks for, in order, blank ones dropped: `TOPO_PERF_SEND` is a
    /// JSON array of strings, so a question may hold any character. Anything else is no run.
    static func questions(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        guard let data = environment[sendVariable]?.data(using: .utf8),
              let questions = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return questions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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

    /// A launch runs once, whichever window's task gets here first: an iPad restoring two
    /// windows has two.
    @MainActor private static var began = false

    /// How long a question's reply is waited for once its turn has ended without one in the
    /// transcript: a turn saved as a limb's is answered by another device, in its own time.
    static let replyWait: Duration = .seconds(60)

    /// Sends the questions one at a time, then marks `perf.run.done answered=<n>/<m>`, which is
    /// what the script waits for and checks. A question goes only after the reply to the one
    /// before it, and the run ends at the first that gets none; nothing is sent at all when the
    /// harness already has words waiting, since a question would only queue behind them.
    @MainActor
    static func run(with harness: Harness, speaker: Speaker,
                    environment: [String: String] = ProcessInfo.processInfo.environment) async {
        let questions = questions(environment)
        guard !questions.isEmpty, !began else { return }
        began = true
        let spoken = environment[spokenVariable] == "1"
        // A spoken turn needs the voice resident at the send, as a press of the microphone does.
        // A fresh install compiles the voice's model on its first load, which has taken 44 s.
        if spoken {
            for _ in 0..<1200 where !speaker.voice.ready { try? await Task.sleep(for: .milliseconds(100)) }
            if !speaker.voice.ready { Perf.mark("perf.voice.unready") }
        }
        while harness.busy { try? await Task.sleep(for: .milliseconds(100)) }
        let answered = harness.hasWaiting ? 0 : await ask(questions, gap: .seconds(gap(environment))) { index, question in
            Perf.mark("perf.question \(index + 1)/\(questions.count)")
            let nonce = harness.willSend(question)
            // As `ChatView.sendSpoken` sends what the ear heard.
            if spoken, speaker.awaitReply(nonce, readAloud: true).spoken { harness.markSpoken(nonce) }
            await harness.retry()
            let deadline = ContinuousClock.now + replyWait
            while harness.busy || (!harness.answered(nonce) && !harness.hasWaiting && ContinuousClock.now < deadline) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            // The next question waits for the reading to end, not only the reply.
            while spoken, speaker.speaking { try? await Task.sleep(for: .milliseconds(200)) }
            if !harness.answered(nonce) {
                Perf.mark("perf.unanswered said=\(harness.said(nonce)) turns=\(harness.turns.count) waiting=\(harness.hasWaiting)")
            }
            return harness.answered(nonce)
        }
        Perf.mark("perf.run.done answered=\(answered)/\(questions.count)")
    }

    /// Asks each question in turn with `gap` between a reply and the next, stopping at the first
    /// `one` answers false for, and answers how many were answered.
    @MainActor
    static func ask(_ questions: [String], gap: Duration, one: (Int, String) async -> Bool) async -> Int {
        for (index, question) in questions.enumerated() {
            if index > 0 { try? await Task.sleep(for: gap) }
            guard await one(index, question) else { return index }
        }
        return questions.count
    }
}
