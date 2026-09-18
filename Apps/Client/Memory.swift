#if os(iOS)
import Foundation
import Observation
import TopoAuth
import TopoCore

/// The memory as the phone keeps it: a folder of markdown mirrored both ways against the store,
/// so the person reads and writes the memory as plain files and a sync is what carries their work
/// to the other devices and brings back what those devices did.
///
/// The folder has two homes. `<Documents>/Vault` is the one every phone has from the first launch:
/// Files shows it under On My iPhone › Topo and any editor that opens documents in place reads and
/// writes it. The other is a folder in iCloud Drive the person picked, which Obsidian opens on the
/// phone and iCloud Drive carries to their Macs. Which one it is, is `home`; everything else here
/// is the same either way, and the mirror, the revisions and the store do not know the difference.
///
/// One mirror for the app and one sync at a time: a request arriving during a pass is served by
/// one more pass after it rather than by a second mirror, since two syncs over one folder would
/// each read what the other was halfway through writing. Every cue is the same call — the
/// foreground, each pass of the answering loop, a reply landing, a silent push saying a revision
/// was written — so how often the folder is current is a question about the cues and not about
/// this.
///
/// Sign-out takes the folder away. The memory is the person's and lives in their iCloud; a phone
/// that is signed out keeps no copy of it. A sync still in flight at that moment is cancelled: it
/// stops at the last thing it did and writes nothing after it, and the folder goes once it has
/// stopped, so a pass cannot put a file back after the folder was taken away. Nor can a later cue: the mirror runs only while this
/// device holds a login, the same condition the harness answers under, and a cue arriving without
/// one — a foreground, a launch as a viewer — takes away any folder it finds instead of filling
/// one, so an interrupted sign-out settles at the next cue rather than standing.
@MainActor
@Observable
final class Memory {
    /// The folder in the app's own container. Fixed, because Files, the person and any editor
    /// they use all know it by where it is. It is the home until the person picks another, and
    /// the one a move comes back to.
    let localDirectory: URL

    /// Where the vault folder is, as this launch resolves it.
    enum Home: Equatable {
        /// `<Documents>/Vault`, in the app's own container.
        case local
        /// A folder in iCloud Drive: `picked` is the URL the person granted, which every access
        /// is started and stopped on, and `folder` is the vault under it — the same URL for a
        /// vault folder, and `Obsidian/<the mind's name>` beneath it for a pick of iCloud Drive
        /// itself.
        case iCloudDrive(picked: URL, folder: URL)
        /// A bookmark is kept and does not resolve, or resolves somewhere that is no longer a
        /// folder Obsidian opens: the folder gone, iCloud Drive turned off, the grant no longer
        /// honoured. No pass runs until the person picks again or comes back to this phone.
        case lost(String)

        /// The folder the mirror runs against, or nil when there is none to run against.
        var folder: URL? {
            switch self {
            case .local: nil
            case .iCloudDrive(_, let folder): folder
            case .lost: nil
            }
        }

        /// The URL the grant is on, which is never a child of it.
        var scope: URL? {
            if case .iCloudDrive(let picked, _) = self { return picked }
            return nil
        }
    }

    /// Where the vault folder is. Read from the bookmark, which is the home: no bookmark is this
    /// phone's own folder, one that resolves is iCloud Drive, one that does not is `lost`.
    private(set) var home: Home = .local

    /// What the last move did, and what it left behind. A source that would not empty after the
    /// commit is reported here and never rolled back, since the home has moved.
    private(set) var stranded: Stranded?
    /// A move in flight, and the last one to fail. The settings screen reads both.
    private(set) var moving = false
    private(set) var moveError: String?
    /// What the last warm-up of an iCloud Drive folder asked for and got.
    private(set) var lastDownloads: VaultDownloads.Report?

    struct Stranded: Equatable {
        /// The folder the move carried the vault out of.
        var folder: URL
        /// What is still in it.
        var names: [String]
        /// Whether that folder is the app's own, which is what the line says.
        var isLocal: Bool
    }

