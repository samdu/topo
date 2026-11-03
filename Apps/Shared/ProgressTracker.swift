import Foundation

/// The decisions pane's progress tracker — a "pizza tracker" for a multi-step process a session is
/// driving — as its JSON gives it (samdu/memory `wiki/decisions-pane.md`, *Progress trackers*,
/// `GET /progress/<id>`). One renderer's model for every surface that draws one: the phone's Live
/// Activity here, and MacManager's desktop widget, which carries a copy of this file, Foundation
/// only, so the two judge the pane's JSON the same way.
///
/// `read` judges every field where it is read and lets a bad field cost itself and nothing else:
/// a label over the contract's length is cut with a note, a state that is not a case is `waiting`
/// with a note, a `current` outside the steps is derived from them. Only a tracker with no steps
/// at all is unreadable, since there is nothing to draw. The type is `Codable` under
/// `ProgressTracker.decoder` and `encoder` (dates as epoch seconds, as the pane writes them), which
/// is how it crosses a process boundary once judged; the JSON the pane answers carries more
/// (`history`, `delivery`) and is read through `read`, never decoded straight.
struct ProgressTracker: Codable, Hashable, Sendable {
    enum State: String, Codable, CaseIterable, Sendable { case running, done, failed }

    struct Step: Codable, Hashable, Sendable {
        enum State: String, Codable, CaseIterable, Sendable { case waiting, running, done, failed, skipped }
        var label: String
        var state: State = .waiting
        /// One line, or empty.
        var note: String = ""
        /// When the step last changed; nil while it has never moved.
        var at: Date?

        /// A step the bar counts as behind it.
        var isPast: Bool { state == .done || state == .skipped }
    }

    struct Owner: Codable, Hashable, Sendable {
        var session: String = ""
        var address: String = ""
        var link: String = ""
    }

    static let titleLimit = 70
    static let stepLimit = 20
    static let labelLimit = 40
    static let noteLimit = 80
    static let idLimit = 64
    static let sessionLimit = 64

    var id: String
    var title: String
    var steps: [Step]
    /// The step in focus, an index into `steps`: the last set running or failed, or the next an
    /// advance started.
    var current: Int
    var state: State
    /// When the whole process should be done, for a renderer to draw an estimate between updates.
    var eta: Date?
    var started: Date
    var updated: Date
    var ended: Date?
    var owner: Owner

    /// The share of the steps behind the bar: done or skipped over the count.
    var fraction: Double {
        guard !steps.isEmpty else { return 0 }
        return Double(steps.filter(\.isPast).count) / Double(steps.count)
    }

    /// The step in focus.
    var focus: Step { steps[min(max(current, 0), steps.count - 1)] }

    /// Still going: no step failed and not every step is done or skipped.
    var isRunning: Bool { state == .running }

    // MARK: Codable

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    // MARK: Reading

    struct Reading: Equatable, Sendable {
        var tracker: ProgressTracker?
        /// Every refusal, in the order the tracker was walked. Empty is a tracker taken whole.
        var notes: [String] = []
    }

