import CoreLocation
import Foundation
import MapKit
import os
import TopoTools

/// A point on the map, as `topo maps` reads and writes one: `37.75990,-122.41480`.
struct MapPoint: Sendable, Equatable {
    var latitude: Double
    var longitude: Double

    /// Nil unless both are finite, the latitude within −90…90 and the longitude within −180…180.
    init?(latitude: Double, longitude: Double) {
        guard latitude.isFinite, longitude.isFinite, (-90.0...90).contains(latitude), (-180.0...180).contains(longitude) else {
            return nil
        }
        self.latitude = latitude
        self.longitude = longitude
    }

    /// `LAT,LON`: two plain decimals and nothing else, so `nan`, `inf`, `1e400`, one number, three
    /// and a place's name are each no point.
    init?(_ text: String) {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let latitude = Self.decimal(parts[0]), let longitude = Self.decimal(parts[1]) else { return nil }
        self.init(latitude: latitude, longitude: longitude)
    }

    private static func decimal(_ text: Substring) -> Double? {
        let digits = text.first == "-" ? text.dropFirst() : text
        let halves = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(halves.count),
              halves.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        return Double(text)
    }

    /// Five decimal places, about a metre.
    var text: String {
        // Adding zero writes a rounded −0 as 0.
        String(format: "%.5f,%.5f", (latitude * 1e5).rounded() / 1e5 + 0, (longitude * 1e5).rounded() / 1e5 + 0)
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    func metres(to other: MapPoint) -> Double {
        CLLocation(latitude: latitude, longitude: longitude).distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}

/// Where a search looks: a centre and a radius in metres.
struct MapRegion: Sendable, Equatable {
    var centre: MapPoint
    var radius: Int
}

struct MapPlace: Sendable, Equatable {
    var name: String?
    var category: String?
    var address: String?
    var point: MapPoint
    var phone: String?
    var url: String?
}

enum MapMode: String, Sendable, CaseIterable {
    case walking, driving, transit
}

struct MapStep: Sendable, Equatable {
    var instruction: String
    /// In metres.
    var distance: Double
}

struct MapRoute: Sendable, Equatable {
    var name: String
    /// In metres.
    var distance: Double
    /// In seconds.
    var expected: TimeInterval
    var notices: [String]
    var steps: [MapStep]
}

struct MapETA: Sendable, Equatable {
    /// In metres.
    var distance: Double
    /// In seconds.
    var expected: TimeInterval
    var depart: Date
    var arrive: Date
}

/// Why Apple Maps gave no answer, as `MapsTool` says it.
enum MapsFailure: Error, Equatable {
    /// No way between the two ends by that mode, with Apple's own words for it when it gave any.
    case noRoute(String?)
    case throttled
    case server(String?)
    /// Nothing came back within the bound, and the request was cancelled.
    case unanswered(Duration)
    case other(String)
}

/// Apple Maps as `topo maps` needs it: `MapKitMaps` on the phone, a fake in the suites. Each
/// answer is a plain value; nothing of MapKit's own crosses it.
@MainActor
protocol MapsStore: AnyObject, Sendable {
    /// Every place Apple Maps gives for `query`, in its order; none is an empty list. With no
    /// region the search is not held to one.
    func search(query: String, region: MapRegion?) async throws -> [MapPlace]
    func route(from: MapPoint, to: MapPoint, mode: MapMode, depart: Date?) async throws -> MapRoute
    func eta(from: MapPoint, to: MapPoint, mode: MapMode, depart: Date?) async throws -> MapETA
}

/// What a wait bounded by `MapsWait.first` ended on.
enum MapsWaited<Value: Sendable>: Sendable {
    case answered(Result<Value, any Error>)
    /// The bound passed first.
    case unanswered
    /// The caller was cancelled first.
    case cancelled
}

enum MapsWait {
    /// Whichever comes first of `work`'s answer, the bound and the caller's cancellation. `work` is
    /// cancelled when it was not first and is never waited on after: one that does not stop when
    /// it is no longer wanted, as a cancelled `MKDirections` does not, holds nothing up.
    static func first<Value: Sendable>(within bound: Duration,
                                       _ work: @escaping @Sendable () async throws -> Value) async -> MapsWaited<Value> {
        // A caller already cancelled starts nothing.
        guard !Task.isCancelled else { return .cancelled }
        let first = FirstAnswer<MapsWaited<Value>>()
        let working = Task {
            // The wait may have ended before this ran: then the work is never begun.
            guard !first.given else { return }
            do {
                first.give(.answered(.success(try await work())))
            } catch {
                first.give(.answered(.failure(error)))
            }
        }
        let timer = Task {
            guard (try? await Task.sleep(for: bound)) != nil else { return }
            first.give(.unanswered)
        }
        let outcome = await withTaskCancellationHandler {
            await first.value()
        } onCancel: {
            first.give(.cancelled)
        }
        timer.cancel()
        if case .answered = outcome { return outcome }
        working.cancel()
        return outcome
    }

    /// `20 s`, or `200 ms` for a bound that is not whole seconds.
    static func written(_ bound: Duration) -> String {
        let parts = bound.components
        if parts.attoseconds == 0 { return "\(parts.seconds) s" }
        return "\(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000) ms"
    }
}

/// The first value given, handed to the one waiting for it; every later one is dropped.
private final class FirstAnswer<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var value: Value?
        var waiting: CheckedContinuation<Value, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func give(_ value: Value) {
        let waiting = state.withLock { state -> CheckedContinuation<Value, Never>? in
            guard state.value == nil else { return nil }
            state.value = value
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume(returning: value)
    }

    var given: Bool { state.withLock { $0.value != nil } }

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            let given = state.withLock { state -> Value? in
                if state.value == nil { state.waiting = continuation }
                return state.value
            }
            if let given { continuation.resume(returning: given) }
        }
    }
}

