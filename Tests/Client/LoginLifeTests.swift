import ImageIO
import TopoAuth
import TopoCore
import TopoCoreTesting
import XCTest

@testable import Topo

/// The one place a login's end is heard (`LoginLife`): the epoch work begun under a login checks,
/// the teardowns features register, and the paths that end a login reaching both.
@MainActor
final class LoginLifeTests: XCTestCase {
    func testAnEpochIsCurrentUntilTheLoginEnds() {
        let login = LoginLife()
        let before = login.epoch
        XCTAssertTrue(before.isCurrent)
        login.moveEpoch()
        XCTAssertFalse(before.isCurrent, "work from the ended login would still be kept")
        XCTAssertTrue(login.epoch.isCurrent, "work of the next login would be dropped")
    }

    /// Work begun after a sign-out's first step, while the sign-out is under way, is not current
    /// once the teardowns run.
    func testWorkBegunDuringTheSignOutIsNotCurrentAfterTheTeardowns() {
        let login = LoginLife()
        login.moveEpoch()
        let during = login.epoch
        XCTAssertTrue(during.isCurrent)
        login.runTeardowns()
        XCTAssertFalse(during.isCurrent, "work begun during the sign-out would land after its teardowns and keep what it made")
    }

    func testTeardownsRunInTheOrderRegisteredAtEveryEnd() {
        let login = LoginLife()
        var ran: [String] = []
        login.onEnd { ran.append("a") }
        login.onEnd { ran.append("b") }
        login.end()
        login.end()
        XCTAssertEqual(ran, ["a", "b", "a", "b"])
    }

    func testAnAwaitingTeardownIsWaitedFor() async {
        let login = LoginLife()
        var done = false
        login.onEnd(awaiting: {
            for _ in 0..<5 { await Task.yield() }
            done = true
        })
        login.end()
        XCTAssertFalse(done)
        await login.tornDown()
        XCTAssertTrue(done)
    }

    /// A teardown runs under the moved epoch: one guarded by `isCurrent` would never run, which is
    /// why the rule is that a teardown never checks it. This one does its work and sees the
    /// epoch of the login it ends already gone.
    func testATeardownRunsUnderTheMovedEpoch() async {
        let login = LoginLife()
        let held = login.epoch
        var sawCurrent: Bool?
        var cleared = false
        login.onEnd {
            sawCurrent = held.isCurrent
            cleared = true
        }
        await SignOut(moveEpoch: { login.moveEpoch() }, stopSpeaking: {}, forgetShares: {}, forgetHarness: {}, forgetMemory: {},
                      runTeardowns: { login.runTeardowns() }, forgetSurfaces: {}, forgetConnections: {}, forgetLogin: {}).act()
        XCTAssertEqual(sawCurrent, false)
        XCTAssertTrue(cleared, "the teardown did not run")
    }

    /// The fourth way a login ends: a refresh at a guest's boot finds it gone (`SignIn.refresh`),
    /// the phase leaves signed in with no sign-out's steps run, and the app's phase observer hands
    /// that to `DefaultSurface.follow`. The activities, the slots' records and the pictures go
    /// with it, as at a sign-out.
    func testALoginLostToARefreshEndsWhatTheLoginHeld() async throws {
        let login = LoginLife()
        // An activity running, with its until task kept.
        let clock = FakeClock()
        let host = FakeActivityHost()
        let keeper = ActivityKeeper(host: host, fetcher: FakeTrackerFetcher([]), sleep: { try await clock.sleep($0) }, now: { clock.date },
                                    login: login)
        let tracker = try XCTUnwrap(ProgressTracker.read(Data(TrackerFixtures.wiki.utf8)).tracker)
        let id = try host.start(TopoActivityAttributes(slot: "job", poll: nil, started: clock.date),
                                ActivityNotice(state: ActivityState(card: TrackerCard(tracker), until: clock.date.addingTimeInterval(600)),
                                               stale: nil, relevance: nil))
        keeper.keep(id)
        XCTAssertEqual(keeper.tasks, 1)
        // A slot's record this phone saved.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("login-life-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SurfaceStore(folder: folder)
        try store.write(WidgetDocument.read(WidgetTool.example).document, slot: "demo")
        let records = InMemoryRecordDatabase()
        let sync = SurfaceSync(records: { SurfaceRecords(database: records) }, ensureZone: {}, mayOwn: { true }, demoted: { _ in true },
                               store: { store }, runner: "phone", defaults: UserDefaults(suiteName: "login-life-\(UUID().uuidString)")!,
                               login: login)
        guard case .record(let demo) = sync.snapshot(slot: "demo", store) else { return XCTFail("demo is not readable") }
        try await SurfaceRecords(database: records).save(demo, over: .none)
        // A picture read for a bubble.
        TurnImages.clear()
        defer { TurnImages.clear() }
        TurnImages.endWith(login)
        let image = try XCTUnwrap(TurnImage.find(in: "[Attached in Topo from this phone: an image, kept at /home/topo/shared/n/a.png (1 bytes)]"))
        let png = try XCTUnwrap(PictureFixture.png())
        _ = await TurnImages.load(image, from: TurnImageFiles(data: { _ in png }))
        XCTAssertNotNil(TurnImages.cached(image))

        // Signed in, then a refresh that finds the login gone.
        let cache = LoginCache(defaults: UserDefaults(suiteName: "login-life-\(UUID().uuidString)")!)
        cache.save(ClaudeLoginStatus(loggedIn: true, authMethod: "claude.ai", subscriptionType: "max"))
        let signIn = SignIn(login: GoneLogin(), cache: cache)
        let was = signIn.phase
        XCTAssertEqual(was, .signedIn)
        let held = login.epoch
        await signIn.refresh()
        XCTAssertEqual(signIn.phase, .idle, "the refresh did not take the login away")
        let reloader = SurfaceReloader(reloadKind: { _ in }, reloadEverything: {}, reloadControlKind: { _ in }, reloadEveryControl: {},
                                       schedule: { _, _ in })
        // What TopoApp's `onChange(of: signIn.phase)` does.
        DefaultSurface(store: { store }, reloader: reloader, login: login).follow(from: was, to: signIn.phase, latest: nil)
        await login.tornDown()
        await sync.flush()
        XCTAssertFalse(held.isCurrent, "the login lost to the refresh left its epoch standing")

        XCTAssertEqual(host.ends.count, 1, "the activity outlived the login")
        guard case .end(id, nil, .now) = host.ends[0] else { return XCTFail("\(host.ends)") }
        XCTAssertEqual(keeper.tasks, 0, "a task of the activity outlived the login")
        let surfaces = try await records.records(ofType: SurfaceRecord.type)
        XCTAssertEqual(surfaces.filter { SurfaceRecords.Read($0).holds }.map(\.id), [], "a slot's record outlived the login")
        XCTAssertFalse(sync.owesForget)
        XCTAssertNil(TurnImages.cached(image), "a picture outlived the login")
    }
}

/// A Claude Code whose login has gone: `auth status` says signed out.
private struct GoneLogin: ClaudeLogin {
    func prepare(progress: @escaping @Sendable (String) -> Void) async throws {}
    func begin(_ heard: @escaping @Sendable (LoginEvent) -> Void) async throws -> any LoginAttempt { throw CancellationError() }
    func status() async throws -> ClaudeLoginStatus { ClaudeLoginStatus(loggedIn: false) }
    func logout() async -> Bool { true }
    func discardCredential() {}
}

private enum PictureFixture {
    /// A one-pixel PNG.
    static func png() -> Data? {
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