    /// The pane's JSON, judged field by field.
    static func read(_ data: Data, now: Date = Date()) -> Reading {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return Reading(notes: ["tracker is not JSON"])
        }
        return read(parsed, now: now)
    }

    static func read(_ json: Any, now: Date = Date()) -> Reading {
        guard let root = json as? [String: Any] else { return Reading(notes: ["tracker is not a JSON object"]) }
        var notes: [String] = []
        func note(_ path: String, _ why: String) { notes.append("tracker.\(path) \(why)") }

        if let kind = root["kind"], (kind as? String) != "progress" {
            return Reading(notes: ["tracker.kind is \(kind), not progress"])
        }

        // The steps first: with none there is nothing to draw, whatever else was given.
        guard let rawSteps = root["steps"] as? [Any], !rawSteps.isEmpty else {
            return Reading(notes: ["tracker.steps is missing or empty, and a tracker is its steps"])
        }
        var steps: [Step] = []
        // Where each step the document wrote is among those kept: `current` names one as written.
        var kept: [Int: Int] = [:]
        for (index, raw) in rawSteps.enumerated() {
            let path = "steps[\(index)]"
            guard steps.count < stepLimit else {
                note(path, "is past the \(stepLimit) steps a tracker holds, and was dropped")
                continue
            }
            let object: [String: Any]
            if let text = raw as? String { object = ["label": text] }
            else if let given = raw as? [String: Any] { object = given }
            else { note(path, "is not a step, and was dropped"); continue }
            guard let label = object["label"] as? String, !label.isEmpty else {
                note(path + ".label", "is missing, and the step was dropped")
                continue
            }
            var step = Step(label: label)
            let line = label.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            if line.count != label.count {
                note(path + ".label", "is more than one line, and only the first was kept")
                step.label = line
            }
            if step.label.count > labelLimit {
                note(path + ".label", "is \(step.label.count) characters, and a label holds \(labelLimit), so it was cut")
                step.label = String(step.label.prefix(labelLimit))
            }
            if let state = object["state"] {
                if let name = state as? String, let known = Step.State(rawValue: name) { step.state = known }
                else { note(path + ".state", "is not one of \(Step.State.allCases.map(\.rawValue).joined(separator: ", ")), so the step is waiting") }
            }
            if let rawNote = object["note"], !(rawNote is NSNull) {
                if let text = rawNote as? String {
                    let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                    if line.count != text.count { note(path + ".note", "is more than one line, and only the first was kept") }
                    if line.count > noteLimit {
                        note(path + ".note", "is \(line.count) characters, and a note holds \(noteLimit), so it was cut")
                        step.note = String(line.prefix(noteLimit))
                    } else {
                        step.note = line
                    }
                } else {
                    note(path + ".note", "is not text")
                }
            }
            if let at = object["at"], !(at is NSNull) {
                if let moment = date(at) { step.at = moment } else { note(path + ".at", "is not a time in epoch seconds") }
            }
            kept[index] = steps.count
            steps.append(step)
        }
        guard !steps.isEmpty else {
            return Reading(notes: notes + ["tracker.steps holds no step that could be read"])
        }

        var id = ""
        if let raw = root["id"] {
            if let text = raw as? String, !text.isEmpty, text.count <= idLimit { id = text }
            else { note("id", "is not text of at most \(idLimit) characters") }
        }

        var title = ""
        if let raw = root["title"] {
            if let text = raw as? String {
                let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                if line.count != text.count { note("title", "is more than one line, and only the first was kept") }
                if line.count > titleLimit {
                    note("title", "is \(line.count) characters, and a title holds \(titleLimit), so it was cut")
                    title = String(line.prefix(titleLimit))
                } else {
                    title = line
                }
            } else {
                note("title", "is not text")
            }
        } else {
            note("title", "is missing")
        }

        let derivedState: State = steps.contains { $0.state == .failed } ? .failed
            : steps.allSatisfy(\.isPast) ? .done : .running
        var state = derivedState
        if let raw = root["state"] {
            if let name = raw as? String, let known = State(rawValue: name) { state = known }
            else { note("state", "is not one of \(State.allCases.map(\.rawValue).joined(separator: ", ")), so it was derived from the steps") }
        }

        let derivedCurrent = steps.lastIndex { $0.state == .running || $0.state == .failed }
            ?? steps.firstIndex { $0.state == .waiting } ?? steps.count - 1
        var current = derivedCurrent
        if let raw = root["current"] {
            if let index = integer(raw), let at = kept[index] { current = at }
            else { note("current", "is not the index of a step that was kept, so it was derived from them") }
        }

        func moment(_ key: String) -> Date? {
            guard let raw = root[key], !(raw is NSNull) else { return nil }
            if let date = date(raw) { return date }
            note(key, "is not a time in epoch seconds")
            return nil
        }
        let started = moment("started") ?? steps.compactMap(\.at).min() ?? now
        let updated = moment("updated") ?? steps.compactMap(\.at).max() ?? started
        let ended = moment("ended")
        let eta = moment("eta")

        var owner = Owner()
        if let raw = root["owner"] {
            if let object = raw as? [String: Any] {
                for key in ["session", "address", "link"] {
                    guard let raw = object[key], !(raw is NSNull) else { continue }
                    guard let text = raw as? String else { note("owner.\(key)", "is not text"); continue }
                    switch key {
                    case "session":
                        if text.count > sessionLimit {
                            note("owner.session", "is \(text.count) characters, and a session name holds \(sessionLimit), so it was cut")
                        }
                        owner.session = String(text.prefix(sessionLimit))
                    case "address": owner.address = text
                    default: owner.link = text
                    }
                }
            } else {
                note("owner", "is not an object")
            }
        }

        let tracker = ProgressTracker(id: id, title: title, steps: steps, current: current, state: state, eta: eta,
                                      started: started, updated: updated, ended: ended, owner: owner)
        return Reading(tracker: tracker, notes: notes)
    }

    private static func date(_ raw: Any) -> Date? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let seconds = number.doubleValue
        // Epoch seconds between 2001 and 2100; anything else is a unit mistake, not a time.
        guard seconds.isFinite, (978_307_200...4_102_444_800).contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func integer(_ raw: Any) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value == value.rounded(), abs(value) < 1e9 else { return nil }
        return Int(value)
    }
}
