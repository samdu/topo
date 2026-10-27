import XCTest

/// The quiet part of `topo_ui` holds the ear and the voice loading at every launch, whatever a
/// suite set (`TopoApplication`). This launch asks for a stub ear, which is resident at once,
/// and on the quiet part for the real voice too, and reads back from the app what it got: on
/// the quiet part both loading, so a launch that is not held fails here and not only in the
/// script's scan. Off it (`topo_ui` whole, `topo_ui:mic`) the stub ear is what the app has, so
/// the hold is the quiet part's alone; the voice is held loading there by the launch itself,
/// since a real one would fetch its model.
final class QuietLaneTests: XCTestCase {
    @MainActor
    func testTheQuietLaneHoldsTheEarAndTheVoiceLoadingAtLaunch() throws {
        let quiet = TopoApplication.quietLane
        let app = TopoLaunch.app()
        app.launchEnvironment["TOPO_CLAUDE_SETUP_TOKEN"] = "ui-test-placeholder"
        app.launchEnvironment["TOPO_DEBUG_OUTBOX"] = ""
        app.launchEnvironment["TOPO_DEBUG_LOOK"] = "{}"
        app.launchEnvironment["TOPO_DEBUG_TRANSCRIPT"] = "empty"
        app.launchEnvironment["TOPO_DEBUG_EAR"] = "stub"
        app.launchEnvironment["TOPO_DEBUG_VOICE"] = quiet ? "" : "loading"
        app.launchArguments += ["-firstRunAnswered", "YES"]
        app.launch()
        ChatReading.dismissAccountAlert()
        defer { app.terminate() }

        let wantEar = quiet ? "loading" : "ready"
        var ear: String?
        var voice: String?
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            ear = ChatReading.mic(ChatReading.microphone(app))?.ear
            voice = ChatReading.chat(app)?.voice
            if ear == wantEar, voice == "loading" { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertEqual(ear, wantEar, quiet ? "the quiet part launched an ear asked for as a stub, and it is not held loading"
                                           : "off the quiet part the ear is the stub the launch asked for")
        XCTAssertEqual(voice, "loading", quiet ? "the quiet part launched the real voice, and it is not held loading"
                                               : "the launch held the voice loading")
    }
}
