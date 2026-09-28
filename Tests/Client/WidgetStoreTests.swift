import XCTest

@testable import Topo

/// The app group's `Surfaces` folder: a document the extension reads is always a whole one, a
/// slot's revision only ever goes up, and the pending cues and the taps are lists of their own.
final class WidgetStoreTests: XCTestCase {
    private func store() -> SurfaceStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("surfaces-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return SurfaceStore(folder: folder)
    }

    private func document(_ words: String) -> WidgetDocument {
        WidgetDocument(families: [.systemSmall: .text(.init(text: words))])
    }

    func testAWriteReadsBackUnderTheNextRevision() throws {
        let store = store()
        XCTAssertNil(store.read(slot: "demo"))
        XCTAssertEqual(try store.write(document("one"), slot: "demo"), 1)
        XCTAssertEqual(try store.write(document("two"), slot: "demo"), 2)
        let reading = try XCTUnwrap(store.read(slot: "demo"))
        XCTAssertEqual(reading.notes, [])
        XCTAssertEqual(reading.document.revision, 2)
        XCTAssertEqual(reading.document.tree(for: .systemSmall), .text(.init(text: "two")))
        XCTAssertEqual(store.slots(), ["demo"])
    }

    /// A slot cleared and written again never reuses a revision a placed widget's old timeline
    /// still carries.
    func testARevisionOutlivesItsSlot() throws {
        let store = store()
        try store.write(document("one"), slot: "demo")
        try store.remove(slot: "demo")
        XCTAssertNil(store.read(slot: "demo"))
        XCTAssertEqual(try store.write(document("again"), slot: "demo"), 2)
    }

    func testTheDefaultIsNotASlot() throws {
        let store = store()
        try store.writeDefault(document("default"))
        try store.write(document("mine"), slot: "mine")
        XCTAssertEqual(store.slots(), ["mine"])
        XCTAssertNotNil(store.read(slot: SurfaceStore.defaultSlot))
    }

    func testTheTapsKeepTheLastFifty() throws {
        let store = store()
        for index in 0..<60 {
            try store.appendTap(.init(time: Date(timeIntervalSince1970: TimeInterval(index)), slot: "s", id: "c\(index)", revision: 1, kind: "run", status: "0"))
        }
        let taps = store.taps()
        XCTAssertEqual(taps.count, 50)
        XCTAssertEqual(taps.first?.id, "c10")
        XCTAssertEqual(taps.last?.id, "c59")
    }

    func testACueComesOffByItsNonce() throws {
        let store = store()
        let first = SurfaceStore.Cue(nonce: "n1", slot: "s", id: "a", revision: 1, time: Date(timeIntervalSince1970: 1))
        let second = SurfaceStore.Cue(nonce: "n2", slot: "s", id: "b", revision: 1, time: Date(timeIntervalSince1970: 2))
        try store.appendCue(first)
        try store.appendCue(second)
        XCTAssertEqual(store.cues(), [first, second])
        try store.removeCue(nonce: "n1")
        XCTAssertEqual(store.cues(), [second])
    }

    /// The gate's reproduction: a slot named for one of the store's own files. The store's files
    /// all start `_`, which no slot can, so a slot called `revisions`, `pending` or `taps` is a
    /// slot and the counters run on.
    func testASlotNamedForTheStoresFilesIsOnlyASlot() throws {
        let store = store()
        XCTAssertEqual(try store.write(document("a"), slot: "demo"), 1)
        XCTAssertEqual(try store.write(document("b"), slot: "demo"), 2)
        for name in ["revisions", "pending", "taps"] { try store.write(document(name), slot: name) }
        XCTAssertEqual(try store.write(document("c"), slot: "demo"), 3, "a slot's write restarted the counters")
        XCTAssertEqual(store.revision(slot: "demo"), 3)
        XCTAssertEqual(store.slots(), ["demo", "pending", "revisions", "taps"])
        XCTAssertThrowsError(try store.write(document("x"), slot: "_revisions"))
        XCTAssertThrowsError(try store.write(document("x"), slot: "../escape"))
        XCTAssertNil(store.read(slot: "../escape"))
    }

