import AppKit
import Foundation
@testable import OmniWM
import Testing

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

@MainActor
private func makeOwnedRegistryTestWindow(
    frame: CGRect = CGRect(x: 80, y: 70, width: 240, height: 180)
) -> NSWindow {
    let window = NSWindow(
        contentRect: frame,
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    return window
}

@MainActor
private func makeOwnedRegistryTestRegistry(frontmostWindow: @escaping () -> NSWindow?) -> OwnedWindowRegistry {
    OwnedWindowRegistry(
        surfaceCoordinator: SurfaceCoordinator(
            scene: SurfaceScene(
                frontmostInteractiveResolver: SurfaceFrontmostInteractiveResolver { window in
                    frontmostWindow().map { window === $0 } ?? false
                }
            )
        )
    )
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

    @Test @MainActor func utilitySurfaceHitTestingRequiresFrontmostWindow() {
        var frontmostWindow: NSWindow?
        let registry = makeOwnedRegistryTestRegistry { frontmostWindow }
        let window = makeOwnedRegistryTestWindow()
        window.orderFrontRegardless()
        let frontWindow = makeOwnedRegistryTestWindow(frame: CGRect(x: 70, y: 60, width: 260, height: 200))
        frontWindow.orderFrontRegardless()
        frontmostWindow = frontWindow
        registry.register(window)
        defer {
            registry.unregister(window)
            window.close()
            frontWindow.close()
            registry.resetForTests()
        }

        #expect(window.isVisible)
        #expect(registry.contains(point: CGPoint(x: 120, y: 110)) == false)

        frontmostWindow = window

        #expect(registry.contains(point: CGPoint(x: 120, y: 110)))
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

    @Test @MainActor func tabbedColumnOverlayRegistersInteractiveExcludedSurface() {
        let registry = OwnedWindowRegistry.shared
        registry.resetForTests()
        let manager = TabbedColumnOverlayManager()
        defer {
            manager.removeAll()
            registry.resetForTests()
        }

        let workspaceId = WorkspaceDescriptor.ID()
        let columnId = NodeId()
        let info = TabbedColumnOverlayInfo(
            workspaceId: workspaceId,
            columnId: columnId,
            columnFrame: CGRect(x: 80, y: 90, width: 500, height: 700),
            tabCount: 2,
            activeVisualIndex: 0,
            activeWindowId: nil
        )

        manager.updateOverlays([info])

        guard let windowNumber = manager.overlayWindowNumberForTests(workspaceId: workspaceId, columnId: columnId) else {
            Issue.record("Expected tabbed overlay window number")
            return
        }

        #expect(TabbedColumnOverlayManager.tabIndicatorWidth == 12)
        #expect(registry.contains(windowNumber: windowNumber))
        #expect(registry.contains(point: CGPoint(x: 73, y: 410)))
        #expect(registry.contains(point: CGPoint(x: 86, y: 410)))
        #expect(registry.contains(point: CGPoint(x: 93, y: 410)) == false)
        #expect(registry.contains(point: CGPoint(x: 97, y: 410)) == false)
        #expect(registry.contains(point: CGPoint(x: 86, y: 110)) == false)
        #expect(registry.hasVisibleWindow == false)
        #expect(registry.isCaptureEligible(windowNumber: windowNumber) == false)
        guard let configuration = manager.overlayWindowConfigurationForTests(
            workspaceId: workspaceId,
            columnId: columnId
        ) else {
            Issue.record("Expected tabbed overlay window configuration")
            return
        }
        #expect(configuration.level == .normal)
        #expect(configuration.isFloatingPanel == false)
        #expect(configuration.styleMask.contains(.nonactivatingPanel))
        #expect(configuration.canBecomeKey == false)
        #expect(configuration.canBecomeMain == false)
        #expect(configuration.collectionBehavior == [.managed, .fullScreenAuxiliary])
        #expect(registry.visibleSurfaceIDs(kind: .tabbedColumnOverlay, capturePolicy: .excluded) == [
            "tabbed-column-overlay-\(workspaceId.uuidString)-\(columnId.uuid.uuidString)"
        ])

        manager.updateOverlays([])

        #expect(registry.contains(windowNumber: windowNumber) == false)
        #expect(registry.contains(point: CGPoint(x: 86, y: 410)) == false)
    }

    @Test @MainActor func tabbedColumnOverlayRegistersClippedCompactFrameOutsideContentEdge() {
        let registry = OwnedWindowRegistry.shared
        registry.resetForTests()
        let manager = TabbedColumnOverlayManager()
        defer {
            manager.removeAll()
            registry.resetForTests()
        }

        let workspaceId = WorkspaceDescriptor.ID()
        let columnId = NodeId()
        let info = TabbedColumnOverlayInfo(
            workspaceId: workspaceId,
            columnId: columnId,
            columnFrame: CGRect(x: 80, y: -100, width: 500, height: 900),
            visibleColumnFrame: CGRect(x: 80, y: 200, width: 500, height: 120),
            tabCount: 3,
            activeVisualIndex: 1,
            activeWindowId: nil
        )

        manager.updateOverlays([info])

        guard let windowNumber = manager.overlayWindowNumberForTests(workspaceId: workspaceId, columnId: columnId) else {
            Issue.record("Expected clipped tabbed overlay window number")
            return
        }

        #expect(registry.contains(windowNumber: windowNumber))
        #expect(registry.contains(point: CGPoint(x: 73, y: 260)))
        #expect(registry.contains(point: CGPoint(x: 91, y: 260)))
        #expect(registry.contains(point: CGPoint(x: 93, y: 260)) == false)
        #expect(registry.contains(point: CGPoint(x: 86, y: 190)) == false)
        #expect(registry.contains(point: CGPoint(x: 86, y: 210)))
    }

    @Test @MainActor func tabbedColumnOverlayForceOrderingRepairsUnchangedVisibleTarget() {
        let registry = OwnedWindowRegistry.shared
        registry.resetForTests()
        let manager = TabbedColumnOverlayManager()
        defer {
            manager.removeAll()
            registry.resetForTests()
        }

        var frontedWindowNumbers: [Int] = []
        var orderedTargets: [Int] = []
        manager.frontHookForTests = { windowNumber in
            frontedWindowNumbers.append(windowNumber)
        }
        manager.orderWindowForTests = { _, targetWindowId in
            orderedTargets.append(targetWindowId)
        }

        let info = TabbedColumnOverlayInfo(
            workspaceId: WorkspaceDescriptor.ID(),
            columnId: NodeId(),
            columnFrame: CGRect(x: 80, y: 90, width: 500, height: 700),
            tabCount: 2,
            activeVisualIndex: 0,
            activeWindowId: 8181
        )

        manager.updateOverlays([info])
        manager.updateOverlays([info])
        manager.updateOverlays([info], forceOrdering: true)

        #expect(frontedWindowNumbers.count == 2)
        #expect(Set(frontedWindowNumbers).count == 1)
        #expect(orderedTargets == [8181, 8181])
    }

    @Test @MainActor func tabbedColumnOverlayTestRecordingFiltersZeroTabInfos() {
        let manager = TabbedColumnOverlayManager()
        manager.disablesWindowUpdatesForTests = true

        let visibleInfo = TabbedColumnOverlayInfo(
            workspaceId: WorkspaceDescriptor.ID(),
            columnId: NodeId(),
            columnFrame: CGRect(x: 80, y: 90, width: 500, height: 700),
            tabCount: 2,
            activeVisualIndex: 0,
            activeWindowId: nil
        )
        let emptyInfo = TabbedColumnOverlayInfo(
            workspaceId: WorkspaceDescriptor.ID(),
            columnId: NodeId(),
            columnFrame: CGRect(x: 80, y: 90, width: 500, height: 700),
            tabCount: 0,
            activeVisualIndex: 0,
            activeWindowId: nil
        )

        manager.updateOverlays([emptyInfo, visibleInfo])

        #expect(manager.lastUpdateInfosForTests == [visibleInfo])
    }

    @Test @MainActor func tabbedColumnOverlayZeroTabsCloseRegisteredOverlay() {
        let registry = OwnedWindowRegistry.shared
        registry.resetForTests()
        let manager = TabbedColumnOverlayManager()
        defer {
            manager.removeAll()
            registry.resetForTests()
        }

        let workspaceId = WorkspaceDescriptor.ID()
        let columnId = NodeId()
        let visibleInfo = TabbedColumnOverlayInfo(
            workspaceId: workspaceId,
            columnId: columnId,
            columnFrame: CGRect(x: 80, y: 90, width: 500, height: 700),
            tabCount: 2,
            activeVisualIndex: 0,
            activeWindowId: nil
        )
        let emptyInfo = TabbedColumnOverlayInfo(
            workspaceId: workspaceId,
            columnId: columnId,
            columnFrame: CGRect(x: 80, y: 90, width: 500, height: 700),
            tabCount: 0,
            activeVisualIndex: 0,
            activeWindowId: nil
        )

        manager.updateOverlays([visibleInfo])

        guard let windowNumber = manager.overlayWindowNumberForTests(workspaceId: workspaceId, columnId: columnId) else {
            Issue.record("Expected tabbed overlay window before zero-tab update")
            return
        }

        #expect(registry.contains(windowNumber: windowNumber))
        manager.updateOverlays([emptyInfo])
        #expect(manager.overlayWindowNumberForTests(workspaceId: workspaceId, columnId: columnId) == nil)
        #expect(registry.contains(windowNumber: windowNumber) == false)
        #expect(registry.contains(point: CGPoint(x: 86, y: 410)) == false)
    }

    @Test @MainActor func tabbedColumnOverlayPublishesAccessibleTabsAndPressActions() {
        let registry = OwnedWindowRegistry.shared
        registry.resetForTests()
        let manager = TabbedColumnOverlayManager()
        defer {
            manager.removeAll()
            registry.resetForTests()
        }

        let workspaceId = WorkspaceDescriptor.ID()
        let columnId = NodeId()
        var selections: [Int] = []
        manager.onSelect = { _, _, visualIndex in
            selections.append(visualIndex)
        }

        let tabs = [
            TabbedColumnOverlayTabInfo(
                visualIndex: 0,
                windowId: 111,
                appName: "Terminal",
                title: "Shell",
                isActive: false
            ),
            TabbedColumnOverlayTabInfo(
                visualIndex: 1,
                windowId: 112,
                appName: "Browser",
                title: "Docs",
                isActive: true
            )
        ]
        let info = TabbedColumnOverlayInfo(
            workspaceId: workspaceId,
            columnId: columnId,
            columnFrame: CGRect(x: 80, y: 90, width: 500, height: 700),
            tabCount: 2,
            activeVisualIndex: 1,
            activeWindowId: nil,
            tabs: tabs
        )

        manager.updateOverlays([info])

        let snapshot = manager.overlayAccessibilitySnapshotForTests(workspaceId: workspaceId, columnId: columnId)
        #expect(snapshot.map(\.visualIndex) == [0, 1])
        #expect(snapshot.allSatisfy { $0.role == .radioButton })
        #expect(snapshot.map(\.label) == ["Tab 1, Shell, Terminal", "Tab 2, Docs, Browser"])
        #expect(snapshot.map(\.value) == [false, true])
        #expect(snapshot.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })
        #expect(manager.performOverlayAccessibilityPressForTests(
            workspaceId: workspaceId,
            columnId: columnId,
            visualIndex: 0
        ))
        #expect(manager.performOverlayAccessibilityPressForTests(
            workspaceId: workspaceId,
            columnId: columnId,
            visualIndex: 7
        ) == false)
        #expect(selections == [0])
    }

    @Test func tabbedRailLayoutFitsVisibleHeight() {
        let bounds = CGRect(x: 0, y: 0, width: 20, height: 48)
        let layout = TabbedRailLayout(tabCount: 8, bounds: bounds)

        #expect(layout.railRect.height <= bounds.height)
        #expect(!layout.items.isEmpty)
        #expect(layout.items.allSatisfy { bounds.contains($0.hitRect) })
        #expect(layout.items.allSatisfy { bounds.contains($0.pillRect) })
        #expect(layout.items.first?.visualIndex == 0)
        let firstY = layout.items.first?.hitRect.minY ?? 0
        let lastY = layout.items.last?.hitRect.minY ?? 0
        #expect(firstY > lastY)
    }

    @Test func tabbedRailLayoutUsesStacklineLozengeDefaultsWhenSpaceAllows() {
        let bounds = CGRect(x: 0, y: 0, width: 20, height: 140)
        let layout = TabbedRailLayout(tabCount: 3, bounds: bounds)

        #expect(layout.railRect.height == 108)
        #expect(layout.items.map(\.hitRect.height) == [32, 32, 32])
        #expect(layout.items.first?.pillRect.width == 12)
    }

    @Test func tabbedRailLayoutHidesWhenTabsCannotReachMinimumHeight() {
        let bounds = CGRect(x: 0, y: 0, width: 20, height: 48)
        let layout = TabbedRailLayout(tabCount: 100, bounds: bounds)

        #expect(layout.items.isEmpty)
        #expect(layout.railRect == .zero)
        #expect(TabbedRailLayout.fittedHeight(tabCount: 100, availableHeight: bounds.height) == 0)
    }

    @Test @MainActor func captureEligibleQueriesTreatUnregisteredWindowsAsEligible() {
        let registry = OwnedWindowRegistry.shared
        registry.resetForTests()
        defer { registry.resetForTests() }

        #expect(registry.isCaptureEligible(windowNumber: 777_777))
    }
}
