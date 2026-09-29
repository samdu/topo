#if os(iOS)
import Foundation

/// The mind's widgets on disk: the `Surfaces` folder in the app group `group.zone.hexagon.topo`,
/// which the app writes and the widget extension reads.
///
/// - `<slot>.json`, one document per slot, as the app kept it (`WidgetDocument.text`), and
///   `_default.json`, the app's own (`DefaultSurface`);
/// - `<slot>/<name>.png`, a slot's images, re-encoded by `topo widget image`;
/// - `_revisions.json`, the last revision given each slot, which outlives a slot's clearing, and
///   a sign-out as `_floor`, the highest given, so no revision is issued twice to any slot of any
///   login and an old timeline's tap never matches a document written since;
/// - `_pending.jsonl`, the turn taps the cue intent recorded and the app has not yet put on the
///   line (`WidgetCues`);
/// - `_outcomes.json`, the last run of each control of each slot, its revision and status, which
///   the failure mark is drawn from, so no number of other taps evicts a control's failure;
/// - `_taps.jsonl`, the last actions taken: time, slot, control, revision, kind and status, and
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

    /// A slot's document. A slot is `_default` or a name `WidgetDocument.isSlot` takes, and the
    /// store's own files all start `_`, which no slot the mind names can: a slot is never one of
    /// them, and never a path out of the folder.
    func url(slot: String) -> URL { folder.appendingPathComponent("\(slot).json") }

    static func isSlot(_ slot: String) -> Bool { slot == defaultSlot || WidgetDocument.isSlot(slot) }
    func images(slot: String) -> URL { folder.appendingPathComponent(slot, isDirectory: true) }
    func image(slot: String, name: String) -> URL { images(slot: slot).appendingPathComponent("\(name).png") }
    var pendingURL: URL { folder.appendingPathComponent("_pending.jsonl") }
    var tapsURL: URL { folder.appendingPathComponent("_taps.jsonl") }
    var revisionsURL: URL { folder.appendingPathComponent("_revisions.json") }
    var outcomesURL: URL { folder.appendingPathComponent("_outcomes.json") }

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
                // A file that is there and cannot be read fails the write rather than reading as none.
                let now = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
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
        guard Self.isSlot(slot), let data = coordinatedRead(url(slot: slot)) else { return nil }
        return WidgetDocument.read(String(decoding: data, as: UTF8.self), from: .store)
    }

    /// Keeps `document` as the slot's, under the next revision, and answers that revision.
    @discardableResult
    func write(_ document: WidgetDocument, slot: String) throws -> Int {
        guard WidgetDocument.isSlot(slot) else { throw CocoaError(.fileWriteInvalidFileName) }
        var kept = document
        kept.revision = try nextRevision(slot: slot)
        try coordinatedWrite(url(slot: slot)) { _ in Data(kept.text.utf8) }
        return kept.revision
    }

    /// The app's own default, written whole. It keeps the revision it was first given in this
    /// login, so a tap on the default drawn a reply ago still lands, and a login's first takes the
    /// next, so a tap from an earlier login's default does not.
    @discardableResult
    func writeDefault(_ document: WidgetDocument) throws -> Int {
        var kept = document
        let current = read(slot: Self.defaultSlot).flatMap { $0.readable ? $0.document.revision : nil }
        kept.revision = try current ?? nextRevision(slot: Self.defaultSlot)
        try coordinatedWrite(url(slot: Self.defaultSlot)) { _ in Data(kept.text.utf8) }
        return kept.revision
    }

    /// A toggle's tap, handled: under one coordinated write, the slot's document, if still at
    /// `revision`, is kept with toggle `control` flipped, at the same revision, since what
    /// changed is its state and not its design. Answers the state it was in, or nil when the
    /// slot is at another revision or holds no such toggle. The state is the stored one, not the
    /// one the tapped entry drew, so two taps before a reload are on and then off.
    func flip(slot: String, control: String, revision: Int) throws -> Bool? {
        var was: Bool?
        try setting(slot: slot, control: control, revision: revision) { was = $0; return !$0 }
        return was
    }

    /// Sets toggle `control` to `on`, whatever it is now: a cue's resolved state, set again as
    /// often as a drain is, or a run's confirmed state after one failed.
    func setOn(_ on: Bool, slot: String, control: String, revision: Int) throws {
        try setting(slot: slot, control: control, revision: revision) { $0 == on ? nil : on }
    }

    /// `change` is handed the toggle's stored state and answers its new one, or nil to leave it.
    private func setting(slot: String, control: String, revision: Int, _ change: (Bool) -> Bool?) throws {
        guard Self.isSlot(slot) else { return }
        try coordinatedWrite(url(slot: slot)) { data in
            guard let data else { return nil }
            var document = WidgetDocument.read(String(decoding: data, as: UTF8.self), from: .store).document
            guard document.revision == revision, let toggle = document.controls[control], toggle.kind == .toggle,
                  let on = change(toggle.on) else { return data }
            document.families = document.families.mapValues { $0.settingOn(on, ofControl: control) }
            return Data(document.text.utf8)
        }
    }

    /// The slots the mind has written, by name: every document but the app's own.
    func slots() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .filter(WidgetDocument.isSlot)
            .sorted()
    }

    /// What `topo widget set` said of the slot's document when it was set: the reader's notes
    /// and the controls judged only at the tap.
    func notes(slot: String) -> [String] {
        guard let data = coordinatedRead(notesURL(slot: slot)) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    func writeNotes(_ notes: [String], slot: String) throws {
        try coordinatedWrite(notesURL(slot: slot)) { _ in notes.isEmpty ? nil : Data(notes.joined(separator: "\n").utf8) }
    }

    func notesURL(slot: String) -> URL { folder.appendingPathComponent("\(slot).notes") }

    /// Takes a slot away, its images and its notes with it.
    func remove(slot: String) throws {
        try coordinatedWrite(url(slot: slot)) { _ in nil }
        try coordinatedWrite(notesURL(slot: slot)) { _ in nil }
        if FileManager.default.fileExists(atPath: images(slot: slot).path) {
            try FileManager.default.removeItem(at: images(slot: slot))
        }
    }

    /// Everything, the default and the pending taps included: what a sign-out leaves.
    /// Removes every slot, image, cue and tap, leaving the counters as their `_floor` alone. A
    /// counter file that cannot be read is left as it is, and writes go on failing closed.
    func removeEverything() throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name != revisionsURL.lastPathComponent {
            var error: NSError?
            var thrown: Error?
            NSFileCoordinator().coordinate(writingItemAt: folder.appendingPathComponent(name), options: .forDeleting, error: &error) { url in
                do { try FileManager.default.removeItem(at: url) } catch { thrown = error }
            }
            if let error { throw error }
            if let thrown { throw thrown }
        }
        guard names.contains(revisionsURL.lastPathComponent) else { return }
        try coordinatedWrite(revisionsURL) { data in
            guard let data, let revisions = try? JSONDecoder().decode([String: Int].self, from: data) else { return data }
            return try JSONEncoder().encode([Self.floor: revisions.values.max() ?? 0])
        }
    }

    // MARK: Revisions

    /// The slot's current revision, which a tap is judged against. Zero is a slot never written.
    func revision(slot: String) -> Int {
        guard let data = coordinatedRead(revisionsURL),
              let revisions = try? JSONDecoder().decode([String: Int].self, from: data) else { return 0 }
        return revisions[slot] ?? 0
    }

    /// The highest revision an earlier login gave, which every slot's next is above.
    static let floor = "_floor"

    /// Whether `revision` was given before the last sign-out, so a tap drawn with it is an earlier
    /// login's and is recorded nowhere.
    func isEarlierLogin(_ revision: Int) -> Bool {
        guard let data = coordinatedRead(revisionsURL),
              let revisions = try? JSONDecoder().decode([String: Int].self, from: data) else { return false }
        return revision <= revisions[Self.floor] ?? 0
    }

    private func nextRevision(slot: String) throws -> Int {
        var next = 0
        try coordinatedWrite(revisionsURL) { data in
            // A counter file that cannot be read is an error, never a fresh start: a counter
            // begun again issues a revision an old timeline already carries.
            var revisions = try data.map { try JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
            next = max(revisions[slot] ?? 0, revisions[Self.floor] ?? 0) + 1
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

    /// A `turn` tap, recorded by the cue intent under a nonce minted there. It names the control
    /// and carries no words: the turn's words are the slot's document's at that revision
    /// (`WidgetDocument.turn`), so nothing that can open a `topo://` URL can put words of its own
    /// in the person's name.
    struct Cue: Codable, Equatable, Sendable {
        var nonce: String
        var slot: String
        var id: String
        var revision: Int
        /// A toggle's new state as the tapped entry drew it; nil for a button or a link.
        var turningOn: Bool?
        var time: Date
        /// A toggle's new state as the app resolved it from the stored one, written before the
        /// toggle is set, so a drain after a crash sets and says the same state.
        var resolved: Bool?
    }

    func appendCue(_ cue: Cue) throws {
        try append(cue, to: pendingURL)
    }

    /// A turn control's tap, kept only when the slot's document is at the cue's revision now: a
    /// tap on a widget still drawn after a sign-out, or on an old timeline, is not kept for a
    /// drain, which could be the next login's. Answers whether it was kept.
    func recordCue(_ cue: Cue) throws -> Bool {
        guard read(slot: cue.slot)?.document.revision == cue.revision else { return false }
        try appendCue(cue)
        return true
    }

    func cues() -> [Cue] { lines(pendingURL) }

    /// Writes `resolved` into the pending cue under `nonce`.
    func resolveCue(nonce: String, _ resolved: Bool) throws {
        try coordinatedWrite(pendingURL) { data in
            Self.encode(Self.decode(Cue.self, data).map { cue in
                var cue = cue
                if cue.nonce == nonce { cue.resolved = resolved }
                return cue
            })
        }
    }

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
        // A stale tap is logged but says nothing of the control's last run, and a tap drawn from
        // an older revision never replaces the outcome of a newer one.
        guard tap.kind == "run", tap.status != "stale" else { return }
        try coordinatedWrite(outcomesURL) { data in
            var outcomes = data.flatMap { try? JSONDecoder().decode([String: [String: Outcome]].self, from: $0) } ?? [:]
            if let last = outcomes[tap.slot]?[tap.id], last.revision > tap.revision { return data }
            outcomes[tap.slot, default: [:]][tap.id] = Outcome(revision: tap.revision, status: tap.status)
            return try JSONEncoder().encode(outcomes)
        }
    }

    /// A control's last run: the revision it was tapped at and what it answered.
    struct Outcome: Codable, Equatable, Sendable {
        var revision: Int
        var status: String
    }

    func taps() -> [Tap] { lines(tapsURL) }

    /// The controls of `slot` whose last tap at `revision` failed: a run that answered anything
    /// but 0.
    /// Read from each control's last outcome, not the taps' log, so a failure stands until that
    /// control runs again or the slot is written anew.
    func failed(slot: String, revision: Int) -> Set<String> {
        guard let data = coordinatedRead(outcomesURL),
              let outcomes = try? JSONDecoder().decode([String: [String: Outcome]].self, from: data) else { return [] }
        return Set((outcomes[slot] ?? [:]).filter { $0.value.revision == revision && !["0", "stale"].contains($0.value.status) }.keys)
    }

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
