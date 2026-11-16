import AppKit
import OSLog
import SwiftUI
import TopoAuth
import TopoCore
import TopoLink
import TopoMind
import TopoTurn

/// The menu-bar hub: the only target that runs resident code. It answers
/// probes for the lease, shows a pairing code and the devices on the Apple
/// ID, and serves the house's screens; with its switch on it runs the mind
/// (`HubMind`), a native Claude Code on this Mac whose login is made by hand
/// in the mind's own config directory.
@main
struct TopoHubApp: App {
    @NSApplicationDelegateAdaptor(HubAppDelegate.self) private var delegate
    @State private var hub: HubModel

    /// The hub runs from launch, not from the first time the menu opens. The Claude.ai tokens an
    /// earlier build kept in the keychain go at the first launch: nothing here signs in now.
    init() {
        LoginMigration.run { item, error in
            Logger(subsystem: "zone.hexagon.topo.hub", category: "auth")
                .error("login migration: the keychain kept \(item.account, privacy: .public) (\(String(describing: error), privacy: .public)); tried again next launch")
        }
        let model = HubModel()
        HubAppDelegate.hub = model
        model.start()
        _hub = State(initialValue: model)
    }

    var body: some Scene {
        MenuBarExtra("Topo", systemImage: "circle.hexagongrid.fill") {
            HubMenu()
                .environment(hub)
        }
        .menuBarExtraStyle(.window)
    }
}

struct HubMenu: View {
    @Environment(HubModel.self) private var hub
    @State private var showingCode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                OctopusMark().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Topo Hub").font(.headline)
                    Text(hub.name).font(.caption).foregroundStyle(.secondary)
                }
            }
            StatusLine()
            Divider()
            MindSection()
            Divider()
            DevicesList()
            Divider()
            SurfacesList()
            Divider()
            DisclosureGroup("Pair a device", isExpanded: $showingCode) {
                PairingPane()
            }
            Divider()
            HStack {
                if hub.store == .memory {
                    Text("Unsigned build: records live in memory").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 320)
    }
}

/// One line on the lease: whether this Mac is primary, and if not, who is.
struct StatusLine: View {
    @Environment(HubModel.self) private var hub

    var body: some View {
        switch hub.status {
        case .starting:
            Label("Starting…", systemImage: "circle.dotted")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        case .up:
            if hub.mind?.holds == true {
                Label("Primary on this Mac", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.teal)
            } else if let holder = hub.leaseHolder {
                Label("Primary is \(hub.displayName(holder))", systemImage: "iphone")
            } else {
                Label("No device is primary right now", systemImage: "circle.dotted").foregroundStyle(.secondary)
            }
        }
    }
}

/// The mind on this Mac: the switch, the model it answers with, and one or two lines on where it
/// stands — signed in or not, its process, and the last pass.
struct MindSection: View {
    @Environment(HubModel.self) private var hub

