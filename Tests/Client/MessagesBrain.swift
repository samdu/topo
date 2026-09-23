import Foundation
import TopoAuth
import TopoTurn

/// The Messages API as the harness's brain over a test's transport: how the suites that script a
/// model's answers as HTTP drive the harness. The app composes the guest (`Harness.standard`).
func messagesBrain(over transport: any Transport) -> any Brain {
    MessagesAPIBrain(api: MessagesAPI(transport: transport, tokens: TestToken()))
}

private struct TestToken: TokenProvider {
    func accessToken() async throws -> String { "tok" }
}
