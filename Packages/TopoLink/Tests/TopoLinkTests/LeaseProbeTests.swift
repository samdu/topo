import Foundation
import Network
import Testing
import TopoCore
@testable import TopoLink

@Suite struct LeaseProbeTests {
    let hub = DeviceID("hub")

    func lease(_ holder: DeviceID, epoch: Int64, port: UInt16) -> Lease {
        Lease(holder: holder, endpoint: "127.0.0.1:\(port)", epoch: epoch, expiresAt: Date() + 10)
    }

    @Test func serverConfirmsOnlyTheLeaseItHolds() async throws {
        let server = try LeaseProbeServer(advertising: nil) { device, epoch in device == DeviceID("hub") && epoch == 3 }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let probe = SocketLeaseProbe(timeout: 2)
        #expect(await probe.confirms(lease(hub, epoch: 3, port: port)))
        #expect(!(await probe.confirms(lease(hub, epoch: 4, port: port))))
        #expect(!(await probe.confirms(lease(DeviceID("phone"), epoch: 3, port: port))))
    }

    @Test func aClosedPortAndSilenceAreNo() async throws {
        let probe = SocketLeaseProbe(timeout: 0.5)
        // Bind a port and release it so nothing listens there.
        let placeholder = try LeaseProbeServer(advertising: nil) { _, _ in true }
        let closedPort = try await placeholder.start()
        await placeholder.stop()
        try await Task.sleep(for: .milliseconds(50))
        let started = Date()
        #expect(!(await probe.confirms(lease(hub, epoch: 1, port: closedPort))))
        #expect(Date().timeIntervalSince(started) < 2)

        // A listener that accepts and never answers.
        let silent = try NWListener(using: .tcp, on: .any)
        let bound = OneShot<UInt16>()
        silent.stateUpdateHandler = { state in if case .ready = state { bound.resume(.success(silent.port?.rawValue ?? 0)) } }
        silent.newConnectionHandler = { $0.start(queue: .global()) }
        silent.start(queue: .global())
        let silentPort = try await bound.value()
        defer { silent.cancel() }
        let began = Date()
        #expect(!(await probe.confirms(lease(hub, epoch: 1, port: silentPort))))
        let took = Date().timeIntervalSince(began)
        #expect(took >= 0.4 && took < 2)
    }

    @Test func aLeaseWithoutAnEndpointIsNo() async {
        let probe = SocketLeaseProbe(timeout: 0.5)
        #expect(!(await probe.confirms(Lease(holder: hub, endpoint: nil, epoch: 1, expiresAt: Date() + 10))))
        #expect(!(await probe.confirms(Lease(holder: hub, endpoint: "nonsense", epoch: 1, expiresAt: Date() + 10))))
    }

    @Test func endpointsParse() {
        #expect(SocketLeaseProbe.parse("10.0.0.2:4000")?.1.rawValue == 4000)
        #expect(SocketLeaseProbe.parse("[fe80::1]:4000")?.1.rawValue == 4000)
        #expect(SocketLeaseProbe.parse("[fe80::1]:4000")?.0.debugDescription.contains("fe80::1") == true)
        #expect(SocketLeaseProbe.parse("host") == nil)
        #expect(SocketLeaseProbe.parse(":4000") == nil)
        #expect(SocketLeaseProbe.parse("host:99999") == nil)
    }

    @Test func wireFormat() {
        let l = Lease(holder: DeviceID("a/b"), endpoint: nil, epoch: 7, expiresAt: Date())
        #expect(String(decoding: ProbeWire.request(l), as: UTF8.self) == "hold a/b 7\n")
        #expect(ProbeWire.parseRequest("hold a/b 7\n")?.0 == DeviceID("a/b"))
        #expect(ProbeWire.parseRequest("hold a/b 7")?.1 == 7)
        #expect(ProbeWire.parseRequest("hold a/b") == nil)
        #expect(ProbeWire.parseRequest("hello a/b 7") == nil)
    }
}
