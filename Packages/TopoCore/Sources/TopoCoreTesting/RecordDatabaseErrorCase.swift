import TopoCore

extension RecordDatabaseError {
    /// Which case an error is, without its payload: what a test names when the case is the
    /// point, since the code under test branches on it (a conflict is merged, a gone record is
    /// made again, an outage is retried, a refusal is not).
    public enum Case: Sendable, Equatable {
        case serverRecordChanged, unknownItem, unavailable, rejected
    }

    public var `case`: Case {
        switch self {
        case .serverRecordChanged: .serverRecordChanged
        case .unknownItem: .unknownItem
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }
}
