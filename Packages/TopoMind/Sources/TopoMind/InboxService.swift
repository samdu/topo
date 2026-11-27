import CryptoKit
import Foundation
import TopoCore

/// What the mind has asked the hub to watch for it: `inbox.json` in the mind's root.
///
///     {"sources": [{"name": "mail", "command": "…", "every": "15m", "urgent": false}],
///      "flush": "2h", "quiet": {"from": "23:00", "to": "07:00"}}
///
/// The mind writes it; the hub reads it at every tick, so a change needs no restart. A source is
/// a shell command that prints what there is, one item a line. Each value is checked where it is
/// read, and a source that is refused costs itself and no other: a document that is missing or
/// is not this shape has no sources.
public struct InboxDocument: Sendable, Equatable {
    public struct Source: Sendable, Equatable {
        public var name: String
        public var command: String
        /// How often the command is run.
        public var every: TimeInterval
        /// Whether a new item is told at once, at any hour, or waits for the flush.
        public var urgent: Bool
    }

    public static let fileName = "inbox.json"
    public static let everyRange: ClosedRange<TimeInterval> = 60...86_400
    public static let flushRange: ClosedRange<TimeInterval> = 300...86_400
    public static let standardFlush: TimeInterval = 7_200
    public static let sourceLimit = 24

    public var sources: [Source] = []
    /// How long new items that are not urgent wait together before the mind is told.
    public var flush = InboxDocument.standardFlush
    /// Minutes of the day between which nothing but an urgent item is told; nil for none.
    public var quiet: (from: Int, to: Int)?

    public static func == (a: InboxDocument, b: InboxDocument) -> Bool {
        a.sources == b.sources && a.flush == b.flush && a.quiet?.from == b.quiet?.from && a.quiet?.to == b.quiet?.to
    }

    public init() {}

    public init(data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        var names: Set<String> = []
        for case let entry as [String: Any] in object["sources"] as? [Any] ?? [] where sources.count < Self.sourceLimit {
            guard let name = entry["name"] as? String, Self.isName(name), !names.contains(name),
                  let command = entry["command"] as? String, !command.allSatisfy(\.isWhitespace), command.count <= 4_000,
                  let every = (entry["every"] as? String).flatMap(Self.seconds), Self.everyRange.contains(every) else { continue }
            names.insert(name)
            sources.append(Source(name: name, command: command, every: every, urgent: entry["urgent"] as? Bool ?? false))
        }
        if let said = (object["flush"] as? String).flatMap(Self.seconds), Self.flushRange.contains(said) { flush = said }
        if let hours = object["quiet"] as? [String: Any], let from = (hours["from"] as? String).flatMap(Self.minute),
           let to = (hours["to"] as? String).flatMap(Self.minute), from != to {
            quiet = (from, to)
        }
    }

    public static func read(at file: URL) -> InboxDocument {
        (try? Data(contentsOf: file)).map(InboxDocument.init(data:)) ?? InboxDocument()
    }

