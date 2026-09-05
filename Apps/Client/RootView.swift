import SwiftUI
import TopoAuth

/// The client's role is decided at first launch from the CloudKit records; until that wiring
/// lands the phone is primary and the watch and TV are viewers waiting to pair.
struct RootView: View {
    @Environment(SignIn.self) private var signIn
    @AppStorage("firstRunAnswer") private var firstRunAnswer = ""

    var body: some View {
        #if os(iOS)
        if signIn.phase != .signedIn {
            SignInView()
        } else if firstRunAnswer.isEmpty {
            FirstRunView { _ in }
        } else {
            ChatView()
        }
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
