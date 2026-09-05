import Foundation
import Testing
import TopoCore
import TopoCoreTesting

@Suite struct PairingTests {
    let db = InMemoryRecordDatabase()
    var directory: DeviceDirectory { DeviceDirectory(database: db) }

    func device(_ id: DeviceID, kind: Device.Kind, key: String = "key", endpoints: [String] = []) -> Device {
        Device(id: id, name: id.rawValue.capitalized, kind: kind, publicKey: key, endpoints: endpoints,
               registeredAt: tA, seenAt: tA)
    }

    @Test func registerCreatesThenUpdatesKeepingPairings() async throws {
        let mac = try await directory.register(device(hub, kind: .mac, endpoints: ["10.0.0.2:4000"]))
        #expect(mac.pairedWith.isEmpty)
        _ = try await directory.register(device(phone, kind: .phone))
        _ = try await directory.pair(PairingCode(mac), as: phone)

        var later = device(hub, kind: .mac, endpoints: ["10.0.0.9:4000"])
        later.name = "Study Mac"
        later.seenAt = tA + 60
        let updated = try await directory.register(later)
        #expect(updated.name == "Study Mac")
        #expect(updated.endpoints == ["10.0.0.9:4000"])
        #expect(updated.seenAt == tA + 60)
        #expect(updated.registeredAt == tA)
        #expect(updated.pairedWith == [phone])
        #expect(try await directory.all().map(\.id) == [phone, hub])
    }

    @Test func pairingListsEachInTheOther() async throws {
        let mac = try await directory.register(device(hub, kind: .mac, key: "mackey"))
        _ = try await directory.register(device(phone, kind: .phone, key: "phonekey"))
        let paired = try await directory.pair(PairingCode(mac), as: phone)
        #expect(paired.id == hub && paired.pairedWith == [phone])
        #expect(try await directory.device(phone)?.pairedWith == [hub])
        // Pairing again changes nothing.
        _ = try await directory.pair(PairingCode(mac), as: phone)
        #expect(try await directory.device(hub)?.pairedWith == [phone])
    }

    @Test func pairingRefusesAWrongKeyAnUnknownDeviceAndItself() async throws {
        let mac = try await directory.register(device(hub, kind: .mac, key: "mackey"))
        _ = try await directory.register(device(phone, kind: .phone))
        var forged = PairingCode(mac)
        forged.publicKey = "someone-else"
        await #expect(throws: PairingError.keyMismatch(hub)) { try await directory.pair(forged, as: phone) }
        let ghost = PairingCode(device: watch, name: "Watch", publicKey: "k", endpoint: nil)
        await #expect(throws: PairingError.unknownDevice(watch)) { try await directory.pair(ghost, as: phone) }
        await #expect(throws: PairingError.selfPairing) { try await directory.pair(PairingCode(mac), as: hub) }
        #expect(try await directory.device(hub)?.pairedWith == [])
    }

    @Test func twoScannersPairingAtOnceBothLand() async throws {
        let mac = try await directory.register(device(hub, kind: .mac))
        _ = try await directory.register(device(phone, kind: .phone))
        _ = try await directory.register(device(watch, kind: .watch))
        let barrier = Barrier(parties: 2)
        await db.setBeforeSave { records in
            if records.first?.id == Device.recordID(for: hub) { await barrier.arrive() }
        }
        async let a = directory.pair(PairingCode(mac), as: phone)
        async let b = directory.pair(PairingCode(mac), as: watch)
        _ = try await [a, b]
        #expect(Set(try await directory.device(hub)?.pairedWith ?? []) == [phone, watch])
    }

    @Test func pairingCodeRoundTripsAndRejectsOtherURLs() throws {
        let code = PairingCode(device: DeviceID("mac/1"), name: "Sam's Mac", publicKey: "a+b/c=", endpoint: "[fe80::1]:4000")
        let back = try #require(PairingCode(url: code.url))
        #expect(back == code)
        #expect(code.url.scheme == "topo" && code.url.host == "pair")
        #expect(PairingCode(url: URL(string: "topo://pair?v=2&d=x&k=y")!) == nil)
        #expect(PairingCode(url: URL(string: "topo://pair?v=1&d=x")!) == nil)
        #expect(PairingCode(url: URL(string: "https://example.com/pair?v=1&d=x&k=y")!) == nil)
        let bare = try #require(PairingCode(url: URL(string: "topo://pair?v=1&d=x&k=y")!))
        #expect(bare.name == "x" && bare.endpoint == nil)
    }

    @Test func deviceRecordRoundTripsAndRejectsMalformed() async throws {
        let mac = device(hub, kind: .mac, key: "k", endpoints: ["a:1", "b:2"])
        _ = try await directory.register(mac)
        let read = try await directory.device(hub)
        #expect(read == mac)
        #expect(Device(record: Record(type: Device.recordType, id: RecordID("device/x"), fields: ["name": .string("x")])) == nil)
        #expect(Device(record: Record(type: Device.recordType, id: RecordID("x"), fields: mac.recordFieldsForTest)) == nil)
    }

    @Test func touchMovesSeenAt() async throws {
        _ = try await directory.register(device(hub, kind: .mac))
        try await directory.touch(hub, at: tA + 5)
        #expect(try await directory.device(hub)?.seenAt == tA + 5)
        await #expect(throws: PairingError.unknownDevice(watch)) { try await directory.touch(watch, at: tA) }
    }
}

private extension Device {
    var recordFieldsForTest: [String: FieldValue] {
        ["name": .string(name), "kind": .string(kind.rawValue), "publicKey": .string(publicKey),
         "registeredAt": .date(registeredAt), "seenAt": .date(seenAt)]
    }
}
