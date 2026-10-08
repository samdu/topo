import Testing
@testable import TopoTurn

@Suite struct ClaudeModelTests {
    @Test func defaultModelIsSonnet() {
        #expect(ClaudeModel.default == .sonnet)
    }

    /// What is offered is sent as its family's alias, with no version in it.
    @Test func theOfferedModelsAreAliases() {
        #expect(ClaudeModel.allCases.map(\.rawValue) == ["sonnet", "opus", "fable"])
        #expect(ClaudeModel.allCases.map(\.displayName) == ["Sonnet", "Opus", "Fable"])
    }

    @Test(arguments: [("sonnet", ClaudeModel.sonnet), ("opus", .opus), ("fable", .fable),
                      ("claude-sonnet-5", .sonnet), ("claude-opus-5", .opus), ("claude-fable-5-1", .fable),
                      ("claude-opus-5-5", .opus)])
    func aKeptSettingNamesItsFamily(_ kept: String, _ model: ClaudeModel) {
        #expect(ClaudeModel(setting: kept) == model)
    }

    @Test(arguments: ["", "claude-haiku-4-5-20251001", "haiku", "gpt-5", "claude-sonnetish", "sonnet-5"])
    func aSettingThatNamesNoOfferedModelIsNone(_ kept: String) {
        #expect(ClaudeModel(setting: kept) == nil)
    }

    /// Whatever a caller asks for, a debug build is given Haiku. This suite is a debug build, so it
    /// can assert the pinned half directly.
    @Test func aDebugBuildAsksHaikuWhateverTheSettingSays() {
        #expect(ClaudeModel.pinned == .haiku)
        #expect(!ClaudeModel.allCases.contains(.haiku))
        for asked in [ClaudeModel.sonnet, .opus, .fable, .haiku] {
            #expect(ClaudeModel.effective(asked) == .haiku)
        }
    }
}
