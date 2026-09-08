import SwiftUI
import TopoAuth

@main
struct TopoApp: App {
    @State private var signIn: SignIn
    @State private var harness: Harness
    @State private var roleSelector: RoleSelector
    @State private var audio: AudioSession
    @State private var voice: VoiceInput
    @State private var speaker: Speaker
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before anything reads the store: a debug build launched with a setup token in its
        // environment is signed in by it, so the simulator comes up past the sign-in screen.
        #if DEBUG
        DebugRun.signIn()
        #endif
        _signIn = State(initialValue: SignIn())
        _harness = State(initialValue: Harness.standard())
        _roleSelector = State(initialValue: RoleSelector(database: TopoCloudKit.database(),
                                                         isSignedIn: { (try? KeychainTokenStore().load()) != nil }))
        let audio = AudioSession()
        _audio = State(initialValue: audio)
        _voice = State(initialValue: VoiceInput(audio: audio))
        _speaker = State(initialValue: Speaker(audio: audio))
    }

    /// The turn `TOPO_DEBUG_SEND` asks for, in a debug build. Nothing at all in a release one.
    private func debugTurn() async {
        #if DEBUG
        await DebugRun.send(with: harness)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView().environment(signIn).environment(harness).environment(roleSelector)
                .environment(voice).environment(speaker)
                // The record configuration is brought up on the foreground so the press is not
                // what pays for the route change; permission-gated inside.
                .onChange(of: scenePhase, initial: true) { _, phase in audio.warmRecord(phase == .active) }
                // Nothing unless a debug build was launched asking for a turn; the screen
                // behaves as it always does either way.
                .task { await debugTurn() }
        }
    }
}
