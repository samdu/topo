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
}

/// Where one turn's time went, from the person's release or send to the reply on the screen, as
/// consecutive stages named for a person. Built from the marks' names, times and the counts they
/// carry alone, so nothing a turn said is in it.
struct TurnTimeline: Equatable, Sendable {
    /// A stage of a turn: a key that is kept, and the words a person reads.
    enum Stage: String, CaseIterable, Sendable {
        case hear, save, ready, prepare, upload, first, screen, reply, store, show

        var title: String {
            switch self {
            case .hear: "Hearing you"
            case .save: "Saving your words to iCloud"
            case .ready: "Getting Claude Code ready"
            case .prepare: "Claude Code preparing the request"
            case .upload: "Sending the request"
            case .first: "Waiting for the model's first word"
            case .screen: "First words on the screen"
            case .reply: "Writing the reply"
            case .store: "Saving the reply to iCloud"
            case .show: "Drawing the reply"
            }
        }
    }

    /// What ran beside the turn's own way, and is no part of its sum: the voice.
    static let soundKey = "sound"
    static let soundTitle = "The voice's first sound"

    struct Span: Equatable, Sendable {
        var stage: Stage
        /// Milliseconds from the turn's start.
        var start: Int64
        var end: Int64
        var took: Int64 { end - start }
    }

    enum Kind: String, Sendable {
        case spoken, typed
    }

    /// When the turn began, on the wall clock.
    var at: Date
    var kind: Kind
    /// Whether the turn ended in its reply on the screen, or in a reply that failed.
    var answered: Bool
    /// Consecutive, from 0 to `total`: they sum to it.
    var spans: [Span]
    var total: Int64
    /// The voice's first sound: from the voice's start to its first frame, in ms from the turn's start.
    var sound: (start: Int64, end: Int64)?
    /// The first model request's body, in bytes; tools the reply ran; model requests it made.
    var requestBytes: Int?
    var tools: Int
    var requests: Int
    /// How many times the words were sent: more than one is a retry.
    var sends: Int
    /// Claude Code was started for this turn rather than found running.
    var started: Bool

    static func == (a: TurnTimeline, b: TurnTimeline) -> Bool {
        a.at == b.at && a.kind == b.kind && a.answered == b.answered && a.spans == b.spans && a.total == b.total
            && a.sound?.start == b.sound?.start && a.sound?.end == b.sound?.end && a.requestBytes == b.requestBytes
            && a.tools == b.tools && a.requests == b.requests && a.sends == b.sends && a.started == b.started
    }

    /// The model's own requests, by the route the proxy names them by.
    static let messages = "POST /v1/messages"

    /// Each stage ends at the first of its marks after the stage before it ended. A stage whose
    /// mark is missing, or came before that, is not drawn, and its time is the next stage's.
    private static func ends(_ stage: Stage) -> (PerfMark) -> Bool {
        switch stage {
        case .hear: { $0.name == "voice.heard" }
        case .save: { $0.name == "turn.person.saved" || $0.name == "turn.unsaved" }
        case .ready: { $0.name == "turn.guest.write" }
        case .prepare: { $0.name == "proxy.request" && $0.detail.hasPrefix(messages + " ") }
        case .upload: { $0.name == "proxy.head" && $0.detail.hasPrefix(messages + " ") }
        case .first: { $0.name == "proxy.firstByte" && $0.detail == messages }
        case .screen: { $0.name == "turn.text.first" }
        case .reply: { $0.name == "turn.guest.result" }
        case .store: { $0.name == "turn.reply.saved" || $0.name.hasPrefix("turn.reply.failed") }
        case .show: { _ in false }
        }
    }

    /// Every finished turn in `marks`, oldest first. A turn is the marks after the last turn's
    /// end up to its own: `turn.reply.shown`, or `turn.reply.failed`; it starts at its first
    /// `turn.send`, or at the release before it where the words were spoken. A send with no end
    /// yet — the turn asking — is no turn.
    static func turns(in marks: [PerfMark]) -> [TurnTimeline] {
        let marks = marks.sorted { $0.ms < $1.ms }
        var found: [TurnTimeline] = []
        var from = 0
        for (index, mark) in marks.enumerated() where mark.name == "turn.reply.shown" || mark.name == "turn.reply.failed" {
            let window = Array(marks[from...index])
            from = index + 1
            let after = index + 1 < marks.count ? Array(marks[(index + 1)...]) : []
            if let turn = TurnTimeline(window, after: after) { found.append(turn) }
        }
        return found
    }

