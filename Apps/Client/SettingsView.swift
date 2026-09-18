#if os(iOS)
import SwiftUI
import TopoAuth
import TopoTurn

/// What the badge opens: the model, the voice, the vocabulary, the diagnostics, the
/// acknowledgements, and the way out.
struct SettingsView: View {
    @Environment(Harness.self) private var harness
    @Environment(SignIn.self) private var signIn
    @Environment(\.dismiss) private var dismiss
    @AppStorage("readAloud") private var readAloud = true
    @State private var showDiagnostics = false
    @State private var showAbout = false
    @State private var showVocabulary = false

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
                }
                Section {
                    Button("Sign out", role: .destructive) { harness.forget(); signIn.signOut() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
            .sheet(isPresented: $showAbout) { AboutView() }
            .sheet(isPresented: $showVocabulary) { VocabularyView() }
        }
        .tint(Theme.primary)
    }
}
#endif
