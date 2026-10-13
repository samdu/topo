import TopoTools
import XCTest

@testable import Topo

/// `topo voice`: the mind reading and changing the microphone's noise suppression, in the defaults
/// the press reads.
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
                          ["noise", "off"], ["noise-suppression", "--off"]] {
            let reply = await tool.run(arguments)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(arguments): \(reply.text)")
            XCTAssertTrue(reply.text.contains("topo voice noise-suppression on"), "\(arguments)")
        }
        XCTAssertNil(defaults.object(forKey: NoiseSuppression.key))
    }

    @MainActor func testTheToolIsInTheTableWithItsUsageAndTheSkillNamesIt() async {
        let table = ToolTable([VoiceTool(defaults: defaults())])
        XCTAssertTrue(table.help.contains("voice  how this phone hears the person"), table.help)
        let usage = await table.run(["help", "voice"])
        XCTAssertTrue(usage.text.contains("topo voice noise-suppression off"), usage.text)
        XCTAssertNotNil(GuestResident.shared.toolTable.first { $0 is VoiceTool }, "the app's table has no voice tool")
        XCTAssertTrue(GuestTools.skill.contains("`topo voice noise-suppression`"), "the mind is not told the tool exists")
    }
}
