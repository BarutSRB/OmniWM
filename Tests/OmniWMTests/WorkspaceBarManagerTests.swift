// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation
import Testing

@testable import OmniWM

private final class RecordingPanelStore: @unchecked Sendable {
    var panels: [WorkspaceBarPanel] = []
}

@MainActor
private final class FrameApplyRecorder {
    private var countsByPanel: [ObjectIdentifier: Int] = [:]

    func apply(frame: NSRect, to panel: WorkspaceBarPanel) {
        countsByPanel[ObjectIdentifier(panel), default: 0] += 1
        panel.setFrame(frame, display: true)
    }

    func setFrameCallCount(for panel: WorkspaceBarPanel) -> Int {
        countsByPanel[ObjectIdentifier(panel), default: 0]
    }
}

private func makeRecordingPanelFactory(
    store: RecordingPanelStore
) -> @MainActor @Sendable () -> WorkspaceBarPanel {
    {
        let panel = WorkspaceBarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        store.panels.append(panel)
        return panel
    }
}

@Suite struct WorkspaceBarManagerTests {
    @Test @MainActor func updateKeepsStableHostingViewAndSkipsFrameWritesWhenGeometryIsUnchanged() throws {
        let monitor = makeLayoutPlanTestMonitor(displayId: 77)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        let manager = WorkspaceBarManager()
        let panelStore = RecordingPanelStore()
        let frameRecorder = FrameApplyRecorder()

        manager.monitorProvider = { [monitor] }
        manager.screenProvider = { _ in nil }
        manager.panelFactory = makeRecordingPanelFactory(store: panelStore)
        manager.frameApplier = { panel, frame in
            frameRecorder.apply(frame: frame, to: panel)
        }

        manager.setup(controller: controller, settings: controller.settings)
        defer { manager.cleanup() }

        let panel = try #require(panelStore.panels.first)
        let initialHostingView = try #require(manager.hostingViewIdentifierForTests(on: monitor.id))
        let initialFrame = try #require(manager.lastAppliedFrameForTests(on: monitor.id))

        #expect(manager.activeBarCountForTests() == 1)
        #expect(frameRecorder.setFrameCallCount(for: panel) == 1)

        manager.update()

        #expect(manager.hostingViewIdentifierForTests(on: monitor.id) == initialHostingView)
        #expect(manager.lastAppliedFrameForTests(on: monitor.id) == initialFrame)
        #expect(frameRecorder.setFrameCallCount(for: panel) == 1)
    }

    @Test @MainActor func unchangedSnapshotReusesCachedMeasurementWidth() {
        let monitor = makeLayoutPlanTestMonitor(displayId: 770)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        let manager = WorkspaceBarManager()


        manager.monitorProvider = { [monitor] }
        manager.screenProvider = { _ in nil }

        manager.setup(controller: controller, settings: controller.settings)
        defer { manager.cleanup() }


        manager.update()

    }

    @Test @MainActor func nonWidthAppearanceChangesReuseCachedMeasurementWidth() {
        let monitor = makeLayoutPlanTestMonitor(displayId: 771)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        let manager = WorkspaceBarManager()


        manager.monitorProvider = { [monitor] }
        manager.screenProvider = { _ in nil }

        manager.setup(controller: controller, settings: controller.settings)
        defer { manager.cleanup() }


        controller.settings.workspaceBarBackgroundOpacity = 0.35
        manager.updateSettings()

    }

    @Test @MainActor func groupedWindowBadgeWidthChangeRemeasuresAndExpandsFrame() throws {
        let monitor = makeLayoutPlanTestMonitor(displayId: 772, width: 3200)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false) else {
            Issue.record("Missing workspace bar fixture")
            return
        }

        controller.settings.workspaceBarDeduplicateAppIcons = true
        controller.appInfoCache.storeInfoForTests(
            pid: 8201,
            name: "Shared App",
            bundleId: "com.example.shared"
        )

