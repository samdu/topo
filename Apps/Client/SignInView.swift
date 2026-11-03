#if os(iOS)
import SwiftUI
import TopoAuth
import TopoProxy

/// The first screen on a primary: once the guest is up, one button. The sign-in is Claude Code's
/// own, in the guest (`SignIn`, `GuestLogin`): this screen opens the page it hands out in a sheet
/// and, where that page cannot come back, the paste page, whose code goes in the field. Beneath
/// it, *Use without an account* signs in with no Claude login at all (`SignIn.useWithoutAccount`):
/// the mind is Apple's on-device model, and the line under the button says so, or why this phone
/// cannot run it.
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
                withoutAccount
            case .approving(let approval):
                if approval.pasting { pasteField } else { ProgressView("Waiting for Claude…") }
                if approval.page != nil {
                    Button("Open the page again") { pasted = ""; signIn.openPageAgain() }
                }
                Button("Cancel") { signIn.cancel() }
            case .failed(let message):
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                signInButton
                withoutAccount
            }
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

    /// Topo on Apple's on-device model, with no Claude account: offered where this phone can run
    /// the model, and otherwise drawn disabled over the reason. Asked as the screen is drawn, since
    /// a model still downloading is ready later.
    private var withoutAccount: some View {
        let unavailable = OnDeviceModel.unavailability()
        return VStack(spacing: 6) {
            Button("Use without an account") { signIn.useWithoutAccount() }
                .font(.subheadline)
                .tint(Theme.teal)
                .disabled(unavailable != nil)
            Text(unavailable ?? "Topo answers with Apple's model, on this phone: no internet, no tools.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .accessibilityElement(children: .contain)
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
