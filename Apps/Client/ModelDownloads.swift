#if os(iOS)
import CryptoKit
import Foundation
import Observation
import UIKit
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Every file the phone downloads for its on-device models, pinned: repository, revision, and
/// the flattened file list with sizes and digests. `Apps/Topo/Resources/models.json`, written by
/// `scripts/model-manifest.sh` from the Hugging Face tree API at the pinned revisions, so a bump
/// of a model is a bump of a revision there and a re-run of the script. A `.mlmodelc` bundle is a
/// directory of several files on the Hub, which is why the list is flat.
struct ModelManifest: Codable, Sendable {
    struct File: Codable, Sendable, Equatable {
        let path: String
        let size: Int64
        let sha256: String
    }

    struct Model: Codable, Sendable, Identifiable {
        /// The model's directory under the store's root, and the name the ear and the voice ask
        /// for it by.
        let id: String
        let repo: String
        let revision: String
        let files: [File]

        var bytes: Int64 { files.reduce(0) { $0 + $1.size } }

        /// Where a file is fetched from: the pinned revision, so the manifest's digest is the
        /// digest of what arrives.
        func url(for file: File) -> URL {
            let path = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path
            return URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(path)")!
        }
    }

    let models: [Model]

    /// The directory name FluidAudio derives for the repository, which its loader appends to
    /// the parent of the directory it is given.
    static let parakeet = "parakeet-tdt-0.6b-v2"
    static let ctc = "parakeet-ctc-110m-coreml"
    /// The voice's directory: everything `PocketEngine` loads, the one speaker included.
    static let pocket = "pocket-tts"

    static func load(from url: URL) throws -> ModelManifest {
        try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: url))
    }

    static func bundled(in bundle: Bundle = .main) throws -> ModelManifest {
        guard let url = bundle.url(forResource: "models", withExtension: "json") else {
            throw ModelStoreError.noManifest
        }
        return try load(from: url)
    }

    func model(_ id: String) -> Model? { models.first { $0.id == id } }
}

enum ModelStoreError: LocalizedError {
    case noManifest
    case unknownModel(String)
    case wrongSize(String, expected: Int64, got: Int64)
    case wrongDigest(String)
    case badStatus(String, Int)

    var errorDescription: String? {
        switch self {
        case .noManifest: return "models.json is not in the bundle"
        case .unknownModel(let id): return "\(id) is not in the manifest"
        case .wrongSize(let path, let expected, let got): return "\(path): \(got) bytes, expected \(expected)"
        case .wrongDigest(let path): return "\(path): digest mismatch"
        case .badStatus(let path, let status): return "\(path): HTTP \(status)"
        }
    }
}

/// The models on disk: one directory per manifest entry under Application Support, and beside
/// each file's directory a ledger of the digests verified on arrival. A model is present only
/// when every file in its manifest is on disk at its size and in the ledger under its digest;
/// anything less is a set to finish, file by file, not to start again.
struct ModelStore: Sendable {
    let root: URL
    /// The entries that live somewhere other than under `root`, by id. The CTC spotter's is the
    /// one: FluidAudio's `VocabularyBoostingSession` reads its tokenizer from
    /// `CtcModels.defaultCacheDirectory` whatever directory the models were loaded from, and
    /// its init takes no other, so the spotter's files are downloaded to that path and the ear
    /// loads them from there; one copy, agreed on by both. The ledger and the resume data sit
    /// beside the files wherever the entry lives.
    let homes: [String: URL]

    init(root: URL, homes: [String: URL] = [:]) {
        self.root = root
        self.homes = homes
    }

