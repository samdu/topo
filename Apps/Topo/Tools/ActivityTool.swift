import Foundation
import TopoTools

/// `topo activity`: the mind's hand on the lock screen and the Dynamic Island (docs/widgets.md,
/// *Live Activities*). It starts a Live Activity from an `ActivityDocument` — a progress tracker,
/// the pane's JSON or where to poll it from, and `topo widget`'s node grammar per region —
/// updates one, ends one, and lists what is running. The system holds attributes and state under
/// 4 KB, so every start and update is judged against `ActivityPayload` first.
struct ActivityTool: Tool {
    var host: @MainActor @Sendable () -> ActivityHost
    var keeper: @MainActor @Sendable () -> ActivityKeeper
    var fetcher: TrackerFetcher = URLTrackerFetcher()
    var now: @Sendable () -> Date = { Date() }

    let name = "activity"
    let summary = "a Live Activity on the lock screen and in the Dynamic Island: a progress tracker, a timer, a countdown"
    var usage: String {
        """
        topo activity                            every activity running: id, slot, started, until, what it draws
        topo activity start SLOT JSON            start one (prints its id; status 6 when part or all of the document was
                                                 refused, the output saying what was kept; 2 when none of it could be read)
        topo activity update ID JSON             new content: what the document carries replaces, the rest stands
        topo activity end ID [--dismiss now|default|DATE] [JSON]
                                                 end one, with a last document if given; default leaves it on the
                                                 lock screen a while, now takes it off, DATE (ISO 8601) at that time
        topo activity example                    a tracker and a timer: the quickest way to the shape

        A SLOT is [a-z0-9-], at most 32 characters, one activity a slot. The document is an object with any of:
          "tracker": the decisions pane's progress tracker JSON (title, steps[label, state, note], current, eta…),
                     drawn as a segmented bar with the step in focus, its note and the estimate;
          "poll": an http(s) URL answering that JSON (GET /progress/<id>), fetched at the start and every
                     \(Int(ActivityKeeper.interval.components.seconds)) s while Topo runs — in front or holding background time — and
                     never while it is suspended: locked away, the activity reads "updated N ago" rather than moving;
          "families": a node tree per region, in topo widget's grammar: lockScreen, islandExpanded,
                     islandCompactLeading, islandCompactTrailing, islandMinimal. A region without one draws the
                     tracker, or Topo's mark. Text with "date" and "dateStyle": "timer" counts by itself, with no
                     update, so a timer or a countdown needs none;
          "until": ISO 8601, at most 12 h ahead: the activity is taken off then while Topo runs, or when Topo
                     next comes to the screen, and reads stale past it meanwhile;
          "tint": a Theme token or #RRGGBB, the activity's background;  "relevance": 0–100, its order.
        Every region shows on a locked phone: put nothing private in one. No control and no image in an activity.
        Budgets: \(ActivityDocument.payloadLimit) bytes for the state with the attributes (a long tracker keeps its steps and
        loses their labels), text \(WidgetDocument.accessoryTextLimit) characters, \(WidgetDocument.nodeLimit) nodes.
        An activity starts only while Topo is on the screen (status 1 otherwise); the system caps how many run,
        and the person can turn them off for Topo in Settings (status 5).
        """
    }

    func run(_ arguments: [String]) async -> ToolReply {
        switch (arguments.first, arguments.count) {
        case (nil, _):
            return await list()
        case ("example", 1):
            return .ok(Self.example(now: now()) + "\n")
        case ("start", 3):
            return await start(slot: arguments[1], json: arguments[2])
        case ("update", 3):
            return await update(id: arguments[1], json: arguments[2])
        case ("end", let count) where (2...5).contains(count):
            return await end(Array(arguments.dropFirst()))
        default:
            return .usage("topo: activity takes nothing, start, update, end or example\n\n\(usage)\n")
        }
    }

    // MARK: Listing

    @MainActor
    private func list() -> ToolReply {
        let records = host().running()
        guard !records.isEmpty else { return .ok("no activity running\n") }
        var lines: [String] = []
        for record in records {
            var head = ["activity: \(record.id)", "slot \(record.attributes.slot)", record.ended ? "ended" : "running",
                        "started \(ToolDates.write(record.attributes.started))"]
            if let until = record.state.until { head.append("until \(ToolDates.write(until))") }
            if let poll = record.attributes.poll { head.append("polled from \(poll.host ?? poll.absoluteString)") }
            lines.append(PhoneTool.line(head))
            if let card = record.state.card {
                let focus = card.focus.map { ", at \($0.label.isEmpty ? "step \(card.current + 1)" : $0.label)" } ?? ""
                lines.append("  tracker: \(card.title), \(card.past) of \(card.steps.count) done, \(card.state.rawValue)\(focus)")
            }
            if let layout = record.state.layout.map(ActivityLayout.read), !layout.regions.isEmpty {
                lines.append("  families: " + ActivityRegion.allCases.filter { layout.regions[$0] != nil }.map(\.rawValue).joined(separator: ", "))
            }
        }
        return .ok(lines.joined(separator: "\n") + "\n")
    }

