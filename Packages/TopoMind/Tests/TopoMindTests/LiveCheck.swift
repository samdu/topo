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
}
