@preconcurrency import CloudKit
import Foundation
import TopoCore
import WatchKit
import WidgetKit

/// The watch's copy of the mind's slots: each `Surface` record the phone saved, read into the
/// watch's group through the same `SurfaceStore` and reader the phone's widgets use, so the
/// extension draws from the group and fetches nothing.
///
/// The records are enumerated from the zone's change feed, from the token the last fetch left,
/// and never from a query, whose index updates late and omits records that still exist. A slot
/// leaves the cache only when its removal is confirmed: a deletion in the feed, or a direct fetch
/// that finds no record. A fetch that fails any other way keeps what is cached, since a
/// last-known slot beats a blank face.
@MainActor
final class WatchSurfaceCache {
    static let tokenKey = "topo.surfaces.token"

    let records: SurfaceRecords
    let store: SurfaceStore
    let defaults: UserDefaults
    /// What a change in the cache sets going: the timelines reloaded and, below watchOS 11, the
    /// relevance donated again.
    let changed: @MainActor () -> Void

    init(records: SurfaceRecords, store: SurfaceStore, defaults: UserDefaults = .standard,
         changed: @escaping @MainActor () -> Void = WatchSurfaceCache.reloadWidgets) {
        self.records = records
        self.store = store
        self.defaults = defaults
        self.changed = changed
    }

    /// One read of the feed into the group. Answers false when it could not be read, which keeps
    /// the cache as it was.
    @discardableResult
    func fetch() async -> Bool {
        let token = defaults.data(forKey: Self.tokenKey)
        let changes: SurfaceRecords.Changes
        var whole = token == nil
        do {
            changes = try await records.changes(since: token)
        } catch RecordChangesError.tokenExpired {
            whole = true
            guard let all = try? await records.changes(since: nil) else { return false }
            changes = all
        } catch {
            return false
        }
        var moved = false
        // Something the feed said that did not reach the group: the token stays where it was,
        // so the next read says it again, since a token past it never would.
        var unconfirmed = false
        func kept(_ outcome: Applied) {
            switch outcome {
            case .changed: moved = true
            case .failed: unconfirmed = true
            case .unchanged: break
            }
        }
        func removed(_ slot: String) {
            do {
                try store.remove(slot: slot)
                moved = true
            } catch {
                unconfirmed = true
            }
        }
        for surface in changes.saved { kept(apply(surface)) }
        for slot in changes.deleted where WidgetDocument.isSlot(slot) && store.read(slot: slot) != nil {
            removed(slot)
        }
        if whole {
            // A feed read from the start lists what exists; a cached slot it does not list is
            // asked for by name, and goes only when the answer is that no record is there.
            let listed = Set(changes.saved.map(\.slot) + changes.unreadable)
            for slot in store.slots() where !listed.contains(slot) {
                switch try? await records.fetch(slot: slot) {
                case .gone?:
                    removed(slot)
                case .surface(let surface)?:
                    kept(apply(surface))
                case .unreadable?:
                    break
                case nil:
                    // Not asked and answered: kept, and the feed is read from the start again
                    // next time, since a token saved now would never list this slot again and a
                    // record deleted meanwhile would stay on the face.
                    unconfirmed = true
                }
            }
        }
        if !unconfirmed { defaults.set(changes.token, forKey: Self.tokenKey) }
        if moved { changed() }
        return true
    }

    enum Applied {
        case changed, unchanged, failed
    }

    /// Keeps `surface` as the reader keeps it: the phone's judgement is not trusted, the watch's
    /// reader judges every field again. A document the reader cannot take at all keeps the slot's
    /// cached one. A write to the group that fails is `failed`, which keeps the feed's token back.
    private func apply(_ surface: SurfaceRecord) -> Applied {
        guard WidgetDocument.isSlot(surface.slot) else { return .unchanged }
        let reading = WidgetDocument.read(surface.document, from: .store)
        guard reading.readable else { return .unchanged }
        var document = reading.document
        document.revision = surface.revision
        let cached = store.read(slot: surface.slot)?.document
        let images = surface.images.filter { WidgetDocument.isName($0.key) }
        let sameImages = Set(store.imageNames(slot: surface.slot)) == Set(images.keys)
            && images.allSatisfy { store.imageData(slot: surface.slot, name: $0.key) == $0.value }
        if cached == document, sameImages { return .unchanged }
        do {
            try store.keepImages(images, slot: surface.slot)
            try store.keep(document, slot: surface.slot)
        } catch {
            return .failed
        }
        return .changed
    }

