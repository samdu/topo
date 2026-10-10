#if os(iOS)
import Foundation

/// Why the screen is not being kept, in words the system's broadcast sheet shows the person.
enum ScreenRefusal: Error, Equatable {
    /// No door, or not the door the broadcast began under: signed out, or not the guest's phone.
    case signedOut

    var words: String {
        switch self {
        case .signedOut: "Open Topo on the phone it lives on and sign in first."
        }
    }
}

/// The stills of the person's screen that the broadcast extension keeps for the mind to look at:
/// the `Screen` folder in the app group, which the extension writes and the app reads.
///
/// - `_open.json`, there while this phone is signed in and is the guest's, naming the login. The
///   extension keeps nothing without it;
/// - `_live.json`, there while a broadcast runs: when it began, and when the extension last saw
///   a frame;
/// - `<login>-<milliseconds>.jpg`, one still, named for the login it was kept under and when.
///
/// Only the app makes the folder, and a sign-out removes it, the door first, so the extension
/// never brings it back: a still written after the folder went fails, one that lands as the door
/// goes is taken away by whichever of the two sees the other last, and one written under a login
/// that has since ended carries that login's name and is no still of the next. At most `ring`
/// are held, the oldest going first. The stills are the person's whole screen, so they are
/// readable only while the phone is unlocked and are left out of its backups.
struct ScreenStore: Sendable {
    static let appGroup = "group.zone.hexagon.topo"
    /// The most stills held.
    static let ring = 30
    /// A broadcast whose extension has seen no frame for this long is over, however it ended.
    static let stale: TimeInterval = 15

    let folder: URL

    init(folder: URL) {
        self.folder = folder
    }

