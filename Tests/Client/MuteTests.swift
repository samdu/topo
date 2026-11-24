import AVFoundation
import Foundation
import SwiftUI
import TopoAuth
import TopoCore
import TopoCoreTesting
import TopoTurn
import UIKit
import XCTest

@testable import Topo

/// The mute as the chat reads it (#793): a reply to a turn the open microphone sends is read aloud
/// when the mute says so at the send, not when the chat's screen first answered.
@MainActor
final class MuteTests: XCTestCase {
    private var kept: [String: Any?] = [:]
    /// What the hosted chat writes in the standard defaults: the mute, and the first run, which a
    /// send over an empty log may mark answered.
    private let keys = [Mute.key, "firstRunAnswered"]

    override func setUp() {
        super.setUp()
        // The chat's `@AppStorage` is the standard defaults', and so is `Mute.readsAloud()`, so the
        // test writes there and puts back what it found.
        for key in keys { kept[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() {
        for key in keys {
            if let value = kept[key] ?? nil { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    private func settle(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                        until condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<3_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "waited half a minute for \(what)", file: file, line: line)
    }

    /// Muted when the chat appeared and unmuted after: the open microphone's next turn is marked
    /// spoken, its reply waited for, with no relaunch between.
    func testAnUnmuteReachesTheOpenMicrophonesNextTurn() async throws {
        try await change(to: true, rerendered: false)
    }

    /// The same with the chat drawn again by what holds it between its appearing and the unmute,
    /// as the root draws it on any change it follows: the open microphone sends through the closure
    /// the chat's task installed, whose copy of the view is then older than the one drawn and does
    /// not see the mute change (#793).
    func testAnUnmuteReachesTheOpenMicrophonesNextTurnOverADrawnAgainChat() async throws {
        try await change(to: true, rerendered: true)
    }

    /// The other way: read aloud when the chat appeared and muted after it was drawn again, the
    /// open microphone's next turn is not a spoken one, so nothing waits for a reply nobody hears.
    func testAMuteReachesTheOpenMicrophonesNextTurnOverADrawnAgainChat() async throws {
        try await change(to: false, rerendered: true)
    }

    /// Mounts the chat with replies read aloud or muted (the other of `readsAloud`), draws it
    /// again from its holder if `rerendered`, sets the mute to `readsAloud` and sends through the
    /// open microphone's send.
    private func change(to readsAloud: Bool, rerendered: Bool) async throws {
        UserDefaults.standard.set(!readsAloud, forKey: Mute.key)

        let name = "topo.tests.mute.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let center = NotificationCenter()
        let seams = Seams()
        let audio = AudioSession(center: center, configure: seams.configure,
                                 deactivate: seams.deactivate, isActive: { true })
        let voice = Voice(engine: GatedSentences())
        voice.load(folder: URL(fileURLWithPath: "/dev/null"))
        await settle("the voice to load") { voice.state == .ready }
        let speaker = Speaker(audio: audio, voice: voice, center: center,
                              makeEngine: { seams.makePlayEngine(rate: Voice.rate) }, heard: .dataRendered)
        let input = VoiceInput(audio: audio, center: center)
        let conversation = Conversation(voice: input, speaker: speaker, endpoint: Endpoint(),
                                        holding: { false }, center: center)
        let db = InMemoryRecordDatabase()
        let harness = Harness(database: db, device: DeviceID("phone"), ensureZone: {}, defaults: defaults,
                              brain: Unanswering())
        let signIn = SignIn(login: SignedIn(), cache: LoginCache(defaults: defaults))
        let roles = RoleSelector(database: db, device: DeviceID("phone"), defaults: defaults,
                                 isSignedIn: { true }, ensureZone: {})
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let memory = Memory(directory: folder, store: MemoryStore(database: db), device: DeviceID("phone"),
                            isSignedIn: { true }, ensureZone: {})
        let connections = Connections(store: InMemoryConnectionStore(), leftBehind: .isolated(),
                                      clearControlSecrets: {})

        let ticker = Ticker()
        let chat = Host(ticker: ticker)
            .environment(harness).environment(signIn).environment(roles).environment(memory)
            .environment(connections).environment(input).environment(speaker).environment(conversation)
            .environment(Mascot())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: chat)
        window.isHidden = false
        defer { window.isHidden = true }

        await settle("the chat to install its send") { conversation.send != nil }
        if rerendered {
            let drawn = ticker.draws
            ticker.tick += 1
            window.layoutIfNeeded()
            await settle("the holder to draw the chat again") { ticker.draws > drawn }
        }
        // The mute's button writes the setting through the chat's `@AppStorage`, which is the
        // standard defaults' key; the screen draws it again before the next turn is heard.
        UserDefaults.standard.set(readsAloud, forKey: Mute.key)
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()

        let send = try XCTUnwrap(conversation.send)
        // The brain never answers, so the mark the send makes is not taken away by a reply or a
        // failure before it is read.
        // The send's task is the main actor's, and everything up to the mark (the row, the wait
        // and the mark itself) runs in the same job as the flag before its first suspension, the
        // attempt: once the flag reads set, the mark or its absence is made.
        let began = Flag()
        let sending = Task { @MainActor in
            began.set = true
            await send("what time is it")
        }
        defer { sending.cancel() }
        await settle("the send to begin") { began.set }
        let marked = defaults.stringArray(forKey: "topo.harness.spoken")?.count ?? 0
        if readsAloud {
            XCTAssertEqual(marked, 1, "an unmuted turn was not marked spoken: its reply would not be read aloud")
        } else {
            XCTAssertEqual(marked, 0, "a muted turn was marked spoken: a reply nobody hears is waited for")
            XCTAssertTrue(speaker.awaiting.isEmpty, "a muted turn's reply is waited for")
        }
        speaker.endAllWaits("the test is done")
        conversation.send = nil
    }
}

/// Whether the send's task has begun.
@MainActor
private final class Flag {
    var set = false
}

/// What the test moves to have the chat's holder draw it again.
@MainActor @Observable
private final class Ticker {
    var tick = 0
    /// The holder's draws, counted where it draws, which is what says it drew the chat again.
    @ObservationIgnored var draws = 0
}

/// The chat as the root holds it, drawn again whenever the ticker moves.
private struct Host: View {
    let ticker: Ticker
    var body: some View {
        let _ = ticker.draws += 1
        return NavigationStack {
            ChatView().overlay(alignment: .top) { Text("\(ticker.tick)").hidden() }
        }
    }
}

/// A brain that answers nothing until it is cancelled: the test is done before a reply would land.
private struct Unanswering: Brain {
    struct NotHere: Error {}
    func answer(_ request: BrainRequest) async throws -> Reply {
        try await Task.sleep(for: .seconds(3_600))
        throw NotHere()
    }
    func describe() async -> String { "no brain" }
}

/// A Claude Code that is signed in.
private struct SignedIn: ClaudeLogin {
    func prepare(progress: @escaping @Sendable (String) -> Void) async throws {}
    func begin(_ heard: @escaping @Sendable (LoginEvent) -> Void) async throws -> any LoginAttempt { throw CancellationError() }
    func status() async throws -> ClaudeLoginStatus { ClaudeLoginStatus(loggedIn: true, authMethod: "claude.ai", subscriptionType: "max") }
    func logout() async -> Bool { true }
    func discardCredential() {}
}
