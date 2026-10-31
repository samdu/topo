import CryptoKit
import Foundation
import OSLog
import TopoAuth
import TopoCore
import TopoProxy
import TopoTools
import TopoTurn
import TopoUserland
import UIKit

/// iOS's background time, from `UIApplication`.
@MainActor
final class ApplicationBackgroundTime: BackgroundTime {
    func begin(expiration: @escaping @MainActor () -> Void) -> Int {
        let task = UIApplication.shared.beginBackgroundTask(withName: "zone.hexagon.topo.guest") {
            MainActor.assumeIsolated { expiration() }
        }
        return task == .invalid ? GraceBudget.refused : task.rawValue
    }

    func end(_ task: Int) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: task))
    }

    var remaining: TimeInterval { UIApplication.shared.backgroundTimeRemaining }
}

/// The resident Claude Code on this phone: the guest booted once per process, the app's
/// `Documents/home` mounted as its home, the API proxy and the tool service on loopback with the
/// `topo` command and its skill written into the home, and the one `GuestSession`,
/// carried through the app's lifecycle by a `GuestLifecycle` — started on the foreground, ended on
/// the way out once the grace is spent. The session id the next process resumes is kept in
/// `Documents/.guest-session`, beside the home, and the bridge's ledger in
/// `Documents/.guest-bridge.json` beside that. The chat's harness brings it up
/// (`ResidentConversation`), once the userland is on the phone; so does a debug launch
/// (`DebugRun.guestTurn`).
@MainActor
final class GuestResident {
    static let shared = GuestResident()

    private let starting = StartOnce<GuestSession>()
    /// What of the start is done, so a start tried again after a failure does not do it twice.
    private var homeMounted = false
    private var lifecycle: GuestLifecycle?
    private var proxy: APIProxy?
    /// The tool service, made once; its listener is started again wherever it was lost.
    private var tools: ToolService?
    /// `topo`, its skill and the GitHub shims written into the home and linked onto the path.
    private var toolsInstalled = false
    /// The tools the service answers with: the app's own, set before the first start
    /// (`TopoApp`). A start before they are set answers `topo help` with none.
    var toolTable: [any Tool] = []
    /// Asked once the guest is up and before any process starts: the sign-in's `refresh`.
    var booted: (@MainActor () async -> Void)?
    private var observers: [NSObjectProtocol] = []

    /// What a debug build launched with a developer's token (`TOPO_CLAUDE_SETUP_TOKEN`, which CI
    /// and the simulator runs use) gives every `claude` it starts in place of a login: the token as
    /// `CLAUDE_CODE_OAUTH_TOKEN`. Empty in a release build, and in a debug build launched without one.
    nonisolated static var developerEnvironment: [String: String] {
        #if DEBUG
        DebugRun.developerToken().map { ["CLAUDE_CODE_OAUTH_TOKEN": $0] } ?? [:]
        #else
        [:]
        #endif
    }

    /// The app's `Documents/home`, mounted at `ClaudeLauncher.home`.
    nonisolated static var homeDirectory: URL {
        URL.documentsDirectory.appendingPathComponent("home", isDirectory: true)
    }

    nonisolated static var sessionFile: SessionFile {
        SessionFile(url: URL.documentsDirectory.appendingPathComponent(".guest-session"))
    }

    /// The bridge's ledger: what the guest has seen of the log, and the input outstanding.
    nonisolated static var ledgerFile: URL {
        URL.documentsDirectory.appendingPathComponent(".guest-bridge.json")
    }

    /// The session once `start` has made it, nil before.
    private(set) var session: GuestSession?

    /// The app's memory, whose home the guest's mount follows (`TopoApp` sets it).
    var memory: Memory?
    /// The memory's folder in the guest.
    let vault = VaultMount(seam: .guest)
    /// Turns sent into that folder, and the memory's moves held apart from them (`TopoApp` hands
    /// it to the memory as its writer).
    private(set) lazy var turns = MemoryTurns { [unowned self] in self.session }

