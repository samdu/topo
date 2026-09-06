import Foundation
import Network
import Testing
import TopoCore
@testable import TopoLink

/// The format Womble's `SurfaceWire` writes, read from this side. Both files
/// carry it, so both are tested against the same lines.
@Suite struct SurfaceWireTests {
    let pad = DeviceID("womble-1")

    @Test func readsAnAdvert() throws {
        let surface = try #require(SurfaceWire.surface(device: pad, fields: [
            "v": "1", "n": "Drawer iPad", "k": "womble", "a": "mac-1,phone-2",
        ]))
        #expect(surface.name == "Drawer iPad")
        #expect(surface.kind == "womble")
        #expect(surface.agents == [DeviceID("mac-1"), DeviceID("phone-2")])
        #expect(!surface.agentsArePartial)
        #expect(surface.registers(DeviceID("mac-1")))
    }

    @Test func aScreenWithNoAgentsIsStillAScreen() throws {
        let surface = try #require(SurfaceWire.surface(device: pad, fields: ["v": "1", "n": "Wall", "k": "womble", "a": ""]))
        #expect(surface.agents.isEmpty)
    }

    @Test func saysWhenTheRosterDidNotFit() throws {
        let surface = try #require(SurfaceWire.surface(device: pad, fields: [
            "v": "1", "n": "Wall", "k": "womble", "a": "mac-1", "a+": "1",
        ]))
        #expect(surface.agentsArePartial)
    }

    /// The lease probe advertises on this type too, so what is not a surface
    /// has to be passed over rather than listed as a screen.
    @Test func anythingWithoutTheThreeFieldsIsNotASurface() {
        #expect(SurfaceWire.surface(device: pad, fields: [:]) == nil)
        #expect(SurfaceWire.surface(device: pad, fields: ["n": "Drawer iPad", "k": "womble"]) == nil)
        #expect(SurfaceWire.surface(device: pad, fields: ["v": "2", "n": "Drawer iPad", "k": "womble"]) == nil)
        #expect(SurfaceWire.surface(device: pad, fields: ["v": "1", "k": "womble"]) == nil)
        #expect(SurfaceWire.surface(device: pad, fields: ["v": "1", "n": "Drawer iPad"]) == nil)
    }

    @Test func readsTheFourAnswers() {
        #expect(SurfaceWire.answer("roster mac-1,phone-2") == .roster([DeviceID("mac-1"), DeviceID("phone-2")]))
        #expect(SurfaceWire.answer("roster ") == .roster([]))
        #expect(SurfaceWire.answer("roster") == .roster([]))
        #expect(SurfaceWire.answer("ok mac-1\n") == .registered(DeviceID("mac-1")))
        #expect(SurfaceWire.answer("wait") == .waiting)
        #expect(SurfaceWire.answer("no not now") == .refused("not now"))
        #expect(SurfaceWire.answer("something else") == nil)
        #expect(SurfaceWire.answer("") == nil)
    }

    @Test func writesTheTwoRequests() {
        #expect(String(decoding: SurfaceWire.rosterRequest, as: UTF8.self) == "roster\n")
        let code = PairingCode(device: DeviceID("mac-1"), name: "Sam's Mac mini", publicKey: "AAAA", endpoint: "10.0.0.2:1234")
        let line = String(decoding: SurfaceWire.registerRequest(code), as: UTF8.self)
        #expect(line.hasPrefix("register topo://pair?"))
        #expect(line.hasSuffix("\n"))
        // The other end reads it back as the code it was made from.
        let url = try? #require(URL(string: String(line.dropFirst("register ".count).trimmingCharacters(in: .whitespacesAndNewlines))))
        #expect(PairingCode(url: url!) == code)
    }
}

/// The asking half, against a listener that answers the way Womble does.
@Suite struct SurfaceAskTests {
    /// A stand-in for a screen: one line in, one line out.
    actor FakeSurface {
        private let listener: NWListener
        private let answer: String
        private(set) var heard: [String] = []
        private var ready: CheckedContinuation<UInt16, any Error>?

        init(answering answer: String) throws {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            listener = try NWListener(using: parameters, on: .any)
            self.answer = answer
        }

        func start() async throws -> UInt16 {
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.serve(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { await self?.state(state) }
            }
            listener.start(queue: .global())
            return try await withCheckedThrowingContinuation { self.ready = $0 }
        }

        func stop() { listener.cancel() }

        private func state(_ state: NWListener.State) {
            switch state {
            case .ready:
                ready?.resume(returning: listener.port?.rawValue ?? 0)
                ready = nil
            case .failed(let error):
                ready?.resume(throwing: error)
                ready = nil
            default:
                break
            }
        }

        private func serve(_ connection: NWConnection) async {
            connection.start(queue: .global())
            defer { connection.cancel() }
            guard let line = try? await connection.readLine(maximum: 2048) else { return }
            heard.append(line)
            try? await connection.send(Data((answer + "\n").utf8))
        }
    }

    func surface(_ device: DeviceID = DeviceID("womble-1")) -> Surface {
        Surface(device: device, name: "Drawer iPad", kind: "womble", agents: [], agentsArePartial: true)
    }

    @Test func asksForTheWholeRosterOverTheSocket() async throws {
        let screen = try FakeSurface(answering: "roster mac-1,phone-2")
        let port = try await screen.start()
        defer { Task { await screen.stop() } }
        let browser = SurfaceBrowser(timeout: 2)
        await browser.seed(surface(), at: NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        #expect(try await browser.roster(of: surface()) == [DeviceID("mac-1"), DeviceID("phone-2")])
        #expect(await screen.heard == ["roster"])
    }

    @Test func aRegistrationTheRoomHasNotAnsweredIsWaitingRatherThanAFailure() async throws {
        let screen = try FakeSurface(answering: "wait")
        let port = try await screen.start()
        defer { Task { await screen.stop() } }
        let browser = SurfaceBrowser(timeout: 2)
        await browser.seed(surface(), at: NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        let code = PairingCode(device: DeviceID("mac-1"), name: "Mac", publicKey: "AAAA", endpoint: nil)
        #expect(try await browser.register(code, with: surface()) == .waiting)
        #expect(await screen.heard.first?.hasPrefix("register topo://pair?") == true)
    }

    /// A screen that has gone dark between the browse and the ask is not
    /// somewhere to hang: there is no endpoint for it, and it says so.
    @Test func askingASurfaceThatIsNotHereFailsAtOnce() async throws {
        let browser = SurfaceBrowser(timeout: 2)
        await #expect(throws: SurfaceError.notHere(DeviceID("womble-1"))) {
            try await browser.roster(of: surface())
        }
    }

    @Test func gibberishFromTheOtherEndIsNotAnAnswer() async throws {
        let screen = try FakeSurface(answering: "hello")
        let port = try await screen.start()
        defer { Task { await screen.stop() } }
        let browser = SurfaceBrowser(timeout: 2)
        await browser.seed(surface(), at: NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        await #expect(throws: SurfaceError.notASurface) {
            try await browser.roster(of: surface())
        }
    }
}
