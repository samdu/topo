import XCTest

// PROBE: not in the committed Topo.xcodeproj. Fails only if CI generated the project.
final class ProbeFailingTests: XCTestCase {
    func testProbeFileOnDiskIsCompiledAndRun() {
        XCTFail("PROBE: on-disk test file was compiled and ran")
    }
}
