import TopoAuth
import TopoCore
import TopoCoreTesting
import XCTest

@testable import Topo

/// Letting go of the login. Five things end, and which of them end, in what order, is what this
/// covers: the reply in the ear, the transcript and its outbox, the folder on disk, the
/// connections' tokens, and the login's tokens last. A call left out is a reply still being read, or a memory still on disk, for an
/// account the app no longer has.
@MainActor
final class SignOutTests: XCTestCase {
    /// What was ended, in the order it was ended in.
    private final class Calls {
        var ended: [String] = []
    }

    private func signOut() -> (SignOut, Calls) {
        let calls = Calls()
        let signOut = SignOut(stopSpeaking: { calls.ended.append("speaker") },
                              forgetShares: { calls.ended.append("shares") },
                              forgetHarness: { calls.ended.append("harness") },
                              forgetMemory: { calls.ended.append("memory") },
                              forgetSurfaces: { calls.ended.append("surfaces") },
                              forgetConnections: { calls.ended.append("connections") },
                              forgetLogin: { calls.ended.append("login") })
        return (signOut, calls)
    }

    func testSigningOutEndsEveryOneOfThem() async {
        let (signOut, calls) = signOut()
        await signOut.act()
        XCTAssertEqual(Set(calls.ended), ["speaker", "shares", "harness", "memory", "surfaces", "connections", "login"])
    }

    /// The door a share comes in by shuts before the harness is waited on: a share put on the line
    /// while the harness forgets would be a turn of the login that just ended.
    func testTheSharesGoBeforeTheHarnessIsWaitedOn() async {
        let (signOut, calls) = signOut()
        await signOut.act()
        XCTAssertLessThan(calls.ended.firstIndex(of: "shares")!, calls.ended.firstIndex(of: "harness")!)
    }

    func testTheLoginGoesLast() async {
        let (signOut, calls) = signOut()
        await signOut.act()
        XCTAssertEqual(calls.ended.last, "login",
                       "the tokens go last, so nothing above runs without an account to run against")
    }

    func testTheSpeakerIsStoppedFirst() async {
        let (signOut, calls) = signOut()
        await signOut.act()
        XCTAssertEqual(calls.ended.first, "speaker",
                       "a reply still being read would hold the process open past the login")
    }

    func testTheOrderIsTheWholeOrder() async {
        let (signOut, calls) = signOut()
        await signOut.act()
        XCTAssertEqual(calls.ended, ["speaker", "shares", "harness", "memory", "surfaces", "connections", "login"])
    }

