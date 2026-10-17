import XCTest

/// The app every UI suite launches: a debug build on the in-memory record store
/// (`TOPO_DEBUG_STORE=memory`, `AppRecords`), so the first screen waits on nothing but the app.
/// On real CloudKit an unsigned simulator's first reads after a fresh boot can take past a test's
/// wait for the chat (#434). The store is per process: a relaunch starts with no records, and what
/// a suite carries across one is on disk (the line's outbox, the defaults), as it is for the app.
enum TopoLaunch {
    static func app() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOPO_DEBUG_STORE"] = "memory"
        return app
    }
}
