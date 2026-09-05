import UIKit

/// One window, one screen. No scene manifest: scenes are iOS 13, and this
/// bundle exists for the devices that never got them.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let navigation = UINavigationController(
            rootViewController: TranscriptViewController(source: CloudKitTranscriptSource()))
        navigation.navigationBar.tintColor = Palette.accent
        window.rootViewController = navigation
        window.backgroundColor = Palette.background
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
