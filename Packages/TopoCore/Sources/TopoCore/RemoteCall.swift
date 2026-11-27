import Foundation

/// One `topo` call a mind on one device asks another device to run (`topo --device iphone …` on
/// a hub): the call and its answer in one record, the target's mailbox, `tool-call/<target>`.
///
/// One slot a device, so calls to it run one at a time and nothing has to be queried: both ends
/// fetch the record by its name. Every write is a compare-and-set on the read it follows, so a
/// call is claimed once, by the device it names, and an asker that gave up cancels only a call
/// nobody claimed. A call not claimed by `expiresAt` is never run: "a timer for five minutes"
/// started an hour later is wrong.
public struct RemoteCall: Sendable, Equatable {
    public static let recordType = "ToolCall"
    public static func recordID(for target: DeviceID) -> RecordID { RecordID("tool-call/\(target.rawValue)") }
    /// The longest answer kept, in characters: a record is not a file.
    public static let textLimit = 16_000

    public enum State: String, Sendable {
        /// Written by the asker, waiting for its target.
        case asked
        /// The target has it and is running it.
        case claimed
        /// Run; `status` and `text` are the tool's.
        case done
        /// The asker gave up before the target claimed it.
        case cancelled
    }

    /// This call's own name, so an answer is told from the answer to the call before it.
    public var id: String
    public var target: DeviceID
    public var caller: DeviceID
    public var argv: [String]
    public var state: State
    public var status: Int64?
    public var text: String?
    public var askedAt: Date
    public var expiresAt: Date
    /// How the target came to run it (what woke it, whether it was in front, how long after the
    /// ask), in its own words: the only sight the asker has of the other device.
    public var evidence: String?
    var changeTag: String?

    public init(id: String = UUID().uuidString.lowercased(), target: DeviceID, caller: DeviceID, argv: [String],
                askedAt: Date = Date(), expiresAt: Date) {
        self.id = id
        self.target = target
        self.caller = caller
        self.argv = argv
        self.state = .asked
        self.askedAt = askedAt
        self.expiresAt = expiresAt
    }

    public init?(record: Record) {
        guard record.type == Self.recordType,
              let id = record.string("call"), let target = record.string("target").map({ DeviceID($0) }),
              record.id == Self.recordID(for: target),
              let caller = record.string("caller"), let argv = record.strings("argv"),
              let state = record.string("state").flatMap(State.init(rawValue:)),
              let askedAt = record.date("askedAt"), let expiresAt = record.date("expiresAt") else { return nil }
        self.id = id
        self.target = target
        self.caller = DeviceID(caller)
        self.argv = argv
        self.state = state
        self.status = record.int("status")
        self.text = record.string("text")
        self.askedAt = askedAt
        self.expiresAt = expiresAt
        self.evidence = record.string("evidence")
        self.changeTag = record.changeTag
    }

    var record: Record {
        var fields: [String: FieldValue] = [
            "call": .string(id), "target": .string(target.rawValue), "caller": .string(caller.rawValue),
            "argv": .strings(argv), "state": .string(state.rawValue),
            "askedAt": .date(askedAt), "expiresAt": .date(expiresAt),
            // What the push's subscription asks about (`sequence > 0`, as the turn's does).
            "sequence": .int(1),
        ]
        if let status { fields["status"] = .int(status) }
        if let text { fields["text"] = .string(String(text.prefix(Self.textLimit))) }
        if let evidence { fields["evidence"] = .string(evidence) }
        return Record(type: Self.recordType, id: Self.recordID(for: target), fields: fields, changeTag: changeTag)
    }

    /// Whether the slot is still this call's to wait in: asked or claimed, and not past its time.
    func stands(at now: Date) -> Bool {
        switch state {
        case .asked: now < expiresAt
        case .claimed: now < expiresAt.addingTimeInterval(RemoteCalls.runBound)
        case .done, .cancelled: false
        }
    }
}

/// Both ends of a `RemoteCall`.
public enum RemoteCalls {
    /// How long a claimed call is given to answer before its slot is another call's.
    public static let runBound: TimeInterval = 120

    public enum Failure: Error, Equatable, Sendable {
        /// The target's slot holds a call still waiting or running.
        case busy
        /// Nothing claimed the call within its time; it was cancelled and will not run.
        case unclaimed
        /// The target claimed it and did not answer within `runBound`; it may yet have run.
        case unanswered
    }

