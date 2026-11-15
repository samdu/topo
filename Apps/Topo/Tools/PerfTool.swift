import Foundation
import TopoCore
import TopoTools

/// `topo perf`: where a turn's time went, from inside. The turns are read off this launch's
/// `perf` marks in the unified log (`docs/perf.md`), through the same reader `topo log` uses, and
/// said as stages named for a person, or as tab-separated rows for a program. Nothing a turn said
/// reaches an answer or a record: a stage's title, times and counts are all either is made of. The
/// app keeps nothing: the mind keeps a turn's `record:` line in its own memory where it wants one.
struct PerfTool: Tool {
    let reader: any LogReading
    var now: @Sendable () -> Date = { Date() }

    /// How far back the log is read: a whole day, which is more than the store keeps of a launch.
    static let window: TimeInterval = 24 * 3600
    static let backs = 1...50

    let name = "perf"
    let summary = "where a turn's time went, stage by stage, to read, chart or keep"
    let usage = """
    topo perf turns                     this launch's finished turns, newest first: how far back, when, spoken or
                                        typed, how long
    topo perf turn [--back N] [--tsv]   where the time of the last finished turn went (N turns back with --back),
                                        stage by stage from the release or the send to the reply on the screen,
                                        and a record: line for it; --tsv answers the stages as rows for a program

    The stages, by key: \(TurnTimeline.Stage.allCases.map { "\($0.rawValue) (\($0.title))" }.joined(separator: ", ")).
    They follow one another, so they add up to the turn's time; a stage that left no mark is not
    there, and its time is the next one's. "\(TurnTimeline.soundTitle)" (key sound) ran beside them on a
    spoken turn and is not part of the sum.

    --tsv: a header line, then one row a stage, tab-separated: key, start_ms, took_ms, title, with
    the sound last where there was one, then the record: line.
    The record: line, without "record: ", is one line a turn: perf-turn, when it began (UTC), spoken
    or typed, answered or failed, then key=ms for total and each stage, sound=ms from the start to
    the voice's first sound, bytes= the first model request's size, tools= and requests= counts.

    The turns go with the launch; to keep track over time, append that line to a file in your
    memory (~/memory/perf/turns.txt, say) after each turn worth keeping.

    The turns are this launch's only, read from the app's perf log lines: none are there while
    topo log level says perf is off. Nothing in an answer is anything a turn said.
    """

    enum Call: Equatable {
        case turns
        case turn(back: Int, tsv: Bool)
    }

    func run(_ arguments: [String]) async -> ToolReply {
        await PhoneTool.run({ _ in nil }, broker: PermissionBroker(), usage: usage, parse: { try parse(arguments) }) { call in
            switch call {
            case .turns:
                let turns = try await read()
                guard !turns.isEmpty else { return .ok(Self.noTurns) }
                return .ok(turns.reversed().enumerated().map { index, turn in
                    PhoneTool.line(["back \(index + 1)", ToolDates.write(turn.at), turn.kind.rawValue,
                                    turn.answered ? nil : "failed", TurnTimeline.seconds(turn.total)])
                }.joined(separator: "\n") + "\n")
            case .turn(let back, let tsv):
                let turn = try await turn(back: back)
                return .ok(tsv ? Self.rows(turn) : Self.describe(turn, back: back))
            }
        }
    }

    static let noTurns = "no finished turn in this launch's perf marks (none since it started, or topo log level has perf off)\n"

    func parse(_ arguments: [String]) throws -> Call {
        let read = try Arguments(arguments, options: ["back"], flags: ["tsv"])
        guard let form = read.words.first else { throw Misuse("perf takes turns or turn") }
        guard read.words.count == 1 else { throw Misuse("perf \(form) takes no \(read.words[1])") }
        switch form {
        case "turns":
            guard read.options.isEmpty, read.flags.isEmpty else { throw Misuse("perf turns takes no options") }
            return .turns
        case "turn":
            let back = try read.options["back"].map { text in
                guard text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text), Self.backs.contains(value) else {
                    throw Misuse("--back takes a whole number from \(Self.backs.lowerBound) to \(Self.backs.upperBound)")
                }
                return value
            } ?? 1
            return .turn(back: back, tsv: read.flags.contains("tsv"))
        default:
            throw Misuse("perf takes turns or turn, not \(form)")
        }
    }

    // MARK: Reading

    private static let queue = DispatchQueue(label: "zone.hexagon.topo.perf-read")

    /// This launch's finished turns, oldest first.
    private func read() async throws -> [TurnTimeline] {
        let reader = reader, since = now().addingTimeInterval(-Self.window)
        // The store's read blocks, so it has a thread of its own and never one of the pool's.
        let lines: [LogLine] = try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { continuation.resume(with: Result { try reader.lines(since: since) }) }
        }
        try Task.checkCancellation()
        return TurnTimeline.turns(in: lines.filter { $0.category == LogCategory.perf.rawValue }.compactMap { PerfMark(message: $0.message) })
    }

    private func turn(back: Int) async throws -> TurnTimeline {
        let turns = try await read()
        guard !turns.isEmpty else { throw ToolFailure(Self.noTurns.trimmingCharacters(in: .newlines)) }
        guard back <= turns.count else {
            throw ToolFailure("this launch has \(turns.count) finished turn\(turns.count == 1 ? "" : "s"); --back \(back) is before the first")
        }
        return turns[turns.count - back]
    }

    // MARK: Saying

    static func describe(_ turn: TurnTimeline, back: Int) -> String {
        let from = turn.kind == .spoken ? "your release" : "your send"
        let to = turn.answered ? "the reply on the screen" : "the reply failing"
        var lines = ["\(back == 1 ? "the last turn" : "\(back) turns back"), at \(ToolDates.write(turn.at)), \(turn.kind.rawValue): "
                     + "\(TurnTimeline.seconds(turn.total)) from \(from) to \(to)"]
        if turn.sends > 1 { lines.append("its words were sent \(turn.sends) times") }
        let width = (turn.spans.map { turn.title($0.stage).count } + [TurnTimeline.soundTitle.count]).max() ?? 0
        func row(_ title: String, _ start: Int64, _ took: Int64) -> String {
            "  " + title.padding(toLength: width, withPad: " ", startingAt: 0)
                + "  at " + TurnTimeline.seconds(start) + "  took " + TurnTimeline.seconds(took)
        }
        lines += turn.spans.map { row(turn.title($0.stage), $0.start, $0.took) }
        if let sound = turn.sound {
            lines.append("alongside:")
            lines.append(row(TurnTimeline.soundTitle, sound.start, sound.end - sound.start))
        }
        lines.append("record: \(turn.record)")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The stages as rows for a program: tab-separated, a header first, the record last.
    static func rows(_ turn: TurnTimeline) -> String {
        var lines = ["key\tstart_ms\ttook_ms\ttitle"]
        lines += turn.spans.map { "\($0.stage.rawValue)\t\($0.start)\t\($0.took)\t\(turn.title($0.stage))" }
        if let sound = turn.sound {
            lines.append("\(TurnTimeline.soundKey)\t\(sound.start)\t\(sound.end - sound.start)\t\(TurnTimeline.soundTitle)")
        }
        lines.append("record: \(turn.record)")
        return lines.joined(separator: "\n") + "\n"
    }
}
