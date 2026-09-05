import SwiftUI
import TopoAuth

@main
struct TopoApp: App {
    @State private var signIn = SignIn()
    @State private var harness = Harness.standard()
    @State private var roleSelector = RoleSelector(database: TopoCloudKit.database(),
                                                   isSignedIn: { (try? KeychainTokenStore().load()) != nil })

    var body: some Scene {
        WindowGroup {
            RootView().environment(signIn).environment(harness).environment(roleSelector)
        }
    }
}
