import TopoTools
import XCTest

@testable import Topo

/// `topo voice`: the mind reading and changing the microphone's noise suppression and the voice's
/// temperature, in the defaults the press and the voice read.
final class VoiceToolTests: XCTestCase {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "topo.tests.\(UUID().uuidString)")!
    }

    func testAPhoneNeverAskedSuppresses() async {
        let defaults = defaults()
        XCTAssertTrue(NoiseSuppression.enabled(defaults))
        for arguments in [["noise-suppression"], ["noise-suppression", "status"]] {
            let reply = await VoiceTool(defaults: defaults).run(arguments)
            XCTAssertEqual(reply, .ok("noise suppression on\n"), "\(arguments)")
        }
        XCTAssertNil(defaults.object(forKey: NoiseSuppression.key), "asking sets nothing")
    }

    func testOffAndOnAreKeptWhereThePressReadsThem() async {
        let defaults = defaults()
        let tool = VoiceTool(defaults: defaults)
        var reply = await tool.run(["noise-suppression", "off"])
        XCTAssertEqual(reply, .ok("noise suppression off, from the next press\n"))
        XCTAssertFalse(NoiseSuppression.enabled(defaults))
        reply = await tool.run(["noise-suppression", "status"])
        XCTAssertEqual(reply, .ok("noise suppression off\n"))
        reply = await tool.run(["noise-suppression", "on"])
        XCTAssertEqual(reply, .ok("noise suppression on, from the next press\n"))
        XCTAssertTrue(NoiseSuppression.enabled(defaults))
    }

    func testRefusesWhatItDoesNotTakeAndChangesNothing() async {
        let defaults = defaults()
        let tool = VoiceTool(defaults: defaults)
        for arguments in [[], ["status"], ["off"], ["noise-suppression", "maybe"], ["noise-suppression", "off", "now"],
                          ["noise", "off"], ["noise-suppression", "--off"], ["temperature", "0.3", "now"],
                          ["temperature", "warm"], ["temperature", "-0.1"], ["temperature", "1.01"],
                          ["temperature", "nan"], ["temperature", "inf"], ["temp", "0.3"],
                          ["call", "maybe"], ["call", "on", "now"], ["calls", "on"],
                          ["wait", "0.5"], ["wait", "3.1"], ["wait", "long"], ["wait", "nan"], ["wait", "inf"],
                          ["wait", "1.2", "now"], ["waits", "1.2"]] {
            let reply = await tool.run(arguments)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(arguments): \(reply.text)")
            XCTAssertTrue(reply.text.contains("topo voice noise-suppression on"), "\(arguments)")
        }
        XCTAssertNil(defaults.object(forKey: NoiseSuppression.key))
        XCTAssertNil(defaults.object(forKey: VoiceTemperature.key))
        XCTAssertNil(defaults.object(forKey: SpokenCallSetting.key))
        XCTAssertNil(defaults.object(forKey: QuietWait.key))
    }

    func testAPhoneNeverAskedWaitsTheStandardPause() async {
        let defaults = defaults()
        for arguments in [["wait"], ["wait", "status"]] {
            let reply = await VoiceTool(defaults: defaults).run(arguments)
            XCTAssertEqual(reply, .ok("wait 1.2 s\n"), "\(arguments)")
        }
        XCTAssertNil(defaults.object(forKey: QuietWait.key), "asking sets nothing")
    }

    func testAWaitIsKeptWhereTheRuleReadsIt() async {
        let defaults = defaults()
        let tool = VoiceTool(defaults: defaults)
        for (asked, said) in [("2", "2.0"), ("0.6", "0.6"), ("3.0", "3.0"), ("1.4", "1.4")] {
            var reply = await tool.run(["wait", asked])
            XCTAssertEqual(reply, .ok("wait \(said) s, from the next verdict\n"))
            XCTAssertEqual(QuietWait.value(defaults), Double(said))
            reply = await tool.run(["wait", "status"])
            XCTAssertEqual(reply, .ok("wait \(said) s\n"))
        }
        // Out of range and not a number: the usage, and the wait as it was.
        for refused in ["0.4", "3.5", "soon"] {
            let reply = await tool.run(["wait", refused])
            XCTAssertEqual(reply.status, ToolReply.usage, refused)
            XCTAssertEqual(QuietWait.value(defaults), 1.4, refused)
        }
    }

    func testAPhoneNeverAskedCallsForSpokenReplies() async {
        let defaults = defaults()
        XCTAssertTrue(SpokenCallSetting.enabled(defaults))
        for arguments in [["call"], ["call", "status"]] {
            let reply = await VoiceTool(defaults: defaults).run(arguments)
            XCTAssertEqual(reply, .ok("call for spoken replies on\n"), "\(arguments)")
        }
        XCTAssertNil(defaults.object(forKey: SpokenCallSetting.key), "asking sets nothing")
    }

    func testTheCallIsKeptWhereTheDriverReadsIt() async {
        let defaults = defaults()
        let tool = VoiceTool(defaults: defaults)
        var reply = await tool.run(["call", "off"])
        XCTAssertEqual(reply, .ok("call for spoken replies off, from the next spoken reply\n"))
        XCTAssertFalse(SpokenCallSetting.enabled(defaults))
        reply = await tool.run(["call", "status"])
        XCTAssertEqual(reply, .ok("call for spoken replies off\n"))
        reply = await tool.run(["call", "on"])
        XCTAssertEqual(reply, .ok("call for spoken replies on, from the next spoken reply\n"))
        XCTAssertTrue(SpokenCallSetting.enabled(defaults))
        // The toggle's own value, kept as `@AppStorage` keeps a Bool, reads the same way.
        defaults.set(false, forKey: SpokenCallSetting.key)
        XCTAssertFalse(SpokenCallSetting.enabled(defaults))
    }

    func testAPhoneNeverAskedSpeaksAtTheStandardTemperature() async {
        let defaults = defaults()
        XCTAssertEqual(VoiceTemperature.value(defaults), 0.3)
        for arguments in [["temperature"], ["temperature", "status"]] {
            let reply = await VoiceTool(defaults: defaults).run(arguments)
            XCTAssertEqual(reply, .ok("temperature 0.30\n"), "\(arguments)")
        }
        XCTAssertNil(defaults.object(forKey: VoiceTemperature.key), "asking sets nothing")
    }

    func testATemperatureIsKeptWhereTheVoiceReadsIt() async {
        let defaults = defaults()
        let tool = VoiceTool(defaults: defaults)
        for (asked, said, kept) in [("0.7", "0.70", Float(0.7)), ("0", "0.00", 0), ("1", "1.00", 1), ("0.5", "0.50", 0.5)] {
            var reply = await tool.run(["temperature", asked])
            XCTAssertEqual(reply, .ok("temperature \(said), from the next reply\n"))
            XCTAssertEqual(VoiceTemperature.value(defaults), kept)
            reply = await tool.run(["temperature"])
            XCTAssertEqual(reply, .ok("temperature \(said)\n"))
        }
    }

    func testAValueKeptThatTheVoiceCannotTakeIsReadAsTheStandardOne() {
        let defaults = defaults()
        for kept: Any in [-0.1, 1.5, Double.nan, Double.infinity, "0.7", Data(), true, false] {
            defaults.set(kept, forKey: VoiceTemperature.key)
            XCTAssertEqual(VoiceTemperature.value(defaults), 0.3, "\(kept)")
        }
        defaults.set(0.7, forKey: VoiceTemperature.key)
        XCTAssertEqual(VoiceTemperature.value(defaults), 0.7, "what the settings sheet's slider writes")
    }

    func testAPhoneNeverAskedSpeaksAtItsOwnPace() async {
        let defaults = defaults()
        XCTAssertEqual(VoiceSpeed.value(defaults), 1.0)
        for arguments in [["speed"], ["speed", "status"]] {
            let reply = await VoiceTool(defaults: defaults).run(arguments)
            XCTAssertEqual(reply, .ok("speed 1.00\n"), "\(arguments)")
        }
        XCTAssertNil(defaults.object(forKey: VoiceSpeed.key), "asking sets nothing")
    }

    func testASpeedIsKeptWhereThePlayQueueReadsIt() async {
        let defaults = defaults()
        let tool = VoiceTool(defaults: defaults)
        for (asked, said, kept) in [("1.2", "1.20", Float(1.2)), ("0.8", "0.80", 0.8), ("1.5", "1.50", 1.5), ("1", "1.00", 1)] {
            var reply = await tool.run(["speed", asked])
            XCTAssertEqual(reply, .ok("speed \(said), from the next words read aloud\n"))
            XCTAssertEqual(VoiceSpeed.value(defaults), kept)
            reply = await tool.run(["speed"])
            XCTAssertEqual(reply, .ok("speed \(said)\n"))
        }
    }

    func testASpeedTheUnitCannotTakeIsRefusedAndOneKeptIsReadAsTheStandard() async {
        let defaults = defaults()
        for asked in ["0.79", "1.51", "0", "-1", "nan", "inf", "fast"] {
            let reply = await VoiceTool(defaults: defaults).run(["speed", asked])
            XCTAssertEqual(reply.status, ToolReply.usage, asked)
        }
        XCTAssertNil(defaults.object(forKey: VoiceSpeed.key))
        for kept: Any in [0.5, 2.0, Double.nan, Double.infinity, "1.2", Data(), true, false] {
            defaults.set(kept, forKey: VoiceSpeed.key)
            XCTAssertEqual(VoiceSpeed.value(defaults), 1.0, "\(kept)")
        }
        defaults.set(1.25, forKey: VoiceSpeed.key)
        XCTAssertEqual(VoiceSpeed.value(defaults), 1.25, "what the settings sheet's slider writes")
    }

    @MainActor func testTheVoiceHandsItsEngineTheTemperatureKeptAsEachSentenceIsAskedFor() async throws {
        let defaults = defaults()
        let engine = TemperatureRecorder()
        let voice = Voice(engine: engine, defaults: defaults)
        _ = try await voice.synthesise("Never asked.")
        defaults.set(0.7, forKey: VoiceTemperature.key)
        _ = try await voice.synthesise("Set in Settings.")
        _ = await VoiceTool(defaults: defaults).run(["temperature", "0.2"])
        _ = try await voice.synthesise("Set by the mind.")
        defaults.set(7.0, forKey: VoiceTemperature.key)
        _ = try await voice.synthesise("Kept out of range.")
        XCTAssertEqual(engine.handed, [0.3, 0.7, 0.2, 0.3])
    }

    @MainActor func testTheToolIsInTheTableWithItsUsageAndTheSkillNamesIt() async {
        let table = ToolTable([VoiceTool(defaults: defaults())])
        XCTAssertTrue(table.help.contains("voice  how this phone hears the person"), table.help)
        let usage = await table.run(["help", "voice"])
        XCTAssertTrue(usage.text.contains("topo voice noise-suppression off"), usage.text)
        XCTAssertNotNil(GuestResident.shared.toolTable.first { $0 is VoiceTool }, "the app's table has no voice tool")
        XCTAssertTrue(usage.text.contains("topo voice temperature VALUE"), usage.text)
        XCTAssertTrue(usage.text.contains("topo voice call off"), usage.text)
        XCTAssertTrue(GuestTools.skill.contains("`topo voice noise-suppression`"), "the mind is not told the tool exists")
        XCTAssertTrue(GuestTools.skill.contains("`topo voice temperature`"), "the mind is not told of the temperature")
        XCTAssertTrue(usage.text.contains("topo voice speed VALUE"), usage.text)
        XCTAssertTrue(GuestTools.skill.contains("`topo voice speed`"), "the mind is not told of the speed")
        XCTAssertTrue(usage.text.contains("topo voice working sounds"), usage.text)
        XCTAssertTrue(GuestTools.skill.contains("`topo voice working`"), "the mind is not told of the working sounds")
        XCTAssertTrue(usage.text.contains("topo voice wait VALUE"), usage.text)
        XCTAssertTrue(GuestTools.skill.contains("`topo voice wait`"), "the mind is not told of the wait")
        XCTAssertTrue(usage.text.contains("topo voice earcons off"), usage.text)
        XCTAssertTrue(GuestTools.skill.contains("`topo voice earcons`"), "the mind is not told of the earcons")
    }

    // MARK: - The keeper's sounds

    func testAPhoneNeverAskedPlaysReceipts() async {
        let defaults = defaults()
        XCTAssertEqual(WorkingSounds.mode(defaults), .receipts)
        for arguments in [["working"], ["working", "status"]] {
            let reply = await VoiceTool(defaults: defaults).run(arguments)
            XCTAssertEqual(reply, .ok("working sounds receipts\n"), "\(arguments)")
        }
        XCTAssertNil(defaults.object(forKey: WorkingSounds.key), "asking sets nothing")
    }

    func testEachModeIsKeptWhereTheSoundsReadIt() async {
        let defaults = defaults()
        let tool = VoiceTool(defaults: defaults)
        for mode in WorkingSounds.Mode.allCases {
            let reply = await tool.run(["working", mode.rawValue])
            XCTAssertEqual(reply, .ok("working sounds \(mode.rawValue), from the next sound\n"))
            XCTAssertEqual(WorkingSounds.mode(defaults), mode)
            XCTAssertEqual(defaults.string(forKey: WorkingSounds.key), mode.rawValue, "kept as anything but the case's name")
            let status = await tool.run(["working", "status"])
            XCTAssertEqual(status, .ok("working sounds \(mode.rawValue)\n"))
        }
    }

    func testAModeItDoesNotTakeIsTheUsageWithNothingKept() async {
        let defaults = defaults()
        let tool = VoiceTool(defaults: defaults)
        for arguments in [["working", "loud"], ["working", "on"], ["working", "off", "now"], ["working", "Sounds"]] {
            let reply = await tool.run(arguments)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(arguments): \(reply.text)")
            XCTAssertTrue(reply.text.contains("topo voice working off"), "\(arguments)")
        }
        XCTAssertNil(defaults.object(forKey: WorkingSounds.key))
    }

    // MARK: - Earcons

    func testAPhoneNeverAskedSoundsTheEarcons() async {
        let defaults = defaults()
        for arguments in [["earcons"], ["earcons", "status"]] {
            let reply = await VoiceTool(defaults: defaults).run(arguments)
            XCTAssertEqual(reply.text, "earcons on\n")
            XCTAssertEqual(reply.status, 0)
        }
        XCTAssertTrue(EarconsSetting.enabled(defaults))
    }

    func testEarconsOffAndOnAreKeptWhereTheCuesReadThem() async {
        let defaults = defaults()
        let tool = VoiceTool(defaults: defaults)
        let off = await tool.run(["earcons", "off"])
        XCTAssertEqual(off.text, "earcons off, from the next cue\n")
        XCTAssertFalse(EarconsSetting.enabled(defaults))
        XCTAssertEqual(defaults.object(forKey: EarconsSetting.key) as? Bool, false)
        let status = await tool.run(["earcons", "status"])
        XCTAssertEqual(status.text, "earcons off\n")
        let on = await tool.run(["earcons", "on"])
        XCTAssertEqual(on.text, "earcons on, from the next cue\n")
        XCTAssertTrue(EarconsSetting.enabled(defaults))
    }

    func testEarconsRefusesWhatItDoesNotTakeAndChangesNothing() async {
        let defaults = defaults()
        let tool = VoiceTool(defaults: defaults)
        for arguments in [["earcons", "loud"], ["earcons", "on", "now"]] {
            let reply = await tool.run(arguments)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(arguments) was taken")
            XCTAssertTrue(reply.text.contains("topo voice earcons on"), reply.text)
        }
        XCTAssertNil(defaults.object(forKey: EarconsSetting.key))
    }
}

/// An engine that keeps the temperature each sentence was asked for at and makes no audio.
final class TemperatureRecorder: VoiceEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var temperatures: [Float] = []
    var handed: [Float] { lock.withLock { temperatures } }

    func load(folder: URL, temperature: Float) async throws {}
    func stream(_ text: String, temperature: Float) async throws -> AsyncThrowingStream<Voice.Frame, Error> {
        lock.withLock { temperatures.append(temperature) }
        return AsyncThrowingStream { $0.finish() }
    }
}
