import Foundation

/// The name of a record, unique within the database. Maps to `CKRecord.ID.recordName`.
public struct RecordID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let name: String
    public init(_ name: String) { self.name = name }
    public var description: String { name }
}

/// The field types the package stores. Each maps to one `CKRecordValue`.
public enum FieldValue: Hashable, Sendable {
    case string(String)
    case int(Int64)
    case date(Date)
    case strings([String])
}

/// A record as the package sees it: a type, a name, fields, and the server's
/// opaque version tag. `changeTag == nil` means the record has never been
/// saved, so saving it is create-only.
public struct Record: Hashable, Sendable {
    public var type: String
    public var id: RecordID
    public var fields: [String: FieldValue]
    public var changeTag: String?

    public init(type: String, id: RecordID, fields: [String: FieldValue] = [:], changeTag: String? = nil) {
        self.type = type
        self.id = id
        self.fields = fields
        self.changeTag = changeTag
    }

    public subscript(field: String) -> FieldValue? {
        get { fields[field] }
        set { fields[field] = newValue }
    }

    public func string(_ field: String) -> String? {
        if case let .string(v)? = fields[field] { return v }
        return nil
    }

    public func int(_ field: String) -> Int64? {
        if case let .int(v)? = fields[field] { return v }
        return nil
    }

    public func date(_ field: String) -> Date? {
        if case let .date(v)? = fields[field] { return v }
        return nil
    }

    public func strings(_ field: String) -> [String]? {
        if case let .strings(v)? = fields[field] { return v }
        return nil
    }
}
