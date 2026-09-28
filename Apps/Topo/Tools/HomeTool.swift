import Foundation
import HomeKit
import TopoTools

/// A characteristic's value as `topo home` reads and writes it.
enum HomeValue: Sendable, Equatable, CustomStringConvertible {
    case bool(Bool)
    case int(Int)
    case number(Double)
    case text(String)

    var description: String {
        switch self {
        case let .bool(value): value ? "true" : "false"
        case let .int(value): String(value)
        case let .number(value): HomeCharacteristic.number(value)
        case let .text(value): PhoneTool.flat(value)
        }
    }
}

struct HomeCharacteristic: Sendable, Equatable {
    var id: String
    /// Short and stable (`power`, `brightness`, `target-temperature`), from `HomeNames`.
    var name: String
    /// HomeKit's metadata format: `bool`, `int`, `float`, `string`, `uint8` … `uint64`, `data`, `tlv8`.
    var format: String
    var readable: Bool
    var writable: Bool
    /// The bounds, step and valid values are `Decimal`, which holds a whole number of any format
    /// exactly: a `Double` would take 2^53 + 1 for 2^53.
    var minimum: Decimal?
    var maximum: Decimal?
    var step: Decimal?
    /// The only values it takes, when HomeKit names them: a condition on top of the range and step.
    var validValues: [Decimal]?
    var maxLength: Int?
    var units: String?
    /// HomeKit's cached value, nil when it holds none.
    var value: HomeValue?
    /// HomeKit's characteristic type (`HMCharacteristicTypeTargetLockMechanismState` …), which
    /// the short name is made from.
    var type = ""

    /// Integer formats, and the bounds of each: a `uint64` past `Int.max` is one `topo home` neither
    /// reads nor writes.
    static let integerBounds: [String: ClosedRange<Decimal>] = [
        "int": Decimal(Int32.min)...Decimal(Int32.max), "uint8": 0...Decimal(UInt8.max),
        "uint16": 0...Decimal(UInt16.max), "uint32": 0...Decimal(UInt32.max), "uint64": 0...Decimal(Int.max),
    ]

    var isInteger: Bool { Self.integerBounds[format] != nil }
    /// Writable and not a name: `topo home` renames nothing, whatever HomeKit would allow.
    var settable: Bool { writable && !HomeNames.names.contains(name) }
    /// A format `topo home` reads and writes; the others (data, TLV8) are shown by their format alone.
    var isPlain: Bool { isInteger || ["bool", "float", "string"].contains(format) }
    /// The tighter of the metadata's bound and the format's.
    var lower: Decimal? {
        let bound = Self.integerBounds[format]?.lowerBound
        guard let minimum else { return bound }
        return bound.map { Swift.max($0, minimum) } ?? minimum
    }
    var upper: Decimal? {
        let bound = Self.integerBounds[format]?.upperBound
        guard let maximum else { return bound }
        return bound.map { Swift.min($0, maximum) } ?? maximum
    }

    /// Whether `number` is one it takes: within the bounds, on the step counted from the lower
    /// bound, and among the valid values when HomeKit names some. A switch is judged as 0 and 1.
    func takes(_ number: Decimal) -> Bool {
        if let lower, number < lower { return false }
        if let upper, number > upper { return false }
        if let step, step > 0 {
            var steps = (number - (lower ?? 0)) / step, whole = Decimal()
            NSDecimalRound(&whole, &steps, 0, .plain)
            if whole != steps { return false }
        }
        if let validValues, !validValues.contains(number) { return false }
        return true
    }

