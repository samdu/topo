import Foundation
import Testing
@testable import TopoAuth

/// A `claude` that answers as the test scripts it: each `begin` is an attempt the test drives,
/// `status` answers what the test set, and every paste, end and logout is counted.
final class FakeLogin: ClaudeLogin, @unchecked Sendable {
    final class Attempt: LoginAttempt, @unchecked Sendable {
        let heard: @Sendable (LoginEvent) -> Void
        private let lock = NSLock()
        private var pasted: [String] = []
        private var ends = 0
        init(heard: @escaping @Sendable (LoginEvent) -> Void) { self.heard = heard }
        var pastes: [String] { lock.withLock { pasted } }
        var ended: Int { lock.withLock { ends } }
        func paste(_ code: String) async throws { lock.withLock { pasted.append(code) } }
        func end() async { lock.withLock { ends += 1 } }
    }

    private let lock = NSLock()
    private var made: [Attempt] = []
    private var answer: ClaudeLoginStatus? = ClaudeLoginStatus(loggedIn: false)
    private var logouts = 0
    private var progressLines: [String] = []
    var prepareError: (any Error)?

    var attempts: [Attempt] { lock.withLock { made } }
    var loggedOut: Int { lock.withLock { logouts } }
    func answer(_ status: ClaudeLoginStatus?) { lock.withLock { answer = status } }
    func say(_ lines: [String]) { lock.withLock { progressLines = lines } }

    func prepare(progress: @escaping @Sendable (String) -> Void) async throws {
        for line in lock.withLock({ progressLines }) { progress(line) }
        if let prepareError { throw prepareError }
    }

    func begin(_ heard: @escaping @Sendable (LoginEvent) -> Void) async throws -> any LoginAttempt {
        let attempt = Attempt(heard: heard)
        lock.withLock { made.append(attempt) }
        return attempt
    }

    func status() async throws -> ClaudeLoginStatus {
        guard let answer = lock.withLock({ answer }) else { throw CocoaError(.fileReadUnknown) }
        return answer
    }

    func logout() async {
        lock.withLock {
            logouts += 1
            answer = ClaudeLoginStatus(loggedIn: false)
        }
    }
}

@MainActor
func until(_ what: String, _ condition: @MainActor () -> Bool) async {
    for _ in 0..<2000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("never: \(what)")
}

@Suite @MainActor struct SignInTests {
    let browser = URL(string: "https://claude.com/cai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1234%2Fcallback")!
    let page = URL(string: "https://claude.com/cai/oauth/authorize?redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback")!
    let claudeAI = ClaudeLoginStatus(loggedIn: true, authMethod: "claude.ai", subscriptionType: "max")

    func cache() -> LoginCache {
        LoginCache(defaults: UserDefaults(suiteName: "topo-signin-\(UUID().uuidString)")!)
    }

    func ready(_ login: FakeLogin, cache: LoginCache? = nil) async -> SignIn {
        let signIn = SignIn(login: login, cache: cache ?? self.cache())
        await signIn.prepare()
        return signIn
    }

    @Test func waitsForTheGuestSayingWhatItWaitsOnThenOffersTheSignIn() async {
        let login = FakeLogin()
        login.say(["rootfs downloading 40%"])
        let signIn = SignIn(login: login, cache: cache())
        #expect(signIn.phase == .preparing(""))
        await signIn.prepare()
        #expect(signIn.phase == .idle)
    }

    @Test func aGuestThatCannotStartIsAFailureOnTheScreen() async {
        let login = FakeLogin()
        login.prepareError = CocoaError(.fileNoSuchFile)
        let signIn = await ready(login)
        guard case .failed = signIn.phase else { Issue.record("\(signIn.phase)"); return }
    }

