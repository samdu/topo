import OSLog

/// This package's marks in the unified log's `perf` category, beside the app's (`TopoCore.Perf`):
/// a name per moment, nothing of the person's.
enum Perf {
    private static let log = Logger(subsystem: "zone.hexagon.topo", category: "perf")

    static func mark(_ name: String) {
        log.notice("mark \(name, privacy: .public)")
    }
}
