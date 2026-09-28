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

    var body: some View {
        NavigationStack {
            Form {
                github
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
