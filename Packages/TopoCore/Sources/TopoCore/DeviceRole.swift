import Foundation

/// What a device is to the mind, as the private database records it: `primary` or `viewer`.
/// Record `role/<device>`, type `Role`. A device decides its own role once at first launch and
/// keeps it; this record is how another device changes it, by the one deliberate control that
/// hands primary over: the taker writes the old holder's record as `viewer` and its own as
/// `primary` in one batch with its lease heartbeat, and every device reads its own record at
/// launch and on each answering pass, dropping to viewer when the record says so.
public struct DeviceRole: Hashable, Sendable {
    public static let recordType = "Role"
    static let recordPrefix = "role/"

    public enum Role: String, Sendable {
        case primary, viewer
    }

    public let device: DeviceID
    public var role: Role
    /// Which device wrote this, and when.
    public var setBy: DeviceID
    public var at: Date

    public init(device: DeviceID, role: Role, setBy: DeviceID, at: Date) {
        self.device = device
        self.role = role
        self.setBy = setBy
        self.at = at
    }

    public static func recordID(for device: DeviceID) -> RecordID { RecordID(recordPrefix + device.rawValue) }

    public init?(record: Record) {
        guard record.type == DeviceRole.recordType, record.id.name.hasPrefix(DeviceRole.recordPrefix),
              let roleString = record.string("role"), let role = Role(rawValue: roleString),
              let setBy = record.string("setBy"), let at = record.date("at") else { return nil }
        self.init(device: DeviceID(String(record.id.name.dropFirst(DeviceRole.recordPrefix.count))),
                  role: role, setBy: DeviceID(setBy), at: at)
    }

    /// The record for this role, over the version last read (`changeTag`) or created (nil).
    public func record(changeTag: String?) -> Record {
        Record(type: DeviceRole.recordType, id: DeviceRole.recordID(for: device), fields: [
            "role": .string(role.rawValue),
            "setBy": .string(setBy.rawValue),
            "at": .date(at),
        ], changeTag: changeTag)
    }

    /// The role recorded for a device, or nil when none has been written.
    public static func read(_ device: DeviceID, from database: any RecordDatabase) async throws -> DeviceRole? {
        try await database.fetch(recordID(for: device)).flatMap(DeviceRole.init(record:))
    }

    /// This role's record, tagged against whatever the database holds for the device now, so the
    /// save is a compare-and-set over that version or a create when there is none.
    public func record(over database: any RecordDatabase) async throws -> Record {
        record(changeTag: try await database.fetch(DeviceRole.recordID(for: device))?.changeTag)
    }
}