    var body: some View {
        @Bindable var hub = hub
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Run the mind on this Mac", isOn: Binding(get: { hub.mindOn }, set: { hub.setMind($0) }))
                .toggleStyle(.switch)
                .help("This Mac answers your turns while it is awake. Off, the phone answers.")
            if hub.mindOn {
                Picker("Model", selection: $hub.model) {
                    ForEach(ClaudeModel.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                if let pinned = ClaudeModel.pinned {
                    Text("Debug build: every turn goes to \(pinned.displayName)").font(.caption2).foregroundStyle(.secondary)
                }
                phaseLine
                if let mind = hub.mind {
                    Text(mind.mind).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    if let pass = mind.lastPass {
                        Text("Last pass \(Self.words(pass.outcome)), \(pass.at.formatted(date: .omitted, time: .standard)), by \(pass.trigger.rawValue)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var phaseLine: some View {
        switch hub.mind?.phase {
        case nil, .off?:
            Label("Starting…", systemImage: "circle.dotted")
        case .starting?:
            Label("Starting the mind…", systemImage: "circle.dotted")
        case .answering?:
            Label(hub.mind?.holds == true ? "Answering on this Mac" : "Waiting for the lease; the phone answers",
                  systemImage: hub.mind?.holds == true ? "brain" : "hourglass")
            if let login = hub.mind?.login, case .signedIn(let summary) = login {
                Text("Signed in: \(summary)").font(.caption2).foregroundStyle(.secondary)
            }
        case .asleep?:
            Label("Asleep; the phone answers", systemImage: "moon")
        case .stopped(let stop)?:
            VStack(alignment: .leading, spacing: 2) {
                Label(Self.words(stop), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                if stop == .signedOut {
                    Text(hub.signInCommand)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
                Button("Try again") { hub.tryMindAgain() }
            }
        }
    }

    static func words(_ stop: HubMind.Stop) -> String {
        switch stop {
        case .signedOut: "Not signed in, so the phone answers. Sign the mind in in Terminal:"
        case .loginUnknown(let why): "Could not ask Claude Code whether it is signed in: \(why)"
        case .notStarted(let why): "Claude Code could not be started: \(why)"
        case .ledgerUnreadable(let why): "The mind's record could not be read: \(why)"
        case .home(let why): "The mind's home could not be made: \(why)"
        }
    }

    static func words(_ outcome: HubMind.Pass.Outcome) -> String {
        switch outcome {
        case .nothing: "found nothing to answer"
        case .answered: "answered"
        case .elsewhere: "found another device answering"
        case .displaced: "lost the lease as it answered"
        case .failed(let kind): "failed (\(kind))"
        }
    }
}

/// Every device on the Apple ID: paired with this Mac or not, on the LAN
/// or not, and which one holds the lease.
struct DevicesList: View {
    @Environment(HubModel.self) private var hub

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Devices").font(.subheadline.weight(.semibold))
            if hub.devices.isEmpty {
                Text("None yet. Pair a phone to begin.").font(.caption).foregroundStyle(.secondary)
            }
            if hub.lanFailure != nil {
                Label("Not allowed on the local network, so nothing here can be seen or found by name", systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(hub.devices) { device in
                HStack(spacing: 8) {
                    Image(systemName: icon(for: device.kind)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.id == hub.device ? "\(device.name) (this Mac)" : device.name)
                        Text(detail(device)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if hub.leaseHolder == device.id {
                        Image(systemName: "crown.fill").foregroundStyle(Theme.teal).help("Holds the primary lease")
                    }
                    Circle()
                        .fill(hub.onLAN.contains(device.id) || device.id == hub.device ? Theme.teal : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .help(hub.onLAN.contains(device.id) ? "On this network" : "Not seen on this network")
                }
            }
        }
    }

    private func icon(for kind: Device.Kind) -> String {
        switch kind {
        case .mac: "desktopcomputer"
        case .phone: "iphone"
        case .pad, .womble: "ipad"
        case .watch: "applewatch"
        case .tv: "appletv"
        }
    }

    private func detail(_ device: Device) -> String {
        var parts: [String] = []
        if device.id != hub.device {
            parts.append(device.isPaired(with: hub.device) ? "Paired" : "Not paired")
        }
        parts.append("Seen \(device.seenAt.formatted(.relative(presentation: .named)))")
        return parts.joined(separator: " · ")
    }
}

/// The screens in the house: what each is called, who it answers for, and
/// the button that asks it to answer for this hub. Registering is the room's
/// decision, so the button's ordinary answer is that the question is now on
/// the screen and somebody there has to say yes.
struct SurfacesList: View {
    @Environment(HubModel.self) private var hub

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Screens").font(.subheadline.weight(.semibold))
            if let failure = hub.surfaces.failure {
                Label(failure, systemImage: "wifi.slash").font(.caption).foregroundStyle(.secondary)
            } else if hub.surfaces.surfaces.isEmpty {
                Text("None on this network. A Womble advertises itself while it is on screen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(hub.surfaces.surfaces) { surface in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "rectangle.on.rectangle").frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(surface.name)
                        Text(detail(surface)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    action(for: surface)
                }
                if hub.pages.isRevoked(surface.device), hub.surfaces.isRegistered(hub.device, with: surface) {
                    HStack(spacing: 6) {
                        Text("Revoked. It is still on this screen's roster.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Serve again") { hub.pages.serveAgain(surface.device, named: surface.name) }
                            .help("Serves this screen again, at a new address")
                    }
                    .padding(.leading, 26)
                } else if let address = hub.pages.address(for: surface.device, host: hub.lanAddress) {
                    HStack(spacing: 6) {
                        Text(address.absoluteString)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Revoke") { hub.pages.revoke(surface.device) }
                            .help("Stops this screen showing what it is showing. It can be registered again.")
                    }
                    .padding(.leading, 26)
                }
            }
            if let failure = hub.pages.failure {
                Label("Not serving screen pages: \(failure)", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let trouble = hub.pages.tokenTrouble {
                Label("Screens' addresses: \(trouble)", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func action(for surface: Surface) -> some View {
        if hub.surfaces.isRegistered(hub.device, with: surface) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal).help("This hub is on its roster")
        } else {
            switch hub.surfaces.registrations[surface.device] {
            case .asking:
                ProgressView().controlSize(.small)
            case .waiting:
                Button("Ask again") { ask(surface) }.help("Tap Register on the screen itself, then ask again")
            case .refused(let reason):
                Button("Ask again") { ask(surface) }.help(reason)
            case .failed(let message):
                Button("Try again") { ask(surface) }.help(message)
            case .registered, .none:
                Button("Register") { ask(surface) }.disabled(hub.pairingCode == nil)
            }
        }
    }

    private func ask(_ surface: Surface) {
        guard let code = hub.pairingCode else { return }
        Task { await hub.surfaces.register(code, with: surface) }
    }

    private func detail(_ surface: Surface) -> String {
        let agents = hub.surfaces.agents(of: surface)
        var parts = [agents.isEmpty ? "No agents registered" : "\(agents.count) registered"]
        if case .waiting = hub.surfaces.registrations[surface.device] {
            parts.append("waiting for someone in the room")
        }
        return parts.joined(separator: " · ")
    }
}

/// The code a phone scans: the hub's identity, so the scanner can check the
/// record it finds against the screen in front of it.
struct PairingPane: View {
    @Environment(HubModel.self) private var hub

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let code = hub.pairingCode, let image = QRImage.render(code.url.absoluteString) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
                    .frame(maxWidth: .infinity)
                Text("Open Topo on your iPhone and point it at this code.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(code.device.rawValue).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            } else {
                Text("Waiting for this Mac's record…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }
}

/// What the system tells the hub: the push that a turn was created, and quit.
final class HubAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var hub: HubModel?
    private static let log = Logger(subsystem: "zone.hexagon.topo.hub", category: "push")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Silent pushes need no permission. Registering touches no record; the subscription the
        // pushes come from is saved only against the real store, with the mind on.
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.log.notice("registered for remote notifications")
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        Self.log.error("remote notifications: \(String(describing: error), privacy: .public)")
    }

    @MainActor
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard HubPush.isOurs(userInfo) else { return }
        Self.hub?.pushed()
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let hub = Self.hub else { return .terminateNow }
        Task {
            await hub.quit()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

extension HubModel {
    func displayName(_ id: DeviceID) -> String {
        devices.first { $0.id == id }?.name ?? id.rawValue
    }
}