    /// Brings the guest's mount of the memory into line with the home, and answers whether it is
    /// mounted. Asked when the session is made, when a turn is readied and when it is sent; never
    /// by a launch, so a process started after a sign-out mounts nothing.
    func reconcileMemory() throws -> Bool {
        let home = memory?.home ?? .local
        let local = memory?.localDirectory ?? Memory.standardDirectory
        return try vault.reconcile(home: home, local: local)
    }

    /// What the first process is told: a mount that could not be brought into line is said in the
    /// log and told as a memory it cannot reach, rather than failing the start.
    private func memoryAtStart(log: @Sendable (String) -> Void) -> Bool {
        do {
            return try reconcileMemory()
        } catch {
            log("memory: \(error)")
            return false
        }
    }

    /// The model a process is started with: the setting, as the debug pin makes it.
    static var model: String {
        let setting = UserDefaults.standard.string(forKey: Harness.modelKey).flatMap(ClaudeModel.init(setting:))
        return ClaudeModel.effective(setting ?? .default).rawValue
    }

    /// The share of its window a process is started to compact at: this device's setting, or nil
    /// for Claude Code's own. A debug build launched with `TOPO_DEBUG_COMPACT_AT=<percent>` takes
    /// that instead, which is how a simulator run sees a compaction without filling a window.
    static var compactAt: Int? {
        #if DEBUG
        if let word = ProcessInfo.processInfo.environment[compactAtVariable], let setting = Compaction.Setting(word) {
            return setting.percent
        }
        #endif
        return Compaction.Setting(kept: UserDefaults.standard.integer(forKey: Compaction.key)).percent
    }

    nonisolated static let compactAtVariable = "TOPO_DEBUG_COMPACT_AT"

    /// Brings the guest and the session up, once per process, and starts following the app's
    /// lifecycle from the foreground it is in now. A start that fails is not kept: the next call
    /// tries again from the step that failed (the kernel's own boot is once per process, and its
    /// answer is `Userland.bootGuest`'s to keep). Once the guest is up, and before any process
    /// starts, `booted` asks Claude Code whether it is still signed in (`SignIn.refresh`); a launch
    /// while it is not is refused. `log` hears the session's and the proxy's lines, and each way
    /// out's outcome.
    func start(userland: Userland = .shared, log: @escaping @Sendable (String) -> Void) async throws -> GuestSession {
        try await starting.value { @MainActor in
            _ = try await userland.bootGuest()
            _ = try await self.prepareTools(log: log)
            Perf.mark("guest.tools.ready")
            let proxy: APIProxy
            if let made = self.proxy {
                proxy = made
            } else {
                proxy = try APIProxy(log: Self.listening("proxy", log: log))
                self.proxy = proxy
            }
            _ = try await proxy.start()
            guard let tools = self.tools else { throw CancellationError() }
            let ports = LaunchPorts(proxy: proxy, tools: tools)
            await self.booted?()
            let handOut: @Sendable (UInt16) async throws -> [String: String] = { port in try Self.launchCredential(port: port) }
            let made = Self.launchEnvironment(ports: ports, credential: handOut)
            let launcher = ClaudeLauncher {
                // The zone written before every launch, so a process started on the foreground
                // after the phone changed zones starts in the new one: its runtime keeps the zone it
                // first reads for its life.
                await userland.bringZoneUpToDate()
                return try await made()
            }
            let session = GuestSession(launcher: launcher, store: Self.sessionFile,
                                       freezer: GuestFreeze(ports: ports, userland: userland, credential: handOut), model: Self.model,
                                       memory: self.memoryAtStart(log: log), compactAt: Self.compactAt, log: log)
            self.session = session
            let lifecycle = GuestLifecycle(session: session, time: ApplicationBackgroundTime(),
                                           report: { outcome in Self.note("background: \(outcome)") })
            self.lifecycle = lifecycle
            self.follow(lifecycle)
            Perf.mark("guest.proxy.up")
            if UIApplication.shared.applicationState != .background { lifecycle.willEnterForeground() }
            return session
        }
    }