        for windowId in 1301...1309 {
            _ = controller.workspaceManager.addWindow(
                makeLayoutPlanTestWindow(windowId: windowId),
                pid: 8201,
                windowId: windowId,
                to: workspaceId,
                mode: .tiling
            )
        }

        let manager = WorkspaceBarManager()
        let panelStore = RecordingPanelStore()
        let frameRecorder = FrameApplyRecorder()


        manager.monitorProvider = { [monitor] }
        manager.screenProvider = { _ in nil }
        manager.panelFactory = makeRecordingPanelFactory(store: panelStore)
        manager.frameApplier = { panel, frame in
            frameRecorder.apply(frame: frame, to: panel)
        }

        manager.setup(controller: controller, settings: controller.settings)
        defer { manager.cleanup() }

        _ = try #require(panelStore.panels.first)
        let initialSnapshot = try #require(manager.snapshotForTests(on: monitor.id))
        let initialWorkspaceItem = try #require(initialSnapshot.items.first(where: { $0.id == workspaceId }))

        #expect(initialWorkspaceItem.tiledWindows.count == 1)
        #expect(initialWorkspaceItem.tiledWindows.first?.windowCount == 9)

        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1310),
            pid: 8201,
            windowId: 1310,
            to: workspaceId,
            mode: .tiling
        )

        manager.update()

        let updatedSnapshot = try #require(manager.snapshotForTests(on: monitor.id))
        let updatedWorkspaceItem = try #require(updatedSnapshot.items.first(where: { $0.id == workspaceId }))
        #expect(updatedWorkspaceItem.tiledWindows.count == 1)
        #expect(updatedWorkspaceItem.tiledWindows.first?.windowCount == 10)
    }

    @Test @MainActor func widthChangingContentRefreshRemeasuresOnceAndUpdatesFrame() throws {
        let monitor = makeLayoutPlanTestMonitor(displayId: 78, width: 3200)
        let workspaceConfigurations = (1...9).map {
            WorkspaceConfiguration(
                name: "\($0)",
                displayName: "Workspace \($0)",
                monitorAssignment: .main
            )
        }
        let controller = makeLayoutPlanTestController(
            monitors: [monitor],
            workspaceConfigurations: workspaceConfigurations
        )
        controller.settings.workspaceBarHideEmptyWorkspaces = true
        controller.workspaceManager.applySettings()

        for index in 1...4 {
            let workspaceId = try #require(controller.workspaceManager.workspaceId(for: "\(index)", createIfMissing: true))
            addLayoutPlanTestWindow(
                on: controller,
                workspaceId: workspaceId,
                windowId: 100 + index
            )
        }

        let manager = WorkspaceBarManager()
        let panelStore = RecordingPanelStore()
        let frameRecorder = FrameApplyRecorder()

        manager.monitorProvider = { [monitor] }
        manager.screenProvider = { _ in nil }
        manager.panelFactory = makeRecordingPanelFactory(store: panelStore)
        manager.frameApplier = { panel, frame in
            frameRecorder.apply(frame: frame, to: panel)
        }

        manager.setup(controller: controller, settings: controller.settings)
        defer { manager.cleanup() }

        let panel = try #require(panelStore.panels.first)
        let initialFrame = try #require(manager.lastAppliedFrameForTests(on: monitor.id))

        for index in 5...9 {
            let workspaceId = try #require(controller.workspaceManager.workspaceId(for: "\(index)", createIfMissing: true))
            addLayoutPlanTestWindow(
                on: controller,
                workspaceId: workspaceId,
                windowId: 100 + index
            )
        }

        manager.update()

        let updatedFrame = try #require(manager.lastAppliedFrameForTests(on: monitor.id))
        #expect(frameRecorder.setFrameCallCount(for: panel) == 2)
        #expect(updatedFrame.width > initialFrame.width)
    }

    @Test @MainActor func enablingFloatingWindowsRemeasuresWhenFloatingOnlyWorkspaceBecomesVisible() throws {
        let monitor = makeLayoutPlanTestMonitor(displayId: 781, width: 3200)
        let workspaceConfigurations = (1...9).map {
            WorkspaceConfiguration(
                name: "\($0)",
                displayName: "Workspace \($0)",
                monitorAssignment: .main
            )
        }
        let controller = makeLayoutPlanTestController(
            monitors: [monitor],
            workspaceConfigurations: workspaceConfigurations
        )
        controller.settings.workspaceBarHideEmptyWorkspaces = true
        controller.settings.workspaceBarShowFloatingWindows = false
        controller.workspaceManager.applySettings()

        guard let workspace1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false) else {
            Issue.record("Missing workspace bar fixture")
            return
        }

        controller.appInfoCache.storeInfoForTests(pid: 8101, name: "Tiled App", bundleId: "com.example.tiled")
        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1201),
            pid: 8101,
            windowId: 1201,
            to: workspace1,
            mode: .tiling
        )
        for index in 2...9 {
            guard let workspaceId = controller.workspaceManager.workspaceId(for: "\(index)", createIfMissing: false) else {
                Issue.record("Missing floating workspace fixture \(index)")
                return
            }
            let pid: pid_t = 8100 + pid_t(index)
            let windowId = 1200 + index
            controller.appInfoCache.storeInfoForTests(
                pid: pid,
                name: "Floating \(index)",
                bundleId: "com.example.floating.\(index)"
            )
            _ = controller.workspaceManager.addWindow(
                makeLayoutPlanTestWindow(windowId: windowId),
                pid: pid,
                windowId: windowId,
                to: workspaceId,
                mode: .floating
            )
        }

        let manager = WorkspaceBarManager()
        let panelStore = RecordingPanelStore()
        let frameRecorder = FrameApplyRecorder()

        manager.monitorProvider = { [monitor] }
        manager.screenProvider = { _ in nil }
        manager.panelFactory = makeRecordingPanelFactory(store: panelStore)
        manager.frameApplier = { panel, frame in
            frameRecorder.apply(frame: frame, to: panel)
        }

        manager.setup(controller: controller, settings: controller.settings)
        defer { manager.cleanup() }

        let panel = try #require(panelStore.panels.first)
        let initialFrame = try #require(manager.lastAppliedFrameForTests(on: monitor.id))
        let initialHostingView = try #require(manager.hostingViewIdentifierForTests(on: monitor.id))

        controller.settings.workspaceBarShowFloatingWindows = true
        manager.updateSettings()

        let updatedFrame = try #require(manager.lastAppliedFrameForTests(on: monitor.id))
        #expect(manager.hostingViewIdentifierForTests(on: monitor.id) == initialHostingView)
        #expect(frameRecorder.setFrameCallCount(for: panel) == 2)
        #expect(updatedFrame.width > initialFrame.width)
    }

    @Test @MainActor func updateSettingsRemeasuresWithoutReplacingTheLiveHost() throws {
        let monitor = makeLayoutPlanTestMonitor(displayId: 79)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        let manager = WorkspaceBarManager()
        let panelStore = RecordingPanelStore()
        let frameRecorder = FrameApplyRecorder()

        manager.monitorProvider = { [monitor] }
        manager.screenProvider = { _ in nil }
        manager.panelFactory = makeRecordingPanelFactory(store: panelStore)
        manager.frameApplier = { panel, frame in
            frameRecorder.apply(frame: frame, to: panel)
        }

        manager.setup(controller: controller, settings: controller.settings)
        defer { manager.cleanup() }

        let panel = try #require(panelStore.panels.first)
        let initialHostingView = try #require(manager.hostingViewIdentifierForTests(on: monitor.id))

        controller.settings.workspaceBarHeight = 48
        manager.updateSettings()

        let updatedFrame = try #require(manager.lastAppliedFrameForTests(on: monitor.id))
        #expect(manager.hostingViewIdentifierForTests(on: monitor.id) == initialHostingView)
        #expect(frameRecorder.setFrameCallCount(for: panel) == 2)
        #expect(updatedFrame.height == 48)
    }

    @Test @MainActor func reconfigureBarsAddsAndRemovesPanelsWithoutRecreatingSurvivors() throws {
        let primaryMonitor = makeLayoutPlanTestMonitor(displayId: 80)
        let secondaryMonitor = makeLayoutPlanTestMonitor(displayId: 81, x: 1920)
        let controller = makeLayoutPlanTestController(
            monitors: [primaryMonitor, secondaryMonitor],
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", monitorAssignment: .secondary)
            ]
        )
        let manager = WorkspaceBarManager()
        let panelStore = RecordingPanelStore()

        manager.monitorProvider = { [primaryMonitor] }
        manager.screenProvider = { _ in nil }
        manager.panelFactory = makeRecordingPanelFactory(store: panelStore)

        manager.setup(controller: controller, settings: controller.settings)
        defer { manager.cleanup() }

        let primaryHostingView = try #require(manager.hostingViewIdentifierForTests(on: primaryMonitor.id))
        #expect(manager.activeBarCountForTests() == 1)
        #expect(panelStore.panels.count == 1)

        manager.reconfigureBars(using: [primaryMonitor, secondaryMonitor])

        let secondaryHostingView = try #require(manager.hostingViewIdentifierForTests(on: secondaryMonitor.id))
        #expect(manager.activeBarCountForTests() == 2)
        #expect(manager.hostingViewIdentifierForTests(on: primaryMonitor.id) == primaryHostingView)
        #expect(panelStore.panels.count == 2)

        manager.reconfigureBars(using: [secondaryMonitor])

        #expect(manager.activeBarCountForTests() == 1)
        #expect(manager.hostingViewIdentifierForTests(on: secondaryMonitor.id) == secondaryHostingView)
        #expect(manager.hostingViewIdentifierForTests(on: primaryMonitor.id) == nil)
        #expect(panelStore.panels.count == 2)
    }

    @Test @MainActor func cleanupCancelsPendingReconfigureBeforeItCanRecreatePanels() async {
        let monitor = makeLayoutPlanTestMonitor(displayId: 82)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        let manager = WorkspaceBarManager()
        let panelStore = RecordingPanelStore()

        manager.monitorProvider = { [monitor] }
        manager.screenProvider = { _ in nil }
        manager.panelFactory = makeRecordingPanelFactory(store: panelStore)

        manager.setup(controller: controller, settings: controller.settings)
        #expect(manager.activeBarCountForTests() == 1)
        #expect(panelStore.panels.count == 1)

        manager.scheduleReconfigure(after: 50_000_000)
        manager.cleanup()

        try? await Task.sleep(nanoseconds: 120_000_000)

        #expect(manager.activeBarCountForTests() == 0)
        #expect(panelStore.panels.count == 1)
    }

    @Test @MainActor func globalDisableWithoutOverridesStaysEmptyAcrossScheduledReconfigure() async {
        let monitor = makeLayoutPlanTestMonitor(displayId: 83)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        controller.settings.workspaceBarEnabled = false

        let manager = WorkspaceBarManager()
        let panelStore = RecordingPanelStore()

        manager.monitorProvider = { [monitor] }
        manager.screenProvider = { _ in nil }
        manager.panelFactory = makeRecordingPanelFactory(store: panelStore)

        manager.setup(controller: controller, settings: controller.settings)
        defer { manager.cleanup() }

        #expect(manager.activeBarCountForTests() == 0)
        #expect(panelStore.panels.isEmpty)

        manager.scheduleReconfigure(after: 50_000_000)
        try? await Task.sleep(nanoseconds: 120_000_000)

        #expect(manager.activeBarCountForTests() == 0)
        #expect(panelStore.panels.isEmpty)
    }

    @Test @MainActor func globalDisableWithMonitorOverrideKeepsBarAliveAcrossUpdateAndReconfigure() async throws {
        let monitor = makeLayoutPlanTestMonitor(displayId: 84)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        controller.settings.workspaceBarEnabled = false
        controller.settings.updateBarSettings(
            MonitorBarSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                enabled: true
            )
        )

        let manager = WorkspaceBarManager()
        let panelStore = RecordingPanelStore()

        manager.monitorProvider = { [monitor] }
        manager.screenProvider = { _ in nil }
        manager.panelFactory = makeRecordingPanelFactory(store: panelStore)

        manager.setup(controller: controller, settings: controller.settings)
        defer { manager.cleanup() }

        let initialHostingView = try #require(manager.hostingViewIdentifierForTests(on: monitor.id))
        #expect(manager.activeBarCountForTests() == 1)
        #expect(panelStore.panels.count == 1)

        manager.update()

        #expect(manager.activeBarCountForTests() == 1)
        #expect(manager.hostingViewIdentifierForTests(on: monitor.id) == initialHostingView)
        #expect(panelStore.panels.count == 1)

        manager.scheduleReconfigure(after: 50_000_000)
        try? await Task.sleep(nanoseconds: 120_000_000)

        #expect(manager.activeBarCountForTests() == 1)
        #expect(manager.hostingViewIdentifierForTests(on: monitor.id) == initialHostingView)
        #expect(panelStore.panels.count == 1)
    }

    @Test @MainActor func disablingGlobalDefaultPreservesEnabledOverrideWithoutRecreatingSurvivor() throws {
        let primaryMonitor = makeLayoutPlanTestMonitor(displayId: 85)
        let secondaryMonitor = makeLayoutPlanTestMonitor(displayId: 86, x: 1920)
        let controller = makeLayoutPlanTestController(
            monitors: [primaryMonitor, secondaryMonitor],
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", monitorAssignment: .secondary)
            ]
        )
        controller.settings.updateBarSettings(
            MonitorBarSettings(
                monitorName: secondaryMonitor.name,
                monitorDisplayId: secondaryMonitor.displayId,
                enabled: true
            )
        )

        let manager = WorkspaceBarManager()
        let panelStore = RecordingPanelStore()

        manager.monitorProvider = { [primaryMonitor, secondaryMonitor] }
        manager.screenProvider = { _ in nil }
        manager.panelFactory = makeRecordingPanelFactory(store: panelStore)

        manager.setup(controller: controller, settings: controller.settings)
        defer { manager.cleanup() }

        let secondaryHostingView = try #require(manager.hostingViewIdentifierForTests(on: secondaryMonitor.id))
        #expect(manager.activeBarCountForTests() == 2)
        #expect(panelStore.panels.count == 2)

        controller.settings.workspaceBarEnabled = false
        manager.updateSettings()

        #expect(manager.activeBarCountForTests() == 1)
        #expect(manager.hostingViewIdentifierForTests(on: primaryMonitor.id) == nil)
        #expect(manager.hostingViewIdentifierForTests(on: secondaryMonitor.id) == secondaryHostingView)
        #expect(panelStore.panels.count == 2)
    }
}

