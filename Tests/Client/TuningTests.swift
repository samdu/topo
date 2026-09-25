import SwiftUI
import TopoCore
import TopoCoreTesting
import XCTest

@testable import Topo

/// The settings sheet's Tuning: an override kept in this device's defaults and worn over the
/// vault's look through `LookDocument`, so a value reaches a view only in its field's range, one
/// out of range falls back for that field alone, and Reset is the vault's look again.
@MainActor
final class TuningTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "topo-tuning-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    /// The vault's own look, with a field or two of its own, which the tuning is worn over.
    private var vault: Look {
        var look = Look()
        look.mascot.clearance = 12
        look.bubble.cornerRadius = 3
        return look
    }

    func testNothingSetIsTheVaultsLook() throws {
        let tuning = Tuning(defaults: defaults())
        XCTAssertNil(tuning.document)
        XCTAssertEqual(try LookCensus.different(tuning.worn(over: vault), vault), [])
    }

    /// Each slider sets its field, worn over the vault's look, and nothing else moves.
    func testEachKnobSetsItsFieldAndNoOther() throws {
        let values: [Tuning.Knob: Double] = [.clearance: 0, .replyTrailingInset: 60, .personLeadingInset: 140,
                                             .scale: 1.5, .roamSpeed: 120]
        for (knob, value) in values {
            let tuning = Tuning(defaults: defaults())
            tuning.set(knob, to: value)
            let worn = tuning.worn(over: vault)
            XCTAssertEqual(knob.value(in: worn), value, "\(knob)")
            let different = try LookCensus.different(worn, vault)
            XCTAssertEqual(different.count, 1, "\(knob): \(different)")
            XCTAssertEqual(worn.bubble.cornerRadius, 3, "\(knob) took the vault's own field down")
        }
    }

    /// Every slider's range is the range the document reads its field in: both ends are taken,
    /// and past either end the field alone falls back to the vault's value.
    func testASliderValueOutOfItsFieldsRangeFallsBackForThatFieldAlone() {
        for knob in Tuning.Knob.allCases {
            for end in [knob.range.lowerBound, knob.range.upperBound] {
                let tuning = Tuning(defaults: defaults())
                tuning.set(knob, to: end)
                XCTAssertEqual(knob.value(in: tuning.worn(over: vault)), end, "\(knob) at \(end)")
            }
            for past in [knob.range.lowerBound - 1, knob.range.upperBound + 1] {
                let tuning = Tuning(defaults: defaults())
                let other: Tuning.Knob = knob == .roamSpeed ? .clearance : .roamSpeed
                tuning.set(other, to: other.range.lowerBound)
                tuning.set(knob, to: past)
                let worn = tuning.worn(over: vault)
                XCTAssertEqual(knob.value(in: worn), knob.value(in: vault), "\(knob) at \(past) reached the look")
                XCTAssertEqual(other.value(in: worn), other.range.lowerBound, "\(knob) at \(past) took \(other) down")
            }
        }
    }

    /// The override is kept in the device's defaults, so a relaunch wears it, and Reset removes it.
    func testTheOverrideOutlivesALaunchAndResetRemovesIt() {
        let store = defaults()
        let tuning = Tuning(defaults: store)
        tuning.set(.personLeadingInset, to: 40)
        tuning.set(.scale, to: 0.5)
        let relaunched = Tuning(defaults: store)
        XCTAssertEqual(relaunched.values, [.personLeadingInset: 40, .scale: 0.5])
        XCTAssertEqual(relaunched.worn(over: vault).transcript.personLeadingInset, 40)
        relaunched.reset()
        XCTAssertNil(store.string(forKey: Tuning.key))
        XCTAssertEqual(try LookCensus.different(relaunched.worn(over: vault), vault), [])
        XCTAssertEqual(Tuning(defaults: store).values, [:])
    }

    /// The join: what the chat draws with is the vault's look with the tuning worn over it.
    func testTheSubtreeDrawsWithTheTuningOverTheVaultsLook() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("topo-tuning-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let memory = Memory(directory: directory.appendingPathComponent("Vault", isDirectory: true),
                            store: MemoryStore(database: InMemoryRecordDatabase()), device: DeviceID("phone"),
                            isSignedIn: { true }, ensureZone: {})
        let tuning = Tuning(defaults: defaults())
        tuning.set(.clearance, to: 30)
        var worn: Look?
        _ = try LookStage.image(Probe { worn = $0 }.wearing(memory, tuning: tuning), look: Look())
        XCTAssertEqual(try XCTUnwrap(worn).mascot.clearance, 30)
        tuning.reset()
        worn = nil
        _ = try LookStage.image(Probe { worn = $0 }.wearing(memory, tuning: tuning), look: Look())
        XCTAssertEqual(try XCTUnwrap(worn).mascot.clearance, Look().mascot.clearance)
    }
}

private struct Probe: View {
    let report: (Look) -> Void
    @Environment(\.look) private var look

    var body: some View {
        Color.white.onAppear { report(look) }
    }
}