    @Test func theBrowserURLOpensTheSheetAndExit0WithClaudeAIIsSignedIn() async throws {
        let login = FakeLogin()
        let cache = cache()
        let signIn = await ready(login, cache: cache)
        signIn.start()
        await until("the login began") { login.attempts.count == 1 }
        let attempt = login.attempts[0]
        attempt.heard(.browser(browser))
        attempt.heard(.pastePage(page))
        await until("the sheet") { signIn.sheet?.url == browser }
        #expect(signIn.sheet?.kind == .approve)
        await until("the page kept") { signIn.phase == .approving(.init(page: page, pasting: false)) }
        login.answer(claudeAI)
        attempt.heard(.ended(.succeeded))
        await until("signed in") { signIn.phase == .signedIn }
        #expect(signIn.sheet == nil)
        #expect(cache.status == claudeAI)
        #expect(cache.isSignedIn)
    }

    @Test func exit0WithoutClaudeAIIsAFailureNotASignIn() async {
        let login = FakeLogin()
        let cache = cache()
        let signIn = await ready(login, cache: cache)
        signIn.start()
        await until("the login began") { login.attempts.count == 1 }
        login.answer(ClaudeLoginStatus(loggedIn: true, authMethod: "oauth_token"))
        login.attempts[0].heard(.ended(.succeeded))
        await until("failed") { if case .failed = signIn.phase { true } else { false } }
        #expect(!cache.isSignedIn)
    }

    @Test func loginFailedIsWhatTheScreenSays() async {
        let login = FakeLogin()
        let signIn = await ready(login)
        signIn.start()
        await until("the login began") { login.attempts.count == 1 }
        login.attempts[0].heard(.ended(.failed("Login failed: Invalid state parameter")))
        await until("failed") { signIn.phase == .failed("Login failed: Invalid state parameter") }
        signIn.start()
        await until("a second login") { login.attempts.count == 2 }
    }

    @Test func closingTheLoopbackSheetEndsTheLoginButClosingThePastePageDoesNot() async {
        let login = FakeLogin()
        let signIn = await ready(login)
        signIn.start()
        await until("the login began") { login.attempts.count == 1 }
        let attempt = login.attempts[0]
        attempt.heard(.browser(browser))
        attempt.heard(.pastePage(page))
        await until("the sheet") { signIn.sheet?.kind == .approve }
        signIn.openPageAgain()
        let pageSheet = signIn.sheet
        #expect(pageSheet?.url == page)
        #expect(pageSheet?.kind == .page)
        #expect(signIn.phase == .approving(.init(page: page, pasting: true)))
        signIn.sheetClosed(pageSheet!)
        #expect(signIn.sheet == nil)
        #expect(signIn.phase == .approving(.init(page: page, pasting: true)))
        await signIn.paste("  code#state \n")
        #expect(attempt.pastes == ["code#state"])
        #expect(attempt.ended == 0)

        // The loopback's sheet, closed by the person, ends the login.
        attempt.heard(.browser(browser))
        await until("the sheet again") { signIn.sheet?.kind == .approve }
        signIn.sheetClosed(signIn.sheet!)
        #expect(signIn.phase == .idle)
        await until("the login ended") { attempt.ended == 1 }
    }

    @Test func aSheetReplacedBeforeItWasClosedIsNotTheOneClosed() async {
        let login = FakeLogin()
        let signIn = await ready(login)
        signIn.start()
        await until("the login began") { login.attempts.count == 1 }
        let attempt = login.attempts[0]
        attempt.heard(.browser(browser))
        attempt.heard(.pastePage(page))
        await until("the sheet") { signIn.sheet?.kind == .approve }
        let first = signIn.sheet!
        signIn.openPageAgain()
        signIn.sheetClosed(first)
        if case .approving = signIn.phase {} else { Issue.record("a replaced sheet's close ended the login") }
        #expect(attempt.ended == 0)
    }

