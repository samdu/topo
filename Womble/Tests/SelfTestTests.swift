import XCTest

final class SelfTestTests: XCTestCase {
    /// A step that answers when told to, so the order and the stopping can
    /// be watched rather than raced.
    private func step(_ name: String, _ result: Result<String, Error>,
                      ran: @escaping () -> Void = {}) -> SelfTestStep {
        return SelfTestStep(name: name) { done in
            ran()
            done(result)
        }
    }

    private struct Broke: LocalizedError {
        var errorDescription: String? { return "it broke" }
    }

    private func run(_ test: SelfTest) {
        let done = expectation(description: "finished")
        test.run(changed: {}, finished: { done.fulfill() })
        wait(for: [done], timeout: 2)
    }

    func testEveryStepRunsInOrderAndSaysWhatItFound() {
        var order: [String] = []
        let test = SelfTest(steps: [
            step("first", .success("one"), ran: { order.append("first") }),
            step("second", .success("two"), ran: { order.append("second") }),
        ])
        run(test)

        XCTAssertEqual(order, ["first", "second"])
        guard case .passed(let note) = test.outcomes[1].state else { return XCTFail("not passed") }
        XCTAssertEqual(note, "two")
        XCTAssertTrue(test.isFinished)
    }

    func testItStopsAtTheFirstFailureAndSaysWhatWasNotTried() {
        var thirdRan = false
        let test = SelfTest(steps: [
            step("first", .success("one")),
            step("second", .failure(Broke())),
            step("third", .success("three"), ran: { thirdRan = true }),
        ])
        run(test)

        XCTAssertFalse(thirdRan, "a step after a failure would be answering a question nobody can trust")
        guard case .failed(let why) = test.outcomes[1].state else { return XCTFail("not failed") }
        XCTAssertEqual(why, "it broke")
        guard case .skipped = test.outcomes[2].state else { return XCTFail("not skipped") }
    }

    func testEveryStepThatRanIsTimed() {
        let test = SelfTest(steps: [step("first", .success("one")), step("second", .failure(Broke()))])
        run(test)
        XCTAssertNotNil(test.outcomes[0].seconds)
        XCTAssertNotNil(test.outcomes[1].seconds, "how long a failure took is often the answer")
    }

    func testStepsWaitBeforeTheyAreRun() {
        let test = SelfTest(steps: [step("first", .success("one"))])
        guard case .waiting = test.outcomes[0].state else { return XCTFail("not waiting") }
        XCTAssertNil(test.outcomes[0].seconds)
    }

    func testRunningAgainStartsFromTheBeginning() {
        var runs = 0
        let test = SelfTest(steps: [step("first", .success("one"), ran: { runs += 1 })])
        run(test)
        run(test)
        XCTAssertEqual(runs, 2)
        XCTAssertEqual(test.outcomes.count, 1)
    }

    func testACloudKitErrorIsNamedByItsCode() {
        let error = NSError(domain: "CKErrorDomain", code: 9,
                            userInfo: [NSLocalizedDescriptionKey: "Not Authenticated"])
        XCTAssertEqual(SelfTest.describe(error), "CloudKit 9: Not Authenticated")
    }

    func testTheRealStepsAreTheOnesWorthRunning() {
        // Nothing here touches CloudKit: it checks the list is the one the
        // screen promises, in the order the reads actually depend on.
        let names = CloudKitSelfTest.steps().map { $0.name }
        XCTAssertEqual(names.first, "iCloud account")
        XCTAssertEqual(names.last, "Tidy up")
        XCTAssertTrue(names.contains("Read it back from the change feed"))
        XCTAssertTrue(names.contains("Refuse to overwrite a turn"))
        XCTAssertTrue(names.contains("The board's container"))
        XCTAssertLessThan(names.firstIndex(of: "Write a turn")!,
                          names.firstIndex(of: "Read it back from the change feed")!)
    }
}
