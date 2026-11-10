import HomeKit

@testable import Topo

/// A loaded home for the judge, answering at once.
@MainActor
final class LoadedHome: HomeStore {
    var authorization: HMHomeManagerAuthorizationStatus = []
    var changed: (@MainActor (HomeChange) -> Void)?
    var records: [HomeRecord] = []
    func homes() -> [HomeRecord] { records }
    func read(_ characteristic: String) async throws -> HomeValue? { nil }
    func write(_ value: HomeValue, to characteristic: String) async throws {}
    func run(scene: String) async throws {}
}

/// The home `topo control` and `topo widget` are tested over.
enum House {
    static let lampID = "6A1F0C2E-0000-4000-8000-000000000001"
    static let lockID = "9B7E3D10-0000-4000-8000-000000000003"

    private static func characteristic(_ id: String, _ name: String, _ format: String, valid: [Decimal]? = nil) -> HomeCharacteristic {
        HomeCharacteristic(id: id, name: name, format: format, readable: true, writable: true, minimum: nil, maximum: nil,
                           step: nil, validValues: valid, maxLength: nil, units: nil, value: nil)
    }

    /// A lamp, a lock, and a switch that only turns on.
    static let house = HomeRecord(
        id: "H1", name: "The flat", primary: true,
        accessories: [
            HomeAccessory(id: lampID, name: "Desk lamp", room: "Office", category: "Lightbulb", reachable: true, services: [
                HomeService(name: "Desk lamp", kind: "Lightbulb", characteristics: [
                    characteristic("L-power", "power", "bool"),
                    characteristic("L-once", "wake", "bool", valid: [1]),
                ]),
            ]),
            HomeAccessory(id: lockID, name: "Front door", room: "Hall", category: "Door Lock", reachable: true, services: [
                HomeService(name: "Front door", kind: "Lock Mechanism", characteristics: [
                    characteristic("D-target", "lock", "uint8", valid: [0, 1]),
                ]),
            ]),
        ],
        scenes: [HomeScene(id: "SC-1111", name: "Good night"),
                 HomeScene(id: "SC-LEAVE", name: "Leave", writes: [HMCharacteristicTypeTargetLockMechanismState])])
}
