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
    @Environment(Mascot.self) private var mascot
    @State private var confirmingDisconnect = false
    /// Where Topo over GitHub's page is drawn and what he last drew.
    @State private var seen = SignSeen()
    @State private var confirmingOnePasswordDisconnect = false

    var body: some View {
        NavigationStack {
            Form {
                github
                onePassword
            }
            // While GitHub waits on its code, Topo stands at the foot of the page, and once the
            // code is copied he holds it up on a sign: a tap copies it again, says so on the sign,
            // and then opens GitHub's page over it.
            .safeAreaInset(edge: .bottom) {
                if case let .waiting(code) = connections.github {
                    GitHubCodeSign(code: code.userCode, raised: connections.codeCopied, copies: connections.copies,
                                   covered: connections.browserShowing) { pause in
                        connections.copyCodeAndOpenGitHub(after: pause)
                    }
                }
            }
            // While GitHub's page for that code is up in the browser's sheet, which covers the
            // foot, he swims up over the page and holds the code there too: a touch on him copies
            // it and opens nothing, and every other touch is the page's.
            .background(AboveSheets(content: overPage, takes: { [seen] in seen.takes($0) }))
            .onChange(of: connections.codeOverPage == nil) { _, gone in
                if gone { seen.leave() }
            }
            .navigationTitle("Connections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(look.settings.tint)
    }

    /// Topo over GitHub's page, carrying what the window above the sheet does not inherit.
    private var overPage: (some View)? {
        connections.codeOverPage.map { code in
            GitHubSignOverPage(code: code, copies: connections.copies, seen: seen) { connections.copyCode() }
                .environment(mascot).environment(\.look, look)
        }
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
            Text("Copy the code, then paste it on GitHub's page and approve Topo; this screen finishes by itself.")
        case .connected:
            Text("git and gh in Topo's Linux use this connection, with your access to every repository, your organizations' membership and workflow files. Disconnecting forgets the token here; revoke it at github.com/settings/applications.")
        default:
            Text("Lets Topo clone, push and open pull requests as you, on any repository you can reach.")
        }
    }
}


/// Topo while GitHub waits on its code, drawn by the engine the chat draws him with. Until the
/// code is copied he stands with nothing in his hands; once it is (`raised`) he takes the sign up
/// and holds the code, and the sign is the button. Each copy while it is up (`copies`) is said on
/// the board itself, Copied for `look.settings.copiedPause`, and then the code again, so a code
/// copied and lost from the pasteboard is still there to read and copy. A tap copies, jumps him
/// at the foot of the page, and hands `tapped` how long the board says Copied. Under Reduce Motion
/// he is one still frame per state, and nothing jumps.
struct GitHubCodeSign: View {
    let code: String
    /// He holds the sign up.
    let raised: Bool
    /// The copies made so far (`Connections.copies`).
    let copies: Int
    /// GitHub's page is over him: no frame is drawn until it goes.
    var covered = false
    /// Points an art pixel: the Connections page's or, over GitHub's page, that one's.
    var scale: CGFloat?
    /// What the tap does, said to VoiceOver, and the name a test finds the sign by.
    var hint = "Copies the code and opens GitHub"
    var identifier = "github-code-sign"
    /// Over GitHub's page: the picture alone, with no line under it and no jump, and what it
    /// draws and where told to `seen`, which is how his window knows a touch on him.
    var overPage = false
    var seen: SignSeen?
    let tapped: (Duration) -> Void
    @Environment(\.look) private var look
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(Mascot.self) private var mascot
    @State private var driver = MascotDriver()
    @State private var bumped = false
    @State private var sayingCopied = false
    @State private var saying: Task<Void, Never>?
    /// Thirtieths of a second for his arm to take the sign up and settle, for the still.
    static let settleSteps = 90
    /// The art row the top of his board stands at once he holds `words` up and has settled,
    /// which is his place's measure over GitHub's page: it moves with the head he wears, so it is
    /// read off the engine's own still rather than kept.
    static func boardTop(_ mascot: Mascot, words: String) -> Int {
        var state = mascot.drawn
        state.sign = words
        state.turnOpen = false
        state.activity = .idle
        guard let still = WidgetMascotView.still(state.input, steps: settleSteps), still.height >= Topo.height else { return 0 }
        let perArt = still.height / Topo.height
        let row = (0..<still.height).first { row in
            (0..<still.width).contains {
                SignSeen.drawn(still, at: CGPoint(x: (CGFloat($0) + 0.5) / CGFloat(still.width),
                                                  y: (CGFloat(row) + 0.5) / CGFloat(still.height)))
            }
        }
        return (row ?? 0) / perArt
    }
    /// What the board says for a while after a copy.
    static let copiedWords = "Copied"

