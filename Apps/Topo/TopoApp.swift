import SwiftUI
import TopoAuth

@main
struct TopoApp: App {
    @State private var signIn = SignIn()
    @State private var harness = Harness.standard()
    @State private var roleSelector = RoleSelector(database: TopoCloudKit.database(),
                                                   isSignedIn: { (try? KeychainTokenStore().load()) != nil })
    @State private var audio = AudioSession()
    @State private var voice: VoiceInput
    @State private var speaker: Speaker
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let audio = AudioSession()
        _audio = State(initialValue: audio)
        _voice = State(initialValue: VoiceInput(audio: audio))
        _speaker = State(initialValue: Speaker(audio: audio))
    }

    var body: some Scene {
        WindowGroup {
            RootView().environment(signIn).environment(harness).environment(roleSelector)
                .environment(voice).environment(speaker)
                // The record configuration is brought up on the foreground so the press is not
                // what pays for the route change; permission-gated inside.
                .onChange(of: scenePhase, initial: true) { _, phase in audio.warmRecord(phase == .active) }
        }
    }
}
