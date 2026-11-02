import CryptoKit
import XCTest

@testable import Topo

final class ModelDownloadsTests: XCTestCase {
    /// The session obeys the person's data settings and outlives the process: nothing expensive
    /// or constrained, waits for a network rather than failing without one, wakes the app when
    /// it is done.
    @MainActor
    func testTheSessionConfigurationLeavesTheDataSettingsToIOS() {
        let configuration = ModelDownloads.configuration()
        XCTAssertEqual(configuration.identifier, "zone.hexagon.topo.models")
        XCTAssertFalse(configuration.allowsExpensiveNetworkAccess)
        XCTAssertFalse(configuration.allowsConstrainedNetworkAccess)
        XCTAssertTrue(configuration.waitsForConnectivity)
        XCTAssertFalse(configuration.isDiscretionary)
        XCTAssertTrue(configuration.sessionSendsLaunchEvents)
    }

    /// The manifest fetches one stock speaker, and it is the one the voice asks the port for: a
    /// speaker named in one place and fetched under another is a voice that never loads.
    func testTheBundledManifestFetchesTheSpeakerTheVoiceAsksFor() throws {
        let pocket = try XCTUnwrap(try ModelManifest.bundled().model(ModelManifest.pocket))
        let speakers = pocket.files.map(\.path).filter { $0.hasSuffix(".safetensors") }
        XCTAssertEqual(speakers, ["v2.1/english/constants_bin/\(Voice.speaker).safetensors"])
        XCTAssertEqual(Voice.speaker, "marius")
        XCTAssertEqual(Voice.tempo, 1.0, "marius is heard at the pace he speaks at")
    }

