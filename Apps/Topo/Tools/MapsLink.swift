import Foundation

/// The Apple Maps link an answer of `topo maps` carries, for the person to tap: the same search,
/// route or travel time in Maps itself, with its map, its turn-by-turn and, by transit, the route
/// MapKit gives an app no steps for. A link is text in the answer and nothing here opens it:
/// leaving Topo is the person's tap. This is the one file of `topo maps` that names Apple Maps'
/// web address (`scripts/tests/maps-opens-nothing-test.sh`).
enum MapsLink {
    /// The longest link written, in bytes, which is a record's field at its longest: a longer one
    /// is left out, never cut, since a cut link opens somewhere else or nowhere.
    static let bytes = 800

    /// A search for `query`, near `centre` when the search had a region.
    static func search(_ query: String, near centre: MapPoint?) -> String? {
        link([URLQueryItem(name: "q", value: query)] + (centre.map { [URLQueryItem(name: "sll", value: $0.text)] } ?? []))
    }

    /// Directions to `to` by `mode`, from `from`, or from wherever the phone is when it is tapped
    /// with no `from`: an end that was `here` is not pinned to where the phone was.
    static func directions(from: MapPoint?, to: MapPoint, mode: MapMode) -> String? {
        let flag = switch mode {
        case .walking: "w"
        case .driving: "d"
        case .transit: "r"
        }
        return link((from.map { [URLQueryItem(name: "saddr", value: $0.text)] } ?? [])
            + [URLQueryItem(name: "daddr", value: to.text), URLQueryItem(name: "dirflg", value: flag)])
    }

    /// The `link` line an answer carries, or none for a link too long to write whole.
    static func line(_ link: String?) -> [String] {
        link.map { ["link | " + $0] } ?? []
    }

    private static func link(_ items: [URLQueryItem]) -> String? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"
        components.queryItems = items
        // `URLComponents` leaves a plus as it is, which a query reads as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let text = components.url?.absoluteString, text.utf8.count <= bytes,
              text.allSatisfy({ $0.isASCII && !$0.isWhitespace && $0 != "|" }) else { return nil }
        return text
    }
}
