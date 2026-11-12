import Foundation
@testable import Topo

/// A bookmark store with no keychain to write to and nothing to keep.
final class InMemoryBookmarkStore: VaultBookmarkStore, @unchecked Sendable {
    private let lock = NSLock()
    private var bookmark: Data?
    /// What a save should do instead of keeping the bookmark, for the test of a commit that
    /// fails: the home has not moved, so the files stay where they were.
    var refuseSave: (any Swift.Error)?

    init(_ bookmark: Data? = nil) { self.bookmark = bookmark }

    func load() throws -> Data? { lock.withLock { bookmark } }
    func save(_ bookmark: Data) throws {
        if let refuseSave { throw refuseSave }
        lock.withLock { self.bookmark = bookmark }
    }
    func clear() throws { lock.withLock { bookmark = nil } }
}
