import AppIntents
import SwiftUI
import WidgetKit

/// Topo's two controls in the gallery, each placed once — in Control Center, on the lock screen or
/// on the Action button — and pointed at one of its kind's six slots, whose document the mind
/// writes (`ControlDocument`). The template takes one intent per kind: what a tap does is read by
/// the app from the slot at the revision the value carried (`WidgetTaps.controlTapped`).
@available(iOS 18, *)
struct TopoButtonControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: ControlSlot.Kind.button.controlKind, provider: ControlSlotProvider<ButtonSlotConfiguration>()) { value in
            ControlWidgetButton(action: ControlButtonIntent(slot: value.slot, revision: value.revision)) {
                Label {
                    Text(value.title)
                    if let subtitle = value.subtitle { Text(subtitle) }
                } icon: {
                    Image(systemName: value.symbol)
                }
                .controlWidgetActionHint(Text(value.hint ?? value.title))
            }
            .tint(value.tint?.color)
        }
        .displayName("Topo Button")
        .description("A button Topo sets up")
    }
}

@available(iOS 18, *)
struct TopoToggleControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: ControlSlot.Kind.toggle.controlKind, provider: ControlSlotProvider<ToggleSlotConfiguration>()) { value in
            ControlWidgetToggle(value.title, isOn: value.on, action: ControlToggleIntent(slot: value.slot, revision: value.revision)) { on in
                Label(on ? value.onText : value.offText, systemImage: on ? value.onSymbol : value.offSymbol)
                    .controlWidgetActionHint(Text(value.hint ?? value.title))
            }
            .tint(value.tint?.color)
        }
        .displayName("Topo Toggle")
        .description("A switch Topo sets up")
    }
}

/// A placed control's one parameter, which of its kind's slots it is.
@available(iOS 18, *)
protocol ControlSlotConfiguring: ControlConfigurationIntent {
    /// The slot picked, or slot 1 of the kind when none was.
    var slotName: String { get }
}

@available(iOS 18, *)
struct ButtonSlotConfiguration: ControlSlotConfiguring {
    static let title: LocalizedStringResource = "Topo Button"
    @Parameter(title: "Slot") var slot: ButtonSlot?
    init() {}
    var slotName: String { (slot ?? .button1).rawValue }
}

@available(iOS 18, *)
struct ToggleSlotConfiguration: ControlSlotConfiguring {
    static let title: LocalizedStringResource = "Topo Toggle"
    @Parameter(title: "Slot") var slot: ToggleSlot?
    init() {}
    var slotName: String { (slot ?? .toggle1).rawValue }
}

/// The six button slots, a fixed list so a slot can be placed before or after the mind fills it.
enum ButtonSlot: String, AppEnum {
    case button1 = "button-1", button2 = "button-2", button3 = "button-3"
    case button4 = "button-4", button5 = "button-5", button6 = "button-6"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Slot"
    static let caseDisplayRepresentations: [ButtonSlot: DisplayRepresentation] = [
        .button1: "Button 1", .button2: "Button 2", .button3: "Button 3",
        .button4: "Button 4", .button5: "Button 5", .button6: "Button 6",
    ]
}

enum ToggleSlot: String, AppEnum {
    case toggle1 = "toggle-1", toggle2 = "toggle-2", toggle3 = "toggle-3"
    case toggle4 = "toggle-4", toggle5 = "toggle-5", toggle6 = "toggle-6"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Slot"
    static let caseDisplayRepresentations: [ToggleSlot: DisplayRepresentation] = [
        .toggle1: "Toggle 1", .toggle2: "Toggle 2", .toggle3: "Toggle 3",
        .toggle4: "Toggle 4", .toggle5: "Toggle 5", .toggle6: "Toggle 6",
    ]
}

/// The slot as the app group holds it at the moment the system asks; the preview is its default.
/// Nothing here reaches the tool service, HomeKit or the network.
@available(iOS 18, *)
struct ControlSlotProvider<Configuration: ControlSlotConfiguring>: AppIntentControlValueProvider {
    func previewValue(configuration: Configuration) -> ControlValue {
        ControlValue(slot: configuration.slotName, document: ControlDocument.standard(slot: configuration.slotName))
    }

    func currentValue(configuration: Configuration) async throws -> ControlValue {
        ControlValue.read(slot: configuration.slotName, store: SurfaceStore.shared())
    }
}