    /// What it takes, in words: "a whole number from 0 to 100 in steps of 1 (%)". Where HomeKit
    /// names valid values it says them too, and only those the range and step also allow, so a
    /// refusal never names the value it refused as one it takes.
    var range: String {
        var text: String
        switch format {
        case "bool":
            let allowed = [(Decimal(0), "off"), (Decimal(1), "on")].filter { takes($0.0) }.map(\.1)
            return allowed.count == 2 ? "on or off (true or false)"
                : allowed.isEmpty ? "on or off, though HomeKit allows neither here" : "only \(allowed[0]) here"
        case "string": return "text" + (maxLength.map { " of at most \($0) characters" } ?? "")
        case "float": text = "a number"
        default: text = isInteger ? "a whole number" : "a \(format) value"
        }
        switch (lower, upper) {
        case let (lower?, upper?): text += " from \(lower) to \(upper)"
        case let (lower?, nil): text += " of at least \(lower)"
        case let (nil, upper?): text += " of at most \(upper)"
        case (nil, nil): break
        }
        if let step, step > 0 { text += " in steps of \(step)" }
        if let validValues {
            let allowed = validValues.filter(takes).map { "\($0)" }
            text += allowed.isEmpty ? ", though none of the values HomeKit names for it fits that"
                : ", and of those only " + (allowed.count == 1 ? allowed[0]
                    : allowed.dropLast().joined(separator: ", ") + " or " + allowed.last!)
        }
        return text + unitsNote
    }

    private var unitsNote: String { units.map { " (\($0))" } ?? "" }

    static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(format: "%g", value)
    }
}

struct HomeService: Sendable, Equatable {
    var name: String
    /// HomeKit's name for what it is: "Lightbulb", "Outlet".
    var kind: String
    /// Accessory Information: the accessory's maker, model and firmware, left out of the listing.
    var isInformation = false
    var characteristics: [HomeCharacteristic]
}

struct HomeAccessory: Sendable, Equatable {
    var id: String
    var name: String
    var room: String
    var category: String
    var reachable: Bool
    var services: [HomeService]
}

struct HomeScene: Sendable, Equatable {
    var id: String
    var name: String
    /// The HomeKit types of the characteristics running it writes, so a scene that unlocks a door
    /// can be refused where setting that characteristic is (`HomeTool.refusing`). An action that
    /// is not a characteristic write is `unknownAction`, which the widgets refuse, since what it
    /// does cannot be read.
    var writes: [String] = []

    static let unknownAction = "unknown-action"
}

struct HomeRecord: Sendable, Equatable {
    var id: String
    var name: String
    var primary: Bool
    var accessories: [HomeAccessory]
    var scenes: [HomeScene]
}

/// What a `HomeStore` tells its owner has changed.
enum HomeChange: Sendable {
    case authorization, homes
}

/// HomeKit once its manager exists: `HomeKitStore` on the phone, a fake in the suites. Making one
/// is what raises HomeKit's prompt, so only `HomeAccess` makes one, on the first call that needs it.
@MainActor
protocol HomeStore: AnyObject {
    var authorization: HMHomeManagerAuthorizationStatus { get }
    /// Called on every update of the authorization or the homes.
    var changed: (@MainActor (HomeChange) -> Void)? { get set }
    /// Every home as HomeKit holds it now.
    func homes() -> [HomeRecord]
    /// A characteristic's value read from the accessory.
    func read(_ characteristic: String) async throws -> HomeValue?
    func write(_ value: HomeValue, to characteristic: String) async throws
    func run(scene: String) async throws
}

/// The one way to HomeKit: its store made on the first call that needs it and never at launch, and
/// the two waits that follow making one. The authorization is known only once the person has
/// answered the prompt (or HomeKit says they did long ago), and the homes only once HomeKit has
/// loaded them; a read before that is an empty list, which would say "no home" of a home that is
/// there. Both waits end when the call they are for is cancelled.
@MainActor
final class HomeAccess {
    private let make: @MainActor () -> any HomeStore
    private var store: (any HomeStore)?
    private var homesLoaded = false
    private var waiting: [UUID: (gate: Gate, continuation: CheckedContinuation<Void, any Error>)] = [:]

    enum Gate {
        case determined, loaded
    }

    init(make: @escaping @MainActor () -> any HomeStore) {
        self.make = make
    }