    /// A counter file that cannot be read fails the write rather than starting the counters again.
    func testACounterThatCannotBeReadFailsClosed() throws {
        let store = store()
        XCTAssertEqual(try store.write(document("a"), slot: "demo"), 1)
        try Data("not json".utf8).write(to: store.revisionsURL)
        XCTAssertThrowsError(try store.write(document("b"), slot: "demo"), "a counter file it could not read was taken for none")
        XCTAssertEqual(store.read(slot: "demo")?.document.revision, 1, "the document moved on without a revision")
    }

    func testEverythingGoesTogether() throws {
        let store = store()
        try store.write(document("x"), slot: "a")
        try store.writeDefault(document("d"))
        try store.writeImage(Data([1, 2, 3]), slot: "a", name: "pic")
        try store.appendCue(.init(nonce: "n", slot: "a", id: "b", revision: 1, time: Date()))
        try store.removeEverything()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.folder.path), ["_revisions.json"])
        XCTAssertEqual(store.cues(), [])
    }

    /// A sign-out keeps the highest revision given, and nothing else of the counters: every
    /// slot's next, the default's included, is above it.
    func testNoRevisionIsGivenTwiceAcrossLogins() throws {
        let store = store()
        try store.write(document("x"), slot: "a")
        try store.write(document("x"), slot: "a")
        let fallback = try store.writeDefault(document("d"))
        try store.removeEverything()
        let counters = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: store.revisionsURL))
        XCTAssertEqual(counters, [SurfaceStore.floor: 2])
        XCTAssertEqual(try store.write(document("x"), slot: "b"), 3)
        XCTAssertGreaterThan(try store.writeDefault(document("d")), fallback)
    }

    /// Review Focus 9: a writer replacing a document as fast as it can, and a reader beside it
    /// that never once reads a document it cannot decode.
    func testReaderNeverSeesHalf() async throws {
        let store = store()
        // Big enough that a torn write would be caught mid-file.
        let long = String(repeating: "word ", count: 30)
        try store.write(document(long), slot: "race")
        let writer = Task.detached {
            for index in 0..<300 {
                try store.write(WidgetDocument(families: [
                    .systemSmall: .stack(.init(axis: .vstack, children: (0..<40).map { .text(.init(text: "\(index) \($0) \(long)")) })),
                ]), slot: "race")
            }
        }
        let reader = Task.detached { () -> Int in
            var reads = 0
            while reads < 600 {
                guard let reading = store.read(slot: "race") else { continue }
                XCTAssertTrue(reading.readable, "a read decoded to \(reading.state)")
                XCTAssertEqual(reading.notes, [])
                reads += 1
            }
            return reads
        }
        try await writer.value
        let reads = await reader.value
        XCTAssertEqual(reads, 600)
    }
}

/// Review Focus 9: however many writes come at once, one reload per kind per window.
@MainActor
final class SurfaceReloaderTests: XCTestCase {
    /// A clock the test moves: what is scheduled runs only when the test says time has passed.
    private final class ManualClock {
        var now: Duration = .zero
        var due: [(Duration, @MainActor () -> Void)] = []

        @MainActor func advance(by step: Duration) {
            now += step
            let ready = due.filter { $0.0 <= now }
            due.removeAll { $0.0 <= now }
            ready.forEach { $0.1() }
        }
    }

    func testCoalesces() {
        let clock = ManualClock()
        var reloads: [String] = []
        let reloader = SurfaceReloader(reloadKind: { reloads.append($0) }, reloadEverything: { reloads.append("*") },
                                       schedule: { delay, body in clock.due.append((clock.now + delay, body)) })
        for _ in 0..<10 {
            reloader.reload()
            clock.advance(by: .milliseconds(100))
        }
        XCTAssertEqual(reloads, [], "nothing reloads before the window is out")
        clock.advance(by: .seconds(1))
        XCTAssertEqual(reloads, [SurfaceStore.kind], "ten writes in a second, one reload")
        clock.advance(by: .seconds(10))
        XCTAssertEqual(reloads, [SurfaceStore.kind])
        reloader.reload()
        clock.advance(by: .seconds(2))
        XCTAssertEqual(reloads, [SurfaceStore.kind, SurfaceStore.kind], "a write after the window is a reload of its own")
    }

    func testEverythingReloadsAtOnce() {
        var reloads: [String] = []
        let reloader = SurfaceReloader(reloadKind: { reloads.append($0) }, reloadEverything: { reloads.append("*") },
                                       schedule: { _, _ in })
        reloader.reloadAll()
        XCTAssertEqual(reloads, ["*"])
    }
}