    func testTheBundledManifestNamesEveryModelWithADigestForEveryFile() throws {
        let manifest = try ModelManifest.bundled()
        for id in [ModelManifest.parakeet, ModelManifest.ctc, ModelManifest.pocket] {
            let model = try XCTUnwrap(manifest.model(id), id)
            XCTAssertFalse(model.files.isEmpty, id)
            XCTAssertEqual(model.revision?.count, 40, "\(id) is pinned to a commit")
            for file in model.files {
                XCTAssertEqual(file.sha256.count, 64, "\(id)/\(file.path)")
                XCTAssertTrue(file.sha256.allSatisfy(\.isHexDigit), "\(id)/\(file.path)")
                XCTAssertGreaterThan(file.size, 0, "\(id)/\(file.path)")
                XCTAssertEqual(model.url(for: file).host, "huggingface.co")
            }
        }
        // The guest's rootfs is not on the Hub: one tarball, fetched from Alpine's CDN at the
        // pinned release, and checked against its digest like every model file.
        let rootfs = try XCTUnwrap(manifest.model(ModelManifest.rootfs))
        XCTAssertNil(rootfs.repo)
        XCTAssertEqual(rootfs.files.map(\.path), ["alpine-minirootfs-3.22.6-aarch64.tar.gz"])
        XCTAssertEqual(rootfs.url(for: rootfs.files[0]).absoluteString,
                       "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/aarch64/alpine-minirootfs-3.22.6-aarch64.tar.gz")
        XCTAssertEqual(rootfs.files[0].sha256.count, 64)
        XCTAssertGreaterThan(rootfs.files[0].size, 0)
        // bash for the guest: Alpine's own packages for the same branch and architecture, exactly
        // bash and what it depends on at their pinned versions, in the order they are laid in, each
        // from the branch's repository and checked by digest like the rootfs.
        let shell = try XCTUnwrap(manifest.model(ModelManifest.shell))
        XCTAssertNil(shell.repo)
        XCTAssertEqual(shell.url, "https://dl-cdn.alpinelinux.org/alpine/v3.22/main/aarch64/")
        XCTAssertEqual(shell.files.map(\.path), [
            "bash-5.2.37-r0.apk",
            "readline-8.2.13-r1.apk",
            "libncursesw-6.5_p20250503-r0.apk",
            "ncurses-terminfo-base-6.5_p20250503-r0.apk",
        ])
        for file in shell.files {
            XCTAssertEqual(file.sha256.count, 64, file.path)
            XCTAssertTrue(file.sha256.allSatisfy(\.isHexDigit), file.path)
            XCTAssertGreaterThan(file.size, 0, file.path)
        }
        // Claude Code is Anthropic's own release distribution, the one the official installer
        // reads: the musl arm64 build at the pinned version, one binary, checked by digest.
        let claude = try XCTUnwrap(manifest.model(ModelManifest.claudeCode))
        XCTAssertNil(claude.repo)
        let version = try XCTUnwrap(claude.version)
        XCTAssertNotNil(version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression), version)
        XCTAssertEqual(claude.files.map(\.path), ["claude"])
        XCTAssertEqual(claude.url(for: claude.files[0]).absoluteString,
                       "https://downloads.claude.ai/claude-code-releases/\(version)/linux-arm64-musl/claude")
        XCTAssertEqual(claude.files[0].sha256.count, 64)
        XCTAssertGreaterThan(claude.files[0].size, 100_000_000)
        // 1Password's CLI is its own zip from its own CDN, pinned whole, with the `op` inside it
        // pinned as the entry's binary: what the guest extracts is checked, not only what came.
        let op = try XCTUnwrap(manifest.model(ModelManifest.onePassword))
        XCTAssertNil(op.repo)
        let opVersion = try XCTUnwrap(op.version)
        XCTAssertEqual(op.files.map(\.path), ["op_linux_arm64_v\(opVersion).zip"])
        XCTAssertEqual(op.url(for: op.files[0]).absoluteString,
                       "https://cache.agilebits.com/dist/1P/op2/pkg/v\(opVersion)/op_linux_arm64_v\(opVersion).zip")
        XCTAssertEqual(op.files[0].sha256.count, 64)
        let binary = try XCTUnwrap(op.binary, "the op inside the zip is pinned")
        XCTAssertEqual(binary.path, "op")
        XCTAssertEqual(binary.sha256.count, 64)
        XCTAssertGreaterThan(binary.size, op.files[0].size)
        // The CoreML bundles arrive flattened: a bundle is several files on the Hub.
        let parakeet = try XCTUnwrap(manifest.model(ModelManifest.parakeet))
        XCTAssertTrue(parakeet.files.contains { $0.path == "Encoder.mlmodelc/weights/weight.bin" })
        XCTAssertTrue(parakeet.files.contains { $0.path == "parakeet_vocab.json" })
    }

    func testAModelIsPresentOnlyWhenEveryFileIsVerified() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("topo-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelStore(root: root)
        let a = Data("the encoder".utf8), b = Data("the vocabulary".utf8)
        let model = ModelManifest.Model(id: "example", repo: "example/example", revision: String(repeating: "0", count: 40), files: [
            .init(path: "Encoder.mlmodelc/weights/weight.bin", size: Int64(a.count), sha256: digest(a)),
            .init(path: "vocab.json", size: Int64(b.count), sha256: digest(b)),
        ])

        XCTAssertFalse(store.isPresent(model))
        XCTAssertEqual(store.unverified(model).map(\.path), model.files.map(\.path))

        try store.admit(temp(a), as: model.files[0], of: model)
        XCTAssertFalse(store.isPresent(model), "one file of two is not present")
        XCTAssertEqual(store.unverified(model).map(\.path), ["vocab.json"])
        XCTAssertEqual(store.verifiedBytes(model), Int64(a.count))

        // Wrong bytes at the right size are refused and leave nothing behind.
        XCTAssertThrowsError(try store.admit(temp(Data("the vocabulary".utf8.reversed())), as: model.files[1], of: model))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.location(of: model.files[1], in: model).path))
        XCTAssertFalse(store.isPresent(model))
        // So is the wrong size.
        XCTAssertThrowsError(try store.admit(temp(Data("short".utf8)), as: model.files[1], of: model))
        XCTAssertFalse(store.isPresent(model))

        try store.admit(temp(b), as: model.files[1], of: model)
        XCTAssertTrue(store.isPresent(model))
        XCTAssertEqual(store.verifiedBytes(model), Int64(a.count + b.count))

        // A verified file that goes missing, or changes size, takes the model back to partial.
        try FileManager.default.removeItem(at: store.location(of: model.files[0], in: model))
        XCTAssertFalse(store.isPresent(model))
        XCTAssertEqual(store.unverified(model).map(\.path), ["Encoder.mlmodelc/weights/weight.bin"])
        try store.admit(temp(a), as: model.files[0], of: model)
        XCTAssertTrue(store.isPresent(model))
        try Data("the encoder, longer".utf8).write(to: store.location(of: model.files[0], in: model))
        XCTAssertFalse(store.isPresent(model))
    }

    /// The branch that decides between a failure and a restart: a task the watchdog cancelled
    /// completes as a restart, in either order of the cancel's handler and the completion, and
    /// never as a failure; one it did not cancel completes as a failure; one that finished as it
    /// was cancelled completes with no error and is owed nothing.
    func testACancelForARestartIsNeverAFailureWhicheverCallbackComesFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("topo-relay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ModelManifest.Model(id: "example", repo: "example/example", revision: String(repeating: "0", count: 40), files: [
            .init(path: "weight.bin", size: 3, sha256: digest(Data("abc".utf8))),
        ])
        let key = "example|weight.bin"
        let handlers = Handlers()
        let relay = SessionRelay(store: ModelStore(root: root), manifest: ModelManifest(models: [model])) { _, handler in
            handlers.keep(handler)
        }
        let events = Events()
        relay.events = { events.add($0) }
        let session = URLSession.shared
        func task() -> URLSessionDownloadTask {
            let task = session.downloadTask(with: URL(string: "https://example.invalid/weight.bin")!)
            task.taskDescription = key
            return task
        }
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

        // Completion first, then the handler with resume data.
        let a = task()
        relay.cancelForRestart(a, key: key)
        XCTAssertTrue(relay.isRestarting(a))
        relay.urlSession(session, task: a, didCompleteWithError: cancelled)
        XCTAssertFalse(relay.isRestarting(a))
        XCTAssertEqual(events.all, [], "the completion of a cancel for a restart says nothing")
        try handlers.take()(Data("resume".utf8))
        XCTAssertEqual(events.all, [.restarting(key)])
        let resume = ModelStore(root: root).resumeData(for: model.files[0], in: model)
        XCTAssertEqual(try Data(contentsOf: resume), Data("resume".utf8), "the handler wrote the resume data before saying so")

        // Handler first (no resume data), then the completion.
        events.clear()
        let b = task()
        relay.cancelForRestart(b, key: key)
        try handlers.take()(nil)
        XCTAssertEqual(events.all, [.restarting(key)])
        relay.urlSession(session, task: b, didCompleteWithError: cancelled)
        XCTAssertEqual(events.all, [.restarting(key)], "one restart, no failure")
        XCTAssertFalse(relay.isRestarting(b))

        // Finished as it was cancelled: no error, nothing owed, the set clean.
        events.clear()
        let c = task()
        relay.cancelForRestart(c, key: key)
        relay.urlSession(session, task: c, didCompleteWithError: nil)
        XCTAssertFalse(relay.isRestarting(c))
        XCTAssertEqual(events.all, [])

        // Not the watchdog's cancel: a failure, as before.
        let d = task()
        relay.urlSession(session, task: d, didCompleteWithError: cancelled)
        XCTAssertEqual(events.all.count, 1)
        guard case .failed(let failedKey, _)? = events.all.first else { return XCTFail("a cancel of the system's own is a failure") }
        XCTAssertEqual(failedKey, key)

        // The relay keys by the task, not the key: a restart in flight for one task under the
        // key does not shield another task's failure under it.
        events.clear()
        let e = task()
        let f = task()
        relay.cancelForRestart(e, key: key)
        relay.urlSession(session, task: f, didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        guard case .failed(let otherKey, _)? = events.all.first else { return XCTFail("another task's failure under the key is a failure") }
        XCTAssertEqual(otherKey, key)
        XCTAssertEqual(events.all.count, 1)
        XCTAssertTrue(relay.isRestarting(e), "the task cancelled for a restart still is")
        XCTAssertFalse(relay.isRestarting(f))
    }

    private final class Handlers: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [@Sendable (Data?) -> Void] = []
        func keep(_ handler: @escaping @Sendable (Data?) -> Void) { lock.withLock { kept.append(handler) } }
        func take() throws -> @Sendable (Data?) -> Void {
            try lock.withLock {
                guard !kept.isEmpty else { throw Missing() }
                return kept.removeFirst()
            }
        }
        struct Missing: Error {}
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [SessionRelay.Event] = []
        var all: [SessionRelay.Event] { lock.withLock { events } }
        func add(_ event: SessionRelay.Event) { lock.withLock { events.append(event) } }
        func clear() { lock.withLock { events = [] } }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func temp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }
}

