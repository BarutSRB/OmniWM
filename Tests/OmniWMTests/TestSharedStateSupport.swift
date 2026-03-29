import AppKit
import Foundation

@testable import OmniWM

@MainActor
func resetSharedControllerStateForTests() {
    let contextFactory = AppAXContext.contextFactoryForTests
    let axWindowRefProvider = AXWindowService.axWindowRefProviderForTests
    let setFrameResultProvider = AXWindowService.setFrameResultProviderForTests
    let fastFrameProvider = AXWindowService.fastFrameProviderForTests
    let titleLookupProvider = AXWindowService.titleLookupProviderForTests
    let timeSource = AXWindowService.timeSourceForTests

    SettingsWindowController.shared.windowForTests?.close()
    AppRulesWindowController.shared.windowForTests?.close()
    SponsorsWindowController.shared.windowForTests?.close()
    OwnedWindowRegistry.shared.resetForTests()

    AppAXContext.contextFactoryForTests = contextFactory
    AXWindowService.axWindowRefProviderForTests = axWindowRefProvider
    AXWindowService.setFrameResultProviderForTests = setFrameResultProvider
    AXWindowService.fastFrameProviderForTests = fastFrameProvider
    AXWindowService.titleLookupProviderForTests = titleLookupProvider
    AXWindowService.timeSourceForTests = timeSource
    AXWindowService.clearTitleCacheForTests()
}
