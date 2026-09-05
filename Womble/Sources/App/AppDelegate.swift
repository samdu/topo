import UIKit

/// One window, one screen. No scene manifest: scenes are iOS 13, and this
/// bundle exists for the devices that never got them.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    /// The screen's own presence on the network: the advert, the roster,
    /// and the question a registration puts to whoever is in the room.
    private let roster = SurfaceRoster()
    private var surface: SurfaceServer?
    private var prompt: RegistrationPrompt?
    private weak var house: HouseViewController?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let transcript = TranscriptViewController(source: CloudKitTranscriptSource())
        let house = HouseViewController(transcript: transcript,
                                        board: BoardViewController(source: CloudKitBoardSource()))
        let navigation = UINavigationController(rootViewController: house)
        navigation.navigationBar.tintColor = Palette.accent
        window.rootViewController = navigation
        window.backgroundColor = Palette.background
        window.makeKeyAndVisible()
        self.window = window
        self.house = house

        let prompt = RegistrationPrompt(roster: roster, presenting: house)
        roster.pendingChanged = { [weak prompt] in prompt?.askIfNeeded() }
        self.prompt = prompt
        let surface = SurfaceServer(device: SurfaceIdentity.device(),
                                    name: UIDevice.current.name, roster: roster)
        surface.start()
        self.surface = surface
        return true
    }

    /// The advert is the app's, not the device's: it goes when the app is
    /// not on screen, because a Womble that answers for a room ought to be
    /// in it.
    func applicationDidEnterBackground(_ application: UIApplication) {
        surface?.stop()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        surface?.start()
        prompt?.askIfNeeded()
        house?.read()
    }
}
