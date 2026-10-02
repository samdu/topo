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

/// `topo location`: where the phone is now, with a place name when one comes back in time.
struct LocationTool: Tool {
    let locator: any Locator
    let authorizer: any Authorizer
    let broker: PermissionBroker
    var now: @Sendable () -> Date = { Date() }

    let name = "location"
    let summary = "where the phone is now, and the place's name"
    let usage = "topo location                       latitude, longitude, accuracy, the fix's age, and a place name"

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
            if let place = fix.place { lines.append("place " + PhoneTool.flat(place)) }
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

/// The first fix `CLLocationUpdate.liveUpdates()` gives, and its place from `CLGeocoder` if that
/// answers within five seconds.
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