    /// A name is letters, digits, `-` and `_`: it heads the source's items in a batch.
    static func isName(_ name: String) -> Bool {
        (1...40).contains(name.count) && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// `90s`, `15m`, `2h`.
    static func seconds(_ text: String) -> TimeInterval? {
        guard let unit = text.last, let count = Double(text.dropLast()), count.isFinite, count > 0 else { return nil }
        switch unit {
        case "s": return count
        case "m": return count * 60
        case "h": return count * 3_600
        default: return nil
        }
    }

    /// `23:00` as minutes of the day.
    static func minute(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    /// Whether `minuteOfDay` is in the quiet hours, which may run over midnight.
    func isQuiet(_ minuteOfDay: Int) -> Bool {
        guard let quiet else { return false }
        return quiet.from < quiet.to ? (quiet.from..<quiet.to).contains(minuteOfDay)
            : minuteOfDay >= quiet.from || minuteOfDay < quiet.to
    }
}

/// The hub's inbox: runs the document's sources on their schedules, keeps what each has printed
/// before from being told again, holds new items together, and hands the mind a batch
/// (`HubMind.hear`) at once for an urgent source's item and otherwise when the flush interval has
/// passed outside the quiet hours.
///
/// A source's first run tells nothing: what it prints then is what was already there. An item is
/// a line, known again by its hash, so the state on disk holds no line that has been told. A
/// batch the mind could not be handed is kept and offered again at the next tick, and nothing is
/// run while the mind is not answering, so nothing piles up for a mind that is off.
public actor InboxService {
    public struct Ran: Sendable {
        public var status: Int32
        public var output: String
        public init(status: Int32, output: String) {
            self.status = status
            self.output = output
        }
    }

    struct State: Codable, Equatable {
        /// Hashes of the lines each source has printed, newest last.
        var seen: [String: [String]] = [:]
        /// The sources that have run once.
        var seeded: Set<String> = []
        var lastRun: [String: Date] = [:]
        /// New lines not yet told, by source, in the order they came.
        var held: [String: [String]] = [:]
        /// Whether something held came from an urgent source.
        var urgent = false
        var lastFlush: Date?
    }

    public static let seenLimit = 2_000
    public static let heldLimit = 200
    public static let lineLimit = 600
    public static let outputLimit = 64_000
    public static let runBound: TimeInterval = 60

    private let document: URL
    private let stateFile: URL
    private let ready: @Sendable () async -> Bool
    private let deliver: @Sendable (String) async -> Bool
    private let run: @Sendable (InboxDocument.Source) async -> Ran
    private let now: @Sendable () -> Date
    private let minuteOfDay: @Sendable (Date) -> Int
    private var state: State
    private var loop: Task<Void, Never>?

    /// - Parameters:
    ///   - root: the mind's root, where the document and the state are.
    ///   - ready: whether the mind answers now; nothing runs while it does not.
    ///   - deliver: hands the mind a batch; false keeps it for the next tick.
    ///   - run: runs a source's command; the default is `/bin/sh -c` in `directory` with `environment`.
    public init(root: URL, directory: URL, environment: [String: String],
                ready: @escaping @Sendable () async -> Bool, deliver: @escaping @Sendable (String) async -> Bool,
                run: (@Sendable (InboxDocument.Source) async -> Ran)? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                minuteOfDay: @escaping @Sendable (Date) -> Int = { date in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                }) {
        document = root.appending(path: InboxDocument.fileName)
        stateFile = root.appending(path: "inbox-state.json")
        self.ready = ready
        self.deliver = deliver
        self.run = run ?? { await InboxService.shell($0.command, in: directory, environment: environment) }
        self.now = now
        self.minuteOfDay = minuteOfDay
        state = (try? Data(contentsOf: stateFile)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    /// Ticks every `interval` until `stop`.
    public func start(every interval: Duration = .seconds(30)) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One pass: the sources that are due are run, and what is held is told if it is time.
    public func tick() async {
        guard await ready() else { return }
        let document = InboxDocument.read(at: self.document)
        let before = state
        let names = Set(document.sources.map(\.name))
        // A source taken out of the document takes what it knew with it, so one put back starts again.
        for gone in Set(state.seen.keys).union(state.seeded).union(state.held.keys) where !names.contains(gone) {
            state.seen[gone] = nil
            state.seeded.remove(gone)
            state.lastRun[gone] = nil
            state.held[gone] = nil
        }
        for source in document.sources {
            if let last = state.lastRun[source.name], now().timeIntervalSince(last) < source.every { continue }
            let began = now()
            let ran = await run(source)
            state.lastRun[source.name] = began
            take(ran, from: source)
        }
        await flush(document)
        if state != before { save() }
    }

    private func take(_ ran: Ran, from source: InboxDocument.Source) {
        guard ran.status == 0 else {
            // A command that failed printed nothing to be believed; the mind hears of it once it is seeded.
            Perf.mark("hub.inbox.ran \(source.name) status=\(ran.status)")
            return
        }
        var seen = state.seen[source.name] ?? []
        var known = Set(seen)
        var fresh: [String] = []
        for line in ran.output.prefix(Self.outputLimit).split(separator: "\n") {
            let line = String(line.trimmingCharacters(in: .whitespaces).prefix(Self.lineLimit))
            guard !line.isEmpty else { continue }
            let hash = Self.hash(line)
            guard known.insert(hash).inserted else { continue }
            seen.append(hash)
            fresh.append(line)
        }
        state.seen[source.name] = Array(seen.suffix(Self.seenLimit))
        let first = state.seeded.insert(source.name).inserted
        Perf.mark("hub.inbox.ran \(source.name) status=0 new=\(fresh.count)\(first ? " first" : "")")
        guard !first, !fresh.isEmpty else { return }
        state.held[source.name] = Array(((state.held[source.name] ?? []) + fresh).suffix(Self.heldLimit))
        if source.urgent { state.urgent = true }
    }

    private func flush(_ document: InboxDocument) async {
        let held = document.sources.compactMap { source in state.held[source.name].map { (source.name, $0) } }.filter { !$0.1.isEmpty }
        guard !held.isEmpty else { return }
        let since = state.lastFlush.map { now().timeIntervalSince($0) } ?? .infinity
        let why: String
        if state.urgent {
            why = "urgent"
        } else if since >= document.flush, !document.isQuiet(minuteOfDay(now())) {
            why = "timer"
        } else {
            return
        }
        let text = held.map { name, lines in "\(name):\n" + lines.map { "- \($0)" }.joined(separator: "\n") }.joined(separator: "\n\n")
        guard await deliver(text) else {
            Perf.mark("hub.inbox.flush.refused")
            return
        }
        Perf.mark("hub.inbox.flushed why=\(why) sources=\(held.count) lines=\(held.reduce(0) { $0 + $1.1.count })")
        state.held = [:]
        state.urgent = false
        state.lastFlush = now()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
    }

    static func hash(_ line: String) -> String {
        SHA256.hash(data: Data(line.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs `command` with `/bin/sh -c`, and ends it at `runBound`: its status and what it printed.
    static func shell(_ command: String, in directory: URL, environment: [String: String]) async -> Ran {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]
                process.currentDirectoryURL = directory
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: Ran(status: 127, output: ""))
                    return
                }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + runBound, execute: timer)
                // Read to the end before the wait, so a command that prints more than a pipe holds ends.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                continuation.resume(returning: Ran(status: process.terminationStatus,
                                                   output: String(decoding: data.prefix(outputLimit), as: UTF8.self)))
            }
        }
    }
}