/// The downloader's waiters: a failure settles the waiters that asked to hear of one, and leaves
/// the ones waiting only for success to wait on.
@MainActor
final class ModelWaitersTests: XCTestCase {
    /// The setup meter's bar: a set of models has a measure only while some of it is downloading
    /// and none of it failed, waits on a network or is being verified, and the share is the
    /// bytes on the phone over the bytes in all, never outside 0 to 1.
    func testASetOfModelsHasAMeasureOnlyWhileItDownloads() {
        typealias Status = ModelDownloads.Status
        XCTAssertTrue(ModelDownloads.measured([.downloading(done: 1, total: 4), .absent]))
        XCTAssertTrue(ModelDownloads.measured([.present, .absent]), "one model on the phone and one to come is partway")
        XCTAssertTrue(ModelDownloads.measured([.present, .downloading(done: 1, total: 4)]))
        for unmeasured in [[Status.present, .present], [.absent, .absent], [.downloading(done: 1, total: 4), .failed("503")],
                           [.downloading(done: 1, total: 4), .waiting], [.present, .verifying], [.queued],
                           [.present, .queued], []] {
            XCTAssertFalse(ModelDownloads.measured(unmeasured), "\(unmeasured)")
        }
        XCTAssertEqual(ModelDownloads.fraction(done: 57, of: 228), 0.25)
        XCTAssertEqual(ModelDownloads.fraction(done: 0, of: 228), 0)
        XCTAssertEqual(ModelDownloads.fraction(done: 300, of: 228), 1)
        XCTAssertNil(ModelDownloads.fraction(done: 0, of: 0))
    }

