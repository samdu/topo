import XCTest

/// Waits up to a minute, in 10 ms steps, for `condition` to hold on the main actor, and fails
/// naming `what` when it never does.
@MainActor
func settle(_ what: String, file: StaticString = #filePath, line: UInt = #line,
            until condition: @escaping @MainActor () -> Bool) async {
    for _ in 0..<6_000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition(), "waited a minute for \(what)", file: file, line: line)
}
