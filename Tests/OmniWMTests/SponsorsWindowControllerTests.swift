import AppKit
import Foundation
import Testing

@testable import OmniWM

@Suite(.serialized) @MainActor struct SponsorsWindowControllerTests {
    @Test func motionToggleKeepsLiveHostingController() async throws {
        let registry = OwnedWindowRegistry.shared
        registry.resetForTests()

        let motionPolicy = MotionPolicy()
        let controller = SponsorsWindowController(
            motionPolicy: motionPolicy,
            ownedWindowRegistry: registry
        )

        controller.show()

        let window = try #require(controller.windowForTests)
        let contentViewController = try #require(window.contentViewController)

        motionPolicy.animationsEnabled = false

        let updatedWindow = try #require(controller.windowForTests)
        #expect(updatedWindow === window)
        #expect(updatedWindow.contentViewController === contentViewController)
        #expect(registry.contains(window: window))

        window.close()
        await Task.yield()
        registry.resetForTests()
    }
}
