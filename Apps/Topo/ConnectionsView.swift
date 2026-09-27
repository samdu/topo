import SwiftUI
import TopoAuth

/// Settings › Connections: one section a service Topo can act on for the person — connect, who
/// it is connected as, disconnect. The tokens are held by the app; the guest asks for one each
/// time it needs it.
struct ConnectionsView: View {
    @Environment(Connections.self) private var connections
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @State private var confirmingDisconnect = false
    @State private var confirmingOnePasswordDisconnect = false

    var body: some View {
        NavigationStack {
            Form {
                github
                onePassword
            }
            .navigationTitle("Connections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(look.settings.tint)
    }

    private var github: some View {
        Section {
            switch connections.github {
            case .disconnected:
                Button("Connect GitHub") { connections.connectGitHub() }
            case .starting:
                Label("Asking GitHub for a code…", systemImage: "hourglass")
            case let .waiting(code):
                Text(code.userCode)
                    .font(look.settings.codeFont)
                    .textSelection(.enabled)
                    .accessibilityLabel("GitHub code \(code.userCode)")
                Button("Copy code") { UIPasteboard.general.string = code.userCode }
                Button("Open GitHub") { connections.reopenGitHub() }
                Button("Cancel", role: .cancel) { connections.cancelGitHub() }
            case .finishing:
                Label("Approved; asking GitHub who you are…", systemImage: "hourglass")
            case let .connected(login):
                LabeledContent("Connected as", value: "@\(login)")
                Button("Revoke on GitHub") { connections.open(Connections.githubAuthorizations) }
                Button("Disconnect", role: .destructive) { confirmingDisconnect = true }
                    .confirmationDialog("Disconnect GitHub?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
                        Button("Disconnect", role: .destructive) { connections.disconnectGitHub() }
                    } message: {
                        Text("Topo forgets the token on this phone. GitHub keeps the authorization until you revoke it at github.com/settings/applications.")
                    }
            case let .failed(words):
                Text(words)
                Button("Try again") { connections.connectGitHub() }
            }
        } header: {
            Text("GitHub")
        } footer: {
            githubFooter
        }
    }

    private var onePassword: some View {
        Section {
            switch connections.onePassword {
            case .disconnected, .failed:
                if case let .failed(words) = connections.onePassword { Text(words) }
                Button("Create a service account") { connections.open(Connections.onePasswordServiceAccounts) }
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    connections.connectOnePassword(pasted: text)
                }
            case .verifying:
                Label("Checking the token with 1Password…", systemImage: "hourglass")
                Button("Cancel", role: .cancel) { connections.cancelOnePassword() }
            case let .connected(vaults):
                LabeledContent("Vaults", value: vaults)
                Button("Disconnect", role: .destructive) { confirmingOnePasswordDisconnect = true }
                    .confirmationDialog("Disconnect 1Password?", isPresented: $confirmingOnePasswordDisconnect,
                                        titleVisibility: .visible) {
                        Button("Disconnect", role: .destructive) { connections.disconnectOnePassword() }
                    } message: {
                        Text("Topo forgets the service-account token on this phone. The service account stays in 1Password until you delete it there.")
                    }
            }
        } header: {
            Text("1Password")
        } footer: {
            if case .connected = connections.onePassword {
                Text("Topo reads secrets from these vaults when you ask it to, through a service account only this phone holds.")
            } else {
                Text("Make a service account for the one vault Topo may read, read-only, and copy its token; then paste it here.")
            }
        }
    }

    @ViewBuilder private var githubFooter: some View {
        switch connections.github {
        case .waiting:
            Text("The code is copied. Paste it on GitHub's page and approve Topo; this screen finishes by itself.")
        case .connected:
            Text("git and gh in Topo's Linux use this connection, with your access to every repository, your organizations' membership and workflow files. Disconnecting forgets the token here; revoke it at github.com/settings/applications.")
        default:
            Text("Lets Topo clone, push and open pull requests as you, on any repository you can reach.")
        }
    }
}
