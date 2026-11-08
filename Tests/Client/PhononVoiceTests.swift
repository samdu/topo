import XCTest

@testable import Topo

/// The engine's order: one sentence at a time, a dropped sentence stops making samples, and the
/// bundle is loaded again for a new temperature only between sentences, with the old instance
/// let go first.
final class PhononVoiceTests: XCTestCase {
    private let fm = FileManager.default
    private var folder: URL!

    override func setUpWithError() throws {
        folder = fm.temporaryDirectory.appendingPathComponent("phonon-voice-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "built": 1794101031, "temperature": 0.3, "voices": ["Friendly Octopus"],
            "dims": ["latent": 32, "frame": 1920], "files": [["path": "flow.mlpackage/Manifest.json", "size": 2, "sha256": "ab"]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: bundleJSON)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: folder)
    }

    private var bundleJSON: URL { folder.appendingPathComponent("bundle.json") }

    func testTheTemperatureIsWrittenAndEveryOtherKeyKept() throws {
        let before = try JSONSerialization.jsonObject(with: Data(contentsOf: bundleJSON)) as! [String: Any]
        try PhononVoiceEngine.write(temperature: 0.7, into: bundleJSON)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: bundleJSON)) as! [String: Any]
        XCTAssertEqual((after["temperature"] as? NSNumber)?.floatValue, 0.7)
        XCTAssertTrue(try String(contentsOf: bundleJSON, encoding: .utf8).contains("\"temperature\":0.7"), "written as the decimal it is")
        XCTAssertEqual(Set(after.keys), Set(before.keys))
        for key in before.keys where key != "temperature" {
            XCTAssertEqual(after[key] as? NSObject, before[key] as? NSObject, key)
        }
    }

    func testSentencesAreMadeOneAtATime() async throws {
        let log = SpeakLog()
        let engine = PhononVoiceEngine(open: { _ in FakePhonon(log: log, chunks: 4) })
        try await engine.load(folder: folder, temperature: 0.3)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 0..<3 {
                group.addTask {
                    for try await _ in try await engine.stream("sentence \(n)", temperature: 0.3) {}
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(log.most, 1, "two sentences were made at once")
        XCTAssertEqual(log.events.filter { $0.hasPrefix("end") }.count, 3)
    }

    /// A sentence dropped mid-way stops making samples, and the engine is free for the next.
    func testADroppedSentenceStopsAndFreesTheEngine() async throws {
        let log = SpeakLog()
        let engine = PhononVoiceEngine(open: { _ in FakePhonon(log: log, chunks: 1_000) })
        try await engine.load(folder: folder, temperature: 0.3)
        var stream: AsyncThrowingStream<Voice.Frame, Error>? = try await engine.stream("long", temperature: 0.3)
        for try await _ in stream! { break }
        stream = nil
        let next = Task { for try await _ in try await engine.stream("next", temperature: 0.3) {} }
        try await withTimeout { try await next.value }
        XCTAssertLessThan(log.chunks(of: "long"), 1_000, "the dropped sentence ran to its end")
        XCTAssertEqual(log.chunks(of: "next"), 1_000)
    }

    /// A new temperature loads the bundle again only once the sentence being made has ended, and
    /// the engine holds no instance while it opens the next.
    func testAReloadIsNeverUnderASentence() async throws {
        let log = SpeakLog()
        let opened = Opened()
        let engine = PhononVoiceEngine(open: { url in
            let temperature = try PhononTestsBundle.temperature(at: url)
            log.add("open \(temperature)")
            opened.check()
            let phonon = FakePhonon(log: log, chunks: 20)
            opened.keep(phonon)
            return phonon
        })
        try await engine.load(folder: folder, temperature: 0.3)
        let first = Task { for try await _ in try await engine.stream("first", temperature: 0.3) {} }
        while log.chunks(of: "first") == 0 { await Task.yield() }
        let second = Task { for try await _ in try await engine.stream("second", temperature: 0.7) {} }
        try await withTimeout { try await first.value; try await second.value }
        let events = log.events
        XCTAssertEqual(events.first, "open 0.3")
        let reload = try XCTUnwrap(events.firstIndex(of: "open 0.7"))
        let firstEnd = try XCTUnwrap(events.firstIndex(of: "end first"))
        let secondStart = try XCTUnwrap(events.firstIndex(of: "start second"))
        XCTAssertLessThan(firstEnd, reload, "the bundle was loaded again under a sentence")
        XCTAssertLessThan(reload, secondStart)
        XCTAssertEqual(opened.alive, [], "an instance was still held while the next opened: \(opened.alive)")
    }

    /// A sentence dropped mid-way, then one at another temperature: the reload waits for the
    /// dropped sentence's call to return, and opens with nothing of the old instance held.
    func testAReloadAfterADroppedSentenceWaitsForItsCallAndHoldsNoInstance() async throws {
        let log = SpeakLog()
        let opened = Opened()
        let engine = PhononVoiceEngine(open: { url in
            log.add("open \(try PhononTestsBundle.temperature(at: url))")
            opened.check()
            let phonon = FakePhonon(log: log, chunks: 1_000)
            opened.keep(phonon)
            return phonon
        })
        try await engine.load(folder: folder, temperature: 0.3)
        var stream: AsyncThrowingStream<Voice.Frame, Error>? = try await engine.stream("dropped", temperature: 0.3)
        for try await _ in stream! { break }
        stream = nil
        let next = Task { for try await _ in try await engine.stream("next", temperature: 0.7) {} }
        try await withTimeout { try await next.value }
        let events = log.events
        let end = try XCTUnwrap(events.firstIndex(of: "end dropped"))
        let reload = try XCTUnwrap(events.firstIndex(of: "open 0.7"))
        XCTAssertLessThan(end, reload, "the bundle was opened again while the dropped sentence's call ran")
        XCTAssertLessThan(log.chunks(of: "dropped"), 1_000)
        XCTAssertEqual(opened.alive, [], "an instance was still held while the next opened: \(opened.alive)")
    }

    private func withTimeout(_ body: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw CancellationError()
            }
            try await group.next()
            group.cancelAll()
        }
    }
}