/// `topo maps`: places, a route and a travel time from Apple Maps, through MapKit. It changes
/// nothing of the person's and reads only where the phone is, and what it sends goes to Apple's
/// servers alone: the search text and its region, both ends of a route, and for `here` where the
/// phone is.
struct MapsTool: Tool {
    let maps: any MapsStore
    let locator: any Locator
    let authorizer: any Authorizer
    let broker: PermissionBroker
    /// How long a location fix is waited on.
    var fixBound: Duration = .seconds(10)
    var now: @Sendable () -> Date = { Date() }

    static let defaultLimit = 10
    static let limits = 1...25
    static let defaultRadius = 5000
    static let radii = 100...50_000
    /// The latitude, north or south, past which a region is refused: nearer a pole than this a
    /// span of longitude no longer makes the square the region is said to be.
    static let squareLatitude = 85.0
    static let stepCap = 40
    static let noticeCap = 5
    /// A text field's cap, in characters and in bytes of UTF-8: four bytes a character at most.
    static let fieldCharacters = 200
    static let fieldBytes = 800
    /// A whole answer's cap, in bytes of UTF-8.
    static let budget = 24 * 1024
    /// The room kept for the last line, which says what was cut.
    static let lastLineRoom = 128

    /// The tool on the phone: Apple Maps through MapKit, and the phone's fix with no place asked
    /// of the geocoder, since no answer carries one.
    @MainActor
    static func standard(permission: LocationPermission, broker: PermissionBroker) -> MapsTool {
        MapsTool(maps: MapKitMaps(), locator: CoreLocationLocator(permission: permission, named: false),
                 authorizer: LocationAuthorizer(permission: permission), broker: broker)
    }

    let name = "maps"
    let summary = "places, routes and travel times (Apple Maps)"
    let usage = """
    topo maps search QUERY [--near LAT,LON] [--radius M] [--anywhere] [--limit N]
                                        places matching QUERY (one argument: quote several words), near the phone
                                        unless --near gives a point or --anywhere lifts the region, which is a
                                        square reaching M metres each way round a centre between latitudes
                                        -85 and 85 (nearer a pole, only --anywhere): M is 100 to 50000 (5000
                                        unless given), N is 1 to 25 (10 unless given)
    topo maps route --to LAT,LON|here [--from LAT,LON|here] [--by walking|driving] [--depart DATE]
                                        one route and its steps
    topo maps eta --to LAT,LON|here [--from LAT,LON|here] [--by walking|driving|transit] [--depart DATE]
                                        the distance and how long it takes

    --from is here and --by is walking unless given. An end is LAT,LON or here, never a name: search
    for the place first and pass its coordinates. Only a call that needs where the phone is (here, or
    a search with neither --near nor --anywhere) asks for Location. DATE has a time of day.

    One record a line, fields apart by " | ", an absent field left empty:
      search  region | here, near or none | LAT,LON | RADIUS_M | approximate or exact | QUERY
              link | URL
              N | name | category | address | LAT,LON | DISTANCE_M | phone | url
      route   route | FROM | TO | by | DISTANCE_M | EXPECTED_S | DEPART | ARRIVE | name
              link | URL
              notice | text
              N | instruction | DISTANCE_M
      eta     eta | FROM | TO | by | DISTANCE_M | EXPECTED_S | DEPART | ARRIVE
              link | URL
    DISTANCE_M of a place is from the region's centre. A last line starting "…" says what was left out.
    The link line is the same search or the same directions in Apple Maps, for the person to tap (a
    search whose QUERY is too long to link whole has none): put
    it in your reply when they would want the map or turn-by-turn. Nothing here opens it. By transit
    it is the only way to the route itself. A --from that was here is left out of it, so it starts
    from wherever the phone is when tapped.
    """

