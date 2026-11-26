import Foundation
import dnssd

/// A public TCP port on the hub's router onto the nudge's channel, so a phone off the hub's
/// network reaches it (`NudgeKey.publicEndpoint`, `docs/hub.md`, *Off the home network*). Asked
/// of mDNSResponder (`DNSServiceNATPortMappingCreate`), which speaks NAT-PMP, PCP and UPnP to the
/// router, renews the mapping for as long as this process holds it and gives it up when the
/// process ends. Only the channel is mapped: it opens to the Apple ID's key alone.
final class HubPortMapping: @unchecked Sendable {
    private let lock = NSLock()
    private var ref: DNSServiceRef?
    private var mapped: String?
    private let queue = DispatchQueue(label: "zone.hexagon.topo.hub.portmap")

    /// The external `a.b.c.d:port` the router gave, or nil before an answer or with none.
    var endpoint: String? { lock.withLock { mapped } }

    /// Asks for `port` (the channel's) to be mapped; false when mDNSResponder refused the ask.
    func start(port: UInt16) -> Bool {
        stop()
        var made: DNSServiceRef?
        let status = DNSServiceNATPortMappingCreate(&made, 0, 0, DNSServiceProtocol(kDNSServiceProtocol_TCP),
                                                    port.bigEndian, port.bigEndian, 0, { _, _, _, error, address, _, _, external, _, context in
            guard let context else { return }
            let mapping = Unmanaged<HubPortMapping>.fromOpaque(context).takeUnretainedValue()
            mapping.answered(error: error, address: address, port: external)
        }, Unmanaged.passUnretained(self).toOpaque())
        guard status == kDNSServiceErr_NoError, let made else { return false }
        DNSServiceSetDispatchQueue(made, queue)
        lock.withLock { ref = made }
        return true
    }

    func stop() {
        let old = lock.withLock { () -> DNSServiceRef? in
            defer { ref = nil; mapped = nil }
            return ref
        }
        if let old { DNSServiceRefDeallocate(old) }
    }

    private func answered(error: DNSServiceErrorType, address: UInt32, port: UInt16) {
        let external = UInt16(bigEndian: port)
        let value: String?
        if error == kDNSServiceErr_NoError, address != 0, external != 0 {
            let bytes = withUnsafeBytes(of: address) { Array($0) } // network order in memory
            value = "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3]):\(external)"
        } else {
            value = nil
        }
        lock.withLock { mapped = value }
    }

    deinit { stop() }
}