    // MARK: Starting

    @MainActor
    private func start(slot: String, json: String) async -> ToolReply {
        guard WidgetDocument.isSlot(slot) else {
            return .usage("topo: a slot is [a-z0-9-], at most 32 characters\n")
        }
        guard host().enabled else {
            return ToolReply(status: ToolReply.denied, text: Self.disabled)
        }
        if let running = host().running().first(where: { $0.attributes.slot == slot && !$0.ended }) {
            return .failed("topo: slot \(slot) is running as \(running.id); update or end it\n")
        }
        let keeper = keeper()
        // Held from here until the reply: a second start of the slot while this one fetches is refused.
        guard keeper.reserve(slot) else {
            return .failed("topo: slot \(slot) is starting; wait for it\n")
        }
        // Released only under the login that reserved it: after an `endAll` the slot is another
        // start's to hold, and this one lets go of nothing.
        let reserved = keeper.generation
        defer { if keeper.generation == reserved { keeper.release(slot) } }
        let reading = ActivityDocument.read(json, now: now())
        guard case .read = reading.state else {
            return .usage("topo: the document " + Self.why(reading.state) + "\n" + Self.notes(reading.notes))
        }
        var notes = reading.notes
        let document = reading.document
        var tracker = document.tracker
        if tracker == nil, let poll = document.poll {
            let generation = keeper.generation
            let data = await fetcher.fetch(poll)
            guard keeper.generation == generation else {
                return .failed("topo: the login ended while the tracker was fetched; nothing started\n")
            }
            guard let data else {
                return .failed("topo: poll gave no tracker: no 2xx within \(Int(URLTrackerFetcher.deadline.components.seconds)) s and \(URLTrackerFetcher.cap / 1024) KB, redirects not followed\n")
            }
            let fetched = ProgressTracker.read(data, now: now())
            guard let got = fetched.tracker else {
                return .failed("topo: poll gave no tracker: \(fetched.notes.joined(separator: "; "))\n")
            }
            notes += fetched.notes
            tracker = got
        }
        let attributes = TopoActivityAttributes(slot: slot, poll: document.poll, started: now())
        let asked = ActivityState(document, tracker: tracker)
        let fitted = ActivityPayload.fit(asked, with: attributes)
        guard let state = fitted.state else {
            return Self.overBudget(fitted.note, notes, "nothing started")
        }
        if let note = fitted.note { notes.append(note) }
        let notice = keeper.notice(state, polled: attributes.poll != nil)
        let started = Result { try host().start(attributes, notice) }
        switch started {
        case .success(let id):
            keeper.keep(id)
            let text = "started \(id) for slot \(slot)\n" + Self.notes(notes)
            return notes.isEmpty ? .ok(text) : ToolReply(status: ToolReply.refused, text: text)
        case .failure(let error):
            return Self.refused(error)
        }
    }

    // MARK: Updating

    @MainActor
    private func update(id: String, json: String) async -> ToolReply {
        guard let record = host().running().first(where: { $0.id == id && !$0.ended }) else {
            return .failed("topo: no activity \(id) running\n")
        }
        let reading = ActivityDocument.read(json, now: now(), update: true)
        guard case .read = reading.state else {
            return .usage("topo: the document " + Self.why(reading.state) + "\n" + Self.notes(reading.notes))
        }
        var notes = reading.notes
        if reading.document.poll != nil { notes.append(Self.pollStands) }
        let asked = ActivityState(reading.document, tracker: reading.document.tracker, over: record.state)
        let fitted = ActivityPayload.fit(asked, with: record.attributes)
        guard let state = fitted.state else {
            return Self.overBudget(fitted.note, notes, "nothing changed")
        }
        if let note = fitted.note { notes.append(note) }
        let keeper = keeper()
        let generation = keeper.generation
        keeper.touch(id)
        let updated = await host().update(id, keeper.notice(state, polled: record.attributes.poll != nil))
        guard updated else { return .failed("topo: no activity \(id) running\n") }
        // Kept only while the login that updated it stands: after an `endAll` nothing is restarted.
        if keeper.generation == generation { keeper.keep(id) }
        let text = "updated \(id)\n" + Self.notes(notes)
        return notes.isEmpty ? .ok(text) : ToolReply(status: ToolReply.refused, text: text)
    }

    // MARK: Ending

