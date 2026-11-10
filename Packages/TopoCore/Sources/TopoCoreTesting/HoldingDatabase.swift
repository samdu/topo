import Foundation
import os
import TopoCore

/// A database whose next save or fetch can be held unanswered, and whose bounded view
/// (`answering(within:)`) gives a request up at its bound as
/// `CloudKitRecordDatabase` does: each save and fetch through the view races
/// the request, a hold included, against the bound, and one the bound wins
/// throws `unavailable`. The request is not ended by that; a held request
/// stays held, and a save applies or not as the test says, until `release`.
///
/// It is the bound the lease asks for (`LeaseTiming.patience`) firing by
/// itself, where a hand-scripted stall shows only what the lease does once a
/// test says the time is up.
public final class HoldingDatabase: RecordDatabase, @unchecked Sendable {
    public let inner: InMemoryRecordDatabase
    private struct State {
        var holdNext = false
        var landing = false
        var holdNextFetch = false
        /// Held requests that have answered since they were let go.
        var answered = 0
        /// Every held request still waiting, each answered by the next `release`.
        var waiters: [CheckedContinuation<Void, Never>] = []
        /// Releases so far: a request held before one and not yet waiting when it came answers at once.
        var releases = 0
        var bounds: [TimeInterval] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(_ inner: InMemoryRecordDatabase) { self.inner = inner }

    /// The bounds the view was asked for, in order.
    public var bounds: [TimeInterval] { state.withLock { $0.bounds } }

    /// The next save is held until `release`. `landing`, the store applies it first and only
    /// the answer is held.
    public func holdNextSave(landing: Bool = false) {
        state.withLock {
            $0.holdNext = true
            $0.landing = landing
        }
    }

    /// The next fetch is held until `release`, and then reads the store.
    public func holdNextFetch() {
        state.withLock { $0.holdNextFetch = true }
    }

    /// How many held requests have answered, the store's answer or `unavailable`, since a release
    /// let them go.
    public var answered: Int { state.withLock { $0.answered } }

    /// How many requests are held now.
    public var held: Int { state.withLock { $0.waiters.count } }

    /// Whether a request is held now.
    public var holding: Bool { held > 0 }

    /// Lets every held request answer, a save with the store's answer if it landed, `unavailable` if not.
    public func release() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.releases += 1
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }

    public func answering(within seconds: TimeInterval) -> any RecordDatabase {
        state.withLock { $0.bounds.append(seconds) }
        return Bounded(base: self, seconds: seconds)
    }

    public struct RanOut: Error {}
    private struct NeverReached: Error {}

    public func save(_ records: [Record]) async throws -> [Record] {
        let (hold, landing, ticket) = state.withLock { state -> (Bool, Bool, Int) in
            defer { state.holdNext = false }
            return (state.holdNext, state.landing, state.releases)
        }
        guard hold else { return try await inner.save(records) }
        let saved = landing ? try await inner.save(records) : nil
        await wait(after: ticket)
        guard let saved else { throw RecordDatabaseError.unavailable(underlying: NeverReached()) }
        return saved
    }

    public func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] {
        let (hold, ticket) = state.withLock { state -> (Bool, Int) in
            defer { state.holdNextFetch = false }
            return (state.holdNextFetch, state.releases)
        }
        guard hold else { return try await inner.fetch(ids) }
        await wait(after: ticket)
        return try await inner.fetch(ids)
    }

    /// Waits for the first release after `ticket`, which is at once if one has already come, and
    /// counts the request answered.
    private func wait(after ticket: Int) async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                if state.releases > ticket { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        state.withLock { $0.answered += 1 }
    }

    public func query(_ query: RecordQuery) async throws -> [Record] { try await inner.query(query) }
    public func records(ofType type: String) async throws -> [Record] { try await inner.records(ofType: type) }

    /// The view `answering(within:)` hands back.
    private struct Bounded: RecordDatabase {
        let base: HoldingDatabase
        let seconds: TimeInterval

        func save(_ records: [Record]) async throws -> [Record] { try await within { try await base.save(records) } }
        func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await within { try await base.fetch(ids) } }
        func query(_ query: RecordQuery) async throws -> [Record] { try await within { try await base.query(query) } }
        func records(ofType type: String) async throws -> [Record] { try await within { try await base.records(ofType: type) } }

        /// `work`'s answer if it comes within the bound, `unavailable` at the bound otherwise;
        /// `work` itself is left to end as it does, its answer going nowhere.
        private func within<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
            let answered = OSAllocatedUnfairLock(initialState: false)
            var tasks: [Task<Void, Never>] = []
            defer { tasks.forEach { $0.cancel() } }
            let seconds = seconds
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                let answer: @Sendable (Result<T, Error>) -> Void = { result in
                    let first = answered.withLock { done in
                        defer { done = true }
                        return !done
                    }
                    if first { continuation.resume(with: result) }
                }
                tasks.append(Task { answer(await Result { try await work() }) })
                tasks.append(Task {
                    guard (try? await Task.sleep(for: .seconds(seconds))) != nil else { return }
                    answer(.failure(RecordDatabaseError.unavailable(underlying: RanOut())))
                })
            }
        }
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