    /// The ear before the voice: a model asked for after others is held while any of them is
    /// wanted, not on the phone and not failed, and only then. One never asked for (a debug
    /// build's stand-in ear) holds nothing, and a failed one lets it go, so a broken ear never
    /// costs the voice.
    func testAModelAskedForAfterOthersIsHeldUntilTheyAreHereOrFailed() {
        let after = ["voice": ["ear", "spotter"]]
        let both: Set<String> = ["ear", "spotter", "voice"]
        XCTAssertTrue(ModelDownloads.held("voice", after: after, wanted: both, present: [], failed: []))
        XCTAssertTrue(ModelDownloads.held("voice", after: after, wanted: both, present: ["ear"], failed: []),
                      "one of the two still to come holds it")
        XCTAssertFalse(ModelDownloads.held("voice", after: after, wanted: both, present: ["ear", "spotter"], failed: []))
        XCTAssertFalse(ModelDownloads.held("voice", after: after, wanted: both, present: ["ear"], failed: ["spotter"]),
                       "a failed one lets it go")
        XCTAssertFalse(ModelDownloads.held("voice", after: after, wanted: both, present: [], failed: ["spotter"]),
                       "one failed lets it go while the other is still to come")
        XCTAssertFalse(ModelDownloads.held("voice", after: after, wanted: ["voice"], present: [], failed: []),
                       "an ear nobody asked for holds nothing")
        XCTAssertFalse(ModelDownloads.held("ear", after: after, wanted: both, present: [], failed: []),
                       "a model asked for after nothing is never held")
        XCTAssertFalse(ModelDownloads.held("voice", after: [:], wanted: both, present: [], failed: []))
    }

    /// A pass enqueues the ear's models first and holds the voice back; the arrival of both, or
    /// the failure of either, lets the voice go. A failed model is enqueued again only by a pass
    /// that retries (a foreground's `start`), never by the pass a release makes.
    func testAPassEnqueuesTheEarAndHoldsTheVoiceUntilTheEarIsHereOrFailed() {
        let models = ["ear", "spotter", "voice", "rootfs"]
        let after = ["voice": ["ear", "spotter"]]
        let all = Set(models)
        let fresh = ModelDownloads.plan(models, after: after, wanted: all, present: [], failed: [], retry: true)
        XCTAssertEqual(fresh.enqueue, ["ear", "spotter", "rootfs"])
        XCTAssertEqual(fresh.holding, ["voice"])
        let earHere = ModelDownloads.plan(models, after: after, wanted: all, present: ["ear", "spotter"], failed: [], retry: false)
        XCTAssertEqual(earHere.enqueue, ["voice", "rootfs"])
        XCTAssertEqual(earHere.holding, [])
        let spotterFailed = ModelDownloads.plan(models, after: after, wanted: all, present: [], failed: ["spotter"], retry: false)
        XCTAssertEqual(spotterFailed.enqueue, ["ear", "voice", "rootfs"], "a release retries nothing and lets the voice go")
        let retried = ModelDownloads.plan(models, after: after, wanted: all, present: [], failed: ["spotter"], retry: true)
        XCTAssertEqual(retried.enqueue, ["ear", "spotter", "voice", "rootfs"], "a foreground retries the failure beside the voice")
        let notAsked = ModelDownloads.plan(models, after: after, wanted: ["voice"], present: [], failed: [], retry: true)
        XCTAssertEqual(notAsked.enqueue, ["voice"], "an ear nobody asked for holds nothing")
    }

