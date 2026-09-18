#if os(iOS)
import SwiftUI
import TopoAuth
import TopoTurn

/// What the badge opens: the model, the voice, the vocabulary, the diagnostics, the
/// acknowledgements, and the way out.
struct SettingsView: View {
    /// The way out, handed down from the chat because that is where the four things it ends are.
    let signOut: SignOut
    @Environment(Harness.self) private var harness
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @AppStorage("readAloud") private var readAloud = true
    @State private var showDiagnostics = false
    @State private var showAbout = false
    @State private var showVocabulary = false
    #if DEBUG
    /// The vault's other home, asked about rather than built: see `VaultProbe`.
    @State private var showVaultProbe = false
    #endif

    var body: some View {
        @Bindable var harness = harness
        NavigationStack {
            Form {
                Section("Mind") {
                    Picker("Model", selection: $harness.model) {
                        ForEach(ClaudeModel.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                Section("Voice") {
                    Toggle("Read replies aloud", isOn: $readAloud)
                    Button("Vocabulary") { showVocabulary = true }
                }
                Section {
                    Button("Diagnostics") { showDiagnostics = true }
                    Button("About Topo") { showAbout = true }
                    #if DEBUG
                    // Whether a folder in iCloud Drive › Obsidian, granted by the picker alone,
                    // is one this app can read and write on a later launch. Nothing it does
                    // reaches the memory; it goes when that answer is in.
                    Button("Probe iCloud Drive…") { showVaultProbe = true }
                    #endif
                }
                Section {
                    Button("Sign out", role: .destructive) { signOut.act() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
            .sheet(isPresented: $showAbout) { AboutView() }
            .sheet(isPresented: $showVocabulary) { VocabularyView() }
            #if DEBUG
            .sheet(isPresented: $showVaultProbe) { VaultProbeView() }
            #endif
        }
        .tint(look.settings.tint)
    }
}

/// Letting go of the login, which is four things and not one. It is a value rather than a block
/// in the button so that what it ends, and the order it ends them in, is something a test can
/// read: a call left out here is a reply still being read, or a memory still on disk, for an
/// account the app has just let go of.
struct SignOut {
    /// The reply in the ear goes with the login: one still being read would otherwise carry on,
    /// holding the process open.
    var stopSpeaking: @MainActor () -> Void = {}
    /// The transcript, the outbox and the spoken marks.
    var forgetHarness: @MainActor () -> Void = {}
    /// The memory is the person's and stays in their iCloud; the copy of it on this phone goes
    /// with the login.
    var forgetMemory: @MainActor () -> Void = {}
    /// The tokens, last, so nothing above it runs without an account to run against.
    var forgetLogin: @MainActor () -> Void = {}

    @MainActor func act() {
        stopSpeaking()
        forgetHarness()
        forgetMemory()
        forgetLogin()
    }
}
#endif