    /// The home mounted, the tool service listening, `topo`, its skill and the GitHub shims written
    /// into the home and the commands linked onto the guest's path; the answer is what the guest's environment gains to
    /// reach the service. The mount, the service and the install are each done once per process and
    /// kept, so a start tried again after a failure picks up from the step that failed; the
    /// listener is asked for at every call, so one iOS took away is started again and the answer
    /// names the port it listens on now. Needs a booted guest.
    func prepareTools(log: @escaping @Sendable (String) -> Void) async throws -> [String: String] {
        let home = Self.homeDirectory
        if !homeMounted {
            try Self.makeHome(home)
            try Guest.shared.mount(home, at: ClaudeLauncher.home)
            homeMounted = true
            GuestImages.changed(home: true)
        }
        let service: ToolService
        if let tools {
            service = tools
        } else {
            service = try ToolService(tools: toolTable, log: Self.listening("tools", log: log))
            tools = service
        }
        let port = try await service.start()
        if !toolsInstalled {
            try GuestTools.install(home: home)
            for (script, command) in GuestTools.links {
                try await Guest.shared.linkCommand(ClaudeLauncher.home + "/" + script, at: command)
            }
            toolsInstalled = true
        }
        return ToolService.environment(port: port, token: await service.token)
            .merging(GuestTools.environment) { own, _ in own }
            .merging(BuildFacts.current) { own, _ in own }
    }

    /// The guest's home, made if it is not there: excluded from backup, since Claude Code keeps
    /// its Claude.ai credential in it (`.claude/.credentials.json`), and readable from the first
    /// unlock after a restart on, as the keychain item it replaces was. `.claude` is made with the
    /// same protection, so the credential written into it takes the class it is made under.
    /// What every launch of the resident is given for its login: refused while the cache says
    /// signed out, so nothing launches between a sign-out and its logout; otherwise the proxy and,
    /// in a debug build launched with one, the developer's token.
    nonisolated static func launchCredential(port: UInt16, cache: LoginCache = .standard) throws -> [String: String] {
        guard cache.isSignedIn else { throw GuestBridgeError.notReady("signed out") }
        return APIProxy.guestEnvironment(port: port).merging(developerEnvironment) { _, new in new }
    }

    /// `set` is how the protection is put on a path: the simulator keeps no protection class, so
    /// a test reads what was asked for there.
    nonisolated static func makeHome(
        _ home: URL,
        set: ([FileAttributeKey: Any], String) throws -> Void = { try FileManager.default.setAttributes($0, ofItemAtPath: $1) }
    ) throws {
        let files = FileManager.default
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        try files.createDirectory(at: claude, withIntermediateDirectories: true, attributes: protection)
        try set(protection, home.path)
        try set(protection, claude.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = home
        try url.setResourceValues(values)
    }

    /// A listener's lines under `name`, to `log`; a loss is told at `notice` as well, since the
    /// one after a suspension is what the phone has to keep for a run read afterwards.
    private nonisolated static func listening(_ name: String, log: @escaping @Sendable (String) -> Void) -> @Sendable (String) -> Void {
        { line in
            log("\(name): \(line)")
            if line.hasPrefix("listener lost") { listenerLog.notice("\(name, privacy: .public): \(line, privacy: .public)") }
        }
    }

    /// Where a listener started again is told: at `notice`, which the phone keeps.
    nonisolated static let listenerLog = Logger(subsystem: "zone.hexagon.topo", category: "resident")

    /// A turn just sent, carried behind another app by a continued-processing task (iOS 26 on):
    /// the task is asked for now, while the app is in front, and the lifecycle hears the turn end
    /// from the updates, which are passed on as they come. Read to the end whoever listens, since
    /// the end is what lets the task go.
    func carried(_ updates: AsyncStream<GuestSession.TurnUpdate>, compaction: Bool) -> AsyncStream<GuestSession.TurnUpdate> {
        guard #available(iOS 26, *), let lifecycle else { return updates }
        // A compaction is the mind's housekeeping, not a reply the person is waiting on.
        guard !compaction else { return updates }
        let turn = lifecycle.turnBegan()
        ContinuedTurns.submit(turn: turn, to: lifecycle, log: Self.note)
        return lifecycle.carry(updates, turn: turn)
    }

    private func follow(_ lifecycle: GuestLifecycle) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { lifecycle.didEnterBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { lifecycle.willEnterForeground() }
            },
        ]
    }
}

