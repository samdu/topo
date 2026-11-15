import Foundation
import TopoTools

/// One perf mark read back off the log: its wall-clock time in milliseconds, its name and what
/// followed the name (`docs/perf.md`).
struct PerfMark: Equatable, Sendable {
    var ms: Int64
    var name: String
    var detail: String

    /// The mark a `perf` line's message holds, `mark t=<ms> <name> [detail]`, or nil.
    init?(message: String) {
        let words = message.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard words.count >= 3, words[0] == "mark", words[1].hasPrefix("t="),
              let ms = Int64(words[1].dropFirst(2)) else { return nil }
        self.ms = ms
        name = String(words[2])
        detail = words.count > 3 ? String(words[3]) : ""
    }

    init(ms: Int64, name: String, detail: String = "") {
        self.ms = ms
        self.name = name
        self.detail = detail
    }

    /// The value of `key=` among the detail's words.
    func value(_ key: String) -> String? {
        detail.split(separator: " ").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    /// The turn a tagged mark names (`Harness.turnMark`).
    var turn: String? { value("turn") }

    /// Whether the mark is one of the model's own requests' (`proxy.* POST /v1/messages …`).
    var isMessages: Bool { detail.hasPrefix(TurnTimeline.messages + " ") }
}

/// Where one turn's time went, from the person's release or send to the reply on the screen: the
/// things that happened, in the order they happened, each with the time since the one before, so
/// the times add up to the turn's. A turn's start and end are the marks tagged with it; what
/// happened in between is read from the marks of that time, and where another turn's time overlaps
/// it, that stretch cannot be told apart and is said as one. Built from the marks' names, their
/// times and the counts they carry alone, so nothing a turn said is in it.
struct TurnTimeline: Sendable {
    /// What kind of moment an event is: the key it is kept under, which the record sums by.
    enum Key: String, CaseIterable, Sendable {
        case hear, queue, save, ready, start, prepare, tool, upload, model, stream, screen, finish, store, show, end, wait, mixed
    }

    struct Event: Equatable, Sendable {
        var key: Key
        var title: String
        /// Milliseconds from the turn's start to the event.
        var at: Int64
        /// Milliseconds from the event before it, or from the start.
        var took: Int64
    }

    enum Kind: String, Sendable {
        case spoken, typed
    }

    static let soundKey = "sound"
    static let soundTitle = "The voice's first sound"
    /// The model's own requests, by the route the proxy names them by.
    static let messages = "POST /v1/messages"

    /// When the turn began, on the wall clock.
    var at: Date
    var kind: Kind
    /// How its last attempt ended: `answered`, or `ended` with no reply drawn here.
    var outcome: String
    var events: [Event]
    var total: Int64
    /// What ran beside the events and is not in their sum: a save made while the guest worked,
    /// `at` its start and `took` its length.
    var beside: [Event]
    /// The voice's first sound, from its start to its first frame, in ms from the turn's start.
    var sound: ClosedRange<Int64>?
    /// Each model request's body, in bytes, in order.
    var requestBytes: [Int]
    /// Each model request's message thread, as the proxy named its kind (`ThreadLog.Kind`), in order.
    var requestThreads: [String]
    var tools: Int
    /// How many times its words were sent: more than one is a retry.
    var sends: Int
    /// Another turn's time overlapped this one's, for the stretch said as one.
    var mixed: Bool

    var answered: Bool { outcome == "answered" }

    private struct Span {
        var id: String
        var origin: Int64
        var end: Int64?
        /// Its last tagged mark, which bounds a turn that has not ended.
        var seen: Int64
    }

