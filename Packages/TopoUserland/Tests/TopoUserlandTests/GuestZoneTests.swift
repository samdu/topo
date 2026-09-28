import Foundation
import TopoUserland
import XCTest

/// The guest's zone: `/etc/localtime` linked into the zoneinfo mounted at `/usr/share/zoneinfo`.
/// Each test mounts its own zoneinfo there and takes it and the link away after, so the shared
/// guest is left as it was found.
final class GuestZoneTests: XCTestCase {
    private let fm = FileManager.default
    private var planted: URL?

    override func setUpWithError() throws {
        _ = try SharedGuest.booted()
    }

    override func tearDown() async throws {
        _ = try? await Guest.shared.run("/bin/rm", ["-f", "/etc/localtime", "/etc/localtime.topo"])
        try? Guest.shared.unmount(Guest.zoneinfo)
        if let planted { try? fm.removeItem(at: planted) }
    }

    /// A zoneinfo of two zones copied from the host's own, and `Bogus`, a regular file with a plain
    /// zone name that is not TZif, mounted where the phone's is.
    private func plantZoneinfo() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("zoneinfo-\(UUID().uuidString)", isDirectory: true)
        planted = dir
        for zone in ["America/Los_Angeles", "Europe/London"] {
            let copy = dir.appendingPathComponent(zone)
            try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: URL(fileURLWithPath: Guest.zoneinfo).appendingPathComponent(zone), to: copy)
        }
        try Data("not a zone\n".utf8).write(to: dir.appendingPathComponent("Bogus"))
        try Guest.shared.mount(dir, at: Guest.zoneinfo)
    }

    /// The guest tells the time in the zone `/etc/localtime` is pointed at, standard time and
    /// summer time each on its own date; a second zone replaces the first, with nothing left beside it.
    func testTheGuestKeepsThePhonesZone() async throws {
        try plantZoneinfo()
        let probe = "readlink /etc/localtime; date -d @1737000000 +%z; date -d @1752000000 +%z; ls /etc/localtime.topo 2>/dev/null"

        try await Guest.shared.writeTimeZone(identifier: "America/Los_Angeles")
        let pacific = try await Guest.shared.run("/bin/sh", ["-c", probe])
        XCTAssertEqual(pacific.output, "/usr/share/zoneinfo/America/Los_Angeles\n-0800\n-0700\n", pacific.errors)

        try await Guest.shared.writeTimeZone(identifier: "Europe/London")
        let london = try await Guest.shared.run("/bin/sh", ["-c", probe])
        XCTAssertEqual(london.output, "/usr/share/zoneinfo/Europe/London\n+0000\n+0100\n", london.errors)
    }

    /// A name that is not a zone's, a zone the zoneinfo has no file for, or a file that is not TZif
    /// throws and leaves `/etc/localtime` where it was: no path out of the zoneinfo, and nothing the
    /// shell runs.
    func testTheTimeZoneRefusesWhatIsNotAZone() async throws {
        try plantZoneinfo()
        try await Guest.shared.writeTimeZone(identifier: "Europe/London")
        let refused = ["../../etc/passwd", "/etc/passwd", "America/$(touch /tmp/ran)", "America/..", "America//Denver",
                       "", "a b", String(repeating: "A", count: 65), "Mars/Olympus", "America", "Bogus"]
        for name in refused {
            do {
                try await Guest.shared.writeTimeZone(identifier: name)
                XCTFail("\(name) was written")
            } catch let failure as Guest.Failure {
                guard case .timeZone = failure else { return XCTFail("\(name): \(failure)") }
            }
        }
        let after = try await Guest.shared.run("/bin/sh", ["-c", "readlink /etc/localtime; ls /etc/localtime.topo /tmp/ran 2>/dev/null"])
        XCTAssertEqual(after.output, "/usr/share/zoneinfo/Europe/London\n")
    }

    /// The phone's own zoneinfo mounts at the same path, carries the zones as TZif, and takes no
    /// write from the guest; a zone written against it tells the time in that zone.
    func testThePhonesZoneinfoIsMountedAndTakesNoWrite() async throws {
        try Guest.shared.mountZoneinfo()
        try Guest.shared.mountZoneinfo()
        let probe = try await Guest.shared.run("/bin/sh", ["-c",
            "head -c 4 /usr/share/zoneinfo/America/Los_Angeles; echo; touch /usr/share/zoneinfo/topo-was-here && echo wrote"])
        XCTAssertEqual(probe.output, "TZif\n", probe.errors)
        XCTAssertFalse(fm.fileExists(atPath: Guest.zoneinfo + "/topo-was-here"))

        try await Guest.shared.writeTimeZone(identifier: "Asia/Tokyo")
        let tokyo = try await Guest.shared.run("/bin/date", ["-d", "@1752000000", "+%z"])
        XCTAssertEqual(tokyo.output, "+0900\n", tokyo.errors)
    }
}