    /// What the board says: nothing until the sign is up, then Copied a while after each copy,
    /// and otherwise the code.
    static func words(code: String, raised: Bool, sayingCopied: Bool) -> String? {
        guard raised else { return nil }
        return sayingCopied ? copiedWords : code
    }

    private var input: TopoInput {
        var state = mascot.drawn
        state.sign = Self.words(code: code, raised: raised, sayingCopied: sayingCopied)
        state.turnOpen = false
        state.activity = .idle
        return state.input
    }

    private struct Said: Equatable { var raised: Bool, copies: Int }

    var body: some View {
        VStack(spacing: look.settings.signSpacing) {
            Button {
                tapped(Self.pause(look.settings))
                guard !reduceMotion, !overPage else { return }
                withAnimation(.spring(duration: 0.2)) { bumped = true } completion: {
                    withAnimation(.spring(duration: 0.3)) { bumped = false }
                }
            } label: {
                // At most `signScale` times the engine's picture, and never wider than the page:
                // the code on the sign is what the person reads, so none of it is cut off. The
                // jump is inside that frame too (`drawnScale`).
                picture
                    .scaleEffect(overPage ? 1 : Self.drawnScale(bumped: bumped, bump: look.settings.copiedBump))
                    .frame(maxWidth: CGFloat(Topo.width) * (scale ?? look.settings.signScale),
                           maxHeight: CGFloat(Topo.height) * (scale ?? look.settings.signScale))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { seen?.frame = $0 }
            }
            .buttonStyle(.plain)
            .allowsHitTesting(raised)
            .accessibilityHidden(!raised)
            .accessibilityLabel("GitHub code \(code)")
            .accessibilityHint(hint)
            .accessibilityIdentifier(identifier)
            .sensoryFeedback(.success, trigger: copies) { _, _ in raised }
            if raised && !overPage {
                Text("Tap the sign to copy the code")
                    .foregroundStyle(look.settings.signInk)
                    .font(look.settings.signFont)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    // A style grows with the text size; past two lines of the largest font it
                    // shrinks to fit rather than pushing the sign up the page.
                    .minimumScaleFactor(Look.Settings.signLineShrink)
                    .frame(maxHeight: Look.Settings.signLineMost)
                    .accessibilityIdentifier("github-code-line")
            }
        }
        .frame(maxWidth: overPage ? nil : .infinity)
        .padding(.bottom, overPage ? 0 : look.settings.signSpacing)
        .onChange(of: Said(raised: raised, copies: copies)) { _, now in
            if now.raised { sayCopied() }
        }
        .onDisappear { saying?.cancel() }
    }

    /// The board says Copied for the look's pause, then the code again; a copy meanwhile starts
    /// the pause again.
    private func sayCopied() {
        saying?.cancel()
        sayingCopied = true
        let pause = Self.pause(look.settings)
        saying = Task {
            do { try await Task.sleep(for: pause) } catch { return }
            sayingCopied = false
        }
    }

    /// How large the picture is drawn in its frame: at rest one `bump`th of it, so the jump at
    /// the tap fills the frame and goes past it nowhere, since a scale effect is not laid out.
    static func drawnScale(bumped: Bool, bump: CGFloat) -> CGFloat {
        bumped ? 1 : 1 / bump
    }

    /// How long the board says Copied, which at the foot is also how long before GitHub's page
    /// opens.
    static func pause(_ settings: Look.Settings) -> Duration {
        .milliseconds(Int((settings.copiedPause * 1000).rounded()))
    }

