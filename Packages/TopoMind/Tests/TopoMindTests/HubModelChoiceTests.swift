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

    /// The process starts with the choice in the zone, and with the picker where no device has said
    /// or the record cannot be read.
    @Test func theStartGivesTheProcessTheChoiceOrThePicker() async throws {
        let h = try HubRig()
        // Mutant: the start given the picker whatever the zone says.
        #expect(await hub(h, picker: .sonnet).startingModel() == .sonnet)
        try await ModelChoice.say(.opus, by: h.phoneID, to: h.db)
        #expect(await hub(h, picker: .sonnet).startingModel() == .opus)
        let configuration = h.configuration
        let unreadable = HubMind(database: ChoiceUnreadable(base: h.db), device: h.hubID, endpoint: "127.0.0.1:1",
                                 probe: Confirming(), brain: h.brain, login: { await MindLogin.check(configuration) },
                                 model: { .fable }, timing: fast)
        // Mutant: a read that failed answered with the default model rather than the picker.
        #expect(await unreadable.startingModel() == .fable)
    }
}

/// A store whose fetch of the person's choice of model fails, as CloudKit unreachable does.
struct ChoiceUnreadable: ForwardingDatabase {
    let base: any RecordDatabase
    func fetch(_ ids: [RecordID], through base: any RecordDatabase) async throws -> [RecordID: Record] {
        if ids.contains(ModelChoice.recordID) { throw RecordDatabaseError.unavailable(underlying: URLError(.notConnectedToInternet)) }
        return try await base.fetch(ids)
    }
}

/// The stages of a pass that answers, each marked once and in the order they happen, from the
/// trigger to the first words: what the time between the turn landing and the reply's first words
/// is read off.
@Suite(.serialized) struct PassMarksTests {
    @Test func aPassThatAnswersMarksEachStageOnceInOrder() async throws {
        let h = try HubRig()
        let marks = Marks()
        try await Perf.$observer.withValue({ marks.add($0) }) {
            let configuration = h.configuration
            let hub = HubMind(database: h.db, device: h.hubID, endpoint: "127.0.0.1:1", probe: Confirming(),
                              brain: h.brain, login: { await MindLogin.check(configuration) },
                              model: { .sonnet }, timing: LeaseTiming(duration: 60, heartbeat: 30),
                              poll: .seconds(3600), answeringPoll: .seconds(3600))
            await hub.turnOn()
            #expect(await eventually { let s = await hub.snapshot(); return s.holds && s.lastPass != nil })
            try await h.phoneSays("hello")
            await hub.trigger(.push)
            #expect(try await eventually { try await h.replies().count == 1 })
            #expect(await eventually { marks.all.contains { $0.hasPrefix("hub.pass.end answered") } })
            await hub.turnOff()
        }
        let names = marks.all.filter { $0.hasPrefix("hub.pass.") }.map { String($0.split(separator: " ")[0].dropFirst(9)) }
        let pass = Array(names[try #require(names.lastIndex(of: "trigger"))...])
        // Mutant: a stage of the brain's not handed to the clock (`stages(to:)`, or the frames).
        #expect(pass == ["trigger", "read", "probed", "model", "lease", "asked", "written", "received", "begun", "words",
                         "answered", "saved", "end"])
    }
}
