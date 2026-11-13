import OSLog
import CallKit
import SwiftUI
import TopoAuth
import TopoCore
import TopoTools

@main
struct TopoApp: App {
    /// For the UIKit callbacks SwiftUI has no spelling of: the models' background download
    /// finishing, and a silent push saying the log moved. See `TopoAppDelegate`.
    @UIApplicationDelegateAdaptor(TopoAppDelegate.self) private var appDelegate
    @State private var signIn: SignIn
    @State private var harness: Harness
    @State private var memory: Memory
    @State private var connections: Connections
    @State private var roleSelector: RoleSelector
    @State private var audio: AudioSession
    @State private var voice: VoiceInput
    @State private var speaker: Speaker
    @State private var callDriver: SpokenCallDriver
    @State private var conversation: Conversation
    private let endpoint: Endpoint
    /// Topo on the composer's glass: the chat's harness moves him, and so do the guest's turns.
    @State private var mascot: Mascot
    @State private var widgetCues: WidgetCues
    @State private var shares: ShareInbox
    @State private var attachments: ComposerAttachments
    @State private var defaultSurface: DefaultSurface
    @State private var controlDefaults = ControlDefaults()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        PerfRun.begin()
        Perf.mark("app.init.begin sinceProcessStart=\(Perf.sinceProcessStart() ?? -1)ms")
        // The Claude.ai tokens a build before Claude Code's own login kept in the keychain go
        // before anything asks whether this phone is signed in: it signs in once more.
        let migrated = LoginMigration.run { item, error in
            TopoLog(.auth).error("login migration: the keychain kept \(item.account) (\(String(describing: error))); tried again next launch")
        }
        let signInAgain = migrated || UserDefaults.standard.bool(forKey: LoginMigration.signInAgainKey)
        // A debug build launched with a developer's token in its environment is signed in by it,
        // so the simulator comes up past the sign-in screen.
        #if DEBUG
        DebugRun.signIn()
        // And before the harness reads its line: a debug build asked for a turn owed gets one,
        // so a launch can be the relaunch that comes back to a row it never finished sending.
        DebugRun.seedOutbox()
        #endif
        // The sign-in is Claude Code's own, in the guest; each boot of the guest asks it again
        // whether it is still signed in, before any process starts.
        #if DEBUG
        let accept = DebugRun.accepts()
        #else
        let accept: @Sendable (ClaudeLoginStatus) -> Bool = { $0.isClaudeAI }
        #endif
        let signIn = SignIn(login: GuestLogin(), signInAgain: signInAgain, accept: accept)
        _signIn = State(initialValue: signIn)
        signIn.beginning = { LoginLife.shared.began() }
        GuestResident.shared.booted = { await signIn.refresh() }
        Harness.recordsWhere = { await AppRecords.recordsWhere() }
        let harness = Harness.standard(database: AppRecords.database(), ensureZone: AppRecords.ensureZone)
        let mascot = Mascot()
        // The guest answering the chat moves Topo as it works: each turn's events set his pose.
        mascot.follow(harness)
        _harness = State(initialValue: harness)
        _mascot = State(initialValue: mascot)
        let memory = Memory.standard(database: AppRecords.database(), ensureZone: AppRecords.ensureZone)
        _memory = State(initialValue: memory)
        // The guest's mount of the memory follows the same home the mirror runs against.
        GuestResident.shared.memory = memory
        memory.writer = GuestResident.shared.turns
        // The phone's own tools, which the guest's `topo` reaches through the tool service. Making
        // them asks for nothing: each permission is asked for by the first call that needs it.
        let connections = Connections()
        _connections = State(initialValue: connections)
        let broker = PermissionBroker()
        let eventKit = EventKitStore()
        let location = LocationPermission()
        let home = HomeAccess { HomeKitStore() }
        let reminders = RemindersTool(store: eventKit, authorizer: EventKitAuthorizer(entity: .reminder, store: eventKit), broker: broker)
        let notify = NotifyTool(scheduler: UserNotificationScheduler(), authorizer: NotificationAuthorizer(), broker: broker)
        let homeTool = HomeTool(home: home, authorizer: HomeAuthorizer(home: home), broker: broker)
        GuestResident.shared.toolTable = [
            LookTool(vault: {
                #if DEBUG
                DebugRun.lookReading.map { ($0.look, $0) } ?? (memory.look, memory.lookReading)
                #else
                (memory.look, memory.lookReading)
                #endif
            }),
            reminders,
            CalendarTool(store: eventKit, authorizer: EventKitAuthorizer(entity: .event, store: eventKit), broker: broker),
            notify,
            ContactsTool(directory: ContactStoreDirectory(), authorizer: ContactsAuthorizer(), broker: broker),
            GitHubTool(store: connections.store, leftBehind: connections.leftBehind),
            SecretTool(store: connections.store, onePassword: GuestOnePassword(), leftBehind: connections.leftBehind,
                       requests: connections.secrets),
            LocationTool(locator: CoreLocationLocator(permission: location), authorizer: LocationAuthorizer(permission: location),
                         broker: broker, places: { memory.places }),
            MapsTool.standard(permission: location, broker: broker),
            homeTool,
            PhotosTool(library: PhotoKitLibrary(), authorizer: PhotosAuthorizer(), broker: broker),
            FilesTool(picker: DocumentPicker(), drop: GuestVaultDrop()),
            ScreenTool(),
            WidgetTool(judge: WidgetRunJudge(home: homeTool, notify: notify, reminders: reminders)),
            ControlTool(judge: WidgetRunJudge(home: homeTool, notify: notify, reminders: reminders),
                        leftBehind: connections.leftBehind),
            ActivityTool(host: { ActivityKeeper.shared.host }, keeper: { ActivityKeeper.shared }),
            TimerTool(scheduler: TimerRecords.scheduler, records: .shared, broker: broker),
            LogTool(reader: UnifiedLogReader()),
            VoiceTool(),
            OpenURLTool(),
            ContextTool(facts: { [weak harness] in
                ContextTool.Facts(context: harness?.context, window: harness?.window, setting: harness?.compaction ?? .auto,
                                  compacting: harness?.compacting ?? false, last: harness?.lastCompaction)
            }, set: { [weak harness] in harness?.compaction = $0 }, compact: { [weak harness] in harness?.compact() ?? false }),
        ]
        // A control's request to the home network asks for local network access in the
        // foreground only, since a background one while it is undetermined is denied unasked.
        LocalNetworkAccess.shared.isActive = { UIApplication.shared.applicationState == .active }
        // A widget's run control reaches the same tools, with `home` refusing a lock's and a
        // door's target; a turn control's cue goes on this harness's line.
        let widgetTable = WidgetActions.table(GuestResident.shared.toolTable)
        // The app's own widget follows the newest reply the log brings.
        let defaultSurface = DefaultSurface()
        _defaultSurface = State(initialValue: defaultSurface)
        harness.onLanded = { [weak harness] reply in defaultSurface.landed(reply, in: harness?.turns ?? []) }
        let widgetCues = WidgetCues(harness: harness)
        _widgetCues = State(initialValue: widgetCues)
        let shares = ShareInbox(line: harness)
        _shares = State(initialValue: shares)
        // What the composer's `+` attaches goes in by the share store and out by the same drain.
        _attachments = State(initialValue: ComposerAttachments(drain: { await shares.drain() }))
        // A sign-out, a takeover or a viewer's arrival takes the pictures read for the bubbles.
        TurnImages.endWith(.shared)
        ShortcutIntents.drain = { await shares.drain() }
        ShortcutIntents.landed = { [weak harness] in harness?.said($0) ?? false }
        WidgetIntents.handler = WidgetTaps(cues: widgetCues, actions: WidgetActions(table: widgetTable))
        TimerIntents.control = { await TimerControls.act($0, $1) }
        // Made now, so a sign-out before any slot is written still takes the records with it.
        _ = SurfaceSync.shared
        // Built now so its sign-out hook is registered in every process, scene or none.
        _ = ActivityKeeper.shared
        // The Live Activities are the login's: ended with the slots at a sign-out, a takeover or
        // a viewer's arrival.
        _roleSelector = State(initialValue: RoleSelector(database: AppRecords.database(),
                                                         isSignedIn: { LoginCache.standard.isSignedIn },
                                                         ensureZone: AppRecords.ensureZone))
        let audio = AudioSession()
        if ProcessInfo.processInfo.arguments.contains("--stay-awake") {
            audio.wantScreenAwake(true, for: .profiling)
        }
        Perf.mark("app.housekeeping.begin")
        _audio = State(initialValue: audio)
        // A clear of the compile cache the person asked for runs before the ear and the voice
        // exist, so no model is loading while it goes. A debug build launched asking for a stub
        // ear gets one; every other launch, the real one.
        #if DEBUG
        let (ear, spoken) = ModelHousekeeping.launch(clear: ModelHousekeeping.clearCompileCache,
                                                     ear: { DebugRun.ear() }, voice: { DebugRun.voice() })
        #else
        let (ear, spoken) = ModelHousekeeping.launch(clear: ModelHousekeeping.clearCompileCache,
                                                     ear: { Ear() }, voice: { Voice() })
        #endif
        Perf.mark("app.housekeeping.end")
        let voice = VoiceInput(audio: audio, ear: ear)
        // The keeper's sounds follow the guest beside Topo, after him, and the speaker plays the bed.
        let sounds = KeeperSounds(audio: audio)
        sounds.follow(harness)
        let speaker = Speaker(audio: audio, voice: spoken, sounds: sounds, earcons: Earcons(audio: audio))
        // A spoken exchange behind the lock is a call: placed while a hold stands with the
        // app in the background, ended as the app comes forward (`SpokenCall`).
        let call = SpokenCall()
        speaker.attach(call)
        call.judged(on: audio, voice: voice)
        let callDriver = SpokenCallDriver(call: call)
        speaker.onHold = { [weak audio] in callDriver.holdChanged($0, forATurn: audio?.heldForATurn ?? $0) }
        speaker.onMicrophone = { callDriver.microphoneChanged($0) }
        _callDriver = State(initialValue: callDriver)
        // The ear first: the voice's compile waits while the ear is to be fetched or compiling,
        // and goes when its compile ends. A debug stand-in ear, which may load for ever, holds
        // nothing back.
        var standIn = false
        #if DEBUG
        standIn = !(ProcessInfo.processInfo.environment[DebugRun.earVariable] ?? "").isEmpty
        #endif
        if !standIn {
            spoken.ear = ear
            ear.settled = { [weak spoken] in spoken?.earSettled() }
        }
        // A reply is not read into an open or opening microphone: one that lands then waits for
        // it to close (`Speaker.speak`), which the watch hears.
        MicrophoneWatch.wire(voice, speaker)
        // A press heard behind a turn on its way bleeps, whatever the press itself has ended.
        speaker.turnOnItsWay = { harness.turnOnItsWay }
        // An open hands-free spoken turn as the app goes behind the lock goes on as a
        // conversation over the call: the call is placed for it, the resident stays up for it,
        // and the microphone is suspended across the session changing hands, at whichever of
        // the interruption's start and the call's placing comes first.
        let endpoint = Endpoint()
        self.endpoint = endpoint
        let calls = CXCallObserver()
        let conversation = Conversation(voice: voice, speaker: speaker, endpoint: endpoint,
                                        holding: { [weak audio] in audio?.holding ?? false },
                                        otherCall: { calls.calls.contains { !$0.hasEnded && $0.uuid != call.id } })
        speaker.onCall = {
            voice.call($0)
            conversation.call($0)
        }
        conversation.conversingChanged = { callDriver.conversingChanged($0) }
        voice.carries = { [weak conversation] in
            guard let conversation else { return false }
            // An interruption over a conversation in front (a phone call, the app still active)
            // ends it, and the session is dropped as an interruption drops one in front.
            guard conversation.carries() else {
                if conversation.inFront { conversation.stop("an interruption in front", sending: false, keepingDecode: true) }
                return false
            }
            conversation.noteInterruption()
            return true
        }
        GuestResident.shared.conversing = { [weak conversation] beginning in
            guard let conversation else { return false }
            return beginning ? conversation.beginIfCarried() : conversation.on
        }
        conversation.ended = { GuestResident.shared.conversationEnded() }
        _conversation = State(initialValue: conversation)
        _voice = State(initialValue: voice)
        _speaker = State(initialValue: speaker)
        // What the process costs, a line a minute, with what it was doing.
        EnergyPulse.shared.state = { [weak harness, weak voice, weak speaker, weak audio] in
            let guest = await GuestResident.shared.session?.residentPID
            var parts = [guest == nil ? "guest none" : "guest resident"]
            if harness?.busy == true { parts.append("turn in flight") }
            if voice?.listening == true { parts.append("mic open") }
            if speaker?.speaking == true { parts.append("speaking") }
            if audio?.holding == true { parts.append("hold standing") }
            return parts.joined(separator: ", ")
        }
        EnergyPulse.shared.start()
        // What says, on a device run with no debugger attached, when iOS suspended the process.
        #if DEBUG
        AudioLog.startHeartbeat()
        #endif
        Perf.mark("app.init.end")
    }

    /// The turn `TOPO_DEBUG_SEND` asks for, in a debug build. Nothing at all in a release one.
    private func debugTurn() async {
        #if DEBUG
        await DebugRun.send(with: harness, mascot: mascot)
        #endif
    }

    /// The guest command `TOPO_DEBUG_USERLAND` asks for, in a debug build: the only path in the
    /// app that boots the guest. Nothing at all in a release one.
    private func debugUserland() async {
        #if DEBUG
        await DebugRun.userland()
        #endif
    }

    /// The turns `TOPO_DEBUG_GUEST_TURN` asks for, in a debug build: the resident Claude Code in
    /// the guest, carried through the app's lifecycle. Nothing at all in a release one.
    private func debugGuestTurn() async {
        #if DEBUG
        await DebugRun.guestTurn(mascot: mascot)
        #endif
    }

    /// The connects `TOPO_DEBUG_CONNECT_GITHUB` and `TOPO_DEBUG_ONEPASSWORD_TOKEN` ask for, in a
    /// debug build. Nothing in a release one.
    private func debugConnections() async {
        #if DEBUG
        async let github: Void = DebugRun.connectGitHub(connections)
        async let onePassword: Void = DebugRun.connectOnePassword(connections)
        _ = await (github, onePassword)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // A debug build asked to host one widget document draws that and nothing else.
            if let document = WidgetHostView.launched {
                WidgetHostView(document: document)
            } else {
                chat
            }
            #else
            chat
            #endif
        }
    }

    /// The app: the chat and everything the scene's phases drive.
    private var chat: some View {
        RootView().environment(signIn).environment(harness).environment(roleSelector)
            .environment(voice).environment(speaker).environment(conversation).environment(memory).environment(mascot)
            .environment(connections).environment(attachments)
            // An image a turn carries is drawn from the guest's home, which is on this phone; the
            // root hands it to the signed-in chat alone (`RootView`).
            .environment(\.turnImageFiles, TurnImageFiles(data: { ShareInbox.imageData($0) }))
            // What every view draws with, which is the vault's `look.json` read onto the
            // compiled look. It is worn here rather than on the chat so that the first run,
            // the sign-in and the viewer screen are drawn by the same document; the memory
            // reads it after each sync, so a look the mind wrote is worn from the next one
            // with no relaunch.
            .wearing(memory)
            // The record configuration is brought up on the foreground so the press is not
            // what pays for the route change; permission-gated inside. The ear's and the
            // voice's models are asked for on the same cue, downloaded if the phone lacks
            // them, so they are resident by the first press.
            // The memory is mirrored by whatever phone holds a login, so what a revision's
            // push wakes follows the login and not the chat: a phone sitting on the first
            // run, or on a sign-in it has already answered, mirrors like any other. The
            // subscription is saved from here for the same reason, and a failure costs only
            // the acceleration, so it is not the screen's to report.
            .onChange(of: signIn.phase, initial: true) { was, phase in
                MemoryWake.follow(signedIn: phase == .signedIn, memory: memory)
                defaultSurface.follow(from: was, to: phase, latest: harness.turns.last { $0.role == .assistant })
                controlDefaults.follow(from: was, to: phase)
                shares.follow(from: was, to: phase, guestIsHere: roleSelector.role == .primary)
                guard phase == .signedIn else { return }
                Task { try? await NotePush.ensureSubscription() }
                // What the watch is owed of the slots: a sign-out's deletes, then any record
                // behind its file.
                Task { await SurfaceSync.shared.flush() }
            }
            // The primary, signed in, takes what other phones' records left on the watch.
            .onChange(of: roleSelector.role == .primary && signIn.phase == .signedIn, initial: true) { _, owner in
                if owner { SurfaceSync.shared.sweep() }
                // A screen share is taken only where the guest lives, and its stills go with
                // the login or the role.
                ScreenTool.follow(owner: owner, store: ScreenStore.shared(), home: GuestResident.homeDirectory)
                // An image or a file can be shared only where the guest's home is.
                if signIn.phase == .signedIn { shares.follow(from: .signedIn, to: .signedIn, guestIsHere: owner) }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                // Said in the audio log beside the call driver's own source, UIKit's, so a run
                // says which of the two the lock reached first.
                AudioLog.say("scene \(phase)")
                audio.warmRecord(phase == .active)
                if phase == .active {
                    Perf.mark("scene.active")
                    Task { await widgetCues.drain() }
                    // An activity past its until goes; the rest are polled again.
                    Task { await ActivityKeeper.shared.resume() }
                    // What was shared from another app while Topo was away becomes a turn now.
                    Task { await shares.drain() }
                    // A copy of a still whose ten minutes ran out while Topo was suspended goes now.
                    Task.detached(priority: .utility) { ScreenTool.sweep(under: GuestResident.homeDirectory) }
                    LocalNetworkAccess.shared.becameActive()
                    voice.prepare()
                    endpoint.prepare()
                    speaker.prepare()
                    // The guest's rootfs and Claude Code, fetched (and the rootfs imported)
                    // on the same cue, so the userland is on the phone before anything
                    // needs it. The chat's harness boots it once both are here.
                    Userland.shared.prepare()
                    // The memory catches up with what the other devices wrote while this
                    // phone was away, and anything edited in Files here goes out, before
                    // the person has typed anything.
                    Task { await memory.sync() }
                }
            }
            // A widget's cue waits for the harness's first read of the log, which is when it
            // can tell a cue it already sent; a link's cue arrives as a URL.
            .onChange(of: harness.hasRead) { _, read in
                if read {
                    Task { await widgetCues.drain() }
                    Task { await shares.drain() }
                }
            }
            .onOpenURL { url in Task { await widgetCues.open(url) } }
            // Nothing unless a debug build was launched asking for a turn; the screen
            // behaves as it always does either way.
            .task { await debugTurn() }
            // Nothing unless the launch was a timed run from a Mac (`PerfRun`).
            .task { await PerfRun.run(with: harness, speaker: speaker, ear: voice.ear) }
            .task { await debugUserland() }
            .task { await debugGuestTurn() }
            .task { await debugConnections() }
    }
}