    /// One end of a route.
    enum End: Equatable {
        case here
        case point(MapPoint)
    }

    /// Where a search looks.
    enum Area: Equatable {
        case here(radius: Int)
        case near(MapPoint, radius: Int)
        case anywhere
    }

    enum Call: Equatable {
        case search(query: String, area: Area, limit: Int)
        case route(from: End, to: End, mode: MapMode, depart: Date?)
        case eta(from: End, to: End, mode: MapMode, depart: Date?)

        /// Whether the call needs where the phone is, and so Location.
        var needsHere: Bool {
            switch self {
            case let .search(_, area, _):
                if case .here = area { return true }
                return false
            case let .route(from, to, _, _), let .eta(from, to, _, _):
                return from == .here || to == .here
            }
        }

        /// How the same call runs with Location refused, said after the refusal.
        var withoutHere: String? {
            guard needsHere else { return nil }
            if case .search = self { return "This search can run without it: give --near LAT,LON or --anywhere." }
            return "This can run without it: give each end as LAT,LON rather than here."
        }
    }

    func run(_ arguments: [String]) async -> ToolReply {
        var withoutHere: String?
        let reply = await PhoneTool.run({ $0.needsHere ? authorizer : nil }, broker: broker, usage: usage, parse: {
            let call = try parse(arguments)
            withoutHere = call.withoutHere
            return call
        }) { call in
            switch call {
            case let .search(query, area, limit):
                return .ok(try await search(query, area, limit: limit))
            case let .route(from, to, mode, depart):
                let link = Self.link(from, to, mode)
                let (from, to) = try await ends(from, to)
                let left = depart ?? now()
                do {
                    let route = try await maps.route(from: from, to: to, mode: mode, depart: depart)
                    return .ok(Self.answer(route, from: from, to: to, mode: mode, depart: left, link: link(to)))
                } catch let failure as MapsFailure {
                    throw ToolFailure(Self.sentence(failure, mode: mode, from: from, to: to, depart: left))
                }
            case let .eta(from, to, mode, depart):
                let link = Self.link(from, to, mode)
                let (from, to) = try await ends(from, to)
                do {
                    let eta = try await maps.eta(from: from, to: to, mode: mode, depart: depart)
                    let line = Self.line(["eta", from.text, to.text, mode.rawValue, Self.whole(eta.distance), Self.whole(eta.expected),
                                          ToolDates.write(eta.depart), ToolDates.write(eta.arrive)])
                    return .ok(([line] + MapsLink.line(link(to))).joined(separator: "\n") + "\n")
                } catch let failure as MapsFailure {
                    throw ToolFailure(Self.sentence(failure, mode: mode, from: from, to: to, depart: depart ?? now()))
                }
            }
        }
        guard reply.status == ToolReply.denied, let withoutHere else { return reply }
        return ToolReply(status: reply.status, text: reply.text + withoutHere + "\n")
    }

    // MARK: Reading the call