@Suite @MainActor struct WorkspaceBarControllerAppearanceRefreshTests {
    @Test func updateWorkspaceBarAppearanceRefreshesLiveBarWithoutRelayout() throws {
        let monitor = makeLayoutPlanTestMonitor(displayId: 88, width: 3200)
        let workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", displayName: "Workspace Atlas", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", displayName: "Workspace Borealis", monitorAssignment: .main),
            WorkspaceConfiguration(name: "3", displayName: "Workspace Cascade", monitorAssignment: .main),
            WorkspaceConfiguration(name: "4", displayName: "Workspace Delta", monitorAssignment: .main)
        ]
        let controller = makeLayoutPlanTestController(
            monitors: [monitor],
            workspaceConfigurations: workspaceConfigurations
        )
        defer { controller.cleanupUIOnStop() }

        controller.settings.workspaceBarLabelFontSize = 10

        let panelStore = RecordingPanelStore()
        let frameRecorder = FrameApplyRecorder()
        controller.configureWorkspaceBarManagerForTests(
            monitors: [monitor],
            panelFactory: makeRecordingPanelFactory(store: panelStore),
            frameApplier: { panel, frame in
                frameRecorder.apply(frame: frame, to: panel)
            }
        )
        controller.setWorkspaceBarEnabled(true)
        controller.layoutRefreshController.resetDebugState()

        let panel = try #require(panelStore.panels.first)
        let initialHostingView = try #require(controller.workspaceBarHostingViewIdentifierForTests(on: monitor.id))
        let initialSnapshot = try #require(controller.workspaceBarSnapshotForTests(on: monitor.id))
        let initialFrame = try #require(controller.workspaceBarLastAppliedFrameForTests(on: monitor.id))

        #expect(controller.activeWorkspaceBarCountForTests() == 1)
        #expect(initialSnapshot.labelFontSize == CGFloat(10))
        #expect(frameRecorder.setFrameCallCount(for: panel) == 1)

        controller.settings.workspaceBarLabelFontSize = 16
        controller.updateWorkspaceBarAppearance()

        let updatedSnapshot = try #require(controller.workspaceBarSnapshotForTests(on: monitor.id))
        let updatedFrame = try #require(controller.workspaceBarLastAppliedFrameForTests(on: monitor.id))
        let refreshDebug = controller.layoutRefreshController.refreshDebugSnapshot()

        #expect(controller.activeWorkspaceBarCountForTests() == 1)
        #expect(panelStore.panels.count == 1)
        #expect(controller.workspaceBarHostingViewIdentifierForTests(on: monitor.id) == initialHostingView)
        #expect(updatedSnapshot.labelFontSize == CGFloat(16))
        #expect(updatedFrame.width > initialFrame.width)
        #expect(frameRecorder.setFrameCallCount(for: panel) == 2)
        #expect(refreshDebug.relayoutExecutions == 0)
        #expect(refreshDebug.immediateRelayoutExecutions == 0)
        #expect(refreshDebug.fullRescanExecutions == 0)
    }
}