enum PhononTestsBundle {
    static func temperature(at folder: URL) throws -> Float {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("bundle.json"))) as! [String: Any]
        return (object["temperature"] as! NSNumber).floatValue
    }
}

/// Weak references to every instance opened before the one being opened: each must be gone by
/// the time the next opens.
final class Opened: @unchecked Sendable {
    private let lock = NSLock()
    private var refs: [Weak] = []
    private var stillAlive: [Int] = []
    var alive: [Int] { lock.withLock { stillAlive } }
    private final class Weak { weak var object: AnyObject?; init(_ o: AnyObject) { object = o } }

    func check() {
        lock.withLock {
            for (n, ref) in refs.enumerated() where ref.object != nil { stillAlive.append(n) }
        }
    }
    func keep(_ object: AnyObject) { lock.withLock { refs.append(Weak(object)) } }
}

final class SpeakLog: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String] = []
    private var active = 0
    private var peak = 0
    private var counts: [String: Int] = [:]
    var events: [String] { lock.withLock { kept } }
    var most: Int { lock.withLock { peak } }
    func chunks(of text: String) -> Int { lock.withLock { counts[text] ?? 0 } }
    func add(_ event: String) { lock.withLock { kept.append(event) } }
    func start(_ text: String) {
        lock.withLock { kept.append("start \(text)"); active += 1; peak = max(peak, active) }
    }
    func chunk(_ text: String) { lock.withLock { counts[text, default: 0] += 1 } }
    func end(_ text: String) { lock.withLock { kept.append("end \(text)"); active -= 1 } }
}

/// Phonon as the engine sees it: one call per sentence that hands its chunks over as it makes
/// them and returns once it is done, or at the next chunk after its task is cancelled, the way
/// ptts's `speak` stops at its sink's flag. The call holds the instance for as long as it runs.
final class FakePhonon: PhononSpeaking, @unchecked Sendable {
    let log: SpeakLog
    let chunks: Int
    init(log: SpeakLog, chunks: Int) { self.log = log; self.chunks = chunks }

    func say(_ text: String, onAudio: @escaping @Sendable ([Float]) -> Void) async throws {
        log.start(text)
        for _ in 0..<chunks {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(1))
            log.chunk(text)
            onAudio([0, 0, 0])
        }
        // The native call's tail after the sink stops: still this instance's work.
        try? await Task.sleep(for: .milliseconds(5))
        log.end(text)
    }
}