    /// The call the arguments make, or why they make none: nothing here reads or asks for Location.
    func parse(_ arguments: [String]) throws -> Call {
        let read = try Arguments(arguments, options: ["near", "radius", "limit", "to", "from", "by", "depart"], flags: ["anywhere"])
        switch read.words.first {
        case "search":
            try read.only(["near", "radius", "limit", "anywhere"], for: "search")
            guard read.words.count == 2, !read.words[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Misuse("search takes one QUERY; quote one of several words")
            }
            let limit = try Self.whole(read.options["limit"], "--limit", within: Self.limits) ?? Self.defaultLimit
            let radius = try Self.whole(read.options["radius"], "--radius", within: Self.radii)
            let near = try read.options["near"].map { text -> MapPoint in
                guard let point = MapPoint(text) else {
                    throw Misuse("--near \(Self.field(text)) is not a point; it takes LAT,LON, as 37.7599,-122.4148 (latitude -90 to 90, longitude -180 to 180)")
                }
                guard abs(point.latitude) <= Self.squareLatitude else {
                    throw Misuse("--near \(Self.field(text)) is too near a pole for a square region; use --anywhere")
                }
                return point
            }
            let area: Area
            switch (near, read.flags.contains("anywhere")) {
            case (.some, true): throw Misuse("--near and --anywhere cannot both be given")
            case (nil, true):
                guard radius == nil else { throw Misuse("--radius means nothing with --anywhere") }
                area = .anywhere
            case (let point?, false): area = .near(point, radius: radius ?? Self.defaultRadius)
            case (nil, false): area = .here(radius: radius ?? Self.defaultRadius)
            }
            return .search(query: read.words[1], area: area, limit: limit)
        case let verb? where verb == "route" || verb == "eta":
            try read.only(["to", "from", "by", "depart"], for: verb)
            guard read.words.count == 1 else {
                throw Misuse("\(verb) takes its ends as --to and --from, each LAT,LON or here, and nothing else; to go to a place by name, run topo maps search NAME first and pass the result's coordinates")
            }
            guard let destination = read.options["to"] else { throw Misuse("\(verb) needs --to LAT,LON or --to here") }
            let to = try Self.end(destination, "--to")
            let from = try read.options["from"].map { try Self.end($0, "--from") } ?? .here
            guard from != to else { throw Misuse("--from and --to are the same place") }
            let mode: MapMode
            if let by = read.options["by"] {
                guard let named = MapMode(rawValue: by) else {
                    throw Misuse("--by \(Self.field(by)) is not a way to travel; it takes walking\(verb == "route" ? " or driving" : ", driving or transit")")
                }
                mode = named
            } else {
                mode = .walking
            }
            // Apple gives apps a transit time and no transit route, so the request is never made.
            if verb == "route", mode == .transit {
                var words = "Apple Maps gives apps a transit time but not transit steps; use topo maps eta --by transit"
                // Maps itself has the transit route, so a destination that is a point is offered as a link.
                if case .point(let point) = to, let link = Self.link(from, to, mode)(point) {
                    words += ", or give the person the route in Maps: \(link)"
                }
                throw Misuse(words)
            }
            var depart: Date?
            if let reading = try PhoneTool.date(read.options["depart"], "--depart") {
                guard reading.hasTime else { throw Misuse("--depart needs a time of day, as 2026-09-27T14:30") }
                depart = reading.date
            }
            return verb == "route" ? .route(from: from, to: to, mode: mode, depart: depart)
                : .eta(from: from, to: to, mode: mode, depart: depart)
        default:
            throw Misuse("maps takes search, route or eta")
        }
    }

    /// The directions link of a route or a travel time, given where its destination turned out to
    /// be: a `--from` that was `here` is left to Maps, which starts from wherever the phone is when
    /// the link is tapped, and a `--to` that was `here` is the fix.
    private static func link(_ from: End, _ to: End, _ mode: MapMode) -> (MapPoint) -> String? {
        var start: MapPoint?
        if case .point(let point) = from { start = point }
        return { MapsLink.directions(from: start, to: $0, mode: mode) }
    }

    private static func end(_ text: String, _ option: String) throws -> End {
        if text == "here" { return .here }
        guard let point = MapPoint(text) else {
            throw Misuse("\(option) \(field(text)) is not a point; it takes LAT,LON, as 37.7599,-122.4148 (latitude -90 to 90, longitude -180 to 180), or here. To go to a place by name, run topo maps search NAME first and pass the result's coordinates")
        }
        return .point(point)
    }

