// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation
import Testing

@testable import OmniWM

private func makeOwnedWindowTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.owned-window.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

@MainActor
private func makeOwnedWindowTestController() -> WMController {
    let operations = WindowFocusOperations(
        activateApp: { _ in },
        focusSpecificWindow: { _, _, _ in },
        raiseWindow: { _ in }
    )
    return WMController(
        settings: SettingsStore(defaults: makeOwnedWindowTestDefaults()),
        windowFocusOperations: operations
    )
}

@MainActor
private func closeOwnedUtilityWindowsForTests() async {
    SettingsWindowController.shared.windowForTests?.close()
    AppRulesWindowController.shared.windowForTests?.close()
    SponsorsWindowController.shared.windowForTests?.close()
    await Task.yield()
}

@Suite(.serialized) struct OwnedWindowRegistryTests {
    @Test @MainActor func utilityWindowControllersRegisterAndUnregisterWindows() async {
        let registry = OwnedWindowRegistry.shared
        registry.resetForTests()
        await closeOwnedUtilityWindowsForTests()
        defer {
            registry.resetForTests()
        }

        let controller = makeOwnedWindowTestController()
        let settings = controller.settings

        SettingsWindowController.shared.show(settings: settings, controller: controller)
        AppRulesWindowController.shared.show(settings: settings, controller: controller)
        SponsorsWindowController.shared.show()

        guard let settingsWindow = SettingsWindowController.shared.windowForTests,
              let appRulesWindow = AppRulesWindowController.shared.windowForTests,
              let sponsorsWindow = SponsorsWindowController.shared.windowForTests
        else {
            Issue.record("Expected owned utility windows to be created")
            return
        }

        #expect(registry.contains(window: settingsWindow))
        #expect(registry.contains(window: appRulesWindow))
        #expect(registry.contains(window: sponsorsWindow))
        #expect(registry.contains(windowNumber: settingsWindow.windowNumber))
        #expect(registry.contains(windowNumber: appRulesWindow.windowNumber))
        #expect(registry.contains(windowNumber: sponsorsWindow.windowNumber))

        settingsWindow.close()
        appRulesWindow.close()
        sponsorsWindow.close()
        await Task.yield()

        #expect(registry.contains(window: settingsWindow) == false)
        #expect(registry.contains(window: appRulesWindow) == false)
        #expect(registry.contains(window: sponsorsWindow) == false)
        #expect(registry.contains(windowNumber: settingsWindow.windowNumber) == false)
        #expect(registry.contains(windowNumber: appRulesWindow.windowNumber) == false)
        #expect(registry.contains(windowNumber: sponsorsWindow.windowNumber) == false)
    }

    @Test @MainActor func workspaceBarSurfaceRemainsHitTestableWithoutSuppressingManagedFocusRecovery() {
        let registry = OwnedWindowRegistry.shared
        registry.resetForTests()
        defer { registry.resetForTests() }

        let panel = WorkspaceBarPanel(
            contentRect: CGRect(x: 120, y: 90, width: 280, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.setFrame(CGRect(x: 120, y: 90, width: 280, height: 36), display: false)
        panel.orderFrontRegardless()

        registry.register(
            panel,
            surfaceId: "workspace-bar-test",
            policy: SurfacePolicy(
                kind: .workspaceBar,
                hitTestPolicy: .interactive,
                capturePolicy: .included,
                suppressesManagedFocusRecovery: false
            )
        )

        #expect(registry.contains(window: panel))
        #expect(registry.contains(windowNumber: panel.windowNumber))
        #expect(registry.contains(point: CGPoint(x: 160, y: 110)))
        #expect(registry.hasVisibleWindow == false)

        panel.close()
        registry.unregister(surfaceId: "workspace-bar-test")
    }

    @Test @MainActor func borderSurfaceRegistersWindowNumberButStaysPassthrough() {
        let registry = OwnedWindowRegistry.shared
        registry.resetForTests()
        defer { registry.resetForTests() }

        registry.registerWindowNumber(
            surfaceId: "border-test",
            policy: SurfacePolicy(
                kind: .border,
                hitTestPolicy: .passthrough,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            ),
            windowNumber: 424242,
            frameProvider: { CGRect(x: 60, y: 50, width: 400, height: 300) },
            visibilityProvider: { true }
        )

        #expect(registry.contains(windowNumber: 424242))
        #expect(registry.contains(point: CGPoint(x: 120, y: 90)) == false)
        #expect(registry.hasVisibleWindow == false)
        #expect(registry.isCaptureEligible(windowNumber: 424242) == false)
        #expect(registry.visibleSurfaceIDs(kind: .border, capturePolicy: .excluded) == ["border-test"])
    }

    @Test @MainActor func captureEligibleQueriesTreatUnregisteredWindowsAsEligible() {
        let registry = OwnedWindowRegistry.shared
        registry.resetForTests()
        defer { registry.resetForTests() }

        #expect(registry.isCaptureEligible(windowNumber: 777_777))
    }
}
