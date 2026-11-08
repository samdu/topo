import CryptoKit
import UIKit
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
        for id in [ModelManifest.parakeet, ModelManifest.mini, ModelManifest.ctc, ModelManifest.pocket] {
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
        XCTAssertEqual(rootfs.files.map(\.path), ["alpine-minirootfs-3.22.7-aarch64.tar.gz"])
        XCTAssertEqual(rootfs.url(for: rootfs.files[0]).absoluteString,
                       "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/aarch64/alpine-minirootfs-3.22.7-aarch64.tar.gz")
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

    /// Fluid Speech Mini loads as FluidAudio's `.ultra` from its own directory, whose loader asks
    /// for the joint as `JointDecisionv3.mlmodelc`: the manifest lays the repository's
    /// `JointDecision.mlmodelc` there and fetches it from its own path, so a file lands where the
    /// loader looks and its URL is one the Hub serves.
    func testFluidSpeechMiniLandsItsJointWhereTheUltraLoaderLooks() throws {
        let mini = try XCTUnwrap(try ModelManifest.bundled().model(ModelManifest.mini))
        XCTAssertEqual(mini.repo, "FluidVoice-Labs/fluid-speech-mini-coreml")
        let bundles = Set(mini.files.compactMap { $0.path.split(separator: "/").first.map(String.init) })
        XCTAssertEqual(bundles, ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
                                 "JointDecisionv3.mlmodelc", "parakeet_vocab.json"])
        let joint = mini.files.filter { $0.path.hasPrefix("JointDecisionv3.mlmodelc/") }
        XCTAssertFalse(joint.isEmpty)
        for file in joint {
            let from = try XCTUnwrap(file.from, file.path)
            XCTAssertEqual(from, "JointDecision.mlmodelc/" + file.path.dropFirst("JointDecisionv3.mlmodelc/".count))
            XCTAssertEqual(mini.url(for: file).absoluteString,
                           "https://huggingface.co/FluidVoice-Labs/fluid-speech-mini-coreml/resolve/\(mini.revision!)/\(from)")
        }
        for file in mini.files where !file.path.hasPrefix("JointDecisionv3.mlmodelc/") {
            XCTAssertNil(file.from, file.path)
        }
    }

    /// The phone's manifest holds the one recogniser its OS runs: Mini on iOS 18 and later, v2
    /// on 17, and the other's entry gone, so it is never fetched and a copy left by an earlier
    /// OS is swept.
    @MainActor
    func testThePhoneKeepsTheRecogniserItsOSRuns() throws {
        XCTAssertEqual(Recogniser.running(iOS18: true), .fluidSpeechMini)
        XCTAssertEqual(Recogniser.running(iOS18: false), .parakeetV2)
        XCTAssertEqual(Recogniser.current, .fluidSpeechMini, "the suite runs on an iOS 18 or later simulator")
        XCTAssertEqual(Recogniser.unused, .parakeetV2)
        XCTAssertEqual(Ear.models, [ModelManifest.mini, ModelManifest.ctc])
        let bundled = try ModelManifest.bundled()
        let kept = bundled.excluding([Recogniser.unused.id])
        XCTAssertNil(kept.model(ModelManifest.parakeet))
        XCTAssertNotNil(kept.model(ModelManifest.mini))
        XCTAssertEqual(kept.models.map(\.id), bundled.models.map(\.id).filter { $0 != ModelManifest.parakeet })
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
    /// completes as a restart, never a failure, and `.restarting` is said only once both the
    /// cancel's handler and the completion have come, in either order, with the resume data
    /// either carried on disk first. One that finished as it was cancelled is owed nothing and
    /// gets no resume data beside its file. One it did not cancel completes as a failure.
    func testACancelForARestartIsSaidOnceBothCallbacksAreInAndNeverAsAFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("topo-relay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "topo-relay-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let abc = digest(Data("abc".utf8))
        let model = ModelManifest.Model(id: "example", repo: "example/example", revision: String(repeating: "0", count: 40), files: [
            .init(path: "weight.bin", size: 3, sha256: abc),
            .init(path: "other.bin", size: 3, sha256: abc),
            .init(path: "third.bin", size: 3, sha256: abc),
        ])
        let key = "example|weight.bin"
        let handlers = Handlers()
        let store = ModelStore(root: root)
        let relay = SessionRelay(store: store, manifest: ModelManifest(models: [model]), defaults: defaults) { _, handler in
            handlers.keep(handler)
        }
        let events = Events()
        // What the resume file holds at the moment each `.restarting` is said, not after.
        let atRestart = Events.Kept()
        let weightResume = store.resumeData(for: model.files[0], in: model)
        relay.events = { event in
            if case .restarting = event { atRestart.add(try? Data(contentsOf: weightResume)) }
            events.add(event)
        }
        let session = URLSession.shared
        func task(_ key: String = key) -> URLSessionDownloadTask {
            let task = session.downloadTask(with: URL(string: "https://example.invalid/weight.bin")!)
            task.taskDescription = key
            return task
        }
        func resume(_ index: Int) -> URL { store.resumeData(for: model.files[index], in: model) }
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

        // Completion first, then the handler with resume data: said at the handler, after it wrote.
        let a = task()
        relay.cancelForRestart(a, key: key)
        XCTAssertTrue(relay.isRestarting(a))
        relay.urlSession(session, task: a, didCompleteWithError: cancelled)
        XCTAssertTrue(relay.isRestarting(a), "the handler is still to come")
        XCTAssertEqual(events.all, [], "the completion alone says nothing")
        try handlers.take()(Data("resume".utf8))
        XCTAssertEqual(events.all, [.restarting(key)])
        XCTAssertFalse(relay.isRestarting(a))
        XCTAssertEqual(atRestart.all.last, Data("resume".utf8), "the handler wrote the resume data before saying so")
        try FileManager.default.removeItem(at: resume(0))

        // Handler first with none, then a completion whose error carries resume data: said at the
        // completion, after its data is on disk, so the replacement can pick up from it.
        events.clear()
        let b = task()
        relay.cancelForRestart(b, key: key)
        try handlers.take()(nil)
        XCTAssertEqual(events.all, [], "the handler alone says nothing")
        XCTAssertTrue(relay.isRestarting(b))
        let carrying = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                               userInfo: [NSURLSessionDownloadTaskResumeData: Data("late".utf8)])
        relay.urlSession(session, task: b, didCompleteWithError: carrying)
        XCTAssertEqual(events.all, [.restarting(key)], "one restart, no failure")
        XCTAssertEqual(atRestart.all.last, Data("late".utf8), "the completion's resume data is on disk when the restart is said")
        XCTAssertFalse(relay.isRestarting(b))
        try FileManager.default.removeItem(at: resume(0))

        // A completion with no error and no finish before it, then the handler: still one restart.
        events.clear()
        let c = task()
        relay.cancelForRestart(c, key: key)
        relay.urlSession(session, task: c, didCompleteWithError: nil)
        XCTAssertEqual(events.all, [])
        try handlers.take()(nil)
        XCTAssertEqual(events.all, [.restarting(key)])

        // Finished as it was cancelled, the finish first: verified, and the handler that comes
        // after writes nothing beside the file and says nothing; nor does the completion.
        events.clear()
        let otherKey = "example|other.bin"
        let d = task(otherKey)
        relay.cancelForRestart(d, key: otherKey)
        relay.urlSession(session, downloadTask: d, didFinishDownloadingTo: try temp(Data("abc".utf8)))
        try handlers.take()(Data("stale".utf8))
        relay.urlSession(session, task: d, didCompleteWithError: nil)
        XCTAssertEqual(events.all, [.verifying(otherKey), .verified(id: "example", path: "other.bin", size: 3)], "nothing owed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: resume(1).path), "no resume data beside a verified file")
        XCTAssertFalse(relay.isRestarting(d))

        // The handler first with none, then the finish, then the completion: nothing owed either.
        events.clear()
        let thirdKey = "example|third.bin"
        let e = task(thirdKey)
        relay.cancelForRestart(e, key: thirdKey)
        try handlers.take()(nil)
        relay.urlSession(session, downloadTask: e, didFinishDownloadingTo: try temp(Data("abc".utf8)))
        relay.urlSession(session, task: e, didCompleteWithError: nil)
        XCTAssertEqual(events.all, [.verifying(thirdKey), .verified(id: "example", path: "third.bin", size: 3)])
        XCTAssertFalse(relay.isRestarting(e))

        // Not the watchdog's cancel: a failure, as before.
        events.clear()
        let f = task()
        relay.urlSession(session, task: f, didCompleteWithError: cancelled)
        XCTAssertEqual(events.all.count, 1)
        guard case .failed(let failedKey, _)? = events.all.first else { return XCTFail("a cancel of the system's own is a failure") }
        XCTAssertEqual(failedKey, key)

        // The relay keys by the task, not the key: a restart in flight for one task under the
        // key does not shield another task's failure under it.
        events.clear()
        let g = task()
        let h = task()
        relay.cancelForRestart(g, key: key)
        relay.urlSession(session, task: h, didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        guard case .failed(let failedAgain, _)? = events.all.first else { return XCTFail("another task's failure under the key is a failure") }
        XCTAssertEqual(failedAgain, key)
        XCTAssertEqual(events.all.count, 1)
        XCTAssertTrue(relay.isRestarting(g), "the task cancelled for a restart still is")
        XCTAssertFalse(relay.isRestarting(h))
    }

    /// A task made from resume data whose server answers with a stale status (403, 412, 416) is a
    /// fresh fetch, not a failure, and that holds for a relay made after a relaunch the session
    /// woke for: the mark is kept in defaults, by key. A task made afresh clears it, so the same
    /// status from that one is a failure.
    func testAStaleStatusFromAResumedTaskIsAFreshFetchAcrossARelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("topo-stale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "topo-stale-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ModelManifest.Model(id: "example", repo: "example/example", revision: String(repeating: "0", count: 40), files: [
            .init(path: "weight.bin", size: 3, sha256: digest(Data("abc".utf8))),
        ])
        let manifest = ModelManifest(models: [model])
        let key = "example|weight.bin"
        // The process that made the task from resume data.
        SessionRelay(store: ModelStore(root: root), manifest: manifest, defaults: defaults).made(key, fromResume: true)

        // The relaunch: a new relay, and the task's answer through a session that says 403.
        func answer(_ relay: SessionRelay) async -> [SessionRelay.Event] {
            let events = Events()
            let finished = expectation(description: "the task's events")
            relay.events = { event in
                events.add(event)
                if case .staleResume = event { finished.fulfill() }
                if case .failed = event { finished.fulfill() }
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ForbiddenProtocol.self]
            let session = URLSession(configuration: configuration, delegate: relay, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let task = session.downloadTask(with: URL(string: "https://example.invalid/weight.bin")!)
            task.taskDescription = key
            task.resume()
            await fulfillment(of: [finished], timeout: 10)
            return events.all
        }
        let relaunched = SessionRelay(store: ModelStore(root: root), manifest: manifest, defaults: defaults)
        XCTAssertTrue(relaunched.madeFromResume(key))
        let stale = await answer(relaunched)
        XCTAssertEqual(stale.first, .staleResume(key), "the relaunched relay still knows the task was made from resume data")

        relaunched.made(key, fromResume: false)
        let fresh = await answer(relaunched)
        guard case .failed(let failedKey, _)? = fresh.first else { return XCTFail("a fresh task's 403 is a failure") }
        XCTAssertEqual(failedKey, key)
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

        /// What a sink saw of the disk as each event arrived.
        final class Kept: @unchecked Sendable {
            private let lock = NSLock()
            private var kept: [Data?] = []
            var all: [Data?] { lock.withLock { kept } }
            func add(_ data: Data?) { lock.withLock { kept.append(data) } }
        }
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

/// A protocol that answers every request with a 403 and no body.
private final class ForbiddenProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
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

    private func downloads(_ manifest: ModelManifest, store: ModelStore? = nil) -> ModelDownloads {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingProtocol.self]
        let suite = "topo-glue-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return ModelDownloads(store: store ?? ModelStore(root: scratch()), manifest: .success(manifest),
                              configuration: configuration, defaults: defaults)
    }

    /// A watchdog's cancel taken through to its replacement: the relay's word, then a tick once
    /// the backoff is due, makes the replacement from the resume data the cancel left, consumes
    /// it, and marks the key as made from resume data.
    func testATickMakesTheReplacementFromTheCancelsResumeData() throws {
        let manifest = manifest()
        let store = ModelStore(root: scratch())
        let downloads = downloads(manifest, store: store)
        let key = "ear|encoder.bin"
        let model = try XCTUnwrap(manifest.model("ear"))
        downloads.relay.made(key, fromResume: true)
        downloads.start(["ear"])
        downloads.enqueue(manifest, excluding: [], retry: true)
        XCTAssertFalse(downloads.relay.madeFromResume(key), "a task made from the URL clears the mark")
        downloads.handle(.progress(key, 36 * 1024))
        crawl(downloads, key)
        let resume = store.resumeData(for: model.files[0], in: model)
        try FileManager.default.createDirectory(at: resume.deletingLastPathComponent(), withIntermediateDirectories: true)
        // An empty binary property list: CFNetwork makes a task from it without throwing, where
        // bytes that parse as anything but a dictionary raise inside `downloadTask(withResumeData:)`.
        try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0).write(to: resume)
        downloads.handle(.restarting(key))
        XCTAssertTrue(downloads.watchdog.restarting(key))
        XCTAssertFalse(downloads.live.contains(key))

        downloads.tick()

        XCTAssertFalse(downloads.watchdog.restarting(key), "the replacement is made, once")
        XCTAssertTrue(downloads.live.contains(key), "and live under the key")
        XCTAssertFalse(FileManager.default.fileExists(atPath: resume.path), "from the cancel's resume data, consumed")
        XCTAssertTrue(downloads.relay.madeFromResume(key))
    }

    /// A resumed task the server answered from the start (offset 0) is never cancelled again,
    /// since its replacement would start from nothing too; one that picked up past 0 is.
    func testAResumeFromNothingIsNotCancelledAgain() {
        let t0 = ContinuousClock.Instant.now
        func crawlDecisions(after offset: Int64) -> [String] {
            let downloads = downloads(manifest())
            let key = "ear|encoder.bin"
            downloads.handle(.resumed(key, offset))
            for s in 0...20 { downloads.watchdog.observe(key, bytes: Int64(s) * 200 * 1024, at: t0 + .seconds(s)) }
            return downloads.watchdog.decisions(at: t0 + .seconds(20)).map(\.key)
        }
        XCTAssertEqual(crawlDecisions(after: 0), [], "200 KB/s from nothing again is left to run")
        XCTAssertEqual(crawlDecisions(after: 4096), ["ear|encoder.bin"], "200 KB/s from a resume is cancelled")
    }

    /// A probe's answer is applied only for the return that asked for it, with the app in front:
    /// each move in or out of the foreground advances the generation, so return 1's answer
    /// landing after a resign and a second return is dropped and leaves the watchdog as it was.
    func testAProbeLandingAfterTheAppResignedAgainIsDropped() {
        // Synchronous throughout: each posted return asks the session, whose answer hops to the
        // main actor and would be applied at the first suspension.
        let downloads = downloads(manifest())
        let key = "ear|encoder.bin"
        let t0 = ContinuousClock.Instant.now
        let center = NotificationCenter.default
        let start = downloads.lifecycle
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(downloads.lifecycle, start + 1, "a return advances the generation")
        let first = downloads.lifecycle
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertEqual(downloads.lifecycle, start + 2, "a resign advances it")
        downloads.watchdog.observe(key, bytes: 4096, at: t0)
        XCTAssertEqual(downloads.watchdog.kept(key), 0, "away: nothing sampled")
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(downloads.lifecycle, start + 3)
        downloads.probed([key: 2048], asked: first, active: true)
        downloads.watchdog.observe(key, bytes: 4096, at: t0 + .seconds(1))
        XCTAssertEqual(downloads.watchdog.kept(key), 0, "return 1's answer, late: the resign stands")
        downloads.probed([key: 2048], asked: downloads.lifecycle, active: false)
        XCTAssertEqual(downloads.watchdog.kept(key), 0, "the app not in front: the resign stands")
        downloads.probed([key: 2048], asked: downloads.lifecycle, active: true)
        XCTAssertEqual(downloads.watchdog.kept(key), 1, "the return that asked, in front: anchored")
    }

    /// A file that finishes between a return's ask and its answer is not brought back by the
    /// answer: the answer is the session's from before, and the finished task reports nothing
    /// more, so a stalled sibling is judged alone.
    func testAFileFinishedBeforeTheProbeLandsIsNotRestored() {
        let downloads = downloads(manifest())
        let a = "ear|encoder.bin"
        let b = "ear|decoder.bin"
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        downloads.watchdog.forget(a)
        downloads.probed([a: 2 * 1024 * 1024, b: 2 * 1024 * 1024], asked: downloads.lifecycle, active: true)
        XCTAssertEqual(downloads.watchdog.kept(a), 0, "forgotten since the ask: not anchored")
        XCTAssertEqual(downloads.watchdog.kept(b), 1)
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
