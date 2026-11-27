import AppKit
import CloudKit
import CryptoKit
import Foundation
import Observation
import os
import Security
import TopoAuth
import TopoCore
import TopoCoreTesting
import TopoLink
import TopoMind
import TopoTools
import TopoTurn

/// The hub's standing state: its own device record, the probe listener that
/// answers for the lease, the mind when it is on (`HubMind`), and what it
/// knows of the other devices. One instance for the life of the process.
@MainActor
@Observable
final class HubModel {
    enum Status: Equatable {
        case starting
        case up
        case failed(String)
    }

    typealias Store = HubLaunch.Store

    /// This Mac's device ID, read from the keychain at launch and, while it
    /// cannot be, at every try of `bringUp`; nothing registers, claims or
    /// serves until it is read.
    private(set) var device: DeviceID
    private var identityRead: Bool
    let name: String
    let store: Store
    private(set) var status: Status = .starting
    private(set) var devices: [Device] = []
    private(set) var onLAN: Set<DeviceID> = []
    /// Set when the Bonjour browse cannot run, which on macOS means the app
    /// has not been allowed on the local network.
    private(set) var lanFailure: String?
    private(set) var pairingCode: PairingCode?
    private(set) var port: UInt16?
    /// The screens in the house. A browse of the same Bonjour type the lease
    /// probe advertises on; the TXT record is what tells one from a device.
    let surfaces = SurfacesModel()
    /// The web-page Wombles this Mac serves, and the token each is served
    /// under. Made in `init` because its reader is this hub's databases.
    private(set) var pages: SurfacePages!

    /// Whether the mind runs on this Mac: the menu's switch, off by default, kept in the hub's
    /// defaults (`MindSwitch`, under `HubLaunch.switchKey`), where a shell sets it too
    /// (`scripts/hub-mind.sh`). The in-memory store keeps a key of its own, so a run against
    /// nothing real never leaves the real switch on.
    private(set) var mindOn: Bool
    /// What the mind last said of itself; nil until it is made.
    private(set) var mind: HubMind.Snapshot?
    /// The model the mind answers with: the phone's choices and default, kept on this Mac.
    var model: ClaudeModel {
        didSet { UserDefaults.standard.set(model.rawValue, forKey: Self.modelKey) }
    }
    /// Whether a phone that nudges this Mac is sent its turn's reply as the mind writes it, over
    /// the nudge's channel (`ReplyFrame`, `NudgeKey`, `docs/hub.md`, *The reply as it is written*):
    /// on by default, kept in the hub's defaults under `streamKey`.
    var streams: Bool {
        didSet { UserDefaults.standard.set(streams, forKey: Self.streamKey) }
    }
    /// The lease as last read, for the menu; the mind's own decides everything.
    private(set) var lease: Lease?
    /// The command that signs the mind's Claude Code in, for the menu to show.
    let signInCommand: String
    /// Where the mind's home is.
    let mindRoot: URL

    nonisolated static let modelKey = "model"
    nonisolated static let streamKey = "stream.replies"
    /// The switch as the defaults hold it, read off the main actor by each nudge: on unless set off.
    nonisolated static var streamsNow: Bool { UserDefaults.standard.object(forKey: streamKey) as? Bool ?? true }

    private static let log = Logger(subsystem: "zone.hexagon.topo.hub", category: "hub")
    private let database: any RecordDatabase
    private let directory: DeviceDirectory
    private let presence = LANPresence()
    private let mindConfiguration: NativeBrain.Configuration
    private let launch: HubLaunch
    private var hubMind: HubMind?
    private var mindSwitch: MindSwitch?
    private var server: LeaseProbeServer?
    /// This launch's key for the nudge's channel, at its listener's port, and whether its record
    /// has been saved: minted once a launch, never logged.
    private var nudgeKey: NudgeKey?
    /// The router's public port onto the nudge's channel, for a phone off the home network.
    private let portMapping = HubPortMapping()
    /// The mind's `topo` (`HubTools`), on the loopback.
    private var tools: ToolService?
    private var nudgeKeySaved = false
    /// The kind of the last failure to save the key's record, while it is not saved.
    private(set) var nudgeKeyFailure: String?
    /// Handshakes the channel's listener has seen fail since launch, as last read.
    private(set) var handshakesFailed = 0
    private var loop: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var signals: [DispatchSourceSignal] = []
    private var signalledAsleep = false
    private var subscribed = false

