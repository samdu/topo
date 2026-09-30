import Foundation
import dnssd

/// One callback of a record query, as dnssd's `DNSServiceQueryRecordReply` gives it.
public struct RecordAnswer: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// A record: `name`, `type`, `ttl` and `rdata` are its.
        case record
        /// `kDNSServiceErr_NoSuchName`: the name does not exist.
        case noSuchName
        /// `kDNSServiceErr_NoSuchRecord`: the name has no record of the type asked for.
        case noSuchRecord
        /// Any other error code.
        case failed(Int32)
    }

    public let outcome: Outcome
    /// `kDNSServiceFlagsMoreComing`: another callback of this batch is queued behind this one.
    public let moreComing: Bool
    /// `kDNSServiceFlagsAdd`: the record is there (clear, it went away).
    public let add: Bool
    /// The record's name in dnssd's text form, as bytes.
    public let name: [UInt8]
    public let type: UInt16
    public let ttl: UInt32
    public let rdata: [UInt8]

    public init(outcome: Outcome, moreComing: Bool, add: Bool, nameBytes: [UInt8], type: UInt16, ttl: UInt32,
                rdata: [UInt8]) {
        self.outcome = outcome
        self.moreComing = moreComing
        self.add = add
        self.name = nameBytes
        self.type = type
        self.ttl = ttl
        self.rdata = rdata
    }

    public init(outcome: Outcome, moreComing: Bool = false, add: Bool = true, name: String = "", type: UInt16 = 0,
                ttl: UInt32 = 0, rdata: [UInt8] = []) {
        self.outcome = outcome
        self.moreComing = moreComing
        self.add = add
        self.name = Array(name.utf8)
        self.type = type
        self.ttl = ttl
        self.rdata = rdata
    }
}

/// A query under way; cancelled on the queue it was started on, after which nothing more is
/// delivered.
public protocol ResolverQuery: AnyObject, Sendable {
    func cancel()
}

/// Where the forwarder's questions go: dnssd on the phone, a script in the tests.
public protocol RecordResolver: Sendable {
    /// Asks for `type` records of `name` (dnssd's text form, class IN) and calls `answer` on `queue`
    /// for each callback until the query is cancelled. Called on `queue`.
    func query(name: String, type: UInt16, queue: DispatchSerialQueue,
               answer: @escaping @Sendable (RecordAnswer) -> Void) -> any ResolverQuery
}

/// The system resolver: `DNSServiceQueryRecord` with `kDNSServiceFlagsReturnIntermediates` (so
/// CNAMEs and negative answers are delivered), on every interface, class IN, driven by
/// `DNSServiceSetDispatchQueue` on the caller's queue and deallocated there. What the phone's
/// own lookups get — Private Relay, a VPN's resolver and its split DNS, a DNS profile — this gets.
public struct SystemRecordResolver: RecordResolver {
    public init() {}

    public func query(name: String, type: UInt16, queue: DispatchSerialQueue,
                      answer: @escaping @Sendable (RecordAnswer) -> Void) -> any ResolverQuery {
        let query = SystemQuery(answer: answer)
        let context = Unmanaged.passRetained(query).toOpaque()
        var ref: DNSServiceRef?
        var error = DNSServiceQueryRecord(&ref, DNSServiceFlags(kDNSServiceFlagsReturnIntermediates), 0, name, type,
                                          UInt16(kDNSServiceClass_IN), systemQueryReply, context)
        if error == kDNSServiceErr_NoError, let ref {
            error = DNSServiceSetDispatchQueue(ref, queue)
            if error != kDNSServiceErr_NoError { DNSServiceRefDeallocate(ref) }
        }
        if error == kDNSServiceErr_NoError, let ref {
            query.ref = ref
            query.context = context
        } else {
            Unmanaged<SystemQuery>.fromOpaque(context).release()
            // Delivered after this call returns, as a callback would be.
            let failed = RecordAnswer(outcome: .failed(error))
            queue.async { answer(failed) }
        }
        return query
    }
}

/// Only ever touched on the forwarder's queue: made there, called back there, cancelled there.
private final class SystemQuery: ResolverQuery, @unchecked Sendable {
    let answer: @Sendable (RecordAnswer) -> Void
    var ref: DNSServiceRef?
    var context: UnsafeMutableRawPointer?

    init(answer: @escaping @Sendable (RecordAnswer) -> Void) { self.answer = answer }

    func cancel() {
        if let ref { DNSServiceRefDeallocate(ref) }
        ref = nil
        if let context { Unmanaged<SystemQuery>.fromOpaque(context).release() }
        context = nil
    }
}

private let systemQueryReply: DNSServiceQueryRecordReply = { _, flags, _, error, fullname, rrtype, _, rdlen, rdata, ttl, context in
    guard let context else { return }
    let query = Unmanaged<SystemQuery>.fromOpaque(context).takeUnretainedValue()
    let outcome: RecordAnswer.Outcome = switch Int(error) {
    case kDNSServiceErr_NoError: .record
    case kDNSServiceErr_NoSuchName: .noSuchName
    case kDNSServiceErr_NoSuchRecord: .noSuchRecord
    default: .failed(error)
    }
    let bytes = rdata.map { Array(UnsafeRawBufferPointer(start: $0, count: Int(rdlen))) } ?? []
    let name = fullname.map { Array(UnsafeRawBufferPointer(start: $0, count: strlen($0))) } ?? []
    query.answer(RecordAnswer(outcome: outcome, moreComing: flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) != 0,
                              add: flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
                              nameBytes: name, type: rrtype, ttl: ttl, rdata: bytes))
}
