import Testing

@testable import OmniWM

@Suite @MainActor struct CommandHandlerTests {
    @Test func overviewIgnoresNonOverviewHotkeys() {
        #expect(CommandHandler.shouldIgnoreCommand(.switchWorkspace(1), isOverviewOpen: true) == true)
        #expect(CommandHandler.shouldIgnoreCommand(.move(.left), isOverviewOpen: true) == true)
    }

    @Test func overviewStillAllowsOverviewToggleHotkey() {
        #expect(CommandHandler.shouldIgnoreCommand(.toggleOverview, isOverviewOpen: true) == false)
        #expect(CommandHandler.shouldIgnoreCommand(.toggleOverview, isOverviewOpen: false) == false)
    }
}