    /// Asks `target` to run `argv`, and waits for its answer. `wake` is called once, when the call
    /// has stood unclaimed for `wakeAfter` seconds (the record's own push is the first word the
    /// target has of it; this is the louder second). The slot is read every `interval`.
    public static func call(_ argv: [String], on target: DeviceID, from caller: DeviceID, in database: any RecordDatabase,
                            claimWithin: TimeInterval = 45, interval: TimeInterval = 0.5,
                            now: @Sendable () -> Date = { Date() }, wakeAfter: TimeInterval = 0,
                            wake: @Sendable (RemoteCall) async -> Void = { _ in }) async throws -> RemoteCall {
        let slot = RemoteCall.recordID(for: target)
        let current = try await database.fetch(slot)
        if let standing = current.flatMap(RemoteCall.init(record:)), standing.stands(at: now()) { throw Failure.busy }
        var call = RemoteCall(target: target, caller: caller, argv: argv, askedAt: now(),
                              expiresAt: now().addingTimeInterval(claimWithin))
        call.changeTag = current?.changeTag
        do {
            call.changeTag = try await database.save(call.record).changeTag
        } catch RecordDatabaseError.serverRecordChanged {
            throw Failure.busy
        }
        var woken = false
        while true {
            if !woken, now() >= call.askedAt.addingTimeInterval(wakeAfter) {
                woken = true
                await wake(call)
            }
            try await Task.sleep(for: .seconds(interval))
            guard let record = try? await database.fetch(slot), let seen = RemoteCall(record: record), seen.id == call.id else {
                // A read that failed, or the slot moved on: only the time says when to stop.
                if now() > call.expiresAt.addingTimeInterval(runBound) { throw Failure.unanswered }
                continue
            }
            switch seen.state {
            case .done: return seen
            case .cancelled: throw Failure.unclaimed
            case .claimed:
                if now() > call.expiresAt.addingTimeInterval(runBound) { throw Failure.unanswered }
            case .asked:
                guard now() > call.expiresAt else { continue }
                var cancelled = seen
                cancelled.state = .cancelled
                // Lost to the target's claim: it is running, so wait for it.
                if (try? await database.save(cancelled.record)) != nil { throw Failure.unclaimed }
            }
        }
    }

    /// What the target does when something says its slot may hold a call: claims a call that is
    /// asked, its own and in time, runs it, and writes the answer. Returns the call it ran, or
    /// nil with nothing to run. `evidence` is asked for after the run.
    @discardableResult
    public static func serve(_ device: DeviceID, in database: any RecordDatabase, now: @Sendable () -> Date = { Date() },
                             evidence: @Sendable (RemoteCall) async -> String? = { _ in nil },
                             run: @Sendable ([String]) async -> (status: Int64, text: String)) async -> RemoteCall? {
        guard let record = try? await database.fetch(RemoteCall.recordID(for: device)),
              var call = RemoteCall(record: record), call.target == device, call.state == .asked,
              now() < call.expiresAt else { return nil }
        call.state = .claimed
        // The claim is the compare-and-set: a second wake for the same call loses here.
        guard let claimed = try? await database.save(call.record) else { return nil }
        call.changeTag = claimed.changeTag
        let answer = await run(call.argv)
        call.state = .done
        call.status = answer.status
        call.text = answer.text
        call.evidence = await evidence(call)
        for _ in 0..<3 {
            if let saved = try? await database.save(call.record) {
                call.changeTag = saved.changeTag
                return call
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return call
    }
}

/// Words a hub's mind has for the person, shown by the system on every device of the Apple ID
/// that subscribes (`AlertPush` in the app): one record a hub, `alert/<hub>`, written over each
/// time. The push's alert is the record's `title` and `body`; no device runs anything to show it.
public struct RemoteAlert: Sendable, Equatable {
    public static let recordType = "Alert"
    public static func recordID(for hub: DeviceID) -> RecordID { RecordID("alert/\(hub.rawValue)") }
    public static let titleLimit = 120
    public static let bodyLimit = 1_000

    public var hub: DeviceID
    public var title: String
    public var body: String

    public init(hub: DeviceID, title: String, body: String) {
        self.hub = hub
        self.title = String(title.prefix(Self.titleLimit))
        self.body = String(body.prefix(Self.bodyLimit))
    }

    /// Writes the alert over the hub's record, whatever it held: the hub is its only writer.
    public func save(to database: any RecordDatabase, at: Date = Date()) async throws {
        for _ in 0..<3 {
            let current = try await database.fetch(Self.recordID(for: hub))
            let record = Record(type: Self.recordType, id: Self.recordID(for: hub), fields: [
                "hub": .string(hub.rawValue), "title": .string(title), "body": .string(body),
                "at": .date(at), "sequence": .int(1),
            ], changeTag: current?.changeTag)
            do {
                _ = try await database.save(record)
                return
            } catch RecordDatabaseError.serverRecordChanged {
                continue
            }
        }
        throw RecordDatabaseError.unavailable(underlying: CancellationError())
    }
}
