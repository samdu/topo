import AVFoundation
import TopoCore
import TopoUserland
import UIKit
import XCTest

@testable import Topo

/// A reply read aloud as the guest writes it, over a turn of more than one message: the words
/// said before a tool call and the words said after it are one growing text to the speaker
/// (`Harness.follow`, `Speaker.speak(writing:answering:)`), so each sentence is read once, in the
/// order it was written, with the break between two messages a sentence's end and never a
/// restart. A real `Speaker` on the audio seams, over a voice that records what it is asked to
/// say.
@MainActor
final class SpokenReplyTests: XCTestCase {
    override func tearDown() {
        UIApplication.shared.isIdleTimerDisabled = false
        super.tearDown()
    }

    private func settle(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                        until condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<6_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "waited a minute for \(what)", file: file, line: line)
    }

    /// A speaker over a resident voice, and the sentences that voice is asked for, in order.
    private func speaker() async -> (Speaker, Heard) {
        let heard = Heard()
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure, isActive: { true })
        let voice = Voice(engine: ScriptedVoice(frames: { sentence in
            heard.append(sentence)
            return [toneFrame(0.5)]
        }))
        voice.load(base: URL(fileURLWithPath: "/dev/null"))
        await settle("the voice to load") { voice.state == .ready }
        let speaker = Speaker(audio: audio, voice: voice, center: center,
                              makeEngine: { seams.makePlayEngine(rate: Voice.rate) })
        return (speaker, heard)
    }

    /// What the harness hands the reader for a turn of `messages`, each written a character at a
    /// time: the reply so far at every delta, and at each new message what was written with the
    /// break after it. Built on `ReplyWords` as `Harness.follow` builds it.
    private func told(_ messages: [String]) -> [String] {
        var words = ReplyWords()
        var told: [String] = []
        for message in messages {
            words.begin()
            if !words.text.isEmpty { told.append(words.text + ReplyWords.separator) }
            for character in message {
                words.append(String(character))
                told.append(words.text)
            }
        }
        return told
    }

    /// The reply grows across a paragraph break — a message, a tool call with nothing said, and
    /// another message — and every sentence is read once and in order: the one that ends the
    /// first message is not lost at the break, and nothing is read again from the top.
    func testSentencesAreReadOnceAndInOrderAcrossAMessageBreak() async {
        let (speaker, heard) = await speaker()
        let messages = ["Let me look. It is somewhere here", "", "Found it. It is on the shelf."]
        let reply = "Let me look. It is somewhere here\n\nFound it. It is on the shelf."
        let sentences = ["Let me look.", "It is somewhere here", "Found it.", "It is on the shelf."]

        var last = ""
        for text in told(messages) {
            XCTAssertTrue(text.hasPrefix(last), "\(text.debugDescription) does not extend \(last.debugDescription)")
            last = text
            speaker.speak(writing: text, answering: "asked")
        }
        XCTAssertEqual(last, reply)
        // Written, the last sentence has not ended; the reply landing reads it.
        await settle("the settled sentences") { heard.sentences.count >= 3 }
        XCTAssertEqual(heard.sentences, Array(sentences.prefix(3)))
        XCTAssertTrue(speaker.speak(reply, answering: "asked"))
        await settle("the last sentence") { heard.sentences.count >= 4 }
        // Long enough for a sentence read a second time to have been asked for.
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(heard.sentences, sentences, "a sentence was read twice, skipped or out of order")
        speaker.stop()
    }

    /// The sentence that ends a message is read when the next message begins, before any of
    /// that message's words: the break the harness hands over is what ends it.
    func testTheSentenceBeforeTheBreakIsReadWhenTheNextMessageBegins() async {
        let (speaker, heard) = await speaker()
        speaker.speak(writing: "Let me look", answering: "asked")
        speaker.speak(writing: "Let me look.", answering: "asked")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(heard.sentences, [], "a sentence was read before it had ended")
        speaker.speak(writing: "Let me look." + ReplyWords.separator, answering: "asked")
        await settle("the first message's sentence") { heard.sentences == ["Let me look."] }
        speaker.speak(writing: "Let me look.\n\nIt is here. ", answering: "asked")
        await settle("the second message's sentence") { heard.sentences.count >= 2 }
        XCTAssertEqual(heard.sentences, ["Let me look.", "It is here."])
        speaker.stop()
    }

    /// What used to be handed over at a new message — the empty string — would have counted the
    /// next message's sentences from none and read the reply's first ones again on landing; the
    /// text the harness hands over now never does that, whatever the messages are.
    func testTheTextHandedOverOnlyEverGrows() {
        for messages in [["One. ", "Two."], ["One.", "", "", "Two. Three."], ["", "One."], ["Same. ", "Same. "],
                         ["- a\n- b", "| x |\n|---|\n| 1 |\n", "Done."]] {
            var last = ""
            for text in told(messages) {
                XCTAssertTrue(text.hasPrefix(last), "\(messages): \(text.debugDescription) after \(last.debugDescription)")
                XCTAssertTrue(Speaker.settled(text).hasPrefix(Speaker.settled(last)) ,
                              "\(messages): what had settled changed at \(text.debugDescription)")
                last = text
            }
        }
    }
}