    /// CloudKit when the bundle carries the iCloud entitlement, otherwise the
    /// testing package's in-memory store: an unsigned build runs, shows every
    /// screen and takes the lease against itself, and says which it is.
    init() {
        do {
            device = try HubIdentity.deviceID()
            identityRead = true
        } catch {
            device = DeviceID("")
            identityRead = false
            Self.log.error("hub identity unreadable: \(String(describing: error), privacy: .public)")
        }
        name = Host.current().localizedName ?? "Mac"
        launch = HubLaunch(environment: ProcessInfo.processInfo.environment, entitled: HubIdentity.hasCloudKitEntitlement)
        store = launch.store
        // The smoke-test controls reach the in-memory store alone (`HubLaunch`, and its suite).
        precondition(launch.controls == nil || store == .memory, "smoke-test controls on the real store")
        database = store == .cloudKit ? CloudKitRecordDatabase() : InMemoryRecordDatabase()
        // The first line the hub writes: which records it is about to touch.
        Self.log.notice("hub store \(self.store.rawValue, privacy: .public)")
        model = UserDefaults.standard.string(forKey: Self.modelKey).flatMap(ClaudeModel.init(setting:)) ?? .default
        streams = Self.streamsNow
        mindOn = MindSwitch.persisted(key: launch.switchKey)
        if store == .cloudKit {
            mindRoot = MindHome.root
            mindConfiguration = MindHome.configuration()
        } else {
            // A mind over records that live in memory keeps a home of its own: its ledger names
            // turns no real log has. The controls name the `claude` it runs and its silence bound.
            mindRoot = MindHome.root.deletingLastPathComponent().appending(path: "Topo Hub (memory store)", directoryHint: .isDirectory)
            var configuration = MindHome.configuration(work: mindRoot.appending(path: "home"),
                                                       config: mindRoot.appending(path: "claude"),
                                                       claude: launch.controls?.claude ?? NativeBrain.Configuration.defaultClaude)
            if let silence = launch.controls?.silence { configuration.silenceBound = silence }
            mindConfiguration = configuration
        }
        signInCommand = "CLAUDE_CONFIG_DIR='\(mindConfiguration.configDirectory?.path ?? "")' \(mindConfiguration.claude.path) auth login --claudeai"
        directory = DeviceDirectory(database: database)
        let log = TurnLog(database: database)
        pages = SurfacePages { [store] in
            let transcript = try? await log.read()
            let board = try? await Self.board(store: store)?.read()
            guard let transcript else {
                // A read that failed is a document that says so, never a
                // 404: the page treats 404 as "this screen is revoked" and
                // clears itself, and a hiccup must not do that.
                return SurfaceDocument(
                    house: nil,
                    transcript: .init(complete: false,
                                      notice: "The hub could not read the log just now.",
                                      turns: []),
                    board: .init(cards: []))
            }
            return SurfaceDocument(house: nil, transcript: transcript,
                                   notice: Self.notice(transcript: transcript, board: board),
                                   board: board ?? Board(revisions: []))
        }
    }

    /// The board is its own container, shared across the household's Apple
    /// IDs; an unsigned build has neither and serves an empty one.
    private nonisolated static func board(store: Store) async throws -> BoardStore? {
        guard store == .cloudKit else { return nil }
        return BoardStore(database: try await TopoBoard.database())
    }

    /// What the page shows above the turns. A read that could not be
    /// finished says so; so does a board that could not be read, because a
    /// noticeboard short by its tail looks complete.
    private nonisolated static func notice(transcript: Transcript, board: Board?) -> String? {
        if !transcript.isComplete { return "Some turns aren't here yet. What arrived is below." }
        if transcript.isForked { return "Two devices carried on from the same point. Both are below." }
        if board == nil { return "The hub could not read the board just now." }
        if let board, !board.isComplete { return "Some of the board isn't here yet." }
        return nil
    }

    func start() {
        guard loop == nil else { return }
        watchSleep()
        listenForSignals()
        writeStatus()
        loop = Task { await run() }
    }