    /// A whole number within `range`, written in plain digits.
    private static func whole(_ text: String?, _ option: String, within range: ClosedRange<Int>) throws -> Int? {
        guard let text else { return nil }
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text), range.contains(value) else {
            throw Misuse("\(option) \(field(text)) is not a whole number from \(range.lowerBound) to \(range.upperBound)")
        }
        return value
    }

    // MARK: Where the phone is

    /// The phone's fix, waited on to the bound. Only a call whose `needsHere` is true reaches it,
    /// after its permission. `instead` is what the same verb takes in place of a fix, said when
    /// none comes.
    private func here(instead: String) async throws -> (point: MapPoint, precise: Bool) {
        let locator = locator
        switch await MapsWait.first(within: fixBound, { try await locator.fix() }) {
        case .answered(let result):
            let fix = try result.get()
            guard let point = MapPoint(latitude: fix.latitude, longitude: fix.longitude) else {
                throw ToolFailure("Core Location gave a fix that is no place on the map")
            }
            return (point, fix.precise)
        case .unanswered:
            throw ToolFailure("no location fix within \(MapsWait.written(fixBound)); give \(instead) instead")
        case .cancelled:
            throw CancellationError()
        }
    }

    private func ends(_ from: End, _ to: End) async throws -> (MapPoint, MapPoint) {
        let fix = from == .here || to == .here ? try await here(instead: "--from LAT,LON and a coordinate --to").point : nil
        // A call cancelled while the fix was waited on asks Apple Maps nothing.
        try Task.checkCancellation()
        func point(_ end: End) -> MapPoint? {
            if case .point(let point) = end { return point }
            return fix
        }
        guard let from = point(from), let to = point(to) else { throw ToolFailure("Core Location gave no fix") }
        return (from, to)
    }

    // MARK: The answers

    private func search(_ query: String, _ area: Area, limit: Int) async throws -> String {
        var region: MapRegion?
        var source = "none"
        var precision = ""
        switch area {
        case .anywhere:
            break
        case let .near(point, radius):
            region = MapRegion(centre: point, radius: radius)
            source = "near"
            precision = "exact"
        case let .here(radius):
            let fix = try await here(instead: "--near LAT,LON or --anywhere")
            guard abs(fix.point.latitude) <= Self.squareLatitude else {
                throw ToolFailure("the phone is too near a pole for a square region; use --anywhere")
            }
            region = MapRegion(centre: fix.point, radius: radius)
            source = "here"
            // An approximate fix is a few kilometres wide, so "near here" is near somewhere else.
            precision = fix.precise ? "exact" : "approximate"
        }
        try Task.checkCancellation()
        let places: [MapPlace]
        do {
            places = try await maps.search(query: query, region: region)
        } catch let failure as MapsFailure {
            throw ToolFailure(Self.sentence(failure))
        }
        let header = Self.line(["region", source, region?.centre.text, region.map { String($0.radius) }, precision, query])
        let link = MapsLink.line(MapsLink.search(query, near: region?.centre))
        let records = places.prefix(limit).enumerated().map { index, place in
            Self.line([String(index + 1), place.name, place.category, place.address, place.point.text,
                       region.map { Self.whole($0.centre.metres(to: place.point)) }, place.phone, place.url])
        }
        return Self.fit(header: [header] + link, records: records, more: places.count - records.count, unit: "results",
                        advice: "; narrow the search or lower --limit")
    }

    private static func answer(_ route: MapRoute, from: MapPoint, to: MapPoint, mode: MapMode, depart: Date, link: String?) -> String {
        // A time that is no time (not finite, negative, decades long) gives no arrival.
        let arrive = route.expected.isFinite && (0...1e9).contains(route.expected)
            ? ToolDates.write(depart.addingTimeInterval(route.expected)) : nil
        var header = [line(["route", from.text, to.text, mode.rawValue, whole(route.distance), whole(route.expected),
                            ToolDates.write(depart), arrive, route.name])]
        header += MapsLink.line(link)
        header += route.notices.prefix(noticeCap).map { line(["notice", $0]) }
        let steps = route.steps.prefix(stepCap).enumerated().map { index, step in
            line([String(index + 1), step.instruction, whole(step.distance)])
        }
        return fit(header: header, records: steps, more: route.steps.count - steps.count, unit: "steps", advice: "")
    }

    /// The header whole, then each record whole until the next would carry the answer past the
    /// budget less the last line's room; that one and every one after it are left out, and the
    /// last line says how many were, with the `more` the caps had already left out.
    static func fit(header: [String], records: [String], more: Int, unit: String, advice: String) -> String {
        var text = header.map { $0 + "\n" }.joined()
        var bytes = text.utf8.count
        var kept = 0
        for record in records {
            let size = record.utf8.count + 1
            guard bytes + size <= budget - lastLineRoom else { break }
            text += record + "\n"
            bytes += size
            kept += 1
        }
        if kept < records.count {
            text += "… \(records.count - kept + more) more \(unit), cut at 24 KB\(advice)\n"
        } else if more > 0 {
            text += "… \(more) more \(unit)\n"
        }
        return text
    }

    /// One record's line: every field in its place, an absent one empty, so a field is found by
    /// counting bars.
    static func line(_ fields: [String?]) -> String {
        fields.map(field).joined(separator: " | ")
    }

    /// A field as it is written: its line breaks spaces and its bars slashes, so it is one field on
    /// one line, cut with `…` at 200 characters or 800 bytes, whichever comes first, between
    /// characters and never inside one.
    static func field(_ text: String?) -> String {
        guard let text else { return "" }
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .replacingOccurrences(of: "|", with: "/").trimmingCharacters(in: .whitespaces)
        var kept = ""
        var bytes = 0
        var characters = 0
        for character in flat {
            let size = String(character).utf8.count
            // The last place and the last three bytes are the ellipsis's, unless the text ends here.
            guard characters < fieldCharacters - 1, bytes + size <= fieldBytes - 3 else {
                return flat.count <= fieldCharacters && flat.utf8.count <= fieldBytes ? flat : kept + "…"
            }
            kept.append(character)
            bytes += size
            characters += 1
        }
        return kept
    }

    /// Metres or seconds as a whole number, or nothing for a value that is not one.
    static func whole(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "" }
        return String(Int(min(value, 1e15).rounded()))
    }

    // MARK: The failures

    private static func sentence(_ failure: MapsFailure, mode: MapMode? = nil, from: MapPoint? = nil, to: MapPoint? = nil,
                                 depart: Date? = nil) -> String {
        switch failure {
        case .noRoute(let words):
            guard let mode, let from, let to else { return "Apple Maps could not answer" + said(words) }
            if mode == .transit, let depart {
                return "no transit route from \(from.text) to \(to.text) at \(ToolDates.write(depart))" + said(words)
                    + "; try --by walking or --by driving"
            }
            return "no \(mode.rawValue) route from \(from.text) to \(to.text)" + said(words)
        case .throttled:
            return "Apple Maps is turning requests away for now (too many in a short time); try again in a minute"
        case .server(let words):
            return "Apple Maps' server failed" + said(words) + "; try again later"
        case .unanswered(let bound):
            return "Apple Maps did not answer within \(MapsWait.written(bound))"
        case .other(let words):
            return "Apple Maps could not answer: \(field(words))"
        }
    }

    private static func said(_ words: String?) -> String {
        guard let words, !field(words).isEmpty else { return "" }
        return " (Apple Maps: \(field(words)))"
    }
}

