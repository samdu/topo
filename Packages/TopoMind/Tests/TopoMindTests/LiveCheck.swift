import Foundation
import Testing
import TopoCore
import TopoTurn
@testable import TopoMind

/// One real turn through the installed `claude`, with the user's own login (no config directory),
/// plan mode, and an empty working directory. Run by hand only: `TOPO_MIND_LIVE=1 swift test
/// --filter LiveCheck`. It spends a Haiku turn of the signed-in account.
@Suite struct LiveCheck {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOPO_MIND_LIVE"] == "1"))
    func oneRealTurn() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "topo-mind-live-\(UUID().uuidString)")
        let work = root.appending(path: "work"), state = root.appending(path: "state")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let brain = NativeBrain(.init(workingDirectory: work, configDirectory: nil, stateDirectory: state,
                                      permissionMode: "plan"))
        let person = Turn(ref: TurnRef(device: DeviceID("live"), sequence: 1), parents: [], role: .person,
                          text: "Reply with exactly the word pong and nothing else.", at: Date())
        let began = ContinuousClock.now
        let reply = try await brain.answer(BrainRequest(context: [], answering: [person], parents: [person.ref],
                                                        nonce: TurnRunner.replyNonce(for: [person.ref]), model: .sonnet))
        let took = ContinuousClock.now - began
        let pid = await brain.pid
        print("LIVE reply=\(reply.text.debugDescription) model=\(reply.model) context=\(reply.context) output=\(reply.outputTokens) took=\(took) pid=\(pid.map(String.init) ?? "-")")
        print("LIVE describe=\(await brain.describe())")
        print("LIVE ledger=\((try? String(contentsOf: state.appending(path: "mind.json"), encoding: .utf8)) ?? "-")")
        print("LIVE work=\(work.path)")
        let confirmed = await brain.shutdown()
        print("LIVE shutdown confirmed=\(confirmed) pidAlive=\(pid.map(MindProcess.alive) ?? false)")
        #expect(!reply.text.isEmpty)
    }

    /// Two real turns in the mind's own home and login (`MindHome`, `auto` mode): one that needs the
    /// Bash tool, then, from a second process over the same ledger, one only the resumed session can
    /// answer. Run by hand only: `TOPO_MIND_LIVE=mind swift test --filter LiveCheck`. Its ledger is
    /// a temporary one, so the hub's own is not touched.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOPO_MIND_LIVE"] == "mind"))
    func aToolTurnThenAResumedOneInTheMindsHome() async throws {
        try MindHome.prepare()
        let state = FileManager.default.temporaryDirectory.appending(path: "topo-mind-live-\(UUID().uuidString)")
        var configuration = MindHome.configuration()
        configuration.stateDirectory = state
        var log: [Turn] = []
        func ask(_ sequence: Int64, _ text: String) async throws -> String {
            let brain = NativeBrain(configuration)
            // The process is started first, as the hub's is, so the turn's stages are a warm process's.
            await brain.use(model: .sonnet)
            try await brain.start()
            let person = Turn(ref: TurnRef(device: DeviceID("live"), sequence: sequence), parents: log.last.map { [$0.ref] } ?? [],
                              role: .person, text: text, at: Date())
            let began = ContinuousClock.now
            let stages = Marks()
            @Sendable func at() -> String { "\((ContinuousClock.now - began) / .milliseconds(1))" }
            await brain.stages(to: { stages.add("\($0)=\(at())") })
            await brain.writes(to: { frame in
                switch frame {
                case .message: stages.add("message=\(at())")
                case .text: stages.add("text=\(at())")
                case .tool: stages.add("tool=\(at())")
                default: break
                }
            })
            defer { print("LIVE mind turn=\(sequence) stages ms: \(stages.all.joined(separator: " "))") }
            let nonce = TurnRunner.replyNonce(for: [person.ref])
            let reply = try await brain.answer(BrainRequest(context: log, answering: [person], parents: [person.ref],
                                                            nonce: nonce, model: .sonnet))
            let written = Turn(ref: TurnRef(device: DeviceID("live-mac"), sequence: sequence), parents: [person.ref],
                               role: .assistant, text: reply.text, at: Date())
            await brain.landed(written, nonce: nonce)
            log += [person, written]
            print("LIVE mind turn=\(sequence) reply=\(reply.text.debugDescription) model=\(reply.model) took=\(ContinuousClock.now - began)")
            print("LIVE mind describe=\(await brain.describe())")
            let pid = await brain.pid
            let confirmed = await brain.shutdown()
            print("LIVE mind shutdown confirmed=\(confirmed) pidAlive=\(pid.map(MindProcess.alive) ?? false)")
            return reply.text
        }
        let first = try await ask(1, "Run `echo topo-$((6*7))` with the Bash tool and reply with exactly what it printed, nothing else.")
        #expect(first.contains("topo-42"))
        let second = try await ask(2, "What did that command print? Reply with exactly that, nothing else, and run nothing.")
        #expect(second.contains("topo-42"))
    }
}