    /// The bar and the words beside it are one count: a model on the phone counts whole, one
    /// downloading by what has arrived, one not begun adds only to the total, and one the
    /// manifest does not name is not counted. The total is the manifest's sizes, whatever a
    /// status says of its own.
    func testTheBarsShareIsTheBytesTheWordsSay() throws {
        typealias Status = ModelDownloads.Status
        let megabyte: Int64 = 1_000_000
        let sizes: [Int64?] = [100 * megabyte, 300 * megabyte, 100 * megabyte, nil]
        let statuses: [Status] = [.present, .downloading(done: 30 * megabyte, total: 7), .absent, .absent]
        let bytes = ModelDownloads.bytes(sizes, statuses)
        XCTAssertEqual(bytes.done, 130 * megabyte)
        XCTAssertEqual(bytes.total, 500 * megabyte)
        XCTAssertEqual(try XCTUnwrap(ModelDownloads.fraction(sizes, statuses)), 0.26, accuracy: 0.0001)
        XCTAssertEqual(ModelDownloads.downloading(bytes), "downloading 130 MB of 500 MB")
        XCTAssertNil(ModelDownloads.fraction(sizes, [.present, .verifying, .absent, .absent]), "a set being verified has no measure")
        XCTAssertNil(ModelDownloads.fraction([nil], [.downloading(done: 1, total: 2)]), "a model the manifest does not name has no size to be a share of")
    }

    func testAFailureSettlesTheWaitersThatAskedForIt() {
        var waiters = ModelWaiters()
        var told: [Result<Void, ModelDownloadFailure>] = []
        waiters.add(["rootfs"], settlesOnFailure: true) { told.append($0) }
        waiters.add(["rootfs"], settlesOnFailure: false) { _ in XCTFail("a success-only waiter heard a failure") }
        waiters.add(["voice"], settlesOnFailure: true) { _ in XCTFail("a waiter on another model heard the failure") }

        let failure = ModelDownloadFailure(id: "rootfs", why: "404")
        waiters.failed("rootfs").forEach { $0(.failure(failure)) }
        XCTAssertEqual(told.count, 1)
        if case .failure(let got) = told.first { XCTAssertEqual(got, failure) } else { XCTFail("not told the failure") }
        XCTAssertEqual(waiters.count, 2, "the settled waiter is gone, the other two wait on")
        XCTAssertTrue(waiters.failed("rootfs").isEmpty, "a settled waiter was told twice")
    }

    func testSuccessSettlesEveryWaiterWhoseModelsArePresent() {
        var waiters = ModelWaiters()
        var told = 0
        waiters.add(["rootfs"], settlesOnFailure: true) { if case .success = $0 { told += 1 } }
        waiters.add(["rootfs"], settlesOnFailure: false) { if case .success = $0 { told += 1 } }
        waiters.add(["rootfs", "voice"], settlesOnFailure: true) { _ in XCTFail("settled with a model still missing") }
        waiters.present(["rootfs"]).forEach { $0(.success(())) }
        XCTAssertEqual(told, 2)
        XCTAssertEqual(waiters.count, 1)
    }
}

/// `ModelDownloads` over an ephemeral session whose protocol never answers: what the glue between
/// the watchdog, the relay and the session's state does with the events the other suites prove
/// are produced. Nothing here reaches the network.
/// A protocol that takes every request and answers none, so a task made under it stays running.
private final class HangingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

@MainActor
final class ModelDownloadsGlueTests: XCTestCase {
    /// A store of this test's own, removed with the test.
    private func scratch() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("topo-glue-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func manifest() -> ModelManifest {
        let revision = String(repeating: "0", count: 40)
        let digest = SHA256.hash(data: Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        return ModelManifest(models: [
            .init(id: "ear", repo: "example/ear", revision: revision, files: [.init(path: "encoder.bin", size: 3, sha256: digest)]),
            .init(id: "voice", repo: "example/voice", revision: revision, files: [.init(path: "weight.bin", size: 3, sha256: digest)]),
        ])
    }

    private func downloads(_ manifest: ModelManifest) -> ModelDownloads {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingProtocol.self]
        return ModelDownloads(store: ModelStore(root: scratch()), manifest: .success(manifest), configuration: configuration)
    }

