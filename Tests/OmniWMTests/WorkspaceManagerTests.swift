// SPDX-License-Identifier: GPL-2.0-only
import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import Testing

private func makeWorkspaceManagerTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.workspace-manager.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeWorkspaceManagerTestMonitor(
    displayId: CGDirectDisplayID,
    name: String,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat = 1920,
    height: CGFloat = 1080
) -> Monitor {
    let frame = CGRect(x: x, y: y, width: width, height: height)
    return Monitor(
        id: Monitor.ID(displayId: displayId),
        displayId: displayId,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: name
    )
}

private func makeWorkspaceManagerTestWindow(windowId: Int = 101) -> AXWindowRef {
    AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
}

private func makeWorkspaceManagerReplacementMetadata(
    bundleId: String = "com.example.editor",
    workspaceId: WorkspaceDescriptor.ID,
    mode: TrackedWindowMode = .tiling,
    title: String? = "Sprint Notes",
    role: String? = "AXWindow",
    subrole: String? = "AXStandardWindow",
    windowLevel: Int32? = 0,
    parentWindowId: UInt32? = nil,
    frame: CGRect? = nil
) -> ManagedReplacementMetadata {
    ManagedReplacementMetadata(
        bundleId: bundleId,
        workspaceId: workspaceId,
        mode: mode,
        role: role,
        subrole: subrole,
        title: title,
        windowLevel: windowLevel,
        parentWindowId: parentWindowId,
        frame: frame
    )
}

@MainActor
private func addWorkspaceManagerTestHandle(
    manager: WorkspaceManager,
    windowId: Int,
    pid: pid_t = getpid(),
    workspaceId: WorkspaceDescriptor.ID
) -> WindowHandle {
    let token = manager.addWindow(
        makeWorkspaceManagerTestWindow(windowId: windowId),
        pid: pid,
        windowId: windowId,
        to: workspaceId
    )
    guard let handle = manager.handle(for: token) else {
        fatalError("Expected bridge handle for workspace manager test")
    }
    return handle
}

private func workspaceConfigurations(
    _ assignments: [(String, MonitorAssignment)]
) -> [WorkspaceConfiguration] {
    assignments.map { name, assignment in
        WorkspaceConfiguration(name: name, monitorAssignment: assignment)
    }
}

@MainActor struct PersistedWindowRestoreCatalogWorkspaceManagerTests {
    @Test func `relaunch hydration resolves workspace name onto fresh runtime workspace id`() throws {
        let defaults = makeWorkspaceManagerTestDefaults()

        let initialSettings = SettingsStore(defaults: defaults)
        initialSettings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .main)
        ])
        let initialManager = WorkspaceManager(settings: initialSettings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 401, name: "Main", x: 0, y: 0)
        initialManager.applyMonitorConfigurationChange([monitor])

        _ = try #require(initialManager.workspaceId(for: "1", createIfMissing: true))
        let initialWorkspace2 = try #require(initialManager.workspaceId(for: "2", createIfMissing: true))
        let sourceToken = initialManager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 4001),
            pid: 4001,
            windowId: 4001,
            to: initialWorkspace2
        )
        _ = initialManager.setManagedReplacementMetadata(
            makeWorkspaceManagerReplacementMetadata(
                workspaceId: initialWorkspace2,
                title: "Workspace Restore"
            ),
            for: sourceToken
        )
        initialManager.flushPersistedWindowRestoreCatalogNow()
        let persistedEntries = initialManager.persistedWindowRestoreCatalogForTests().entries
        #expect(persistedEntries.count == 1)

        let relaunchedSettings = SettingsStore(defaults: defaults)
        let relaunchedManager = WorkspaceManager(settings: relaunchedSettings)
        relaunchedManager.applyMonitorConfigurationChange([monitor])

        let relaunchedWorkspace1 = try #require(relaunchedManager.workspaceId(for: "1", createIfMissing: true))
        let relaunchedWorkspace2 = try #require(relaunchedManager.workspaceId(for: "2", createIfMissing: true))
        #expect(relaunchedWorkspace2 != initialWorkspace2)

        let relaunchedToken = relaunchedManager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 4002),
            pid: 4002,
            windowId: 4002,
            to: relaunchedWorkspace1,
            managedReplacementMetadata: makeWorkspaceManagerReplacementMetadata(
                workspaceId: relaunchedWorkspace1,
                title: "Workspace Restore"
            )
        )

        #expect(relaunchedManager.workspace(for: relaunchedToken) == relaunchedWorkspace2)
        #expect(relaunchedManager.replacementCorrelation(for: relaunchedToken) == nil)
        #expect(relaunchedManager.consumedBootPersistedWindowRestoreKeysForTests() == Set(persistedEntries.map(\.key)))
    }

    @Test func `same topology relaunch restores floating geometry and rescue eligibility`() throws {
        let defaults = makeWorkspaceManagerTestDefaults()

        let initialSettings = SettingsStore(defaults: defaults)
        initialSettings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main)
        ])
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 410, name: "Studio Display", x: 0, y: 0)
        let initialManager = WorkspaceManager(settings: initialSettings)
        initialManager.applyMonitorConfigurationChange([monitor])

        let initialWorkspace = try #require(initialManager.workspaceId(for: "1", createIfMissing: true))
        let sourceToken = initialManager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 4101),
            pid: 4101,
            windowId: 4101,
            to: initialWorkspace,
            mode: .floating
        )
        _ = initialManager.setManagedReplacementMetadata(
            makeWorkspaceManagerReplacementMetadata(
                workspaceId: initialWorkspace,
                mode: .floating,
                title: "Floating Restore"
            ),
            for: sourceToken
        )
        let persistedFrame = CGRect(x: 360, y: 210, width: 780, height: 520)
        initialManager.updateFloatingGeometry(
            frame: persistedFrame,
            for: sourceToken,
            referenceMonitor: monitor,
            restoreToFloating: true
        )
        initialManager.flushPersistedWindowRestoreCatalogNow()

        let relaunchedSettings = SettingsStore(defaults: defaults)
        let relaunchedManager = WorkspaceManager(settings: relaunchedSettings)
        relaunchedManager.applyMonitorConfigurationChange([monitor])

        let relaunchedWorkspace = try #require(relaunchedManager.workspaceId(for: "1", createIfMissing: true))
        let relaunchedToken = relaunchedManager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 4102),
            pid: 4102,
            windowId: 4102,
            to: relaunchedWorkspace,
            mode: .tiling,
            managedReplacementMetadata: makeWorkspaceManagerReplacementMetadata(
                workspaceId: relaunchedWorkspace,
                title: "Floating Restore"
            )
        )

        let restoredFrame = try #require(
            relaunchedManager.resolvedFloatingFrame(for: relaunchedToken, preferredMonitor: monitor)
        )
        let restoreIntent = try #require(relaunchedManager.restoreIntent(for: relaunchedToken))

        #expect(relaunchedManager.windowMode(for: relaunchedToken) == .floating)
        #expect(restoredFrame == persistedFrame)
        #expect(restoreIntent.rescueEligible)
    }

    @Test func `near fullscreen floating geometry stores exact normalized origin`() throws {
        let settings = SettingsStore(defaults: makeWorkspaceManagerTestDefaults())
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main)
        ])
        let monitor = makeWorkspaceManagerTestMonitor(
            displayId: 411,
            name: "Studio Display",
            x: 0,
            y: 0,
            width: 100,
            height: 100
        )
        let manager = WorkspaceManager(settings: settings)
        manager.applyMonitorConfigurationChange([monitor])

        let workspaceId = try #require(manager.workspaceId(for: "1", createIfMissing: true))
        let token = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 4111),
            pid: 4111,
            windowId: 4111,
            to: workspaceId,
            mode: .floating
        )
        manager.updateFloatingGeometry(
            frame: CGRect(x: 0.25, y: 0.125, width: 99.5, height: 99.75),
            for: token,
            referenceMonitor: monitor
        )

        let normalizedOrigin = try #require(manager.floatingState(for: token)?.normalizedOrigin)
        #expect(normalizedOrigin.x == 0.5)
        #expect(normalizedOrigin.y == 0.5)
    }

    @Test func `persisted restore falls back to best monitor across single to multi relaunch`() throws {
        let defaults = makeWorkspaceManagerTestDefaults()

        let initialSettings = SettingsStore(defaults: defaults)
        initialSettings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main)
        ])
        let oldStudio = makeWorkspaceManagerTestMonitor(
            displayId: 420,
            name: "Studio Display",
            x: 0,
            y: 0,
            width: 1600,
            height: 900
        )
        let initialManager = WorkspaceManager(settings: initialSettings)
        initialManager.applyMonitorConfigurationChange([oldStudio])

        let initialWorkspace = try #require(initialManager.workspaceId(for: "1", createIfMissing: true))
        let sourceToken = initialManager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 4201),
            pid: 4201,
            windowId: 4201,
            to: initialWorkspace,
            mode: .floating
        )
        _ = initialManager.setManagedReplacementMetadata(
            makeWorkspaceManagerReplacementMetadata(
                workspaceId: initialWorkspace,
                mode: .floating,
                title: "Monitor Fallback"
            ),
            for: sourceToken
        )
        initialManager.updateFloatingGeometry(
            frame: CGRect(x: 1260, y: 620, width: 280, height: 180),
            for: sourceToken,
            referenceMonitor: oldStudio,
            restoreToFloating: true
        )
        initialManager.flushPersistedWindowRestoreCatalogNow()

        let newStudio = makeWorkspaceManagerTestMonitor(
            displayId: 421,
            name: "Studio Display",
            x: 0,
            y: 0,
            width: 1600,
            height: 900
        )
        let sideMonitor = makeWorkspaceManagerTestMonitor(
            displayId: 422,
            name: "Sidecar",
            x: 1600,
            y: 0,
            width: 1280,
            height: 900
        )
        let relaunchedManager = WorkspaceManager(settings: SettingsStore(defaults: defaults))
        relaunchedManager.applyMonitorConfigurationChange([newStudio, sideMonitor])

        let relaunchedWorkspace = try #require(relaunchedManager.workspaceId(for: "1", createIfMissing: true))
        let relaunchedToken = relaunchedManager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 4202),
            pid: 4202,
            windowId: 4202,
            to: relaunchedWorkspace,
            managedReplacementMetadata: makeWorkspaceManagerReplacementMetadata(
                workspaceId: relaunchedWorkspace,
                title: "Monitor Fallback"
            )
        )

        let restoreIntent = try #require(relaunchedManager.restoreIntent(for: relaunchedToken))
        let restoredFrame = try #require(
            relaunchedManager.resolvedFloatingFrame(for: relaunchedToken, preferredMonitor: newStudio)
        )

        #expect(restoreIntent.preferredMonitor?.displayId == newStudio.displayId)
        #expect(newStudio.visibleFrame.contains(restoredFrame))
    }

    @Test func `persisted restore keeps floating recovery within bounds across multi to single relaunch`() throws {
        let defaults = makeWorkspaceManagerTestDefaults()

        let initialSettings = SettingsStore(defaults: defaults)
        initialSettings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])
        let primary = makeWorkspaceManagerTestMonitor(displayId: 430, name: "Primary", x: 0, y: 0)
        let secondary = makeWorkspaceManagerTestMonitor(displayId: 431, name: "Secondary", x: 1920, y: 0)
        let initialManager = WorkspaceManager(settings: initialSettings)
        initialManager.applyMonitorConfigurationChange([primary, secondary])

        let initialWorkspace1 = try #require(initialManager.workspaceId(for: "1", createIfMissing: true))
        let initialWorkspace2 = try #require(initialManager.workspaceId(for: "2", createIfMissing: true))
        let sourceToken = initialManager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 4301),
            pid: 4301,
            windowId: 4301,
            to: initialWorkspace2,
            mode: .floating
        )
        _ = initialManager.setManagedReplacementMetadata(
            makeWorkspaceManagerReplacementMetadata(
                workspaceId: initialWorkspace2,
                mode: .floating,
                title: "Collapsed Restore"
            ),
            for: sourceToken
        )
        initialManager.updateFloatingGeometry(
            frame: CGRect(x: 3440, y: 720, width: 320, height: 220),
            for: sourceToken,
            referenceMonitor: secondary,
            restoreToFloating: true
        )
        initialManager.flushPersistedWindowRestoreCatalogNow()

        let singleMonitor = makeWorkspaceManagerTestMonitor(
            displayId: 432,
            name: "Primary",
            x: 0,
            y: 0,
            width: 1440,
            height: 900
        )
        let relaunchedManager = WorkspaceManager(settings: SettingsStore(defaults: defaults))
        relaunchedManager.applyMonitorConfigurationChange([singleMonitor])

        let relaunchedWorkspace1 = try #require(relaunchedManager.workspaceId(for: "1", createIfMissing: true))
        let relaunchedWorkspace2 = try #require(relaunchedManager.workspaceId(for: "2", createIfMissing: true))
        let relaunchedToken = relaunchedManager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 4302),
            pid: 4302,
            windowId: 4302,
            to: relaunchedWorkspace1,
            managedReplacementMetadata: makeWorkspaceManagerReplacementMetadata(
                workspaceId: relaunchedWorkspace1,
                title: "Collapsed Restore"
            )
        )

        let restoredFrame = try #require(
            relaunchedManager.resolvedFloatingFrame(for: relaunchedToken, preferredMonitor: singleMonitor)
        )

        #expect(relaunchedManager.workspace(for: relaunchedToken) == relaunchedWorkspace2)
        #expect(singleMonitor.visibleFrame.contains(restoredFrame))
        #expect(initialWorkspace1 != relaunchedWorkspace1)
    }

    @Test func `ambiguous duplicate semantic keys are rejected from persistence`() throws {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main)
        ])

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 440, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        let workspaceId = try #require(manager.workspaceId(for: "1", createIfMissing: true))
        let firstToken = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 4401),
            pid: 4401,
            windowId: 4401,
            to: workspaceId
        )
        let secondToken = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 4402),
            pid: 4402,
            windowId: 4402,
            to: workspaceId
        )

        let ambiguousMetadata = makeWorkspaceManagerReplacementMetadata(
            bundleId: "com.example.terminal",
            workspaceId: workspaceId,
            title: nil
        )
        _ = manager.setManagedReplacementMetadata(ambiguousMetadata, for: firstToken)
        _ = manager.setManagedReplacementMetadata(ambiguousMetadata, for: secondToken)

        #expect(manager.persistedWindowRestoreCatalogForTests().entries.isEmpty)
    }

    @Test func `removing tracked window removes persisted entry on next catalog save`() throws {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main)
        ])

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 450, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        let workspaceId = try #require(manager.workspaceId(for: "1", createIfMissing: true))
        let token = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 4501),
            pid: 4501,
            windowId: 4501,
            to: workspaceId
        )
        _ = manager.setManagedReplacementMetadata(
            makeWorkspaceManagerReplacementMetadata(
                workspaceId: workspaceId,
                title: "Removal"
            ),
            for: token
        )

        manager.flushPersistedWindowRestoreCatalogNow()
        #expect(settings.loadPersistedWindowRestoreCatalog().entries.count == 1)

        _ = manager.removeWindow(pid: token.pid, windowId: token.windowId)
        manager.flushPersistedWindowRestoreCatalogNow()

        #expect(settings.loadPersistedWindowRestoreCatalog() == .empty)
    }
}

