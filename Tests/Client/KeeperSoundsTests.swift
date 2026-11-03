import AVFoundation
import TopoCore
import TopoCoreTesting
import TopoTurn
import TopoUserland
import UIKit
import XCTest

@testable import Topo

/// A receipt's or the bed's player as the suite has it: every play, pause and fade recorded.
@MainActor
final class FakeWorkingPlayer: WorkingPlayer {
    let url: URL
    var volume: Float = 1
    var numberOfLoops = 0
    var currentTime: TimeInterval = 0
    private(set) var isPlaying = false
    var refusesToStart = false
    private(set) var plays = 0
    private(set) var pauses = 0
    /// Each fade asked for: the volume and how long.
    private(set) var fades: [(to: Float, over: TimeInterval)] = []

    init(url: URL) { self.url = url }

    var name: String { url.deletingPathExtension().lastPathComponent }

    func play() -> Bool {
        guard !refusesToStart else { return false }
        plays += 1
        isPlaying = true
        return true
    }

    func pause() {
        pauses += 1
        isPlaying = false
    }

    func setVolume(_ volume: Float, fadeDuration: TimeInterval) {
        fades.append((volume, fadeDuration))
        self.volume = volume
    }

    /// An interruption: the system stopped the player under whoever wanted it.
    func interrupted() { isPlaying = false }
}

/// Every player `KeeperSounds` asked for, in order.
@MainActor
final class WorkingRecorder {
    private(set) var players: [FakeWorkingPlayer] = []
    var nextRefusesToStart = false
    var names: [String] { players.map(\.name) }
    var bed: FakeWorkingPlayer? { players.first { $0.name == KeeperSounds.bedFile } }

    func make(_ url: URL) -> FakeWorkingPlayer {
        let player = FakeWorkingPlayer(url: url)
        player.refusesToStart = nextRefusesToStart
        nextRefusesToStart = false
        players.append(player)
        return player
    }
}

/// The keeper's sounds over a real `Speaker` on the audio seams and the guest activity as the
/// harness tells it, with the players the suite's. What is held: each tool class sounds its tone
/// and only while a hold stands, so a typed turn is silent; the bed only under `sounds`, in from
/// the release and out at the reply's first frame, paused not stopped; off goes through in every
/// mode; a value kept that is no mode reads as `receipts`; nothing on a session that will not
/// activate; nothing into an open microphone; a hold that extends a standing one and never holds
/// alone; and the players dropped, not rebuilt, at a reset.
@MainActor
final class KeeperSoundsTests: XCTestCase {
    override func tearDown() {
        UIApplication.shared.isIdleTimerDisabled = false
        super.tearDown()
    }

    @MainActor struct Rig {
        let speaker: Speaker
        let sounds: KeeperSounds
        let players: WorkingRecorder
        let seams: Seams
        let audio: AudioSession
        let center: NotificationCenter
        let defaults: UserDefaults
        let clock: PausedSleep
    }