    /// The app group's folder, or nil where the process has no app group (an unsigned build).
    static func shared() -> ScreenStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map { ScreenStore(folder: $0.appendingPathComponent("Screen", isDirectory: true)) }
    }

    struct Door: Codable, Equatable, Sendable {
        /// This login, named afresh each time the door is opened from shut.
        var login: String
    }

    struct Live: Codable, Equatable, Sendable {
        var login: String
        var since: Date
        /// When the extension last saw a frame.
        var beat: Date
    }

    struct Still: Equatable, Sendable {
        var time: Date
        var url: URL
    }

    private var doorURL: URL { folder.appendingPathComponent("_open.json") }
    private var liveURL: URL { folder.appendingPathComponent("_live.json") }

    // MARK: The app's side

    /// Signed in on the guest's phone: a broadcast is taken from now on. A door already open
    /// keeps its login.
    func open() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = folder
        try? folder.setResourceValues(values)
        guard door() == nil else { return }
        try JSONEncoder().encode(Door(login: UUID().uuidString))
            .write(to: doorURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Signed out, or no longer the guest's phone: no still is kept, and none stays.
    ///
    /// The door goes first: a still the extension links after that finds no door when it looks
    /// again and takes itself away, and one linked before is in the folder this removes. A still
    /// landing while the folder is being emptied leaves it not empty, so the removal is tried
    /// again.
    func close() {
        try? FileManager.default.removeItem(at: doorURL)
        for _ in 0..<Self.closes {
            try? FileManager.default.removeItem(at: folder)
            guard FileManager.default.fileExists(atPath: folder.path) else { return }
        }
    }

    /// How many times a removal that a landing still got in the way of is tried.
    static let closes = 3

    /// Follows the login and the role: open while this phone is signed in and the guest's, shut
    /// otherwise, a launch that finds either gone included.
    func follow(owner: Bool) {
        if owner { try? open() } else { close() }
    }

    func door() -> Door? {
        (try? Data(contentsOf: doorURL)).flatMap { try? JSONDecoder().decode(Door.self, from: $0) }
    }

    /// The broadcast running now, or nil: none began, it ended, or its extension has seen no
    /// frame for `stale`.
    func live(now: Date = Date()) -> Live? {
        guard let door = door(),
              let live = (try? Data(contentsOf: liveURL)).flatMap({ try? JSONDecoder().decode(Live.self, from: $0) }),
              live.login == door.login, now.timeIntervalSince(live.beat) < Self.stale else { return nil }
        return live
    }

    /// The stills of this login, oldest first.
    func stills() -> [Still] {
        guard let door = door() else { return [] }
        return stills(of: door)
    }

    private func stills(of door: Door) -> [Still] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name -> Still? in
            guard let time = Self.time(of: name, login: door.login) else { return nil }
            return Still(time: time, url: folder.appendingPathComponent(name))
        }
        .sorted { $0.time < $1.time }
    }

    static func name(login: String, at time: Date) -> String {
        "\(login)-\(Int64((time.timeIntervalSince1970 * 1000).rounded())).jpg"
    }

    /// When the still of that name was kept, or nil for a name that is no still of `login`.
    static func time(of name: String, login: String) -> Date? {
        let prefix = login + "-", suffix = ".jpg"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix),
              let milliseconds = Int64(name.dropFirst(prefix.count).dropLast(suffix.count)), milliseconds >= 0 else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    // MARK: The extension's side

    /// A broadcast beginning: answers the door it runs under, with the last broadcast's stills
    /// gone and this one marked live. Refused where there is no door.
    func begin(at now: Date = Date()) throws(ScreenRefusal) -> Door {
        guard let door = door() else { throw .signedOut }
        clearStills()
        guard beat(at: now, since: now, under: door) else { throw .signedOut }
        return door
    }

    /// Marks the broadcast as running at `now`. Answers false where the door is no longer the
    /// one it began under, which is when the broadcast ends.
    @discardableResult
    func beat(at now: Date, since: Date, under door: Door) -> Bool {
        guard self.door() == door else { return false }
        let live = Live(login: door.login, since: since, beat: now)
        // A write refused here is the phone locked or the folder gone; the door says which.
        try? JSONEncoder().encode(live).write(to: liveURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return self.door() == door
    }

    /// Keeps one still, answering whether it was kept. Refused where the door is no longer the
    /// one the broadcast began under. A write that fails with the door still there is the phone
    /// locked, and that frame is dropped.
    ///
    /// The still is written in the folder under a hidden name and renamed to its own, so no
    /// reader sees half a picture, no copy of it is anywhere else, and the folder is never made.
    /// The door is read again once the still has its name: a sign-out between the first reading
    /// and the rename would otherwise leave a still nothing takes away. `landed` is called between
    /// the rename and that reading, for a suite to shut the door there.
    @discardableResult
    func keep(_ jpeg: Data, at time: Date, under door: Door, landed: () -> Void = {}) throws(ScreenRefusal) -> Bool {
        guard self.door() == door else { throw .signedOut }
        let part = folder.appendingPathComponent(".\(UUID().uuidString).part")
        let still = folder.appendingPathComponent(Self.name(login: door.login, at: time))
        do {
            try jpeg.write(to: part, options: .completeFileProtection)
            try FileManager.default.moveItem(at: part, to: still)
        } catch {
            try? FileManager.default.removeItem(at: part)
            guard self.door() == door else { throw .signedOut }
            return false
        }
        landed()
        guard self.door() == door else {
            try? FileManager.default.removeItem(at: still)
            throw .signedOut
        }
        let held = stills(of: door)
        for still in held.dropLast(Self.ring) { try? FileManager.default.removeItem(at: still.url) }
        return true
    }

    /// The broadcast ended: it is no longer live. Its stills stay for the mind to look at.
    func end() {
        try? FileManager.default.removeItem(at: liveURL)
    }

    /// Takes away every still, of whatever login: the folder is the app group's, which only
    /// Topo's own processes write, and a still is the only thing in it named `.jpg`.
    private func clearStills() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasSuffix(".jpg") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
#endif