    static func standard() -> ModelStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var homes: [String: URL] = [:]
        #if canImport(FluidAudio)
        homes[ModelManifest.ctc] = CtcModels.defaultCacheDirectory(for: .ctc110m)
        #endif
        let store = ModelStore(root: support.appendingPathComponent("Models", isDirectory: true), homes: homes)
        store.rehome()
        return store
    }

    func directory(for model: ModelManifest.Model) -> URL {
        homes[model.id] ?? root.appendingPathComponent(model.id, isDirectory: true)
    }

    /// An entry downloaded under `root` before its home was elsewhere is moved there, ledger
    /// and resume data with it: a rename on one volume, not a second download.
    func rehome() {
        let fm = FileManager.default
        for (id, home) in homes {
            let old = root.appendingPathComponent(id, isDirectory: true)
            guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: home.path) else { continue }
            try? fm.createDirectory(at: home.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: old, to: home)
        }
    }

    func location(of file: ModelManifest.File, in model: ModelManifest.Model) -> URL {
        directory(for: model).appendingPathComponent(file.path)
    }

    /// Where a task's resume data waits between one process and the next.
    func resumeData(for file: ModelManifest.File, in model: ModelManifest.Model) -> URL {
        directory(for: model).appendingPathComponent(file.path + ".resume")
    }

    private func ledgerURL(for model: ModelManifest.Model) -> URL {
        directory(for: model).appendingPathComponent(".verified.json")
    }

    private func ledger(for model: ModelManifest.Model) -> [String: String] {
        guard let data = try? Data(contentsOf: ledgerURL(for: model)),
              let ledger = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return ledger
    }

    private func size(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }

    /// The files of `model` not yet on disk, at their size, with their digest verified.
    func unverified(_ model: ModelManifest.Model) -> [ModelManifest.File] {
        let ledger = ledger(for: model)
        return model.files.filter { file in
            ledger[file.path] != file.sha256 || size(at: location(of: file, in: model)) != file.size
        }
    }

    func isPresent(_ model: ModelManifest.Model) -> Bool { unverified(model).isEmpty }

    /// How much of `model` is on disk and verified.
    func verifiedBytes(_ model: ModelManifest.Model) -> Int64 {
        let missing = Set(unverified(model).map(\.path))
        return model.files.filter { !missing.contains($0.path) }.reduce(0) { $0 + $1.size }
    }

    /// A downloaded file, checked against the manifest and moved into place, or refused and
    /// deleted. The temporary file is consumed either way.
    func admit(_ temp: URL, as file: ModelManifest.File, of model: ModelManifest.Model) throws {
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let got = size(at: temp), got == file.size else {
            throw ModelStoreError.wrongSize(file.path, expected: file.size, got: size(at: temp) ?? 0)
        }
        guard try Self.sha256(of: temp) == file.sha256 else { throw ModelStoreError.wrongDigest(file.path) }
        let destination = location(of: file, in: model)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        try? FileManager.default.removeItem(at: resumeData(for: file, in: model))
        var ledger = ledger(for: model)
        ledger[file.path] = file.sha256
        try JSONEncoder().encode(ledger).write(to: ledgerURL(for: model), options: .atomic)
    }

    /// The digest of a file, read in pieces: a weight file is half a gigabyte.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The download of the on-device models: one background `URLSession` for the process, so iOS
/// applies the person's data settings (no expensive or constrained network: Low Data Mode and the
/// cellular data choices are theirs, not ours) and finishes the transfer with the app suspended or
/// gone. Download tasks only, one per file in the manifest, each verified against its digest and
/// moved into the store on arrival; a set half done on the next launch carries on from the files
/// it has, with the server's resume data where it gave any. No prompt and no gate: the download
/// starts on the first foreground and runs whenever iOS lets it.
///
/// A launch iOS makes for a finished transfer arrives through `TopoAppDelegate`, which keeps the
/// completion handler here until the session says it has delivered every event.
@MainActor
@Observable
final class ModelDownloads {
    static let identifier = "zone.hexagon.topo.models"
    static let shared = ModelDownloads()

    enum Status: Equatable {
        case absent
        /// The session has a task and no network its settings allow.
        case waiting
        case downloading(done: Int64, total: Int64)
        case verifying
        case present
        case failed(String)
    }

    let store: ModelStore
    /// Nil when the bundle has no readable manifest, in which case every model is `failed`.
    let manifest: ModelManifest?
    private let trouble: String?
    private let session: URLSession
    private let relay: SessionRelay
    /// The models on disk in full.
    private(set) var present: Set<String> = []
    /// Bytes verified per model, kept here so a status line does not read the ledger.
    private var done: [String: Int64] = [:]
    /// Bytes written so far by each task in flight, by its key.
    private var inFlight: [String: Int64] = [:]
    private var waiting: Set<String> = []
    private var verifying: Set<String> = []
    private var failures: [String: String] = [:]
    private var waiters: [(ids: [String], body: @MainActor () -> Void)] = []
    /// The models something in this process has asked for; the rest of the manifest is left
    /// alone (the simulator's voice never asks for Pocket).
    private var wanted: Set<String> = []
    private var reconciling = false
    /// What iOS gave `handleEventsForBackgroundURLSession`, called once the session has
    /// delivered the events it woke the app for.
    var completion: (() -> Void)?