    /// What the last sync did, for the diagnostics screen.
    private(set) var lastReport: VaultMirror.Report?
    /// When a sync last finished without an error.
    private(set) var lastSync: Date?
    /// The last sync to fail, and what it said. A failure is left here and retried on the next
    /// cue; the mirror refuses to act on a partial read, so nothing was half-applied.
    private(set) var lastError: Failure?
    /// How many passes have run, and how many callers have asked for one. A test reads both to
    /// see that requests coalesce: three asks over one pass leave `requests` at three and
    /// `passes` at two.
    private(set) var passes = 0
    private(set) var requests = 0

    struct Failure: Equatable {
        var at: Date
        var message: String
    }

    private let store: MemoryStore
    private let device: DeviceID
    private let isSignedIn: @Sendable () -> Bool
    private let bookmarks: any VaultBookmarkStore
    private let ubiquityRoot: URL?
    private let isUbiquitous: @Sendable (URL) -> Bool
    private let warm: @Sendable (URL) async -> VaultDownloads.Report
    private let ensureZone: @Sendable () async throws -> Void
    private let now: @Sendable () -> Date
    private var mirror: VaultMirror?
    /// The folder the mirror and the presenter were made for. A home that has moved is a mirror
    /// and a presenter made again, since both are about one folder.
    private var mirrorFolder: URL?
    private var presenter: VaultPresenter?
    /// Set while a move is running: every cue answers with no pass, because the folder the pass
    /// would run against is the one being carried.
    private var paused = false
    private var zoneReady = false
    private var running: Task<Void, Never>?
    /// A pass a sign-out cancelled, still winding down. Nothing new touches the folder until
    /// it has stopped: a sign-in landing in that moment would otherwise have its first sync
    /// running beside the old one, over the same folder.
    private var stopping: Task<Void, Never>?
    private var queued = false
    /// Advanced by a sign-out and by every pass that begins, so anything left over from before
    /// — a report whose database call has only now returned, a sign-out's folder cleanup that
    /// waited for it — can tell that it is no longer the newest thing to have happened. The
    /// mirror's own cancellation is what stops a stale pass writing to disk; this is what stops
    /// it writing to the screen, and stops one login's cleanup taking away the next one's
    /// folder.
    private var generation = 0

    init(directory: URL, store: MemoryStore, device: DeviceID = DeviceIdentity.current,
         isSignedIn: @escaping @Sendable () -> Bool,
         bookmarks: any VaultBookmarkStore = KeychainBookmarkStore(),
         ubiquityRoot: URL? = VaultHome.ubiquityRoot(),
         isUbiquitous: @escaping @Sendable (URL) -> Bool = VaultHome.isUbiquitous,
         warm: @escaping @Sendable (URL) async -> VaultDownloads.Report = { await VaultDownloads.warm($0) },
         ensureZone: @escaping @Sendable () async throws -> Void = { try await TopoCloudKit.ensureZone() },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.localDirectory = directory
        self.store = store
        self.device = device
        self.isSignedIn = isSignedIn
        self.bookmarks = bookmarks
        self.ubiquityRoot = ubiquityRoot
        self.isUbiquitous = isUbiquitous
        self.warm = warm
        self.ensureZone = ensureZone
        self.now = now
        home = readHome()
    }

    /// The app's memory: the folder Files shows or the one the person picked, over the same
    /// CloudKit database the harness uses and under the same device identity.
    static func standard(tokens: TokenStore = KeychainTokenStore()) -> Memory {
        Memory(directory: Memory.standardDirectory, store: MemoryStore(database: TopoCloudKit.database()),
               isSignedIn: { (try? tokens.load()) != nil })
    }

