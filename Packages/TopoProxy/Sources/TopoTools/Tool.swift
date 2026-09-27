import Foundation

/// One of the phone's tools, as the guest's `topo` command reaches it: `topo <name> <arguments…>`.
/// A tool answers every call with a `ToolReply` rather than throwing, since what it says back is
/// all the mind in the guest hears of it.
public protocol Tool: Sendable {
    /// The word after `topo`.
    var name: String { get }
    /// One line for `topo help`.
    var summary: String { get }
    /// What `topo help <name>` prints: how to call it, one form a line.
    var usage: String { get }
    /// Runs one call. `arguments` are what followed the name.
    func run(_ arguments: [String]) async -> ToolReply
}

/// What a call answers: the status the guest's `topo` exits with, and the text it prints.
public struct ToolReply: Sendable, Equatable {
    public var status: Int32
    public var text: String

    public init(status: Int32, text: String) {
        self.status = status
        self.text = text
    }

    /// Done.
    public static let ok: Int32 = 0
    /// The tool could not do what it was asked, and says why.
    public static let failed: Int32 = 1
    /// The call was not one the tool takes; the text is its usage.
    public static let usage: Int32 = 2
    /// The app did not answer at all. The script's own status: no reply carries it.
    public static let unreachable: Int32 = 3
    /// The call ran past the service's bound.
    public static let timedOut: Int32 = 4
    /// Part of the call was refused, and the text says which part and why.
    public static let refused: Int32 = 6

    public static func ok(_ text: String) -> ToolReply { ToolReply(status: ok, text: text) }
    public static func failed(_ text: String) -> ToolReply { ToolReply(status: failed, text: text) }
    public static func usage(_ text: String) -> ToolReply { ToolReply(status: usage, text: text) }
}

/// The tools by name, and `help`: what the service dispatches a call through, and what `topo help`
/// lists, so the list and the dispatch cannot disagree.
public struct ToolTable: Sendable {
    public let tools: [any Tool]

    public init(_ tools: [any Tool]) {
        self.tools = tools
    }

    public func tool(named name: String) -> (any Tool)? {
        tools.first { $0.name == name }
    }

    /// The whole of `topo help`.
    public var help: String {
        var lines = ["topo: the phone's own tools, run by the Topo app.", "", "usage: topo <tool> [arguments…]", ""]
        let width = tools.map(\.name.count).max() ?? 0
        for tool in tools {
            lines.append("  " + tool.name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + tool.summary)
        }
        lines += ["", "topo help <tool> says how to call one.",
                  "Exit status: 0 done, 1 failed, 2 not a call the tool takes, 3 the app did not answer,",
                  "4 the call took too long, 6 part of it refused (the text says which)."]
        return lines.joined(separator: "\n") + "\n"
    }

    /// One call, `argv` as the guest's `topo` was given it.
    public func run(_ argv: [String]) async -> ToolReply {
        guard let first = argv.first, !["help", "-h", "--help"].contains(first) else {
            if argv.count > 1, let tool = tool(named: argv[1]) {
                return .ok("topo \(tool.name): \(tool.summary)\n\n\(tool.usage)\n")
            }
            if argv.count > 1 { return .usage("topo: no tool called \(argv[1])\n\n" + help) }
            return .ok(help)
        }
        guard let tool = tool(named: first) else {
            return .usage("topo: no tool called \(first)\n\n" + help)
        }
        return await tool.run(Array(argv.dropFirst()))
    }
}