    /// Where the permission stands, without making the store: until one is made it is not known,
    /// and the call that asks makes it.
    var access: Access {
        guard let store else { return .undetermined }
        let status = store.authorization
        if status.contains(.authorized) { return .granted }
        if status.contains(.restricted) { return .restricted }
        return status.contains(.determined) ? .denied : .undetermined
    }

    /// Makes the store, which raises the prompt if the person has never answered it, and answers
    /// whether HomeKit is allowed once the answer is known.
    func request() async -> Bool {
        do {
            try await wait(for: .determined)
        } catch {
            return false
        }
        return made().authorization.contains(.authorized)
    }

    /// The homes HomeKit has already loaded with access granted, primary first, or nil: it never
    /// makes the store and never waits, so it asks the person nothing. What a widget's `run`
    /// action is judged against when it is set (`WidgetTool`).
    var loadedHomes: [HomeRecord]? {
        guard let store, homesLoaded, store.authorization.contains(.authorized) else { return nil }
        var homes = store.homes()
        homes.sort { $0.primary && !$1.primary }
        return homes
    }

    /// Every home, primary first, once HomeKit has loaded them.
    func homes() async throws -> [HomeRecord] {
        try await wait(for: .loaded)
        var homes = made().homes()
        homes.sort { $0.primary && !$1.primary }
        return homes
    }

    func read(_ characteristic: String) async throws -> HomeValue? {
        try await made().read(characteristic)
    }

    /// The write, unless the call was cancelled first: a call answered at the bound writes nothing.
    func write(_ value: HomeValue, to characteristic: String) async throws {
        try Task.checkCancellation()
        try await made().write(value, to: characteristic)
    }

    func run(scene: String) async throws {
        try Task.checkCancellation()
        try await made().run(scene: scene)
    }

    private func made() -> any HomeStore {
        if let store { return store }
        let store = make()
        self.store = store
        store.changed = { [weak self] change in self?.update(change) }
        return store
    }

    private func passed(_ gate: Gate) -> Bool {
        switch gate {
        // Restricted is an answer the person never gives, so it may come without `.determined`.
        // Only the status answers: homes loaded while it is still undetermined say nothing of
        // what the person will choose, so the call waits on, to the service's bound.
        case .determined: !made().authorization.isDisjoint(with: [.determined, .restricted])
        case .loaded: homesLoaded
        }
    }

    private func update(_ change: HomeChange) {
        if change == .homes { homesLoaded = true }
        // Access taken away: whatever homes HomeKit reported before are not the ones it will
        // report once access is back, so the next call waits for a fresh update. A status still
        // undetermined has taken nothing away.
        let status = made().authorization
        if change == .authorization, !status.contains(.authorized), !status.isDisjoint(with: [.determined, .restricted]) {
            homesLoaded = false
        }
        for (id, waiter) in waiting where passed(waiter.gate) {
            waiting[id] = nil
            waiter.continuation.resume()
        }
    }

    private func wait(for gate: Gate) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if passed(gate) {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting[id] = (gate, continuation)
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        waiting.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}

/// `topo home`: the person's HomeKit home — list it, read one accessory, write one characteristic
/// of one accessory, run one scene. Nothing is added, removed, renamed, paired or unpaired, and no
/// call names more than one target.
struct HomeTool: Tool {
    let home: HomeAccess
    let authorizer: any Authorizer
    let broker: PermissionBroker
    /// How long one read of an accessory is waited on before its value is said as `?`.
    var readBound: Duration = .seconds(4)
    /// Characteristics this tool refuses to set however the call names them, by short name or by
    /// HomeKit type: the widgets' tool table refuses a lock's and a garage door's target state
    /// (`widgetRefused`); the guest's refuses none.
    var refusing: Set<String> = []

    /// What a widget's `run` may not set: the short names `WidgetAction` refuses before the call
    /// is resolved, the HomeKit types, so a renamed short name cannot let one through, and a
    /// scene action that cannot be read, so a scene fails closed.
    static let widgetRefused: Set<String> = WidgetAction.refusedCharacteristics
        .union([HMCharacteristicTypeTargetLockMechanismState, HMCharacteristicTypeTargetDoorState, HomeScene.unknownAction])

