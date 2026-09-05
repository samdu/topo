import SwiftUI
import TopoAuth

/// The menu-bar hub: the only target that runs resident code. It carries the Claude login for the
/// mind; the CLI and channel servers it will bundle are not here yet.
@main
struct TopoHubApp: App {
    @State private var signIn = SignIn()

    var body: some Scene {
        MenuBarExtra("Topo", systemImage: "circle.hexagongrid.fill") {
            HubMenu().environment(signIn)
        }
        .menuBarExtraStyle(.window)
    }
}

struct HubMenu: View {
    @Environment(SignIn.self) private var signIn
    @State private var webAuth = WebAuth()
    @State private var pasted = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Topo Hub").font(.headline)
            switch signIn.phase {
            case .signedIn:
                Label("Signed in with Claude", systemImage: "checkmark.circle.fill")
                Button("Sign out") { signIn.signOut() }
            case .idle:
                Button("Sign in with Claude") { webAuth.open(signIn.start()) { signIn.cancel() } }
            case .waiting(let pasteHint):
                if pasteHint {
                    TextField("Paste the code", text: $pasted)
                    Button("Continue") { Task { await signIn.finish(pasted: pasted) } }
                } else {
                    ProgressView("Waiting for Claude…")
                }
                Button("Cancel") { webAuth.close(); signIn.cancel() }
            case .exchanging:
                ProgressView("Signing in…")
            case .failed(let message):
                Text(message).foregroundStyle(.secondary)
                Button("Try again") { webAuth.open(signIn.start()) { signIn.cancel() } }
            }
            Divider()
            Button("Quit Topo Hub") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 280)
        .onChange(of: signIn.phase) { _, phase in
            if phase == .signedIn || { if case .failed = phase { true } else { false } }() { webAuth.close() }
        }
    }
}
