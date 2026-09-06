import SwiftUI
import TopoAuth

/// The client's role is decided at first launch from the CloudKit records (`RoleSelector`): a
/// phone or pad becomes primary and shows sign-in when nothing is primary yet, and a viewer
/// otherwise. The watch and TV are always viewers.
struct RootView: View {
    @Environment(SignIn.self) private var signIn
    #if os(iOS)
    @Environment(Harness.self) private var harness
    #endif
    @AppStorage("firstRunAnswer") private var firstRunAnswer = ""
    /// Set once the first answer is in the log, so the question is not asked twice.
    @AppStorage("firstRunAnswered") private var answered = false
    #if os(iOS)
    @Environment(RoleSelector.self) private var roleSelector
    #endif

    var body: some View {
        #if os(iOS)
        switch roleSelector.role {
        case nil:
            DecidingView(trouble: roleSelector.trouble) { await roleSelector.decide() }
        case .viewer:
            // A viewer holds no login. One found here (a reinstall keeps the keychain while the
            // role record says viewer, or a demotion decided at launch) goes now.
            ViewerRootView().task {
                if signIn.phase == .signedIn {
                    harness.forget()
                    signIn.signOut()
                }
            }
        case .primary:
            if signIn.phase != .signedIn {
                SignInView()
            } else if firstRunAnswer.isEmpty, !answered {
                FirstRunView { _ in }
            } else {
                ChatView()
            }
        }
        #elseif os(watchOS)
        WatchRootView()
        #elseif os(tvOS)
        TVRootView()
        #else
        ViewerPlaceholder()
        #endif
    }
}

/// What a viewer shows: only a "connected to" line.
struct ViewerPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            OctopusMark().frame(width: 64, height: 64)
            Text("Waiting to pair").font(.headline)
            Text("Sign in on your iPhone and this device will follow.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

#if os(iOS)
/// First launch, before the records have said what this device is. Reads again on its own
/// while iCloud is out of reach, and says so.
struct DecidingView: View {
    var trouble: String?
    var decide: () async -> Void

    var body: some View {
        VStack(spacing: 12) {
            OctopusMark().frame(width: 64, height: 64)
            ProgressView()
            Text(trouble == nil ? "Checking iCloud for your other devices…" : "Couldn't check iCloud: \(trouble!)")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .task {
            while !Task.isCancelled {
                await decide()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
}
#endif
