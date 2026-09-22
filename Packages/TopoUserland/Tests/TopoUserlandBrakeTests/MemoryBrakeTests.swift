import XCTest
import TopoUserland

/// The brake on a stale sample. The sampler is stopped for these tests, so nothing refreshes the
/// sample but the hook, and the sample is made stale by waiting out the kernel's two seconds. An
/// allocation that merely succeeds would prove nothing — it passes with the brake bypassed, and a
/// running sampler would refresh before the stale path was reached — so each test counts the
/// hook's calls and asserts the decision.
///
/// A bundle of its own, so a process of its own: a feed puts the kernel in footprint mode for the
/// life of the process, and a simulator has no jetsam line for the production sampler to renew a
/// sample from, so any guest run after these in the same process would meet a stale sample
/// nothing can refresh.
final class MemoryBrakeTests: XCTestCase {
    private static let gigabyte: UInt64 = 1 << 30
    /// Past the kernel's two seconds (ISH_MEM_STALE_MS), with a margin.
    private static let stale: TimeInterval = 2.2

    nonisolated(unsafe) static var calls = 0
    nonisolated(unsafe) static var renews = false

    override func setUp() {
        MemorySampler.shared.stop()
        Self.calls = 0
    }

    override func tearDown() {
        MemoryBrake.setRefresh(MemoryBrake.sampleNow)
    }

    private static func roomy() {
        MemoryBrake.feed(limit: 8 * gigabyte, available: 6 * gigabyte)
    }

    /// Counts its calls and, when `renews`, delivers a fresh roomy sample, as the app's sampler
    /// does when it can read the jetsam line.
    private static let hook: MemoryBrake.Refresh = {
        MemoryBrakeTests.calls += 1
        if MemoryBrakeTests.renews { MemoryBrakeTests.roomy() }
    }

    func testAStaleSampleAsksTheAppForAFreshOneAndTheAllocationIsAdmitted() {
        Self.roomy()
        Self.renews = true
        MemoryBrake.setRefresh(Self.hook)
        XCTAssertTrue(MemoryBrake.admits(4096), "a fresh sample with gigabytes free refused")
        XCTAssertEqual(Self.calls, 0, "the hook ran on a fresh sample")

        Thread.sleep(forTimeInterval: Self.stale)
        XCTAssertTrue(MemoryBrake.admits(4096), "the brake failed closed with gigabytes free")
        XCTAssertEqual(Self.calls, 1, "the stale sample was not refreshed through the hook")
    }

    func testAStaleSampleTheAppCannotRenewIsRefused() {
        Self.roomy()
        Self.renews = false
        MemoryBrake.setRefresh(Self.hook)

        Thread.sleep(forTimeInterval: Self.stale)
        XCTAssertFalse(MemoryBrake.admits(4096), "a dead sampler did not fail closed")
        XCTAssertEqual(Self.calls, 1)
    }

    func testTheBrakeStillHoldsOnAFreshSampleNearTheLine() {
        // 5% of the line left: under the kernel's 10% margin, so the brake is on however fresh.
        MemoryBrake.feed(limit: 8 * Self.gigabyte, available: 8 * Self.gigabyte / 20)
        Self.renews = true
        MemoryBrake.setRefresh(Self.hook)
        XCTAssertFalse(MemoryBrake.admits(4096))
        XCTAssertEqual(Self.calls, 0)
    }

    /// The same two cases through a guest program's own allocations: a shell that builds a
    /// megabyte string after the sample went stale. Renewed, it runs; not renewed, the guest is
    /// refused its memory.
    func testAGuestAllocatingOnAStaleSampleIsServedWhenTheAppRenewsIt() async throws {
        _ = try SharedGuest.booted()
        MemorySampler.shared.stop()
        Self.roomy()
        Self.renews = true
        MemoryBrake.setRefresh(Self.hook)
        try await Task.sleep(for: .seconds(Self.stale))

        let exit = try await Guest.shared.run("/bin/sh", ["-c", Self.allocate])
        XCTAssertEqual(exit.status, 0, exit.errors)
        XCTAssertEqual(exit.output, "1048576\n")
        XCTAssertGreaterThanOrEqual(Self.calls, 1, "the guest's allocation did not go through the hook")
    }

    func testAGuestAllocatingOnAStaleSampleTheAppCannotRenewIsRefused() async throws {
        _ = try SharedGuest.booted()
        MemorySampler.shared.stop()
        Self.roomy()
        Self.renews = false
        MemoryBrake.setRefresh(Self.hook)
        try await Task.sleep(for: .seconds(Self.stale))

        let exit = try await Guest.shared.run("/bin/sh", ["-c", Self.allocate])
        XCTAssertNotEqual(exit.status, 0, "the guest was given memory on a dead sample")
        XCTAssertNotEqual(exit.output, "1048576\n")
        XCTAssertGreaterThanOrEqual(Self.calls, 1)
    }

    /// A megabyte string in the shell, and its length.
    private static let allocate = #"s=$(head -c 1048576 /dev/zero | tr '\0' x); echo ${#s}"#
}