    @MainActor
    private func end(_ arguments: [String]) async -> ToolReply {
        let id = arguments[0]
        var rest = Array(arguments.dropFirst())
        var dismissal = ActivityDismissal.standard
        if let flag = rest.firstIndex(of: "--dismiss") {
            guard flag + 1 < rest.count else { return .usage("topo: --dismiss takes now, default or an ISO 8601 date\n") }
            let value = rest[flag + 1]
            switch value {
            case "now": dismissal = .now
            case "default": dismissal = .standard
            default:
                guard let read = ToolDates.read(value), read.date > now() else {
                    return .usage("topo: --dismiss takes now, default or an ISO 8601 date and time still ahead\n")
                }
                dismissal = .at(read.date)
            }
            rest.removeSubrange(flag...(flag + 1))
        }
        guard rest.count <= 1 else { return .usage("topo: end takes an id, --dismiss and at most one document\n") }
        guard let record = host().running().first(where: { $0.id == id && !$0.ended }) else {
            return .failed("topo: no activity \(id) running\n")
        }
        var state: ActivityState?
        var notes: [String] = []
        if let json = rest.first {
            let reading = ActivityDocument.read(json, now: now(), update: true)
            guard case .read = reading.state else {
                return .usage("topo: the document " + Self.why(reading.state) + "\n" + Self.notes(reading.notes))
            }
            notes = reading.notes
            if reading.document.poll != nil { notes.append(Self.pollStands) }
            let asked = ActivityState(reading.document, tracker: reading.document.tracker, over: record.state)
            let fitted = ActivityPayload.fit(asked, with: record.attributes)
            guard let fit = fitted.state else {
                return Self.overBudget(fitted.note, notes, "nothing ended")
            }
            if let note = fitted.note { notes.append(note) }
            state = fit
        }
        keeper().forget(id)
        guard await host().end(id, state, dismissal: dismissal) else { return .failed("topo: no activity \(id) running\n") }
        let text = "ended \(id)\n" + Self.notes(notes)
        return notes.isEmpty ? .ok(text) : ToolReply(status: ToolReply.refused, text: text)
    }

    // MARK: Words

    static let disabled = "topo: Live Activities are off for Topo; they are turned on in Settings › Topo › Live Activities\n"
    static let pollStands = "poll is set at the start and stands; it was ignored"

    /// Status 6: the whole document refused, since nothing of it fits beside the attributes.
    static func overBudget(_ note: String?, _ notes: [String], _ outcome: String) -> ToolReply {
        ToolReply(status: ToolReply.refused, text: "topo: the document " + (note ?? "is over the payload budget") + "; \(outcome)\n" + Self.notes(notes))
    }

    static func refused(_ error: Error) -> ToolReply {
        switch error as? ActivityRefusal {
        case .disabled: ToolReply(status: ToolReply.denied, text: disabled)
        case .notOnScreen: .failed("topo: Topo is not on the screen, and a Live Activity starts only while it is; ask again with Topo in front\n")
        case .tooMany: .failed("topo: the system is showing as many Live Activities as it allows; end one first\n")
        case .tooLarge: .failed("topo: the system refused the activity as too large\n")
        case .other(let why): .failed("topo: the system would not start the activity: \(why)\n")
        case nil: .failed("topo: the system would not start the activity\n")
        }
    }

    static func why(_ state: ActivityDocument.State) -> String {
        if case .unreadable(let why) = state { return why }
        return "was read"
    }

    static func notes(_ notes: [String]) -> String {
        notes.isEmpty ? "" : notes.map { "note: \($0)\n" }.joined()
    }

    static func example(now: Date) -> String {
        examples(now: now).map { "\($0.label):\n\($0.json)" }.joined(separator: "\n")
    }

    static func examples(now: Date) -> [(label: String, json: String)] {
        let soon = ToolDates.write(now.addingTimeInterval(25 * 60), in: TimeZone(identifier: "UTC")!)
        let tracker = """
        {"version": 1, "tint": "primary", "until": "\(soon)",
         "tracker": {"title": "macOS update on buddybox",
                     "steps": [{"label": "Check for update", "state": "done", "note": "26.1 → 26.2 available"},
                               {"label": "Download", "state": "running"}, "Install and restart", "Verify versions"],
                     "current": 1, "eta": \(Int(now.timeIntervalSince1970) + 1500)}}
        """
        let polled = """
        {"version": 1, "poll": "https://pane.example.ts.net/decisions/progress/b36e250e", "until": "\(soon)"}
        """
        let timer = """
        {"version": 1, "until": "\(soon)", "families": {
          "lockScreen": {"kind": "hstack", "children": [
            {"kind": "glyph", "symbol": "cup.and.saucer.fill", "size": 28, "colour": "primary"},
            {"kind": "vstack", "alignment": "leading", "children": [
              {"kind": "text", "text": "Tea", "style": "headline"},
              {"kind": "text", "date": "\(soon)", "dateStyle": "timer", "style": "title2", "design": "rounded"}]}]},
          "islandExpanded": {"kind": "text", "text": "Tea", "date": "\(soon)", "dateStyle": "timer", "style": "title3"},
          "islandCompactLeading": {"kind": "glyph", "symbol": "cup.and.saucer.fill", "size": 14, "colour": "primary"},
          "islandCompactTrailing": {"kind": "text", "date": "\(soon)", "dateStyle": "timer", "style": "caption"},
          "islandMinimal": {"kind": "glyph", "symbol": "cup.and.saucer.fill", "size": 14, "colour": "primary"}}}
        """
        return [("a tracker given whole", tracker), ("a tracker polled from the pane", polled), ("a timer, which needs no update", timer)]
    }
}
