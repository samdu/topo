import AlarmKit
import Foundation
import SwiftUI
import TopoTools

/// `AlarmScheduler` over AlarmKit. `schedule` and the prompt are asynchronous and called as they
/// are; `alarms` and `cancel` are synchronous calls into the system, reached only through
/// `Confined`, whose queue is not the cooperative pool.
@available(iOS 26, *)
struct AlarmKitScheduler: AlarmScheduler {
    private let manager = Confined(AlarmManager.shared, label: "zone.hexagon.topo.alarms")

    var available: Bool { true }
    var authorizer: (any Authorizer)? { AlarmAuthorizer() }

    func schedule(id: UUID, label: String, duration: TimeInterval) async throws {
        let title = LocalizedStringResource(stringLiteral: label)
        let stop = AlarmButton(text: "Stop", textColor: Theme.onPrimary, systemImageName: "stop.circle")
        let presentation = AlarmPresentation(alert: .init(title: title, stopButton: stop), countdown: .init(title: title))
        let attributes = AlarmAttributes(presentation: presentation, metadata: TopoAlarmMetadata(label: label), tintColor: Theme.primary)
        do {
            _ = try await AlarmManager.shared.schedule(id: id, configuration: .timer(duration: duration, attributes: attributes))
        } catch AlarmManager.AlarmError.maximumLimitReached {
            throw AlarmLimit()
        }
    }

    func alarms() async throws -> [(id: UUID, state: String)] {
        try await manager.run { manager, _ in
            try manager.alarms.map { ($0.id, Self.state($0.state)) }
        }
    }

    func cancel(id: UUID) async throws {
        try await manager.run { manager, _ in try manager.cancel(id: id) }
    }

    static func state(_ state: Alarm.State) -> String {
        switch state {
        case .scheduled, .countdown: "counting"
        case .paused: "paused"
        case .alerting: "sounding"
        @unknown default: "unknown"
        }
    }
}

/// AlarmKit's permission, asked at a timer's start and nowhere else (`PermissionBroker`).
@available(iOS 26, *)
struct AlarmAuthorizer: ThrowingPrompt {
    let name = "Alarms"

    func access() async -> Access {
        switch AlarmManager.shared.authorizationState {
        case .notDetermined: .undetermined
        case .denied: .denied
        case .authorized: .granted
        @unknown default: .denied
        }
    }

    func request() async -> Bool { (try? await prompt()) == .granted }

    func prompt() async throws -> Access {
        switch try await AlarmManager.shared.requestAuthorization() {
        case .notDetermined: .undetermined
        case .authorized: .granted
        case .denied: .denied
        @unknown default: .denied
        }
    }
}
