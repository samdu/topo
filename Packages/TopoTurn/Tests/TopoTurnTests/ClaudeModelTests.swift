import Testing
@testable import TopoTurn

@Suite struct ClaudeModelTests {
    @Test func defaultModelIsSonnet() {
        #expect(ClaudeModel.default == .sonnet5)
        #expect(ClaudeModel.allCases.map(\.rawValue) == ["claude-sonnet-5", "claude-opus-5", "claude-fable-5-1"])
    }

    /// Whatever a caller asks for, a debug build is given Haiku. This suite is a debug build, so it
    /// can assert the pinned half directly.
    @Test func aDebugBuildAsksHaikuWhateverTheSettingSays() {
        #expect(ClaudeModel.pinned == .haiku45)
        #expect(!ClaudeModel.allCases.contains(.haiku45))
        for asked in [ClaudeModel.sonnet5, .opus5, .fable51, .haiku45] {
            #expect(ClaudeModel.effective(asked) == .haiku45)
        }
    }
}
