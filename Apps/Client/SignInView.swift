#if os(iOS)
import SwiftUI
import TopoAuth

/// The first screen on a primary: once the guest is up, one button. The sign-in is Claude Code's
/// own, in the guest (`SignIn`, `GuestLogin`): this screen opens the page it hands out in a sheet
/// and, where that page cannot come back, the paste page, whose code goes in the field. The
/// "advanced" link is where an API key, another provider or a custom endpoint will go.
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
            if signIn.signInAgain, signIn.phase == .idle {
                Text("Sign in again: Topo now signs in through Claude Code, which brings your claude.ai connectors.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            switch signIn.phase {
            case .preparing(let line):
                ProgressView("Getting Topo ready…")
                if !line.isEmpty {
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
            case .idle, .signedIn:
                signInButton
            case .approving(let approval):
                if approval.pasting { pasteField } else { ProgressView("Waiting for Claude…") }
                if approval.page != nil {
                    Button("Open the page again") { pasted = ""; signIn.openPageAgain() }
                }
                Button("Cancel") { signIn.cancel() }
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
        .task { await signIn.prepare() }
        // The sheet follows the sign-in's: a new one opens over the last, none closes it.
        .onChange(of: signIn.sheet, initial: true) { _, sheet in
            guard let sheet else { webAuth.close(); return }
            webAuth.open(sheet.url) { signIn.sheetClosed(sheet) }
        }
        // Signed in, this screen is gone before it hears of it: the sheet goes with it.
        .onDisappear { webAuth.close() }
    }

    private var signInButton: some View {
        Button {
            signIn.start()
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
            Button("Continue") { Task { await signIn.paste(pasted) } }
                .buttonStyle(.borderedProminent)
                .tint(Theme.teal)
                .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
#endif
