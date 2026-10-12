import AppIntents
import Foundation

/// What Topo offers the Shortcuts app, Siri and Spotlight: three actions, each of which hands
/// Topo a turn and none of which waits for the reply, since a reply is the guest's work of
/// minutes and an intent has seconds.
///
/// Each asks for the phone to be unlocked (`authenticationPolicy`): a prompt is words from
/// whoever holds the phone, and a turn is something the mind acts on.
///
/// - **Ask Topo** takes a prompt and brings Topo forward, where the answer is read.
/// - **Follow up with Topo** takes a prompt and leaves Topo where it is: the turn goes on the
///   conversation in the background.
/// - **Topo quick task** takes one of `QuickTask`'s names, in the background too.
///
/// A turn from a Shortcut goes the way a share does: kept in `ShareStore` under a nonce minted
/// here and the login the door names, and put on the line by `ShareInbox`, so it is one turn
/// however often it is drained, never sent under another login, and gone at a sign-out. A prompt
/// is whatever the Shortcut passed, which an automation can take from a message or a web page, so
/// its turn says a Shortcut sent it; a quick task's words are the app's own.
///
/// The intents are the app's alone, so each runs in the app's process, launched into the
/// background when it is not running.
enum ShortcutIntents {
    /// Puts what is kept on the line, set by `TopoApp` at launch, which the system finishes
    /// before an intent it launched the app for runs.
    @MainActor static var drain: (@MainActor () async -> Void)?
    /// Whether the turn under a nonce is in the log, set beside `drain`.
    @MainActor static var landed: (@MainActor (String) -> Bool)?

    /// How long a background intent waits for its turn to reach the log: a read and a write of
    /// the log, inside the time the system gives an intent.
    static let bound: Duration = .seconds(20)
    static let glance: Duration = .milliseconds(100)

    /// Keeps a turn for the drain, and answers what was kept. Refused where the phone is signed
    /// out, the prompt is empty or over the limit, or as many shares as the store holds wait.
    static func keep(_ kind: Share.Kind, _ text: String, in store: ShareStore?, nonce: String = UUID().uuidString,
                     at time: Date = Date()) throws(ShareRefusal) -> Share {
        guard let store, let door = store.door() else { throw .signedOut }
        let share = Share(nonce: nonce, login: door.login, time: time, kind: kind, note: "", text: text)
        try store.keep(share)
        return share
    }

    /// Keeps the turn and starts a drain, which runs on whatever this does. A background intent
    /// then waits until its turn is in the log, or `bound` has passed, so the turn is saved
    /// before the system suspends the app again; it never waits on the drain itself, whose end
    /// is the reply's. One that brings Topo forward returns at once. What is kept is sent when
    /// Topo next drains, whether or not the wait saw it land.
    @MainActor
    static func send(_ kind: Share.Kind, _ text: String, waits: Bool, in store: ShareStore? = ShareStore.shared(),
                     drain: (@MainActor () async -> Void)? = ShortcutIntents.drain,
                     landed: (@MainActor (String) -> Bool)? = ShortcutIntents.landed,
                     bound: Duration = ShortcutIntents.bound) async throws(ShortcutRefusal) {
        let kept: Share
        do {
            kept = try keep(kind, text, in: store)
        } catch {
            throw ShortcutRefusal(refusal: error)
        }
        guard let drain else { return }
        Task { await drain() }
        guard waits, let landed else { return }
        let clock = ContinuousClock()
        let deadline = clock.now + bound
        while !landed(kept.nonce), clock.now < deadline {
            try? await Task.sleep(for: glance)
        }
    }
}

/// Why a Shortcut's turn was not kept, said by Shortcuts or Siri.
struct ShortcutRefusal: Error, CustomLocalizedStringResourceConvertible {
    var refusal: ShareRefusal

    var localizedStringResource: LocalizedStringResource {
        switch refusal {
        case .signedOut: "Open Topo and sign in first."
        case .nothing: "There is nothing there to send Topo."
        case .tooLong: "That is more text than Topo takes at once."
        case .tooMany: "Topo is holding as much as it can. Open Topo so it can read it."
        case .anotherPhone, .tooLarge, .failed: "Topo could not take that."
        }
    }
}

struct AskTopoIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Topo"
    static let description = IntentDescription("Opens Topo and sends it what you ask. The answer is in the conversation.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Prompt", requestValueDialog: "What do you want to ask Topo?")
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Topo \(\.$prompt)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ShortcutIntents.send(.prompt, prompt, waits: false)
        return .result()
    }
}

struct FollowUpIntent: AppIntent {
    static let title: LocalizedStringResource = "Follow up with Topo"
    static let description = IntentDescription("Sends Topo something more in the conversation, without opening it. The answer is there when you next open Topo.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Prompt", requestValueDialog: "What do you want to tell Topo?")
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Follow up with Topo: \(\.$prompt)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await ShortcutIntents.send(.prompt, prompt, waits: true)
        return .result(dialog: "Topo has it. The answer will be in the conversation.")
    }
}

struct QuickTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Topo quick task"
    static let description = IntentDescription("Asks Topo for one of its usual tasks, without opening it. The answer is there when you next open Topo.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Task")
    var task: QuickTask

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Topo for \(\.$task)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await ShortcutIntents.send(.task, task.rawValue, waits: true)
        return .result(dialog: "Topo has it. The answer will be in the conversation.")
    }
}

extension QuickTask: AppEnum {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Quick task")
    static let caseDisplayRepresentations: [QuickTask: DisplayRepresentation] = [
        .today: "Today's briefing",
        .due: "What is due",
        .forgot: "What did I forget",
    ]
}

/// The three as App Shortcuts, so each is in Shortcuts, Spotlight and Siri with nothing set up.
struct TopoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskTopoIntent(), phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) something"],
                    shortTitle: "Ask Topo", systemImageName: "bubble.left")
        AppShortcut(intent: FollowUpIntent(), phrases: ["Follow up with \(.applicationName)", "Tell \(.applicationName) something"],
                    shortTitle: "Follow up", systemImageName: "arrowshape.turn.up.left")
        AppShortcut(intent: QuickTaskIntent(), phrases: ["\(.applicationName) quick task", "\(.applicationName) \(\.$task)"],
                    shortTitle: "Quick task", systemImageName: "bolt")
    }
}
