import AVFoundation
import CallKit
import UIKit
import XCTest

@testable import Topo

/// A player that says what the call's session was doing at each pause and play, so a test reads
/// the bed's moments against the session's.
@MainActor
final class PhasedPlayer: WorkingPlayer {
    let url: URL
    var volume: Float = 1
    var numberOfLoops = 0
    var currentTime: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var fades: [Float] = []
    /// Each play and pause, with the call's phase at that moment.
    private(set) var moments: [(what: String, call: AudioSession.CallPhase)] = []
    var phase: @MainActor () -> AudioSession.CallPhase = { .none }

    init(url: URL) { self.url = url }

    var name: String { url.deletingPathExtension().lastPathComponent }

    func play() -> Bool {
        moments.append(("play", phase()))
        isPlaying = true
        return true
    }

    func pause() {
        moments.append(("pause", phase()))
        isPlaying = false
    }

    func setVolume(_ volume: Float, fadeDuration: TimeInterval) {
        fades.append(volume)
        self.volume = volume
    }
}

/// A voice whose every sentence waits for the test to let it go, and then yields the frames the
/// test gave it — none, for a sentence that makes no audio — and finishes.
final class GatedSentences: VoiceEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [Int: [[Float]]] = [:]
    private var asked = 0

    var sentencesAsked: Int { lock.withLock { asked } }
    /// Lets sentence `number` (from 1) go, with `frames` frames of tone.
    func open(_ number: Int, frames: Int = 1) {
        lock.withLock { opened[number] = Array(repeating: toneFrame(0.5), count: frames) }
    }

    func load(folder: URL, temperature: Float) async throws {}

    func stream(_ text: String, temperature: Float) async throws -> AsyncThrowingStream<Voice.Frame, Error> {
        let mine = lock.withLock { asked += 1; return asked }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var frames: [[Float]]?
                while frames == nil, !Task.isCancelled {
                    frames = self.lock.withLock { self.opened[mine] }
                    if frames == nil { try? await Task.sleep(for: .milliseconds(5)) }
                }
                for samples in frames ?? [] {
                    continuation.yield(Voice.Frame(samples: samples, rate: Voice.rate))
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

/// The working bed under a spoken turn's hold, on the settings a phone never asked has: from the
/// release's utterance taken, through the wait, to the reply's first frame, again in a reading's
/// gaps while the guest works, and paused while the call's session changes hands; never with
/// replies muted, and never under Receipts or Off kept.
@MainActor
final class AudibleHoldTests: XCTestCase {
    override func tearDown() {
        UIApplication.shared.isIdleTimerDisabled = false
        super.tearDown()
    }

    @MainActor struct Rig {
        let speaker: Speaker
        let sounds: KeeperSounds
        let audio: AudioSession
        let seams: Seams
        let defaults: UserDefaults
        let clock: PausedSleep
        let players: Players
        let voice: GatedSentences
    }

    @MainActor final class Players {
        private(set) var made: [PhasedPlayer] = []
        var phase: @MainActor () -> AudioSession.CallPhase = { .none }
        var bed: PhasedPlayer? { made.first { $0.name == KeeperSounds.bedFile } }
        func make(_ url: URL) -> PhasedPlayer {
            let player = PhasedPlayer(url: url)
            player.phase = phase
            made.append(player)
            return player
        }
    }

    private func settle(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                        until condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<6_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "waited a minute for \(what)", file: file, line: line)
    }

    private func defaults() -> UserDefaults {
        let name = "topo.tests.audible-hold.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    /// The store never asked, unless a test keeps a mode, and the earcons off, so the players
    /// made are the keeper's.
    private func rig(mode: WorkingSounds.Mode? = nil) async -> Rig {
        let seams = Seams()
        let center = NotificationCenter()
        let defaults = defaults()
        if let mode { defaults.set(mode.rawValue, forKey: WorkingSounds.key) }
        defaults.set(false, forKey: EarconsSetting.key)
        let audio = AudioSession(center: center, configure: seams.configure, setCategory: seams.setCategory,
                                 deactivate: seams.deactivate, isActive: { true })
        let players = Players()
        players.phase = { [weak audio] in audio?.call ?? .none }
        let clock = PausedSleep()
        let sounds = KeeperSounds(audio: audio, defaults: defaults, bundle: Bundle(for: KeeperSounds.self),
                                  makePlayer: { players.make($0) }, sleep: { try await clock.sleep($0) })
        let engine = GatedSentences()
        let voice = Voice(engine: engine)
        voice.load(folder: URL(fileURLWithPath: "/dev/null"))
        await settle("the voice to load") { voice.state == .ready }
        let speaker = Speaker(audio: audio, voice: voice, center: center,
                              makeEngine: { seams.makePlayEngine(rate: Voice.rate) },
                              heard: .dataRendered, sounds: sounds)
        return Rig(speaker: speaker, sounds: sounds, audio: audio, seams: seams, defaults: defaults,
                   clock: clock, players: players, voice: engine)
    }

    private func render(_ rig: Rig, _ what: String, file: StaticString = #filePath, line: UInt = #line,
                        until condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            if let engine = rig.seams.engines.last {
                let out = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                         frameCapacity: engine.manualRenderingMaximumFrameCount))
                _ = try? engine.renderOffline(256, to: out)
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(condition(), "rendered 400 slices waiting for \(what)", file: file, line: line)
    }

    /// Renders well past one frame of tone, so the queue has drained what it held and its drain
    /// has reached the speaker.
    private func drainTheQueue(_ rig: Rig) async throws {
        let engine = try XCTUnwrap(rig.seams.engines.last)
        for _ in 0..<60 {
            let out = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                     frameCapacity: engine.manualRenderingMaximumFrameCount))
            _ = try? engine.renderOffline(256, to: out)
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Review Focus 8: a phone never asked has the bed.
    func testAPhoneNeverAskedHasSounds() {
        XCTAssertEqual(WorkingSounds.mode(defaults()), .sounds)
    }

    // MARK: - The release

    /// Review Focus 2: a release wants the bed only once its utterance has been taken, and then
    /// before any wait is taken; the hand-over to the wait neither fades it out nor plays it again.
    func testTheBedBeginsOnceTheReleasesUtteranceIsTakenAndPlaysOnIntoTheWait() async throws {
        let rig = await rig()
        let release = try XCTUnwrap(rig.speaker.releasing(), "the release was not held")
        XCTAssertNil(rig.players.bed, "the bed was asked for before the utterance was taken")
        rig.speaker.utteranceTaken()
        let bed = try XCTUnwrap(rig.players.bed, "no bed under the release's decode")
        XCTAssertTrue(bed.isPlaying)
        XCTAssertEqual(bed.fades, [KeeperSounds.bedVolume])
        rig.speaker.sending(under: release)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        XCTAssertEqual(rig.speaker.releasesHeld, 0)
        XCTAssertEqual(bed.fades, [KeeperSounds.bedVolume], "the hand-over to the wait faded the bed")
        XCTAssertEqual(bed.moments.map(\.what), ["play"], "the bed was played twice or paused at the hand-over")
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    /// The press path's hook: `VoiceInput.end` tells of the take once the sink has been emptied,
    /// before the decode, so the bed begins under the decode and never under input still being
    /// collected.
    func testVoiceInputTellsOfTheTakeAfterTheSinkIsEmptied() async throws {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure, setCategory: seams.setCategory,
                                 deactivate: seams.deactivate, isActive: { true })
        let ear = Ear(vocabulary: Vocabulary(defaults: defaults()),
                      engine: ScriptedEngine(bare: "purple elephants", boosted: "purple elephants"))
        let nowhere = URL(fileURLWithPath: "/dev/null")
        ear.load(parakeet: nowhere, ctc: nowhere)
        await settle("the ear to load") { ear.ready }
        let input = VoiceInput(audio: audio, ear: ear, center: center,
                               makeEngine: { seams.makeEngine() },
                               formats: { seams.readFormats($0) },
                               permission: { true }, permitted: { true },
                               voiceProcessing: { try seams.process($0, $1) })
        var takes: [(sunk: Int, listening: Bool)] = []
        input.onTaken = { takes.append((input.sink.take().count, input.listening)) }
        let opened = await input.pressDown(as: .chat)
        XCTAssertNil(opened)
        XCTAssertTrue(input.listening)
        let format = input.sink.format
        let frames = AVAudioFrameCount(format.sampleRate * 1.5)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = sinf(Float(i) * 0.05) * 0.3 }
        input.sink.append(buffer)
        try? await Task.sleep(for: .seconds(VoiceInput.tapLimit + 0.1))
        let heard = await input.pressUp(as: .chat)
        XCTAssertEqual(heard, "purple elephants")
        XCTAssertEqual(takes.count, 1, "the take was told other than once")
        XCTAssertEqual(takes.first?.sunk, 0, "the sink still held audio when the take was told")
        XCTAssertEqual(takes.first?.listening, true, "the take was told after the decode, not before it")
    }

    /// Review Focus 1: a release whose send took no wait fades the bed before its hold goes, and
    /// nothing is held once the bed is paused.
    func testAReleaseThatTookNoWaitFadesTheBedAndHoldsNothingAfter() async throws {
        let rig = await rig()
        let release = try XCTUnwrap(rig.speaker.releasing())
        rig.speaker.utteranceTaken()
        let bed = try XCTUnwrap(rig.players.bed)
        rig.speaker.released(release, "its send took no wait")
        XCTAssertEqual(bed.fades.last, 0, "the bed was not faded at the release's end")
        XCTAssertTrue(rig.sounds.holdingASound, "the fade is not held through")
        await settle("the fade's pause to be asked for") { rig.clock.asked.contains(KeeperSounds.parkAfter) }
        rig.clock.fire(KeeperSounds.parkAfter)
        await settle("the bed to be paused") { !bed.isPlaying }
        XCTAssertFalse(rig.audio.holding, "a hold outlived the release and the bed's fade")
    }

    // MARK: - The mute

    /// Review Focus 6: a release under the mute (a conversation's, which takes one muted) holds
    /// as it did and plays no bed.
    func testAMutedReleasePlaysNoBed() async throws {
        let rig = await rig()
        rig.defaults.set(false, forKey: Mute.key)
        let release = try XCTUnwrap(rig.speaker.releasing())
        rig.speaker.utteranceTaken()
        XCTAssertTrue(rig.audio.holding)
        XCTAssertNil(rig.players.bed, "a bed under the mute")
        rig.speaker.released(release, "the test is done")
    }

    /// Review Focus 6: the mute pressed with a release still standing fades the bed at once.
    func testTheMuteFadesTheBedUnderAReleaseStillStanding() async throws {
        let rig = await rig()
        _ = try XCTUnwrap(rig.speaker.releasing())
        rig.speaker.utteranceTaken()
        let bed = try XCTUnwrap(rig.players.bed)
        rig.defaults.set(false, forKey: Mute.key)
        SpokenReply.muteChanged(readsAloud: false, speaker: rig.speaker)
        XCTAssertEqual(rig.speaker.releasesHeld, 1, "the mute let the release go")
        XCTAssertEqual(bed.fades.last, 0, "the bed played on under the mute")
    }

    // MARK: - The reading

    /// Review Focus 5: a reply landing ends its wait, and the bed plays on until the reply's first
    /// frame is scheduled.
    func testTheBedPlaysOnFromTheLandingToTheFirstFrame() async throws {
        let rig = await rig()
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        let bed = try XCTUnwrap(rig.players.bed)
        XCTAssertTrue(rig.speaker.speak("Paris is the capital.", answering: "turn"))
        XCTAssertEqual(rig.speaker.awaiting, [], "the landing left its wait standing")
        await settle("the sentence to be asked for") { rig.voice.sentencesAsked == 1 }
        XCTAssertEqual(bed.fades, [KeeperSounds.bedVolume], "the bed went out before the first frame")
        rig.voice.open(1)
        try await render(rig, "the first frame") { bed.fades.last == 0 }
        try await render(rig, "the reply to end") { !rig.speaker.speaking }
        XCTAssertEqual(bed.fades, [KeeperSounds.bedVolume, 0], "the bed came back after a reply with nothing standing")
    }

    /// A replay answers no turn, so it has no bed under it, gap or not.
    func testAReplayHasNoBed() async throws {
        let rig = await rig()
        XCTAssertTrue(rig.speaker.speak("Paris is the capital."))
        await settle("the sentence to be asked for") { rig.voice.sentencesAsked == 1 }
        XCTAssertNil(rig.players.bed, "a bed under a replay")
        rig.voice.open(1)
        try await render(rig, "the replay to end") { !rig.speaker.speaking }
        XCTAssertNil(rig.players.bed)
    }

    /// Review Focus 4: under a reply read as the guest writes it, the queue draining with a
    /// sentence still being made is the pause between two sentences and brings no bed; once the
    /// voice has said all it has with the guest still writing, the bed fills the gap, and the next
    /// frame takes it away. Review Focus 1: in the gap the turn's holds are the reading's alone.
    func testTheBedFillsTheGapOnlyOnceTheVoiceIsHeardOut() async throws {
        let rig = await rig()
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        let bed = try XCTUnwrap(rig.players.bed)
        rig.speaker.speak(writing: "One. Two. ", answering: "turn")
        await settle("the first sentence to be asked for") { rig.voice.sentencesAsked == 1 }
        rig.voice.open(1)
        try await render(rig, "the first frame") { bed.fades.last == 0 }
        await settle("the second sentence to be asked for") { rig.voice.sentencesAsked == 2 }
        // The queue drains the first under the second still being made: no bed.
        try await drainTheQueue(rig)
        XCTAssertEqual(bed.fades, [KeeperSounds.bedVolume, 0], "the bed swelled between two sentences")
        rig.voice.open(2)
        try await render(rig, "the voice heard out") { rig.speaker.voiceGap }
        XCTAssertEqual(bed.fades.last, KeeperSounds.bedVolume, "no bed in the gap while the guest works")
        XCTAssertTrue(bed.isPlaying)
        XCTAssertTrue(rig.audio.heldForATurn)
        XCTAssertEqual(rig.speaker.awaiting, [], "a wait stands in the gap")
        XCTAssertEqual(rig.speaker.releasesHeld, 0)
        // The guest writes on: the next frame takes the bed away.
        rig.speaker.speak(writing: "One. Two. Three. ", answering: "turn")
        await settle("the third sentence to be asked for") { rig.voice.sentencesAsked == 3 }
        XCTAssertEqual(bed.fades.last, KeeperSounds.bedVolume, "the bed went before the next frame")
        rig.voice.open(3)
        try await render(rig, "the next frame") { bed.fades.last == 0 }
        XCTAssertFalse(rig.speaker.voiceGap)
        rig.speaker.stop()
    }

    /// The red line's order: the queue drains while the last sentence is still being made, and
    /// that sentence then ends with no frame after it, the queue idle and the guest still writing.
    /// No drain is coming, so the gap is opened where the sentence is made.
    func testTheGapOpensWhereASentenceWithNoFrameIsMadeAfterTheDrain() async throws {
        let rig = await rig()
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        let bed = try XCTUnwrap(rig.players.bed)
        rig.speaker.speak(writing: "One. Two. ", answering: "turn")
        await settle("the first sentence to be asked for") { rig.voice.sentencesAsked == 1 }
        rig.voice.open(1)
        try await render(rig, "the first frame") { bed.fades.last == 0 }
        await settle("the second sentence to be asked for") { rig.voice.sentencesAsked == 2 }
        // The queue drains the first sentence under the second still being made.
        try await drainTheQueue(rig)
        XCTAssertFalse(rig.speaker.voiceGap, "a drain under a sentence still being made opened a gap")
        XCTAssertEqual(bed.fades, [KeeperSounds.bedVolume, 0])
        // The second sentence makes no audio at all.
        rig.voice.open(2, frames: 0)
        await settle("the gap to open where the sentence was made") { rig.speaker.voiceGap }
        XCTAssertEqual(bed.fades.last, KeeperSounds.bedVolume, "tool work under `.speaking` was left silent")
        XCTAssertTrue(bed.isPlaying)
        rig.speaker.stop()
    }

    // MARK: - The call

    /// Review Focus 3: the call's placing pauses the bed before `callPlaced` sets the category,
    /// and that category is the one change the session sees until the activation, which plays the
    /// bed again; at the call's end the bed is paused before `callOver`.
    func testTheCallsSessionChangingHandsPausesTheBedFirst() async throws {
        let rig = await rig()
        let system = FakeCallSystem()
        let call = SpokenCall(system: system, sleep: ManualSleep().sleep)
        rig.speaker.attach(call)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        let bed = try XCTUnwrap(rig.players.bed)
        XCTAssertTrue(bed.isPlaying)
        rig.seams.forget()

        call.start()
        call.provider(system.provider, perform: try XCTUnwrap(system.starts.last))
        XCTAssertEqual(rig.audio.call, .placed)
        XCTAssertFalse(bed.isPlaying, "the bed played on while the call's session changed hands")
        XCTAssertEqual(bed.moments.last?.what, "pause")
        XCTAssertEqual(bed.moments.last?.call, AudioSession.CallPhase.none, "the bed was paused after the category changed")
        XCTAssertEqual(rig.seams.lines, ["category set"], "the session was touched beside the placing's category")

        call.provider(system.provider, didActivate: AVAudioSession.sharedInstance())
        XCTAssertEqual(rig.audio.call, .active)
        XCTAssertTrue(bed.isPlaying, "the activation did not bring the bed back")
        XCTAssertEqual(bed.moments.last?.what, "play")
        XCTAssertEqual(bed.moments.last?.call, .active)

        call.end()
        call.provider(system.provider, didDeactivate: AVAudioSession.sharedInstance())
        let pauses = bed.moments.filter { $0.what == "pause" }
        XCTAssertEqual(pauses.count, 2, "the call's end did not pause the bed")
        XCTAssertNotEqual(pauses.last?.call, AudioSession.CallPhase.none, "the bed was paused after the call was over")
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    // MARK: - The person's choice

    /// Review Focus 7: Receipts or Off kept, nothing above makes a bed.
    func testReceiptsAndOffKeptHaveNoBed() async throws {
        for mode in [WorkingSounds.Mode.receipts, .off] {
            let rig = await rig(mode: mode)
            let release = try XCTUnwrap(rig.speaker.releasing())
            rig.speaker.utteranceTaken()
            rig.speaker.sending(under: release)
            _ = rig.speaker.awaitReply("turn", readAloud: true)
            rig.speaker.speak(writing: "One. ", answering: "turn")
            await settle("the sentence to be asked for") { rig.voice.sentencesAsked == 1 }
            rig.voice.open(1)
            try await render(rig, "the voice heard out") { rig.speaker.voiceGap }
            XCTAssertNil(rig.players.bed, "a bed under \(mode)")
            rig.speaker.stop()
        }
    }
}