    static var standardDirectory: URL {
        let documents = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true))
            ?? URL.documentsDirectory
        return documents.appending(path: "Vault", directoryHint: .isDirectory)
    }

    /// Brings the folder and the store into step, and returns once a pass that began no earlier
    /// than this call has finished. One at a time: a call arriving during a pass asks for one
    /// more after it, and however many arrive they ask for the same one.
    func sync() async {
        let asked = generation
        // A move has the folder open under a coordinated write of its own, and the home is about
        // to be somewhere else, so there is nothing here for a pass to run against.
        guard !paused else { return }
        guard isSignedIn() else {
            // A cue can reach a phone with no login — the foreground after a sign-out, a
            // launch as a viewer — and nothing of the memory belongs on one. A folder a
            // sign-out did not get to the end of goes here instead of filling up.
            await removeFolder()
            return
        }
        requests += 1
        // Whatever a sign-out cancelled is still stopping; wait it out rather than start a
        // second sync over one folder.
        while let winding = stopping {
            await winding.value
            if stopping == winding { stopping = nil }
        }
        // That wait is as long as the pass it waits for, and a sign-out can happen twice in
        // it: the login checked at the door is not the login this pass would run under, and
        // a sign-out that found no pass to cancel left its cleanup to whatever woke next.
        // So the door is checked again here, after every wait and before anything is made.
        guard isSignedIn() else {
            await removeFolder()
            return
        }
        guard !paused else { return }
        guard generation == asked else {
            // Something moved under this request while it waited. A sign-out's own cleanup
            // owns the folder now; a pass another cue began answers this request too, and is
            // asked for one more after it — and waited for, since this call answers only when
            // a pass no earlier than it has finished.
            if let running {
                queued = true
                await running.value
            }
            return
        }
        if let running {
            queued = true
            await running.value
            return
        }
        let task = Task { @MainActor in await self.drain() }
        running = task
        await task.value
    }

    private func drain() async {
        repeat {
            queued = false
            await onePass()
        } while queued
        running = nil
    }

    private func onePass() async {
        passes += 1
        // A pass beginning is this device holding a login and using it, which changes hands
        // as much as a sign-out does: a cleanup left over from before this pass takes nothing
        // away, and a report from before it reaches nothing.
        generation += 1
        let mine = generation
        // Read afresh every pass: the home moves, and a bookmark that resolved at launch is one
        // iCloud Drive can have stopped honouring since.
        home = readHome()
        if case .lost(let why) = home {
            // Nothing runs against a folder that cannot be reached. Not an empty one either: a
            // pass against the local folder here would fill this phone with a memory the person
            // asked to keep somewhere else.
            lastError = Failure(at: now(), message: "the memory's folder cannot be reached: \(why)")
            return
        }
        let folder = home.folder ?? localDirectory
        // The grant is on the folder the person picked, never on a child of it, and it is held
        // for the whole pass: the mirror opens, reads and writes files inside it throughout.
        // A false answer is not read as a refusal — it is also what a URL that needs no scope
        // says — so what a grant that has really gone costs is the read failing below, which is
        // where it is reported.
        let scoped = home.scope?.startAccessingSecurityScopedResource() == true
        defer { if scoped, let scope = home.scope { scope.stopAccessingSecurityScopedResource() } }
        do {
            if !zoneReady {
                try await ensureZone()
                zoneReady = true
            }
            if home.scope != nil {
                // What iCloud Drive has taken off this device is asked for before the scan reads
                // it; what has not arrived by the bound is left for the next pass, which is a file
                // the mirror reports as unreadable and acts on in neither direction.
                let downloads = await warm(folder)
                guard mine == generation else { return }
                lastDownloads = downloads.isEmpty ? nil : downloads
            } else {
                lastDownloads = nil
            }
            let report = try await vault(at: folder).sync()
            guard mine == generation else { return }
            lastReport = report
            lastSync = now()
            lastError = nil
        } catch is CancellationError {
            // Sign-out, or the screen going. The pass stopped at the last thing it did and
            // did nothing after it, and nobody is waiting on what it was going to do, so
            // there is nothing here to tell anyone.
        } catch {
            guard mine == generation else { return }
            lastError = Failure(at: now(), message: Self.describe(error))
        }
    }

    /// The mirror for a folder, made the first time that folder is the home, and the presenter
    /// held for as long as it is. An open-in-place folder asks its owner to stand as a presenter
    /// of it, which is how another app's coordinated write is announced to this process rather
    /// than landing underneath it.
    ///
    /// A home that has moved is a different folder, so both are made again: a mirror carries the
    /// baseline of the folder it was made for, and a presenter names one path.
    private func vault(at folder: URL) -> VaultMirror {
        if let mirror, mirrorFolder == folder { return mirror }
        dropPresenter()
        let presenter = VaultPresenter(url: folder)
        NSFileCoordinator.addFilePresenter(presenter)
        self.presenter = presenter
        let mirror = VaultMirror(directory: folder, store: store, device: device)
        self.mirror = mirror
        mirrorFolder = folder
        return mirror
    }

    private func dropPresenter() {
        if let presenter {
            NSFileCoordinator.removeFilePresenter(presenter)
            self.presenter = nil
        }
    }

    /// Sign-out. The mirror stops, the folder goes, and what the screen was showing about the
    /// memory goes with it.
    func forget() {
        generation += 1
        let generation = self.generation
        let running = self.running
        running?.cancel()
        self.running = nil
        // A sign-out with no pass of its own to stop still has one to wait out when an
        // earlier sign-out's is still stopping: taking that away would leave every request
        // parked behind it free to run as this sign-out's cleanup makes the folder go.
        let winding = running ?? stopping
        queued = false
        mirror = nil
        mirrorFolder = nil
        zoneReady = false
        lastReport = nil
        lastSync = nil
        lastError = nil
        lastDownloads = nil
        stranded = nil
        moveError = nil
        dropPresenter()
        // After the pass in flight has stopped, never during it: a folder taken away mid-write
        // is one a half-finished pass puts back. And only while this is still the newest thing
        // that happened — a later sign-out has a cleanup of its own, and a pass begun under a
        // new login owns the folder now, so taking it away here would be one login deleting
        // the next one's memory.
        //
        // The cleanup is what everything else waits for, not the pass it waits for itself:
        // taking the folder away is a coordinated write with a wait of its own, and a request
        // let through in the middle of it would make the folder this is still deleting.
        stopping = Task { @MainActor [weak self] in
            _ = await winding?.value
            guard let self, self.generation == generation else { return }
            await self.removeFolder()
        }
    }

    private func removeFolder() async {
        // The capability goes with the login: a signed-out phone keeps no handle on the person's
        // files. What it does not do is take away a folder in their own iCloud Drive — that is
        // their memory, in their iCloud, where a Mac of theirs opens it, and deleting it would be
        // this app throwing away the thing it was asked to keep. What goes is the copy in this
        // app's own container.
        try? bookmarks.clear()
        home = .local
        do {
            try await VaultMirror.removeFolder(at: localDirectory)
            lastError = nil
        } catch {
            // A folder that would not go is a phone that signed out and still holds the
            // person's memory. Nothing is shown for it there and then — a signed-out phone
            // shows the sign-in screen, which has no diagnostics — so it is recorded here: the
            // next cue that finds no login tries the removal again, and until one succeeds the
            // failure is what the diagnostics memory row says on the next sign-in.
            lastError = Failure(at: now(), message: Self.describe(error))
        }
    }

    // MARK: Where the vault lives

    /// The home as the kept bookmark resolves it, now. No bookmark is this phone's own folder; a
    /// bookmark that will not resolve, or resolves somewhere Obsidian does not open a vault, is
    /// `lost` and stops every pass.
    ///
    /// The folder under a pick is derived rather than kept, by the rule that judged the pick: the
    /// bookmark is to what the person granted, and a grant of iCloud Drive itself is a vault at
    /// `Obsidian/<the mind's name>` under it.
    private func readHome() -> Home {
        let kept: Data?
        do {
            kept = try bookmarks.load()
        } catch {
            return .lost("the keychain refused the bookmark: \(error)")
        }
        guard let kept else { return .local }
        let resolved: VaultHome.Resolved
        do {
            resolved = try VaultHome.resolve(kept)
        } catch {
            return .lost("\(error)")
        }
        let started = resolved.url.startAccessingSecurityScopedResource()
        defer { if started { resolved.url.stopAccessingSecurityScopedResource() } }
        if resolved.stale {
            // A stale bookmark still resolves; what it asks for is to be made again from the URL
            // it resolved to, which keeps the grant across whatever moved the folder. A remake
            // that fails costs nothing this pass — the resolved URL is good — and is tried again
            // on the next one.
            if let fresh = try? VaultHome.remake(resolved.url) { try? bookmarks.save(fresh) }
        }
        switch VaultHome.judge(resolved.url, ubiquityRoot: ubiquityRoot, isUbiquitous: isUbiquitous) {
        case .success(let pick):
            return .iCloudDrive(picked: resolved.url,
                                folder: VaultHome.folder(for: pick, picked: resolved.url))
        case .failure(let refusal):
            return .lost(refusal.reason)
        }
    }

    /// How the settings row and the diagnostics row name the home.
    var homeSummary: String {
        switch home {
        case .local: "On this iPhone"
        case .iCloudDrive(_, let folder): VaultHome.describe(folder, ubiquityRoot: ubiquityRoot)
        case .lost(let why): "lost: \(why)"
        }
    }

    /// Whether the offer card stands: a vault with more than a handful in it, still on this phone.
    /// The card is shown once and Not now is for good, which is the caller's to remember.
    static let offerThreshold = 5

    func offersICloudDrive(answered: Bool) -> Bool {
        guard !answered, case .local = home else { return false }
        return (lastReport?.files ?? 0) > Self.offerThreshold
    }

    /// Moves the memory into a folder the person picked. Answers the reason it did not, or nil.
    ///
    /// The judgement comes first and changes nothing: the picker offers local storage and every
    /// installed provider beside iCloud Drive, and a folder that is not one Obsidian opens is
    /// refused with the home where it was.
    @discardableResult
    func keepInICloudDrive(_ picked: URL) async -> String? {
        let started = picked.startAccessingSecurityScopedResource()
        defer { if started { picked.stopAccessingSecurityScopedResource() } }
        let pick: VaultHome.Pick
        switch VaultHome.judge(picked, ubiquityRoot: ubiquityRoot, isUbiquitous: isUbiquitous) {
        case .success(let accepted): pick = accepted
        case .failure(let refusal):
            moveError = refusal.reason
            return refusal.reason
        }
        let bookmark: Data
        do {
            bookmark = try VaultHome.bookmark(for: picked)
        } catch {
            moveError = "the folder could not be kept: \(error)"
            return moveError
        }
        let destination = VaultHome.folder(for: pick, picked: picked)
        return await move(from: localDirectory, to: destination, wasLocal: true,
                          removingSourceFolder: true) { [bookmarks] in
            try bookmarks.save(bookmark)
        }
    }

    /// Brings the memory back into the app's own container: the same operation with the folders
    /// swapped, and the baseline coming back with the files.
    @discardableResult
    func keepOnThisPhone() async -> String? {
        guard case .iCloudDrive(let picked, let folder) = home else { return nil }
        let started = picked.startAccessingSecurityScopedResource()
        defer { if started { picked.stopAccessingSecurityScopedResource() } }
        // The folder the person picked is theirs and stays; what goes out of it is what the
        // memory put there.
        return await move(from: folder, to: localDirectory, wasLocal: false,
                          removingSourceFolder: false) { [bookmarks] in
            try bookmarks.clear()
        }
    }

    /// The move, either way. The mirror is stopped and every cue answers with no pass until it is
    /// over, the folders are carried under one coordinated write, and the commit is `commit` —
    /// the one write that says where the vault is.
    private func move(from source: URL, to destination: URL, wasLocal: Bool,
                      removingSourceFolder: Bool,
                      commit: @escaping @Sendable () throws -> Void) async -> String? {
        guard !moving else { return "a move is already running" }
        moving = true
        paused = true
        moveError = nil
        defer {
            moving = false
            paused = false
        }
        // The pass in flight is waited out rather than cancelled: it is halfway through writing
        // the folder this move is about to carry, and a cancelled one leaves the baseline saying
        // less than the folder holds.
        queued = false
        await running?.value
        await stopping?.value
        // The presenter names the folder it was made for, and this process is about to hold a
        // coordinated write over that folder from a queue of the migration's own.
        dropPresenter()
        mirror = nil
        mirrorFolder = nil
        do {
            let outcome = try await VaultMigration.move(from: source, to: destination,
                                                        device: device, at: now(),
                                                        removingSourceFolder: removingSourceFolder,
                                                        commit: commit)
            home = readHome()
            stranded = outcome.left.isEmpty ? nil
                : Stranded(folder: source, names: outcome.left, isLocal: wasLocal)
            // The folder has moved, so what the last pass said about the old one is not about
            // this one; the sync below is what fills these in again.
            lastReport = nil
            lastSync = nil
            lastError = nil
            lastDownloads = nil
        } catch {
            // Before the commit, so the home is where it was and the source is untouched; the
            // destination holds whatever partial copy was made, which the next attempt writes
            // over file by file.
            home = readHome()
            moveError = Self.describeMove(error)
            return moveError
        }
        // Against the new folder, from the baseline that came with it.
        await sync()
        return nil
    }

    /// Tries again to empty the folder a move left something in. Never a rollback: the home has
    /// moved, and this is only the old copy going.
    func removeStranded() async {
        guard let stranded else { return }
        let scope = home.scope
        var started = false
        if !stranded.isLocal, let scope { started = scope.startAccessingSecurityScopedResource() }
        defer { if started, let scope { scope.stopAccessingSecurityScopedResource() } }
        do {
            try await VaultMirror.removeFolder(at: stranded.folder)
            self.stranded = nil
        } catch {
            self.stranded = Stranded(folder: stranded.folder,
                                     names: stranded.names, isLocal: stranded.isLocal)
            moveError = Self.describe(error)
        }
    }

    private static func describeMove(_ error: any Error) -> String {
        switch error {
        case VaultTransfer.Failure.unreadable(let path):
            "\(path) could not be read, so the memory stayed where it was"
        case VaultTransfer.Failure.unwritable(let path):
            "\(path) could not be written into the new folder, so the memory stayed where it was"
        case VaultTransfer.Failure.unverified(let path):
            "\(path) did not arrive whole, so the memory stayed where it was"
        default:
            "the move stopped and the memory stayed where it was: \(error)"
        }
    }

    /// What the diagnostics screen shows on the `memory` row.
    var summary: String {
        var parts: [String] = [homeSummary]
        if let lastSync {
            parts.append("synced \(Self.clock(lastSync))")
        } else {
            parts.append(lastError == nil ? "not synced yet" : "never synced")
        }
        if let report = lastReport {
            parts.append("written \(report.written.count), removed \(report.removed.count), "
                + "pushed \(report.pushed.count), deleted \(report.deleted.count), "
                + "skipped \(report.skipped.count)")
        }
        if let downloads = lastDownloads?.summary {
            parts.append(downloads)
        }
        if let stranded {
            parts.append("the old copy is still \(stranded.isLocal ? "on this iPhone" : "in iCloud Drive")"
                + " (\(stranded.names.count))")
        }
        if let moveError {
            parts.append("move: \(moveError)")
        }
        if let lastError {
            parts.append("failed \(Self.clock(lastError.at)): \(lastError.message)")
        }
        return parts.joined(separator: "; ")
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case MemoryError.incompleteVault(let missing, let unreadable):
            let parts = missing.map(\.description).sorted() + unreadable.map(\.name).sorted()
            return "the store is missing revisions (\(parts.joined(separator: ", "))); it syncs again next pass"
        default:
            return "\(error)"
        }
    }
}