    /// The session's configuration: background, so the transfer outlives the process; nothing
    /// expensive or constrained, so the person's data settings decide; waiting for connectivity
    /// rather than failing without it; not discretionary, so it runs as soon as it may.
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.waitsForConnectivity = true
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        return configuration
    }

    private init(store: ModelStore = .standard(), manifest: Result<ModelManifest, Error> = Result { try ModelManifest.bundled() }) {
        self.store = store
        switch manifest {
        case .success(let m):
            self.manifest = m
            trouble = nil
        case .failure(let error):
            self.manifest = nil
            trouble = error.localizedDescription
        }
        relay = SessionRelay(store: store, manifest: self.manifest)
        session = URLSession(configuration: Self.configuration(), delegate: relay, delegateQueue: nil)
        relay.events = { [weak self] event in Task { @MainActor in self?.handle(event) } }
        for model in self.manifest?.models ?? [] {
            done[model.id] = store.verifiedBytes(model)
            if store.isPresent(model) { present.insert(model.id) }
        }
    }

    /// Where a model's files are, for its loader. Throws for a name the manifest lacks.
    func directory(for id: String) throws -> URL {
        guard let model = manifest?.model(id) else { throw ModelStoreError.unknownModel(id) }
        return store.directory(for: model)
    }

    /// Starts, or carries on, the download of the named models where they are not yet present.
    /// Idempotent and called on every foreground: tasks the session already holds (from before a
    /// relaunch included) are left alone, and a file that failed is tried again. With no names,
    /// only the reconciliation runs, which is what a relaunch for a finished transfer needs.
    func start(_ ids: [String] = []) {
        wanted.formUnion(ids)
        guard let manifest, !reconciling else { return }
        reconciling = true
        session.getAllTasks { tasks in
            let running = Set(tasks.filter { $0.state == .running || $0.state == .suspended }.compactMap(\.taskDescription))
            Task { @MainActor in
                self.enqueue(manifest, excluding: running)
                self.reconciling = false
            }
        }
    }

    private func enqueue(_ manifest: ModelManifest, excluding running: Set<String>) {
        for model in manifest.models where wanted.contains(model.id) && !present.contains(model.id) {
            failures[model.id] = nil
            for file in store.unverified(model) {
                let key = Self.key(model, file)
                if running.contains(key) {
                    // The session's own, from before a relaunch: counted as in flight until it
                    // reports, so the status line does not read "not downloaded" meanwhile.
                    inFlight[key] = inFlight[key] ?? 0
                    continue
                }
                guard !verifying.contains(key) else { continue }
                let task: URLSessionDownloadTask
                let resume = store.resumeData(for: file, in: model)
                if let data = try? Data(contentsOf: resume) {
                    task = session.downloadTask(withResumeData: data)
                    try? FileManager.default.removeItem(at: resume)
                } else {
                    task = session.downloadTask(with: model.url(for: file))
                }
                task.taskDescription = key
                inFlight[key] = inFlight[key] ?? 0
                task.resume()
            }
        }
    }

    func status(for id: String) -> Status {
        guard let manifest, let model = manifest.model(id) else { return .failed(trouble ?? "\(id) is not in the manifest") }
        if present.contains(id) { return .present }
        if let why = failures[id] { return .failed(why) }
        let keys = model.files.map { Self.key(model, $0) }
        if keys.contains(where: { verifying.contains($0) }) { return .verifying }
        let flowing = keys.filter { inFlight[$0] != nil }
        if flowing.isEmpty { return .absent }
        if flowing.contains(where: waiting.contains), !flowing.contains(where: { (inFlight[$0] ?? 0) > 0 }) {
            return .waiting
        }
        let bytes = (done[id] ?? 0) + flowing.reduce(0) { $0 + (inFlight[$1] ?? 0) }
        return .downloading(done: bytes, total: model.bytes)
    }

    /// One line for several models together, as the ear's or the voice's status: the state that
    /// matters most among them, with the bytes summed over the set while it downloads.
    func describe(_ ids: [String]) -> String {
        let statuses = ids.map { status(for: $0) }
        for status in statuses {
            if case .failed(let why) = status { return "download failed: \(why)" }
        }
        if statuses.contains(.waiting) { return "waiting for a network the data settings allow" }
        if statuses.contains(.verifying) { return "verifying the download" }
        if statuses.allSatisfy({ $0 == .present }) { return "downloaded" }
        if statuses.allSatisfy({ $0 == .absent }) { return "not downloaded" }
        var done: Int64 = 0, total: Int64 = 0
        for (id, status) in zip(ids, statuses) {
            guard let model = manifest?.model(id) else { continue }
            total += model.bytes
            switch status {
            case .present: done += model.bytes
            case .downloading(let bytes, _): done += bytes
            default: break
            }
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "downloading \(formatter.string(fromByteCount: done)) of \(formatter.string(fromByteCount: total))"
    }

    /// Runs `body` once every model in `ids` is present: now, if they already are.
    func whenPresent(_ ids: [String], _ body: @escaping @MainActor () -> Void) {
        if ids.allSatisfy({ present.contains($0) }) {
            body()
        } else {
            waiters.append((ids, body))
        }
    }

    private static func key(_ model: ModelManifest.Model, _ file: ModelManifest.File) -> String {
        "\(model.id)|\(file.path)"
    }

    private func handle(_ event: SessionRelay.Event) {
        switch event {
        case .waiting(let key):
            waiting.insert(key)
        case .progress(let key, let bytes):
            waiting.remove(key)
            inFlight[key] = bytes
        case .verifying(let key):
            waiting.remove(key)
            inFlight[key] = nil
            verifying.insert(key)
        case .verified(let id, let path, let size):
            verifying.remove("\(id)|\(path)")
            done[id, default: 0] += size
            if let model = manifest?.model(id), store.isPresent(model) {
                present.insert(id)
                let ready = waiters.filter { $0.ids.allSatisfy(present.contains) }
                waiters.removeAll { $0.ids.allSatisfy(present.contains) }
                ready.forEach { $0.body() }
            }
        case .failed(let key, let why):
            verifying.remove(key)
            waiting.remove(key)
            inFlight[key] = nil
            let id = String(key.prefix(while: { $0 != "|" }))
            failures[id] = why
        case .finished:
            let handler = completion
            completion = nil
            handler?()
        }
    }
}

