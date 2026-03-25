import AppKit
import SwiftUI
import Testing

@testable import OmniWM

@Suite(.serialized) @MainActor struct StatusBarMenuTests {
    @Test func hostedMenuViewUsesCurrentAppAppearance() throws {
        let application = NSApplication.shared
        let originalAppearance = application.appearance
        defer { application.appearance = originalAppearance }

        let controller = makeLayoutPlanTestController()
        let viewModel = StatusBarMenuViewModel(settings: controller.settings, controller: controller)

        application.appearance = NSAppearance(named: .aqua)
        let lightHost = NSHostingView(rootView: StatusBarMenuView(viewModel: viewModel))
        lightHost.appearance = application.appearance

        #expect(lightHost.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)

        application.appearance = NSAppearance(named: .darkAqua)
        let darkHost = NSHostingView(rootView: StatusBarMenuView(viewModel: viewModel))
        darkHost.appearance = application.appearance

        #expect(darkHost.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }
}
