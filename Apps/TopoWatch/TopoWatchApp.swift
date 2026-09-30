import SwiftUI
import TopoAuth
import TopoCore
import WatchKit

@main
struct TopoWatchApp: App {
    @WKApplicationDelegateAdaptor(TopoWatchDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase
    @State private var signIn = SignIn(store: InMemoryTokenStore())
    @State private var transcript: TranscriptStore
    @State private var cues: WatchCues

    init() {
        let transcript = TranscriptStore(database: TopoCloudKit.database())
        let cues = WatchCues(transcript: transcript)
        _transcript = State(initialValue: transcript)
        _cues = State(initialValue: cues)
        // Set before any intent can run: a turn control's tap launches the app and performs its
        // intent here, and a drain left unset then is a cue waiting for the next time it opens.
        WatchIntents.drain = { await cues.drain() }
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(store: transcript).environment(signIn)
                .onOpenURL { url in Task { await cues.open(url) } }
        }
        .onChange(of: phase) { _, phase in
            if phase == .active { Task { await cues.drain() } }
        }
    }
}

/// The WatchKit callbacks SwiftUI has no spelling of: the `Surface` push and the background
/// refresh, each one fetch of the slots.
final class TopoWatchDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        WKApplication.shared().registerForRemoteNotifications()
        Task { @MainActor in
            WatchSurfaceSync.shared.scheduleRefresh()
            try? await SurfacePush.ensureSubscription()
        }
    }

    func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> WKBackgroundFetchResult {
        guard SurfacePush.isOurs(userInfo) else { return .noData }
        await WatchSurfaceSync.shared.pushed()
        return .newData
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            guard let refresh = task as? WKApplicationRefreshBackgroundTask else {
                task.setTaskCompletedWithSnapshot(false)
                continue
            }
            Task { @MainActor in
                await WatchSurfaceSync.shared.refreshed()
                refresh.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: any Error) {
        // Without a token the watch fetches when opened and on its refresh.
    }
}
