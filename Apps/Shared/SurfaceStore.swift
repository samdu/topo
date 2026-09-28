#if os(iOS)
import Foundation

/// The mind's widgets on disk: the `Surfaces` folder in the app group `group.zone.hexagon.topo`,
/// which the app writes and the widget extension reads.
///
/// - `<slot>.json`, one document per slot, as the app kept it (`WidgetDocument.text`), and
///   `_default.json`, the app's own (`DefaultSurface`);
/// - `<slot>/<name>.png`, a slot's images, re-encoded by `topo widget image`;
/// - `revisions.json`, the last revision given each slot, which outlives a slot's clearing so a
///   slot written again never reuses a revision an old timeline's tap still carries;
/// - `pending.jsonl`, the turn taps the cue intent recorded and the app has not yet put on the
///   line (`WidgetCues`);
/// - `taps.jsonl`, the last actions taken: time, slot, control, revision, kind and status, and
///   never an argument or a word a tool said.
///
/// Every write is one atomic replace under an `NSFileCoordinator` write, and every read is under a
/// coordinated read, so the extension never reads half a document. The files are
/// `completeUntilFirstUserAuthentication`: a lock-screen widget draws after the first unlock.
struct SurfaceStore: Sendable {
    static let appGroup = "group.zone.hexagon.topo"
    /// The one widget kind, `TopoSurface`, which `SurfaceReloader` reloads.
    static let kind = "TopoSurface"
    static let defaultSlot = "_default"
    static let tapsKept = 50

    let folder: URL

    init(folder: URL) {
        self.folder = folder
    }

