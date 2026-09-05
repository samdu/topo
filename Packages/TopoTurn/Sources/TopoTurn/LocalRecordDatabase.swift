import Foundation
import TopoCore

/// `RecordDatabase` in one JSON file, with CloudKit's conflict semantics: a save with no tag
/// creates only, a tagged save applies only to that version, and a batch applies all or none.
/// The device's log when there is no iCloud account to hold it.
public final class LocalRecordDatabase: RecordDatabase, @unchecked Sendable {
    private let url: URL?
    private let lock = NSLock()
    private var store: [RecordID: Record] = [:]
    private var tag = 0

    /// Pass nil for a database that lives only in memory.
    public init(url: URL?) throws {
        self.url = url
        if let url, let data = try? Data(contentsOf: url) {
            let file = try JSONDecoder().decode(File.self, from: data)
            store = Dictionary(uniqueKeysWithValues: file.records.map { ($0.record.id, $0.record) })
            tag = file.tag
        }
    }

    public func save(_ records: [Record]) async throws -> [Record] {
        try lock.withLock {
            for record in records {
                let current = store[record.id]
                if let current, current.changeTag != record.changeTag {
                    throw RecordDatabaseError.serverRecordChanged(record.id, server: current)
                }
                if current == nil, record.changeTag != nil {
                    throw RecordDatabaseError.unknownItem(record.id)
                }
            }
            var saved: [Record] = []
            for record in records {
                tag += 1
                var next = record
                next.changeTag = String(tag)
                store[record.id] = next
                saved.append(next)
            }
            try persist()
            return saved
        }
    }

    public func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] {
        lock.withLock { Dictionary(uniqueKeysWithValues: ids.compactMap { id in store[id].map { (id, $0) } }) }
    }

    public func query(_ query: RecordQuery) async throws -> [Record] {
        lock.withLock {
            store.values.filter { record in
                record.type == query.type && query.filters.allSatisfy { filter in
                    guard let value = record.fields[filter.field] else { return false }
                    switch (filter.op, value, filter.value) {
                    case (.equals, _, _): return value == filter.value
                    case (.greaterThan, .int(let a), .int(let b)): return a > b
                    case (.greaterThan, .date(let a), .date(let b)): return a > b
                    case (.greaterThan, .string(let a), .string(let b)): return a > b
                    default: return false
                    }
                }
            }
        }
    }

    private func persist() throws {
        guard let url else { return }
        let file = File(tag: tag, records: store.values.map(CodableRecord.init))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(file).write(to: url, options: .atomic)
    }

    struct File: Codable {
        var tag: Int
        var records: [CodableRecord]
    }

    struct CodableRecord: Codable {
        enum Value: Codable {
            case string(String), int(Int64), date(Date), strings([String])
        }
        var type: String
        var id: String
        var changeTag: String?
        var fields: [String: Value]

        init(_ record: Record) {
            type = record.type
            id = record.id.name
            changeTag = record.changeTag
            fields = record.fields.mapValues {
                switch $0 {
                case .string(let v): .string(v)
                case .int(let v): .int(v)
                case .date(let v): .date(v)
                case .strings(let v): .strings(v)
                }
            }
        }

        var record: Record {
            Record(type: type, id: RecordID(id), fields: fields.mapValues {
                switch $0 {
                case .string(let v): FieldValue.string(v)
                case .int(let v): .int(v)
                case .date(let v): .date(v)
                case .strings(let v): .strings(v)
                }
            }, changeTag: changeTag)
        }
    }
}
