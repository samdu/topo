import XCTest

@testable import Topo

/// Where what the microphone hears goes (`Dictation`): sent on the release for a session begun
/// with the pane at rest, and written after what was there for one begun over the row.
final class DictationTests: XCTestCase {
    /// One space between what was written and what was heard, and none where either is empty.
    func testWhatIsHeardGoesAfterWhatWasWrittenWithOneSpaceBetween() {
        XCTAssertEqual(Dictation.join("Remind me", "to water the plants"), "Remind me to water the plants")
        XCTAssertEqual(Dictation.join("", "to water the plants"), "to water the plants")
        XCTAssertEqual(Dictation.join("Remind me", ""), "Remind me")
        XCTAssertEqual(Dictation.join("", ""), "")
    }

    /// What was written keeps a space or a line it already ends with, and what was heard brings
    /// none of its own: one space, never two, and nothing heard changes nothing.
    func testTheSpaceBetweenIsNeverDoubled() {
        XCTAssertEqual(Dictation.join("Remind me ", "to water"), "Remind me to water")
        XCTAssertEqual(Dictation.join("Remind me\n", "to water"), "Remind me\nto water")
        XCTAssertEqual(Dictation.join("Remind me", "  to water \n"), "Remind me to water")
        XCTAssertEqual(Dictation.join("Remind me ", "   "), "Remind me ")
    }

    /// A spoken turn's caption is what was heard and its release sends; dictation into the draft
    /// writes after what was there when it began, however much has been heard since, and sends
    /// nothing.
    func testASessionGoesWhereItWasGoingWhenItBegan() {
        XCTAssertTrue(Dictation.spoken.sends)
        XCTAssertEqual(Dictation.spoken.written(hearing: "bins on Tuesday"), "bins on Tuesday")

        let dictation = Dictation(over: "Remind me")
        XCTAssertFalse(dictation.sends)
        XCTAssertEqual(dictation.written(hearing: "to"), "Remind me to")
        XCTAssertEqual(dictation.written(hearing: "to water the plants"), "Remind me to water the plants",
                       "what is heard later is written after what had been heard, not after what was written")
        XCTAssertEqual(dictation.written(hearing: ""), "Remind me", "nothing heard does not leave what was written as it was")
        XCTAssertFalse(Dictation(over: "").sends, "a session begun over an empty row sends on its release")
        XCTAssertEqual(Dictation(over: "").written(hearing: "bins"), "bins")
    }

    /// A press over the row is dictation only while the draft is the person's to write in. With a
    /// turn on its way — the pane still a row as the keyboard goes down after the send — it is
    /// a spoken turn: what is heard is sent on the release as a turn of its own and is not
    /// written after the words in flight, which would be lost with them when they landed.
    func testAPressOverATurnOnItsWayIsASpokenTurnWhateverFormThePaneIsIn() {
        let over = Dictation.beginning(row: true, inFlight: false, written: "Remind me")
        XCTAssertEqual(over, Dictation(over: "Remind me"))
        XCTAssertFalse(over.sends)

        let inFlight = Dictation.beginning(row: true, inFlight: true, written: "Remind me")
        XCTAssertEqual(inFlight, .spoken, "a press over a turn on its way dictates after words it cannot send")
        XCTAssertTrue(inFlight.sends)
        XCTAssertEqual(inFlight.written(hearing: "and the bins"), "and the bins", "what is heard was written after the turn in flight")
        XCTAssertTrue(inFlight.standing(in: "Remind me"))

        XCTAssertEqual(Dictation.beginning(row: false, inFlight: false, written: "Remind me"), .spoken)
        XCTAssertEqual(Dictation.beginning(row: false, inFlight: true, written: "Remind me"), .spoken)
    }

    /// A dictation over the row writes only into a draft that is as it left it. Words typed since
    /// the press are the person's, and a caption written after what the session began over would
    /// take them out, so the session writes nothing more.
    func testADraftTypedIntoSinceIsNotTheDictationsToWrite() {
        var dictation = Dictation(over: "Remind me")
        XCTAssertTrue(dictation.standing(in: "Remind me"), "nothing has been typed since the press")
        XCTAssertFalse(dictation.standing(in: "Remind me to"), "typing before the first caption was written over")

        dictation.wrote = dictation.written(hearing: "to water")
        XCTAssertTrue(dictation.standing(in: "Remind me to water"), "the session's own caption ended it")
        XCTAssertFalse(dictation.standing(in: "Remind me to water the"), "typing after a caption was written over")
        XCTAssertFalse(dictation.standing(in: "Remind me"), "a caption deleted was written back")
        XCTAssertFalse(dictation.standing(in: ""), "a draft cleared was written back")

        var spoken = Dictation.spoken
        XCTAssertTrue(spoken.standing(in: "anything"), "a spoken turn's draft is its own")
        spoken.wrote = "bins"
        XCTAssertTrue(spoken.standing(in: "bins on"))
    }

    /// A session begins on a press down on a microphone that is shut. The release, the press that
    /// closes a microphone left open, and a press on Stop begin none, so each follows the session
    /// it belongs to.
    @MainActor func testOnlyAPressOnAShutMicrophoneBeginsASession() {
        let shut = Composer.MicState()
        let held = Composer.MicState(listening: true, owner: .chat)
        let handsFree = Composer.MicState(listening: true, owner: .chat, handsFree: true)
        let speaking = Composer.MicState(speaking: true)
        XCTAssertTrue(Dictation.begins(down: true, drawn: shut))
        XCTAssertFalse(Dictation.begins(down: false, drawn: shut))
        XCTAssertFalse(Dictation.begins(down: false, drawn: held), "the release began a session of its own")
        XCTAssertFalse(Dictation.begins(down: true, drawn: handsFree), "the press that closes the microphone began a session")
        XCTAssertFalse(Dictation.begins(down: true, drawn: speaking), "a press on Stop began a session")
    }
}
