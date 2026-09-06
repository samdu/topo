import SwiftUI
import TopoAuth
import TopoCore

/// The menu-bar hub: the only target that runs resident code. It holds the
/// primary lease, answers probes for it, shows a pairing code and the
/// devices on the Apple ID, and carries the Claude login for the mind. The
/// CLI and channel servers it will bundle are not here yet.
@main
struct TopoHubApp: App {
    @State private var signIn = SignIn()
    @State private var hub: HubModel

    /// The hub runs from launch, not from the first time the menu opens.
    init() {
        let model = HubModel()
        model.start()
        _hub = State(initialValue: model)
    }

    var body: some Scene {
        MenuBarExtra("Topo", systemImage: "circle.hexagongrid.fill") {
            HubMenu()
                .environment(signIn)
                .environment(hub)
        }
        .menuBarExtraStyle(.window)
    }
}

struct HubMenu: View {
    @Environment(SignIn.self) private var signIn
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
            DevicesList()
            Divider()
            DisclosureGroup("Pair a device", isExpanded: $showingCode) {
                PairingPane()
            }
            Divider()
            SignInSection()
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
        case .primary(let epoch):
            HStack(spacing: 6) {
                Label("Primary on this Mac", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.teal)
                Text("lease \(epoch)").font(.caption).foregroundStyle(.secondary)
            }
        case .held(let by):
            Label("Primary is \(hub.displayName(by))", systemImage: "iphone")
        case .unreachable(let by):
            Label("\(hub.displayName(by)) is primary and can't be reached from here", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.secondary)
        case .contended:
            Label("The lease is moving; trying again", systemImage: "arrow.triangle.2.circlepath")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
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

struct SignInSection: View {
    @Environment(SignIn.self) private var signIn
    @State private var webAuth = WebAuth()
    @State private var pasted = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch signIn.phase {
            case .signedIn:
                Label("Signed in with Claude", systemImage: "checkmark.circle.fill")
                Button("Sign out") { signIn.signOut() }
            case .idle:
                Button("Sign in with Claude") { webAuth.open(signIn.start()) { signIn.cancel() } }
            case .waiting(let pasteHint):
                if pasteHint {
                    TextField("Paste the code", text: $pasted)
                    Button("Continue") { Task { await signIn.finish(pasted: pasted) } }
                } else {
                    ProgressView("Waiting for Claude…")
                }
                Button("Cancel") { webAuth.close(); signIn.cancel() }
            case .exchanging:
                ProgressView("Signing in…")
            case .failed(let message):
                Text(message).foregroundStyle(.secondary)
                Button("Try again") { webAuth.open(signIn.start()) { signIn.cancel() } }
            }
        }
        .onChange(of: signIn.phase) { _, phase in
            if phase == .signedIn || { if case .failed = phase { true } else { false } }() { webAuth.close() }
        }
    }
}

extension HubModel {
    func displayName(_ id: DeviceID) -> String {
        devices.first { $0.id == id }?.name ?? id.rawValue
    }
}
