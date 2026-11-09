import Foundation
import Observation
import os
import TopoCore
import TopoLink

/// The hub serving the web-page Wombles: a screen's own path on the house
/// network, the page itself, and the one document it polls.
///
/// Off Apple there is no bundle to install, so a Womble is a page this Mac
/// serves — `Womble/Web`, copied into the hub as it is. The document is read
/// afresh for a request that needs it, from the same log and board every
/// other screen reads; nothing is cached here beyond the ETag the page sends
/// back, because a wall screen asking every five seconds is cheap and a
/// stale board on a wall is not.
@MainActor
@Observable
final class SurfacePages {
    private var keeper = SurfaceTokenKeeper.keychain()
    /// The tokens this hub serves under; none while the keychain cannot be read.
    var tokens: SurfaceTokens { keeper.tokens ?? SurfaceTokens() }
    /// Why the screens' tokens cannot be read or were not kept, if so.
    var tokenTrouble: String? { keeper.trouble }
    private(set) var port: UInt16?
    /// Why the page is not being served, if it is not.
    private(set) var failure: String?

    private static let log = Logger(subsystem: "zone.hexagon.topo.hub", category: "pages")
    private let house: String?
    private let read: @Sendable () async -> SurfaceDocument?
    private var server: SurfacePageServer?

    init(house: String? = nil, read: @escaping @Sendable () async -> SurfaceDocument?) {
        self.house = house
        self.read = read
    }

    /// Opens the listener. The page is served under every token this hub
    /// holds; a request under one it does not is a `404` saying nothing
    /// about whether it was ever real.
    func start() async {
        guard server == nil else { return }
        let read = read
        let known: @Sendable (String) async -> Bool = { [weak self] token in
            await MainActor.run { self?.tokens.screen(for: token) != nil }
        }
        do {
            let server = try SurfacePageServer(files: Self.page()) { token in
                guard await known(token) else { return nil }
                return await read()
            }
            port = try await server.start()
            self.server = server
            failure = nil
            Self.log.notice("serving surfaces on \(self.port ?? 0)")
        } catch {
            failure = "\(error)"
            Self.log.error("surface page server failed: \(String(describing: error), privacy: .public)")
        }
    }

    func stop() async {
        await server?.stop()
        server = nil
        port = nil
    }

    /// The address to put on a television: this Mac on the house network,
    /// under the screen's own token. Nil until the listener is up and the
    /// screen has a token.
    func address(for surface: DeviceID, host: String?) -> URL? {
        guard let port, let token = tokens.token(for: surface), let host else { return nil }
        return URL(string: "http://\(host):\(port)/s/\(token)/")
    }

    func mint(for surface: DeviceID, named name: String) {
        guard let tokens = keeper.tokens, tokens.token(for: surface) == nil, !tokens.isRevoked(surface) else { return }
        keeper.change { _ = $0.mint(for: surface, named: name) }
    }

    /// Asks a keychain that could not be read again, and keeps a change that
    /// did not land: once a pass.
    func reload() { keeper.reload() }

    /// Serves a screen somebody revoked, under a new token. The old address
    /// is gone for good; this is a fresh decision and a fresh one of those.
    func serveAgain(_ surface: DeviceID, named name: String) {
        keeper.change { $0.serveAgain(surface, named: name) }
    }

    func isRevoked(_ surface: DeviceID) -> Bool { tokens.isRevoked(surface) }

    /// Taking a screen off the roster is not something the network can do,
    /// so this is the other half: the token stops working at once, the page
    /// it was serving clears itself the next time it asks, and the screen is
    /// remembered as revoked so the hub's next pass does not quietly mint it
    /// another one.
    func revoke(_ surface: DeviceID) {
        keeper.change { $0.revoke(surface) }
    }

    /// `Womble/Web` as the hub bundles it. A build that left the files out
    /// serves nothing rather than an empty page.
    private static func page(in bundle: Bundle = .main) -> [String: SurfacePageServer.File] {
        let types = ["index.html": "text/html; charset=utf-8",
                     "womble.css": "text/css; charset=utf-8",
                     "womble.js": "text/javascript; charset=utf-8"]
        var files: [String: SurfacePageServer.File] = [:]
        for (name, type) in types {
            let parts = name.split(separator: ".")
            guard let url = bundle.url(forResource: String(parts[0]), withExtension: String(parts[1])),
                  let data = try? Data(contentsOf: url) else {
                log.error("the hub bundle has no \(name, privacy: .public)")
                continue
            }
            files[name] = SurfacePageServer.File(data: data, contentType: type)
        }
        return files
    }
}
