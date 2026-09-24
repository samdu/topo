#if DEBUG
import Foundation
import TopoAuth
import TopoCore
#if os(iOS)
import UIKit
#endif

/// What a debug build takes from its launch environment, so a simulator can be signed in and made
/// to say something without anybody touching the screen. None of it exists in a release build: the
/// whole file is behind `#if DEBUG`, and the model every turn goes to is pinned to Haiku by
/// `ClaudeModel.pinned`, which is behind the same flag.
///
/// The token arrives as an environment variable and nowhere else — not a scheme, not a file, not a
/// build setting — because a variable lives only in the launching shell and the launched process.
/// `scripts/simulator-run.sh` reads it from the vault and hands it to `simctl` as
/// `SIMCTL_CHILD_TOPO_CLAUDE_SETUP_TOKEN`; nothing writes it down.
enum DebugRun {
    static let tokenVariable = "TOPO_CLAUDE_SETUP_TOKEN"
    static let lifetimeVariable = "TOPO_CLAUDE_SETUP_TOKEN_DAYS"
    static let sendVariable = "TOPO_DEBUG_SEND"
    static let earVariable = "TOPO_DEBUG_EAR"
    static let voiceVariable = "TOPO_DEBUG_VOICE"
    static let keepSpokenVariable = "TOPO_DEBUG_KEEP_SPOKEN"
    static let replyDelayVariable = "TOPO_DEBUG_REPLY_DELAY"
    static let loopVariable = "TOPO_DEBUG_LOOP_SECONDS"
    static let outboxVariable = "TOPO_DEBUG_OUTBOX"
    static let lookVariable = "TOPO_DEBUG_LOOK"
    static let softwareKeyboardVariable = "TOPO_DEBUG_SOFTWARE_KEYBOARD"
    static let transcriptVariable = "TOPO_DEBUG_TRANSCRIPT"

    #if os(iOS)
    /// `TOPO_DEBUG_SOFTWARE_KEYBOARD=1`: the keyboard on the screen even in a simulator with the
    /// Mac's keyboard connected, which is how a simulator starts. With the Mac's keyboard nothing
    /// rises and the screen's safe area never changes, and the glass goes short on the keyboard's
    /// own safe area (`KeyboardInset`), so a suite pressing the short well needs the keyboard a
    /// phone has. It clears the input modes' hardware layout, the simulator's own switch, through
    /// UIKit's private `setHardwareLayout:`, which is why it is here and nowhere else.
    static func softwareKeyboard(_ environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard environment[softwareKeyboardVariable] == "1" else { return }
        let clear = NSSelectorFromString("setHardwareLayout:")
        for mode in UITextInputMode.activeInputModes where mode.responds(to: clear) {
            mode.perform(clear, with: nil)
        }
    }
    #endif

    /// `TOPO_DEBUG_LOOK=<look.json>`: a look worn in place of the vault's, read by the same
    /// `LookDocument` field by field, so a UI suite can put the screen at the ends of the ranges
    /// the document accepts with no vault behind it. Nil when the variable is absent, which is
    /// every ordinary run.
    static let look: Look? = ProcessInfo.processInfo.environment[lookVariable].map { LookDocument.read($0).look }