    let name = "home"
    let summary = "the lights, locks, thermostats and scenes of the person's home (HomeKit)"
    let usage = """
    topo home                           every accessory, by room: id first, then room, name, kind, whether it answers,
                                        and what can be set on it with the values worth knowing
    topo home get ID                    one accessory: every characteristic, what it takes, whether it can be set, and every plain one's value
    topo home set ID CHARACTERISTIC VALUE
                                        write one characteristic of one accessory (brightness, power, target-temperature…,
                                        or the characteristic's id); answers the value read back
    topo home scenes                    the scenes, id first
    topo home scene ID                  run one

    An id may be shortened to any start of it that fits one thing. VALUE is on or off (true or
    false) for a switch, a number for a level, within what `topo home get` says it takes.
    """

    enum Call: Equatable {
        case list
        case get(String)
        case set(String, characteristic: String, value: String)
        case scenes
        case scene(String)
    }

    func run(_ arguments: [String]) async -> ToolReply {
        await PhoneTool.run(authorizer, broker: broker, usage: usage, parse: { try parse(arguments) }) { call in
            let homes = try await home.homes()
            guard !homes.isEmpty else {
                throw ToolFailure("no home is set up on this phone; the person sets one up in the Home app")
            }
            switch call {
            case .list:
                return .ok(await list(homes))
            case let .get(id):
                return .ok(await show(try accessory(id, in: homes)))
            case let .set(id, name, text):
                let accessory = try accessory(id, in: homes)
                let characteristic = try Self.characteristic(name, of: accessory)
                try Self.admit(characteristic, of: accessory, refusing: refusing)
                let value = try Self.judge(text, for: characteristic, of: accessory)
                try await home.write(value, to: characteristic.id)
                let back = await read(characteristic.id)
                return .ok(PhoneTool.line([accessory.name, characteristic.name, back?.description ?? "? (written; reading it back failed)"]) + "\n")
            case .scenes:
                let lines = homes.flatMap { home in
                    home.scenes.map { PhoneTool.line([$0.id, $0.name, homes.count > 1 ? home.name : nil]) }
                }
                return .ok(PhoneTool.lines(lines, none: "no scenes"))
            case let .scene(id):
                let scene = try Self.one(id, among: homes.flatMap(\.scenes), id: \.id, name: \.name, kind: "scene")
                try Self.admit(scene, refusing: refusing)
                try await home.run(scene: scene.id)
                return .ok("ran: \(PhoneTool.line([scene.id, scene.name]))\n")
            }
        }
    }

    /// The call the arguments make, or why they make none: nothing here needs the permission.
    func parse(_ arguments: [String]) throws -> Call {
        let words = try Arguments(arguments).words
        switch (words.first, words.count) {
        case (nil, _): return .list
        case ("get", 2): return .get(words[1])
        case ("set", 4): return .set(words[1], characteristic: words[2], value: words[3])
        case ("scenes", 1): return .scenes
        case ("scene", 2): return .scene(words[1])
        default: throw Misuse("home takes nothing, get ID, set ID CHARACTERISTIC VALUE, scenes, or scene ID")
        }
    }

    // MARK: Reading

    /// The characteristics worth a read in the listing.
    static let summarised: Set<String> = ["power", "brightness", "hue", "saturation", "target-temperature", "lock", "lock-state"]

