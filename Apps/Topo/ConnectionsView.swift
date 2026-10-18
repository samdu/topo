import SwiftUI
import TopoAuth
import TopoMascot

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
            // While GitHub waits on its code, Topo holds it up on a sign at the foot of the page:
            // a tap copies it, says so, and only then opens GitHub's page over it.
            .safeAreaInset(edge: .bottom) {
                if case let .waiting(code) = connections.github {
                    GitHubCodeSign(code: code.userCode, copied: connections.codeCopied,
                                   covered: connections.browserShowing) { pause in
                        connections.copyCodeAndOpenGitHub(after: pause)
                    }
                }
            }
            .navigationTitle("Connections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(look.settings.tint)
    }

    /// What the GitHub row offers in each state. A failure keeps Disconnect beside Try again, since
    /// the failure may be a clear the keychain refused, with the token still on the phone:
    /// Disconnect tries the clear again (every connection's, while a refused sign-out clear stands).
    enum GitHubAction: Equatable {
        case connect, tryAgain, openGitHub, cancel, revoke, disconnect
    }

    static func githubActions(_ state: Connections.GitHub) -> [GitHubAction] {
        switch state {
        case .disconnected: [.connect]
        case .starting, .finishing: []
        case .waiting: [.openGitHub, .cancel]
        case .connected: [.revoke, .disconnect]
        case .failed: [.tryAgain, .disconnect]
        }
    }

    private var github: some View {
        Section {
            switch connections.github {
            case .disconnected: EmptyView()
            case .starting: Label("Asking GitHub for a code…", systemImage: "hourglass")
            case let .waiting(code):
                Text(code.userCode)
                    .font(look.settings.codeFont)
                    .textSelection(.enabled)
                    .accessibilityLabel("GitHub code \(code.userCode)")
            case .finishing: Label("Approved; asking GitHub who you are…", systemImage: "hourglass")
            case let .connected(login): LabeledContent("Connected as", value: "@\(login)")
            case let .failed(words): Text(words)
            }
            ForEach(Self.githubActions(connections.github), id: \.self) { action in
                switch action {
                case .connect: Button("Connect GitHub") { connections.connectGitHub() }
                case .tryAgain: Button("Try again") { connections.connectGitHub() }
                // The sign's tap without the pause: the code copied, and the page opened at once.
                case .openGitHub: Button("Copy code and open GitHub") { connections.copyCodeAndOpenGitHub() }
                case .cancel: Button("Cancel", role: .cancel) { connections.cancelGitHub() }
                case .revoke: Button("Revoke on GitHub") { connections.open(Connections.githubAuthorizations) }
                case .disconnect:
                    Button("Disconnect", role: .destructive) { confirmingDisconnect = true }
                        .confirmationDialog("Disconnect GitHub?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
                            Button("Disconnect", role: .destructive) { connections.disconnectGitHub() }
                        } message: {
                            Text("Topo forgets the token on this phone. GitHub keeps the authorization until you revoke it at github.com/settings/applications.")
                        }
                }
            }
        } header: {
            Text("GitHub")
        } footer: {
            githubFooter
        }
    }

    /// What the 1Password row offers in each state. A failure keeps Disconnect beside the paste,
    /// since the failure may be a clear the keychain refused, with the token still on the phone:
    /// Disconnect tries the clear again (every connection's, while a refused sign-out clear stands).
    enum OnePasswordAction: Equatable {
        case createServiceAccount, paste, cancel, disconnect
    }

    static func onePasswordActions(_ state: Connections.OnePassword) -> [OnePasswordAction] {
        switch state {
        case .disconnected: [.createServiceAccount, .paste]
        case .failed: [.createServiceAccount, .paste, .disconnect]
        case .verifying: [.cancel]
        case .connected: [.disconnect]
        }
    }

    private var onePassword: some View {
        Section {
            switch connections.onePassword {
            case let .failed(words): Text(words)
            case .verifying: Label("Checking the token with 1Password…", systemImage: "hourglass")
            case let .connected(vaults): LabeledContent("Vaults", value: vaults)
            case .disconnected: EmptyView()
            }
            ForEach(Self.onePasswordActions(connections.onePassword), id: \.self) { action in
                switch action {
                case .createServiceAccount:
                    Button("Create a service account") { connections.open(Connections.onePasswordServiceAccounts) }
                case .paste:
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        connections.connectOnePassword(pasted: text)
                    }
                case .cancel:
                    Button("Cancel", role: .cancel) { connections.cancelOnePassword() }
                case .disconnect:
                    Button("Disconnect", role: .destructive) { confirmingOnePasswordDisconnect = true }
                        .confirmationDialog("Disconnect 1Password?", isPresented: $confirmingOnePasswordDisconnect,
                                            titleVisibility: .visible) {
                            Button("Disconnect", role: .destructive) { connections.disconnectOnePassword() }
                        } message: {
                            Text("Topo forgets the service-account token on this phone. Revoke the service account in 1Password too: a copy of its token taken while it was connected keeps working until you do.")
                        }
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
        case .waiting where connections.codeCopied:
            Text("The code is copied. Paste it on GitHub's page and approve Topo; this screen finishes by itself.")
        case .waiting:
            Text("Tap Topo's sign to copy the code, then paste it on GitHub's page and approve Topo; this screen finishes by itself.")
        case .connected:
            Text("git and gh in Topo's Linux use this connection, with your access to every repository, your organizations' membership and workflow files. Disconnecting forgets the token here; revoke it at github.com/settings/applications.")
        default:
            Text("Lets Topo clone, push and open pull requests as you, on any repository you can reach.")
        }
    }
}