    /// Every finished turn in `marks`, in the order they ended. A turn is finished when each of
    /// its attempts has ended and the last did not leave the guest answering: the turn asking,
    /// still in flight, is none.
    static func turns(in marks: [PerfMark]) -> [TurnTimeline] {
        let marks = marks.enumerated().sorted { ($0.element.ms, $0.offset) < ($1.element.ms, $1.offset) }.map(\.element)
        var order: [String] = []
        var begun: [String: Int] = [:], ended: [String: Int] = [:], last: [String: PerfMark] = [:]
        var line: [String: Int64] = [:], firstAttempt: [String: Int64] = [:], seen: [String: Int64] = [:]
        var spoken: Set<String> = []
        for mark in marks {
            guard let id = mark.turn else { continue }
            seen[id] = mark.ms
            switch mark.name {
            case "turn.line":
                if line[id] == nil { line[id] = mark.ms }
                if !order.contains(id) { order.append(id) }
            case "turn.spoken":
                spoken.insert(id)
            case "turn.attempt":
                begun[id, default: 0] += 1
                if firstAttempt[id] == nil { firstAttempt[id] = mark.ms }
                if !order.contains(id) { order.append(id) }
            case "turn.attempt.end":
                ended[id, default: 0] += 1
                last[id] = mark
            default:
                break
            }
        }
        let spans: [Span] = order.compactMap { id in
            guard let start = line[id] ?? firstAttempt[id] else { return nil }
            var origin = start
            // A spoken turn begins at the release whose hearing came before its words went on the line.
            // One with another turn's words put on the line in between is not this turn's release.
            if spoken.contains(id), let heard = marks.last(where: { $0.name == "voice.heard" && $0.ms <= start }),
               let released = marks.last(where: { $0.name == "voice.released" && $0.ms <= heard.ms }),
               !line.contains(where: { $0.key != id && $0.value > released.ms && $0.value < start }) {
                origin = released.ms
            }
            // An attempt that ended `unsaved` left the guest answering: the turn goes on.
            let done = (begun[id] ?? 0) > 0 && begun[id] == ended[id] && last[id]?.detail.hasSuffix(" unsaved") == false
            guard done, let final = last[id] else { return Span(id: id, origin: origin, end: nil, seen: seen[id] ?? start) }
            // An answered turn stops at its reply handed to the view, by its own mark (an untagged
            // one may be another turn's); the attempt's end comes after the pass's own work that
            // follows, which is no turn's wait and overlaps none.
            let shown = final.detail.hasSuffix(" answered")
                ? marks.last { $0.name == "turn.reply.shown" && $0.turn == id && $0.ms >= origin && $0.ms <= final.ms }
                : nil
            return Span(id: id, origin: origin, end: shown?.ms ?? final.ms, seen: seen[id] ?? start)
        }
        var found: [(end: Int64, turn: TurnTimeline)] = []
        for span in spans {
            guard let end = span.end, let final = last[span.id] else { continue }
            let turn = TurnTimeline(span, end: end, final: final, marks: marks, others: spans.filter { $0.id != span.id },
                                    spoken: spoken.contains(span.id))
            found.append((end, turn))
        }
        return found.sorted { $0.end < $1.end }.map(\.turn)
    }

