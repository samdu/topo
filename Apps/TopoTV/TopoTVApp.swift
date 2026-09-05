import SwiftUI
import TopoAuth

/// The TV build never offers to be primary, so it never holds the Claude login.
@main
struct TopoTVApp: App {
    @State private var signIn = SignIn(store: InMemoryTokenStore())

    var body: some Scene {
        WindowGroup {
            RootView().environment(signIn)
        }
    }
}
