import SwiftUI
import TopoAuth

@main
struct TopoApp: App {
    @State private var signIn = SignIn()
    @State private var harness = Harness.standard()

    var body: some Scene {
        WindowGroup {
            RootView().environment(signIn).environment(harness)
        }
    }
}
