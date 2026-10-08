import Foundation

/// The places the person has named, as a document the mind can write: `places.json` in the
/// vault's root, beside `look.json`. A geocoder names the nearest address, which for a flat above
/// a shop is the shop's; a place named here is what `topo location` says instead when the phone
/// is inside it.
///
/// ```
/// {"home": {"latitude": 37.78167, "longitude": -122.45261, "radius": 30, "address": "3147 Geary Blvd"}}
/// ```
///
/// Each key is a place's name. It is read entry by entry, as `LookDocument` reads a look: an
/// entry that is not an object, lacks a coordinate, or holds a number that is not finite or is
/// outside its range is left out alone with the reason written down, and every other entry
/// stands.
enum PlacesDocument {
    /// Where the document lives, in the vault's root beside the notes.
    static let name = "places.json"

    /// In metres: what a place with no `radius` is given, and what one may name.
    static let defaultRadius = 50.0
    static let radii = 5.0...5000.0
    /// The longest name and address read, in characters.
    static let nameLength = 64
    static let addressLength = 200
    /// The most places read: the rest are counted in one note.
    static let limit = 100

    struct Place: Equatable, Sendable {
        var name: String
        var latitude: Double
        var longitude: Double
        /// In metres.
        var radius: Double
        var address: String?
    }

    /// One read of the document: the places it names, and what it had to say about itself.
    struct Reading: Equatable, Sendable {
        var places: [Place] = []
        /// Why nothing was read from a file that is there: not JSON, not an object, not text.
        var unreadable: String?
        /// Every entry and field the document named and did not get, each saying which and why.
        var notes: [String] = []
    }

    static func read(_ text: String?) -> Reading {
        guard let text else { return Reading() }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
            return Reading(unreadable: "is not JSON")
        }
        guard let root = parsed as? [String: Any] else { return Reading(unreadable: "is not a JSON object") }
        var reading = Reading()
        // By name, so what is read and what is noted do not depend on a dictionary's order.
        for key in root.keys.sorted() {
            guard reading.places.count < limit else {
                reading.notes.append("\(root.count - limit) more places than the \(limit) read")
                break
            }
            let label = shown(key)
            guard !key.isEmpty, key.count <= nameLength, !key.contains(where: \.isNewline) else {
                reading.notes.append("\(label) is not a name of one line and at most \(nameLength) characters")
                continue
            }
            guard let entry = root[key] as? [String: Any] else {
                reading.notes.append("\(label) is not an object")
                continue
            }
            guard let latitude = number(entry["latitude"], in: -90...90) else {
                reading.notes.append("\(label).latitude is not a number from -90 to 90")
                continue
            }
            guard let longitude = number(entry["longitude"], in: -180...180) else {
                reading.notes.append("\(label).longitude is not a number from -180 to 180")
                continue
            }
            var radius = defaultRadius
            if let given = entry["radius"] {
                guard let read = number(given, in: radii) else {
                    reading.notes.append("\(label).radius is not a number of metres from \(Int(radii.lowerBound)) to \(Int(radii.upperBound))")
                    continue
                }
                radius = read
            }
            var address: String?
            if let given = entry["address"] {
                // An address that cannot be read costs the address and not the place.
                if let text = given as? String, !text.isEmpty, text.count <= addressLength, !text.contains(where: \.isNewline) {
                    address = text
                } else {
                    reading.notes.append("\(label).address is not text of one line and at most \(addressLength) characters")
                }
            }
            for stray in entry.keys.sorted() where !["latitude", "longitude", "radius", "address"].contains(stray) {
                reading.notes.append("\(label).\(shown(stray)) is not a field a place has")
            }
            reading.places.append(Place(name: key, latitude: latitude, longitude: longitude, radius: radius, address: address))
        }
        return reading
    }

    /// A JSON number that is finite and in `range`: a bool, which `NSNumber` also holds, is not one.
    private static func number(_ value: Any?, in range: ClosedRange<Double>) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite && range.contains(double) ? double : nil
    }

    /// A key as a note names it: on one line and no longer than a name may be.
    private static func shown(_ key: String) -> String {
        let flat = key.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > nameLength ? String(flat.prefix(nameLength)) + "…" : flat
    }
}