    private init(_ span: Span, end: Int64, final: PerfMark, marks: [PerfMark], others: [Span], spoken: Bool) {
        let origin = span.origin
        at = Date(timeIntervalSince1970: Double(origin) / 1000)
        kind = spoken ? .spoken : .typed
        outcome = final.detail.split(separator: " ").last.map(String.init) ?? "ended"
        let window = marks.filter { $0.ms >= origin && $0.ms <= end }
        // Where another turn was under way inside this one's time, the untagged marks of that
        // stretch belong to either: from the first of it to the last is said as one. One that has
        // not ended is under way to this turn's end if it began inside it, and otherwise only as
        // far as its own last mark (a line a hub answered, say, is no part of every turn after).
        // Stretches that do not touch stay apart, so this turn's own events between them are read.
        var shared: [ClosedRange<Int64>] = []
        for other in others {
            let reach = other.end ?? (other.origin >= origin ? end : other.seen)
            let from = max(other.origin, origin), to = min(reach, end)
            guard from < to else { continue }
            shared.append(from...to)
        }
        var blurs: [ClosedRange<Int64>] = []
        for range in shared.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = blurs.last, range.lowerBound <= last.upperBound {
                blurs[blurs.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                blurs.append(range)
            }
        }
        mixed = !blurs.isEmpty
        let clean = window.filter { mark in !blurs.contains { $0.contains(mark.ms) } }

        var raw: [(ms: Int64, key: Key, title: String)] = []
        if spoken, let heard = window.first(where: { $0.name == "voice.heard" }) {
            raw.append((heard.ms, .hear, "Heard you"))
        }
        let attempts = window.filter { $0.name == "turn.attempt" && $0.turn == span.id }
        sends = attempts.count
        for (n, attempt) in attempts.enumerated() {
            raw.append((attempt.ms, .queue, n == 0 ? "Started on its way" : "Sent again"))
        }
        // A stretch begins where the other turn did: the wait up to there is this turn's own,
        // whatever it was waiting on, and only the stretch itself is said as shared.
        for blur in blurs {
            if blur.lowerBound > origin { raw.append((blur.lowerBound, .wait, "Another message began")) }
            raw.append((blur.upperBound, .mixed, "Alongside another message"))
        }
        let write = clean.first { $0.name == "turn.guest.write" }
        if let write {
            raw.append((write.ms, .ready, "Claude Code had your words"))
            // Its first word back on the turn: a process still starting (a launch, a resume, a
            // boot) spends its start here, not in making the request.
            if let begun = clean.first(where: { $0.name == "turn.guest.init" && $0.ms >= write.ms }) {
                raw.append((begun.ms, .start, "Claude Code started on your words"))
            }
        }
        // Words given to the guest ahead of their save are saved while it works: that save is no
        // wait of the turn's, so it is said beside it, from the first send, and not in the sum.
        var beside: [Event] = []
        let sent = attempts.first?.ms ?? origin
        func save(_ mark: PerfMark, _ title: String) {
            if let write, write.ms < mark.ms {
                beside.append(Event(key: .save, title: title + ", while Claude Code worked", at: sent - origin, took: mark.ms - sent))
            } else {
                raw.append((mark.ms, .save, title))
            }
        }
        if let saved = clean.first(where: { $0.name == "turn.lease.fresh" || $0.name == "turn.saved" })
            ?? clean.first(where: { $0.name == "turn.person.saved" }) {
            save(saved, "Your words saved to iCloud")
        }
        if let unsaved = clean.first(where: { $0.name == "turn.unsaved" }) { save(unsaved, "iCloud had not taken your words yet") }
        self.beside = beside
        // The model's requests, each followed by the id its marks share.
        var bytes: [Int] = [], threads: [String] = [], previousDone = origin
        let requests = clean.filter { $0.name == "proxy.request" && $0.isMessages }
        for (n, request) in requests.enumerated() {
            let number = n + 1, id = request.value("id")
            let size = request.value("bytes").flatMap(Int.init)
            if let size { bytes.append(size) }
            let toolRan = clean.contains { $0.name == "turn.guest.toolUse" && $0.ms >= previousDone && $0.ms <= request.ms }
            raw.append((request.ms, toolRan ? .tool : .prepare,
                        toolRan ? "A tool ran, then Claude Code made request \(number)" : "Claude Code made request \(number)"))
            guard let id else { continue }
            func mine(_ name: String) -> PerfMark? {
                clean.first { $0.name == name && $0.isMessages && $0.value("id") == id && $0.ms >= request.ms }
            }
            if let thread = request.value("thread") { threads.append(thread) }
            if let sent = mine("proxy.sent") {
                let about = [size.map(Self.size), request.value("thread").flatMap { Self.threadWords[$0] }].compactMap { $0 }
                raw.append((sent.ms, .upload, "Request \(number) sent" + (about.isEmpty ? "" : " (\(about.joined(separator: ", ")))")))
            }
            if let first = mine("proxy.firstByte") { raw.append((first.ms, .model, "The model began answering request \(number)")) }
            if let done = mine("proxy.done") {
                raw.append((done.ms, .stream, "The model finished request \(number)"))
                previousDone = done.ms
            }
        }
        requestBytes = bytes
        requestThreads = threads
        tools = clean.filter { $0.name == "turn.guest.toolUse" }.count
        if let first = clean.first(where: { $0.name == "turn.text.first" }) { raw.append((first.ms, .screen, "First words on your screen")) }
        if let result = clean.first(where: { $0.name == "turn.guest.result" }) { raw.append((result.ms, .finish, "Claude Code finished the reply")) }
        if let saved = clean.first(where: { $0.name == "turn.reply.saved" }) { raw.append((saved.ms, .store, "The reply saved to iCloud")) }
        if let failed = clean.last(where: { $0.name == "turn.reply.failed" }) { raw.append((failed.ms, .store, "The reply failed")) }
        if outcome == "answered" {
            raw.append((end, .show, "The reply on your screen"))
        } else {
            raw.append((end, .end, "The turn ended with no reply here"))
        }

        // A shared stretch is one event from its start to its end: this turn's own marks inside it
        // (an attempt sent again, say) are not said, so none takes part of the stretch's time, and
        // at its end the stretch is said before anything that came at the same moment.
        let said = raw.filter { item in item.key == .mixed || !blurs.contains { $0.lowerBound < item.ms && item.ms < $0.upperBound } }
        let sorted = said.enumerated().sorted {
            ($0.element.ms, $0.element.key == .mixed ? 0 : 1, $0.offset) < ($1.element.ms, $1.element.key == .mixed ? 0 : 1, $1.offset)
        }.map(\.element)
        var cursor = origin
        events = sorted.map { item in
            defer { cursor = item.ms }
            return Event(key: item.key, title: item.title, at: item.ms - origin, took: item.ms - cursor)
        }
        total = (sorted.last?.ms ?? end) - origin
        // The voice's first sound for this turn's reply, by its own tag: a replay, or another
        // turn's reply, is never this turn's. Its first frame is the one before any other begins.
        // Read by position in the marks' order, since two marks can share a millisecond.
        if let i = marks.firstIndex(where: { $0.name == "speak.begin" && $0.turn == span.id && $0.ms >= origin }) {
            let after = marks[(i + 1)...]
            let next = after.firstIndex { $0.name == "speak.begin" } ?? marks.endIndex
            if let frame = marks[(i + 1)..<next].first(where: { $0.name == "speak.firstFrame" }) {
                sound = (marks[i].ms - origin)...(frame.ms - origin)
            }
        }
    }