    /// The app group's folder, or nil where the process has no app group (an unsigned build).
    static func shared() -> SurfaceStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map { SurfaceStore(folder: $0.appendingPathComponent("Surfaces", isDirectory: true)) }
    }

    func url(slot: String) -> URL { folder.appendingPathComponent("\(slot).json") }
    func images(slot: String) -> URL { folder.appendingPathComponent(slot, isDirectory: true) }
    func image(slot: String, name: String) -> URL { images(slot: slot).appendingPathComponent("\(name).png") }
    var pendingURL: URL { folder.appendingPathComponent("pending.jsonl") }
    var tapsURL: URL { folder.appendingPathComponent("taps.jsonl") }
    var revisionsURL: URL { folder.appendingPathComponent("revisions.json") }

    // MARK: Coordination

    private func coordinatedRead(_ url: URL) -> Data? {
        var data: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { url in
            data = try? Data(contentsOf: url)
        }
        return data
    }

    /// `change` is handed what is there now and answers what replaces it, all under one
    /// coordinated write: nil removes the file.
    @discardableResult
    private func coordinatedWrite(_ url: URL, _ change: (Data?) throws -> Data?) throws -> Bool {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var error: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { url in
            do {
                let now = try? Data(contentsOf: url)
                if let next = try change(now) {
                    try next.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                } else if now != nil {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                thrown = error
            }
        }
        if let error { throw error }
        if let thrown { throw thrown }
        return true
    }

    // MARK: Documents

    /// The slot's kept document, read under a coordinated read. Nil is no file; a file the
    /// reader cannot take is a reading that says why.
    func read(slot: String) -> WidgetDocument.Reading? {
        guard let data = coordinatedRead(url(slot: slot)) else { return nil }
        return WidgetDocument.read(String(decoding: data, as: UTF8.self), from: .store)
    }

    /// Keeps `document` as the slot's, under the next revision, and answers that revision.
    @discardableResult
    func write(_ document: WidgetDocument, slot: String) throws -> Int {
        var kept = document
        kept.revision = try nextRevision(slot: slot)
        try coordinatedWrite(url(slot: slot)) { _ in Data(kept.text.utf8) }
        return kept.revision
    }

    /// The app's own default, written whole at the revision it carries.
    func writeDefault(_ document: WidgetDocument) throws {
        try coordinatedWrite(url(slot: Self.defaultSlot)) { _ in Data(document.text.utf8) }
    }

    /// The slots the mind has written, by name: every document but the app's own.
    func slots() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && $0 != "revisions.json" }
            .map { String($0.dropLast(5)) }
            .filter { $0 != Self.defaultSlot }
            .sorted()
    }

    /// Takes a slot away, its images with it.
    func remove(slot: String) throws {
        try coordinatedWrite(url(slot: slot)) { _ in nil }
        if FileManager.default.fileExists(atPath: images(slot: slot).path) {
            try FileManager.default.removeItem(at: images(slot: slot))
        }
    }

    /// Everything, the default and the pending taps included: what a sign-out leaves.
    func removeEverything() throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        var error: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(writingItemAt: folder, options: .forDeleting, error: &error) { url in
            do { try FileManager.default.removeItem(at: url) } catch { thrown = error }
        }
        if let error { throw error }
        if let thrown { throw thrown }
    }

    // MARK: Revisions

    /// The slot's current revision, which a tap is judged against. Zero is a slot never written.
    func revision(slot: String) -> Int {
        guard let data = coordinatedRead(revisionsURL),
              let revisions = try? JSONDecoder().decode([String: Int].self, from: data) else { return 0 }
        return revisions[slot] ?? 0
    }

    private func nextRevision(slot: String) throws -> Int {
        var next = 0
        try coordinatedWrite(revisionsURL) { data in
            var revisions = data.flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
            next = (revisions[slot] ?? 0) + 1
            revisions[slot] = next
            return try JSONEncoder().encode(revisions)
        }
        return next
    }

    // MARK: Images

    func writeImage(_ png: Data, slot: String, name: String) throws {
        try FileManager.default.createDirectory(at: images(slot: slot), withIntermediateDirectories: true)
        try coordinatedWrite(image(slot: slot, name: name)) { _ in png }
    }

    func imageNames(slot: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: images(slot: slot).path)) ?? []
        return names.filter { $0.hasSuffix(".png") }.map { String($0.dropLast(4)) }.sorted()
    }

    func imageData(slot: String, name: String) -> Data? {
        coordinatedRead(image(slot: slot, name: name))
    }

    // MARK: Cues

    /// A `turn` tap, recorded by the cue intent under a nonce minted there.
    struct Cue: Codable, Equatable, Sendable {
        var nonce: String
        var slot: String
        var id: String
        var revision: Int
        var say: String?
        var time: Date

        /// The words the turn carries.
        var words: String {
            "widget \(slot): " + (say ?? "tapped \(id)")
        }
    }

    func appendCue(_ cue: Cue) throws {
        try append(cue, to: pendingURL)
    }

    func cues() -> [Cue] { lines(pendingURL) }

    /// Takes the cue under `nonce` off the pending list.
    func removeCue(nonce: String) throws {
        try coordinatedWrite(pendingURL) { data in
            let kept = Self.decode(Cue.self, data).filter { $0.nonce != nonce }
            return kept.isEmpty ? nil : Self.encode(kept)
        }
    }

    // MARK: Taps

    /// One action taken, as `topo widget taps` shows it: never an argument or a tool's words.
    struct Tap: Codable, Equatable, Sendable {
        var time: Date
        var slot: String
        var id: String
        var revision: Int
        var kind: String
        /// The call's exit status, `stale` for a tap on an old revision, `cued` for a turn.
        var status: String
    }

    func appendTap(_ tap: Tap) throws {
        try coordinatedWrite(tapsURL) { data in
            Self.encode(Array((Self.decode(Tap.self, data) + [tap]).suffix(Self.tapsKept)))
        }
    }

    func taps() -> [Tap] { lines(tapsURL) }

    // MARK: Lines

    private func append<T: Codable>(_ value: T, to url: URL) throws {
        try coordinatedWrite(url) { data in Self.encode(Self.decode(T.self, data) + [value]) }
    }

    private func lines<T: Codable>(_ url: URL) -> [T] {
        Self.decode(T.self, coordinatedRead(url))
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> [T] {
        guard let data else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(T.self, from: Data($0)) }
    }

    private static func encode<T: Encodable>(_ values: [T]) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        var data = Data()
        for value in values {
            if let line = try? encoder.encode(value) { data.append(line); data.append(UInt8(ascii: "\n")) }
        }
        return data
    }
}
#endif