// MARK: MapKit

/// One request to Apple Maps, started once. `cancel` ends it, and its `start` with it.
@MainActor
protocol MapRequest<Answer>: AnyObject {
    associatedtype Answer
    func start() async throws -> Answer
    func cancel()
}

/// What makes MapKit's requests: `MKMapRequests` on the phone, and in the suites a fake that holds
/// each one, answers it or never does, which is how `MapKitMaps`'s bound and cancel are tested.
@MainActor
protocol MapRequestRunner: AnyObject, Sendable {
    func search(_ request: MKLocalSearch.Request) -> any MapRequest<[MKMapItem]>
    func directions(_ request: MKDirections.Request) -> any MapRequest<[MKRoute]>
    func eta(_ request: MKDirections.Request) -> any MapRequest<MKDirections.ETAResponse>
}

/// Apple Maps through MapKit. Each request is waited on for `requestBound` and no longer, and is
/// cancelled at the bound and when the call it is for is cancelled; either way its answer is no
/// longer waited for, since a cancelled `MKDirections` never gives one.
@MainActor
final class MapKitMaps: MapsStore {
    private let runner: any MapRequestRunner
    let requestBound: Duration

    init(runner: any MapRequestRunner = MKMapRequests(), requestBound: Duration = .seconds(20)) {
        self.runner = runner
        self.requestBound = requestBound
    }

