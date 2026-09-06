import Foundation
import Observation
import os
import TopoCore
import TopoLink

/// The screens in the house, as the hub sees them: what the browse found,
/// the whole roster where the advert could not carry it, and how the last
/// registration went.
///
/// Reading is free — the roster is in the advert, and asking for the rest
/// needs no pairing — so this keeps itself current on the hub's timer.
/// Registering is not: it is a question put to whoever is in the room, so it
/// happens when somebody presses the button and its answer is `waiting`
/// until they say yes on the screen itself.
@MainActor
@Observable
final class SurfacesModel {
    /// Where a registration this hub asked for has got to.
    enum Registration: Equatable {
        case asking
        /// The question is on the screen; nobody in the room has answered it.
        case waiting
        case registered
        case refused(String)
        case failed(String)
    }

    private(set) var surfaces: [Surface] = []
    /// The agents each screen answers for, once asked. The advert carries as
    /// much as fits in one TXT entry, so this is only for the ones that said
    /// there was more.
    private(set) var rosters: [DeviceID: [DeviceID]] = [:]
    private(set) var registrations: [DeviceID: Registration] = [:]
    /// Why nothing is listed, if the browse itself is not running.
    private(set) var failure: String?

    private static let log = Logger(subsystem: "zone.hexagon.topo.hub", category: "surfaces")
    private let browser: SurfaceBrowser

    init(browser: SurfaceBrowser = SurfaceBrowser()) {
        self.browser = browser
    }

    func start() async {
        await browser.start()
        await browser.observe { [weak self] found in
            Task { @MainActor in self?.show(found) }
        }
    }

    func stop() async {
        await browser.stop()
    }

    /// What the hub's own timer calls: the browse keeps the list, this fills
    /// in the rosters too long to advertise and drops what has gone away.
    func refresh() async {
        failure = await browser.failure
        for surface in surfaces where surface.agentsArePartial {
            do {
                rosters[surface.device] = try await browser.roster(of: surface)
            } catch {
                // A screen that went dark between the browse and the ask is
                // not an error worth showing: the advert goes with it.
                Self.log.debug("roster of \(surface.device.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Every agent a screen answers for: the whole roster where one was
    /// asked for, and what the advert said otherwise.
    func agents(of surface: Surface) -> [DeviceID] {
        rosters[surface.device] ?? surface.agents
    }

    func isRegistered(_ agent: DeviceID, with surface: Surface) -> Bool {
        agents(of: surface).contains(agent)
    }

    /// Asks a screen to answer for this hub. `waiting` is the ordinary
    /// answer to a first ask, and asking again after somebody has tapped
    /// Register is how the hub learns they did.
    func register(_ code: PairingCode, with surface: Surface) async {
        registrations[surface.device] = .asking
        do {
            switch try await browser.register(code, with: surface) {
            case .registered:
                registrations[surface.device] = .registered
                rosters[surface.device] = nil
                await refresh()
            case .waiting:
                registrations[surface.device] = .waiting
            case .refused(let reason):
                registrations[surface.device] = .refused(reason)
            case .roster:
                registrations[surface.device] = .failed("That screen answered something else")
            }
        } catch {
            registrations[surface.device] = .failed("\(error)")
        }
    }

    private func show(_ found: [Surface]) {
        surfaces = found
        let here = Set(found.map(\.device))
        rosters = rosters.filter { here.contains($0.key) }
        registrations = registrations.filter { here.contains($0.key) }
    }
}