    @Test func openThePageAgainWithNoLoginRunningStartsAFreshOne() async {
        let login = FakeLogin()
        let signIn = await ready(login)
        signIn.start()
        await until("the login began") { login.attempts.count == 1 }
        login.attempts[0].heard(.ended(.stopped))
        await until("failed") { if case .failed = signIn.phase { true } else { false } }
        signIn.openPageAgain()
        await until("a fresh login") { login.attempts.count == 2 }
    }

    @Test func whatACancelledLoginSaysAfterReachesNothing() async {
        let login = FakeLogin()
        let signIn = await ready(login)
        signIn.start()
        await until("the login began") { login.attempts.count == 1 }
        let attempt = login.attempts[0]
        signIn.cancel()
        #expect(signIn.phase == .idle)
        await until("ended") { attempt.ended == 1 }
        attempt.heard(.browser(browser))
        login.answer(claudeAI)
        attempt.heard(.ended(.succeeded))
        for _ in 0..<200 { await Task.yield() }
        #expect(signIn.phase == .idle)
        #expect(signIn.sheet == nil)
    }

    @Test func signOutClearsTheCacheAtOnceAndLogsOutAfter() async {
        let login = FakeLogin()
        let cache = cache()
        cache.save(claudeAI)
        login.answer(claudeAI)
        let signIn = SignIn(login: login, cache: cache)
        #expect(signIn.phase == .signedIn)
        signIn.signOut()
        #expect(!cache.isSignedIn, "the cache still said signed in when the sign-out returned")
        #expect(signIn.phase == .idle)
        await signIn.loggedOut()
        #expect(login.loggedOut == 1)
    }

    @Test func signOutWithSomethingLeftSaysIt() async {
        let login = FakeLogin()
        let cache = cache()
        cache.save(claudeAI)
        let signIn = SignIn(login: login, cache: cache)
        signIn.signOut(unfinished: "GitHub's token is still in the keychain")
        #expect(signIn.phase == .failed("Signed out, but GitHub's token is still in the keychain"))
    }

    @Test func aRefreshAtBootSignsOutALoginThatHasGoneAndKeepsOneThatHasNot() async {
        let login = FakeLogin()
        let cache = cache()
        cache.save(claudeAI)
        let signIn = SignIn(login: login, cache: cache)
        login.answer(claudeAI)
        await signIn.refresh()
        #expect(signIn.phase == .signedIn)
        login.answer(ClaudeLoginStatus(loggedIn: false))
        await signIn.refresh()
        #expect(signIn.phase == .idle)
        #expect(!cache.isSignedIn)
    }

    @Test func aStatusThatCannotBeReadChangesNothing() async {
        let login = FakeLogin()
        let cache = cache()
        cache.save(claudeAI)
        let signIn = SignIn(login: login, cache: cache)
        login.answer(nil)
        await signIn.refresh()
        #expect(signIn.phase == .signedIn)
        #expect(cache.isSignedIn)
    }

    @Test func aRefreshAfterASignOutWaitsForItsLogout() async {
        let login = FakeLogin()
        let cache = cache()
        cache.save(claudeAI)
        login.answer(claudeAI)
        let signIn = SignIn(login: login, cache: cache)
        signIn.signOut()
        await signIn.refresh()
        #expect(signIn.phase == .idle, "a status read before the logout signed the phone back in")
        #expect(!cache.isSignedIn)
    }

    @Test func aDeveloperTokenIsAcceptedWhereTheBuildSaysSo() async {
        let login = FakeLogin()
        let cache = cache()
        cache.save(ClaudeLoginStatus(loggedIn: true, authMethod: "oauth_token"))
        login.answer(ClaudeLoginStatus(loggedIn: true, authMethod: "oauth_token"))
        let signIn = SignIn(login: login, cache: cache, accept: { $0.loggedIn })
        await signIn.refresh()
        #expect(signIn.phase == .signedIn)
    }
}