    func search(query: String, region: MapRegion?) async throws -> [MapPlace] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let region {
            let span = 2 * Double(region.radius)
            request.region = MKCoordinateRegion(center: region.centre.coordinate, latitudinalMeters: span, longitudinalMeters: span)
            // Without this the region is a hint MapKit is free to ignore, and does: a search around
            // one city answers with places in another. Before iOS 18 a hint is all there is.
            if #available(iOS 18.0, *) { request.regionPriority = .required }
        }
        do {
            return try await answer(runner.search(request)) { $0.compactMap(Self.place) }
        } catch let error as MKError where error.code == .placemarkNotFound && Self.directionsCode(error) == nil {
            // How MapKit says a search found nothing. The same code beside a directions code is
            // Apple Maps having no answer, which is a failure below.
            return []
        } catch {
            // Any other failure of a search is said as itself, never as nothing found.
            if case .noRoute(let words)? = Self.failure(error) as? MapsFailure {
                throw MapsFailure.other(words ?? error.localizedDescription)
            }
            throw Self.failure(error)
        }
    }

    func route(from: MapPoint, to: MapPoint, mode: MapMode, depart: Date?) async throws -> MapRoute {
        do {
            let route = try await answer(runner.directions(Self.request(from: from, to: to, mode: mode, depart: depart))) {
                $0.first.map(Self.route)
            }
            guard let route else { throw MapsFailure.noRoute(nil) }
            return route
        } catch {
            throw Self.failure(error)
        }
    }

    func eta(from: MapPoint, to: MapPoint, mode: MapMode, depart: Date?) async throws -> MapETA {
        do {
            return try await answer(runner.eta(Self.request(from: from, to: to, mode: mode, depart: depart))) {
                MapETA(distance: $0.distance, expected: $0.expectedTravelTime, depart: $0.expectedDepartureDate,
                       arrive: $0.expectedArrivalDate)
            }
        } catch {
            throw Self.failure(error)
        }
    }

    /// The request's answer as a plain value if it comes first; at the bound or the caller's
    /// cancellation the request is cancelled and left.
    private func answer<Answer, Plain: Sendable>(_ request: any MapRequest<Answer>,
                                                 _ plain: @escaping @MainActor (Answer) -> Plain) async throws -> Plain {
        try Task.checkCancellation()
        let waited = await MapsWait.first(within: requestBound) { @MainActor in plain(try await request.start()) }
        switch waited {
        case .answered(let result):
            return try result.get()
        case .unanswered:
            request.cancel()
            throw MapsFailure.unanswered(requestBound)
        case .cancelled:
            request.cancel()
            throw CancellationError()
        }
    }

    private static func request(from: MapPoint, to: MapPoint, mode: MapMode, depart: Date?) -> MKDirections.Request {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.coordinate))
        request.requestsAlternateRoutes = false
        request.departureDate = depart
        switch mode {
        case .walking: request.transportType = .walking
        case .driving: request.transportType = .automobile
        case .transit: request.transportType = .transit
        }
        return request
    }

    /// A place as a plain value, or nil for an item whose coordinate is no place on the map.
    static func place(_ item: MKMapItem) -> MapPlace? {
        let coordinate = item.placemark.coordinate
        guard let point = MapPoint(latitude: coordinate.latitude, longitude: coordinate.longitude) else { return nil }
        let category = item.pointOfInterestCategory.map { category -> String in
            let name = category.rawValue
            return name.hasPrefix("MKPOICategory") ? String(name.dropFirst("MKPOICategory".count)) : name
        }
        let address = item.placemark.title
        return MapPlace(name: item.name, category: category, address: address == item.name ? nil : address, point: point,
                        phone: item.phoneNumber, url: item.url?.absoluteString)
    }

    /// A route as a plain value. MapKit opens some routes with a step that has no instruction, the
    /// origin itself, which is left out; a first step that says something is kept.
    static func route(_ route: MKRoute) -> MapRoute {
        var steps = route.steps.map { MapStep(instruction: $0.instructions, distance: $0.distance) }
        if let first = steps.first, first.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { steps.removeFirst() }
        return MapRoute(name: route.name, distance: route.distance, expected: route.expectedTravelTime,
                        notices: route.advisoryNotices, steps: steps)
    }

    /// The directions codes MapKit gives, under `MKDirectionsErrorCode`, for two points nothing
    /// joins: 16 from `calculate()` and 1 from `calculateETA()`.
    static let unroutable: Set<Int> = [1, 16]

    /// The directions code an error of MapKit's carries, if it carries one.
    static func directionsCode(_ error: any Error) -> Int? {
        ((error as NSError).userInfo["MKDirectionsErrorCode"] as? NSNumber)?.intValue
    }

    /// MapKit's error as `MapsTool` says it. Every directions error carries a directions code
    /// whatever its `MKError` code is, so the directions code is what tells two points nothing
    /// joins from Apple Maps having no answer for now, which is said in Apple's own words. With no
    /// directions code the `MKError` code is all there is.
    static func failure(_ error: any Error) -> any Error {
        if error is CancellationError || error is MapsFailure { return error }
        guard let failure = error as? MKError else { return MapsFailure.other(error.localizedDescription) }
        let info = (error as NSError).userInfo
        let words = info[NSLocalizedFailureReasonErrorKey] as? String ?? info[NSLocalizedDescriptionKey] as? String
        if let directions = directionsCode(error) {
            return unroutable.contains(directions) ? MapsFailure.noRoute(words) : MapsFailure.other(words ?? error.localizedDescription)
        }
        switch failure.code {
        case .directionsNotFound, .placemarkNotFound:
            return MapsFailure.noRoute(words)
        case .serverFailure:
            return MapsFailure.server(words)
        case .loadingThrottled:
            return MapsFailure.throttled
        default:
            return MapsFailure.other(words ?? error.localizedDescription)
        }
    }
}

