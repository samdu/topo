import XCTest

@testable import Topo

@MainActor
final class VocabularyTests: XCTestCase {
    /// Defaults of its own per test, so nothing here reaches the real ones or another test.
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "topo.tests.\(UUID().uuidString)")!
    }

    func testTheListIsEmptyUntilSomeoneAddsToIt() {
        XCTAssertEqual(Vocabulary(defaults: makeDefaults()).terms, [])
    }

    func testTheListRoundTripsThroughTheDefaults() {
        let defaults = makeDefaults()
        let store = Vocabulary(defaults: defaults)
        XCTAssertTrue(store.add("Daphne"))
        XCTAssertTrue(store.add("  Helen "))
        XCTAssertEqual(store.terms, ["Daphne", "Helen"])

        XCTAssertEqual(Vocabulary(defaults: defaults).terms, ["Daphne", "Helen"])
    }

    func testRemovingIsSavedToo() {
        let defaults = makeDefaults()
        let store = Vocabulary(defaults: defaults)
        store.add("Daphne")
        store.add("Helen")
        store.remove(atOffsets: IndexSet(integer: 0))
        XCTAssertEqual(store.terms, ["Helen"])
        XCTAssertEqual(Vocabulary(defaults: defaults).terms, ["Helen"])
    }

    func testAWordTheRescorerWouldIgnoreOrAlreadyHasIsRefused() {
        let store = Vocabulary(defaults: makeDefaults())
        XCTAssertFalse(store.add("ab"))
        XCTAssertFalse(store.add("   "))
        XCTAssertTrue(store.add("Ceph"))
        XCTAssertFalse(store.add("ceph"))
        XCTAssertEqual(store.terms, ["Ceph"])
    }

    func testEveryEditTellsTheEar() {
        let store = Vocabulary(defaults: makeDefaults())
        var told = 0
        store.changed = { told += 1 }
        store.add("Daphne")
        store.add("ab")
        store.remove(atOffsets: IndexSet(integer: 0))
        XCTAssertEqual(told, 2)
    }
}
