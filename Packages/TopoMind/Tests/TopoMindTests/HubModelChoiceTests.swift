import Foundation
import Testing
import TopoCore
import TopoCoreTesting
import TopoTurn
@testable import TopoMind

/// Marks made under one test's tasks.
final class Marks: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    var all: [String] { lock.withLock { names } }
    func add(_ name: String) { lock.withLock { names.append(name) } }
}

/// The model a hub answers with is the person's choice in the zone (`ModelChoice`), and its own
/// picker where no device has said. Every suite run is a debug build, pinned to Haiku at the
/// process (`ClaudeModel.effective`), so what is held is the model the pass asked for, by its mark.
@Suite(.serialized) struct HubModelChoiceTests {
    func hub(_ h: HubRig, picker: ClaudeModel) -> HubMind {
        let configuration = h.configuration
        return HubMind(database: h.db, device: h.hubID, endpoint: "127.0.0.1:1", probe: Confirming(),
                       brain: h.brain, login: { await MindLogin.check(configuration) },
                       model: { picker }, timing: fast, poll: .milliseconds(100))
    }

    @Test func aTurnIsAnsweredWithTheChoiceADeviceSaid() async throws {
        let h = try HubRig()
        let marks = Marks()
        try await Perf.$observer.withValue({ marks.add($0) }) {
            let hub = hub(h, picker: .sonnet)
            await hub.turnOn()
            #expect(await eventually { await hub.snapshot().holds })
            // No device has said: the picker.
            try await h.phoneSays("first")
            #expect(try await eventually { try await h.replies().count == 1 })
            #expect(marks.all.contains("hub.pass.model sonnet picker"))
            // The phone says Opus, then its turn.
            try await ModelChoice.say(.opus, by: h.phoneID, to: h.db)
            try await h.phoneSays("second")
            #expect(try await eventually { try await h.replies().count == 2 })
            #expect(marks.all.contains("hub.pass.model opus chosen"))
            // A pass with nothing to answer reads no choice.
            let asked = marks.all.filter { $0.hasPrefix("hub.pass.model") }.count
            try await Task.sleep(for: .milliseconds(600))
            #expect(marks.all.filter { $0.hasPrefix("hub.pass.model") }.count == asked)
            await hub.turnOff()
        }
    }
}