    // MARK: What is said and kept

    static func seconds(_ ms: Int64) -> String { String(format: "%.2f s", Double(ms) / 1000) }

    /// A request's thread in a person's words, by the kind the proxy names (`ThreadLog.Kind`).
    static let threadWords = ["none": "the whole conversation", "create": "a thread begun",
                              "continue": "a thread continued", "unread": "a thread not read"]

    static func size(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) bytes" : String(format: "%.0f KB", Double(bytes) / 1024)
    }

    /// The time spent under each key, in the keys' order, those with none left out.
    var byKey: [(key: Key, ms: Int64)] {
        Key.allCases.compactMap { key in
            let events = events.filter { $0.key == key }
            return events.isEmpty ? nil : (key, events.map(\.took).reduce(0, +))
        }
    }

    /// The line a record of this turn is kept as: when it began in UTC, its kind and outcome, the
    /// whole, the milliseconds under each key, then the counts.
    var record: String {
        var fields = ["perf-turn", ToolDates.write(at, in: TimeZone(identifier: "UTC")!), kind.rawValue, outcome, "total=\(total)"]
        fields += byKey.map { "\($0.key.rawValue)=\($0.ms)" }
        if let save = beside.first(where: { $0.key == .save }) { fields.append("saved=\(save.at + save.took)") }
        if let sound { fields.append("\(Self.soundKey)=\(sound.upperBound)") }
        if let thread = requestThreads.first, Self.threadWords[thread] != nil { fields.append("thread=\(thread)") }
        fields += ["bytes=\(requestBytes.reduce(0, +))", "requests=\(requestBytes.count)", "tools=\(tools)", "sends=\(sends)"]
        if mixed { fields.append("mixed") }
        return fields.joined(separator: " ")
    }
}