    static func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
        if #available(watchOS 11, *) {
            WidgetCenter.shared.invalidateRelevance(ofKind: SurfaceStore.kind)
        } else {
            Task { await WatchRelevance.donate() }
        }
    }
}

/// When the watch fetches: when the app is open (its 20 s refresh), on the `Surface` push, and on
/// a background refresh it asks for 30 minutes on — and at no other time, since a watch that
/// polls on its own is a battery flattened for a slot that changes a few times a day. Fetches are
/// single-flight: a push landing while one runs asks for one more after it, not a second at once.
@MainActor
final class WatchSurfaceSync {
    static let refreshInterval: TimeInterval = 30 * 60

    static let shared = WatchSurfaceSync(
        fetch: {
            guard let store = SurfaceStore.shared() else { return }
            await WatchSurfaceCache(records: SurfaceRecords(database: TopoCloudKit.database()), store: store).fetch()
        },
        schedule: { date in
            WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: date, userInfo: nil) { _ in }
        })

    private let fetchBody: @MainActor () async -> Void
    private let schedule: @MainActor (Date) -> Void
    private let now: @MainActor () -> Date
    private var running: Task<Void, Never>?
    private var again = false

    init(fetch: @escaping @MainActor () async -> Void, schedule: @escaping @MainActor (Date) -> Void,
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.fetchBody = fetch
        self.schedule = schedule
        self.now = now
    }

    /// The app open, on its refresh.
    func opened() async { await fetch() }

    /// The `Surface` subscription's push.
    func pushed() async { await fetch() }

    /// The background refresh the system granted: one fetch, and the next asked for.
    func refreshed() async {
        await fetch()
        scheduleRefresh()
    }

    func scheduleRefresh() {
        schedule(now().addingTimeInterval(Self.refreshInterval))
    }

    private func fetch() async {
        if let running {
            again = true
            await running.value
            return
        }
        // `running` is let go in the same turn as the loop's last look at `again`, so a fetch asked
        // for after that look starts its own rather than waiting on one that has ended.
        let task = Task { @MainActor in
            repeat {
                again = false
                await fetchBody()
            } while again
            running = nil
        }
        running = task
        await task.value
    }
}

/// The push that says a `Surface` record was saved or deleted. Like `TurnPush` it carries
/// nothing: the watch reads the feed as it does on any fetch, so a push dropped, doubled or
/// forged costs a read and puts nothing on the face. The predicate is `updated` after 1970, which
/// every surface satisfies, on a queryable field rather than the record name's index, which the
/// development schema never builds.
enum SurfacePush {
    static let subscriptionID = "surface-changes"

    static func subscription() -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: SurfaceRecord.type,
            predicate: NSPredicate(format: "updated > %@", Date(timeIntervalSince1970: 0) as NSDate),
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion])
        subscription.zoneID = TopoCloudKit.zoneID
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        return subscription
    }

    /// Registers the subscription unless this Apple ID already has it. A failure is the caller's
    /// to swallow: without the push the watch still fetches when opened and on its refresh.
    static func ensureSubscription() async throws {
        let database = CKContainer(identifier: TopoCloudKit.containerIdentifier).privateCloudDatabase
        do {
            _ = try await database.subscription(for: subscriptionID)
            return
        } catch let error as CKError where error.code == .unknownItem {
            // Not there yet, which is the only error worth continuing past.
        }
        _ = try await database.modifySubscriptions(saving: [subscription()], deleting: [])
    }

    static func isOurs(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return false }
        return notification.subscriptionID == subscriptionID
    }
}

/// The watch's own `_default`, from the log it already reads: Topo, the last reply's time and
/// "Ask Topo", and no word of a reply on any family, since a watch face is read by whoever sees
/// the wrist and the watch has no setting to redact by. Rewritten when the newest reply changes.
@MainActor
final class WatchDefaultSurface {
    let store: @MainActor () -> SurfaceStore?
    let changed: @MainActor () -> Void
    private var written: TurnRef?
    private var wroteEmpty = false