    /// What another process can ask of a running hub by its pid. SIGUSR1: follow the switch in
    /// the defaults now rather than at the next refresh (`scripts/hub-mind.sh`; idempotent, never
    /// a flip). SIGTERM: quit as the menu's Quit does, so the lease is let go and the mind's
    /// process reaped before the hub exits, within 10 s. On the in-memory store alone, SIGUSR2
    /// posts the workspace's will-sleep, then its did-wake, in turn, to the observers the real
    /// ones reach.
    private func listenForSignals() {
        signal(SIGUSR1, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let follow = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        follow.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Self.log.notice("mind: asked to follow the switch")
                Task { await self.followSwitch() }
            }
        }
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in
            Self.log.notice("hub: SIGTERM, quitting")
            // Off the main queue, which the quit itself needs.
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                Self.log.error("hub: the quit was not done within 10 s; exiting")
                exit(0)
            }
            // Not NSApplication.terminate: called from a main-queue handler, its wait for the
            // quit's reply blocks the very queue the quit runs on. Quit's work, then the exit.
            Task { @MainActor in
                await self?.quit()
                Self.log.notice("hub: quit after SIGTERM")
                exit(0)
            }
        }
        follow.resume()
        term.resume()
        signals = [follow, term]
        guard launch.controls != nil else { return }
        signal(SIGUSR2, SIG_IGN)
        let sleep = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        sleep.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let name = self.signalledAsleep ? NSWorkspace.didWakeNotification : NSWorkspace.willSleepNotification
                self.signalledAsleep.toggle()
                NSWorkspace.shared.notificationCenter.post(name: name, object: nil)
            }
        }
        sleep.resume()
        signals.append(sleep)
    }

    /// The menu's switch. On takes the lease over and starts the mind; off stops renewing the
    /// lease at once, stops the loop and shuts the mind's process down, and the phone answers
    /// once the lease lapses. Kept in the defaults before it is applied.
    func setMind(_ on: Bool) {
        guard on != mindOn else { return }
        mindOn = on
        // Kept first, so a follow that runs meanwhile (the refresh, SIGUSR1) reads this and not
        // what it replaces. Before the mind is made the switch is only kept; it is followed once made.
        MindSwitch.keep(on, key: launch.switchKey)
        Self.log.notice("mind switched \(on ? "on" : "off", privacy: .public)")
        writeStatus()
        Task { await followSwitch() }
    }

    /// Brings the mind to the switch the defaults hold, which a shell may have set: at launch once
    /// the mind is made, at every refresh, and at SIGUSR1.
    private func followSwitch() async {
        guard let mindSwitch else { return }
        let on = await mindSwitch.follow()
        if on != mindOn {
            Self.log.notice("mind switched \(on ? "on" : "off", privacy: .public) by the defaults")
            mindOn = on
        }
        if on { await subscribe() }
        writeStatus()
    }

    /// The status a shell reads (`HubStatus`, `scripts/hub-mind.sh status`). A write that fails is
    /// logged and left: the next change writes it again.
    private func writeStatus() {
        let status = HubStatus(pid: getpid(), store: store, on: mindOn, snapshot: mind, leaseHolder: leaseHolder?.rawValue,
                               nudgeKey: nudgeKeyState, handshakesFailed: nudgeKey == nil ? nil : handshakesFailed)
        do {
            try status.write(in: mindRoot)
        } catch {
            Self.log.error("hub status not written: \(String(describing: error), privacy: .public)")
        }
    }

    /// A mind that stopped (signed out, could not start, stalled) starts again from its login.
    func tryMindAgain() {
        guard let hubMind else { return }
        Task { await hubMind.tryAgain() }
    }

    /// A push of the hub's subscription: the loop's next pass now.
    func pushed() {
        Perf.mark("hub.push.received")
        guard let hubMind else { return }
        Task { await hubMind.trigger(.push) }
    }

    /// Quit: the mind's process ends and the lease is let go before the app does.
    func quit() async {
        await hubMind?.shutdown()
    }

    /// Sleep stops the mind's loop and lets the lease go before the Mac sleeps; wake takes it
    /// over again. The sleep's work is waited for, a bounded moment, on the notification's own
    /// thread, so the lease is abandoned before the system goes on to sleep.
    private func watchSleep() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let mind = self?.hubMind else { return }
                Self.log.notice("mind: the Mac is going to sleep")
                let done = DispatchSemaphore(value: 0)
                Task.detached {
                    await mind.willSleep()
                    done.signal()
                }
                if done.wait(timeout: .now() + 2) == .timedOut {
                    Self.log.error("mind: sleep's stop was not done within 2 s")
                }
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let mind = self?.hubMind else { return }
                Self.log.notice("mind: the Mac woke")
                Task { await mind.didWake() }
            }
        })
    }

    /// The hub's push subscription, saved once a launch with the mind on, against the real store
    /// only. A failure is logged and left: the poll answers without it.
    private func subscribe() async {
        guard store == .cloudKit, mindOn, !subscribed else { return }
        do {
            let outcome = try await HubPush.ensureSubscription()
            subscribed = true
            Self.log.notice("push subscription \(HubPush.subscriptionID, privacy: .public) \(outcome.described, privacy: .public)")
        } catch {
            Self.log.error("push subscription failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Brings the hub up, retrying with backoff until it is, then takes the
    /// lease and keeps the device list fresh for the life of the process. A
    /// CloudKit or network outage at launch is a delay, not a verdict.
    private func run() async {
        var delay: TimeInterval = 2
        while !Task.isCancelled {
            do {
                try await bringUp()
                break
            } catch {
                Self.log.error("hub start failed, retrying in \(delay)s: \(String(describing: error), privacy: .public)")
                status = .failed("\(error)")
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 60)
            }
        }
        status = .up
        while !Task.isCancelled {
            if let key = nudgeKey, key.publicEndpoint != portMapping.endpoint {
                nudgeKey = key.reached(at: portMapping.endpoint)
                nudgeKeySaved = false
                Self.log.notice("hub channel's public endpoint now \(self.portMapping.endpoint ?? "none", privacy: .public)")
            }
            await saveNudgeKey()
            await followSwitch()
            await refreshLease()
            handshakesFailed = await server?.handshakesFailed ?? 0
            writeStatus()
            await refreshDevices()
            await surfaces.refresh()
            // A screen this hub is on the roster of is a screen it serves a
            // page to, however it got there: the tap happened in the room.
            pages.reload()
            for surface in surfaces.surfaces where surfaces.isRegistered(device, with: surface) {
                pages.mint(for: surface.device, named: surface.name)
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }

    /// Ensures the zone, opens the probe listener, registers the device and
    /// makes the lease. Each step keeps what it made, so a retry after a
    /// failure picks up where it stopped.
    private func bringUp() async throws {
        if !identityRead {
            device = try HubIdentity.deviceID()
            identityRead = true
        }
        if let ck = database as? CloudKitRecordDatabase { try await ck.ensureZone() }
        if server == nil {
            let key = NudgeKey.mint(hub: device)
            let server = try LeaseProbeServer(advertising: device, key: key, holds: { [weak self] holder, epoch in
                guard let self else { return false }
                return await self.holds(holder, epoch: epoch)
            }, nudged: { [weak self] holder, epoch, mark, stream in
                guard let self else { return false }
                return await self.nudged(holder, epoch: epoch, mark: mark, stream: stream)
            }, coming: { [weak self] holder, epoch, mark in
                guard let self else { return nil }
                return await self.headsUp(holder, epoch: epoch, mark: mark)
            })
            port = try await server.start()
            nudgeKey = key.on(port: await server.securePort ?? 0)
            // The router's mapping before the key's first save, so a phone that reads this
            // launch's key has the public endpoint with it; a router that answers in 3 s or not at
            // all leaves it out until the run loop sees one.
            if let channel = nudgeKey?.port, channel != 0, portMapping.start(port: channel) {
                for _ in 0..<30 where portMapping.endpoint == nil { try? await Task.sleep(for: .milliseconds(100)) }
                nudgeKey = nudgeKey?.reached(at: portMapping.endpoint)
            }
            Self.log.notice("hub channel's public endpoint \(self.nudgeKey?.publicEndpoint ?? "none", privacy: .public)")
            self.server = server
            Self.log.notice("hub \(self.device.rawValue, privacy: .public) listening on \(self.port ?? 0), the nudge's channel on \(self.nudgeKey?.port ?? 0), store \(self.store.rawValue, privacy: .public)")
        }
        // The key's record before the mind is made, so a phone that finds this launch's lease
        // finds its key. A save that fails holds up nothing: the mind is made all the same, a
        // phone finds no key or the last launch's and sends no nudge, and the run loop saves it.
        await saveNudgeKey()
        let endpoints = HubIdentity.addresses().map { "\($0):\(port ?? 0)" }
        let record = try await directory.register(Device(
            id: device, name: name, kind: .mac, publicKey: try HubIdentity.publicKey(),
            endpoints: endpoints, registeredAt: Date(), seenAt: Date()))
        pairingCode = PairingCode(record)
        if tools == nil, store == .cloudKit {
            let directory = directory
            let records = database
            // The directory holds the devices that registered (the Macs, the surfaces). A phone or
            // a pad is known by its role record, and the primary among them is "the phone".
            let everyDevice: @Sendable () async -> [Device] = {
                var all = (try? await directory.all()) ?? []
                let roles = ((try? await records.records(ofType: DeviceRole.recordType)) ?? []).compactMap(DeviceRole.init(record:))
                for role in roles where !all.contains(where: { $0.id == role.device }) && role.device.rawValue.hasPrefix("ios-") {
                    all.append(Device(id: role.device, name: role.role == .primary ? "the primary phone" : "a viewer",
                                      kind: role.role == .primary ? .phone : .pad, publicKey: "", endpoints: [],
                                      registeredAt: role.at, seenAt: role.at))
                }
                return all
            }
            let token = ToolService.newToken()
            let service = try ToolService(tools: [
                DeviceTool(hub: device, database: database, devices: everyDevice, alertAfter: {
                    UserDefaults.standard.object(forKey: "call.alertAfter") as? Double ?? 6
                }),
                AlertTool(hub: device, database: database),
                DevicesTool(devices: everyDevice),
            ], token: token, bound: .seconds(190))
            let port = try await service.start()
            try HubTools.install(port: port, token: token, root: mindRoot,
                                 config: mindConfiguration.configDirectory ?? mindConfiguration.stateDirectory)
            tools = service
            Self.log.notice("hub tools on \(port)")
        }
        if hubMind == nil {
            makeMind(endpoint: endpoints.first)
            await sayAsALimb()
            await followSwitch()
            await presence.start()
            await presence.observe { [weak self] names in
                Task { @MainActor in self?.onLAN = names }
            }
            await surfaces.start()
            await pages.start()
        }
    }

    /// Saves this launch's key for the nudge's channel until a save lands, with the same key each
    /// time; a failure is logged by its kind, never with the key.
    private func saveNudgeKey() async {
        guard !nudgeKeySaved, let nudgeKey else { return }
        do {
            try await nudgeKey.save(to: database)
            nudgeKeySaved = true
            nudgeKeyFailure = nil
            Self.log.notice("hub nudge key saved")
        } catch {
            nudgeKeyFailure = NudgeKey.kind(of: error)
            Self.log.error("hub nudge key not saved (\(NudgeKey.kind(of: error), privacy: .public)), nudges go unanswered until it is")
        }
    }

    /// Whether this launch's key for the nudge's channel is saved, for the status and the menu:
    /// `saved`, `not saved` with the last failure's kind, or nil before the channel is made.
    var nudgeKeyState: String? {
        guard nudgeKey != nil else { return nil }
        if nudgeKeySaved { return "saved" }
        return "not saved" + (nudgeKeyFailure.map { " (\($0))" } ?? "")
    }

    /// The mind, made once the probe listener's endpoint is known; it claims nothing until it is
    /// turned on.
    private func makeMind(endpoint: String?) {
        let configuration = mindConfiguration
        let work = configuration.workingDirectory
        let config = configuration.configDirectory ?? configuration.stateDirectory
        let mind = HubMind(
            database: database, device: device, endpoint: endpoint, probe: SocketLeaseProbe(),
            brain: NativeBrain(configuration),
            login: { await MindLogin.check(configuration) },
            prepare: { try MindHome.prepare(work: work, config: config) },
            model: { UserDefaults.standard.string(forKey: HubModel.modelKey).flatMap(ClaudeModel.init(setting:)) ?? .default },
            observe: { [weak self] snapshot in
                Task { @MainActor in
                    guard let self else { return }
                    if self.mind?.phase != snapshot.phase || self.mind?.holds != snapshot.holds {
                        Self.log.notice("mind \(snapshot.phase.name, privacy: .public), holds the lease: \(snapshot.holds, privacy: .public)")
                    }
                    self.mind = snapshot
                    self.writeStatus()
                }
            })
        hubMind = mind
        mindSwitch = MindSwitch(mind: mind, key: launch.switchKey)
        Self.log.notice("mind made, \(self.mindOn ? "on" : "off", privacy: .public), home \(self.mindRoot.path, privacy: .public)")
    }

    /// On the in-memory store alone, `TOPO_HUB_LIMB_SAYS` is a limb's turn written to the log at
    /// launch, for the mind to answer in a run of the hub against nothing real.
    private func sayAsALimb() async {
        guard let words = launch.controls?.limbSays else { return }
        let log = TurnLog(database: database)
        do {
            let writer = try await log.writer(for: DeviceID("phone-memory00"))
            _ = try await writer.append(.person, words, continuing: try await log.read())
            Self.log.notice("memory store: a limb's turn written")
        } catch {
            Self.log.error("memory store: the limb's turn failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Reads the lease for the menu, and what the mind says of itself. Reads only.
    private func refreshLease() async {
        if let record = try? await database.fetch(Lease.recordID) { lease = Lease(record: record) }
        if let hubMind { mind = await hubMind.snapshot() }
    }

    func refreshDevices() async {
        try? await directory.touch(device, at: Date())
        if let all = try? await directory.all() { devices = all }
        lanFailure = await presence.failure
    }

    /// A phone's nudge (`HubNudge`): the mind's pass now, answered when it has ended, with the
    /// reply streamed down the nudge's connection as it is written when the phone asked for it
    /// and while the switch is on: turned off, it stops a stream in progress at the next frame
    /// (`ReplyCast.gated`).
    private nonisolated func nudged(_ holder: DeviceID, epoch: Int64, mark: String,
                                    stream: (@Sendable (ReplyFrame) -> Void)?) async -> Bool {
        guard let mind = await hubMind else { return false }
        let gated = Self.streamsNow ? stream.map { ReplyCast.gated($0, while: { Self.streamsNow }) } : nil
        return await mind.nudge(holder: holder, epoch: epoch, mark: mark, stream: gated)
    }

    /// A phone's heads-up that its turn is being saved (`HubNudge.Coming`): the mind's pass gets
    /// ready for it now, and the listener tells it the turn's ref or that none is coming.
    private nonisolated func headsUp(_ holder: DeviceID, epoch: Int64, mark: String) async -> LeaseProbeServer.ComingTicket? {
        guard let mind = await hubMind, let ticket = await mind.headsUp(holder: holder, epoch: epoch, mark: mark) else { return nil }
        return LeaseProbeServer.ComingTicket(saved: { ticket.saved($0) }, ended: { ticket.end() })
    }

    private nonisolated func holds(_ holder: DeviceID, epoch: Int64) async -> Bool {
        guard let mind = await hubMind else { return false }
        return await mind.holds(holder, epoch: epoch)
    }

    /// The address a screen on the house network reaches this Mac at.
    var lanAddress: String? { HubIdentity.addresses().first }

    /// Who holds the lease: this Mac while its mind does, otherwise the holder of the lease as
    /// last read while it is fresh.
    var leaseHolder: DeviceID? {
        if mind?.holds == true { return device }
        guard let lease, !lease.isExpired(at: Date()), lease.holder != device else { return nil }
        return lease.holder
    }
}

/// What this Mac is to the database: a stable device ID and a key pair,
/// made once and kept in the keychain. A keychain that cannot be read is an
/// error and never a reason to make either again: a new ID is another device
/// beside the lease's, and a new key another pairing code.
enum HubIdentity {
    static let service = "zone.hexagon.topo.hub"

    struct Unreadable: Error, CustomStringConvertible {
        let description: String
    }

    static func deviceID() throws -> DeviceID {
        let data = try KeychainItem(service: service, account: "device")
            .readOrMake { Data(("mac-" + UUID().uuidString.lowercased()).utf8) }
        guard let id = String(data: data, encoding: .utf8) else {
            throw Unreadable(description: "the hub's device ID in the keychain is not text")
        }
        return DeviceID(id)
    }

    static func privateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        let raw = try KeychainItem(service: service, account: "key")
            .readOrMake { Curve25519.KeyAgreement.PrivateKey().rawRepresentation }
        do {
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        } catch {
            throw Unreadable(description: "the hub's key in the keychain is not a key")
        }
    }

    static func publicKey() throws -> String { try privateKey().publicKey.rawRepresentation.base64EncodedString() }

    static var hasCloudKitEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) != nil
    }

    /// The Mac's IPv4 addresses on interfaces that are up, Wi-Fi and wired first.
    static func addresses() -> [String] {
        var out: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (Int32(ifa.ifa_flags) & IFF_UP) != 0, (Int32(ifa.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let name = String(cString: ifa.ifa_name)
                let address = String(cString: host)
                if name.hasPrefix("en") { out.insert(address, at: 0) } else { out.append(address) }
            }
        }
        return out
    }
}
