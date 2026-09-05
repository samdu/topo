import SwiftUI
import TopoAuth

@main
struct TopoWatchApp: App {
    @State private var signIn = SignIn(store: InMemoryTokenStore())

    var body: some Scene {
        WindowGroup {
            RootView().environment(signIn)
        }
    }
}
