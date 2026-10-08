import CoreLocation
import Foundation
import TopoTools

struct LocationFix: Sendable, Equatable {
    var latitude: Double
    var longitude: Double
    /// In metres.
    var accuracy: Double
    var at: Date
    var precise: Bool
    var place: String?
}

/// Where the phone is: Core Location on the phone, a fake in the suites.
protocol Locator: Sendable {
    func fix() async throws -> LocationFix
}

/// `topo location`: where the phone is now, with the place the person named when the phone is
/// inside one (`PlacesDocument`), and the geocoder's nearest address when one comes back in time.
struct LocationTool: Tool {
    let locator: any Locator
    let authorizer: any Authorizer
    let broker: PermissionBroker
    /// What the vault's `places.json` said at the last sync: `Memory.places`.
    var places: @MainActor @Sendable () -> PlacesDocument.Reading = { PlacesDocument.Reading() }
    var now: @Sendable () -> Date = { Date() }

    let name = "location"
    let summary = "where the phone is now, and the place's name"
    let usage = """
    topo location                       latitude, longitude, accuracy, the fix's age, and the place

    The place line is `place NAME (ADDRESS) — nearest address …` when the phone is inside a place the
    vault's places.json names, and `place (nearest address) …` otherwise: the geocoder's house number
    is its nearest guess, not a measurement, and for a flat above a shop it is the shop's.
    places.json is yours to write, in the memory's root, when the person corrects a place:
      {"home": {"latitude": 37.78167, "longitude": -122.45261, "radius": 30, "address": "3147 Geary Blvd"}}
    radius is metres (5 to 5000, 50 when left out) and address is optional. It is read at the memory's
    next sync, and a `note` line here says what in it was not read.
    """

    /// The most `note` lines about places.json one answer carries.
    static let noted = 3

    /// The named place the fix is inside, the nearest centre first when it is inside several. An
    /// approximate fix is kilometres wide, so it is inside no place.
    static func named(_ fix: LocationFix, among places: [PlacesDocument.Place]) -> PlacesDocument.Place? {
        guard fix.precise else { return nil }
        let here = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
        return places
            .map { (place: $0, metres: here.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))) }
            .filter { $0.metres <= $0.place.radius }
            .min { ($0.metres, $0.place.name) < ($1.metres, $1.place.name) }?
            .place
    }

    /// The place line: the named place and the geocoder's address, either or neither.
    static func placeLine(_ named: PlacesDocument.Place?, nearest: String?) -> String? {
        let nearest = nearest.map(PhoneTool.flat)
        guard let named else { return nearest.map { "place (nearest address) " + $0 } }
        let place = "place " + named.name + (named.address.map { " (\($0))" } ?? "")
        return place + (nearest.map { " — nearest address " + $0 } ?? "")
    }

    func run(_ arguments: [String]) async -> ToolReply {
        await PhoneTool.run(authorizer, broker: broker, usage: usage, parse: {
            guard arguments.isEmpty else { throw Misuse("location takes no arguments") }
        }) { _ in
            let fix = try await locator.fix()
            var lines = [
                String(format: "latitude %.5f", fix.latitude),
                String(format: "longitude %.5f", fix.longitude),
                String(format: "accuracy %.0f m", fix.accuracy) + (fix.precise ? "" : " (approximate: the person allows only an approximate location)"),
                "at \(ToolDates.write(fix.at)) (\(max(0, Int(now().timeIntervalSince(fix.at)))) s ago)",
            ]
            let reading = await places()
            if let line = Self.placeLine(Self.named(fix, among: reading.places), nearest: fix.place) { lines.append(line) }
            var notes = reading.notes
            if let why = reading.unreadable { notes.insert(why, at: 0) }
            lines += notes.prefix(Self.noted).map { "note \(PlacesDocument.name): " + PhoneTool.flat($0) }
            if notes.count > Self.noted { lines.append("note \(PlacesDocument.name): and \(notes.count - Self.noted) more") }
            return .ok(lines.joined(separator: "\n") + "\n")
        }
    }
}

/// When-in-use location, asked for through a manager of its own whose answer comes back on its
/// delegate.
@MainActor
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    private var waiting: [CheckedContinuation<Bool, Never>] = []

    var status: CLAuthorizationStatus { (manager ?? CLLocationManager()).authorizationStatus }
    var precise: Bool { (manager ?? CLLocationManager()).accuracyAuthorization == .fullAccuracy }

    func request() async -> Bool {
        let manager = manager ?? CLLocationManager()
        self.manager = manager
        guard manager.authorizationStatus == .notDetermined else { return Self.granted(manager.authorizationStatus) }
        manager.delegate = self
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            if waiting.count == 1 { manager.requestWhenInUseAuthorization() }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status != .notDetermined else { return }
        Task { @MainActor in
            let answered = waiting
            waiting = []
            answered.forEach { $0.resume(returning: Self.granted(status)) }
        }
    }

    nonisolated static func granted(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }
}

struct LocationAuthorizer: Authorizer {
    let name = "Location"
    let permission: LocationPermission

    func access() async -> Access {
        switch await permission.status {
        case .notDetermined: .undetermined
        case .restricted: .restricted
        case .denied: .denied
        default: .granted
        }
    }

    func request() async -> Bool { await permission.request() }
}

/// The first fix `CLLocationUpdate.liveUpdates()` gives, and, when `named`, its place from
/// `CLGeocoder` if that answers within five seconds.
struct CoreLocationLocator: Locator {
    let permission: LocationPermission
    /// False for a caller that wants the fix alone (`topo maps`): the geocoder is not asked.
    var named = true

    func fix() async throws -> LocationFix {
        var found: CLLocation?
        for try await update in CLLocationUpdate.liveUpdates() {
            if let location = update.location {
                found = location
                break
            }
        }
        guard let location = found else { throw ToolFailure("Core Location gave no fix") }
        let place = named ? await Self.place(of: location) : nil
        return LocationFix(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                           accuracy: location.horizontalAccuracy, at: location.timestamp,
                           precise: await permission.precise, place: place)
    }

    private static func place(of location: CLLocation) async -> String? {
        await PhoneTool.within(.seconds(5)) {
            guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
            var seen: [String] = []
            for part in [mark.name, mark.subLocality, mark.locality, mark.administrativeArea, mark.country].compactMap({ $0 })
            where !seen.contains(part) {
                seen.append(part)
            }
            return seen.isEmpty ? nil : seen.joined(separator: ", ")
        }
    }
}