    /// One turn from `window`, which ends at its end mark; `after` is what followed, where the
    /// voice may still be starting.
    private init?(_ window: [PerfMark], after: [PerfMark]) {
        guard let send = window.firstIndex(where: { $0.name == "turn.send" }), let last = window.last else { return nil }
        let released = window[..<send].last { $0.name == "voice.released" }
        let origin = released?.ms ?? window[send].ms
        at = Date(timeIntervalSince1970: Double(origin) / 1000)
        kind = released == nil ? .typed : .spoken
        answered = last.name == "turn.reply.shown"
        total = last.ms - origin
        let own = window.filter { $0.ms >= origin }
        var spans: [Span] = [], cursor = origin, position = own.startIndex
        for stage in Stage.allCases {
            if stage == .hear, released == nil { continue }
            let end: Int64
            if stage == .show {
                // Whatever ended the turn: the reply drawn, or the failure after its last stage.
                guard last.ms > cursor else { continue }
                end = last.ms
            } else {
                let ends = Self.ends(stage)
                guard let found = own[position...].firstIndex(where: ends) else { continue }
                position = found
                end = own[found].ms
            }
            spans.append(Span(stage: stage, start: cursor - origin, end: end - origin))
            cursor = end
        }
        self.spans = spans
        let request = own.first { $0.name == "proxy.request" && $0.detail.hasPrefix(Self.messages + " ") }
        requestBytes = request.flatMap { mark in
            mark.detail.split(separator: " ").first { $0.hasPrefix("bytes=") }.flatMap { Int($0.dropFirst(6)) }
        }
        tools = own.filter { $0.name == "turn.guest.toolUse" }.count
        requests = own.filter { $0.name == "proxy.request" && $0.detail.hasPrefix(Self.messages + " ") }.count
        sends = own.filter { $0.name == "turn.send" }.count
        started = own.contains { $0.name == "resident.launch.begin" || $0.name == "guest.boot.begin" }
        // The voice starts while the reply is still being written, or after it is drawn; what
        // follows the end is looked at until the next turn is sent.
        let following = window[send...] + after.prefix { $0.name != "turn.send" && $0.name != "voice.released" }
        if let begin = following.first(where: { $0.name == "speak.begin" }),
           let frame = following.first(where: { $0.name == "speak.firstFrame" && $0.ms >= begin.ms }) {
            sound = (begin.ms - origin, frame.ms - origin)
        }
    }

    // MARK: What is said and kept

    static func seconds(_ ms: Int64) -> String { String(format: "%.2f s", Double(ms) / 1000) }

    func title(_ stage: Stage) -> String {
        switch stage {
        case .upload: requestBytes.map { "\(stage.title) (\(Self.size($0)))" } ?? stage.title
        case .reply where tools > 0 || requests > 1:
            "\(stage.title) (\(tools) tool\(tools == 1 ? "" : "s"), \(requests) model request\(requests == 1 ? "" : "s"))"
        case .ready where started: "\(stage.title) (started afresh)"
        default: stage.title
        }
    }

    static func size(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) bytes" : String(format: "%.0f KB", Double(bytes) / 1024)
    }

    /// The line a record of this turn is kept as: when it began in UTC, its kind, and each stage's
    /// milliseconds by key, with the counts after.
    var record: String {
        var fields = ["perf-turn", ToolDates.write(at, in: TimeZone(identifier: "UTC")!), kind.rawValue, answered ? "answered" : "failed", "total=\(total)"]
        fields += spans.map { "\($0.stage.rawValue)=\($0.took)" }
        if let sound { fields.append("\(Self.soundKey)=\(sound.end)") }
        if let requestBytes { fields.append("bytes=\(requestBytes)") }
        fields += ["tools=\(tools)", "requests=\(requests)"]
        return fields.joined(separator: " ")
    }
}
