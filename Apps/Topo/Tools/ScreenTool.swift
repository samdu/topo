import Foundation
import TopoTools
import TopoUserland

/// `topo screen`: the stills of the person's screen that the broadcast extension keeps while they
/// share it with Topo (`ScreenStore`, `Apps/Broadcast`). Read only. The person starts and stops
/// a share, through the system's own sheet, which is where it is permitted, each time: the tool
/// starts nothing, and where nothing is shared it says so and how they would.
///
/// `look` copies stills into a folder of the tool's own in the guest's home through `HomeFile`,
/// each under the time it was kept: a still already there under its name is that still. The
/// copies are the person's screen as much as the stills are, so they do not pile up and do not
/// outlast the login: a `look` takes away the copies more than `copiesLast` old, and `forget`,
/// which `follow` calls with the door shut, takes away all of them.
struct ScreenTool: Tool {
    var store: @Sendable () -> ScreenStore? = { ScreenStore.shared() }
    /// The guest's home on the host, which `guestHome` names in the guest.
    var home: @Sendable () -> URL = { GuestResident.homeDirectory }
    var now: @Sendable () -> Date = { Date() }

    static let guestHome = ClaudeLauncher.home
    /// The folder under the home a still is copied into.
    static let folder = "screen"
    /// The most stills one `look` copies.
    static let most = 6
    /// The most bytes of one still: far past what the extension writes, so a file that is not
    /// one of its stills is not read whole.
    static let stillBytes = 8 * 1024 * 1024
    /// How long a copy in the guest's home lasts before a later `look` takes it away.
    static let copiesLast: TimeInterval = 10 * 60

    /// Follows the login and the role, as `ScreenStore.follow` does, and with the door shut takes
    /// the copies out of the guest's home too: signed out, or no longer the guest's phone, none of
    /// the person's screen stays on it.
    static func follow(owner: Bool, store: ScreenStore?, home: URL) {
        store?.follow(owner: owner)
        if !owner { forget(under: home) }
    }

    /// Takes away every copy a `look` made.
    static func forget(under home: URL) {
        HomeFile.clear([folder], under: home, olderThan: -1)
    }

    static let notShared = """
    the screen is not being shared with Topo. Only the person can share it: in Topo's settings, \
    Share the screen with Topo, or in Control Center, touch and hold Screen Recording and choose Topo. \
    It is shared until they stop it
    """

    let name = "screen"
    let summary = "the person's screen while they share it with Topo: whether they are, and stills of it to look at"
    var usage: String { """
    topo screen status                  whether the screen is being shared, since when, how many stills are kept and
                                        how old the newest is
    topo screen look [--last N]         copy the newest still (the newest N, at most \(Self.most), oldest first) into
                                        \(Self.guestHome)/\(Self.folder) as a JPEG and print path | taken | age, to read as an image

    A still is kept when the screen changes, at most one every second or two, and the newest \(ScreenStore.ring) are held.
    Only the person starts and stops a share, from the system's own sheet. Stills from a share that has ended
    stay until the next begins. A copy in \(Self.guestHome)/\(Self.folder) lasts \(Int(Self.copiesLast / 60)) minutes; look again for one that has gone, and keep nothing of your own in that folder.
    """ }

    enum Call: Equatable {
        case status
        case look(last: Int)
    }

    func parse(_ arguments: [String]) throws -> Call {
        switch arguments.first {
        case "status" where arguments.count == 1:
            return .status
        case "look":
            switch arguments.count {
            case 1:
                return .look(last: 1)
            case 3 where arguments[1] == "--last":
                guard let last = Int(arguments[2]), (1...Self.most).contains(last) else {
                    throw ToolFailure("--last takes a number from 1 to \(Self.most)")
                }
                return .look(last: last)
            default:
                throw ToolFailure(usage, status: ToolReply.usage)
            }
        default:
            throw ToolFailure(usage, status: ToolReply.usage)
        }
    }

    func run(_ arguments: [String]) async -> ToolReply {
        await PhoneTool.run({ _ in nil }, broker: PermissionBroker(), usage: usage, parse: { try parse(arguments) }) { call in
            let store = store(), home = home(), now = now()
            // The folder's listing and the stills' bytes are a few small files, read in a task of their own.
            return try await Task.detached(priority: .userInitiated) {
                guard let store, store.door() != nil else { throw ToolFailure(Self.notShared) }
                let live = store.live(now: now), stills = store.stills()
                switch call {
                case .status:
                    guard live != nil || !stills.isEmpty else { throw ToolFailure(Self.notShared) }
                    return ToolReply(status: ToolReply.ok, text: Self.status(live: live, stills: stills, now: now) + "\n")
                case let .look(last):
                    guard !stills.isEmpty else {
                        throw ToolFailure(live == nil ? Self.notShared : "the screen is being shared and no still is kept yet; look again in a moment")
                    }
                    HomeFile.clear([Self.folder], under: home, olderThan: Self.copiesLast)
                    var lines = [Self.status(live: live, stills: stills, now: now)]
                    for still in stills.suffix(last) {
                        // One the ring let go of between the listing and here is skipped, as is one that
                        // cannot be read because the phone is locked.
                        guard let data = try? Data(contentsOf: still.url, options: .mappedIfSafe), data.count <= Self.stillBytes else { continue }
                        let name = Self.name(of: still.time)
                        _ = try HomeFile.create(data, named: name, in: [Self.folder], under: home)
                        lines.append(PhoneTool.line(["\(Self.guestHome)/\(Self.folder)/\(name)", Self.stamp(still.time), Self.age(of: still.time, now: now)]))
                    }
                    guard lines.count > 1 else { throw ToolFailure("no still could be read: they went as they were being read, or the phone is locked. Look again once it is unlocked") }
                    return ToolReply(status: ToolReply.ok, text: lines.joined(separator: "\n") + "\n")
                }
            }.value
        }
    }

    static func status(live: ScreenStore.Live?, stills: [ScreenStore.Still], now: Date) -> String {
        let sharing = live.map { "sharing since \(stamp($0.since))" } ?? "not sharing now; the stills are from the last share"
        let newest = stills.last.map { "newest \(age(of: $0.time, now: now))" }
        return PhoneTool.line([sharing, "\(stills.count) still\(stills.count == 1 ? "" : "s")", newest])
    }

    /// The name a still is copied under: when it was kept, in UTC, to the millisecond.
    static func name(of time: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter.string(from: time) + ".jpg"
    }

    static func stamp(_ time: Date) -> String {
        time.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeZone(separator: .omitted))
    }

    static func age(of time: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(time).rounded()))
        return seconds < 120 ? "\(seconds) s ago" : "\(seconds / 60) min ago"
    }
}
