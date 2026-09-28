import XCTest

@testable import Topo

/// Letting go of the login. Four things end, and which of them end, in what order, is what this
/// covers: the reply in the ear, the transcript and its outbox, the folder on disk, and the
/// tokens last. A call left out is a reply still being read, or a memory still on disk, for an
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
                              forgetHarness: { calls.ended.append("harness") },
                              forgetMemory: { calls.ended.append("memory") },
                              forgetSurfaces: { calls.ended.append("surfaces") },
                              forgetLogin: { calls.ended.append("login") })
        return (signOut, calls)
    }

    func testSigningOutEndsEveryOneOfThem() async {
        let (signOut, calls) = signOut()
        await signOut.act()
        XCTAssertEqual(Set(calls.ended), ["speaker", "harness", "memory", "surfaces", "login"])
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
        XCTAssertEqual(calls.ended, ["speaker", "harness", "memory", "surfaces", "login"])
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
        var everything = 0
        var kinds = 0
        let reloader = SurfaceReloader(reloadKind: { _ in kinds += 1 }, reloadEverything: { everything += 1 },
                                       schedule: { _, _ in })
        let signOut = SignOut(forgetSurfaces: { reloader.forget(store) })
        await signOut.act()
        let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertEqual(left, [], "the app group kept \(left)")
        XCTAssertEqual(everything, 1, "WidgetCenter was not told to reload every timeline")
        guard case .signedOut = SurfaceProvider.surface(slot: "demo", family: .systemSmall, at: Date(), store: store) else {
            return XCTFail("a placed widget still draws something after the sign-out")
        }
    }

    /// Nothing is ended by building the value: the button's press is what ends them.
    func testNothingHappensUntilItIsTaken() {
        let (_, calls) = signOut()
        XCTAssertTrue(calls.ended.isEmpty)
    }
}