    @ViewBuilder private var picture: some View {
        if reduceMotion {
            if let still = WidgetMascotView.still(input, steps: Self.settleSteps) {
                image(still).task(id: still) { seen?.image = still }
            }
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
                    seen?.image = driver.image
                }
            }
            .onAppear { driver.conditions = .init(active: true, onScreen: true) }
        }
    }

    private func image(_ frame: CGImage) -> some View {
        Image(decorative: frame, scale: 1).interpolation(.none).resizable().scaledToFit()
    }
}

/// Topo over GitHub's page: he comes up from the foot of the screen at `look.mascot.swimSpeed`
/// to his place, the top of the sign's board `look.settings.signOverPageTop` points under the
/// safe area's top and centred, below the browser's bar on an iPhone, and only there takes the
/// sign up, saying Copied a while before it shows the code. Under Reduce Motion he is put there.
/// Nothing of the page is his until he is in his place (`SignSeen.arrived`).
struct GitHubSignOverPage: View {
    let code: String
    let copies: Int
    let seen: SignSeen
    let copy: () -> Void
    @Environment(\.look) private var look
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(Mascot.self) private var mascot
    @State private var boardTop: Int?

    var body: some View {
        let scale = look.settings.signOverPageScale
        let size = CGSize(width: CGFloat(Topo.width) * scale, height: CGFloat(Topo.height) * scale)
        let board = boardTop ?? GitHubCodeSign.boardTop(mascot, words: code)
        let top = look.settings.signOverPageTop - CGFloat(board) * scale
        GeometryReader { proxy in
            let foot = proxy.size.height + proxy.safeAreaInsets.bottom - top
            GitHubCodeSign(code: code, raised: seen.arrived, copies: copies, scale: scale, hint: "Copies the code",
                           identifier: "github-code-sign-over-page", overPage: true, seen: seen) { _ in copy() }
                .frame(width: size.width, height: size.height)
                .position(x: proxy.size.width / 2, y: top + size.height / 2)
                .offset(y: seen.below ?? foot)
                .onAppear {
                    if boardTop == nil { boardTop = board }
                    seen.swim(from: foot, seconds: reduceMotion || foot <= 0 ? nil : foot / look.mascot.swimSpeed)
                }
        }
    }
}

/// Where Topo over GitHub's page is drawn and the last picture of him, in his window's points,
/// so the window takes a touch on a pixel of him or his sign once he is in his place and passes
/// every other touch to the page.
@Observable @MainActor final class SignSeen {
    @ObservationIgnored var frame = CGRect.null
    @ObservationIgnored var image: CGImage?
    /// He is in his place, holding the sign up.
    private(set) var arrived = false
    /// Points below his place he is drawn at; nil before his swim has begun, which is the foot.
    private(set) var below: CGFloat?
    @ObservationIgnored private var swimming: Task<Void, Never>?

    /// Swims him up from `foot` points below his place over `seconds`, SwiftUI's animation and
    /// so drawn at the display's rate, and has him arrive when its time is up, by the clock; with
    /// no seconds he is put there. A swim begun stands until he leaves: it lives here, not in the
    /// view, which the window above the sheet may build again under it.
    func swim(from foot: CGFloat, seconds: Double?) {
        guard below == nil else { return }
        guard let seconds else {
            below = 0
            arrived = true
            return
        }
        withAnimation(.easeInOut(duration: seconds)) { below = 0 }
        swimming = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) } catch { return }
            self?.arrived = true
        }
    }

    /// The page has gone: the next one he swims up over again.
    func leave() {
        swimming?.cancel()
        swimming = nil
        arrived = false
        below = nil
    }

    func takes(_ point: CGPoint) -> Bool {
        guard arrived, frame.contains(point), frame.width > 0, frame.height > 0, let image else { return false }
        return Self.drawn(image, at: CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height))
    }

    /// Whether anything is drawn in `image` at `unit`, a point of its unit square from the top left.
    static func drawn(_ image: CGImage, at unit: CGPoint) -> Bool {
        let x = Int(unit.x * CGFloat(image.width)), y = Int(unit.y * CGFloat(image.height))
        guard (0..<image.width).contains(x), (0..<image.height).contains(y),
              let one = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return false }
        var pixel: UInt32 = 0
        let read = withUnsafeMutableBytes(of: &pixel) { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return read && pixel >> 24 != 0
    }
}
