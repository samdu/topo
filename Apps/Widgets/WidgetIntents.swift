import AppIntents
import Foundation
import WidgetKit

/// What a control on one of the mind's widgets hands on when it is tapped, compiled into the app
/// and the extension alike so the widget can name them and the app can run them.
///
/// Two types, because whether an intent brings the app forward is a static property of its type:
/// a `turn` has to open Topo, and a `run` must not.
///
/// A `run` is a `LiveActivityIntent` because that is what runs in the app's process rather than
/// the extension's, with the app launched into the background if it is not running, and the app
/// is where the tool table, HomeKit's manager and EventKit's store are. Measured on the simulator
/// (the ledger's first ruling): a plain `AppIntent` from a widget runs in the extension, and
/// `ForegroundContinuableIntent` is unavailable in an extension at all.
#if os(watchOS)
/// What a tap on the watch's widgets hands on. The watch runs no widget intent in the app without
/// bringing it forward (`LiveActivityIntent` is not on watchOS), so both of these open `TopoWatch`.
enum WatchIntents {
    /// Set by `TopoWatchApp` at launch: puts what the cue intent recorded on the line.
    @MainActor static var drain: (@MainActor () async -> Void)?
}

/// A `turn` control on the watch: records the cue in the watch's group under a nonce minted here
/// and brings Topo forward, whose drain sends it (`WatchCues`).
struct WatchCueIntent: AppIntent {
    static let title: LocalizedStringResource = "Tell Topo"
    static let openAppWhenRun = true
    static let isDiscoverable = false

    @Parameter(title: "Slot") var slot: String
    @Parameter(title: "Control") var control: String
    @Parameter(title: "Revision") var revision: Int
    @Parameter(title: "Turning on") var turningOn: Bool?

    init() {}

    init(slot: String, control: String, revision: Int, turningOn: Bool? = nil) {
        self.slot = slot
        self.control = control
        self.revision = revision
        self.turningOn = turningOn
    }

    func cue(nonce: String = UUID().uuidString, at time: Date = Date()) -> SurfaceStore.Cue {
        SurfaceStore.Cue(nonce: nonce, slot: slot, id: control, revision: revision, turningOn: turningOn, time: time)
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let store = SurfaceStore.shared() { _ = try store.recordCue(cue()) }
        await WatchIntents.drain?()
        return .result()
    }
}

/// Every other control on the watch: opens Topo, and nothing else.
struct WatchOpenIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Topo"
    static let openAppWhenRun = true
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult { .result() }
}
#else
enum WidgetIntents {
    /// What a tap does in the app, set by `TopoApp` at launch, which the system finishes before an
    /// intent it launched the app for runs. Nil in the extension, which never runs either intent.
    @MainActor static var handler: (any WidgetTapHandler)?
}

/// The app's side of a tap.
@MainActor
protocol WidgetTapHandler: AnyObject {
    /// A `turn` control's tap, recorded in the app group under its nonce (`recorded`, false where
    /// the process has no app group): put what is pending on the line.
    func cued(_ cue: SurfaceStore.Cue, recorded: Bool) async
    /// A `run` control's tap: judge the revision, run the call, record the status.
    func run(slot: String, control: String, revision: Int, turningOn: Bool?) async
}

/// A `turn` control: records the cue in the app group under a nonce minted here and brings Topo
/// forward, where the drain puts it on the line (`WidgetCues`).
struct WidgetCueIntent: AppIntent {
    static let title: LocalizedStringResource = "Tell Topo"
    static let openAppWhenRun = true
    static let isDiscoverable = false

    @Parameter(title: "Slot") var slot: String
    @Parameter(title: "Control") var control: String
    @Parameter(title: "Revision") var revision: Int
    @Parameter(title: "Turning on") var turningOn: Bool?

    init() {}

    init(slot: String, control: String, revision: Int, turningOn: Bool? = nil) {
        self.slot = slot
        self.control = control
        self.revision = revision
        self.turningOn = turningOn
    }

    /// The cue this tap records: which control, at which revision, and never words.
    func cue(nonce: String = UUID().uuidString, at time: Date = Date()) -> SurfaceStore.Cue {
        SurfaceStore.Cue(nonce: nonce, slot: slot, id: control, revision: revision, turningOn: turningOn, time: time)
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let cue = cue()
        var recorded = false
        if let store = SurfaceStore.shared() {
            recorded = try store.recordCue(cue)
        }
        await WidgetIntents.handler?.cued(cue, recorded: recorded)
        return .result()
    }
}

/// A `run` control: one `topo` call from the allowlist, run in the app with no turn.
struct WidgetRunIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Run Topo's control"
    static let isDiscoverable = false

    @Parameter(title: "Slot") var slot: String
    @Parameter(title: "Control") var control: String
    @Parameter(title: "Revision") var revision: Int
    @Parameter(title: "Turning on") var turningOn: Bool?

    init() {}

    init(slot: String, control: String, revision: Int, turningOn: Bool? = nil) {
        self.slot = slot
        self.control = control
        self.revision = revision
        self.turningOn = turningOn
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await WidgetIntents.handler?.run(slot: slot, control: control, revision: revision, turningOn: turningOn)
        return .result()
    }
}
#endif

/// The URLs the widgets open: `topo://open`, and `topo://cue?…` for a `link` whose action is a
/// turn, since a `Link` hands on a URL and no intent.
enum WidgetURL {
    static let scheme = "topo"
    static let open = URL(string: "topo://open")!

    static func cue(slot: String, control: String, revision: Int) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "cue"
        parts.queryItems = [URLQueryItem(name: "slot", value: slot), URLQueryItem(name: "control", value: control),
                            URLQueryItem(name: "revision", value: String(revision))]
        return parts.url!
    }

    /// The cue a `topo://cue` URL carries, under a nonce minted as it is read. Anything else the
    /// URL carries is ignored: the words are the document's.
    static func cue(from url: URL, nonce: String = UUID().uuidString, at time: Date = Date()) -> SurfaceStore.Cue? {
        guard url.scheme == scheme, url.host == "cue",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let slot = value("slot"), let control = value("control"),
              let revision = value("revision").flatMap(Int.init) else { return nil }
        return SurfaceStore.Cue(nonce: nonce, slot: slot, id: control, revision: revision, time: time)
    }
}

/// The one thing a placed widget is configured with: which of the mind's slots it shows.
struct SurfaceConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Topo"
    static let description = IntentDescription("Which of Topo's widgets this one shows.")

    @Parameter(title: "Widget", optionsProvider: SlotOptions())
    var slot: String?

    init() {}

    init(slot: String) {
        self.slot = slot
    }
}

/// The slots in the app group, listed as the person places a widget.
struct SlotOptions: DynamicOptionsProvider {
    func results() async throws -> [String] {
        SurfaceStore.shared()?.slots() ?? []
    }
}

extension WidgetFamilyName {
    init(_ family: WidgetFamily) {
        switch family {
        case .systemSmall: self = .systemSmall
        case .systemMedium: self = .systemMedium
        case .systemLarge, .systemExtraLarge: self = .systemLarge
        case .accessoryCircular: self = .accessoryCircular
        case .accessoryRectangular: self = .accessoryRectangular
        case .accessoryInline: self = .accessoryInline
        #if os(watchOS)
        case .accessoryCorner: self = .accessoryCorner
        #endif
        default: self = .default
        }
    }
}
