import Foundation
import Network

/// Advertises this screen on the LAN and answers the two things a surface
/// is asked: what it is called, and who is registered to it.
///
/// The advert is a `_topo._tcp` service named by this screen's own ID, with
/// the display name and the roster in its TXT record, so a hub browsing the
/// house sees every screen and whose agents each one answers for without
/// connecting to any of them. The socket is for the rest: the whole roster
/// when it is too long for TXT, and registration, which is a question for
/// the room rather than something the network decides.
///
/// Network framework, not `NetService`, because the listener and the advert
/// are one object here; both are iOS 12, which is this bundle's floor.
final class SurfaceServer {
    private let device: DeviceID
    private let name: String
    private let roster: SurfaceRoster
    private let queue = DispatchQueue(label: "zone.hexagon.topo.womble.surface")
    private var listener: NWListener?

    /// Why the advert is not up, if it is not. On iOS 14 and later the
    /// usual reason is that the app has not been allowed on the local
    /// network; the screen says so rather than looking merely quiet.
    private(set) var failure: String?
    var failureChanged: (() -> Void)?

    init(device: DeviceID, name: String, roster: SurfaceRoster) {
        self.device = device
        self.name = name
        self.roster = roster
        roster.rosterChanged = { [weak self] in self?.republish() }
    }

    var isAdvertising: Bool { listener != nil && failure == nil }

    func start() {
        guard listener == nil else { return }
        let listener: NWListener
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            listener = try NWListener(using: parameters)
        } catch {
            set(failure: "\(error)")
            return
        }
        listener.service = service()
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.set(failure: nil)
            case .failed(let error), .waiting(let error):
                self?.set(failure: "\(error)")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func service() -> NWListener.Service {
        let txt = NetService.data(fromTXTRecord: SurfaceWire.txt(name: name, agents: roster.agents))
        return NWListener.Service(name: device.rawValue, type: SurfaceWire.serviceType, domain: nil, txtRecord: txt)
    }

    /// The roster changed, so the advert has to say so.
    private func republish() {
        guard let listener = listener else { return }
        listener.service = service()
    }

    private func set(failure: String?) {
        guard failure != self.failure else { return }
        self.failure = failure
        DispatchQueue.main.async { [weak self] in self?.failureChanged?() }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        readLine(connection, buffer: Data()) { [weak self] line in
            guard let self = self, let line = line, let request = SurfaceWire.request(line) else {
                self?.reply(connection, SurfaceWire.line(.refused("unreadable")))
                return
            }
            // The roster is the screen's, and the screen is the main thread's.
            DispatchQueue.main.async {
                let answer = self.roster.answer(to: request)
                self.reply(connection, SurfaceWire.line(answer))
            }
        }
    }

    private func reply(_ connection: NWConnection, _ line: String) {
        connection.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Reads until a newline, the end of the stream, or the limit, however
    /// TCP splits it.
    private func readLine(_ connection: NWConnection, buffer: Data, completion: @escaping (String?) -> Void) {
        if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            completion(String(decoding: buffer[..<newline], as: UTF8.self))
            return
        }
        guard buffer.count < SurfaceWire.requestLimit else {
            completion(nil)
            return
        }
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: SurfaceWire.requestLimit - buffer.count) { data, _, complete, error in
            if error != nil {
                completion(nil)
                return
            }
            var next = buffer
            if let data = data { next.append(data) }
            if complete, !next.contains(UInt8(ascii: "\n")) {
                completion(next.isEmpty ? nil : String(decoding: next, as: UTF8.self))
                return
            }
            self.readLine(connection, buffer: next, completion: completion)
        }
    }
}

/// This screen's own name on the network. A Womble writes no device record,
/// so its ID is made once here and kept between launches; losing it on a
/// reinstall costs the registrations, which the room can give again.
enum SurfaceIdentity {
    private static let key = "surface.device"

    static func device(defaults: UserDefaults = .standard) -> DeviceID {
        if let existing = defaults.string(forKey: key), !existing.isEmpty { return DeviceID(existing) }
        let made = "womble-" + UUID().uuidString.lowercased()
        defaults.set(made, forKey: key)
        return DeviceID(made)
    }
}