@Suite(.serialized) @MainActor struct WorkspaceBarManagerAppearanceTests {
    @Test func updateSettingsRefreshesAppearanceWithoutReplacingLiveHost() throws {
        let application = NSApplication.shared
        let originalAppearance = application.appearance
        defer { application.appearance = originalAppearance }

        let monitor = makeLayoutPlanTestMonitor(displayId: 87)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        let manager = WorkspaceBarManager()
        let panelStore = RecordingPanelStore()

        manager.monitorProvider = { [monitor] }
        manager.screenProvider = { _ in nil }
        manager.panelFactory = makeRecordingPanelFactory(store: panelStore)

        application.appearance = NSAppearance(named: .aqua)
        manager.setup(controller: controller, settings: controller.settings)
        defer { manager.cleanup() }

        let initialHostingView = try #require(manager.hostingViewIdentifierForTests(on: monitor.id))

        #expect(manager.panelEffectiveAppearanceForTests(on: monitor.id) == .aqua)
        #expect(manager.hostingViewEffectiveAppearanceForTests(on: monitor.id) == .aqua)

        application.appearance = NSAppearance(named: .darkAqua)
        manager.updateSettings()

        #expect(manager.hostingViewIdentifierForTests(on: monitor.id) == initialHostingView)
        #expect(manager.panelEffectiveAppearanceForTests(on: monitor.id) == .darkAqua)
        #expect(manager.hostingViewEffectiveAppearanceForTests(on: monitor.id) == .darkAqua)
    }
}