/// MapKit's own requests, and nothing else.
@MainActor
final class MKMapRequests: MapRequestRunner {
    nonisolated init() {}

    func search(_ request: MKLocalSearch.Request) -> any MapRequest<[MKMapItem]> {
        let search = MKLocalSearch(request: request)
        return MapKitRequest(begin: { done in
            search.start { response, error in done(.init(response?.mapItems, error)) }
        }, stop: { search.cancel() })
    }

    func directions(_ request: MKDirections.Request) -> any MapRequest<[MKRoute]> {
        let directions = MKDirections(request: request)
        return MapKitRequest(begin: { done in
            directions.calculate { response, error in done(.init(response?.routes, error)) }
        }, stop: { directions.cancel() })
    }

    func eta(_ request: MKDirections.Request) -> any MapRequest<MKDirections.ETAResponse> {
        let directions = MKDirections(request: request)
        return MapKitRequest(begin: { done in
            directions.calculateETA { response, error in done(.init(response, error)) }
        }, stop: { directions.cancel() })
    }
}

/// One MapKit request behind its completion handler. `MKDirections.cancel()` never calls the
/// handler, so `cancel` ends the wait itself.
@MainActor
final class MapKitRequest<Answer>: MapRequest {
    /// What MapKit gave its handler, on its way to the main actor. MapKit's objects are not
    /// `Sendable`; one is handed over whole and read only there.
    struct Handed: @unchecked Sendable {
        let result: Result<Answer, any Error>

        init(_ result: Result<Answer, any Error>) {
            self.result = result
        }

        /// A handler's two arguments: the answer, or the error, or MapKit's unknown error for neither.
        init(_ answer: Answer?, _ error: (any Error)?) {
            result = answer.map { .success($0) } ?? .failure(error ?? MKError(.unknown))
        }
    }

    typealias Done = @Sendable (Handed) -> Void

    private let begin: @MainActor (@escaping Done) -> Void
    private let stop: @MainActor () -> Void
    private var waiting: CheckedContinuation<Handed, Never>?
    private var cancelled = false

    init(begin: @escaping @MainActor (@escaping Done) -> Void, stop: @escaping @MainActor () -> Void) {
        self.begin = begin
        self.stop = stop
    }

    func start() async throws -> Answer {
        let handed = await withCheckedContinuation { (continuation: CheckedContinuation<Handed, Never>) in
            guard !cancelled else { return continuation.resume(returning: Handed(.failure(CancellationError()))) }
            waiting = continuation
            begin { [weak self] handed in
                Task { @MainActor in self?.finish(handed) }
            }
        }
        return try handed.result.get()
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        stop()
        finish(Handed(.failure(CancellationError())))
    }

    private func finish(_ handed: Handed) {
        waiting?.resume(returning: handed)
        waiting = nil
    }
}