struct WorkspaceManagerTests {
    @Test func `managed restore semantic identity changes when semantic snapshot fields change`() {
        let frameTolerance: CGFloat = 0.5
        let workspaceId = UUID()
        let token = WindowToken(pid: 88, windowId: 8801)
        let frame = CGRect(x: 120, y: 140, width: 800, height: 520)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 880, name: "Main", x: 0, y: 0)
        let metadata = makeWorkspaceManagerReplacementMetadata(
            workspaceId: workspaceId,
            title: "Managed Restore",
            frame: frame
        )
        let baseState = ManagedWindowRestoreSnapshot.NiriState(
            nodeId: nil,
            columnIndex: 0,
            tileIndex: 0,
            columnWindowTokens: [token],
            columnSizing: .init(
                width: .fixed(640),
                cachedWidth: 640,
                presetWidthIdx: 1,
                isFullWidth: false,
                savedWidth: .proportion(0.45),
                hasManualSingleWindowWidthOverride: false,
                height: .fixed(720),
                cachedHeight: 720,
                isFullHeight: false,
                savedHeight: .proportion(0.55)
            ),
            windowSizing: .init(
                height: .auto(weight: 1.5),
                savedHeight: .fixed(320),
                windowWidth: .fixed(410),
                sizingMode: .normal
            )
        )
        let changedState = ManagedWindowRestoreSnapshot.NiriState(
            nodeId: nil,
            columnIndex: 1,
            tileIndex: 0,
            columnWindowTokens: [token],
            columnSizing: baseState.columnSizing,
            windowSizing: baseState.windowSizing
        )
        let baseSnapshot = ManagedWindowRestoreSnapshot(
            token: token,
            workspaceId: workspaceId,
            frame: frame,
            topologyProfile: TopologyProfile(monitors: [monitor]),
            niriState: baseState,
            replacementMetadata: metadata
        )
        let changedSnapshot = ManagedWindowRestoreSnapshot(
            token: token,
            workspaceId: workspaceId,
            frame: frame,
            topologyProfile: TopologyProfile(monitors: [monitor]),
            niriState: changedState,
            replacementMetadata: metadata
        )

