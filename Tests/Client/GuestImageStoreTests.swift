import XCTest

@testable import Topo

/// What is kept of the guest's files for the chat (`GuestImageStore`): an answer stands for its
/// path while it is fresh, and nothing read in an age that has ended — before a sign-out, or
/// before the memory was mounted from another folder — is kept or answered.
final class GuestImageStoreTests: XCTestCase {
    /// A guest whose files a test sets, which counts what it was asked and can hold a read.
    private final class FakeGuest: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [String: Data] = [:]
        private var asked: [String] = []
        private var held: CheckedContinuation<Void, Never>?
        private var holding = false

        func set(_ files: [String: Data]) { lock.withLock { self.files = files } }
        var paths: [String] { lock.withLock { asked } }
        /// The next read waits until `release()`.
        func hold() { lock.withLock { holding = true } }
        var waiting: Bool { lock.withLock { held != nil } }
        func release() { lock.withLock { let waiter = held; held = nil; holding = false; return waiter }?.resume() }

        func ask(_ path: String) async -> Data?? {
            let (data, wait) = lock.withLock { () -> (Data?, Bool) in
                asked.append(path)
                return (files[path], holding)
            }
            if wait { await withCheckedContinuation { waiter in lock.withLock { held = waiter } } }
            return .some(data)
        }
    }

    private func eventually(_ what: String, _ done: () -> Bool) async {
        for _ in 0..<500 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(done(), what)
    }

    func testAnAnswerIsKeptWhileFreshAndOneReadServesEveryRowAskingAtOnce() async {
        let guest = FakeGuest()
        guest.set(["/tmp/a.png": Data("a".utf8)])
        let store = GuestImageStore(ask: guest.ask)
        XCTAssertNil(store.kept("/tmp/a.png"))
        async let one = store.read("/tmp/a.png"), two = store.read("/tmp/a.png"), none = store.read("/tmp/none.png")
        let answers = await [one, two, none]
        XCTAssertEqual(answers, [Data("a".utf8), Data("a".utf8), nil])
        XCTAssertEqual(store.kept("/tmp/a.png"), Data("a".utf8))
        let again = await store.read("/tmp/none.png")
        XCTAssertNil(again)
        XCTAssertEqual(guest.paths.sorted(), ["/tmp/a.png", "/tmp/none.png"], "a fresh answer was asked for again")

        let stale = GuestImageStore(fresh: 0, ask: guest.ask)
        _ = await stale.read("/tmp/a.png")
        guest.set(["/tmp/a.png": Data("b".utf8)])
        let reread = await stale.read("/tmp/a.png")
        XCTAssertEqual(reread, Data("b".utf8), "an answer no longer fresh was not asked for again")
    }

    /// A read begun before a sign-out and landing after it: its bytes are neither answered nor
    /// kept, then or later.
    func testAReadThatLandsAfterASignOutIsNeverKept() async {
        let guest = FakeGuest()
        guest.set(["/home/topo/private.png": Data("private".utf8)])
        let store = GuestImageStore(ask: guest.ask)
        guest.hold()
        let reading = Task { await store.read("/home/topo/private.png") }
        await eventually("the read to reach the guest") { guest.waiting }

        store.forget()
        guest.release()
        let answer = await reading.value
        XCTAssertNil(answer, "a read from before the sign-out was answered after it")
        XCTAssertNil(store.kept("/home/topo/private.png"), "bytes read before the sign-out were kept after it")
    }

    /// The memory mounted from another folder: what was read from the first is not what is
    /// drawn from the second, at the same path.
    func testAnotherVaultAtTheSamePathIsReadAfresh() async {
        let guest = FakeGuest()
        let paths = ["/memory/chart.png", "/home/topo/memory/chart.png", "memory/chart.png"]
        guest.set(Dictionary(uniqueKeysWithValues: paths.map { ($0, Data("first vault".utf8)) }))
        let store = GuestImageStore(ask: guest.ask)
        for path in paths {
            let read = await store.read(path)
            XCTAssertEqual(read, Data("first vault".utf8))
        }

        guest.set(Dictionary(uniqueKeysWithValues: paths.map { ($0, Data("second vault".utf8)) }))
        store.forget()
        for path in paths {
            XCTAssertNil(store.kept(path), "\(path) was kept across the mount")
            let read = await store.read(path)
            XCTAssertEqual(read, Data("second vault".utf8), path)
        }
    }

    /// Where there is no guest to ask, nothing is kept, so the first read once there is one asks.
    func testNoGuestIsNotAnAnswer() async {
        let store = GuestImageStore(ask: { _ in .none })
        let read = await store.read("/tmp/a.png")
        XCTAssertNil(read)
        XCTAssertNil(store.kept("/tmp/a.png"))
    }
}