/// The app's standing interest in the vault folder, which is what an open-in-place document
/// folder asks of the app that owns it: while this is registered, a coordinated read or write by
/// another app is arbitrated against this process rather than racing it.
///
/// It answers no callbacks. Nothing here watches the folder — a watch on the root would miss a
/// save inside a subfolder anyway, and the foreground and the answering loop are what say when
/// to look.
final class VaultPresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue

    init(url: URL) {
        presentedItemURL = url
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue = queue
    }
}

/// Who a silent push about a revision wakes.
///
/// `PushWake`'s shape, with a different owner. A turn is answered by the screen that is
/// answering, so that handler stands exactly as long as the answering loop does; the memory is
/// mirrored by any phone that holds a login, whatever screen it happens to be showing — a first
/// run, a sign-in that has not been answered yet — so this one follows the login instead.
/// `TopoApp` is where it is put up and taken down, and at a sign-out it is gone, so a push
/// arriving after reaches nothing.
@MainActor
enum MemoryWake {
    static var handler: (@MainActor () async -> Void)?

    static func install(_ handler: @escaping @MainActor () async -> Void) {
        self.handler = handler
    }

    static func remove() {
        handler = nil
    }

    /// Installed exactly while this device holds a login.
    static func follow(signedIn: Bool, memory: Memory) {
        if signedIn {
            install { [memory] in await memory.sync() }
        } else {
            remove()
        }
    }
}
#endif
