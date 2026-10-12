#if os(iOS) || os(macOS)
import SwiftUI
import TopoAuth

/// The first screen on a primary: one button. The "advanced" link is where an API key, another
/// provider or a custom endpoint will go.
struct SignInView: View {
    @Environment(SignIn.self) private var signIn
    @State private var webAuth = WebAuth()
    @State private var pasted = ""
    /// The guest's authorization this screen has opened, so it is opened once.
    @State private var opened: URL?

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
            case .approvingGuest(let url, let pasteHint):
                Text("Approve once more, for Claude Code on this phone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if pasteHint { pasteField } else { ProgressView() }
                Button("Open the page again") { webAuth.open(url) { signIn.guestSheetClosed(url) } }
                Button("Skip") { webAuth.close(); signIn.cancel() }
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
        .onChange(of: signIn.phase, initial: true) { _, phase in
            if phase == .signedIn || { if case .failed = phase { true } else { false } }() { webAuth.close() }
            // The guest's authorization, in a sheet of its own in place of the login's, once.
            if case .approvingGuest(let url, _) = phase, opened != url {
                opened = url
                pasted = ""
                webAuth.open(url) { signIn.guestSheetClosed(url) }
            }
        }
        // Signed in, this screen is gone before it hears of it: the sheet goes with it.
        .onDisappear { webAuth.close() }
    }

    private var signInButton: some View {
        Button {
            let url = signIn.start()
            webAuth.open(url) { signIn.loginSheetClosed() }
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
