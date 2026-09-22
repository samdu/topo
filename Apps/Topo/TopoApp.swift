import SwiftUI
import TopoAuth

@main
struct TopoApp: App {
    /// For the UIKit callbacks SwiftUI has no spelling of: the models' background download
    /// finishing, and a silent push saying the log moved. See `TopoAppDelegate`.
    @UIApplicationDelegateAdaptor(TopoAppDelegate.self) private var appDelegate
    @State private var signIn: SignIn
    @State private var harness: Harness
    @State private var memory: Memory
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
        // And before the harness reads its line: a debug build asked for a turn owed gets one,
        // so a launch can be the relaunch that comes back to a row it never finished sending.
        DebugRun.seedOutbox()
        #endif
        _signIn = State(initialValue: SignIn())
        _harness = State(initialValue: Harness.standard())
        _memory = State(initialValue: Memory.standard())
        _roleSelector = State(initialValue: RoleSelector(database: TopoCloudKit.database(),
                                                         isSignedIn: { (try? KeychainTokenStore().load()) != nil }))
        let audio = AudioSession()
        _audio = State(initialValue: audio)
        // The compile cache a new install leaves behind is cleared before the ear and the voice
        // exist, so no model is loading while it goes. A debug build launched asking for a stub
        // ear gets one; every other launch, the real one.
        #if DEBUG
        let (ear, spoken) = ModelHousekeeping.launch(clear: ModelHousekeeping.clearCompileCache,
                                                     ear: { DebugRun.ear() }, voice: { DebugRun.voice() })
        #else
        let (ear, spoken) = ModelHousekeeping.launch(clear: ModelHousekeeping.clearCompileCache,
                                                     ear: { Ear() }, voice: { Voice() })
        #endif
        _voice = State(initialValue: VoiceInput(audio: audio, ear: ear))
        _speaker = State(initialValue: Speaker(audio: audio, voice: spoken))
        // What says, on a device run with no debugger attached, when iOS suspended the process.
        #if DEBUG
        AudioLog.startHeartbeat()
        #endif
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
                .environment(voice).environment(speaker).environment(memory)
                // What every view draws with, which is the vault's `look.json` read onto the
                // compiled look. It is worn here rather than on the chat so that the first run,
                // the sign-in and the viewer screen are drawn by the same document; the memory
                // reads it after each sync, so a look the mind wrote is worn from the next one
                // with no relaunch.
                .wearing(memory)
                // The record configuration is brought up on the foreground so the press is not
                // what pays for the route change; permission-gated inside. The ear's and the
                // voice's models are asked for on the same cue, downloaded if the phone lacks
                // them, so they are resident by the first press.
                // The memory is mirrored by whatever phone holds a login, so what a revision's
                // push wakes follows the login and not the chat: a phone sitting on the first
                // run, or on a sign-in it has already answered, mirrors like any other. The
                // subscription is saved from here for the same reason, and a failure costs only
                // the acceleration, so it is not the screen's to report.
                .onChange(of: signIn.phase, initial: true) { _, phase in
                    MemoryWake.follow(signedIn: phase == .signedIn, memory: memory)
                    guard phase == .signedIn else { return }
                    Task { try? await NotePush.ensureSubscription() }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    audio.warmRecord(phase == .active)
                    if phase == .active {
                        voice.prepare()
                        speaker.prepare()
                        // The memory catches up with what the other devices wrote while this
                        // phone was away, and anything edited in Files here goes out, before
                        // the person has typed anything.
                        Task { await memory.sync() }
                    }
                }
                // Nothing unless a debug build was launched asking for a turn; the screen
                // behaves as it always does either way.
                .task { await debugTurn() }
        }
    }
}
