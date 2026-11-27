import Foundation
import TopoCore
import TopoMind
import TopoTools

/// The `topo` command of a mind on a Mac (`docs/hub.md`, *The mind's tools*): a tool service on
/// the hub's loopback, as the phone's guest has, whose tools reach the person's other devices
/// through the records. The command is a script the hub writes into the mind's `bin` at each
/// launch, beside a file with this launch's address and token that only the Mac's user reads.
enum HubTools {
    static let script = #"""
    #!/bin/bash
    # topo: the hub's tools for its mind. Written by Topo Hub at every launch.
    { set +x; } > /dev/null 2>&1
    here="$(cd "$(dirname "$0")" && pwd)"
    { read -r url && read -r token; } < "$here/../tools" 2>/dev/null || { echo "topo: Topo Hub is not running" >&2; exit 3; }
    # `--device NAME tool …` is the `device` tool's call.
    if [ "${1-}" = --device ]; then shift; set -- device "$@"; fi
    answer="$(
        {
            printf '%s\n' "$token"
            for argument in "$@"; do printf '%s' "$argument" | base64 | tr -d '\n'; printf '\n'; done
        } | curl -sS -m 200 -H 'Content-Type: text/plain' --data-binary @- "$url/run" 2>&1
        fetched=$?
        printf .
        exit "$fetched"
    )"
    fetched=$?
    answer="${answer%.}"
    if [ "$fetched" != 0 ]; then echo "topo: Topo Hub did not answer" >&2; exit 3; fi
    first="${answer%%$'\n'*}"
    case "$first" in
        "exit: "*) status="${first#exit: }" ;;
        *) echo "topo: Topo Hub answered something unreadable" >&2; exit 3 ;;
    esac
    if [ "$first" != "$answer" ]; then printf '%s' "${answer#*$'\n'}"; fi
    exit "$status"
    """#

    static let skill = """
    ---
    name: topo
    description: Reach the person's phone and other Apple devices from this Mac with the `topo` command - set a timer or alarm, schedule or send a notification, read and add reminders and calendar events, contacts, location, the home's accessories, maps. Use whenever the person asks for something a phone does.
    ---

    You run on the person's Mac. `topo` reaches their other devices:

    - `topo devices` lists them.
    - `topo --device iphone <tool> [arguments…]` runs one of the phone's own tools on it and prints its answer. `topo --device iphone help` lists the tools the phone lets this Mac run, and `topo --device iphone help <tool>` says how to call one. NAME is `iphone`, `ipad`, or part of a device's name.
    - `topo notify TITLE [BODY]` shows a notification on every one of the person's devices now. For one at a later time, use the phone's own: `topo --device iphone notify TITLE --in 15m`.

    Your own Claude Code's launch is yours to add to: write `~/Library/Application Support/Topo Hub/launch.json` as `{"arguments": ["--mcp-config", "/path/servers.json", "--channels", "name"]}`. The flags taken are `--channels`, `--mcp-config`, `--add-dir`, `--append-system-prompt`, `--plugin-dir`, `--settings` and `--dangerously-load-development-channels`, each with one value. A channel of the person's own (an MCP server from `--mcp-config` or your settings) is loaded with the last: `\"--dangerously-load-development-channels\", \"server:buddy-inbox\"`, several names in the one value with spaces between. It takes effect at your next turn, when your process is started again with them and resumes this conversation. If Claude Code will not start with them it is started without, so check the file when what you added is not there.

    A call to a device waits up to a minute for it. The phone answers at once while Topo is open on it, and otherwise when the system wakes it; a call nothing claimed is cancelled and never runs late, and `topo` says so. Tell the person plainly when the phone did not answer.
    """

    /// Writes the command, its skill and this launch's address and token.
    static func install(port: UInt16, token: String, root: URL, config: URL) throws {
        let files = FileManager.default
        let bin = root.appending(path: "bin", directoryHint: .isDirectory)
        try files.createDirectory(at: bin, withIntermediateDirectories: true)
        let command = bin.appending(path: "topo")
        try Data(script.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("    ") ? String($0.dropFirst(4)) : String($0) }.joined(separator: "\n").appending("\n").utf8)
            .write(to: command, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        let tools = root.appending(path: "tools")
        try Data("http://127.0.0.1:\(port)\n\(token)\n".utf8).write(to: tools, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tools.path)
        let skills = config.appending(path: "skills/topo", directoryHint: .isDirectory)
        try files.createDirectory(at: skills, withIntermediateDirectories: true)
        try Data(skill.utf8).write(to: skills.appending(path: "SKILL.md"), options: .atomic)
    }
}

/// `topo devices`: the devices on the Apple ID, as the directory has them.
struct DevicesTool: Tool {
    let devices: @Sendable () async -> [Device]
    let name = "devices"
    let summary = "the person's devices"
    let usage = "topo devices                        each device's kind, name and id, last seen first"

    func run(_ arguments: [String]) async -> ToolReply {
        let lines = await devices().sorted { $0.seenAt > $1.seenAt }
            .map { "\($0.kind.rawValue)\t\($0.name)\t\($0.id.rawValue)\tseen \(ISO8601DateFormatter().string(from: $0.seenAt))" }
        return .ok(lines.isEmpty ? "no devices\n" : lines.joined(separator: "\n") + "\n")
    }
}

/// `topo --device NAME <tool> …`: one of another device's own tools, run on it (`RemoteCall`).
struct DeviceTool: Tool {
    let hub: DeviceID
    let database: any RecordDatabase
    let devices: @Sendable () async -> [Device]
    /// Seconds a call stands unclaimed before the alert that says so is shown on the person's
    /// devices; negative, never.
    let alertAfter: @Sendable () -> TimeInterval

    let name = "device"
    let summary = "run one of another device's own tools on it: topo --device iphone timer …"
    let usage = """
    topo --device NAME <tool> [arguments…]   run the tool on that device and print its answer
    topo --device NAME help [tool]           the tools that device lets this Mac run

    NAME is iphone, ipad, watch, a device's id, or part of its name (topo devices lists them).
    """

    func run(_ arguments: [String]) async -> ToolReply {
        guard arguments.count >= 2 else { return .usage(usage + "\n") }
        let all = await devices().filter { $0.id != hub }
        guard let target = Self.resolve(arguments[0], among: all) else {
            return .failed("topo: no device called \(arguments[0]); topo devices lists them\n")
        }
        let argv = Array(arguments.dropFirst())
        let after = alertAfter()
        do {
            let answer = try await RemoteCalls.call(argv, on: target.id, from: hub, in: database, wakeAfter: max(after, 0)) { call in
                guard after >= 0 else { return }
                try? await RemoteAlert(hub: hub, title: "Topo", body: "Using \(target.name): \(argv.prefix(3).joined(separator: " "))")
                    .save(to: database)
            }
            Perf.mark("hub.call.answered \(argv.first ?? "") status=\(answer.status ?? -1) \(answer.evidence ?? "")")
            return ToolReply(status: Int32(answer.status ?? Int64(ToolReply.failed)), text: answer.text ?? "")
        } catch RemoteCalls.Failure.busy {
            return .failed("topo: \(target.name) is still on the call before this one; try again in a moment\n")
        } catch RemoteCalls.Failure.unclaimed {
            Perf.mark("hub.call.unclaimed \(argv.first ?? "")")
            return ToolReply(status: ToolReply.unreachable, text:
                "topo: \(target.name) did not pick the call up within 45 s, so it was cancelled and will not run. It runs at once while Topo is open on the device.\n")
        } catch RemoteCalls.Failure.unanswered {
            return ToolReply(status: ToolReply.timedOut, text: "topo: \(target.name) took the call and did not answer; it may or may not have run\n")
        } catch {
            return .failed("topo: iCloud could not be reached for the call\n")
        }
    }

    /// The device a name means: an id, a kind's word, or part of a name; the last seen of several.
    static func resolve(_ name: String, among devices: [Device]) -> Device? {
        let wanted = name.lowercased()
        let kinds: [String: Device.Kind] = ["iphone": .phone, "phone": .phone, "ipad": .pad, "pad": .pad, "watch": .watch, "mac": .mac, "tv": .tv]
        let matches = devices.filter { device in
            device.id.rawValue.lowercased() == wanted || kinds[wanted] == device.kind || device.name.lowercased().contains(wanted)
        }
        return matches.max { $0.seenAt < $1.seenAt }
    }
}

/// `topo inbox TEXT`: a batch of signals handed to the mind as a turn (`HubMind.hear`). The
/// door the hub's inbox service delivers through.
struct InboxTool: Tool {
    let hear: @Sendable (String) async -> Bool
    let name = "inbox"
    let summary = "hands the mind a batch of collected signals as a turn; the inbox service's own door"
    let usage = "topo inbox TEXT                     the mind is told TEXT at its next pass and answers in the transcript\n"

    func run(_ arguments: [String]) async -> ToolReply {
        guard arguments.count == 1, !arguments[0].allSatisfy(\.isWhitespace) else { return .usage(usage) }
        return await hear(arguments[0]) ? .ok("told\n") : .failed("topo: the mind on this Mac is not answering now, so nothing was told\n")
    }
}

/// `topo notify TITLE [BODY]`: words shown now on every device of the Apple ID (`RemoteAlert`).
struct AlertTool: Tool {
    let hub: DeviceID
    let database: any RecordDatabase
    let name = "notify"
    let summary = "a notification on every one of the person's devices, now"
    let usage = """
    topo notify TITLE [BODY]            shown now on each device that has Topo and allows its notifications

    For one at a later time, schedule it on the phone: topo --device iphone notify TITLE --in 15m
    """

    func run(_ arguments: [String]) async -> ToolReply {
        guard (1...2).contains(arguments.count), !arguments[0].isEmpty else { return .usage(usage + "\n") }
        // The push's alert is the record's two fields, and an empty one is drawn as its format.
        let (title, body) = arguments.count == 2 ? (arguments[0], arguments[1]) : ("Topo", arguments[0])
        do {
            try await RemoteAlert(hub: hub, title: title, body: body).save(to: database)
            Perf.mark("hub.alert.saved")
            return .ok("sent; iCloud delivers it, usually within seconds\n")
        } catch {
            return .failed("topo: iCloud could not be reached for the notification\n")
        }
    }
}