    /// The watchdog's cancel of `key`, decided: 20 s of samples at 36 KB/s.
    private func crawl(_ downloads: ModelDownloads, _ key: String) {
        let t0 = ContinuousClock.Instant.now
        for s in 0...20 { downloads.watchdog.observe(key, bytes: Int64(s) * 36 * 1024, at: t0 + .seconds(s)) }
        XCTAssertEqual(downloads.watchdog.decisions(at: t0 + .seconds(20)).map(\.key), [key])
    }

    private func tasks(of downloads: ModelDownloads) async -> [String] {
        await withCheckedContinuation { continuation in
            downloads.session.getAllTasks { continuation.resume(returning: $0.compactMap(\.taskDescription).sorted()) }
        }
    }

    func testAPassMakesNoTaskForAKeyBetweenItsCancelAndItsReplacementOrOneThisProcessMade() async {
        let manifest = manifest()
        let downloads = downloads(manifest)
        let key = "ear|encoder.bin"
        downloads.start(["ear"])
        // The first pass: one task, the key live. (`start`'s own pass lands at the first await,
        // and is one more pass that makes no second task.)
        downloads.enqueue(manifest, excluding: [], retry: true)
        XCTAssertEqual(downloads.live, [key])
        var made = await tasks(of: downloads)
        XCTAssertEqual(made, [key])
        // A second pass whose snapshot of the session missed that task (`excluding: []`) makes
        // no second one: the key is live.
        downloads.enqueue(manifest, excluding: [], retry: true)
        made = await tasks(of: downloads)
        XCTAssertEqual(made, [key], "a pass makes no task for a key this process made")
        // The watchdog cancels it: between the cancel and the relay's word, and between that
        // word and the replacement's tick, the key is restarting and no pass makes a task.
        crawl(downloads, key)
        downloads.handle(.restarting(key))
        XCTAssertEqual(downloads.live, [], "the cancelled task is not live")
        XCTAssertTrue(downloads.watchdog.restarting(key))
        downloads.enqueue(manifest, excluding: [], retry: true)
        made = await tasks(of: downloads)
        XCTAssertEqual(made, [key], "a pass makes no task for a key between its cancel and its replacement")
        XCTAssertEqual(downloads.live, [])
        // Forgotten (verified, failed), a pass makes one again.
        downloads.watchdog.forget(key)
        downloads.enqueue(manifest, excluding: [], retry: true)
        made = await tasks(of: downloads)
        XCTAssertEqual(made, [key, key], "a key no longer restarting or live is enqueued as any other")
    }

    func testARestartIsNotAFailureAnywhere() {
        let manifest = manifest()
        let downloads = downloads(manifest)
        let key = "ear|encoder.bin"
        downloads.start(["ear"])
        downloads.start(["voice"], after: ["ear"])
        downloads.enqueue(manifest, excluding: [], retry: true)
        downloads.handle(.progress(key, 1))
        XCTAssertEqual(downloads.status(for: "ear"), .downloading(done: 1, total: 3))
        XCTAssertEqual(downloads.status(for: "voice"), .queued, "held behind the ear")
        var settled: [Result<Void, ModelDownloadFailure>] = []
        downloads.whenSettled(["ear"]) { settled.append($0) }
        crawl(downloads, key)

        downloads.handle(.restarting(key))

        XCTAssertFalse(downloads.failed(["ear"]), "a restart sets no failure")
        XCTAssertEqual(downloads.status(for: "ear"), .downloading(done: 1, total: 3), "the key stays in flight at the bytes last reported")
        XCTAssertTrue(settled.isEmpty, "a waiter on the model is not told anything")
        XCTAssertEqual(downloads.status(for: "voice"), .queued, "the model held behind it is still held")
        XCTAssertTrue(downloads.watchdog.restarting(key), "the replacement is owed")
        // A restart for a key no longer in flight (verified or failed meanwhile) owes nothing.
        downloads.handle(.verifying(key))
        downloads.handle(.restarting(key))
        XCTAssertFalse(downloads.watchdog.restarting(key))
        XCTAssertEqual(downloads.status(for: "ear"), .verifying)
    }
}