/// The session's delegate, off the main actor: the callbacks arrive on the session's own queue,
/// and the one that hands over a finished file has to deal with it before returning. It verifies
/// and admits the file there and then, and reports everything else to `ModelDownloads` as events.
private final class SessionRelay: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case waiting(String)
        case progress(String, Int64)
        case verifying(String)
        case verified(id: String, path: String, size: Int64)
        case failed(String, String)
        case finished
    }

    private let store: ModelStore
    private let manifest: ModelManifest?
    private let lock = NSLock()
    private var sink: (@Sendable (Event) -> Void)?
    /// Events from before the sink was set: the session can deliver a relaunch's events the
    /// moment it exists, and the one that calls the system's completion handler must not be
    /// lost to that gap.
    private var pending: [Event] = []

    init(store: ModelStore, manifest: ModelManifest?) {
        self.store = store
        self.manifest = manifest
    }

    var events: (@Sendable (Event) -> Void)? {
        get { lock.withLock { sink } }
        set {
            let held: [Event] = lock.withLock {
                sink = newValue
                defer { pending = [] }
                return pending
            }
            held.forEach { newValue?($0) }
        }
    }

    private func report(_ event: Event) {
        let sink: (@Sendable (Event) -> Void)? = lock.withLock {
            if self.sink == nil { pending.append(event) }
            return self.sink
        }
        sink?(event)
    }

    private func lookup(_ task: URLSessionTask) -> (key: String, model: ModelManifest.Model, file: ModelManifest.File)? {
        guard let key = task.taskDescription, let bar = key.firstIndex(of: "|"),
              let model = manifest?.model(String(key[..<bar])) else { return nil }
        let path = String(key[key.index(after: bar)...])
        guard let file = model.files.first(where: { $0.path == path }) else { return nil }
        return (key, model, file)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (key, model, file) = lookup(downloadTask) else {
            try? FileManager.default.removeItem(at: location)
            return
        }
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            try? FileManager.default.removeItem(at: location)
            report(.failed(key, ModelStoreError.badStatus(file.path, status).localizedDescription))
            return
        }
        report(.verifying(key))
        do {
            try store.admit(location, as: file, of: model)
            report(.verified(id: model.id, path: file.path, size: file.size))
        } catch {
            report(.failed(key, error.localizedDescription))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        report(.progress(key, totalBytesWritten))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let (key, model, file) = lookup(task) else { return }
        // What the server lets the next task pick up from, kept for the next `start`.
        if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            let resume = store.resumeData(for: file, in: model)
            try? FileManager.default.createDirectory(at: resume.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: resume, options: .atomic)
        }
        report(.failed(key, error.localizedDescription))
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        guard let key = task.taskDescription else { return }
        report(.waiting(key))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        report(.finished)
    }
}

/// The app delegate the SwiftUI app adapts, for the one UIKit callback SwiftUI has no spelling
/// of: iOS relaunching the app because its background session finished. Touching `shared`
/// recreates the session under its identifier, which is what reconnects the delegate; the
/// finished files are then delivered to it and admitted, and the handler is called after.
final class TopoAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == ModelDownloads.identifier else { completionHandler(); return }
        Task { @MainActor in
            ModelDownloads.shared.completion = completionHandler
            ModelDownloads.shared.start()
        }
    }
}
#endif