    /// The widgets go with the login: the app group's documents, images and pending taps
    /// removed, and every timeline reloaded at once rather than after the reload window.
    func testClearsWidgetSurfaces() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("signout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SurfaceStore(folder: folder)
        try store.write(WidgetDocument.read(WidgetTool.example).document, slot: "demo")
        try store.writeDefault(DefaultSurface.document(nil))
        try store.writeImage(Data([0x89]), slot: "demo", name: "photo")
        try store.appendCue(SurfaceStore.Cue(nonce: "N", slot: "demo", id: "hi", revision: 1, time: Date()))
        ControlDefaults.fill(store)
        try store.writeNotes(["unchecked: x"], slot: ControlSlot.stored("button-1"))
        var everything = 0
        var kinds = 0
        var everyControl = 0
        let reloader = SurfaceReloader(reloadKind: { _ in kinds += 1 }, reloadEverything: { everything += 1 },
                                       reloadControlKind: { _ in kinds += 1 }, reloadEveryControl: { everyControl += 1 },
                                       schedule: { _, _ in })
        // The slots' records, which the watch draws, go with the files.
        let records = InMemoryRecordDatabase()
        let sync = SurfaceSync(records: { SurfaceRecords(database: records) }, ensureZone: {}, mayOwn: { true }, demoted: { _ in true }, store: { store }, runner: "phone",
                               defaults: UserDefaults(suiteName: "signout-\(UUID().uuidString)")!, reloader: reloader)
        guard case .record(let demo) = sync.snapshot(slot: "demo", store) else { return XCTFail("demo is not readable") }
        try await SurfaceRecords(database: records).save(demo, over: .none)
        let signOut = SignOut(stopSpeaking: {}, forgetShares: {}, forgetHarness: {}, forgetMemory: {}, forgetSurfaces: { reloader.forget(store) },
                              forgetConnections: {}, forgetLogin: {})
        await signOut.act()
        await sync.flush()
        let surfaces = try await records.records(ofType: SurfaceRecord.type)
        XCTAssertEqual(surfaces.filter { SurfaceRecords.Read($0).holds }.map(\.id), [], "a slot's record outlived the login")
        XCTAssertFalse(sync.owesForget)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertEqual(left, ["_revisions.json"], "the app group kept \(left)")
        let counters = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: store.revisionsURL))
        XCTAssertEqual(Array(counters.keys), [SurfaceStore.floor], "a slot's name outlived the login")
        XCTAssertEqual(everything, 1, "WidgetCenter was not told to reload every timeline")
        XCTAssertEqual(everyControl, 1, "ControlCenter was not told to reload every control")
        XCTAssertTrue(ControlSlot.all.allSatisfy { ControlValue.read(slot: $0, store: store).signedOut }, "a control outlived the login")
        guard case .signedOut = SurfaceProvider.surface(slot: "demo", family: .systemSmall, at: Date(), store: store) else {
            return XCTFail("a placed widget still draws something after the sign-out")
        }
    }

    /// Every control secret goes with the connections, at a sign-out, a takeover or a demotion.
    func testClearsControlSecrets() async throws {
        let secrets = ControlSecrets(service: "zone.hexagon.topo.control-secret.tests.\(UUID().uuidString)")
        defer { try? secrets.clearAll() }
        let connections = Connections(store: InMemoryConnectionStore(), leftBehind: .isolated(),
                                      clearControlSecrets: { try secrets.clearAll() })
        try secrets.set("tok", name: "ha")
        try secrets.set("other", name: "webhook")
        let signOut = SignOut(stopSpeaking: {}, forgetShares: {}, forgetHarness: {}, forgetMemory: {}, forgetSurfaces: {},
                              forgetConnections: { connections.forget() }, forgetLogin: {})
        await signOut.act()
        XCTAssertEqual(try secrets.names(), [], "a control secret outlived the login")
        XCTAssertNil(connections.unforgotten)
    }

    /// Nothing is ended by building the value: the button's press is what ends them.
    func testNothingHappensUntilItIsTaken() {
        let (_, calls) = signOut()
        XCTAssertTrue(calls.ended.isEmpty)
    }

    /// The far end of a takeover ends the same things, the connections among them, the login last.
    func testATakeoverForgetsTheConnectionsBeforeTheLogin() async {
        let calls = Calls()
        let takeover = Takeover(forgetShares: { calls.ended.append("shares") },
                                demoteHarness: { calls.ended.append("harness") },
                                acceptDemotion: { calls.ended.append("role") },
                                stopSpeaking: { calls.ended.append("speaker") },
                                forgetMemory: { calls.ended.append("memory") },
                                forgetSurfaces: { calls.ended.append("surfaces") },
                                forgetConnections: { calls.ended.append("connections") },
                                forgetLogin: { calls.ended.append("login") })
        await takeover.act()
        XCTAssertEqual(calls.ended, ["shares", "harness", "role", "speaker", "memory", "surfaces", "connections", "login"])
    }

    /// A phone found a viewer at launch with a login or something waiting demotes, forgets the
    /// memory, the surfaces and the connections, and the login last.
    func testAViewerWithALoginEndsItAllTheLoginLast() async {
        let calls = Calls()
        await arrival(calls, holdsLogin: true).act()
        XCTAssertEqual(calls.ended, ["shares", "harness", "memory", "surfaces", "connections", "login"])
    }

    /// One with no login and nothing waiting still forgets the surfaces and a connection's token,
    /// whose app group and keychain
    /// item outlives the login's.
    func testAViewerWithNoLoginStillForgetsItsConnections() async {
        let calls = Calls()
        await arrival(calls, holdsLogin: false).act()
        XCTAssertEqual(calls.ended, ["shares", "surfaces", "connections"])
    }

    private func arrival(_ calls: Calls, holdsLogin: Bool) -> ViewerArrival {
        ViewerArrival(forgetShares: { calls.ended.append("shares") },
                      holdsLogin: { holdsLogin },
                      demoteHarness: { calls.ended.append("harness") },
                      forgetMemory: { calls.ended.append("memory") },
                      forgetSurfaces: { calls.ended.append("surfaces") },
                      forgetConnections: { calls.ended.append("connections") },
                      forgetLogin: { calls.ended.append("login") })
    }
}
