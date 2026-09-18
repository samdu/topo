import UIKit

/// The app delegate the SwiftUI app adapts, for the UIKit callbacks SwiftUI has no spelling of:
/// iOS relaunching the app because the models' background session finished, and a silent push
/// saying the log moved. It holds no state of its own; each callback hands off to what owns it.
final class TopoAppDelegate: NSObject, UIApplicationDelegate {
    @MainActor
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // No permission to ask for: a content-available push needs the device token and nothing
        // from the person.
        application.registerForRemoteNotifications()
        return true
    }

    /// Touching `ModelDownloads.shared` recreates the session under its identifier, which is what
    /// reconnects the delegate; the finished files are then delivered to it and admitted, and the
    /// handler is called after.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == ModelDownloads.identifier else { completionHandler(); return }
        Task { @MainActor in
            ModelDownloads.shared.completion = completionHandler
            ModelDownloads.shared.start()
        }
    }

    /// A subscription of ours firing, matched by its id and handed to whoever owns it: `TurnPush`
    /// to the answering screen, which runs the loop's next pass now, and `NotePush` to the
    /// memory, which syncs the folder. Each reaches nothing when no screen has installed its
    /// handler, and neither ever reaches the other's.
    @MainActor
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        if TurnPush.isOurs(userInfo) {
            guard let handler = PushWake.handler else { return .noData }
            await handler()
            return .newData
        }
        if NotePush.isOurs(userInfo) {
            guard let handler = MemoryWake.handler else { return .noData }
            await handler()
            return .newData
        }
        return .noData
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // Nothing to do and nothing to say: without a token the loop answers on its interval.
    }
}

/// Who a silent push wakes.
///
/// The screen that is answering installs a handler while its answering loop runs and takes it
/// away when the loop ends, so a push that arrives after sign-out or a takeover reaches nothing.
/// A wake is a nudge to a loop that is already running, never a way for the log to start a
/// harness nobody is watching.
@MainActor
enum PushWake {
    /// Installed by the answering screen. Nil whenever no screen is answering.
    static var handler: (@MainActor () async -> Void)?

    static func install(_ handler: @escaping @MainActor () async -> Void) {
        self.handler = handler
    }

    static func remove() {
        handler = nil
    }
}
