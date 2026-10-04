import Foundation
import OSLog

/// This package's marks in the unified log's `perf` category, beside the app's (`TopoCore.Perf`):
/// a name per moment, nothing of the person's.
enum Perf {
    private static let log = Logger(subsystem: "zone.hexagon.topo", category: "perf")

    static func mark(_ name: String) {
        log.notice("mark t=\(Int64(Date().timeIntervalSince1970 * 1000)) \(name, privacy: .public)")
    }
}
