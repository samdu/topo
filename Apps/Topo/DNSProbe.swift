#if DEBUG
// Throwaway (plan-dns-forwarder Task 1, never merged): runs, on the phone, the exact dnssd call the
// guest's DNS forwarder will make, and records every callback, the loopback binds, and whether
// loopback NWListeners reach ready.
import Foundation
import Network
import dnssd
import TopoUserland

@MainActor enum DNSProbe {
    static let queries: [(String, UInt16)] = [
        ("whoami.akamai.net", 1),
        ("pane.burmese-egret.ts.net", 1),
        ("topo-nx-7f3a9c2e.hexagon.zone", 1),   // NXDOMAIN (dig, 2026-09-28)
        ("github.com", 28),                     // NODATA: A only
        ("www.github.com", 1),                  // one CNAME
        ("www.github.com", 28),                 // CNAME then NODATA
        ("www.apple.com", 1),                   // three CNAMEs
    ]

    static func run() async -> String {
        var lines = ["probe \(ISO8601DateFormatter().string(from: Date()))",
                     "systemNameservers: \(Guest.systemNameservers())"]
        lines += binds()
        lines += await listeners()
        let queue = DispatchQueue(label: "zone.hexagon.topo.dns-probe")
        let results = await withTaskGroup(of: (Int, [String]).self) { group in
            for (index, query) in queries.enumerated() {
                group.addTask { (index, await Query.run(name: query.0, type: query.1, queue: queue)) }
            }
            var results = [Int: [String]]()
            for await (index, out) in group { results[index] = out }
            return results
        }
        for index in queries.indices { lines += results[index] ?? [] }
        return lines.joined(separator: "\n")
    }

    private static func binds() -> [String] {
        var out = [String]()
        for (label, type) in [("udp", SOCK_DGRAM), ("tcp", SOCK_STREAM)] {
            for port: UInt16 in [53, 0] {
                let fd = socket(AF_INET, type, 0)
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                let error = errno
                out.append("bind \(label) 127.0.0.1:\(port): " +
                           (result == 0 ? "ok" : "errno \(error) \(String(cString: strerror(error)))"))
                close(fd)
            }
        }
        return out
    }

    private static func listeners() async -> [String] {
        var out = [String]()
        for (label, parameters) in [("udp", NWParameters.udp), ("tcp", NWParameters.tcp)] {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            guard let listener = try? NWListener(using: parameters) else {
                out.append("NWListener \(label): init threw"); continue
            }
            let state: String = await withCheckedContinuation { continuation in
                let once = Once(continuation)
                listener.newConnectionHandler = { $0.cancel() }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.resume("ready port \(listener.port.map { "\($0.rawValue)" } ?? "?")")
                    case .failed(let error): once.resume("failed \(error)")
                    case .waiting(let error): once.resume("waiting \(error)")
                    default: break
                    }
                }
                listener.start(queue: .main)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { once.resume("no state in 3 s") }
            }
            listener.cancel()
            out.append("NWListener \(label) 127.0.0.1: \(state)")
        }
        return out
    }
}

private final class Once: @unchecked Sendable {
    private var continuation: CheckedContinuation<String, Never>?
    init(_ continuation: CheckedContinuation<String, Never>) { self.continuation = continuation }
    func resume(_ value: String) {
        DispatchQueue.main.async { self.continuation?.resume(returning: value); self.continuation = nil }
    }
}

/// One `DNSServiceQueryRecord` with `ReturnIntermediates`, interface 0, class IN, driven on
/// `queue`, deallocated there after 6 s, every callback recorded.
private final class Query: @unchecked Sendable {
    let name: String
    let type: UInt16
    let start = Date()
    var lines: [String]
    var ref: DNSServiceRef?

    init(name: String, type: UInt16) {
        self.name = name
        self.type = type
        lines = ["query \(name) type \(type)"]
    }

    static func run(name: String, type: UInt16, queue: DispatchQueue) async -> [String] {
        let query = Query(name: name, type: type)
        return await withCheckedContinuation { continuation in
            queue.async {
                let context = Unmanaged.passRetained(query).toOpaque()
                let error = DNSServiceQueryRecord(&query.ref, DNSServiceFlags(kDNSServiceFlagsReturnIntermediates), 0,
                                                  name, type, UInt16(kDNSServiceClass_IN), callback, context)
                if error != kDNSServiceErr_NoError {
                    query.lines.append("  QueryRecord error \(error)")
                } else {
                    let set = DNSServiceSetDispatchQueue(query.ref, queue)
                    if set != kDNSServiceErr_NoError { query.lines.append("  SetDispatchQueue error \(set)") }
                }
                queue.asyncAfter(deadline: .now() + 6) {
                    if let ref = query.ref { DNSServiceRefDeallocate(ref) }
                    query.ref = nil
                    query.lines.append("  deallocated at \(query.elapsed) ms")
                    Unmanaged<Query>.fromOpaque(context).release()
                    continuation.resume(returning: query.lines)
                }
            }
        }
    }

    var elapsed: Int { Int(Date().timeIntervalSince(start) * 1000) }
}

private let callback: DNSServiceQueryRecordReply = { _, flags, interface, error, fullname, rrtype, _, rdlen, rdata, ttl, context in
    guard let context else { return }
    let query = Unmanaged<Query>.fromOpaque(context).takeUnretainedValue()
    var marks = [String]()
    if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) != 0 { marks.append("MoreComing") }
    if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 { marks.append("Add") }
    let name = fullname.map { String(cString: $0) } ?? "-"
    let bytes = rdata.map { Array(UnsafeRawBufferPointer(start: $0, count: Int(rdlen))) } ?? []
    query.lines.append("  +\(query.elapsed)ms flags 0x\(String(flags, radix: 16)) [\(marks.joined(separator: ","))] " +
                       "if \(interface) err \(errorName(error)) \(name) type \(rrtype) ttl \(ttl) " +
                       "rdlen \(rdlen) \(render(rrtype, bytes))")
}

private func errorName(_ error: DNSServiceErrorType) -> String {
    switch Int(error) {
    case kDNSServiceErr_NoError: "NoError"
    case kDNSServiceErr_NoSuchName: "NoSuchName"
    case kDNSServiceErr_NoSuchRecord: "NoSuchRecord"
    case kDNSServiceErr_Timeout: "Timeout"
    case kDNSServiceErr_DefunctConnection: "DefunctConnection"
    case kDNSServiceErr_PolicyDenied: "PolicyDenied"
    default: "\(error)"
    }
}

private func render(_ type: UInt16, _ bytes: [UInt8]) -> String {
    switch type {
    case 1 where bytes.count == 4: return bytes.map(String.init).joined(separator: ".")
    case 28 where bytes.count == 16:
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        _ = bytes.withUnsafeBytes { inet_ntop(AF_INET6, $0.baseAddress, &text, socklen_t(text.count)) }
        return String(cString: text)
    case 5: return labels(bytes)
    default: return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// An uncompressed wire name, as dnssd hands a CNAME's rdata.
private func labels(_ bytes: [UInt8]) -> String {
    var parts = [String](), index = 0
    while index < bytes.count, bytes[index] != 0 {
        let length = Int(bytes[index])
        guard length < 64, index + 1 + length <= bytes.count else { return "raw " + bytes.map { String(format: "%02x", $0) }.joined() }
        parts.append(String(decoding: bytes[(index + 1)..<(index + 1 + length)], as: UTF8.self))
        index += 1 + length
    }
    return parts.joined(separator: ".") + "."
}
#endif