        #expect(
            baseSnapshot.isSemanticallyEquivalent(
                to: changedSnapshot,
                frameTolerance: frameTolerance
            ) == false
        )
        #expect(
            baseSnapshot.semanticIdentity(
                frameTolerance: frameTolerance
            ) != changedSnapshot.semanticIdentity(
                frameTolerance: frameTolerance
            )
        )
    }

    @Test @MainActor func `managed restore snapshot skips approximate frame-only updates but keeps material state changes`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 360, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let token = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 3601),
            pid: 3601,
            windowId: 3601,
            to: workspaceId
        )
        let frame = CGRect(x: 120, y: 140, width: 800, height: 520)
        let jitteredFrame = frame.offsetBy(dx: 0.2, dy: -0.2)
        let metadata = makeWorkspaceManagerReplacementMetadata(
            workspaceId: workspaceId,
            title: "Managed Restore",
            frame: frame
        )


        #expect(
            manager.setManagedRestoreSnapshot(
                ManagedWindowRestoreSnapshot(
                    token: token,
                    workspaceId: workspaceId,
                    frame: frame,
                    topologyProfile: manager.topologyProfile,
                    niriState: nil,
                    replacementMetadata: metadata
                ),
                for: token
            )
        )

        #expect(
            manager.setManagedRestoreSnapshot(
                ManagedWindowRestoreSnapshot(
                    token: token,
                    workspaceId: workspaceId,
                    frame: jitteredFrame,
                    topologyProfile: manager.topologyProfile,
                    niriState: nil,
                    replacementMetadata: makeWorkspaceManagerReplacementMetadata(
                        workspaceId: workspaceId,
                        title: "Managed Restore",
                        frame: jitteredFrame
                    )
                ),
                for: token
            ) == false
        )

        let resizedState = ManagedWindowRestoreSnapshot.NiriState(
            nodeId: nil,
            columnIndex: 0,
            tileIndex: 0,
            columnWindowTokens: [token],
            columnSizing: .init(
                width: .fixed(640),
                cachedWidth: 640,
                presetWidthIdx: 1,
                isFullWidth: false,
                savedWidth: .proportion(0.45),
                hasManualSingleWindowWidthOverride: true,
                height: .fixed(720),
                cachedHeight: 720,
                isFullHeight: false,
                savedHeight: .proportion(0.55)
            ),
            windowSizing: .init(
                height: .auto(weight: 1.5),
                savedHeight: .fixed(320),
                windowWidth: .fixed(410),
                sizingMode: .normal
            )
        )

        #expect(
            manager.setManagedRestoreSnapshot(
                ManagedWindowRestoreSnapshot(
                    token: token,
                    workspaceId: workspaceId,
                    frame: jitteredFrame,
                    topologyProfile: manager.topologyProfile,
                    niriState: resizedState,
                    replacementMetadata: makeWorkspaceManagerReplacementMetadata(
                        workspaceId: workspaceId,
                        title: "Managed Restore",
                        frame: jitteredFrame
                    )
                ),
                for: token
            )
        )

        let storedSnapshot = manager.managedRestoreSnapshot(for: token)
        #expect(storedSnapshot?.frame == jitteredFrame)
        #expect(storedSnapshot?.niriState == resizedState)
    }

    @Test func `niri state semantic equivalence tolerates animation drift and detects user resizes`() {
        let token = WindowToken(pid: 99, windowId: 9901)
        let frameTolerance: CGFloat = 0.5
        let weightTolerance: CGFloat = 1e-3

        let base = ManagedWindowRestoreSnapshot.NiriState(
            nodeId: nil,
            columnIndex: 3,
            tileIndex: 0,
            columnWindowTokens: [token],
            columnSizing: .init(
                width: .proportion(0.5),
                cachedWidth: 1268.0,
                presetWidthIdx: nil,
                isFullWidth: false,
                savedWidth: nil,
                hasManualSingleWindowWidthOverride: false,
                height: .proportion(1.0),
                cachedHeight: 0.0,
                isFullHeight: false,
                savedHeight: nil
            ),
            windowSizing: .init(
                height: .auto(weight: 1.0),
                savedHeight: nil,
                windowWidth: .auto(weight: 1.0),
                sizingMode: .normal
            )
        )

        // Sub-pixel cachedWidth drift and a 1e-4 weight drift (observed per
        // animation tick) must be reported equivalent to avoid cache-write
        // storms on every CADisplayLink tick.
        let driftedAnimationTick = ManagedWindowRestoreSnapshot.NiriState(
            nodeId: base.nodeId,
            columnIndex: base.columnIndex,
            tileIndex: base.tileIndex,
            columnWindowTokens: base.columnWindowTokens,
            columnSizing: .init(
                width: base.columnSizing.width,
                cachedWidth: 1268.12,
                presetWidthIdx: base.columnSizing.presetWidthIdx,
                isFullWidth: base.columnSizing.isFullWidth,
                savedWidth: base.columnSizing.savedWidth,
                hasManualSingleWindowWidthOverride:
                    base.columnSizing.hasManualSingleWindowWidthOverride,
                height: base.columnSizing.height,
                cachedHeight: base.columnSizing.cachedHeight,
                isFullHeight: base.columnSizing.isFullHeight,
                savedHeight: base.columnSizing.savedHeight
            ),
            windowSizing: .init(
                height: .auto(weight: 1.0003),
                savedHeight: base.windowSizing.savedHeight,
                windowWidth: base.windowSizing.windowWidth,
                sizingMode: base.windowSizing.sizingMode
            )
        )
        #expect(
            base.isSemanticallyEquivalent(
                to: driftedAnimationTick,
                frameTolerance: frameTolerance,
                weightTolerance: weightTolerance
            )
        )

        // A user-initiated resize that pushes the tile weight to 3.0 must be
        // reported as a genuine change so the cache refreshes.
        let userResized = ManagedWindowRestoreSnapshot.NiriState(
            nodeId: base.nodeId,
            columnIndex: base.columnIndex,
            tileIndex: base.tileIndex,
            columnWindowTokens: base.columnWindowTokens,
            columnSizing: base.columnSizing,
            windowSizing: .init(
                height: .auto(weight: 3.0),
                savedHeight: base.windowSizing.savedHeight,
                windowWidth: base.windowSizing.windowWidth,
                sizingMode: base.windowSizing.sizingMode
            )
        )
        #expect(
            !base.isSemanticallyEquivalent(
                to: userResized,
                frameTolerance: frameTolerance,
                weightTolerance: weightTolerance
            )
        )

        // Niri's fullscreen-width toggle flips isFullWidth — must not be
        // masked by the tolerance.
        let fullWidthToggled = ManagedWindowRestoreSnapshot.NiriState(
            nodeId: base.nodeId,
            columnIndex: base.columnIndex,
            tileIndex: base.tileIndex,
            columnWindowTokens: base.columnWindowTokens,
            columnSizing: .init(
                width: base.columnSizing.width,
                cachedWidth: base.columnSizing.cachedWidth,
                presetWidthIdx: base.columnSizing.presetWidthIdx,
                isFullWidth: true,
                savedWidth: base.columnSizing.savedWidth,
                hasManualSingleWindowWidthOverride:
                    base.columnSizing.hasManualSingleWindowWidthOverride,
                height: base.columnSizing.height,
                cachedHeight: base.columnSizing.cachedHeight,
                isFullHeight: base.columnSizing.isFullHeight,
                savedHeight: base.columnSizing.savedHeight
            ),
            windowSizing: base.windowSizing
        )
        #expect(
            !base.isSemanticallyEquivalent(
                to: fullWidthToggled,
                frameTolerance: frameTolerance,
                weightTolerance: weightTolerance
            )
        )

        // Tile re-ordering in the column (tileIndex 0 → 1) is a structural
        // change and must always register even with no drift.
        let reorderedTile = ManagedWindowRestoreSnapshot.NiriState(
            nodeId: base.nodeId,
            columnIndex: base.columnIndex,
            tileIndex: 1,
            columnWindowTokens: base.columnWindowTokens,
            columnSizing: base.columnSizing,
            windowSizing: base.windowSizing
        )
        #expect(
            !base.isSemanticallyEquivalent(
                to: reorderedTile,
                frameTolerance: frameTolerance,
                weightTolerance: weightTolerance
            )
        )

        // nil ↔ non-nil asymmetry stays strict.
        #expect(
            !ManagedWindowRestoreSnapshot.NiriState.isSemanticallyEquivalent(
                nil,
                base,
                frameTolerance: frameTolerance,
                weightTolerance: weightTolerance
            )
        )
        #expect(
            ManagedWindowRestoreSnapshot.NiriState.isSemanticallyEquivalent(
                nil,
                nil,
                frameTolerance: frameTolerance,
                weightTolerance: weightTolerance
            )
        )
    }

    @Test @MainActor func `equal distance remap uses deterministic tie break`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

        let manager = WorkspaceManager(settings: settings)

        let oldLeft = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Old Left", x: 0, y: 0)
        let oldRight = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Old Right", x: 2000, y: 0)
        manager.applyMonitorConfigurationChange([oldLeft, oldRight])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: oldLeft.id))
        #expect(manager.setActiveWorkspace(ws2, on: oldRight.id))

        let newCenter = makeWorkspaceManagerTestMonitor(displayId: 30, name: "New Center", x: 1000, y: 0)
        let newFar = makeWorkspaceManagerTestMonitor(displayId: 40, name: "New Far", x: 3000, y: 0)
        manager.applyMonitorConfigurationChange([newCenter, newFar])

        #expect(manager.activeWorkspace(on: newCenter.id)?.id == ws1)
        #expect(manager.activeWorkspace(on: newFar.id)?.id == ws2)
    }

    @Test @MainActor func `apply monitor configuration change matches restore assignments when monitor is inserted`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .specificDisplay(OutputId(displayId: 10, name: "Center"))),
            ("2", .specificDisplay(OutputId(displayId: 20, name: "Right"))),
            ("3", .specificDisplay(OutputId(displayId: 20, name: "Right")))
        ])

        let manager = WorkspaceManager(settings: settings)
        let oldCenter = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Center", x: 1000, y: 0)
        let oldRight = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Right", x: 3000, y: 0)
        manager.applyMonitorConfigurationChange([oldCenter, oldRight])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true),
              let ws3 = manager.workspaceId(for: "3", createIfMissing: true)
        else {
            Issue.record("Failed to create expected workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: oldCenter.id))
        #expect(manager.setActiveWorkspace(ws2, on: oldRight.id))
        #expect(manager.setActiveWorkspace(ws3, on: oldRight.id))

        let newLeft = makeWorkspaceManagerTestMonitor(displayId: 30, name: "Left", x: 0, y: 0)
        let newCenter = makeWorkspaceManagerTestMonitor(displayId: 40, name: "Replacement Center", x: 1000, y: 0)
        let newRight = makeWorkspaceManagerTestMonitor(displayId: 50, name: "Replacement Right", x: 3000, y: 0)
        let newMonitors = [newLeft, newCenter, newRight]

        let expectedAssignments = resolveWorkspaceRestoreAssignments(
            snapshots: [
                WorkspaceRestoreSnapshot(monitor: .init(monitor: oldCenter), workspaceId: ws1),
                WorkspaceRestoreSnapshot(monitor: .init(monitor: oldRight), workspaceId: ws3)
            ],
            monitors: newMonitors,
            workspaceExists: { $0 == ws1 || $0 == ws3 }
        )

        manager.applyMonitorConfigurationChange(newMonitors)

        #expect(expectedAssignments[newLeft.id] == nil)
        #expect(expectedAssignments[newCenter.id] == ws1)
        #expect(expectedAssignments[newRight.id] == ws3)
        #expect(manager.activeWorkspace(on: newLeft.id) == nil)
        #expect(manager.activeWorkspace(on: newCenter.id)?.id == expectedAssignments[newCenter.id])
        #expect(manager.activeWorkspace(on: newRight.id)?.id == expectedAssignments[newRight.id])
        #expect(manager.workspaces(on: newRight.id).map(\.id) == [ws2, ws3])
    }

    @Test @MainActor func `workspace ids outside configured set are not synthesized`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        #expect(manager.workspaceId(for: "1", createIfMissing: true) != nil)
        #expect(manager.workspaceId(for: "2", createIfMissing: true) == nil)
        #expect(manager.workspaceId(for: "10", createIfMissing: true) == nil)
    }

    @Test @MainActor func `specific display workspace migrates to fallback session and returns when target reappears`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .specificDisplay(OutputId(displayId: 300, name: "Detached")))
        ])

        let manager = WorkspaceManager(settings: settings)
        let main = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Main", x: 0, y: 0)
        let side = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Side", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([main, side])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create expected workspaces")
            return
        }

        #expect(manager.activeWorkspace(on: side.id) == nil)
        #expect(manager.monitorId(for: ws2) == main.id)
        #expect(manager.workspaces(on: main.id).map(\.id) == [ws1, ws2])

        let detached = makeWorkspaceManagerTestMonitor(displayId: 300, name: "Detached", x: 3840, y: 0)
        manager.applyMonitorConfigurationChange([main, side, detached])

        #expect(manager.activeWorkspace(on: detached.id)?.id == ws2)
        #expect(manager.monitorId(for: ws2) == detached.id)

        manager.applyMonitorConfigurationChange([main, side])

        #expect(manager.activeWorkspace(on: main.id)?.id == ws1)
        #expect(manager.activeWorkspace(on: side.id)?.id == ws2)
        #expect(manager.previousWorkspace(on: side.id)?.id == nil)
        #expect(manager.monitorId(for: ws2) == side.id)

        let restoredDetached = makeWorkspaceManagerTestMonitor(displayId: 300, name: "Detached", x: 3840, y: 0)
        manager.applyMonitorConfigurationChange([main, side, restoredDetached])

        #expect(manager.activeWorkspace(on: main.id)?.id == ws1)
        #expect(manager.activeWorkspace(on: side.id) == nil)
        #expect(manager.activeWorkspace(on: restoredDetached.id)?.id == ws2)
        #expect(manager.monitorId(for: ws2) == restoredDetached.id)
    }

    @Test @MainActor func `specific display assignments are rebound before live projection`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .specificDisplay(OutputId(displayId: 300, name: "Detached")))
        ])

        let manager = WorkspaceManager(settings: settings)
        let main = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Main", x: 0, y: 0)
        let reboundDetached = makeWorkspaceManagerTestMonitor(displayId: 400, name: "Detached", x: 1920, y: 0)

        manager.applyMonitorConfigurationChange([main, reboundDetached])

        guard let ws2 = manager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Failed to create specific-display workspace")
            return
        }

        #expect(
            settings.workspaceConfigurations[1].monitorAssignment
                == .specificDisplay(OutputId(displayId: reboundDetached.displayId, name: reboundDetached.name))
        )
        #expect(manager.monitorId(for: ws2) == reboundDetached.id)
    }

    @Test @MainActor func `unassigned third monitor stays stable across active workspace reads`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

        let manager = WorkspaceManager(settings: settings)
        var sessionChangeCount = 0
        manager.onSessionStateChanged = {
            sessionChangeCount += 1
        }

        let main = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Main", x: 0, y: 0)
        let secondary = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Secondary", x: 1920, y: 0)
        let third = makeWorkspaceManagerTestMonitor(displayId: 30, name: "Third", x: 3840, y: 0)
        manager.applyMonitorConfigurationChange([main, secondary, third])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create expected workspaces")
            return
        }

        #expect(manager.activeWorkspace(on: main.id)?.id == ws1)
        #expect(manager.activeWorkspace(on: secondary.id)?.id == ws2)

        sessionChangeCount = 0

        #expect(manager.activeWorkspace(on: third.id) == nil)
        #expect(manager.activeWorkspaceOrFirst(on: third.id) == nil)
        #expect(manager.activeWorkspace(on: third.id) == nil)
        #expect(manager.currentActiveWorkspace(on: third.id) == nil)
        #expect(manager.workspaces(on: third.id).isEmpty)
        #expect(sessionChangeCount == 0)
    }

    @Test @MainActor func `assigned monitor repairs missing visible session from kernel resolved active workspace`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main)
        ])
        let manager = WorkspaceManager(settings: settings)

        let main = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([main])

        settings.workspaceConfigurations = []
        manager.applySettings()

        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main)
        ])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create expected workspace")
            return
        }

        var sessionChangeCount = 0
        manager.onSessionStateChanged = {
            sessionChangeCount += 1
        }

        #expect(manager.activeWorkspace(on: main.id) == nil)
        #expect(manager.activeWorkspaceOrFirst(on: main.id)?.id == ws1)
        #expect(manager.activeWorkspace(on: main.id)?.id == ws1)
        #expect(manager.monitorId(for: ws1) == main.id)
        #expect(sessionChangeCount == 1)
    }

    @Test @MainActor func `secondary workspaces collapse onto remaining monitor and return when secondary reappears`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create expected workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: left.id))
        #expect(manager.setActiveWorkspace(ws2, on: right.id))

        manager.applyMonitorConfigurationChange([left])

        #expect(manager.activeWorkspace(on: left.id)?.id == ws2)
        #expect(manager.previousWorkspace(on: left.id)?.id == ws1)
        #expect(manager.monitorId(for: ws2) == left.id)
        #expect(manager.workspaces(on: left.id).map(\.id) == [ws1, ws2])

        let restoredRight = makeWorkspaceManagerTestMonitor(displayId: 30, name: "Restored", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, restoredRight])

        #expect(manager.activeWorkspace(on: left.id)?.id == ws1)
        #expect(manager.activeWorkspace(on: restoredRight.id)?.id == ws2)
        #expect(manager.monitorId(for: ws2) == restoredRight.id)
    }

    @Test @MainActor func `set active workspace tracks interaction monitor ownership`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: left.id))
        #expect(manager.interactionMonitorId == left.id)

        #expect(manager.setActiveWorkspace(ws2, on: right.id))
        #expect(manager.interactionMonitorId == right.id)
        #expect(manager.previousInteractionMonitorId == left.id)
        #expect(manager.activeWorkspace(on: left.id)?.id == ws1)
        #expect(manager.activeWorkspace(on: right.id)?.id == ws2)
    }

    @Test @MainActor func `failed topology reconcile rolls back transient mouse warp rebinds`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Left", x: 0, y: 0)
        let replacement = makeWorkspaceManagerTestMonitor(displayId: 11, name: "Left", x: 0, y: 0)

        manager.applyMonitorConfigurationChange([left])

        let persistedLeft = OutputId(from: left)
        settings.mouseWarpMonitorOrder = [persistedLeft]

        WorkspaceManager.forceTopologyReconcileFailureForTests = true
        defer { WorkspaceManager.forceTopologyReconcileFailureForTests = false }
        manager.applyMonitorConfigurationChange([replacement])

        #expect(settings.mouseWarpMonitorOrder == [persistedLeft])
        #expect(manager.monitors == [left])
    }

    @Test @MainActor func `move workspace to foreign monitor is rejected when home monitor differs`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: left.id))
        #expect(manager.setActiveWorkspace(ws2, on: right.id))

        #expect(manager.moveWorkspaceToMonitor(ws1, to: right.id) == false)
        #expect(manager.interactionMonitorId == right.id)
        #expect(manager.previousInteractionMonitorId == left.id)
        #expect(manager.activeWorkspace(on: left.id)?.id == ws1)
        #expect(manager.activeWorkspace(on: right.id)?.id == ws2)
        #expect(manager.previousWorkspace(on: right.id)?.id == nil)
    }

    @Test @MainActor func `begin managed focus request only mutates pending state`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: left.id))
        #expect(manager.setActiveWorkspace(ws2, on: right.id))
        #expect(manager.setInteractionMonitor(left.id))
        #expect(manager.enterNonManagedFocus(appFullscreen: true))

        let handle = addWorkspaceManagerTestHandle(manager: manager, windowId: 2101, workspaceId: ws2)

        #expect(manager.beginManagedFocusRequest(handle, in: ws2, onMonitor: right.id))
        #expect(manager.pendingFocusedHandle == handle)
        #expect(manager.pendingFocusedWorkspaceId == ws2)
        #expect(manager.pendingFocusedMonitorId == right.id)
        #expect(manager.focusedHandle == nil)
        #expect(manager.lastFocusedHandle(in: ws2) == handle)
        #expect(manager.interactionMonitorId == left.id)
        #expect(manager.isNonManagedFocusActive == true)
        #expect(manager.isAppFullscreenActive == true)
    }

    @Test @MainActor func `confirm managed focus atomically commits owner state`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: left.id))
        #expect(manager.setActiveWorkspace(ws2, on: right.id))
        #expect(manager.setInteractionMonitor(left.id))
        #expect(manager.enterNonManagedFocus(appFullscreen: true))

        let handle = addWorkspaceManagerTestHandle(manager: manager, windowId: 2111, workspaceId: ws2)

        #expect(manager.beginManagedFocusRequest(handle, in: ws2, onMonitor: right.id))
        #expect(manager.confirmManagedFocus(
            handle,
            in: ws2,
            onMonitor: right.id,
            appFullscreen: false,
            activateWorkspaceOnMonitor: true
        ))

        #expect(manager.pendingFocusedHandle == nil)
        #expect(manager.focusedHandle == handle)
        #expect(manager.lastFocusedHandle(in: ws2) == handle)
        #expect(manager.interactionMonitorId == right.id)
        #expect(manager.previousInteractionMonitorId == left.id)
        #expect(manager.isNonManagedFocusActive == false)
        #expect(manager.isAppFullscreenActive == false)
    }

    @Test @MainActor func `confirm managed focus clears stale pending request for different window`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        #expect(manager.setActiveWorkspace(workspaceId, on: monitor.id))

        let confirmedHandle = addWorkspaceManagerTestHandle(manager: manager, windowId: 2121, workspaceId: workspaceId)
        let pendingHandle = addWorkspaceManagerTestHandle(manager: manager, windowId: 2122, workspaceId: workspaceId)

        #expect(manager.beginManagedFocusRequest(pendingHandle, in: workspaceId, onMonitor: monitor.id))
        #expect(manager.confirmManagedFocus(
            confirmedHandle,
            in: workspaceId,
            onMonitor: monitor.id,
            appFullscreen: false,
            activateWorkspaceOnMonitor: true
        ))

        #expect(manager.pendingFocusedHandle == nil)
        #expect(manager.focusedHandle == confirmedHandle)
        #expect(manager.lastFocusedHandle(in: workspaceId) == confirmedHandle)
        #expect(manager.preferredFocusHandle(in: workspaceId) == confirmedHandle)
    }

    @Test @MainActor func `stable token focus bridge reuses handle across reupsert`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let token1 = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2191),
            pid: getpid(),
            windowId: 2191,
            to: workspaceId
        )
        guard let handle1 = manager.handle(for: token1) else {
            Issue.record("Missing initial bridge handle")
            return
        }
        _ = manager.setManagedFocus(token1, in: workspaceId, onMonitor: monitor.id)

        let token2 = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2191),
            pid: getpid(),
            windowId: 2191,
            to: workspaceId
        )
        guard let handle2 = manager.handle(for: token2) else {
            Issue.record("Missing refreshed bridge handle")
            return
        }

        #expect(token1 == token2)
        #expect(handle1 === handle2)
        #expect(manager.focusedToken == token1)
        #expect(manager.focusedHandle === handle1)
        #expect(manager.lastFocusedToken(in: workspaceId) == token1)
        #expect(manager.lastFocusedHandle(in: workspaceId) === handle1)
    }

    @Test @MainActor func `rekey window preserves handle and focus state`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 11, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let handle = addWorkspaceManagerTestHandle(
            manager: manager,
            windowId: 2192,
            pid: 2192,
            workspaceId: workspaceId
        )
        let oldToken = handle.id
        let hiddenState = WindowModel.HiddenState(
            proportionalPosition: CGPoint(x: 0.25, y: 0.75),
            referenceMonitorId: monitor.id,
            workspaceInactive: true,
            offscreenSide: .left
        )
        let floatingState = WindowModel.FloatingState(
            lastFrame: CGRect(x: 100, y: 120, width: 500, height: 380),
            normalizedOrigin: CGPoint(x: 0.2, y: 0.3),
            referenceMonitorId: monitor.id,
            restoreToFloating: true
        )
        let constraints = WindowSizeConstraints(
            minSize: CGSize(width: 320, height: 240),
            maxSize: CGSize(width: 960, height: 720),
            isFixed: false
        )

        _ = manager.setManagedFocus(handle, in: workspaceId, onMonitor: monitor.id)
        _ = manager.beginManagedFocusRequest(handle, in: workspaceId, onMonitor: monitor.id)
        _ = manager.rememberFocus(handle, in: workspaceId)
        manager.setHiddenState(hiddenState, for: handle)
        manager.setFloatingState(floatingState, for: handle.id)
        manager.setManualLayoutOverride(.forceFloat, for: handle.id)
        manager.setLayoutReason(.macosHiddenApp, for: handle)
        manager.setCachedConstraints(constraints, for: handle.id)

        let newToken = WindowToken(pid: oldToken.pid, windowId: 2193)
        let newAXRef = makeWorkspaceManagerTestWindow(windowId: 2193)
        guard let rekeyedEntry = manager.rekeyWindow(from: oldToken, to: newToken, newAXRef: newAXRef) else {
            Issue.record("Failed to rekey window")
            return
        }

        #expect(rekeyedEntry.handle === handle)
        #expect(handle.id == newToken)
        #expect(rekeyedEntry.token == newToken)
        #expect(rekeyedEntry.axRef.windowId == 2193)
        #expect(rekeyedEntry.workspaceId == workspaceId)
        #expect(manager.entry(for: oldToken) == nil)
        #expect(manager.entry(for: newToken) === rekeyedEntry)
        #expect(manager.focusedHandle === handle)
        #expect(manager.focusedToken == newToken)
        #expect(manager.pendingFocusedHandle === handle)
        #expect(manager.pendingFocusedToken == newToken)
        #expect(manager.lastFocusedHandle(in: workspaceId) === handle)

        guard let rekeyedHiddenState = manager.hiddenState(for: newToken) else {
            Issue.record("Missing hidden state after rekey")
            return
        }
        #expect(rekeyedHiddenState.proportionalPosition == hiddenState.proportionalPosition)
        #expect(rekeyedHiddenState.referenceMonitorId == hiddenState.referenceMonitorId)
        #expect(rekeyedHiddenState.workspaceInactive == hiddenState.workspaceInactive)
        #expect(rekeyedHiddenState.offscreenSide == hiddenState.offscreenSide)
        #expect(manager.floatingState(for: newToken) == floatingState)
        #expect(manager.manualLayoutOverride(for: newToken) == .forceFloat)
        #expect(manager.layoutReason(for: newToken) == .macosHiddenApp)
        #expect(manager.cachedConstraints(for: newToken) == nil)
    }

    @Test @MainActor func `floating focus does not poison tiled preferred focus`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 12, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let tiledToken = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2201),
            pid: 2201,
            windowId: 2201,
            to: workspaceId
        )
        let floatingToken = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2202),
            pid: 2202,
            windowId: 2202,
            to: workspaceId,
            mode: .floating
        )

        _ = manager.setManagedFocus(tiledToken, in: workspaceId, onMonitor: monitor.id)
        _ = manager.setManagedFocus(floatingToken, in: workspaceId, onMonitor: monitor.id)

        #expect(manager.lastFocusedToken(in: workspaceId) == tiledToken)
        #expect(manager.lastFloatingFocusedToken(in: workspaceId) == floatingToken)
        #expect(manager.preferredFocusToken(in: workspaceId) == tiledToken)
        #expect(manager.resolveWorkspaceFocusToken(in: workspaceId) == tiledToken)
    }

    @Test @MainActor func `preferred focus allows remembered workspace inactive window`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 120, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        _ = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2210),
            pid: 2210,
            windowId: 2210,
            to: workspaceId
        )
        let rememberedToken = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2211),
            pid: 2211,
            windowId: 2211,
            to: workspaceId
        )
        _ = manager.rememberFocus(rememberedToken, in: workspaceId)
        manager.setHiddenState(
            .init(
                proportionalPosition: CGPoint(x: 0.1, y: 0.9),
                referenceMonitorId: monitor.id,
                reason: .workspaceInactive
            ),
            for: rememberedToken
        )

        #expect(manager.preferredFocusToken(in: workspaceId) == rememberedToken)
        #expect(manager.resolveWorkspaceFocusToken(in: workspaceId) == rememberedToken)
    }

    @Test @MainActor func `preferred focus falls back to workspace inactive tiled window`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 121, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let token = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2212),
            pid: 2212,
            windowId: 2212,
            to: workspaceId
        )
        manager.setHiddenState(
            .init(
                proportionalPosition: CGPoint(x: 0.2, y: 0.8),
                referenceMonitorId: monitor.id,
                reason: .workspaceInactive
            ),
            for: token
        )

        #expect(manager.preferredFocusToken(in: workspaceId) == token)
    }

    @Test @MainActor func `resolve workspace focus falls back to floating when no tiled window exists`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 13, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let floatingToken = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2203),
            pid: 2203,
            windowId: 2203,
            to: workspaceId,
            mode: .floating
        )
        _ = manager.setManagedFocus(floatingToken, in: workspaceId, onMonitor: monitor.id)

        #expect(manager.preferredFocusToken(in: workspaceId) == nil)
        #expect(manager.resolveWorkspaceFocusToken(in: workspaceId) == floatingToken)
    }

    @Test @MainActor func `resolve workspace focus falls back to workspace inactive floating window`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 122, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let floatingToken = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2213),
            pid: 2213,
            windowId: 2213,
            to: workspaceId,
            mode: .floating
        )
        manager.setHiddenState(
            .init(
                proportionalPosition: CGPoint(x: 0.3, y: 0.7),
                referenceMonitorId: monitor.id,
                reason: .workspaceInactive
            ),
            for: floatingToken
        )

        #expect(manager.preferredFocusToken(in: workspaceId) == nil)
        #expect(manager.resolveWorkspaceFocusToken(in: workspaceId) == floatingToken)
    }

    @Test @MainActor func `resolve and set workspace focus clears hidden confirmed focus without fallback`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 123, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let handle = addWorkspaceManagerTestHandle(
            manager: manager,
            windowId: 2214,
            pid: 2214,
            workspaceId: workspaceId
        )

        _ = manager.setManagedFocus(handle, in: workspaceId, onMonitor: monitor.id)
        manager.setHiddenState(
            .init(
                proportionalPosition: CGPoint(x: 0.4, y: 0.6),
                referenceMonitorId: monitor.id,
                reason: .layoutTransient(.left)
            ),
            for: handle
        )

        #expect(manager.resolveWorkspaceFocus(in: workspaceId) == nil)
        #expect(manager.resolveAndSetWorkspaceFocus(in: workspaceId, onMonitor: monitor.id) == nil)
        #expect(manager.focusedToken == nil)
        #expect(manager.focusedHandle == nil)
    }

    @Test @MainActor func `resolved floating frame uses normalized origin on monitor change`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 14, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 15, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let token = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2204),
            pid: 2204,
            windowId: 2204,
            to: workspaceId,
            mode: .floating
        )
        manager.setFloatingState(
            .init(
                lastFrame: CGRect(x: 200, y: 150, width: 400, height: 300),
                normalizedOrigin: CGPoint(x: 0.75, y: 0.5),
                referenceMonitorId: left.id,
                restoreToFloating: true
            ),
            for: token
        )

        let resolved = manager.resolvedFloatingFrame(for: token, preferredMonitor: right)

        #expect(resolved == CGRect(x: 3060, y: 390, width: 400, height: 300))
    }

    @Test @MainActor func `resolve workspace focus ignores dead remembered handles`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let survivor = addWorkspaceManagerTestHandle(
            manager: manager,
            windowId: 2201,
            pid: 2201,
            workspaceId: workspaceId
        )
        let removed = addWorkspaceManagerTestHandle(
            manager: manager,
            windowId: 2202,
            pid: 2202,
            workspaceId: workspaceId
        )

        _ = manager.setManagedFocus(removed, in: workspaceId, onMonitor: monitor.id)
        _ = manager.removeWindow(pid: 2202, windowId: 2202)
        _ = manager.rememberFocus(removed, in: workspaceId)

        #expect(manager.resolveWorkspaceFocus(in: workspaceId) == survivor)
        #expect(manager.resolveAndSetWorkspaceFocus(in: workspaceId, onMonitor: monitor.id) == survivor)
        #expect(manager.focusedHandle == nil)
        #expect(manager.lastFocusedHandle(in: workspaceId) == survivor)
    }

    @Test @MainActor func `remove missing clears dead focus memory and recovery selects survivor after consecutive misses`(
    ) {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 30, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let survivor = addWorkspaceManagerTestHandle(
            manager: manager,
            windowId: 2301,
            pid: 2301,
            workspaceId: workspaceId
        )
        let removed = addWorkspaceManagerTestHandle(
            manager: manager,
            windowId: 2302,
            pid: 2302,
            workspaceId: workspaceId
        )

        _ = manager.setManagedFocus(removed, in: workspaceId, onMonitor: monitor.id)
        _ = manager.beginManagedFocusRequest(removed, in: workspaceId, onMonitor: monitor.id)

        manager.removeMissing(
            keys: Set([.init(pid: 2301, windowId: 2301)]),
            requiredConsecutiveMisses: 2
        )
        #expect(manager.entry(for: removed) != nil)
        #expect(manager.focusedHandle == removed)
        #expect(manager.pendingFocusedToken == removed.id)

        manager.removeMissing(
            keys: Set([.init(pid: 2301, windowId: 2301)]),
            requiredConsecutiveMisses: 2
        )

        #expect(manager.entry(for: removed) == nil)
        #expect(manager.focusedToken == nil)
        #expect(manager.pendingFocusedToken == nil)
        #expect(manager.focusedHandle == nil)
        #expect(manager.lastFocusedHandle(in: workspaceId) == nil)
        #expect(manager.resolveAndSetWorkspaceFocus(in: workspaceId, onMonitor: monitor.id) == survivor)
        #expect(manager.focusedHandle == nil)
        #expect(manager.lastFocusedHandle(in: workspaceId) == survivor)
    }

    @Test @MainActor func `remove missing does not evict native fullscreen suspended window`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 31, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let suspended = addWorkspaceManagerTestHandle(
            manager: manager,
            windowId: 2311,
            pid: 2311,
            workspaceId: workspaceId
        )
        manager.setLayoutReason(.nativeFullscreen, for: suspended)

        manager.removeMissing(keys: [], requiredConsecutiveMisses: 2)
        manager.removeMissing(keys: [], requiredConsecutiveMisses: 2)

        #expect(manager.entry(for: suspended) != nil)
        #expect(manager.layoutReason(for: suspended) == .nativeFullscreen)
    }

    @Test @MainActor func `native fullscreen restore only clears target record when same pid has multiple suspended windows`(
    ) {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create workspaces")
            return
        }

        let pid: pid_t = 4601
        let token1 = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2321),
            pid: pid,
            windowId: 2321,
            to: ws1
        )
        let token2 = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2322),
            pid: pid,
            windowId: 2322,
            to: ws2
        )

        _ = manager.requestNativeFullscreenEnter(token1, in: ws1)
        _ = manager.markNativeFullscreenSuspended(token1)
        _ = manager.requestNativeFullscreenEnter(token2, in: ws2)
        _ = manager.markNativeFullscreenSuspended(token2)
        _ = manager.requestNativeFullscreenExit(token2, initiatedByCommand: true)
        _ = manager.restoreNativeFullscreenRecord(for: token2)

        #expect(manager.nativeFullscreenRecord(for: token2) == nil)
        #expect(manager.layoutReason(for: token2) == .standard)
        #expect(manager.layoutReason(for: token1) == .nativeFullscreen)
        #expect(manager.nativeFullscreenCommandTarget(frontmostToken: token1) == token1)
    }

    @Test @MainActor func `native fullscreen unavailable replacement matches exact metadata when same pid shares workspace`(
    ) {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main)
        ])

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 33, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let pid: pid_t = 4701
        let firstToken = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2341),
            pid: pid,
            windowId: 2341,
            to: workspaceId
        )
        let secondToken = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2342),
            pid: pid,
            windowId: 2342,
            to: workspaceId
        )
        let replacementToken = WindowToken(pid: pid, windowId: 2343)
        let firstFrame = CGRect(x: 10, y: 20, width: 540, height: 900)
        let secondFrame = CGRect(x: 570, y: 80, width: 720, height: 760)
        let firstMetadata = makeWorkspaceManagerReplacementMetadata(
            bundleId: "com.example.same-app",
            workspaceId: workspaceId,
            title: "Alpha",
            frame: firstFrame
        )
        let secondMetadata = makeWorkspaceManagerReplacementMetadata(
            bundleId: "com.example.same-app",
            workspaceId: workspaceId,
            title: "Beta",
            frame: secondFrame
        )
        let replacementMetadata = makeWorkspaceManagerReplacementMetadata(
            bundleId: "com.example.same-app",
            workspaceId: workspaceId,
            title: "Beta",
            frame: secondFrame.offsetBy(dx: 8, dy: -6)
        )
        let mismatchedMetadata = makeWorkspaceManagerReplacementMetadata(
            bundleId: "com.example.same-app",
            workspaceId: workspaceId,
            title: "Gamma",
            frame: secondFrame
        )

        _ = manager.setManagedRestoreSnapshot(
            ManagedWindowRestoreSnapshot(
                token: firstToken,
                workspaceId: workspaceId,
                frame: firstFrame,
                topologyProfile: manager.topologyProfile,
                niriState: nil,
                replacementMetadata: firstMetadata
            ),
            for: firstToken
        )
        _ = manager.setManagedRestoreSnapshot(
            ManagedWindowRestoreSnapshot(
                token: secondToken,
                workspaceId: workspaceId,
                frame: secondFrame,
                topologyProfile: manager.topologyProfile,
                niriState: nil,
                replacementMetadata: secondMetadata
            ),
            for: secondToken
        )

        _ = manager.requestNativeFullscreenEnter(firstToken, in: workspaceId)
        _ = manager.markNativeFullscreenSuspended(firstToken)
        _ = manager.markNativeFullscreenTemporarilyUnavailable(firstToken)
        _ = manager.requestNativeFullscreenEnter(secondToken, in: workspaceId)
        _ = manager.markNativeFullscreenSuspended(secondToken)
        _ = manager.markNativeFullscreenTemporarilyUnavailable(secondToken)

        switch manager.nativeFullscreenUnavailableCandidate(
            for: replacementToken,
            activeWorkspaceId: workspaceId,
            replacementMetadata: nil
        ) {
        case .ambiguous:
            break
        case let .matched(record):
            Issue.record("Expected nil metadata to remain ambiguous, matched \(record.currentToken)")
        case .none:
            Issue.record("Expected nil metadata to see the pending same-app records")
        }

        switch manager.nativeFullscreenUnavailableCandidate(
            for: replacementToken,
            activeWorkspaceId: workspaceId,
            replacementMetadata: mismatchedMetadata
        ) {
        case .none:
            break
        case let .matched(record):
            Issue.record("Expected mismatched metadata to fail closed, matched \(record.currentToken)")
        case .ambiguous:
            Issue.record("Expected mismatched metadata to fail closed, not stay ambiguous")
        }

        let match = manager.nativeFullscreenUnavailableCandidate(
            for: replacementToken,
            activeWorkspaceId: workspaceId,
            replacementMetadata: replacementMetadata
        )
        guard case let .matched(matchedRecord) = match else {
            Issue.record("Expected replacement metadata to match the exact second window")
            return
        }
        #expect(matchedRecord.originalToken == secondToken)
        #expect(matchedRecord.restoreSnapshot?.frame == secondFrame)

        let replacementWindow = makeWorkspaceManagerTestWindow(windowId: 2343)
        _ = manager.rekeyWindow(
            from: secondToken,
            to: replacementToken,
            newAXRef: replacementWindow,
            managedReplacementMetadata: replacementMetadata
        )
        _ = manager.requestNativeFullscreenExit(replacementToken, initiatedByCommand: true)
        guard let restoringRecord = manager.beginNativeFullscreenRestore(for: replacementToken) else {
            Issue.record("Expected replacement token to begin exact restore")
            return
        }

        #expect(restoringRecord.originalToken == secondToken)
        #expect(restoringRecord.currentToken == replacementToken)
        #expect(restoringRecord.restoreSnapshot?.frame == secondFrame)
        #expect(manager.managedRestoreSnapshot(for: replacementToken)?.frame == secondFrame)
        #expect(manager.nativeFullscreenRecord(for: firstToken)?.currentToken == firstToken)
        #expect(manager.nativeFullscreenRecord(for: firstToken)?.restoreSnapshot?.frame == firstFrame)
    }

    @Test @MainActor func `native fullscreen unavailable replacement matches exact metadata across workspace mismatch`(
    ) {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .main)
        ])

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 34, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceOne = manager.workspaceId(for: "1", createIfMissing: true),
              let workspaceTwo = manager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create workspaces")
            return
        }

        let pid: pid_t = 4711
        let firstToken = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2351),
            pid: pid,
            windowId: 2351,
            to: workspaceOne
        )
        let secondToken = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2352),
            pid: pid,
            windowId: 2352,
            to: workspaceTwo
        )
        let replacementToken = WindowToken(pid: pid, windowId: 2353)
        let firstFrame = CGRect(x: 10, y: 20, width: 540, height: 900)
        let secondFrame = CGRect(x: 570, y: 80, width: 720, height: 760)
        let firstMetadata = makeWorkspaceManagerReplacementMetadata(
            bundleId: "com.example.same-app",
            workspaceId: workspaceOne,
            title: "Workspace One",
            frame: firstFrame
        )
        let secondMetadata = makeWorkspaceManagerReplacementMetadata(
            bundleId: "com.example.same-app",
            workspaceId: workspaceTwo,
            title: "Workspace Two",
            frame: secondFrame
        )
        let replacementMetadata = makeWorkspaceManagerReplacementMetadata(
            bundleId: "com.example.same-app",
            workspaceId: workspaceOne,
            title: "Workspace Two",
            frame: secondFrame.offsetBy(dx: 6, dy: -4)
        )

        _ = manager.setManagedRestoreSnapshot(
            ManagedWindowRestoreSnapshot(
                token: firstToken,
                workspaceId: workspaceOne,
                frame: firstFrame,
                topologyProfile: manager.topologyProfile,
                niriState: nil,
                replacementMetadata: firstMetadata
            ),
            for: firstToken
        )
        _ = manager.setManagedRestoreSnapshot(
            ManagedWindowRestoreSnapshot(
                token: secondToken,
                workspaceId: workspaceTwo,
                frame: secondFrame,
                topologyProfile: manager.topologyProfile,
                niriState: nil,
                replacementMetadata: secondMetadata
            ),
            for: secondToken
        )

        _ = manager.requestNativeFullscreenEnter(firstToken, in: workspaceOne)
        _ = manager.markNativeFullscreenSuspended(firstToken)
        _ = manager.markNativeFullscreenTemporarilyUnavailable(firstToken)
        _ = manager.requestNativeFullscreenEnter(secondToken, in: workspaceTwo)
        _ = manager.markNativeFullscreenSuspended(secondToken)
        _ = manager.markNativeFullscreenTemporarilyUnavailable(secondToken)

        let match = manager.nativeFullscreenUnavailableCandidate(
            for: replacementToken,
            activeWorkspaceId: workspaceOne,
            replacementMetadata: replacementMetadata
        )
        guard case let .matched(matchedRecord) = match else {
            Issue.record("Expected replacement metadata to match record-owned workspace despite active workspace")
            return
        }

        #expect(matchedRecord.originalToken == secondToken)
        #expect(matchedRecord.workspaceId == workspaceTwo)
        #expect(matchedRecord.restoreSnapshot?.frame == secondFrame)
    }

    @Test @MainActor func `native fullscreen unavailable single candidate matches despite volatile metadata`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .main)
        ])

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 35, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceOne = manager.workspaceId(for: "1", createIfMissing: true),
              let workspaceTwo = manager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create workspaces")
            return
        }

        let pid: pid_t = 4721
        let originalToken = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2361),
            pid: pid,
            windowId: 2361,
            to: workspaceTwo
        )
        let replacementToken = WindowToken(pid: pid, windowId: 2362)
        let originalFrame = CGRect(x: 120, y: 160, width: 700, height: 680)
        let capturedMetadata = makeWorkspaceManagerReplacementMetadata(
            bundleId: "com.example.same-app",
            workspaceId: workspaceTwo,
            title: "Captured Title",
            frame: originalFrame
        )
        let volatileReplacementMetadata = makeWorkspaceManagerReplacementMetadata(
            bundleId: "com.example.same-app",
            workspaceId: workspaceOne,
            title: "Transient Native Fullscreen Title",
            frame: CGRect(x: 900, y: 40, width: 300, height: 240)
        )

        _ = manager.setManagedRestoreSnapshot(
            ManagedWindowRestoreSnapshot(
                token: originalToken,
                workspaceId: workspaceTwo,
                frame: originalFrame,
                topologyProfile: manager.topologyProfile,
                niriState: nil,
                replacementMetadata: capturedMetadata
            ),
            for: originalToken
        )
        _ = manager.requestNativeFullscreenEnter(originalToken, in: workspaceTwo)
        _ = manager.markNativeFullscreenSuspended(originalToken)
        _ = manager.markNativeFullscreenTemporarilyUnavailable(originalToken)

        let match = manager.nativeFullscreenUnavailableCandidate(
            for: replacementToken,
            activeWorkspaceId: workspaceOne,
            replacementMetadata: volatileReplacementMetadata
        )
        guard case let .matched(matchedRecord) = match else {
            Issue.record("Expected the single unavailable same-pid record to match volatile replacement metadata")
            return
        }

        #expect(matchedRecord.originalToken == originalToken)
        #expect(matchedRecord.workspaceId == workspaceTwo)
        #expect(matchedRecord.restoreSnapshot?.frame == originalFrame)
    }

    @Test @MainActor func `stale temporarily unavailable native fullscreen cleanup waits for timeout and app termination still clears immediately`(
    ) {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main)
        ])

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 32, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let firstToken = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2331),
            pid: 2331,
            windowId: 2331,
            to: workspaceId
        )
        _ = manager.requestNativeFullscreenEnter(firstToken, in: workspaceId)
        _ = manager.markNativeFullscreenSuspended(firstToken)
        _ = manager.markNativeFullscreenTemporarilyUnavailable(
            firstToken,
            now: Date(timeIntervalSince1970: 100)
        )

        let earlyRemoved = manager.expireStaleTemporarilyUnavailableNativeFullscreenRecords(
            now: Date(timeIntervalSince1970: 114),
            staleInterval: 15
        )
        #expect(earlyRemoved.isEmpty)
        #expect(manager.entry(for: firstToken) != nil)
        #expect(manager.nativeFullscreenRecord(for: firstToken) != nil)

        let lateRemoved = manager.expireStaleTemporarilyUnavailableNativeFullscreenRecords(
            now: Date(timeIntervalSince1970: 116),
            staleInterval: 15
        )
        #expect(lateRemoved.count == 1)
        #expect(manager.entry(for: firstToken) == nil)
        #expect(manager.nativeFullscreenRecord(for: firstToken) == nil)

        let secondPid: pid_t = 2332
        let secondToken = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2332),
            pid: secondPid,
            windowId: 2332,
            to: workspaceId
        )
        _ = manager.requestNativeFullscreenEnter(secondToken, in: workspaceId)
        _ = manager.markNativeFullscreenSuspended(secondToken)
        _ = manager.markNativeFullscreenTemporarilyUnavailable(
            secondToken,
            now: Date(timeIntervalSince1970: 200)
        )

        let affectedWorkspaces = manager.removeWindowsForApp(pid: secondPid)
        #expect(affectedWorkspaces == Set([workspaceId]))
        #expect(manager.entry(for: secondToken) == nil)
        #expect(manager.nativeFullscreenRecord(for: secondToken) == nil)
    }

    @Test @MainActor func `monitor reconnect prefers focused workspace monitor for interaction state`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: left.id))
        #expect(manager.setActiveWorkspace(ws2, on: right.id))
        #expect(manager.setInteractionMonitor(left.id))

        let handle = addWorkspaceManagerTestHandle(manager: manager, windowId: 2401, workspaceId: ws2)
        #expect(manager.setManagedFocus(handle, in: ws2, onMonitor: right.id))

        let replacement = makeWorkspaceManagerTestMonitor(displayId: 30, name: "Replacement", x: -1920, y: 0)
        manager.applyMonitorConfigurationChange([replacement, right])

        #expect(manager.interactionMonitorId == right.id)
        #expect(manager.focusedHandle == handle)
    }

    @Test @MainActor func `remove windows for app clears focused and remembered handles`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create workspaces")
            return
        }

        let pid: pid_t = 3303
        let handle1 = addWorkspaceManagerTestHandle(manager: manager, windowId: 3301, pid: pid, workspaceId: ws1)
        let handle2 = addWorkspaceManagerTestHandle(manager: manager, windowId: 3302, pid: pid, workspaceId: ws2)

        _ = manager.rememberFocus(handle1, in: ws1)
        _ = manager.setManagedFocus(handle2, in: ws2, onMonitor: right.id)

        let affected = manager.removeWindowsForApp(pid: pid)

        #expect(affected == Set([ws1, ws2]))
        #expect(manager.entries(forPid: pid).isEmpty)
        #expect(manager.focusedHandle == nil)
        #expect(manager.lastFocusedHandle(in: ws1) == nil)
        #expect(manager.lastFocusedHandle(in: ws2) == nil)
        #expect(manager.resolveWorkspaceFocus(in: ws1) == nil)
        #expect(manager.resolveWorkspaceFocus(in: ws2) == nil)
    }

    @Test @MainActor func `swap workspaces across home monitors is rejected`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: left.id))
        #expect(manager.setActiveWorkspace(ws2, on: right.id))
        #expect(manager.swapWorkspaces(ws1, on: left.id, with: ws2, on: right.id) == false)
        #expect(manager.activeWorkspace(on: left.id)?.id == ws1)
        #expect(manager.previousWorkspace(on: left.id)?.id == nil)
        #expect(manager.activeWorkspace(on: right.id)?.id == ws2)
        #expect(manager.previousWorkspace(on: right.id)?.id == nil)
        #expect(manager.monitorId(for: ws1) == left.id)
        #expect(manager.monitorId(for: ws2) == right.id)
    }

    @Test @MainActor func `viewport state persists across workspace transitions`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create workspaces")
            return
        }

        var viewport = manager.niriViewportState(for: ws1)
        viewport.activeColumnIndex = 2
        manager.updateNiriViewportState(viewport, for: ws1)

        #expect(manager.setActiveWorkspace(ws1, on: monitor.id))
        #expect(manager.setActiveWorkspace(ws2, on: monitor.id))
        #expect(manager.setActiveWorkspace(ws1, on: monitor.id))
        #expect(manager.niriViewportState(for: ws1).activeColumnIndex == 2)
    }

    @Test @MainActor func `apply monitor configuration change keeps forced workspace authoritative after restore`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("3", .secondary)
        ])

        let manager = WorkspaceManager(settings: settings)
        let oldLeft = makeWorkspaceManagerTestMonitor(displayId: 100, name: "L", x: 0, y: 0)
        let oldRight = makeWorkspaceManagerTestMonitor(displayId: 200, name: "R", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([oldLeft, oldRight])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws3 = manager.workspaceId(for: "3", createIfMissing: true)
        else {
            Issue.record("Failed to create expected workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: oldLeft.id))
        #expect(manager.setActiveWorkspace(ws3, on: oldRight.id))

        let newLeft = makeWorkspaceManagerTestMonitor(displayId: 200, name: "R", x: 0, y: 0)
        let newRight = makeWorkspaceManagerTestMonitor(displayId: 100, name: "L", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([newLeft, newRight])

        let sorted = Monitor.sortedByPosition(manager.monitors)
        guard let forcedTarget = MonitorDescription.secondary.resolveMonitor(sortedMonitors: sorted) else {
            Issue.record("Failed to resolve forced monitor target")
            return
        }

        #expect(forcedTarget.id == newRight.id)
        #expect(manager.activeWorkspace(on: forcedTarget.id)?.id == ws3)
        #expect(manager.activeWorkspace(on: newLeft.id)?.id != ws3)
    }

    @Test @MainActor func `apply monitor configuration change preserves viewport state on reconnect`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

        let manager = WorkspaceManager(settings: settings)
        let oldLeft = makeWorkspaceManagerTestMonitor(displayId: 100, name: "L", x: 0, y: 0)
        let oldRight = makeWorkspaceManagerTestMonitor(displayId: 200, name: "R", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([oldLeft, oldRight])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create expected workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: oldLeft.id))
        #expect(manager.setActiveWorkspace(ws2, on: oldRight.id))

        let selectedNodeId = NodeId()
        manager.withNiriViewportState(for: ws2) { state in
            state.activeColumnIndex = 3
            state.selectedNodeId = selectedNodeId
        }

        manager.applyMonitorConfigurationChange([oldLeft])

        #expect(manager.activeWorkspace(on: oldLeft.id)?.id == ws2)
        #expect(manager.previousWorkspace(on: oldLeft.id)?.id == ws1)
        #expect(manager.monitorId(for: ws2) == oldLeft.id)
        #expect(manager.niriViewportState(for: ws2).activeColumnIndex == 3)
        #expect(manager.niriViewportState(for: ws2).selectedNodeId == selectedNodeId)

        let restoredRight = makeWorkspaceManagerTestMonitor(displayId: 300, name: "Replacement", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([oldLeft, restoredRight])

        #expect(manager.activeWorkspace(on: oldLeft.id)?.id == ws1)
        #expect(manager.activeWorkspace(on: restoredRight.id)?.id == ws2)
        #expect(manager.monitorId(for: ws2) == restoredRight.id)
        #expect(manager.workspaces(on: oldLeft.id).map(\.id) == [ws1])
        #expect(manager.workspaces(on: restoredRight.id).map(\.id) == [ws2])
        #expect(manager.niriViewportState(for: ws2).activeColumnIndex == 3)
        #expect(manager.niriViewportState(for: ws2).selectedNodeId == selectedNodeId)
    }

    @Test @MainActor func `reconnect restores previously visible workspace when monitor owns multiple workspaces`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary),
            ("3", .secondary)
        ])

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 100, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 200, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true),
              let ws3 = manager.workspaceId(for: "3", createIfMissing: true)
        else {
            Issue.record("Failed to create expected workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: left.id))
        #expect(manager.setActiveWorkspace(ws2, on: right.id))
        #expect(manager.setActiveWorkspace(ws3, on: right.id))

        let selectedNodeId = NodeId()
        manager.withNiriViewportState(for: ws3) { state in
            state.activeColumnIndex = 4
            state.selectedNodeId = selectedNodeId
        }

        manager.applyMonitorConfigurationChange([left])

        #expect(manager.activeWorkspace(on: left.id)?.id == ws3)
        #expect(manager.previousWorkspace(on: left.id)?.id == ws1)
        #expect(manager.monitorId(for: ws2) == left.id)
        #expect(manager.monitorId(for: ws3) == left.id)
        #expect(manager.workspaces(on: left.id).map(\.id) == [ws1, ws2, ws3])

        let restoredRight = makeWorkspaceManagerTestMonitor(displayId: 300, name: "Replacement", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, restoredRight])

        #expect(manager.activeWorkspace(on: left.id)?.id == ws1)
        #expect(manager.activeWorkspace(on: restoredRight.id)?.id == ws3)
        #expect(manager.monitorId(for: ws2) == restoredRight.id)
        #expect(manager.monitorId(for: ws3) == restoredRight.id)
        #expect(manager.workspaces(on: left.id).map(\.id) == [ws1])
        #expect(manager.workspaces(on: restoredRight.id).map(\.id) == [ws2, ws3])
        #expect(manager.niriViewportState(for: ws3).activeColumnIndex == 4)
        #expect(manager.niriViewportState(for: ws3).selectedNodeId == selectedNodeId)
    }

    @Test @MainActor func `apply monitor configuration change clears invalid previous interaction monitor`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 100, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 200, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create expected workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: left.id))
        #expect(manager.setActiveWorkspace(ws2, on: right.id))
        #expect(manager.previousInteractionMonitorId == left.id)

        manager.applyMonitorConfigurationChange([right])

        #expect(manager.interactionMonitorId == right.id)
        #expect(manager.previousInteractionMonitorId == nil)
    }

    @Test @MainActor func `apply monitor configuration change normalizes invalid interaction monitor`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 100, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 200, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        _ = manager.setInteractionMonitor(right.id, preservePrevious: false)
        #expect(manager.interactionMonitorId == right.id)
        #expect(manager.previousInteractionMonitorId == nil)

        manager.applyMonitorConfigurationChange([left])

        #expect(manager.interactionMonitorId == left.id)
        #expect(manager.previousInteractionMonitorId == nil)
    }

    @Test @MainActor func `removing visible workspace falls back to lowest assigned id on monitor`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("3", .main)
        ])

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 100, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws3 = manager.workspaceId(for: "3", createIfMissing: true)
        else {
            Issue.record("Failed to create expected workspaces")
            return
        }

        #expect(manager.activeWorkspace(on: monitor.id)?.id == ws1)
        #expect(manager.setActiveWorkspace(ws3, on: monitor.id))
        #expect(manager.activeWorkspace(on: monitor.id)?.id == ws3)

        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]
        manager.applySettings()

        #expect(manager.activeWorkspace(on: monitor.id)?.id == ws1)
        #expect(manager.workspaceId(named: "3") == nil)
    }

    @Test @MainActor func `configured workspace10 can be created sorted and focused`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("10", .main),
            ("11", .main)
        ])

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 150, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspace10 = manager.workspaceId(for: "10", createIfMissing: true),
              let workspace11 = manager.workspaceId(for: "11", createIfMissing: true)
        else {
            Issue.record("Failed to create expected high workspace IDs")
            return
        }

        #expect(manager.workspaces.map(\.name) == ["1", "10", "11"])
        _ = workspace11
        #expect(manager.activeWorkspace(on: monitor.id)?.name == "1")
        #expect(manager.setActiveWorkspace(workspace10, on: monitor.id))
        #expect(manager.activeWorkspace(on: monitor.id)?.name == "10")
    }

    @Test @MainActor func `apply session patch commits viewport and remembered focus atomically`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 300, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let handle = addWorkspaceManagerTestHandle(manager: manager, windowId: 3201, workspaceId: workspaceId)
        let selectedNodeId = NodeId()
        var viewportState = manager.niriViewportState(for: workspaceId)
        viewportState.selectedNodeId = selectedNodeId
        viewportState.activeColumnIndex = 2

        #expect(
            manager.applySessionPatch(
                .init(
                    workspaceId: workspaceId,
                    viewportState: viewportState,
                    rememberedFocusToken: handle.id
                )
            )
        )
        #expect(manager.niriViewportState(for: workspaceId).selectedNodeId == selectedNodeId)
        #expect(manager.niriViewportState(for: workspaceId).activeColumnIndex == 2)
        #expect(manager.lastFocusedToken(in: workspaceId) == handle.id)
    }

    @Test @MainActor func `apply session patch preserves current spring against stale gesture viewport`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 301, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        var currentState = manager.niriViewportState(for: workspaceId)
        currentState.activeColumnIndex = 4
        currentState.selectedNodeId = NodeId()
        currentState.viewOffsetPixels = .spring(
            SpringAnimation(
                from: 24,
                to: 96,
                startTime: 0,
                config: .snappy
            )
        )
        manager.updateNiriViewportState(currentState, for: workspaceId)

        var staleGestureState = ViewportState()
        staleGestureState.activeColumnIndex = 1
        let patchedSelection = NodeId()
        staleGestureState.selectedNodeId = patchedSelection
        staleGestureState.beginGesture(isTrackpad: true)

        #expect(
            manager.applySessionPatch(
                .init(
                    workspaceId: workspaceId,
                    viewportState: staleGestureState,
                    rememberedFocusToken: nil
                )
            )
        )

        let mergedState = manager.niriViewportState(for: workspaceId)
        #expect(mergedState.activeColumnIndex == 4)
        #expect(mergedState.selectedNodeId == patchedSelection)
        switch mergedState.viewOffsetPixels {
        case .spring:
            break
        default:
            Issue.record("Expected the current spring animation to survive a stale gesture patch")
        }
    }

    @Test @MainActor func `apply session transfer moves viewport and focus memory together`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 310, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 320, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let sourceWorkspaceId = manager.workspaceId(for: "1", createIfMissing: true),
              let targetWorkspaceId = manager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create workspaces")
            return
        }

        let sourceHandle = addWorkspaceManagerTestHandle(
            manager: manager,
            windowId: 3301,
            workspaceId: sourceWorkspaceId
        )
        let targetHandle = addWorkspaceManagerTestHandle(
            manager: manager,
            windowId: 3302,
            workspaceId: targetWorkspaceId
        )

        var sourceState = manager.niriViewportState(for: sourceWorkspaceId)
        sourceState.selectedNodeId = NodeId()
        var targetState = manager.niriViewportState(for: targetWorkspaceId)
        targetState.selectedNodeId = NodeId()

        #expect(
            manager.applySessionTransfer(
                .init(
                    sourcePatch: .init(
                        workspaceId: sourceWorkspaceId,
                        viewportState: sourceState,
                        rememberedFocusToken: sourceHandle.id
                    ),
                    targetPatch: .init(
                        workspaceId: targetWorkspaceId,
                        viewportState: targetState,
                        rememberedFocusToken: targetHandle.id
                    )
                )
            )
        )
        #expect(manager.niriViewportState(for: sourceWorkspaceId).selectedNodeId == sourceState.selectedNodeId)
        #expect(manager.niriViewportState(for: targetWorkspaceId).selectedNodeId == targetState.selectedNodeId)
        #expect(manager.lastFocusedToken(in: sourceWorkspaceId) == sourceHandle.id)
        #expect(manager.lastFocusedToken(in: targetWorkspaceId) == targetHandle.id)
    }

    @Test @MainActor func `commit workspace selection updates selected node and remembered focus atomically`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 330, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let handle = addWorkspaceManagerTestHandle(manager: manager, windowId: 3401, workspaceId: workspaceId)
        let selectedNodeId = NodeId()

        #expect(
            manager.commitWorkspaceSelection(
                nodeId: selectedNodeId,
                focusedToken: handle.id,
                in: workspaceId,
                onMonitor: monitor.id
            )
        )
        #expect(manager.niriViewportState(for: workspaceId).selectedNodeId == selectedNodeId)
        #expect(manager.lastFocusedToken(in: workspaceId) == handle.id)
    }

    @Test @MainActor func `scratchpad token rekeys and clears on window removal`() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 340, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let token = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 3501),
            pid: 3501,
            windowId: 3501,
            to: workspaceId,
            mode: .floating
        )
        #expect(manager.setScratchpadToken(token))
        #expect(manager.scratchpadToken() == token)

        let rekeyedToken = WindowToken(pid: 3501, windowId: 3502)
        let newAXRef = makeWorkspaceManagerTestWindow(windowId: 3502)
        #expect(manager.rekeyWindow(from: token, to: rekeyedToken, newAXRef: newAXRef) != nil)
        #expect(manager.scratchpadToken() == rekeyedToken)

        _ = manager.removeWindow(pid: rekeyedToken.pid, windowId: rekeyedToken.windowId)
        #expect(manager.scratchpadToken() == nil)
    }
}