    init(store: @escaping @MainActor () -> SurfaceStore? = { SurfaceStore.shared() },
         changed: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadAllTimelines() }) {
        self.store = store
        self.changed = changed
    }

    /// The log as last read: the default follows its newest reply, once per reply.
    func follow(_ turns: [Turn]) {
        let reply = turns.last(where: { $0.role == .assistant })
        if let reply {
            guard reply.ref != written else { return }
        } else {
            guard written == nil, !wroteEmpty else { return }
        }
        guard let store = store(), (try? store.writeDefault(Self.document(reply))) != nil else { return }
        written = reply?.ref
        wroteEmpty = reply == nil
        changed()
    }

    /// The default for `reply`, built as JSON and read through the reader like any document.
    static func document(_ reply: Turn?) -> WidgetDocument {
        let when: [String: Any]? = reply.map {
            ["kind": "text", "text": "", "date": WidgetReader.dates.string(from: $0.at), "dateStyle": "relative",
             "style": "caption", "colour": "textMuted"]
        }
        let topo: [String: Any] = ["kind": "topo", "pose": "idle"]
        let families: [String: Any] = [
            "accessoryCircular": topo,
            "accessoryCorner": topo,
            "accessoryRectangular": ["kind": "hstack", "spacing": 6, "children": [
                topo,
                ["kind": "vstack", "alignment": "leading", "children": [["kind": "text", "text": "Ask Topo", "style": "headline"]]
                    + [when].compactMap { $0 }],
            ]],
            "accessoryInline": ["kind": "hstack", "children": [
                ["kind": "glyph", "symbol": "bubble.left.fill"],
                when ?? ["kind": "text", "text": "Ask Topo"],
            ]],
        ]
        let object: [String: Any] = ["version": WidgetDocument.version, "families": families, "tap": ["kind": "open"]]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return WidgetDocument() }
        return WidgetDocument.read(String(decoding: data, as: UTF8.self)).document
    }
}

/// The cues a watch `turn` control recorded in the watch's group, sent through the transcript
/// under the nonce `WatchCueIntent` minted with each. The words are the cached document's at the
/// cue's revision; a cue whose revision the cache no longer holds, or whose control is not a
/// turn there, is dropped with no record. A cue goes only once its nonce is on the line or in the
/// log, and `TranscriptStore.send(_:nonce:)` queues nothing for a nonce already there, so a drain
/// run twice, or after a crash, is one turn. It waits for a read of the log, without which the
/// store cannot know what the log holds.
@MainActor
final class WatchCues {
    let transcript: TranscriptStore
    let store: @MainActor () -> SurfaceStore?
    private var running: Task<Void, Never>?
    private var again = false

    init(transcript: TranscriptStore, store: @escaping @MainActor () -> SurfaceStore? = { SurfaceStore.shared() }) {
        self.transcript = transcript
        self.store = store
    }

    /// A `topo://` URL a widget opened: a whole widget's `tap`. `topo://cue?…` is kept as a cue,
    /// under a nonce minted here, only when the cached document is at its revision and holds a
    /// turn by its control, then drained; `topo://open` drains what is there. Any page may open
    /// one, and it carries no words.
    func open(_ url: URL) async {
        if let cue = WidgetURL.cue(from: url), let store = store(),
           let document = store.read(slot: cue.slot)?.document, document.revision == cue.revision,
           document.turn(slot: cue.slot, control: cue.id, turningOn: cue.turningOn) != nil {
            try? store.appendCue(cue)
        }
        await drain()
    }

    func drain() async {
        if let running {
            again = true
            await running.value
            return
        }
        let task = Task { @MainActor in
            repeat {
                again = false
                await pass()
            } while again
            running = nil
        }
        running = task
        await task.value
    }

    private func pass() async {
        guard let store = store(), !store.cues().isEmpty else { return }
        if !transcript.hasRead { await transcript.refresh() }
        guard transcript.hasRead else { return }
        for cue in store.cues() {
            guard let document = store.read(slot: cue.slot)?.document, document.revision == cue.revision,
                  let words = document.turn(slot: cue.slot, control: cue.id, turningOn: cue.turningOn) else {
                try? store.removeCue(nonce: cue.nonce)
                continue
            }
            if await transcript.send(words, nonce: cue.nonce) {
                try? store.removeCue(nonce: cue.nonce)
            }
        }
    }
}
