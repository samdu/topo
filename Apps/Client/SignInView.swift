#if os(iOS) || os(macOS)
import SwiftUI
import TopoAuth

/// The first screen on a primary: one button. The "advanced" link is where an API key, another
/// provider or a custom endpoint will go.
struct SignInView: View {
    @Environment(SignIn.self) private var signIn
    @State private var webAuth = WebAuth()
    @State private var pasted = ""

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            OctopusMark().frame(width: 96, height: 96)
            Text("Topo")
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
            Spacer()
            switch signIn.phase {
            case .idle, .signedIn:
                signInButton
            case .waiting(let pasteHint):
                if pasteHint { pasteField } else { ProgressView("Waiting for Claude…") }
                Button("Cancel") { webAuth.close(); signIn.cancel() }
            case .exchanging:
                ProgressView("Signing in…")
            case .failed(let message):
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                signInButton
            }
            Button("Advanced") {}
                .font(.footnote)
                .foregroundStyle(.secondary)
                .disabled(true)
            Spacer().frame(height: 24)
        }
        .padding()
        .onChange(of: signIn.phase) { _, phase in
            if phase == .signedIn || { if case .failed = phase { true } else { false } }() { webAuth.close() }
        }
    }

    private var signInButton: some View {
        Button {
            let url = signIn.start()
            webAuth.open(url) { signIn.cancel() }
        } label: {
            Text("Sign in with Claude")
                .font(.headline)
                .frame(maxWidth: 320)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.teal)
    }

    private var pasteField: some View {
        VStack(spacing: 12) {
            Text("Copy the code the sign-in page shows and paste it here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Code", text: $pasted)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            Button("Continue") { Task { await signIn.finish(pasted: pasted) } }
                .buttonStyle(.borderedProminent)
                .tint(Theme.teal)
                .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
#endif
