import CloudKit
import TopoCore
import TopoCoreTesting
import TopoTools
import XCTest

@testable import Topo

/// `places.json` (#247): read entry by entry, read by the memory after each sync through the
/// mirror's coordination, and said by `topo location` when the phone is inside a place it names.
@MainActor
final class PlacesTests: XCTestCase {
    private let home = PlacesDocument.Place(name: "home", latitude: 37.78167, longitude: -122.45261, radius: 30, address: "3147 Geary Blvd")
    private let homeText = #"{"home": {"latitude": 37.78167, "longitude": -122.45261, "radius": 30, "address": "3147 Geary Blvd"}}"#
    private let noon = ISO8601DateFormatter().date(from: "2026-09-26T19:00:00Z")!

    // MARK: The document

    func testAPlaceIsReadWithItsDefaults() {
        XCTAssertEqual(PlacesDocument.read(homeText), PlacesDocument.Reading(places: [home]))
        let bare = PlacesDocument.read(#"{"work": {"latitude": 37.79, "longitude": -122.4}}"#)
        XCTAssertEqual(bare.places, [PlacesDocument.Place(name: "work", latitude: 37.79, longitude: -122.4, radius: 50, address: nil)])
        XCTAssertEqual(bare.notes, [])
        XCTAssertEqual(PlacesDocument.read(nil), PlacesDocument.Reading())
        XCTAssertEqual(PlacesDocument.read("{}"), PlacesDocument.Reading())
    }

    func testAFileThatIsNotAnObjectIsNoPlacesAndTheReason() {
        XCTAssertEqual(PlacesDocument.read("home: here"), PlacesDocument.Reading(unreadable: "is not JSON"))
        XCTAssertEqual(PlacesDocument.read("[1, 2]"), PlacesDocument.Reading(unreadable: "is not a JSON object"))
        // A number no double holds is not JSON to Foundation's parser, so the file is not read.
        XCTAssertEqual(PlacesDocument.read(#"{"x": {"latitude": 1e400, "longitude": 1}}"#), PlacesDocument.Reading(unreadable: "is not JSON"))
    }

    /// One entry that cannot be read costs itself and nothing else, and says why.
    func testABadEntryIsLeftOutAloneAndNoted() {
        let cases: [(String, String)] = [
            (#""x": 3"#, "x is not an object"),
            (#""x": {"longitude": 1}"#, "x.latitude is not a number from -90 to 90"),
            (#""x": {"latitude": 91, "longitude": 1}"#, "x.latitude is not a number from -90 to 90"),
            (#""x": {"latitude": "37.7", "longitude": 1}"#, "x.latitude is not a number from -90 to 90"),
            (#""x": {"latitude": true, "longitude": 1}"#, "x.latitude is not a number from -90 to 90"),
            (#""x": {"latitude": 1, "longitude": -181}"#, "x.longitude is not a number from -180 to 180"),
            (#""x": {"latitude": 1, "longitude": 1, "radius": 0}"#, "x.radius is not a number of metres from 5 to 5000"),
            (#""x": {"latitude": 1, "longitude": 1, "radius": 5001}"#, "x.radius is not a number of metres from 5 to 5000"),
            (#""x": {"latitude": 1, "longitude": 1, "radius": "30"}"#, "x.radius is not a number of metres from 5 to 5000"),
            (#""": {"latitude": 1, "longitude": 1}"#, " is not a name of one line and at most 64 characters"),
            (#""a\nb": {"latitude": 1, "longitude": 1}"#, "a b is not a name of one line and at most 64 characters"),
        ]
        for (entry, note) in cases {
            let reading = PlacesDocument.read("{\(entry), " + homeText.dropFirst())
            XCTAssertEqual(reading.places, [home], entry)
            XCTAssertEqual(reading.notes, [note], entry)
            XCTAssertNil(reading.unreadable, entry)
        }
        let long = String(repeating: "n", count: 65)
        let reading = PlacesDocument.read(#"{"\#(long)": {"latitude": 1, "longitude": 1}}"#)
        XCTAssertEqual(reading.places, [])
        XCTAssertEqual(reading.notes, [String(repeating: "n", count: 64) + "… is not a name of one line and at most 64 characters"])
    }

    /// An address that cannot be read, and a key nothing reads, cost themselves and not the place.
    func testABadAddressOrAStrayKeyKeepsThePlace() {
        let reading = PlacesDocument.read(#"{"home": {"latitude": 37.78167, "longitude": -122.45261, "radius": 30, "address": 3147, "lat": 1}}"#)
        var bare = home
        bare.address = nil
        XCTAssertEqual(reading.places, [bare])
        XCTAssertEqual(reading.notes, ["home.address is not text of one line and at most 200 characters", "home.lat is not a field a place has"])
    }

    func testPlacesPastTheLimitAreCounted() {
        let entries = (0..<103).map { #""p\#(String(format: "%03d", $0))": {"latitude": 1, "longitude": 1}"# }.joined(separator: ", ")
        let reading = PlacesDocument.read("{\(entries)}")
        XCTAssertEqual(reading.places.count, 100)
        XCTAssertEqual(reading.places.last?.name, "p099")
        XCTAssertEqual(reading.notes, ["3 more places than the 100 read"])
    }

    // MARK: The memory reads it

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("topo-places-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.appendingPathComponent("Vault", isDirectory: true)
    }

    private func write(_ text: String, to name: String, in database: any RecordDatabase, at when: Date) async throws {
        let store = MemoryStore(database: database)
        let writer = try await store.writer(for: DeviceID("hub"))
        try await writer.write(text, to: VaultPath(name)!, continuing: store.read(), at: when)
    }

    /// The whole path: a revision of `places.json` in the store, a sync, and the memory holds the
    /// places; a later revision replaces them, a bad one says why, and a sign-out forgets them.
    func testTheMemoryReadsThePlacesAfterEachSyncAndForgetsThemAtSignOut() async throws {
        let database = InMemoryRecordDatabase()
        let memory = Memory(directory: makeDirectory(), store: MemoryStore(database: database), device: DeviceID("phone"),
                            isSignedIn: { true }, ensureZone: {})
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        try await write("eggs", to: "Groceries.md", in: database, at: t0)
        await memory.sync()
        XCTAssertEqual(memory.places, PlacesDocument.Reading())

        try await write(homeText, to: PlacesDocument.name, in: database, at: t0.addingTimeInterval(10))
        await memory.sync()
        XCTAssertEqual(memory.places, PlacesDocument.Reading(places: [home]))

        try await write("not json", to: PlacesDocument.name, in: database, at: t0.addingTimeInterval(20))
        await memory.sync()
        XCTAssertEqual(memory.places, PlacesDocument.Reading(unreadable: "is not JSON"))

        try await write(homeText, to: PlacesDocument.name, in: database, at: t0.addingTimeInterval(30))
        await memory.sync()
        XCTAssertEqual(memory.places.places, [home])
        memory.forget()
        XCTAssertEqual(memory.places, PlacesDocument.Reading())
    }

    // MARK: topo location says it

    private struct Fixed: Locator {
        var fix: LocationFix
        func fix() async throws -> LocationFix { fix }
    }

    private func location(latitude: Double, longitude: Double, precise: Bool = true, nearest: String? = "3145 Geary Blvd, Lone Mountain, San Francisco",
                          _ reading: PlacesDocument.Reading) async -> String {
        let fix = LocationFix(latitude: latitude, longitude: longitude, accuracy: precise ? 5 : 3000, at: noon, precise: precise, place: nearest)
        let now = noon
        let tool = LocationTool(locator: Fixed(fix: fix), authorizer: PlacesPermission(), broker: PermissionBroker(),
                                places: { reading }, now: { now })
        let reply = await tool.run([])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        return reply.text.split(separator: "\n").dropFirst(4).joined(separator: "\n")
    }

    /// The issue's fix: 5 m of accuracy, the geocoder naming the shop downstairs.
    func testAFixInsideANamedPlaceSaysItsNameAndMarksTheGeocodersAddress() async {
        let reading = PlacesDocument.Reading(places: [home])
        let inside = await location(latitude: 37.78153, longitude: -122.45287, reading)
        XCTAssertEqual(inside, "place home (3147 Geary Blvd) — nearest address 3145 Geary Blvd, Lone Mountain, San Francisco")
        let alone = await location(latitude: 37.78153, longitude: -122.45287, nearest: nil, reading)
        XCTAssertEqual(alone, "place home (3147 Geary Blvd)")
        var unaddressed = home
        unaddressed.address = nil
        let plain = await location(latitude: 37.78153, longitude: -122.45287, PlacesDocument.Reading(places: [unaddressed]))
        XCTAssertEqual(plain, "place home — nearest address 3145 Geary Blvd, Lone Mountain, San Francisco")
    }

    func testAFixOutsideEveryNamedPlaceIsTheGeocodersLineMarkedAsSuch() async {
        // About 110 m north of the centre, past the 30 m radius.
        let outside = await location(latitude: 37.78267, longitude: -122.45261, PlacesDocument.Reading(places: [home]))
        XCTAssertEqual(outside, "place (nearest address) 3145 Geary Blvd, Lone Mountain, San Francisco")
        let none = await location(latitude: 37.78153, longitude: -122.45287, PlacesDocument.Reading())
        XCTAssertEqual(none, "place (nearest address) 3145 Geary Blvd, Lone Mountain, San Francisco")
        let nothing = await location(latitude: 37.78267, longitude: -122.45261, nearest: nil, PlacesDocument.Reading(places: [home]))
        XCTAssertEqual(nothing, "")
    }

    /// An approximate fix is kilometres wide: it is inside no place, however near its centre.
    func testAnApproximateFixIsInsideNoPlace() async {
        let approximate = await location(latitude: 37.78167, longitude: -122.45261, precise: false, PlacesDocument.Reading(places: [home]))
        XCTAssertEqual(approximate, "place (nearest address) 3145 Geary Blvd, Lone Mountain, San Francisco")
    }

    func testInsideSeveralPlacesTheNearestCentreIsSaid() async {
        let block = PlacesDocument.Place(name: "the block", latitude: 37.7819, longitude: -122.4529, radius: 400, address: nil)
        let both = PlacesDocument.Reading(places: [block, home])
        let nearHome = await location(latitude: 37.78166, longitude: -122.45262, both)
        XCTAssertTrue(nearHome.hasPrefix("place home (3147 Geary Blvd)"), nearHome)
        let downTheBlock = await location(latitude: 37.7830, longitude: -122.4529, both)
        XCTAssertTrue(downTheBlock.hasPrefix("place the block — nearest address"), downTheBlock)
    }

    /// What the document did not get is said back to whoever wrote it, three notes at most.
    func testWhatPlacesJSONDidNotGetIsNoted() async {
        let noted = await location(latitude: 0, longitude: 0, nearest: nil,
                                   PlacesDocument.Reading(places: [home], notes: ["a is not an object", "b\nc", "d", "e", "f"]))
        XCTAssertEqual(noted, "note places.json: a is not an object\nnote places.json: b c\nnote places.json: d\nnote places.json: and 2 more")
        let unreadable = await location(latitude: 0, longitude: 0, nearest: nil, PlacesDocument.Reading(unreadable: "is not JSON"))
        XCTAssertEqual(unreadable, "note places.json: is not JSON")
    }
}

private struct PlacesPermission: Authorizer {
    let name = "Location"
    func access() async -> Access { .granted }
    func request() async -> Bool { true }
}