    private func settle(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                        until condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<6_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "waited a minute for \(what)", file: file, line: line)
    }

    private func drain() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func makeDefaults() -> UserDefaults {
        let name = "topo.tests.keeper-sounds.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private func rig(mode: WorkingSounds.Mode? = nil, isActive: Bool = true,
                     heard: AVAudioPlayerNodeCompletionCallbackType = .dataPlayedBack) async -> Rig {
        let seams = Seams()
        let center = NotificationCenter()
        let defaults = makeDefaults()
        if let mode { defaults.set(mode.rawValue, forKey: WorkingSounds.key) }
        let audio = AudioSession(center: center, configure: seams.configure, isActive: { isActive })
        let players = WorkingRecorder()
        let clock = PausedSleep()
        let sounds = KeeperSounds(audio: audio, defaults: defaults, bundle: Bundle(for: KeeperSounds.self),
                                  makePlayer: { players.make($0) }, sleep: { try await clock.sleep($0) })
        let voice = Voice(engine: ScriptedVoice())
        voice.load(base: URL(fileURLWithPath: "/dev/null"))
        await settle("the voice to load") { voice.state == .ready }
        let speaker = Speaker(audio: audio, voice: voice, center: center,
                              makeEngine: { seams.makePlayEngine(rate: Voice.rate) },
                              heard: heard, sounds: sounds)
        return Rig(speaker: speaker, sounds: sounds, players: players, seams: seams, audio: audio,
                   center: center, defaults: defaults, clock: clock)
    }

    private func toolUse(_ name: String, path: String? = nil) -> GuestActivity {
        .update(.event(.toolUse(name: name, path: path)))
    }

    private func renderUntil(_ rig: Rig, _ what: String, file: StaticString = #filePath, line: UInt = #line,
                             _ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            let engine = try XCTUnwrap(rig.seams.engines.last, file: file, line: line)
            let out = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                     frameCapacity: engine.manualRenderingMaximumFrameCount))
            _ = try? engine.renderOffline(256, to: out)
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(condition(), "rendered 400 slices waiting for \(what)", file: file, line: line)
    }

    // MARK: - The receipts

    /// Each class the mascot can name sounds its tone, over the bundled file, while a wait stands;
    /// a tool with no class sounds nothing. Under `receipts` no bed is made.
    func testEachToolClassSoundsItsToneWhileAWaitStands() async {
        let rig = await rig()
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        XCTAssertTrue(rig.speaker.keeping, "the wait's keeper is not running, so the session is not live")
        XCTAssertTrue(rig.audio.holding)

        rig.sounds.follow(toolUse("WebSearch"))
        rig.sounds.follow(toolUse("Bash"))
        rig.sounds.follow(toolUse("Edit", path: "notes/today.md"))
        rig.sounds.follow(toolUse("Edit", path: "Sources/App.swift"))
        rig.sounds.follow(toolUse("TodoWrite"))
        XCTAssertEqual(rig.sounds.played, [.read, .act, .write, .act])
        XCTAssertEqual(rig.players.names, ["bloop_read", "bloop_act", "bloop_write"], "a tone's player was made twice, or the bed under receipts")
        XCTAssertEqual(rig.players.players.map(\.plays), [1, 2, 1])
        XCTAssertNil(rig.players.bed)
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    /// The calendar is an act, like building; thinking and idle are nothing.
    func testTheClassesMapToTheTones() {
        XCTAssertEqual(KeeperSounds.tone(for: .searching), .read)
        XCTAssertEqual(KeeperSounds.tone(for: .building), .act)
        XCTAssertEqual(KeeperSounds.tone(for: .calendar), .act)
        XCTAssertEqual(KeeperSounds.tone(for: .writing), .write)
        XCTAssertNil(KeeperSounds.tone(for: .thinking))
        XCTAssertNil(KeeperSounds.tone(for: .idle))
        XCTAssertNil(KeeperSounds.tone(for: nil))
    }

    /// Review Focus 9: a typed turn holds nothing, so its tools sound nothing and its failure
    /// sounds nothing, in every mode.
    func testNothingSoundsForATypedTurn() async {
        for mode in WorkingSounds.Mode.allCases {
            let rig = await rig(mode: mode)
            XCTAssertFalse(rig.audio.holding)
            rig.sounds.follow(toolUse("WebSearch"))
            rig.sounds.follow(.update(.ended(.failed(.exited("exit 1")))))
            rig.sounds.working(true)
            XCTAssertEqual(rig.sounds.played, [], "\(mode)")
            XCTAssertTrue(rig.players.players.isEmpty, "\(mode): a player was made for a turn nothing waits for")
        }
    }

    /// The guest's turn failing sounds the error, once, before the wait ends; the wait ending
    /// sounds nothing of its own.
    func testAFailedTurnSoundsTheError() async {
        let rig = await rig()
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.sounds.follow(.update(.ended(.failed(.exited("exit 1")))))
        XCTAssertEqual(rig.sounds.played, [.error])
        rig.speaker.endAwaiting("turn", "the turn failed")
        XCTAssertEqual(rig.sounds.played, [.error])
        XCTAssertTrue(rig.audio.holding, "the receipt's hold went with the wait's")
        await settle("the hold's length to be asked for") { rig.clock.asked.contains(KeeperSounds.toneLength) }
        rig.clock.fire()
        await settle("the receipt's hold to go") { !rig.audio.holding }
    }

    /// Off sounds nothing and makes no player; back on, the next sound plays.
    func testOffSoundsNothing() async {
        let rig = await rig(mode: .off)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.sounds.follow(toolUse("WebSearch"))
        rig.sounds.working(true)
        XCTAssertEqual(rig.sounds.played, [])
        XCTAssertTrue(rig.players.players.isEmpty)

        rig.defaults.set(WorkingSounds.Mode.receipts.rawValue, forKey: WorkingSounds.key)
        rig.sounds.follow(toolUse("WebSearch"))
        XCTAssertEqual(rig.sounds.played, [.read])
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    /// Review Focus 12: a value kept that is no mode — a word nobody chose, a Boolean — reads as
    /// `receipts`; a phone never asked reads as `receipts`.
    func testAnUnknownKeptValueIsTheStandard() {
        let defaults = makeDefaults()
        XCTAssertEqual(WorkingSounds.mode(defaults), .receipts)
        defaults.set("loud", forKey: WorkingSounds.key)
        XCTAssertEqual(WorkingSounds.mode(defaults), .receipts)
        defaults.set(true, forKey: WorkingSounds.key)
        XCTAssertEqual(WorkingSounds.mode(defaults), .receipts)
        defaults.set(false, forKey: WorkingSounds.key)
        XCTAssertEqual(WorkingSounds.mode(defaults), .receipts)
        defaults.set("sounds", forKey: WorkingSounds.key)
        XCTAssertEqual(WorkingSounds.mode(defaults), .sounds)
        defaults.set("off", forKey: WorkingSounds.key)
        XCTAssertEqual(WorkingSounds.mode(defaults), .off)
    }

    /// No receipt sounds over Topo's own voice: a tool reached for after the reading began, with
    /// a second wait keeping the hold, is silent; one after the reading ends sounds again.
    func testNoReceiptSoundsOverTheVoice() async throws {
        let rig = await rig(heard: .dataRendered)
        _ = rig.speaker.awaitReply("first", readAloud: true)
        _ = rig.speaker.awaitReply("second", readAloud: true)
        XCTAssertTrue(rig.speaker.speak("Paris.", answering: "first"))
        XCTAssertTrue(rig.speaker.speaking)
        rig.sounds.follow(toolUse("Bash"))
        XCTAssertEqual(rig.sounds.played, [], "a receipt sounded over the voice")
        try await renderUntil(rig, "the reply to be made") { rig.speaker.report.finished }
        await settle("the reply to end") { !rig.speaker.speaking }
        rig.sounds.follow(toolUse("Bash"))
        XCTAssertEqual(rig.sounds.played, [.act])
        rig.speaker.endAwaiting("second", "the test is done")
    }

    /// No receipt is played into an open microphone: a hands-free session listening while the
    /// turn it sent is worked on (a press of its own ends every wait, so the bed and the receipts
    /// go with them). The speaker tells the sounds as the press's call returns and as it closes.
    func testNoReceiptIsPlayedIntoAnOpenMicrophone() async {
        let rig = await rig()
        var open = false
        rig.speaker.microphoneOpen = { open }
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        open = true
        rig.speaker.microphoneOpened(counted: false)
        rig.sounds.follow(toolUse("WebSearch"))
        XCTAssertEqual(rig.sounds.played, [], "a receipt was played into an open microphone")
        XCTAssertTrue(rig.players.players.isEmpty)
        open = false
        rig.speaker.microphoneClosed()
        rig.sounds.follow(toolUse("Bash"))
        XCTAssertEqual(rig.sounds.played, [.act])

        // A press over the wait ends it: only the last receipt's own hold stands, and a receipt
        // under nothing but that would be the receipts keeping the process alive by themselves.
        rig.speaker.microphoneOpening()
        XCTAssertTrue(rig.speaker.awaiting.isEmpty)
        XCTAssertTrue(rig.audio.holding, "the receipt's hold went with the wait's")
        XCTAssertFalse(rig.audio.heldForATurn)
        // The press opened nothing (a refusal, say): the microphone is closed again, and a tool
        // reached for now meets only the receipt's own hold.
        rig.speaker.microphoneOpened(counted: true)
        rig.sounds.follow(toolUse("Bash"))
        XCTAssertEqual(rig.sounds.played, [.act], "a receipt sounded under nothing but a receipt's hold")
        await settle("the hold's length to be asked for") { rig.clock.asked.contains(KeeperSounds.toneLength) }
        rig.clock.fire()
        await settle("the receipt's hold to go") { !rig.audio.holding }
    }

    /// A microphone opened with no press telling the speaker is still one no receipt is played
    /// into, since the sounds ask the speaker at each one; and the bed dips once the watch on the
    /// microphone tells the speaker it is listening.
    func testNoReceiptIsPlayedIntoAMicrophoneNoPressOpened() async throws {
        let rig = await rig(mode: .sounds)
        var open = false
        rig.speaker.microphoneOpen = { open }
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        let bed = try XCTUnwrap(rig.players.bed)
        XCTAssertEqual(bed.fades.last?.to, KeeperSounds.bedVolume)
        open = true
        rig.sounds.follow(toolUse("WebSearch"))
        XCTAssertEqual(rig.sounds.played, [], "a receipt was played into a microphone no press opened")
        rig.speaker.microphoneListening()
        XCTAssertEqual(bed.fades.last?.to, KeeperSounds.duckedVolume, "the bed did not dip under the microphone")
        open = false
        rig.speaker.microphoneClosed()
        XCTAssertEqual(bed.fades.last?.to, KeeperSounds.bedVolume)
        rig.sounds.follow(toolUse("Bash"))
        XCTAssertEqual(rig.sounds.played, [.act])
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    /// A sound on a session that is not live is refused and configures nothing to get one: no
    /// player, no hold, nothing played. Behind the lock that is the lock screen's interruption
    /// with a claim change deferred under the wait's hold, which a sound must not apply from the
    /// background; a sound on a session nothing has activated yet is refused the same way.
    func testASoundOnASessionThatIsNotLiveIsRefusedAndConfiguresNothing() async {
        let rig = await rig(mode: .sounds, isActive: false)
        XCTAssertFalse(rig.sounds.tool("WebSearch", path: nil), "a receipt played on a session nothing had activated")
        rig.audio.wantRecord(true, for: .warm)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.audio.wantRecord(false, for: .warm)
        rig.center.post(name: AVAudioSession.interruptionNotification, object: nil,
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await drain()
        rig.seams.forget()

        XCTAssertFalse(rig.sounds.tool("WebSearch", path: nil))
        XCTAssertEqual(rig.sounds.played, [])
        XCTAssertEqual(rig.players.names, [KeeperSounds.bedFile], "a player was made on a session that is not live")
        // The bed somehow still going: the wait's end fades it, and takes no hold for the fade,
        // since the hold's keeper would reconfigure the session from the background.
        rig.speaker.endAwaiting("turn", "the turn failed")
        XCTAssertEqual(rig.players.bed?.fades.last?.to, 0)
        XCTAssertFalse(rig.audio.holding, "the fade held on a session that is not live")
        XCTAssertEqual(rig.seams.lines, [], "a sound configured the session")
        XCTAssertEqual(rig.seams.records, [], "a sound applied a claim change from the background")
    }

    /// The interruption stopped the bed under a wait that still wants it, and the speaker asks
    /// for it back before the session is live again (a rebuild the session refused): the bed is
    /// not played again, since `AVAudioPlayer.play()` would activate the session itself, from
    /// the background, and nothing is configured.
    func testTheBedIsNotPlayedAgainOnASessionThatIsNotLive() async throws {
        let rig = await rig(mode: .sounds, isActive: false)
        rig.audio.wantRecord(true, for: .warm)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        let bed = try XCTUnwrap(rig.players.bed)
        XCTAssertEqual(bed.plays, 1)
        rig.audio.wantRecord(false, for: .warm)
        rig.center.post(name: AVAudioSession.interruptionNotification, object: nil,
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await drain()
        bed.interrupted()
        rig.seams.forget()

        rig.sounds.resume()
        XCTAssertEqual(bed.plays, 1, "the bed was played again on a session that is not live")
        XCTAssertFalse(bed.isPlaying)
        XCTAssertEqual(rig.seams.lines, [], "a sound configured the session")
        XCTAssertEqual(rig.seams.records, [], "a sound applied a claim change from the background")
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    // MARK: - The bed

    /// Under `sounds` the bed fades in from the release and out at the reply's first frame, once,
    /// and is paused after its fade rather than stopped; the next wait plays it on from where it was.
    func testTheBedPlaysFromTheReleaseToTheReplysFirstFrameAndIsPausedNotStopped() async throws {
        let rig = await rig(mode: .sounds, heard: .dataRendered)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        let bed = try XCTUnwrap(rig.players.bed, "no bed was made at the release")
        XCTAssertEqual(bed.numberOfLoops, -1)
        XCTAssertEqual(bed.plays, 1)
        XCTAssertTrue(bed.isPlaying)
        XCTAssertEqual(bed.fades.map(\.to), [KeeperSounds.bedVolume])
        XCTAssertEqual(bed.fades.map(\.over), [KeeperSounds.fadeIn])

        // The reply lands and is read: its first frame fades the bed out, and the second
        // sentence's first frame does not fade it again.
        XCTAssertTrue(rig.speaker.speak("Paris is the capital. It is on the Seine.", answering: "turn"))
        await settle("the reply to start") { rig.speaker.report.started }
        try await renderUntil(rig, "both sentences to be made") { rig.speaker.report.finished }
        XCTAssertEqual(bed.fades.map(\.to), [KeeperSounds.bedVolume, 0], "the bed faded at more than one frame")
        XCTAssertEqual(bed.fades.last?.over, KeeperSounds.fadeOut)
        XCTAssertTrue(bed.isPlaying, "the bed was stopped before its fade")
        XCTAssertEqual(rig.clock.asked.filter { $0 == KeeperSounds.parkAfter }.count, 2, "the fade's hold and its pause, once each")
        bed.currentTime = 3.2
        rig.clock.fire()
        await settle("the bed to be paused") { bed.pauses == 1 }
        XCTAssertFalse(bed.isPlaying)

        // The next wait: the same player plays on from where it was paused.
        _ = rig.speaker.awaitReply("second", readAloud: true)
        XCTAssertEqual(rig.players.players.filter { $0.name == KeeperSounds.bedFile }.count, 1, "a second bed was made")
        XCTAssertEqual(bed.plays, 2)
        XCTAssertEqual(bed.currentTime, 3.2, "the bed was started from the top")
        XCTAssertEqual(bed.fades.last?.to, KeeperSounds.bedVolume)
        rig.speaker.stop()
    }

    /// With a second turn's wait standing, the first's reply does not end the bed at its landing
    /// — the wait it ends is not the last — but at its first frame, so the bed is not under the
    /// voice. It is not brought back for the second wait once the reply is read.
    func testTheBedGivesWayAtTheFirstFrameUnderASecondWait() async throws {
        let rig = await rig(mode: .sounds, heard: .dataRendered)
        _ = rig.speaker.awaitReply("first", readAloud: true)
        _ = rig.speaker.awaitReply("second", readAloud: true)
        let bed = try XCTUnwrap(rig.players.bed)
        XCTAssertTrue(rig.speaker.speak("Paris.", answering: "first"))
        XCTAssertEqual(rig.speaker.awaiting, ["second"])
        XCTAssertEqual(bed.fades.map(\.to), [KeeperSounds.bedVolume], "the bed faded at the reply's landing, under a wait still standing")
        await settle("the reply to start") { rig.speaker.report.started }
        try await renderUntil(rig, "the reply to be made") { rig.speaker.report.finished }
        XCTAssertEqual(bed.fades.map(\.to), [KeeperSounds.bedVolume, 0], "the bed played on under the voice")
        rig.speaker.endAwaiting("second", "the test is done")
    }

    /// Under `receipts` there is no bed; a mode changed to `off` mid-wait stops the bed under
    /// it; and a wait that follows within the fade cancels the pause, so the bed plays on.
    func testTheBedOnlyUnderSoundsAndOffGoesThrough() async throws {
        let receipts = await rig(mode: .receipts)
        _ = receipts.speaker.awaitReply("turn", readAloud: true)
        XCTAssertNil(receipts.players.bed, "a bed under receipts")
        receipts.speaker.endAwaiting("turn", "the test is done")

        let rig = await rig(mode: .sounds)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        let bed = try XCTUnwrap(rig.players.bed)
        rig.defaults.set(WorkingSounds.Mode.off.rawValue, forKey: WorkingSounds.key)
        rig.sounds.working(false)
        XCTAssertEqual(bed.fades.last?.to, 0, "off did not stop the bed")
        // Wanted again before the pause lands: the pause is cancelled and the bed plays on.
        await settle("the fade's sleeps to be asked for") { rig.clock.asked.filter { $0 == KeeperSounds.parkAfter }.count == 2 }
        rig.defaults.set(WorkingSounds.Mode.sounds.rawValue, forKey: WorkingSounds.key)
        rig.sounds.working(true)
        XCTAssertEqual(bed.fades.last?.to, KeeperSounds.bedVolume)
        rig.clock.fire()
        await drain()
        XCTAssertEqual(bed.pauses, 0, "the bed was paused under a wait that wanted it")
        XCTAssertTrue(bed.isPlaying)
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    /// The bed dips while a microphone is open over it (a hands-free session's, listening as its
    /// turn is sent) and comes back when it closes; a press over the wait ends it, bed and all.
    func testTheBedDipsUnderAnOpenMicrophone() async throws {
        let rig = await rig(mode: .sounds)
        var open = true
        rig.speaker.microphoneOpen = { open }
        rig.speaker.microphoneOpened(counted: false)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        let bed = try XCTUnwrap(rig.players.bed)
        XCTAssertEqual(bed.fades.map(\.to), [KeeperSounds.duckedVolume], "the bed came in at full volume under an open microphone")
        rig.speaker.microphoneClosed()
        XCTAssertEqual(bed.fades.count, 1, "a microphone still open changed the bed")
        open = false
        rig.speaker.microphoneClosed()
        XCTAssertEqual(bed.fades.map(\.to), [KeeperSounds.duckedVolume, KeeperSounds.bedVolume])
        open = true
        rig.speaker.microphoneOpened(counted: false)
        XCTAssertEqual(bed.fades.last?.to, KeeperSounds.duckedVolume)
        rig.speaker.microphoneOpened(counted: false)
        XCTAssertEqual(bed.fades.count, 3, "the open microphone dipped the bed twice")
        open = false
        rig.speaker.microphoneClosed()
        XCTAssertEqual(bed.fades.last?.to, KeeperSounds.bedVolume)

        rig.speaker.microphoneOpening()
        XCTAssertTrue(rig.speaker.awaiting.isEmpty, "a press left the wait standing")
        XCTAssertEqual(bed.fades.last?.to, 0, "the bed played on under a press that ended its wait")
        // Under nothing but the fade's own hold, the bed is not wanted back.
        XCTAssertFalse(rig.audio.heldForATurn)
        rig.sounds.working(true)
        XCTAssertEqual(bed.fades.last?.to, 0, "the bed came back under a sound's own hold")
        rig.speaker.microphoneOpened(counted: true)
    }

    /// The lock screen's interruption stops the bed under a wait that still wants it; where the
    /// speaker puts its engine back, the bed is played again, through the same refusal path.
    func testTheBedComesBackWhereTheEngineDoes() async throws {
        let rig = await rig(mode: .sounds)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        let bed = try XCTUnwrap(rig.players.bed)
        rig.center.post(name: AVAudioSession.interruptionNotification, object: nil,
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        bed.interrupted()
        await drain()
        XCTAssertEqual(bed.plays, 1)
        rig.center.post(name: AVAudioSession.interruptionNotification, object: nil,
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        await drain()
        XCTAssertEqual(bed.plays, 2, "the bed was not played again with the engine")
        XCTAssertTrue(bed.isPlaying)
        XCTAssertEqual(bed.fades.last?.to, KeeperSounds.bedVolume)
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    // MARK: - The hold

    /// A sound begun while a hold stands holds the process until it is over and no longer:
    /// the error receipt's hold outlasts the wait's by the tone's length, then goes.
    func testASoundsHoldExtendsTheWaitsAndThenGoes() async {
        let rig = await rig()
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        XCTAssertTrue(rig.sounds.failed())
        rig.speaker.endAwaiting("turn", "the turn failed")
        XCTAssertTrue(rig.audio.holding, "the receipt's hold went with the wait's")
        XCTAssertTrue(rig.speaker.keeping, "the keeper stopped under the receipt")
        await settle("the hold's length to be asked for") { rig.clock.asked.contains(KeeperSounds.toneLength) }
        rig.clock.fire()
        await settle("the hold to go") { !rig.audio.holding }
        XCTAssertFalse(rig.speaker.running, "the engine ran on with nothing held")
    }

    /// The fade's hold is taken before the wait's drops: behind the lock with a claim change
    /// deferred under the wait, the keeper does not stop and the claim does not apply between
    /// the two holds, only once the fade's hold has gone.
    func testTheFadesHoldIsTakenBeforeTheWaitsDrops() async throws {
        let rig = await rig(mode: .sounds, isActive: false)
        rig.audio.wantRecord(true, for: .warm)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        XCTAssertTrue(rig.speaker.keeping)
        rig.audio.wantRecord(false, for: .warm)
        rig.seams.forget()
        let bed = try XCTUnwrap(rig.players.bed)

        rig.speaker.endAwaiting("turn", "the turn is done")
        XCTAssertEqual(bed.fades.last?.to, 0)
        XCTAssertTrue(rig.audio.holding, "the process was let go of with the fade unheard")
        XCTAssertFalse(rig.speaker.keeperTransitions.contains("stopped"), "the keeper stopped between the wait's hold and the fade's")
        XCTAssertEqual(rig.seams.records, [], "the deferred claim applied between the wait's hold and the fade's")
        await settle("the fade's sleeps to be asked for") { rig.clock.asked.filter { $0 == KeeperSounds.parkAfter }.count == 2 }
        rig.clock.fire()
        await settle("the fade's hold to go") { !rig.audio.holding }
        // Away, the last hold's going applies nothing either: the session is marked for the
        // foreground's next path, and a sound on it is refused.
        XCTAssertEqual(rig.seams.records, [], "a claim was applied from the background")
        XCTAssertFalse(rig.speaker.running)
        XCTAssertFalse(rig.sounds.tool("WebSearch", path: nil))
    }

    /// A sound begun with nothing held holds nothing, and a claim change under it applies at once.
    func testASoundBegunWithNothingHeldHoldsNothing() async {
        let rig = await rig(mode: .sounds)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.speaker.endAwaiting("turn", "the test is done")
        await settle("the fade's sleeps to be asked for") { rig.clock.asked.filter { $0 == KeeperSounds.parkAfter }.count == 2 }
        rig.clock.fire()
        await settle("the fade's hold to go") { !rig.audio.holding }
        // Nothing held: a receipt is the keeper's and is not played; the bed is not either.
        XCTAssertFalse(rig.sounds.tool("Bash", path: nil))
        rig.sounds.working(true)
        XCTAssertFalse(rig.audio.holding, "a sound held alone")
        rig.seams.forget()
        rig.audio.wantRecord(true, for: .warm)
        XCTAssertEqual(rig.seams.lines, ["activate ok"], "the claim waited on a sound")
    }

    /// iOS reset the media server with a receipt's hold standing and the bed playing: the players
    /// are dropped and nothing is built, started or spoken to in the handler — not the keeper on
    /// the dead engine as the waits end under it, not the dropped bed — and the next sound makes
    /// its own.
    func testAMediaServicesResetDropsThePlayersAndBuildsNothing() async throws {
        let rig = await rig(mode: .sounds)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.sounds.follow(toolUse("WebSearch"))
        XCTAssertEqual(rig.players.names, [KeeperSounds.bedFile, "bloop_read"])
        let bed = try XCTUnwrap(rig.players.bed)
        await settle("the receipt's hold to ask for its length") { rig.clock.asked.contains(KeeperSounds.toneLength) }
        let fades = bed.fades.count
        let engines = rig.seams.engines.count
        let transitions = rig.speaker.keeperTransitions.count
        let asked = rig.clock.asked.count
        // The reset leaves the engine stopped, as the offline one is not by the notification
        // alone: the wait ending under the handler with the receipt's hold still standing
        // re-notifies the hold, and on a stopped engine that is the keeper started again.
        let engine = try XCTUnwrap(rig.seams.engines.last)
        engine.stop()
        let starts = rig.seams.playEngineStarts

        rig.center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        await drain()
        XCTAssertEqual(rig.players.names, [KeeperSounds.bedFile, "bloop_read"], "a player was built in the reset handler")
        XCTAssertFalse(rig.audio.holding, "the reset left a hold standing")
        XCTAssertEqual(rig.seams.engines.count, engines, "an engine was built in the reset handler")
        XCTAssertFalse(rig.speaker.keeperTransitions.dropFirst(transitions).contains("playing"), "the keeper was started in the reset handler: \(rig.speaker.keeperTransitions)")
        XCTAssertEqual(rig.seams.playEngineStarts, starts, "the engine the reset killed was started again")
        XCTAssertFalse(engine.isRunning)
        XCTAssertFalse(rig.speaker.running)
        XCTAssertEqual(bed.fades.count, fades, "the dropped bed was faded")
        XCTAssertEqual(bed.pauses, 0, "the dropped bed was spoken to")
        XCTAssertEqual(rig.clock.asked.count, asked, "a sleep was asked for in the reset handler")

        _ = rig.speaker.awaitReply("again", readAloud: true)
        rig.sounds.follow(toolUse("WebSearch"))
        XCTAssertEqual(rig.players.names, [KeeperSounds.bedFile, "bloop_read", KeeperSounds.bedFile, "bloop_read"],
                       "a player the reset invalidated was reused")
        rig.speaker.endAwaiting("again", "the test is done")
    }

    // MARK: - The harness

    /// Following the harness wraps what Topo installed: he still hears every activity, and the
    /// sounds hear it after him.
    func testFollowingTheHarnessLeavesTopoFollowingIt() async {
        let rig = await rig()
        let harness = Harness(database: InMemoryRecordDatabase(), device: DeviceID("phone"), ensureZone: {},
                              defaults: makeDefaults(), brain: NoBrain(),
                              leaseSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                              pause: { _ in throw CancellationError() })
        let mascot = Mascot()
        mascot.follow(harness)
        rig.sounds.follow(harness)
        _ = rig.speaker.awaitReply("turn", readAloud: true)

        harness.onGuest?(.began(pid: nil, answering: []))
        harness.onGuest?(toolUse("WebSearch"))
        XCTAssertEqual(mascot.state.activity, .searching, "Topo stopped following the harness")
        XCTAssertEqual(rig.sounds.played, [.read])
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    /// Every sound has its file in the bundle, at the root, where `KeeperSounds` looks.
    func testEverySoundIsBundled() {
        let bundle = Bundle(for: KeeperSounds.self)
        for tone in KeeperSounds.Tone.allCases {
            XCTAssertNotNil(bundle.url(forResource: tone.file, withExtension: "wav"), "\(tone.file).wav is not in the bundle")
        }
        XCTAssertNotNil(bundle.url(forResource: KeeperSounds.bedFile, withExtension: "wav"))
    }
}

/// A sleep the test fires, so a bound or a pause is a moment the test chooses.
final class PausedSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, any Error>] = []
    private var _asked: [Duration] = []

    var asked: [Duration] { lock.withLock { _asked } }

    func sleep(_ duration: Duration) async throws {
        lock.withLock { _asked.append(duration) }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { waiting.append(continuation) }
            }
        } onCancel: {
            let cancelled = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
                let all = waiting
                waiting = []
                return all
            }
            cancelled.forEach { $0.resume(throwing: CancellationError()) }
        }
    }

    /// Every sleep waiting ends now.
    func fire() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            let all = waiting
            waiting = []
            return all
        }
        all.forEach { $0.resume() }
    }
}

/// A brain for a harness no turn is sent through.
private struct NoBrain: Brain {
    struct NotHere: Error {}
    func answer(_ request: BrainRequest) async throws -> Reply { throw NotHere() }
    func describe() async -> String { "no brain" }
}