/// What each launch of the resident is told of the proxy and the tool service. Claude Code reads
/// their ports once, from its environment at launch, so every launch starts both listeners anew
/// (`relisten`) and is told the ports they have now: a listener bound a moment ago is the app's
/// own, where one held across a suspension may have been taken away, its word of that not come
/// yet, and its port bound again by another process. A launch has no resident beside it, so no
/// connection is lost by it.
@MainActor
final class LaunchPorts {
    let proxy: APIProxy
    let tools: ToolService

    init(proxy: APIProxy, tools: ToolService) {
        self.proxy = proxy
        self.tools = tools
    }

    /// The ports the last launch was told, which a frozen resident still holds in its environment.
    private(set) var told: (proxy: UInt16, tools: UInt16)?
    /// A digest of the token the last launch was handed, never the token: the guest cannot refresh
    /// one, so a frozen resident is continued only while the credential still hands out the same.
    private var handed: SHA256.Digest?

    /// Notes the token a launch's environment carries.
    func hand(_ environment: [String: String]) {
        handed = environment[Self.tokenVariable].map { SHA256.hash(data: Data($0.utf8)) }
    }

    /// Whether `credential`, asked now for the port the last launch was told, hands out the token
    /// that launch was given: an access token refreshed or expired since is not, and a frozen
    /// resident holding it is replaced rather than continued. The read may refresh over the
    /// network, so it has `bound`; one that runs out is a token not known to be the same.
    func stillHanded(by credential: @escaping @Sendable (UInt16) async throws -> [String: String],
                     within bound: Duration = .seconds(3)) async -> Bool {
        guard let told, let handed else { return false }
        let (answers, answer) = AsyncStream<String?>.makeStream()
        let reading = Task { answer.yield(try? await credential(told.proxy)[Self.tokenVariable]) }
        let timer = Task { try? await Task.sleep(for: bound); answer.yield(nil) }
        var now: String?
        for await first in answers { now = first; break }
        reading.cancel()
        timer.cancel()
        guard let now else { return false }
        return SHA256.hash(data: Data(now.utf8)) == handed
    }

    nonisolated static let tokenVariable = "CLAUDE_CODE_OAUTH_TOKEN"

    /// The ports to tell the next launch: each service's, on a listener started for it.
    func ports() async throws -> (proxy: UInt16, tools: UInt16) {
        let now = (try await proxy.relisten(), try await tools.relisten())
        told = now
        return now
    }

