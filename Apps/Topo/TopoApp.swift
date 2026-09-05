import SwiftUI
import TopoAuth

@main
struct TopoApp: App {
    @State private var signIn = SignIn()

    var body: some Scene {
        WindowGroup {
            RootView().environment(signIn)
        }
    }
}
