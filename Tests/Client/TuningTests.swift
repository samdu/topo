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

    // MARK: Where he sits

    /// A drag let go writes `pinned` and the pin to the override, which a relaunch reads back and
    /// wears; nothing else of the look moves.
    func testADragsPinIsKeptAndOutlivesALaunch() throws {
        let store = defaults()
        let tuning = Tuning(defaults: store)
        tuning.pin(at: CGPoint(x: 0.25, y: 0.625))
        XCTAssertEqual(tuning.placement, .pinned)
        let relaunched = Tuning(defaults: store)
        XCTAssertEqual(relaunched.placement, .pinned)
        XCTAssertEqual(relaunched.pin, CGPoint(x: 0.25, y: 0.625))
        let worn = relaunched.worn(over: vault)
        XCTAssertEqual(worn.mascot.placement, .pinned)
        XCTAssertEqual(worn.mascot.pin, CGPoint(x: 0.25, y: 0.625))
        XCTAssertEqual(Set(try LookCensus.different(worn, vault)), ["mascot.placement", "mascot.pin.x", "mascot.pin.y"])
    }

    /// The override outranks the document: a vault's `look.json` placing him on the glass at
    /// another pin, read through `LookDocument` as the app reads it, does not undo a pin this
    /// device keeps; Reset removes the override and the vault's placement and pin are worn again.
    func testThePinOutranksTheVaultsLookAndResetGivesItBack() throws {
        let document = LookDocument.read(#"{"mascot": {"placement": "glass", "pin": {"x": 0.1, "y": 0.2}, "clearance": 12}}"#)
        XCTAssertEqual(document.notes, [])
        let vault = document.look
        let store = defaults()
        let tuning = Tuning(defaults: store)
        tuning.pin(at: CGPoint(x: 0.75, y: 0.5))
        let worn = Tuning(defaults: store).worn(over: vault)
        XCTAssertEqual(worn.mascot.placement, .pinned)
        XCTAssertEqual(worn.mascot.pin, CGPoint(x: 0.75, y: 0.5))
        XCTAssertEqual(worn.mascot.clearance, 12, "the vault's own field went with it")
        tuning.reset()
        XCTAssertNil(store.string(forKey: Tuning.key))
        let back = Tuning(defaults: store).worn(over: vault)
        XCTAssertEqual(back.mascot.placement, .glass)
        XCTAssertEqual(back.mascot.pin, CGPoint(x: 0.1, y: 0.2))
    }

    // MARK: His frame rate

    /// The sheet's frame rate is worn as the look's `frameInterval` and nothing else moves, the
    /// rest's interval included; a release build, which wears no slider, wears it, since it is read
    /// beside the placement and not as a knob; Reset gives the vault's back.
    func testTheFrameRateIsWornInEveryBuildAndResetGivesTheVaultsBack() throws {
        let store = defaults()
        let tuning = Tuning(defaults: store)
        tuning.set(frameRate: 20)
        XCTAssertEqual(tuning.frameRate, 20)
        let worn = tuning.worn(over: vault)
        XCTAssertEqual(worn.mascot.frameInterval, 1.0 / 20)
        XCTAssertEqual(worn.mascot.restInterval, vault.mascot.restInterval, "the rest's rate is not the sheet's")
        XCTAssertEqual(try LookCensus.different(worn, vault), ["mascot.frameInterval"])
        let release = Tuning(defaults: store, knobs: false)
        XCTAssertEqual(release.frameRate, 20, "a release build left the rate unworn")
        XCTAssertEqual(release.worn(over: vault).mascot.frameInterval, 1.0 / 20)
        for rate in [Tuning.frameRates.lowerBound, 24, Tuning.frameRates.upperBound] {
            tuning.set(frameRate: rate)
            XCTAssertEqual(Tuning(defaults: store).frameRate, rate, "\(rate) came back a hair off")
            XCTAssertEqual(Tuning(defaults: store).worn(over: vault).mascot.frameInterval, 1 / rate)
        }
        tuning.reset()
        XCTAssertNil(tuning.frameRate)
        XCTAssertNil(store.string(forKey: Tuning.key))
        XCTAssertEqual(try LookCensus.different(Tuning(defaults: store).worn(over: vault), vault), [])
    }

    /// The mind setting `mascot.frameInterval` drops the sheet's rate, the sheet drops the mind's,
    /// and taking the field back leaves the vault's.
    func testTheFrameRateAndTheMindsIntervalAreOneField() throws {
        let store = defaults()
        let tuning = Tuning(defaults: store)
        tuning.set(frameRate: 30)
        let set = tuning.set(["mascot", "frameInterval"], to: 1.0 / 25, over: vault)
        XCTAssertEqual(set.kept, ["mascot.frameInterval"])
        XCTAssertNil(tuning.frameRate, "the mind's interval left the sheet's rate standing")
        XCTAssertEqual(tuning.worn(over: vault).mascot.frameInterval, 1.0 / 25)
        tuning.set(frameRate: 22)
        XCTAssertNil(store.string(forKey: Tuning.mindKey), "the sheet's rate left the mind's interval kept")
        XCTAssertEqual(Tuning(defaults: store).worn(over: vault).mascot.frameInterval, 1.0 / 22, "the mind's interval outranked the sheet's")
        XCTAssertEqual(tuning.reset([["mascot", "frameInterval"]]), [.reset])
        XCTAssertNil(tuning.frameRate)
        XCTAssertEqual(try LookCensus.different(Tuning(defaults: store).worn(over: vault), vault), [])
    }

    /// The settings sheet's placement is kept on its own, and choosing `pinned` there keeps
    /// whatever pin there is — the one a drag left, or the look's.
    func testThePlacementChosenKeepsThePin() {
        let store = defaults()
        let tuning = Tuning(defaults: store)
        tuning.place(.glass)
        XCTAssertEqual(tuning.worn(over: vault).mascot.placement, .glass)
        XCTAssertEqual(tuning.worn(over: vault).mascot.pin, vault.mascot.pin)
        tuning.pin(at: CGPoint(x: 0.5, y: 0.5))
        tuning.place(.roam)
        tuning.place(.pinned)
        let relaunched = Tuning(defaults: store)
        XCTAssertEqual(relaunched.worn(over: vault).mascot.pin, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(relaunched.worn(over: vault).mascot.placement, .pinned)
    }

    /// A kept pin out of `0...1` — one written by hand, or by a build that read it otherwise — is
    /// refused where it is worn, by the document's own reader, and the look's pin stands; the
    /// placement beside it is taken.
    func testAKeptPinOutOfRangeIsRefusedWhereItIsWorn() {
        let store = defaults()
        store.set(#"{"mascot": {"placement": "pinned", "pin": {"x": 2, "y": 0.5}}}"#, forKey: Tuning.key)
        let worn = Tuning(defaults: store).worn(over: vault)
        XCTAssertEqual(worn.mascot.placement, .pinned)
        XCTAssertEqual(worn.mascot.pin, vault.mascot.pin)
    }

    /// A kept `frameInterval` out of its field's range — a planted one, since the sheet writes
    /// only its own stops — is refused where it is worn, costs that field alone, and is written
    /// back as it was rather than as a rate it does not come to.
    func testAKeptFrameIntervalOutOfRangeIsRefusedWhereItIsWorn() throws {
        for planted in ["3", "1.5", "0", "-0.05"] {
            let store = defaults()
            store.set(#"{"mascot": {"frameInterval": \#(planted), "placement": "glass"}}"#, forKey: Tuning.key)
            let tuning = Tuning(defaults: store)
            let worn = tuning.worn(over: vault)
            XCTAssertEqual(worn.mascot.frameInterval, vault.mascot.frameInterval, "\(planted) reached the look")
            XCTAssertEqual(worn.mascot.placement, .glass, "\(planted) took the placement down")
            tuning.place(.roam)
            XCTAssertEqual(Tuning(defaults: store).frameInterval, Double(planted), "\(planted) was rewritten")
            XCTAssertEqual(Tuning(defaults: store).worn(over: vault).mascot.frameInterval, vault.mascot.frameInterval)
        }
    }

    /// A release build has no Tuning sliders, so it wears none of their values: slider values a
    /// debug install left in the defaults are read as nothing, the placement, the pin and the
    /// frame rate beside them are worn, and the next write keeps only what the release build shows.
    func testAReleaseBuildWearsOnlyThePlacementThePinAndTheFrameRate() throws {
        let store = defaults()
        store.set(#"{"mascot": {"clearance": 40, "scale": 2, "placement": "pinned", "pin": {"x": 0.2, "y": 0.4}, "frameInterval": 0.05}, "transcript": {"replyTrailingInset": 90}}"#,
                  forKey: Tuning.key)
        let release = Tuning(defaults: store, knobs: false)
        XCTAssertEqual(release.values, [:])
        XCTAssertEqual(release.frameRate, 20)
        let worn = release.worn(over: vault)
        XCTAssertEqual(Set(try LookCensus.different(worn, vault)), ["mascot.placement", "mascot.pin.x", "mascot.pin.y", "mascot.frameInterval"])
        release.place(.glass)
        XCTAssertEqual(Tuning(defaults: store, knobs: true).values, [:], "the release build kept slider values it does not show")
        XCTAssertEqual(Tuning(defaults: store, knobs: true).placement, .glass)
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