    private func list(_ homes: [HomeRecord]) async -> String {
        let reads = homes.flatMap(\.accessories).filter(\.reachable)
            .flatMap(\.services).filter { !$0.isInformation }.flatMap(\.characteristics)
            .filter { $0.readable && $0.isPlain && Self.summarised.contains($0.name) }.map(\.id)
        let values = await read(reads)
        var lines: [String] = []
        for record in homes {
            lines.append("home: \(PhoneTool.flat(record.name))" + (record.primary ? " (primary)" : ""))
            let accessories = record.accessories.sorted { ($0.room, $0.name) < ($1.room, $1.name) }
            if accessories.isEmpty { lines.append("no accessories") }
            for accessory in accessories {
                let services = accessory.services.filter { !$0.isInformation }.compactMap { service -> String? in
                    let settable = service.characteristics.filter { $0.settable && $0.isPlain && $0.name != "identify" }
                    guard !settable.isEmpty else { return nil }
                    let parts = settable.map { characteristic in
                        guard Self.summarised.contains(characteristic.name), characteristic.readable else { return characteristic.name }
                        return "\(characteristic.name) \(values[characteristic.id]?.description ?? "?")"
                    }
                    return "\(PhoneTool.flat(service.name)): " + parts.joined(separator: ", ")
                }
                lines.append(PhoneTool.line([accessory.id, accessory.room, accessory.name, accessory.category,
                                             accessory.reachable ? "reachable" : "not reachable"] + services))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func show(_ accessory: HomeAccessory) async -> String {
        let readable = accessory.reachable
            ? accessory.services.flatMap(\.characteristics).filter { $0.readable && $0.isPlain }.map(\.id) : []
        let values = await read(readable)
        var lines = [PhoneTool.line([accessory.id, accessory.room, accessory.name, accessory.category,
                                     accessory.reachable ? "reachable" : "not reachable"])]
        for service in accessory.services {
            lines.append("service: " + PhoneTool.line([service.name, service.kind]))
            for characteristic in service.characteristics {
                let value: String
                if !characteristic.isPlain {
                    value = "(\(characteristic.format))"
                } else if !characteristic.readable {
                    value = "(not readable)"
                } else {
                    value = values[characteristic.id]?.description ?? "?"
                }
                let access = !characteristic.writable ? "read only"
                    : !characteristic.settable ? "a name, which topo home does not change"
                    : !characteristic.isPlain ? "a \(characteristic.format) value, which topo home does not set"
                    : characteristic.readable ? "can be set" : "can be set, not read"
                lines.append("  " + PhoneTool.line([characteristic.id, characteristic.name, value, characteristic.range, access]))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Each read at once, each bounded, a failed or late one left out.
    private func read(_ ids: [String]) async -> [String: HomeValue] {
        await withTaskGroup(of: (String, HomeValue?).self) { group in
            for id in ids { group.addTask { (id, await read(id)) } }
            var values: [String: HomeValue] = [:]
            for await (id, value) in group { values[id] = value }
            return values
        }
    }

    private func read(_ id: String) async -> HomeValue? {
        let home = home
        return await PhoneTool.within(readBound) { (try? await home.read(id)) ?? nil }
    }

    // MARK: Finding

    private func accessory(_ id: String, in homes: [HomeRecord]) throws -> HomeAccessory {
        try Self.accessory(id, in: homes)
    }

    static func accessory(_ id: String, in homes: [HomeRecord]) throws -> HomeAccessory {
        try one(id, among: homes.flatMap(\.accessories), id: \.id, name: \.name, kind: "accessory")
    }

    /// Refuses a characteristic this tool does not set, by the short name it resolved to.
    static func admit(_ characteristic: HomeCharacteristic, of accessory: HomeAccessory, refusing: Set<String>) throws {
        guard refusing.contains(characteristic.name) || refusing.contains(characteristic.type) else { return }
        throw ToolFailure("\(accessory.name) \(characteristic.name) is not a widget's to set; a lock or a door goes through a turn",
                          status: ToolReply.refused)
    }

    /// Refuses a scene that writes a characteristic this tool does not set, or holds an action
    /// that cannot be read.
    static func admit(_ scene: HomeScene, refusing: Set<String>) throws {
        let refused = refusing.intersection(scene.writes)
        guard !refused.isEmpty else { return }
        if refused == [HomeScene.unknownAction] {
            throw ToolFailure("the scene \(scene.name) holds an action that cannot be read, which is not a widget's to run; run it through a turn",
                              status: ToolReply.refused)
        }
        throw ToolFailure("the scene \(scene.name) sets a lock or a door, which is not a widget's to run; a lock or a door goes through a turn",
                          status: ToolReply.refused)
    }

    /// A `set` or `scene` call judged against homes already loaded, the way the call itself would
    /// judge it, with nothing written and nothing run.
    static func judge(_ call: Call, in homes: [HomeRecord], refusing: Set<String>) throws {
        switch call {
        case let .set(id, name, text):
            let accessory = try accessory(id, in: homes)
            let characteristic = try characteristic(name, of: accessory)
            try admit(characteristic, of: accessory, refusing: refusing)
            _ = try judge(text, for: characteristic, of: accessory)
        case let .scene(id):
            try admit(one(id, among: homes.flatMap(\.scenes), id: \.id, name: \.name, kind: "scene"), refusing: refusing)
        case .list, .get, .scenes:
            break
        }
    }

    /// The one thing whose id is `text` or starts with it. None is a failure; more than one is a
    /// call to make again with more of the id, naming each.
    static func one<T>(_ text: String, among all: [T], id: KeyPath<T, String>, name: KeyPath<T, String>, kind: String) throws -> T {
        let key = text.lowercased()
        if let exact = all.first(where: { $0[keyPath: id].lowercased() == key }) { return exact }
        let found = all.filter { $0[keyPath: id].lowercased().hasPrefix(key) }
        guard !found.isEmpty, !key.isEmpty else { throw ToolFailure("no \(kind) with the id \(text)") }
        guard found.count == 1 else {
            let each = found.map { "\($0[keyPath: id]) \(PhoneTool.flat($0[keyPath: name]))" }.joined(separator: "; ")
            throw ToolFailure("\(text) starts the id of more than one \(kind): \(each); give more of it", status: ToolReply.usage)
        }
        return found[0]
    }

    /// One characteristic of the accessory, by its short name or its id. A name more than one of
    /// its services carry (each outlet of a strip has its own `power`) is refused, naming each id.
    static func characteristic(_ text: String, of accessory: HomeAccessory) throws -> HomeCharacteristic {
        let all = accessory.services.flatMap { service in service.characteristics.map { (service, $0) } }
        let named = all.filter { $0.1.name == text.lowercased() }
        if named.count == 1 { return named[0].1 }
        if named.count > 1 {
            let each = named.map { "\($0.1.id) (\(PhoneTool.flat($0.0.name)))" }.joined(separator: "; ")
            throw ToolFailure("\(accessory.name) has more than one \(text): \(each); name one by its id", status: ToolReply.usage)
        }
        do {
            return try one(text, among: all.map(\.1), id: \.id, name: \.name, kind: "characteristic")
        } catch let failure as ToolFailure where failure.status == ToolReply.failed {
            throw ToolFailure("\(accessory.name) has no characteristic \(text); `topo home get \(accessory.id)` lists them", status: ToolReply.usage)
        }
    }

    /// `text` as the value `characteristic` takes, or a refusal saying what it takes. Nothing is
    /// written unless this answers.
    static func judge(_ text: String, for characteristic: HomeCharacteristic, of accessory: HomeAccessory) throws -> HomeValue {
        let what = "\(accessory.name) \(characteristic.name)"
        func refuse(_ why: String) -> ToolFailure {
            ToolFailure("\(what) \(why); nothing was written", status: ToolReply.usage)
        }
        guard characteristic.writable else { throw refuse("is read only") }
        guard characteristic.settable else { throw refuse("is a name, and topo home renames nothing") }
        let takes = "takes \(characteristic.range), not \(text)"
        switch characteristic.format {
        case "bool":
            let value: Bool
            switch text.lowercased() {
            case "on", "true", "1": value = true
            case "off", "false", "0": value = false
            default: throw refuse(takes)
            }
            guard characteristic.takes(value ? 1 : 0) else { throw refuse(takes) }
            return .bool(value)
        case "string":
            // Length is the only bound HomeKit's metadata gives a string.
            if let maxLength = characteristic.maxLength, text.count > maxLength { throw refuse(takes) }
            return .text(text)
        case "float":
            guard let number = Double(text), number.isFinite, let exact = Decimal(string: text),
                  characteristic.takes(exact) else { throw refuse(takes) }
            return .number(number)
        default:
            guard characteristic.isInteger else { throw refuse("is a \(characteristic.format) value, which topo home does not write") }
            if Int(text) == nil, UInt64(text) != nil {
                throw refuse("takes a value above \(Int.max), which topo home does not write")
            }
            guard let number = Int(text), characteristic.takes(Decimal(number)) else { throw refuse(takes) }
            return .int(number)
        }
    }
}

struct HomeAuthorizer: Authorizer {
    let name = "HomeKit"
    let home: HomeAccess

    func access() async -> Access { await home.access }
    func request() async -> Bool { await home.request() }
}

// MARK: HomeKit

/// `HMHomeManager` and its delegate. Making one raises HomeKit's prompt if the person has never
/// answered it; the delegate hears the answer and the homes loading, on the main queue. HomeKit's
/// reads, writes and scenes answer on blocks of their own, awaited through continuations, and each
/// block is `@Sendable` since HomeKit may call it off the main thread.
@MainActor
final class HomeKitStore: NSObject, HomeStore, HMHomeManagerDelegate {
    private let manager = HMHomeManager()
    var changed: (@MainActor (HomeChange) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var authorization: HMHomeManagerAuthorizationStatus { manager.authorizationStatus }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        Task { @MainActor in self.changed?(.authorization) }
    }

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in self.changed?(.homes) }
    }

    func homes() -> [HomeRecord] {
        manager.homes.map { home in
            HomeRecord(id: home.uniqueIdentifier.uuidString, name: home.name, primary: home.isPrimary,
                       accessories: home.accessories.map(Self.record),
                       scenes: home.actionSets.map { set in
                           HomeScene(id: set.uniqueIdentifier.uuidString, name: set.name,
                                     writes: set.actions.map {
                                         ($0 as? HMCharacteristicWriteAction<NSCopying>)?.characteristic.characteristicType ?? HomeScene.unknownAction
                                     })
                       })
        }
    }

    func read(_ id: String) async throws -> HomeValue? {
        guard let characteristic = characteristic(id) else { throw ToolFailure("that characteristic is gone") }
        try await Self.answer { done in characteristic.readValue(completionHandler: done) }
        return Self.value(characteristic.value, format: characteristic.metadata?.format)
    }

    func write(_ value: HomeValue, to id: String) async throws {
        guard let characteristic = characteristic(id) else { throw ToolFailure("that characteristic is gone") }
        let object: Any = switch value {
        case let .bool(bool): NSNumber(value: bool)
        case let .int(int): NSNumber(value: int)
        case let .number(number): NSNumber(value: number)
        case let .text(text): text as NSString
        }
        try await Self.answer { done in characteristic.writeValue(object, completionHandler: done) }
    }

    func run(scene id: String) async throws {
        for home in manager.homes {
            if let actionSet = home.actionSets.first(where: { $0.uniqueIdentifier.uuidString == id }) {
                try await Self.answer { done in home.executeActionSet(actionSet, completionHandler: done) }
                return
            }
        }
        throw ToolFailure("that scene is gone")
    }

    private func characteristic(_ id: String) -> HMCharacteristic? {
        for home in manager.homes {
            for accessory in home.accessories {
                for service in accessory.services {
                    if let found = service.characteristics.first(where: { $0.uniqueIdentifier.uuidString == id }) { return found }
                }
            }
        }
        return nil
    }

    /// A HomeKit call that answers on a block, awaited.
    private static func answer(_ call: (@escaping @Sendable ((any Error)?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            call { @Sendable error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func record(_ accessory: HMAccessory) -> HomeAccessory {
        HomeAccessory(
            id: accessory.uniqueIdentifier.uuidString, name: accessory.name, room: accessory.room?.name ?? "",
            category: accessory.category.localizedDescription, reachable: accessory.isReachable,
            services: accessory.services.map { service in
                HomeService(name: service.name, kind: service.localizedDescription,
                            isInformation: service.serviceType == HMServiceTypeAccessoryInformation,
                            characteristics: service.characteristics.map(record))
            })
    }

    private static func record(_ characteristic: HMCharacteristic) -> HomeCharacteristic {
        let metadata = characteristic.metadata
        let format = metadata?.format ?? "data"
        return HomeCharacteristic(
            id: characteristic.uniqueIdentifier.uuidString,
            name: HomeNames.name(type: characteristic.characteristicType, description: characteristic.localizedDescription),
            format: format,
            readable: characteristic.properties.contains(HMCharacteristicPropertyReadable),
            writable: characteristic.properties.contains(HMCharacteristicPropertyWritable),
            minimum: metadata?.minimumValue?.decimalValue, maximum: metadata?.maximumValue?.decimalValue,
            step: metadata?.stepValue?.decimalValue, validValues: metadata?.validValues?.map(\.decimalValue),
            maxLength: metadata?.maxLength?.intValue, units: metadata?.units.map(HomeNames.units),
            value: value(characteristic.value, format: format), type: characteristic.characteristicType)
    }

    /// A `uint64` above `Int.max` has no `HomeValue`, so it reads as `?` rather than as a wrong number.
    static func value(_ value: Any?, format: String?) -> HomeValue? {
        switch (format, value) {
        case let ("uint64", number as NSNumber) where number.uint64Value > UInt64(Int.max): nil
        case let ("bool", number as NSNumber): .bool(number.boolValue)
        case let ("float", number as NSNumber): .number(number.doubleValue)
        case let ("string", text as String): .text(text)
        case let (format?, number as NSNumber) where HomeCharacteristic.integerBounds[format] != nil: .int(number.intValue)
        default: nil
        }
    }
}

/// The short names `topo home` gives HomeKit's characteristics, so `set` can name one the way a
/// person would; any other is its own description, lower-cased and hyphenated.
enum HomeNames {
    static let known: [String: String] = [
        HMCharacteristicTypePowerState: "power",
        HMCharacteristicTypeBrightness: "brightness",
        HMCharacteristicTypeHue: "hue",
        HMCharacteristicTypeSaturation: "saturation",
        HMCharacteristicTypeColorTemperature: "color-temperature",
        HMCharacteristicTypeTargetTemperature: "target-temperature",
        HMCharacteristicTypeCurrentTemperature: "current-temperature",
        HMCharacteristicTypeTargetHeatingCooling: "target-mode",
        HMCharacteristicTypeCurrentHeatingCooling: "current-mode",
        HMCharacteristicTypeTargetLockMechanismState: "lock",
        HMCharacteristicTypeCurrentLockMechanismState: "lock-state",
        HMCharacteristicTypeTargetPosition: "target-position",
        HMCharacteristicTypeCurrentPosition: "current-position",
        HMCharacteristicTypeActive: "active",
        HMCharacteristicTypeRotationSpeed: "speed",
        HMCharacteristicTypeCurrentRelativeHumidity: "humidity",
        HMCharacteristicTypeOutletInUse: "in-use",
        HMCharacteristicTypeIdentify: "identify",
        HMCharacteristicTypeName: "name",
        // HMCharacteristicTypeConfiguredName, which the SDK names only from iOS 18: HAP's own type.
        "000000E3-0000-1000-8000-0026BB765291": "configured-name",
    ]

    /// The names `set` refuses, whatever the characteristic's metadata says.
    static let names: Set<String> = ["name", "configured-name"]

    static func name(type: String, description: String) -> String {
        known[type] ?? description.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
    }

    static func units(_ units: String) -> String {
        switch units {
        case HMCharacteristicMetadataUnitsCelsius: "°C"
        case HMCharacteristicMetadataUnitsFahrenheit: "°F"
        case HMCharacteristicMetadataUnitsPercentage: "%"
        case HMCharacteristicMetadataUnitsArcDegree: "degrees"
        default: units
        }
    }
}