    /// Both services listening again on the very ports the last launch was told, for a frozen
    /// resident on its way back; false when either cannot be taken back (another process bound it
    /// while the app was away) or no launch was told any.
    func reclaim() async -> Bool {
        guard let told else { return false }
        do {
            _ = try await proxy.relisten(on: told.proxy)
            _ = try await tools.relisten(on: told.tools)
            return true
        } catch {
            GuestResident.listenerLog.notice("guest: a port the frozen resident was told could not be taken back: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}

/// The app's freezer: every guest task stopped on the way out, and on the way back the proxy and
/// the tool service taken back on the ports the resident was told and the DNS forwarder up before
/// any task is continued, so nothing in the guest runs toward a listener the app does not hold.
@MainActor
final class GuestFreeze: GuestFreezer {
    /// How long the stop may take to be confirmed: well inside the grace.
    static let stopBound: Duration = .seconds(1)

    let ports: LaunchPorts
    let userland: Userland
    let credential: @Sendable (UInt16) async throws -> [String: String]

    init(ports: LaunchPorts, userland: Userland, credential: @escaping @Sendable (UInt16) async throws -> [String: String]) {
        self.ports = ports
        self.userland = userland
        self.credential = credential
    }

    nonisolated func stop() async -> Bool {
        await GuestProcess.stopAll(within: Self.stopBound)
    }

    nonisolated func resume() async -> Bool {
        guard await ports.stillHanded(by: credential) else {
            GuestResident.listenerLog.notice("guest: the token the frozen resident holds is no longer the one handed out; starting a fresh process")
            return false
        }
        guard await ports.reclaim() else { return false }
        await userland.reviveForwarder()
        guard await GuestProcess.continueAll() else {
            GuestResident.listenerLog.notice("guest: a task of the frozen resident stayed stopped after the continue; starting a fresh process")
            return false
        }
        return true
    }
}

extension GuestResident {
    /// What the resident's launcher answers at each launch: the proxy's and the tool service's
    /// ports from `ports`, the credential `credential` makes for the proxy's, `topo`'s own
    /// variables and the app's build (`BuildFacts`). Says at notice what the launch is told, once the environment is made; a launch
    /// that then fails to start says so in the session's own line.
    nonisolated static func launchEnvironment(
        ports: LaunchPorts, note: @escaping @Sendable (String) -> Void = { GuestResident.listenerLog.notice("\($0, privacy: .public)") },
        credential: @escaping @Sendable (UInt16) async throws -> [String: String]
    ) -> @Sendable () async throws -> [String: String] {
        { @Sendable in
            let now = try await ports.ports()
            let given = try await credential(now.proxy)
            await ports.hand(given)
            let toolsToken = await ports.tools.token
            let environment = given
                .merging(ToolService.environment(port: now.tools, token: toolsToken)) { own, _ in own }
                .merging(GuestTools.environment) { own, _ in own }
                .merging(BuildFacts.current) { own, _ in own }
            note("guest: the launch is told the proxy at \(now.proxy) and the tools at \(now.tools)")
            return environment
        }
    }
}

/// One start at a time, whose success is kept and whose failure is not: every caller while a start
/// runs gets its answer, and a call after one that failed starts again.
@MainActor
final class StartOnce<Value: Sendable> {
    private var task: Task<Value, Error>?

    func value(_ start: @escaping @MainActor () async throws -> Value) async throws -> Value {
        if let task { return try await task.value }
        let task = Task { @MainActor in try await start() }
        self.task = task
        do {
            return try await task.value
        } catch {
            if self.task == task { self.task = nil }
            throw error
        }
    }
}

/// The resident Claude Code as the bridge's conversation: the guest brought up through
/// `GuestResident` once the userland is on the phone, and the one `GuestSession` from then on.
/// Until the rootfs and Claude Code are both fetched nothing is started and a turn is refused with
/// the userland's own status line, which is what the chat shows.
struct ResidentConversation: GuestConversation {
    var home: URL { GuestResident.homeDirectory }

    /// The session, started if it was not: refused, as not ready, while the userland is still on
    /// its way or the guest could not start.
    @MainActor
    private func session() async throws -> GuestSession {
        guard LoginCache.standard.isSignedIn else { throw GuestBridgeError.notReady("signed out") }
        let userland = Userland.shared
        guard userland.isReady else {
            userland.prepare()
            throw GuestBridgeError.notReady(userland.summary)
        }
        do {
            return try await GuestResident.shared.start(log: GuestResident.log)
        } catch {
            throw GuestBridgeError.notReady("the guest did not start: \(error)")
        }
    }

    func ready() async throws {
        let session = try await session()
        // The home may have moved, or its folder been made again, since the process was launched:
        // a turn is never sent into a mount of a folder that is not the memory's. What the mount
        // came to is what the process must have been told, and one told otherwise is replaced
        // before the turn goes to it (`GuestSession.use(memory:)`).
        let mounted: Bool
        do {
            mounted = try await GuestResident.shared.reconcileMemory()
        } catch {
            throw GuestBridgeError.notReady("\(error)")
        }
        await session.use(memory: mounted)
        do {
            try await session.ready()
        } catch GuestSession.Refusal.notResident {
            throw GuestBridgeError.notReady("Claude Code is not resident while the app is in the background")
        } catch {
            throw GuestBridgeError.notReady("Claude Code did not start: \(error)")
        }
    }

    @MainActor
    func warm() async {
        // The chat asks as it appears, which is before the launch has looked for the userland on
        // the phone. A userland already here says so within moments of being looked for; one
        // still downloading is not waited for, and the chat's loop asks again on every pass.
        let userland = Userland.shared
        userland.prepare()
        for _ in 0..<50 where !userland.isReady { try? await Task.sleep(for: .milliseconds(100)) }
        guard let session = try? await session() else { return }
        try? await session.ready()
    }

    func use(model: String?) async {
        // A session not started yet starts with the setting (`GuestResident.model`).
        await GuestResident.shared.session?.use(model: model)
    }

    func use(compactAt: Int?) async {
        // A session not started yet starts with the setting (`GuestResident.compactAt`). A debug
        // launch's own threshold stands over the setting, as it does at the start.
        #if DEBUG
        guard ProcessInfo.processInfo.environment[GuestResident.compactAtVariable].flatMap(Compaction.Setting.init) == nil else { return }
        #endif
        await GuestResident.shared.session?.use(compactAt: compactAt)
    }

    func sessionID() async -> String? {
        if let session = await GuestResident.shared.session { return await session.sessionID }
        return GuestResident.sessionFile.load()
    }

    func residentPID() async -> Int32? {
        await GuestResident.shared.session?.residentPID
    }

    func send(_ text: String, id: String) async throws -> AsyncStream<GuestSession.TurnUpdate> {
        let session = try await session()
        // A move of the memory may have come since `ready()`: the turn waits for one running, and
        // goes into a mount of the home as it is once none is (`MemoryTurns`).
        let updates = try await GuestResident.shared.turns.send(text, id: id, to: session) {
            do {
                return try GuestResident.shared.reconcileMemory()
            } catch {
                throw GuestBridgeError.notReady("\(error)")
            }
        }
        return await GuestResident.shared.carried(updates, compaction: text == GuestBridge.compactCommand)
    }

    func settle() async -> Bool {
        // No guest has run in this process, and the last process's guest ended with it: what it
        // wrote is final.
        await GuestResident.shared.session?.settle() ?? true
    }

    func forget() async {
        // What was read of the guest's files for the chat goes with the login.
        GuestImages.changed()
        // The resident is ended with no replacement, and waited for; then the mount goes, and then
        // the grant on the person's iCloud Drive folder, before any process starts again: the
        // memory is not reachable from a signed-out guest, and the grant is not held past the login.
        guard let session = await GuestResident.shared.session else {
            GuestResident.sessionFile.clear()
            await GuestResident.shared.vault.forget()
            return
        }
        await session.forgetSession { @MainActor in
            GuestResident.shared.vault.forget()
        }
    }

    func status() async -> String {
        let summary = await Userland.shared.summary
        guard let session = await GuestResident.shared.session else { return "\(summary); not started" }
        let phase = await session.currentPhase
        let pid = await session.residentPID.map { ", pid \($0)" } ?? ""
        let model = await session.currentModel ?? "Claude Code's own model"
        return "\(summary); \(phase)\(pid), \(model)"
    }
}

extension GuestResident {
    /// Where the session's, the proxy's and the tool service's lines go, and each way out's
    /// outcome: the unified log, under the category `topo log --category resident` reads, the
    /// proxy's starting `proxy:` and the tool service's `tools:`, and printed in a debug build,
    /// where a simulator run reads them.
    nonisolated static let log: @Sendable (String) -> Void = { line in
        // A cut the way out kept is a line a device check reads after the fact, so it is kept
        // on disk as `note`'s are.
        if line.hasPrefix(GuestSession.cutLine) { return note(line) }
        let line = redacted(line)
        Logger(subsystem: "zone.hexagon.topo", category: "resident").info("\(line, privacy: .public)")
        #if DEBUG
        DebugRun.say("guest: \(line)")
        #endif
    }

    /// The lines a device check reads after the fact — each way out of the background and each
    /// continued-processing task asked for and started — at `notice`, which the phone keeps on
    /// disk: an `info` line is kept in memory alone, and is gone within minutes.
    nonisolated static let note: @Sendable (String) -> Void = { line in
        let line = redacted(line)
        Logger(subsystem: "zone.hexagon.topo", category: "resident").notice("\(line, privacy: .public)")
        #if DEBUG
        DebugRun.say("guest: \(line)")
        #endif
    }

    /// `text` with every credential a line of the guest's could hold hidden: an `sk-ant-` key, a `Bearer`
    /// value, the guest's token variable and the tool service's, a GitHub token and a 1Password
    /// service-account token. Every line the resident logs goes
    /// through this, since `topo log` answers what the app logged.
    nonisolated static func redacted(_ text: String) -> String {
        var shown = text
        for (pattern, replacement) in [
            (#"sk-ant-[A-Za-z0-9_\-]+"#, "sk-ant-[redacted]"),
            (#"(?i)bearer\s+\S+"#, "Bearer [redacted]"),
            (#"(CLAUDE_CODE_OAUTH_TOKEN=)\S+"#, "$1[redacted]"),
            (#"(\#(ToolService.tokenVariable)=)\S+"#, "$1[redacted]"),
            (#"\b(gh[pousr]_|github_pat_)[A-Za-z0-9_]+"#, "$1[redacted]"),
            (#"\bops_[A-Za-z0-9_\-.=]+"#, "ops_[redacted]"),
        ] {
            shown = shown.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return shown
    }
}

#if DEBUG
extension DebugRun {
    static let guestTurnVariable = "TOPO_DEBUG_GUEST_TURN"
    /// What separates the turns in `TOPO_DEBUG_GUEST_TURN`.
    static let guestTurnSeparator = " || "

    /// The turns `TOPO_DEBUG_GUEST_TURN` names, in order, blank ones dropped.
    static func guestTurns(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        guard let value = environment[guestTurnVariable] else { return [] }
        return value.components(separatedBy: guestTurnSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// `TOPO_DEBUG_GUEST_TURN="<turn> || <turn> || …"`: on launch, bring the resident Claude Code up
    /// (`GuestResident`, the guest booted and Claude Code mounted as `TOPO_DEBUG_USERLAND` does,
    /// the proxy started, the home mounted) and send the turns to it one at a time, each once the
    /// app is in the foreground and the process is resident, printing each turn's model and
    /// session from its `system/init`, the tools it called and what each one's result said (named
    /// by the call it answers, in the order the calls were made, as `toolResultLine` writes it),
    /// its reply and its wall time from send
    /// to result — or that it failed or was abandoned — and every lifecycle line: the start (fresh
    /// or resuming which session), each way out's outcome and the termination it confirmed.
    /// Nothing is sent twice: a turn abandoned at the teardown point is reported and the next
    /// turn goes on the next foreground. Ends in `guest turn done`. Nothing at all when the
    /// variable is absent; refused beside `TOPO_DEBUG_USERLAND`, since the resident's end ends
    /// every guest task.
    @MainActor
    static func guestTurn(mascot: Mascot,
                          environment: [String: String] = ProcessInfo.processInfo.environment) async {
        let turns = guestTurns(environment)
        guard !turns.isEmpty else { return }
        // The resident's end is every guest task's, so nothing else may run in the guest beside it.
        if let command = environment[userlandVariable], !command.isEmpty {
            say("guest turn error: \(guestTurnVariable) and \(userlandVariable) are separate launches")
            say("guest turn done")
            return
        }
        say("guest: \(Userland.shared.summary)")
        do {
            let session = try await GuestResident.shared.start { line in say("guest: \(line)") }
            for (index, text) in turns.enumerated() {
                let number = index + 1
                var updates: AsyncStream<GuestSession.TurnUpdate>?
                var sent = ContinuousClock.now
                while updates == nil {
                    try await residentInForeground(session)
                    sent = ContinuousClock.now
                    do {
                        updates = try await session.send(text)
                    } catch GuestSession.Refusal.notResident {
                        // Ended between the wait and the send: wait for the next one.
                        continue
                    }
                }
                // The process the turn went to, named on every line that says what took it, so a
                // run can hold that its turns all went to one resident process.
                let pid = await session.residentPID.map(String.init) ?? "none"
                say("guest turn \(number) sent: \(text)")
                guard let updates else { continue }
                // Topo on the glass follows the turn: each update moves him, and the turn going,
                // however it went, leaves him idle. Every change of pose is printed.
                mascot.guestTurnBegan()
                var pose = mascot.state.activity
                // The calls whose results have not come back yet, oldest first.
                var calls: [String] = []
                for await update in updates {
                    mascot.guest(update)
                    if mascot.state.activity != pose {
                        pose = mascot.state.activity
                        say("guest turn \(number) mascot: \(pose.rawValue)")
                    }
                    switch update {
                    case .event(.started(let id, let model)):
                        say("guest turn \(number) model: \(model), session \(id), process \(pid)")
                    case .event(.toolUse(let name, let path)):
                        calls.append(name)
                        say("guest turn \(number) tool: \(name)" + (path.map { " \($0)" } ?? ""))
                    case .event(.toolResult(let isError, let text)):
                        let name = calls.isEmpty ? "(no call)" : calls.removeFirst()
                        say("guest turn \(number) " + toolResultLine(tool: name, isError: isError, text: text))
                    case .event(.compacted(let compacted)):
                        say("guest turn \(number) compacted: \(compacted.trigger), \(compacted.pre) → \(compacted.post)")
                    case .event(.usage(let usage)):
                        say("guest turn \(number) context: \(usage.context)")
                    case .event(.malformed(let line)):
                        say("guest turn \(number) malformed line: \(line)")
                    case .event:
                        break
                    case .ended(let end):
                        let seconds = String(format: "%.2f", Double((ContinuousClock.now - sent) / .milliseconds(1)) / 1000)
                        switch end {
                        case .answered(let result):
                            say("guest turn \(number) answered in \(seconds) s: \(result.text ?? "")")
                            if let window = result.window { say("guest turn \(number) window: \(window)") }
                        case .failed(let failure):
                            say("guest turn \(number) failed in \(seconds) s: \(failure)")
                        case .abandoned:
                            say("guest turn \(number) abandoned after \(seconds) s")
                        }
                    }
                }
                mascot.guestTurnGone()
                if pose != .idle { say("guest turn \(number) mascot: idle") }
            }
        } catch {
            say("guest turn error: \(error)")
        }
        say("guest turn done")
    }

    /// One tool result as the guest-turn run prints it: `tool result: <tool>: ok: <text>` or
    /// `…: error: <text>`, the text on one line (a newline written `\n`), a credential in it
    /// redacted — an `sk-ant-` key, a `Bearer` value, the guest's token variable, the tool
    /// service's, a GitHub or 1Password token — and anything past
    /// 300 characters cut, since a result can be a whole file.
    static func toolResultLine(tool: String, isError: Bool, text: String) -> String {
        var shown = redacted(text.trimmingCharacters(in: .newlines))
        shown = shown.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "\\n")
        if shown.count > 300 { shown = String(shown.prefix(300)) + "…" }
        return "tool result: \(tool): \(isError ? "error" : "ok"): \(shown)"
    }

    /// `GuestResident.redacted`, which everything the guest writes goes through before it is
    /// printed.
    static func redacted(_ text: String) -> String { GuestResident.redacted(text) }

    /// Waits until the app is in the foreground and the resident process is up.
    @MainActor
    private static func residentInForeground(_ session: GuestSession) async throws {
        while true {
            if UIApplication.shared.applicationState != .background {
                do {
                    try await session.ready()
                    return
                } catch GuestSession.Refusal.notResident {
                    // Went to the background while it was starting: wait for the next foreground.
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }
}
#endif

extension VaultMount.Seam {
    /// The guest's own: the vault's filesystem at `ClaudeLauncher.vault`, the home's `memory` link
    /// to it, and the grant started and stopped on the URL it is on.
    static var guest: VaultMount.Seam {
        VaultMount.Seam(
            mount: {
                try Guest.shared.mountVault($0, at: ClaudeLauncher.vault)
                GuestImages.changed()
            },
            unmount: {
                try Guest.shared.unmount(ClaudeLauncher.vault)
                GuestImages.changed()
            },
            link: { try Guest.shared.link(ClaudeLauncher.vault, at: ClaudeLauncher.memory) },
            startAccess: { $0.startAccessingSecurityScopedResource() },
            stopAccess: { $0.stopAccessingSecurityScopedResource() },
            identity: { VaultMount.Identity.of($0) },
            makeFolder: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) })
    }
}
