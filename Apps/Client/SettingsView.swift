#if os(iOS)
import SwiftUI
import TopoAuth
import TopoTurn

/// What the badge opens: the model, the voice, the vocabulary, the connections, the
/// diagnostics, the acknowledgements, and the way out.
struct SettingsView: View {
    /// The way out, handed down from the chat because that is where the five things it ends are.
    let signOut: SignOut
    @Environment(Harness.self) private var harness
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @AppStorage("readAloud") private var readAloud = true
    @State private var showDiagnostics = false
    @State private var showAbout = false
    @State private var showVocabulary = false
    @State private var showMemory = false
    @State private var showConnections = false

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
                Section("Memory") {
                    // The screen behind it says where the vault's folder is and carries the one
                    // control that moves it, so the row names that rather than the section again.
                    Button("Where it lives") { showMemory = true }
                }
                Section("Connections") {
                    // GitHub and 1Password, and who or what each reaches, on the screen behind it.
                    Button("GitHub and 1Password") { showConnections = true }
                }
                Section {
                    Button("Diagnostics") { showDiagnostics = true }
                    Button("About Topo") { showAbout = true }
                }
                Section {
                    Button("Sign out", role: .destructive) { Task { await signOut.act() } }
                }
                // Last: where Topo sits and the Reset for this device's hand on the look, with a
                // debug build's sliders under them.
                TuningSection()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
            .sheet(isPresented: $showAbout) { AboutView() }
            .sheet(isPresented: $showVocabulary) { VocabularyView() }
            .sheet(isPresented: $showMemory) { MemoryView() }
            .sheet(isPresented: $showConnections) { ConnectionsView() }
        }
        .tint(look.settings.tint)
    }
}

/// Letting go of the login, which is five things and not one. It is a value rather than a block
/// in the button so that what it ends, and the order it ends them in, is something a test can
/// read: a call left out here is a reply still being read, or a memory still on disk, for an
/// account the app has just let go of.
struct SignOut {
    /// The reply in the ear goes with the login: one still being read would otherwise carry on,
    /// holding the process open.
    var stopSpeaking: @MainActor () -> Void = {}
    /// The transcript, the outbox and the spoken marks, the turn and the pass in flight, and what
    /// the guest kept of the conversation. Awaited, so the guest's session and the bridge's ledger
    /// are gone before the login is.
    var forgetHarness: @MainActor () async -> Void = {}
    /// The memory is the person's and stays in their iCloud; the copy of it on this phone goes
    /// with the login.
    var forgetMemory: @MainActor () -> Void = {}
    /// The connections (GitHub): a phone with no login holds none of its person's tokens. Before
    /// the login, so a connect still in flight is stopped while there is an account it was for.
    var forgetConnections: @MainActor () -> Void = {}
    /// The tokens, last, so nothing above it runs without an account to run against.
    var forgetLogin: @MainActor () -> Void = {}

    @MainActor func act() async {
        stopSpeaking()
        await forgetHarness()
        forgetMemory()
        forgetConnections()
        forgetLogin()
    }
}

/// The far end of a takeover: another device wrote this one's role as viewer. A value for the same
/// reason `SignOut` is one, since what it ends is the login and everything held under it.
struct Takeover {
    /// What was waiting goes into the log first, while the chat and its task still stand.
    var demoteHarness: @MainActor () async -> Void = {}
    /// Then the role flips.
    var acceptDemotion: @MainActor () -> Void = {}
    /// The login goes, so the reply being read goes with it, as at a sign-out.
    var stopSpeaking: @MainActor () -> Void = {}
    /// A viewer holds no login and keeps no memory.
    var forgetMemory: @MainActor () -> Void = {}
    /// Nor any of its person's connections, and a connect in flight saves nothing after this.
    var forgetConnections: @MainActor () -> Void = {}
    /// The tokens, last.
    var forgetLogin: @MainActor () -> Void = {}

    @MainActor func act() async {
        await demoteHarness()
        acceptDemotion()
        stopSpeaking()
        forgetMemory()
        forgetConnections()
        forgetLogin()
    }
}
#endif
