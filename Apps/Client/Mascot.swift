#if os(iOS)
import Foundation
import Observation
import TopoMascot
import TopoTurn
import TopoUserland

/// What Topo on the glass stands for: the model answering, how much context it holds, what it is
/// doing and the words on a sign. The engine (`Packages/TopoMascot`) draws him from it — the
/// model picks his head, the context's fill his colour and face, the activity his pose.
///
/// It is a value a pure function makes from events (`MascotMapping`), so which pose a turn puts
/// him in is a thing a test can hold over recorded stream-json rather than a view reading a
/// harness.
struct MascotState: Equatable, Sendable {
    /// The model's id as the API names it (`claude-haiku-4-5-20251001`): its family is the head.
    var model: String
    /// The tokens of context the last message was written over: input and both cache counts.
    var tokens: Int = 0
    var activity: Activity = .idle
    /// Words on a sign he holds up. Nothing sets it yet; while it is nil he holds none.
    var sign: String?

    /// The poses the engine has for work, and the one for none. A pose that is not idle is shown
    /// only while a turn is in flight: the working animation is the honest sign that work is.
    enum Activity: String, CaseIterable, Sendable {
        case idle, thinking, searching, building, writing, calendar, yoga
    }

    /// What the engine is handed for this state, a frame at a time.
    var input: TopoInput {
        TopoInput(model: model, tokens: Double(tokens), activity: sign == nil ? activity.rawValue : "sign", sign: sign)
    }
}

/// Events to state: the one place that says what a turn's events do to him.
///
/// The guest's events are Claude Code's stream-json (`StreamEvent`): `system/init` names the model,
/// each assistant message's usage the context, a thinking block is thinking, and a tool call's
/// name — and for a tool that writes a file, the file — is the pose. A turn's end, however it
/// ended, is idle, and so is a turn's start: nothing of one turn's pose is carried into the next.
enum MascotMapping {
    /// What a turn is doing when it calls `tool`, which for a file tool names `path`; nil for a
    /// tool that says nothing about the work, which leaves the pose as it was.
    ///
    /// - A file tool writing under the memory's mount is yoga: editing its own memory is the mind
    ///   improving itself. `memory` is where that mount is in the guest, and there is none until
    ///   the notes folder is mounted, so today nothing in the guest is yoga.
    /// - Bash, and a file tool writing a file that is code by its extension, is building.
    /// - WebSearch and WebFetch are searching.
    /// - A file tool writing anything else is writing: prose, notes, a file named with no path.
    /// - Nothing maps to calendar yet: the phone's own tools are not in the guest.
    static func activity(tool: String, path: String?, memory: String?) -> MascotState.Activity? {
        if StreamJSON.fileTools[tool] != nil {
            if let path, let memory, isUnder(path, memory) { return .yoga }
            if let path, isCode(path) { return .building }
            return .writing
        }
        switch tool {
        case "Bash": return .building
        case "WebSearch", "WebFetch": return .searching
        default: return nil
        }
    }

    /// One of the turn's events onto the state.
    static func next(_ state: MascotState, _ event: StreamEvent, memory: String?) -> MascotState {
        var next = state
        switch event {
        case .started(_, let model):
            next.model = model
        case .usage(let usage):
            if !usage.model.isEmpty { next.model = usage.model }
            next.tokens = usage.context
        case .thinking:
            next.activity = .thinking
        case .toolUse(let name, let path):
            if let activity = activity(tool: name, path: path, memory: memory) { next.activity = activity }
        case .text, .result, .other, .malformed:
            break
        }
        return next
    }

    /// A turn's update: its events, then its end. Answered, failed or abandoned, the end is idle.
    static func next(_ state: MascotState, _ update: GuestSession.TurnUpdate, memory: String?) -> MascotState {
        switch update {
        case .event(let event):
            return next(state, event, memory: memory)
        case .ended:
            return ended(state)
        }
    }

    /// A turn is sent: whatever the last one was doing is not what this one is doing.
    static func began(_ state: MascotState) -> MascotState { ended(state) }

    /// A turn is over, or its updates stopped without an end: nothing is in flight.
    static func ended(_ state: MascotState) -> MascotState {
        var next = state
        next.activity = .idle
        return next
    }

    /// The chat's own harness, when no guest turn runs: the model it asks and the context of the
    /// last reply it got, and no tools, since the Messages API turn runs none.
    static func harness(_ state: MascotState, model: String, tokens: Int?) -> MascotState {
        var next = state
        next.model = model
        if let tokens { next.tokens = tokens }
        return next
    }

    /// The extensions of files that are code, lower-cased. What is not here is writing.
    static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "rs", "go", "java", "kt", "kts", "scala",
        "py", "rb", "php", "pl", "lua", "js", "mjs", "cjs", "ts", "tsx", "jsx", "sh", "bash", "zsh",
        "fish", "sql", "html", "css", "scss", "json", "yaml", "yml", "toml", "xml", "plist", "ipynb",
        "gradle", "cmake", "make", "mk", "dockerfile", "r", "jl", "ex", "exs", "erl", "hs", "ml",
        "cs", "fs", "dart", "vue", "svelte", "zig", "nim",
    ]

    static func isCode(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if ["makefile", "dockerfile", "gemfile", "rakefile", "package.swift"].contains(name) { return true }
        let ext = (name as NSString).pathExtension
        return !ext.isEmpty && codeExtensions.contains(ext)
    }

    /// Whether `path` is `root` or inside it, once both are standardised, so `..` cannot walk a
    /// path in or out of the memory.
    static func isUnder(_ path: String, _ root: String) -> Bool {
        let path = (path as NSString).standardizingPath, root = (root as NSString).standardizingPath
        guard path.hasPrefix("/"), root.hasPrefix("/") else { return false }
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

/// Topo's state as the app holds it: one value the glass reads, moved by the chat's harness and
/// by the guest's turns.
@MainActor
@Observable
final class Mascot {
    private(set) var state: MascotState
    /// Where the memory is mounted in the guest, for the yoga pose. Nil: nothing mounts it yet.
    var memory: String?

    init(model: String = ClaudeModel.effective(.default).rawValue) {
        state = MascotState(model: model)
    }

    /// The chat's harness: the model it asks, and the context of the last reply it got.
    func harness(model: String, tokens: Int?) {
        state = MascotMapping.harness(state, model: model, tokens: tokens)
    }

    /// A guest turn was sent.
    func guestTurnBegan() { state = MascotMapping.began(state) }

    /// One of a guest turn's updates.
    func guest(_ update: GuestSession.TurnUpdate) {
        state = MascotMapping.next(state, update, memory: memory)
    }

    /// A guest turn's updates stopped, with or without an end: whatever it was doing, it is not
    /// doing it now.
    func guestTurnGone() { state = MascotMapping.ended(state) }
}
#endif