/// Topo holding GitHub's one-time code up on a sign, drawn by the engine the chat draws him with,
/// and the line under him. The sign is the button: a tap copies the code and jumps the sign, the
/// line turns to the confirmation, and `tapped` is handed how long the confirmation stands before
/// GitHub's page opens. He is drawn holding the sign from the first frame, never taking it up, so
/// the code is readable at once. Under Reduce Motion he is one still frame, and nothing jumps.
struct GitHubCodeSign: View {
    let code: String
    let copied: Bool
    /// GitHub's page is over him: no frame is drawn until it goes.
    var covered = false
    let tapped: (Duration) -> Void
    @Environment(\.look) private var look
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(Mascot.self) private var mascot
    @State private var driver = MascotDriver()
    @State private var bumped = false
    /// Thirtieths of a second for his arm to take the sign up and settle, for the still.
    static let settleSteps = 90

    private var input: TopoInput {
        var state = mascot.drawn
        state.sign = code
        state.turnOpen = false
        state.activity = .idle
        return state.input
    }

    var body: some View {
        VStack(spacing: look.settings.signSpacing) {
            Button {
                tapped(Self.pause(look.settings))
                guard !reduceMotion else { return }
                withAnimation(.spring(duration: 0.2)) { bumped = true } completion: {
                    withAnimation(.spring(duration: 0.3)) { bumped = false }
                }
            } label: {
                // At most `signScale` times the engine's picture, and never wider than the page:
                // the code on the sign is what the person reads, so none of it is cut off.
                picture
                    .frame(maxWidth: CGFloat(Topo.width) * look.settings.signScale,
                           maxHeight: CGFloat(Topo.height) * look.settings.signScale)
                    .scaleEffect(bumped ? look.settings.copiedBump : 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("GitHub code \(code)")
            .accessibilityHint("Copies the code and opens GitHub")
            .accessibilityIdentifier("github-code-sign")
            .sensoryFeedback(.success, trigger: copied) { _, now in now }
            Group {
                if copied {
                    Label("Copied", systemImage: "checkmark").foregroundStyle(look.settings.copiedInk)
                } else {
                    Text("Tap the sign to copy the code").foregroundStyle(look.settings.signInk)
                }
            }
            .font(look.settings.signFont)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("github-code-line")
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, look.settings.signSpacing)
    }

    /// How long the confirmation stands before GitHub's page opens.
    static func pause(_ settings: Look.Settings) -> Duration {
        .milliseconds(Int((settings.copiedPause * 1000).rounded()))
    }

    @ViewBuilder private var picture: some View {
        if reduceMotion {
            if let still = WidgetMascotView.still(input, steps: Self.settleSteps) { image(still) }
        } else {
            TimelineView(.animation(minimumInterval: look.mascot.frameInterval, paused: covered)) { context in
                Group {
                    // Until the first frame, the still: a picture drawn once, as a snapshot is, has him too.
                    if let frame = driver.image { image(frame) }
                    else if let still = WidgetMascotView.still(input, steps: Self.settleSteps) { image(still) }
                }
                .onChange(of: context.date) { last, now in
                    driver.input = input
                    if driver.frames == 0 { driver.settle(Self.settleSteps) }
                    driver.tick(min(now.timeIntervalSince(last), MascotCanvas.stepCap(interval: look.mascot.frameInterval)))
                }
            }
            .onAppear { driver.conditions = .init(active: true, onScreen: true) }
        }
    }

    private func image(_ frame: CGImage) -> some View {
        Image(decorative: frame, scale: 1).interpolation(.none).resizable().scaledToFit()
    }
}