    /// `TOPO_DEBUG_TRANSCRIPT=<empty|long|full|continuity|continuity-short>`: the chat draws these fixture turns
    /// (`PreviewTurns`) in place of the log's, so a UI suite can put Topo over a transcript of a
    /// known shape — nothing, turns with gaps beside them, and turns that leave no gap at all —
    /// whatever the account's log holds. Only what is drawn changes: the harness, the log and the
    /// microphone are the ordinary ones. Nil when the variable is absent or names none of them.
    static func transcript(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [Turn]? {
        switch environment[transcriptVariable] {
        case "empty": []
        case "long": PreviewTurns.long
        case "full": PreviewTurns.full
        case "continuity": PreviewTurns.continuity
        case "continuity-short": PreviewTurns.continuityShort
        default: nil
        }
    }

    /// `TOPO_DEBUG_LOOP_SECONDS=<seconds>`: how long the answering loop waits between passes,
    /// in place of the five seconds it ordinarily waits. A minute makes the loop too slow to be
    /// what carried a revision to the folder, so what arrives in the meantime arrived by push.
    /// Nil when the variable is absent, which is every ordinary run.
    static func loopSeconds(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Double? {
        guard let seconds = environment[loopVariable].flatMap(Double.init), seconds > 0 else { return nil }
        return seconds
    }

    /// `TOPO_DEBUG_OUTBOX=<words>`: what is on the harness's line before it is made, in place of
    /// whatever the last launch left there. Words put one turn on it, as if the app had been
    /// killed with them said and not yet in the log — which is the state a relaunch finds, the
    /// one the row has to come back into, and the one no suite can reach by sending a turn and
    /// killing the app mid-write. Empty clears the line, which is how a suite asks for a launch
    /// with nothing owed: the line is on disk, so a turn a test sent and never settled is still
    /// there for the next launch, and a test that did not say what it wanted would be testing
    /// what the test before it left.
    ///
    /// The nonce is this launch's own, so the words go under one nonce however many times they
    /// are sent, exactly as a turn said on the screen does. Does nothing at all when the variable
    /// is absent, which is every ordinary run.
    static func seedOutbox(defaults: UserDefaults = .standard,
                           environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let value = environment[outboxVariable] else { return }
        let words = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            defaults.removeObject(forKey: outboxKey)
            say("cleared the line")
            return
        }
        let entry = ["text": words, "nonce": UUID().uuidString]
        guard let data = try? JSONSerialization.data(withJSONObject: [entry]) else { return }
        defaults.set(data, forKey: outboxKey)
        say("put \"\(words)\" on the line, as a launch that found a turn owed")
    }

    /// Where the harness keeps its line. Named here as well because the seeding above runs before
    /// the harness exists.
    private static let outboxKey = "topo.harness.outbox"

    /// `TOPO_DEBUG_REPLY_DELAY=<seconds>`: how long the harness waits before it asks the model,
    /// so the reply lands well past iOS's ordinary background grace and only a working hold
    /// carries it. Nil when the variable is absent, which is every ordinary run.
    static func replyDelay(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Double? {
        guard let seconds = environment[replyDelayVariable].flatMap(Double.init), seconds > 0 else { return nil }
        return seconds
    }

    /// Waits it out, and says so. Nothing at all when the variable is absent.
    static func delayReply(_ environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard let seconds = replyDelay(environment) else { return }
        say("holding the reply \(seconds)s before the model call")
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Where the guest's long-lived token lives on this platform: the phone runs a guest, and
    /// nothing else here does.
    static var defaultGuestStore: TokenStore? {
        #if os(iOS)
        KeychainTokenStore.guest
        #else
        nil
        #endif
    }

    /// Puts a long-lived Claude Code setup token in the store as if a sign-in had just finished, so
    /// the app comes up past the sign-in screen. Does nothing when the variable is absent, which is
    /// every ordinary debug build: an engineer's own sign-in is left exactly as it was.
    ///
    /// A setup token has no refresh token — it is minted for a year and cannot be exchanged — so it
    /// is written with a life short enough to be obviously wrong if it is still there next month and
    /// long enough that no run tries to refresh it. A refresh would fail loudly rather than quietly:
    /// the empty refresh token is rejected and the turn reports it.
    @discardableResult
    static func signIn(store: TokenStore = KeychainTokenStore(),
                       guestStore: TokenStore? = defaultGuestStore,
                       environment: [String: String] = ProcessInfo.processInfo.environment,
                       now: Date = Date()) -> Bool {
        let token = (environment[tokenVariable] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }
        let days = environment[lifetimeVariable].flatMap(Double.init) ?? 30
        let tokens = Tokens(accessToken: token,
                            refreshToken: "",
                            expiresAt: now.addingTimeInterval(days * 86_400),
                            scopes: ClaudeOAuth.Configuration.claude.scopes)
        do {
            try store.save(tokens)
            // A setup token is the long-lived kind the guest runs on, so it is the guest's too.
            try guestStore?.save(tokens)
            say("signed in from \(tokenVariable) for \(Int(days)) days")
            return true
        } catch {
            say("could not write the token to the keychain: \(error)")
            return false
        }
    }

    /// What `TOPO_DEBUG_SEND` asks to be said, or nil.
    static func words(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let text = (environment[sendVariable] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Every line this prints is prefixed, so a script watching `simctl launch --console` can find
    /// them among the system's own noise.
    static func say(_ line: String) { print("[topo-debug] \(line)") }
}

#if os(iOS)
import TopoCore
import TopoTurn

extension DebugRun {
    /// One turn, driven from the launch environment rather than the keyboard: the words go through
    /// the same harness the chat screen uses — the lease, the log, the guest's resident Claude
    /// Code — and what came back is printed. A script asserts on those lines; there is no other
    /// way to send a message to a simulator from a shell without an XCUITest target and a
    /// screenful of taps.
    ///
    /// It waits first for the guest to be able to take a turn (the userland fetched, the resident
    /// process up), printing the userland's line while it waits, so the turn is the guest's
    /// answer rather than a refusal. Topo on the glass follows the turn as the chat's does, and
    /// every change of his pose is printed as `mascot:`, between `mascot: turn began for <refs>`
    /// and `mascot: turn gone for <refs>`, the refs being the turns that guest turn answers.
    ///
    /// The reply printed is the one to the turn this run sent, found by that turn's nonce and the
    /// reply's parents, never merely the newest reply in the log; it carries `TOPO_DEBUG_RUN`,
    /// the id the script launched this run under, so a line from any other launch matches nothing;
    /// and it names the guest session and the resident process that wrote it.
    @MainActor
    static func send(with harness: Harness, mascot: Mascot,
                     environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard let text = words(environment) else { return }
        let run = environment[runVariable] ?? ""
        say("model: \(ClaudeModel.effective(harness.model).rawValue) (setting: \(harness.model.rawValue))")
        if let guest = harness.guest {
            var said = ""
            while true {
                do {
                    try await guest.ready()
                    break
                } catch {
                    let line = "\(error)"
                    if line != said { say("guest: waiting: \(line)") }
                    said = line
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            say("guest: ready")
        }
        let chat = harness.onGuest
        var pose = mascot.state.activity
        harness.onGuest = { activity in
            chat?(activity)
            switch activity {
            case .began(let pid, let answering):
                pose = mascot.state.activity
                say("mascot: turn began for \(refs(answering)), process \(pid.map(String.init) ?? "none"), \(pose.rawValue)")
            case .update:
                if mascot.state.activity != pose {
                    pose = mascot.state.activity
                    say("mascot: \(pose.rawValue)")
                }
            case .gone(let answering):
                pose = mascot.state.activity
                say("mascot: turn gone for \(refs(answering)), \(pose.rawValue)")
            }
        }
        defer { harness.onGuest = chat }
        say("sending: \(text)")
        let nonce = harness.willSend(text)
        await harness.retry()
        await harness.refresh()
        if let error = harness.error {
            say("error: \(error)")
        }
        let answered = answer(to: nonce, in: harness.turns)
        var by: (session: String?, pid: Int32?)?
        if case .answered(_, let reply) = answered { by = await harness.guest?.provenance(of: reply.nonce) }
        say(line(for: answered, nonce: nonce, run: run, by: by))
        say("turns in the log: \(harness.turns.count)")
        say("done")
    }

    /// The turns a guest turn answers as the mascot's lines name them, joined by `+`: the refs
    /// the reply line names its turn by, so the script ties the two.
    static func refs(_ answering: [TurnRef]) -> String {
        answering.isEmpty ? "none" : answering.map(\.description).joined(separator: "+")
    }

    static let runVariable = "TOPO_DEBUG_RUN"

    /// Where the turn sent under a nonce stands in the log.
    enum Answer: Equatable {
        /// No person's turn carries the nonce: the words never reached the log.
        case notInLog
        /// The person's turn is in the log and nothing answers it.
        case unanswered(Turn)
        /// The person's turn and the first reply that names it as a parent.
        case answered(Turn, reply: Turn)
    }

    /// The reply to the person's turn appended under `nonce`: an assistant turn continuing from
    /// that turn, whether it is its only parent (`TurnRunner.run`) or one of the heads a reply
    /// joins (`answerPending`). A reply to any other turn, older or newer, is not an answer to it.
    static func answer(to nonce: String, in turns: [Turn]) -> Answer {
        guard !nonce.isEmpty,
              let person = turns.first(where: { $0.role == .person && $0.nonce == nonce }) else { return .notInLog }
        guard let reply = turns.first(where: { $0.role == .assistant && $0.parents.contains(person.ref) }) else {
            return .unanswered(person)
        }
        return .answered(person, reply: reply)
    }

    /// The line `scripts/simulator-run.sh` asserts on. Only `reply to <ref> in run <run> from
    /// session <id>, process <pid>: ` passes: `by` is the guest session and resident process that
    /// wrote the reply, `none` for each this launch did not see write it.
    static func line(for answer: Answer, nonce: String, run: String,
                     by: (session: String?, pid: Int32?)? = nil) -> String {
        switch answer {
        case .notInLog:
            return "not in the log: no turn under \(nonce) in run \(run)"
        case .unanswered(let person):
            return "no reply to \(person.ref) in run \(run)"
        case .answered(let person, let reply):
            let session = by?.session ?? "none", process = by?.pid.map(String.init) ?? "none"
            return "reply to \(person.ref) in run \(run) from session \(session), process \(process): "
                + reply.text.replacingOccurrences(of: "\n", with: " ")
        }
    }

    /// The ear a debug build starts with. `TOPO_DEBUG_EAR=stub` is one resident without a model:
    /// a press runs the whole of `VoiceInput` (the tap, the sample sink, the caption loop, the
    /// decode at the release) over an engine that hears nothing. `TOPO_DEBUG_EAR=loading` is one
    /// whose load never finishes, so every press is refused with the ear's reason, however fast
    /// the real models would have downloaded. `TOPO_DEBUG_EAR=` an
    /// absolute directory holding `parakeet-tdt-0.6b-v2` and `parakeet-ctc-110m-coreml` is the
    /// real ear, loaded from there instead of the app's own download, which is how the UI test
    /// gets Parakeet resident in a simulator without the background download. Any other launch
    /// gets the real ear, prepared as usual.
    @MainActor
    static func ear(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Ear {
        guard let choice = environment[earVariable], !choice.isEmpty else { return Ear() }
        if choice == "loading" {
            let ear = Ear(engine: StubEngine(loads: false))
            let nowhere = URL(fileURLWithPath: "/dev/null")
            ear.load(parakeet: nowhere, ctc: nowhere)
            say("ear: loading, and never resident, so every press is refused")
            return ear
        }
        if choice == "stub" {
            let ear = Ear(engine: StubEngine())
            let nowhere = URL(fileURLWithPath: "/dev/null")
            ear.load(parakeet: nowhere, ctc: nowhere)
            say("ear: a stub, resident without a model")
            return ear
        }
        let root = URL(fileURLWithPath: choice, isDirectory: true)
        let ear = Ear()
        ear.load(parakeet: root.appendingPathComponent(ModelManifest.parakeet, isDirectory: true),
                 ctc: root.appendingPathComponent(ModelManifest.ctc, isDirectory: true))
        say("ear: Parakeet from \(root.path)")
        return ear
    }

    /// The voice a debug build starts with. `TOPO_DEBUG_VOICE=loading` is one that never becomes
    /// resident, so no reply is read aloud however much of Pocket is on the phone.
    /// `TOPO_DEBUG_VOICE=` an absolute directory holding the pack under
    /// `Models/pocket-tts/v2.1/english` is the real voice, loaded from there instead of the
    /// app's own download, which is how a lane gets Pocket resident in a simulator without the
    /// background download. Any other launch gets the real voice, prepared as usual.
    @MainActor
    static func voice(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Voice {
        guard let choice = environment[voiceVariable], !choice.isEmpty else { return Voice() }
        if choice == "loading" {
            say("voice: loading, and never resident")
            return Voice.stalledVoice()
        }
        let base = URL(fileURLWithPath: choice, isDirectory: true)
        let voice = Voice()
        voice.load(base: base)
        say("voice: Pocket from \(base.path)")
        return voice
    }

    /// The chat screen's report for the spoken-turn UI test, on the title's accessibility value.
    struct ChatReport: Codable, Equatable {
        /// The nonce of the last turn the chat sent from the microphone; nil before one.
        var spoken: String?
        /// That turn in the log, and the first reply naming it among its parents.
        var person: TurnReport?
        var reply: TurnReport?
        /// The error line on the chat screen, if any.
        var error: String?
        var speaker: Speaker.Report
        /// The voice's state, so a lane waits for Pocket to be resident rather than sending a
        /// question the speaker would have nothing to read it with.
        var voice: String
        /// Where Topo stands over the chat, and whether he is hidden; nil before he has been placed.
        var mascot: MascotRoam.Report?
    }

    struct TurnReport: Codable, Equatable {
        var ref: String
        var parents: [String]
        var text: String

        init(_ turn: Turn) {
            ref = turn.ref.description
            parents = turn.parents.map(\.description)
            text = turn.text
        }
    }

    static let chatReportIdentifier = "topo-debug-chat"

    static func chatReport(spoken: String?, turns: [Turn], error: String?, speaker: Speaker.Report,
                           voice: Voice.State, mascot: MascotRoam.Report? = nil) -> String {
        var report = ChatReport(spoken: spoken, error: error, speaker: speaker, voice: "\(voice)", mascot: mascot)
        switch spoken.map({ answer(to: $0, in: turns) }) {
        case .unanswered(let person):
            report.person = TurnReport(person)
        case .answered(let person, let reply):
            report.person = TurnReport(person)
            report.reply = TurnReport(reply)
        case .notInLog, nil:
            break
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(report)).flatMap { String(data: $0, encoding: .utf8) } ?? "unencodable"
    }

    /// `TOPO_DEBUG_KEEP_SPOKEN=1`: what a press hears is printed and not sent, so a UI test
    /// that speaks into the microphone takes no turn.
    static func keepsSpoken(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[keepSpokenVariable] == "1"
    }

    /// Loads nothing, builds no session, hears nothing. One that `loads: false` never returns
    /// from its load, which holds the ear at `loading`.
    struct StubEngine: SpeechEngine {
        var loads = true
        func load(parakeet: URL, ctc: URL, onProgress: @escaping @Sendable (String) -> Void) async throws {
            guard !loads else { return }
            while true { try await Task.sleep(for: .seconds(3600)) }
        }
        func rebuild(terms: [String], version: Int) async throws {}
        func transcribe(_ samples: [Float], boosted: Bool) async throws -> String { "" }
    }
}
#endif
#endif
