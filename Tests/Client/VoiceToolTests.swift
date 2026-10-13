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
                          ["temperature", "nan"], ["temperature", "inf"], ["temp", "0.3"]] {
            let reply = await tool.run(arguments)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(arguments): \(reply.text)")
            XCTAssertTrue(reply.text.contains("topo voice noise-suppression on"), "\(arguments)")
        }
        XCTAssertNil(defaults.object(forKey: NoiseSuppression.key))
        XCTAssertNil(defaults.object(forKey: VoiceTemperature.key))
    }

    func testAPhoneNeverAskedSpeaksAtTheStandardTemperature() async {
        let defaults = defaults()
        XCTAssertEqual(VoiceTemperature.value(defaults), 0.5)
        for arguments in [["temperature"], ["temperature", "status"]] {
            let reply = await VoiceTool(defaults: defaults).run(arguments)
            XCTAssertEqual(reply, .ok("temperature 0.50\n"), "\(arguments)")
        }
        XCTAssertNil(defaults.object(forKey: VoiceTemperature.key), "asking sets nothing")
    }

    func testATemperatureIsKeptWhereTheVoiceReadsIt() async {
        let defaults = defaults()
        let tool = VoiceTool(defaults: defaults)
        for (asked, said, kept) in [("0.7", "0.70", Float(0.7)), ("0", "0.00", 0), ("1", "1.00", 1), ("0.3", "0.30", 0.3)] {
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
            XCTAssertEqual(VoiceTemperature.value(defaults), 0.5, "\(kept)")
        }
        defaults.set(0.7, forKey: VoiceTemperature.key)
        XCTAssertEqual(VoiceTemperature.value(defaults), 0.7, "what the settings sheet's slider writes")
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
        XCTAssertEqual(engine.handed, [0.5, 0.7, 0.2, 0.5])
    }

    @MainActor func testTheToolIsInTheTableWithItsUsageAndTheSkillNamesIt() async {
        let table = ToolTable([VoiceTool(defaults: defaults())])
        XCTAssertTrue(table.help.contains("voice  how this phone hears the person"), table.help)
        let usage = await table.run(["help", "voice"])
        XCTAssertTrue(usage.text.contains("topo voice noise-suppression off"), usage.text)
        XCTAssertNotNil(GuestResident.shared.toolTable.first { $0 is VoiceTool }, "the app's table has no voice tool")
        XCTAssertTrue(usage.text.contains("topo voice temperature VALUE"), usage.text)
        XCTAssertTrue(GuestTools.skill.contains("`topo voice noise-suppression`"), "the mind is not told the tool exists")
        XCTAssertTrue(GuestTools.skill.contains("`topo voice temperature`"), "the mind is not told of the temperature")
    }
}

/// An engine that keeps the temperature each sentence was asked for at and makes no audio.
final class TemperatureRecorder: VoiceEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var temperatures: [Float] = []
    var handed: [Float] { lock.withLock { temperatures } }

    func load(base: URL) async throws {}
    func stream(_ text: String, temperature: Float) async throws -> AsyncThrowingStream<Voice.Frame, Error> {
        lock.withLock { temperatures.append(temperature) }
        return AsyncThrowingStream { $0.finish() }
    }
}