@Suite struct ClaudeLoginStatusTests {
    @Test func readsTheJSONClaudeCodePrints() {
        let output = """
        {
          "loggedIn": true,
          "authMethod": "claude.ai",
          "apiProvider": "firstParty",
          "email": "someone@example.com",
          "subscriptionType": "max"
        }
        """
        let status = ClaudeLoginStatus.parse(output)
        #expect(status == ClaudeLoginStatus(loggedIn: true, authMethod: "claude.ai", subscriptionType: "max"))
        #expect(status?.isClaudeAI == true)
        #expect(status?.summary == "claude.ai, max")
    }

    @Test func aTokenFromTheEnvironmentIsNotClaudeAI() {
        let status = ClaudeLoginStatus.parse(#"{"loggedIn": true, "authMethod": "oauth_token"}"#)
        #expect(status?.isClaudeAI == false)
    }

    @Test func noJSONIsNoStatus() {
        #expect(ClaudeLoginStatus.parse("Not logged in") == nil)
        #expect(ClaudeLoginStatus.parse("") == nil)
        #expect(ClaudeLoginStatus.parse(#"{"loggedIn": false}"#)?.summary == "signed out")
    }
}

/// The item round trip, and the migration's deletes, against a keychain of the test's own on the
/// Mac (`TemporaryKeychain`), so neither needs an unlocked login keychain nor writes to it. A
/// keychain that cannot be created, set or unlocked fails the test at a `#require`.
@Suite struct KeychainItemTests {
    func item(_ account: String = UUID().uuidString, in keychain: Any?) -> KeychainItem {
        var item = KeychainItem(service: "zone.hexagon.topo.tests", account: account)
        #if os(macOS)
        item.keychainPath = (keychain as? TemporaryKeychain)?.path
        #endif
        return item
    }

    func keychain() throws -> Any? {
        #if os(macOS)
        return try TemporaryKeychain()
        #else
        return nil
        #endif
    }

    func delete(_ keychain: Any?) {
        #if os(macOS)
        (keychain as? TemporaryKeychain)?.delete()
        #endif
    }

    @Test func roundTripsThroughTheKeychain() throws {
        let keychain = try keychain()
        defer { delete(keychain) }
        let item = item(in: keychain)
        defer { try? item.delete() }
        #expect(try item.read() == nil)
        try item.write(Data("a".utf8))
        #if os(macOS)
        #expect((keychain as! TemporaryKeychain).holdsItem(service: item.service, account: item.account),
                "the item was written outside the keychain it was pointed at")
        #endif
        #expect(try item.read() == Data("a".utf8))
        try item.write(Data("b".utf8))
        #expect(try item.read() == Data("b".utf8))
        try item.delete()
        #expect(try item.read() == nil)
    }

    @Test func theMigrationDeletesTheOldItemsAndSaysSo() throws {
        let keychain = try keychain()
        defer { delete(keychain) }
        let ordinary = item("claude", in: keychain), guest = item("claude-guest", in: keychain)
        defer { try? ordinary.delete(); try? guest.delete() }
        let defaults = UserDefaults(suiteName: "topo-migration-\(UUID().uuidString)")!
        #expect(!LoginMigration.run(items: [ordinary, guest], defaults: defaults))
        #expect(!defaults.bool(forKey: LoginMigration.signInAgainKey))
        try ordinary.write(Data("tokens".utf8))
        try guest.write(Data("guest".utf8))
        #expect(LoginMigration.run(items: [ordinary, guest], defaults: defaults))
        #expect(try ordinary.read() == nil)
        #expect(try guest.read() == nil)
        #expect(defaults.bool(forKey: LoginMigration.signInAgainKey))
    }

    @Test func theMigrationNamesTheItemsTheOldBuildKept() {
        #expect(LoginMigration.items.map(\.service) == ["zone.hexagon.topo.claude", "zone.hexagon.topo.claude"])
        #expect(LoginMigration.items.map(\.account) == ["claude", "claude-guest"])
    }
}
