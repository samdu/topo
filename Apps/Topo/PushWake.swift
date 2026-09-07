import CloudKit
import Foundation
import UIKit

/// Where a silent push lands, and who it wakes.
///
/// The app delegate exists only for this: SwiftUI has no way to receive a
/// remote notification. It holds no state of its own — the screen that is
/// answering installs a handler while it stands and takes it away when it
/// goes, so a push that arrives after sign-out or a takeover reaches nothing.
/// That is deliberate: a wake is a nudge to a screen that is already working,
/// never a way for the log to start a harness nobody is watching.
@MainActor
enum PushWake {
    /// Installed by the answering screen. Nil whenever no screen is answering.
    /// Main-actor bound, like the harness it drives, so it crosses no
    /// isolation boundary and needs no sendability of its own.
    static var handler: (@MainActor () async -> Void)?

    static func install(_ handler: @escaping @MainActor () async -> Void) {
        self.handler = handler
    }

    static func remove() {
        handler = nil
    }
}

final class PushDelegate: NSObject, UIApplicationDelegate {
    @MainActor
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // No permission to ask for: a content-available push needs the device
        // token and nothing from the person.
        application.registerForRemoteNotifications()
        return true
    }

    @MainActor
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard TurnPush.isOurs(userInfo), let handler = PushWake.handler else { return .noData }
        await handler()
        return .newData
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // Nothing to do and nothing to say: without a token the loop answers
        // as it always has, a few seconds later.
    }
}
