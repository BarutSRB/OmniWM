import ApplicationServices
import Foundation
import QuartzCore
import Testing

@testable import OmniWM

func makeTestHandle(pid: pid_t = 1) -> WindowHandle {
    WindowHandle(
        id: WindowToken(pid: pid, windowId: Int.random(in: 1 ... 1_000_000)),
        pid: pid,
        axElement: AXUIElementCreateSystemWide()
    )
}

func makeTestMonitor(
    displayId: CGDirectDisplayID,
    name: String,
    x: CGFloat
) -> Monitor {
    let frame = CGRect(x: x, y: 0, width: 1920, height: 1080)
    return Monitor(
        id: Monitor.ID(displayId: displayId),
        displayId: displayId,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: name
    )
}

func makeHorizontalNeighboringTestMonitors() -> (primary: Monitor, secondary: Monitor) {
    (
        primary: makeLayoutPlanTestMonitor(
            displayId: 100,
            name: "Primary",
            x: 0,
            width: 1600,
            height: 900
        ),
        secondary: makeLayoutPlanTestMonitor(
            displayId: 200,
            name: "Secondary",
            x: 1600,
            width: 1600,
            height: 900
        )
    )
}

func makeVerticalStackedTestMonitors() -> (lower: Monitor, upper: Monitor) {
    (
        lower: makeLayoutPlanTestMonitor(
            displayId: 301,
            name: "Lower",
            x: 0,
            y: 0,
            width: 900,
            height: 1600
        ),
        upper: makeLayoutPlanTestMonitor(
            displayId: 302,
            name: "Upper",
            x: 0,
            y: 1600,
            width: 900,
            height: 1600
        )
    )
}

private func hasNiriScrollDirective(
    _ directives: [AnimationDirective],
    workspaceId: WorkspaceDescriptor.ID
) -> Bool {
    directives.contains { directive in
        if case let .startNiriScroll(candidate) = directive {
            return candidate == workspaceId
        }
        return false
    }
}

private func hasActivationDirective(
    _ directives: [AnimationDirective],
    token: WindowToken
) -> Bool {
    directives.contains { directive in
        if case let .activateWindow(candidate) = directive {
            return candidate == token
        }
        return false
    }
}

private func hasHiddenVisibilityChange(_ changes: [LayoutVisibilityChange]) -> Bool {
    changes.contains { change in
        if case .hide = change {
            return true
        }
        return false
    }
}

private func hiddenVisibilitySides(_ changes: [LayoutVisibilityChange]) -> [HideSide] {
    changes.compactMap { change in
        if case let .hide(_, side: side) = change {
            return side
        }
        return nil
    }
}

private func hasHideVisibilityChange(
    _ changes: [LayoutVisibilityChange],
    token: WindowToken,
    side: HideSide? = nil
) -> Bool {
    changes.contains { change in
        guard case let .hide(candidate, changeSide) = change,
              candidate == token
        else {
            return false
        }
        return side == nil || side == changeSide
    }
}

private func hasShowVisibilityChange(
    _ changes: [LayoutVisibilityChange],
    token: WindowToken
) -> Bool {
    changes.contains { change in
        if case let .show(candidate) = change {
            return candidate == token
        }
        return false
    }
}

private func hasAnyVisibilityChange(
    _ changes: [LayoutVisibilityChange],
    token: WindowToken
) -> Bool {
    hasHideVisibilityChange(changes, token: token) || hasShowVisibilityChange(changes, token: token)
}

private func hiddenVisibilityTokens(_ changes: [LayoutVisibilityChange]) -> [WindowToken] {
    changes.compactMap { change in
        if case let .hide(token, side: _) = change {
            return token
        }
        return nil
    }
}

private func hasFrameChange(
    _ changes: [LayoutFrameChange],
    token: WindowToken
) -> Bool {
    changes.contains { $0.token == token }
}

private enum CrossMonitorWorkspaceSide {
    case primary
    case secondary
}

private struct CenteredCrossMonitorFixture {
    let controller: WMController
    let engine: NiriLayoutEngine
    let primaryMonitor: Monitor
    let secondaryMonitor: Monitor
    let primaryWorkspaceId: WorkspaceDescriptor.ID
    let secondaryWorkspaceId: WorkspaceDescriptor.ID
    let targetWorkspaceId: WorkspaceDescriptor.ID
    let targetMonitor: Monitor
    let neighboringMonitor: Monitor
}

@MainActor
private func suppressAutomaticRefreshExecution(on controller: WMController) {
    controller.layoutRefreshController.resetDebugState()
    controller.layoutRefreshController.debugHooks.onRelayout = { _, _ in true }
    controller.layoutRefreshController.debugHooks.onVisibilityRefresh = { _ in true }
    controller.layoutRefreshController.debugHooks.onFullRescan = { _ in true }
    controller.layoutRefreshController.debugHooks.onWindowRemoval = { _, _ in true }
}

@MainActor
private func executeAndSettleLayoutPlans(
    _ plans: [WorkspaceLayoutPlan],
    on controller: WMController
) async {
    controller.layoutRefreshController.executeLayoutPlans(plans)
    await waitForLayoutPlanRefreshWork(on: controller)
    controller.layoutRefreshController.stopAllScrollAnimations()
}

private func assertHideOnlyMonitorBoundaryDiff(
    _ plan: WorkspaceLayoutPlan,
    token: WindowToken,
    side: HideSide,
    disallowedMonitor: Monitor
) {
    #expect(hasHideVisibilityChange(plan.diff.visibilityChanges, token: token, side: side))
    #expect(!hasFrameChange(plan.diff.frameChanges, token: token))
    for change in plan.diff.frameChanges {
        #expect(!change.frame.intersects(disallowedMonitor.frame))
    }
}

@MainActor
private func selectWindowAndSettleViewport(
    _ window: NiriWindow,
    in workspaceId: WorkspaceDescriptor.ID,
    on monitor: Monitor,
    engine: NiriLayoutEngine,
    controller: WMController
) {
    _ = controller.workspaceManager.setManagedFocus(
        window.token,
        in: workspaceId,
        onMonitor: monitor.id
    )
    _ = controller.workspaceManager.commitWorkspaceSelection(
        nodeId: window.id,
        focusedToken: window.token,
        in: workspaceId,
        onMonitor: monitor.id
    )

    let workingFrame = controller.insetWorkingFrame(for: monitor)
    let gap = CGFloat(controller.workspaceManager.gaps)
    controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
        state.selectedNodeId = window.id
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)
        engine.ensureSelectionVisible(
            node: window,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )
        state.viewOffsetPixels = .static(state.viewOffsetPixels.target())
    }
}

@MainActor
private func calculateCurrentLayout(
    controller: WMController,
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID,
    monitor: Monitor,
    animationTime: TimeInterval? = nil
) -> (
    frames: [WindowToken: CGRect],
    hiddenHandles: [WindowToken: HideSide]
) {
    let gaps = LayoutGaps(
        horizontal: CGFloat(controller.workspaceManager.gaps),
        vertical: CGFloat(controller.workspaceManager.gaps),
        outer: controller.workspaceManager.outerGaps
    )
    let workingFrame = controller.insetWorkingFrame(for: monitor)
    let area = WorkingAreaContext(
        workingFrame: workingFrame,
        viewFrame: monitor.frame,
        scale: controller.layoutRefreshController.backingScale(for: monitor)
    )
    let state = controller.workspaceManager.niriViewportState(for: workspaceId)
    return engine.calculateCombinedLayoutUsingPools(
        in: workspaceId,
        monitor: monitor,
        gaps: gaps,
        state: state,
        workingArea: area,
        animationTime: animationTime
    )
}

@MainActor
private func makeCenteredCrossMonitorFixture(
    workspaceSide: CrossMonitorWorkspaceSide,
    windowIds: ClosedRange<Int>
) async -> CenteredCrossMonitorFixture? {
    let monitors = makeHorizontalNeighboringTestMonitors()
    let fixture = makeTwoMonitorLayoutPlanTestController(
        primaryMonitor: monitors.primary,
        secondaryMonitor: monitors.secondary
    )
    let controller = fixture.controller

    suppressAutomaticRefreshExecution(on: controller)
    controller.enableNiriLayout(maxWindowsPerColumn: 1, centerFocusedColumn: .always)
    controller.updateNiriConfig(
        maxVisibleColumns: 2,
        centerFocusedColumn: .always,
        defaultColumnWidth: .some(0.85)
    )
    await waitForLayoutPlanRefreshWork(on: controller)

    guard controller.workspaceManager.setActiveWorkspace(fixture.primaryWorkspaceId, on: monitors.primary.id),
          controller.workspaceManager.setActiveWorkspace(fixture.secondaryWorkspaceId, on: monitors.secondary.id),
          controller.workspaceManager.monitorId(for: fixture.primaryWorkspaceId) == monitors.primary.id,
          controller.workspaceManager.monitorId(for: fixture.secondaryWorkspaceId) == monitors.secondary.id
    else {
        Issue.record("Failed to bind workspaces to the expected monitors for cross-monitor leak regression test")
        return nil
    }

    controller.syncMonitorsToNiriEngine()

    let targetWorkspaceId: WorkspaceDescriptor.ID
    let targetMonitor: Monitor
    let neighboringMonitor: Monitor
    switch workspaceSide {
    case .primary:
        targetWorkspaceId = fixture.primaryWorkspaceId
        targetMonitor = monitors.primary
        neighboringMonitor = monitors.secondary
    case .secondary:
        targetWorkspaceId = fixture.secondaryWorkspaceId
        targetMonitor = monitors.secondary
        neighboringMonitor = monitors.primary
    }

    for windowId in windowIds {
        _ = addLayoutPlanTestWindow(on: controller, workspaceId: targetWorkspaceId, windowId: windowId)
    }

    guard let engine = controller.niriEngine else {
        Issue.record("Expected Niri engine for cross-monitor leak regression test")
        return nil
    }

    return CenteredCrossMonitorFixture(
        controller: controller,
        engine: engine,
        primaryMonitor: monitors.primary,
        secondaryMonitor: monitors.secondary,
        primaryWorkspaceId: fixture.primaryWorkspaceId,
        secondaryWorkspaceId: fixture.secondaryWorkspaceId,
        targetWorkspaceId: targetWorkspaceId,
        targetMonitor: targetMonitor,
        neighboringMonitor: neighboringMonitor
    )
}

@Suite struct NiriLayoutEngineTests {
    private struct SingleColumnFocusFixture {
        let controller: WMController
        let monitor: Monitor
        let workspaceId: WorkspaceDescriptor.ID
        let engine: NiriLayoutEngine
        let column: NiriContainer
        let bottomToken: WindowToken
        let middleToken: WindowToken
        let topToken: WindowToken
        let bottomWindow: NiriWindow
        let middleWindow: NiriWindow
        let topWindow: NiriWindow
    }

    private struct NeighboringMonitorRevealFixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let owningMonitor: Monitor
        let neighboringMonitor: Monitor
        let firstWindow: NiriWindow
        let secondWindow: NiriWindow
        let gap: CGFloat
        let gaps: LayoutGaps
        let area: WorkingAreaContext
    }

    @MainActor
    private func makeSingleColumnFocusFixture(displayMode: ColumnDisplay) async -> SingleColumnFocusFixture {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            fatalError("Missing monitor or active workspace for single-column focus fixture")
        }

        controller.enableNiriLayout(
            maxWindowsPerColumn: 4,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        controller.updateNiriConfig(
            maxVisibleColumns: 3,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.layoutRefreshController.stopAllScrollAnimations()
        controller.syncMonitorsToNiriEngine()

        let bottomToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 901)
        let middleToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 902)
        let topToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 903)

        guard let engine = controller.niriEngine else {
            fatalError("Expected Niri engine for single-column focus fixture")
        }

        let root = NiriRoot(workspaceId: workspaceId)
        engine.roots[workspaceId] = root
        engine.ensureMonitor(for: monitor.id, monitor: monitor).workspaceRoots[workspaceId] = root

        let column = NiriContainer()
        column.displayMode = displayMode
        root.appendChild(column)
        assignFixedWidths(root.columns)

        let bottomWindow = NiriWindow(token: bottomToken)
        let middleWindow = NiriWindow(token: middleToken)
        let topWindow = NiriWindow(token: topToken)

        column.appendChild(bottomWindow)
        column.appendChild(middleWindow)
        column.appendChild(topWindow)
        if displayMode == .tabbed {
            column.setActiveTileIdx(1)
            engine.updateTabbedColumnVisibility(column: column)
        }

        engine.tokenToNode[bottomToken] = bottomWindow
        engine.tokenToNode[middleToken] = middleWindow
        engine.tokenToNode[topToken] = topWindow

        _ = controller.workspaceManager.setManagedFocus(middleToken, in: workspaceId, onMonitor: monitor.id)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: middleWindow.id,
            focusedToken: middleToken,
            in: workspaceId,
            onMonitor: monitor.id
        )
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = middleWindow.id
            state.activeColumnIndex = 0
            state.viewOffsetPixels = .static(0)
        }

        return SingleColumnFocusFixture(
            controller: controller,
            monitor: monitor,
            workspaceId: workspaceId,
            engine: engine,
            column: column,
            bottomToken: bottomToken,
            middleToken: middleToken,
            topToken: topToken,
            bottomWindow: bottomWindow,
            middleWindow: middleWindow,
            topWindow: topWindow
        )
    }

    private func makeVisibleColumnFixture(
        visibleCount: Int,
        extraColumns: Int = 2,
        width: CGFloat = 1600,
        height: CGFloat = 900
    ) -> (
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        windows: [NiriWindow],
        monitor: Monitor,
        gap: CGFloat,
        gaps: LayoutGaps,
        area: WorkingAreaContext
    ) {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1, maxVisibleColumns: visibleCount)
        engine.centerFocusedColumn = .never

        let workspaceId = UUID()
        var windows: [NiriWindow] = []
        var previousSelection: NodeId?

        for index in 0 ..< (visibleCount + extraColumns) {
            let handle = makeTestHandle(pid: pid_t(200 + index))
            let window = engine.addWindow(
                handle: handle,
                to: workspaceId,
                afterSelection: previousSelection
            )
            windows.append(window)
            previousSelection = window.id
        }

        let monitor = makeLayoutPlanTestMonitor(width: width, height: height)
        let gap: CGFloat = 8
        let gaps = LayoutGaps(horizontal: gap, vertical: gap)
        let area = WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )
        let fixedWidth = (monitor.visibleFrame.width - gap * CGFloat(visibleCount - 1)) / CGFloat(visibleCount)

        for column in engine.columns(in: workspaceId) {
            column.width = .fixed(fixedWidth)
            column.cachedWidth = fixedWidth
        }

        return (engine, workspaceId, windows, monitor, gap, gaps, area)
    }

    @MainActor
    private func makeDisabledMotionWidthCommandFixture(
        visibleCount: Int = 2,
        extraColumns: Int = 3
    ) async throws -> (
        controller: WMController,
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        columns: [NiriContainer],
        windows: [NiriWindow],
        gap: CGFloat,
        workingFrame: CGRect
    ) {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            fatalError("Missing monitor or active workspace for disabled-motion width command fixture")
        }

        controller.enableNiriLayout(
            maxWindowsPerColumn: 1,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        controller.updateNiriConfig(
            maxVisibleColumns: visibleCount,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        guard let engine = controller.niriEngine else {
            fatalError("Expected Niri engine for disabled-motion width command fixture")
        }

        for windowId in 700 ..< 700 + visibleCount + extraColumns {
            _ = addLayoutPlanTestWindow(
                on: controller,
                workspaceId: workspaceId,
                windowId: windowId
            )
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        let gap = CGFloat(controller.workspaceManager.gaps)
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let fixedWidth = (
            workingFrame.width - gap * CGFloat(visibleCount - 1)
        ) / CGFloat(visibleCount)

        for column in engine.columns(in: workspaceId) {
            column.width = .fixed(fixedWidth)
            column.cachedWidth = fixedWidth
        }

        let columns = engine.columns(in: workspaceId)
        let windows = columns.compactMap(\.windowNodes.first)
        guard windows.count >= visibleCount else {
            fatalError("Expected enough windows for disabled-motion width command fixture")
        }

        let activeIndex = visibleCount - 1
        let selectedWindow = windows[activeIndex]
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.animationClock = engine.animationClock
            state.selectedNodeId = selectedWindow.id
            state.activeColumnIndex = activeIndex
            state.viewOffsetPixels = .static(0)
            engine.ensureSelectionVisible(
                node: selectedWindow,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gap
            )
        }
        _ = controller.workspaceManager.setManagedFocus(selectedWindow.token, in: workspaceId, onMonitor: monitor.id)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: selectedWindow.id,
            focusedToken: selectedWindow.token,
            in: workspaceId,
            onMonitor: monitor.id
        )

        let refreshedPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(refreshedPlans)

        controller.layoutRefreshController.stopAllScrollAnimations()
        controller.setAnimationsEnabled(false)

        return (
            controller,
            engine,
            workspaceId,
            monitor,
            columns,
            windows,
            gap,
            workingFrame
        )
    }

    private func makeViewportStateForVisibleColumn(
        targetWindow: NiriWindow,
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        gap: CGFloat
    ) -> ViewportState {
        var state = ViewportState()
        state.animationClock = engine.animationClock
        state.selectedNodeId = targetWindow.id
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)
        engine.ensureSelectionVisible(
            node: targetWindow,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )
        return state
    }

    private func settledLayoutState(
        from state: ViewportState,
        column: NiriContainer?,
        settleTime: TimeInterval
    ) -> ViewportState {
        var settledState = state
        _ = settledState.advanceAnimations(at: settleTime)
        _ = column?.tickWidthAnimation(at: settleTime)
        return settledState
    }

    private func assignFixedWidths(
        _ columns: [NiriContainer],
        width: CGFloat = 400
    ) {
        for column in columns {
            column.width = .fixed(width)
            column.cachedWidth = width
        }
    }

    private func assignWidths(
        _ columns: [NiriContainer],
        widths: [CGFloat]
    ) {
        for (column, width) in zip(columns, widths) {
            column.width = .fixed(width)
            column.cachedWidth = width
        }
    }

    private func assignHeights(
        _ columns: [NiriContainer],
        heights: [CGFloat]
    ) {
        for (column, height) in zip(columns, heights) {
            column.height = .fixed(height)
            column.cachedHeight = height
        }
    }

    private func viewportStart(
        for state: ViewportState,
        columns: [NiriContainer],
        gap: CGFloat
    ) -> CGFloat {
        state.columnX(at: state.activeColumnIndex, columns: columns, gap: gap)
            + state.viewOffsetPixels.target()
    }

    private func resolvedSettings(
        for engine: NiriLayoutEngine,
        maxVisibleColumns: Int? = nil,
        maxWindowsPerColumn: Int? = nil,
        centerFocusedColumn: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowAspectRatio: SingleWindowAspectRatio? = nil,
        infiniteLoop: Bool? = nil
    ) -> ResolvedNiriSettings {
        let global = engine.globalResolvedSettings()
        return ResolvedNiriSettings(
            maxVisibleColumns: maxVisibleColumns ?? global.maxVisibleColumns,
            maxWindowsPerColumn: maxWindowsPerColumn ?? global.maxWindowsPerColumn,
            centerFocusedColumn: centerFocusedColumn ?? global.centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn ?? global.alwaysCenterSingleColumn,
            singleWindowAspectRatio: singleWindowAspectRatio ?? global.singleWindowAspectRatio,
            infiniteLoop: infiniteLoop ?? global.infiniteLoop
        )
    }

    private func attachWorkspace(
        _ workspaceId: WorkspaceDescriptor.ID,
        to monitor: Monitor,
        engine: NiriLayoutEngine,
        resolvedSettings: ResolvedNiriSettings? = nil
    ) {
        engine.moveWorkspace(workspaceId, to: monitor.id, monitor: monitor)
        if let resolvedSettings {
            engine.updateMonitorSettings(resolvedSettings, for: monitor.id)
        }
    }

    private func makeNeighboringLayoutContext(
        for monitor: Monitor,
        gap: CGFloat = 8,
        scale: CGFloat = 2.0
    ) -> (
        gap: CGFloat,
        gaps: LayoutGaps,
        area: WorkingAreaContext
    ) {
        let gaps = LayoutGaps(horizontal: gap, vertical: gap)
        let area = WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: scale
        )
        return (gap, gaps, area)
    }

    private func makeHorizontalNeighboringRevealFixture(
        workspaceOnPrimary: Bool,
        withAnimationClock: Bool = false,
        pidBase: pid_t = 51
    ) -> NeighboringMonitorRevealFixture {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1, maxVisibleColumns: 1)
        if withAnimationClock {
            engine.animationClock = AnimationClock()
        }

        let workspaceId = UUID()
        let monitors = makeHorizontalNeighboringTestMonitors()
        let owningMonitor: Monitor
        let neighboringMonitor: Monitor

        if workspaceOnPrimary {
            attachWorkspace(
                workspaceId,
                to: monitors.primary,
                engine: engine,
                resolvedSettings: resolvedSettings(
                    for: engine,
                    maxVisibleColumns: 2,
                    centerFocusedColumn: .always
                )
            )
            _ = engine.ensureMonitor(for: monitors.secondary.id, monitor: monitors.secondary)
            owningMonitor = monitors.primary
            neighboringMonitor = monitors.secondary
        } else {
            _ = engine.ensureMonitor(for: monitors.primary.id, monitor: monitors.primary)
            attachWorkspace(
                workspaceId,
                to: monitors.secondary,
                engine: engine,
                resolvedSettings: resolvedSettings(
                    for: engine,
                    maxVisibleColumns: 2,
                    centerFocusedColumn: .always
                )
            )
            owningMonitor = monitors.secondary
            neighboringMonitor = monitors.primary
        }

        let firstWindow = engine.addWindow(handle: makeTestHandle(pid: pidBase), to: workspaceId, afterSelection: nil)
        let secondWindow = engine.addWindow(
            handle: makeTestHandle(pid: pidBase + 1),
            to: workspaceId,
            afterSelection: firstWindow.id
        )
        assignWidths(
            engine.columns(in: workspaceId),
            widths: [owningMonitor.visibleFrame.width, owningMonitor.visibleFrame.width]
        )

        let (gap, gaps, area) = makeNeighboringLayoutContext(for: owningMonitor)
        return NeighboringMonitorRevealFixture(
            engine: engine,
            workspaceId: workspaceId,
            owningMonitor: owningMonitor,
            neighboringMonitor: neighboringMonitor,
            firstWindow: firstWindow,
            secondWindow: secondWindow,
            gap: gap,
            gaps: gaps,
            area: area
        )
    }

    private func makeVerticalNeighboringRevealFixture(
        workspaceOnLowerMonitor: Bool,
        withAnimationClock: Bool = false,
        pidBase: pid_t = 161
    ) -> NeighboringMonitorRevealFixture {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1, maxVisibleColumns: 1)
        if withAnimationClock {
            engine.animationClock = AnimationClock()
        }

        let workspaceId = UUID()
        let monitors = makeVerticalStackedTestMonitors()
        let owningMonitor: Monitor
        let neighboringMonitor: Monitor

        if workspaceOnLowerMonitor {
            attachWorkspace(
                workspaceId,
                to: monitors.lower,
                engine: engine,
                resolvedSettings: resolvedSettings(
                    for: engine,
                    maxVisibleColumns: 2,
                    centerFocusedColumn: .always
                )
            )
            _ = engine.ensureMonitor(for: monitors.upper.id, monitor: monitors.upper)
            owningMonitor = monitors.lower
            neighboringMonitor = monitors.upper
        } else {
            _ = engine.ensureMonitor(for: monitors.lower.id, monitor: monitors.lower)
            attachWorkspace(
                workspaceId,
                to: monitors.upper,
                engine: engine,
                resolvedSettings: resolvedSettings(
                    for: engine,
                    maxVisibleColumns: 2,
                    centerFocusedColumn: .always
                )
            )
            owningMonitor = monitors.upper
            neighboringMonitor = monitors.lower
        }

        let firstWindow = engine.addWindow(handle: makeTestHandle(pid: pidBase), to: workspaceId, afterSelection: nil)
        let secondWindow = engine.addWindow(
            handle: makeTestHandle(pid: pidBase + 1),
            to: workspaceId,
            afterSelection: firstWindow.id
        )
        assignHeights(
            engine.columns(in: workspaceId),
            heights: [owningMonitor.visibleFrame.height, owningMonitor.visibleFrame.height]
        )

        let (gap, gaps, area) = makeNeighboringLayoutContext(for: owningMonitor)
        return NeighboringMonitorRevealFixture(
            engine: engine,
            workspaceId: workspaceId,
            owningMonitor: owningMonitor,
            neighboringMonitor: neighboringMonitor,
            firstWindow: firstWindow,
            secondWindow: secondWindow,
            gap: gap,
            gaps: gaps,
            area: area
        )
    }

    @Test func selectionFallbackAfterRemoval_sameSibling() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)
        let _ = engine.addWindow(handle: h3, to: wsId, afterSelection: w2.id)

        let cols = engine.columns(in: wsId)
        #expect(cols.count >= 2)

        let fallback = engine.fallbackSelectionOnRemoval(removing: w2.id, in: wsId)
        #expect(fallback != nil)
        #expect(fallback != w2.id)

        let fallbackNode = engine.findNode(by: fallback!)
        #expect(fallbackNode != nil)
    }

    @Test func firstWindowUsesBalancedWidthWhenDefaultWidthIsAutoWhenSingleWindowRatioIsDisabled() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.presetColumnWidths = [.proportion(0.85), .proportion(1.0), .proportion(0.5)]
        engine.singleWindowAspectRatio = .none
        let wsId = UUID()

        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)

        guard let column = engine.column(of: window) else {
            Issue.record("Expected claimed column for first window")
            return
        }

        #expect(column.width == .proportion(1.0 / 3.0))
        #expect(column.presetWidthIdx == nil)
    }

    @Test func firstWindowUsesResolvedMonitorMaxVisibleColumnsWhenDefaultWidthIsAuto() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 1)
        engine.presetColumnWidths = [.proportion(0.85), .proportion(1.0), .proportion(0.5)]
        engine.singleWindowAspectRatio = .none
        let wsId = UUID()
        let monitor = makeTestMonitor(displayId: 501, name: "Override", x: 0)
        attachWorkspace(
            wsId,
            to: monitor,
            engine: engine,
            resolvedSettings: resolvedSettings(for: engine, maxVisibleColumns: 3)
        )

        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)

        guard let column = engine.column(of: window) else {
            Issue.record("Expected claimed column for monitor-override width test")
            return
        }

        #expect(column.width == .proportion(1.0 / 3.0))
        #expect(column.presetWidthIdx == nil)
    }

    @Test func singleWindowAspectRatioCentersLoneWindowFrame() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.singleWindowAspectRatio = .ratio4x3
        engine.alwaysCenterSingleColumn = false
        let wsId = UUID()
        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        let monitor = makeLayoutPlanTestMonitor()

        let layout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: 8, vertical: 8),
            state: ViewportState()
        )

        guard let frame = layout.frames[window.token] else {
            Issue.record("Expected a rendered frame for the single Niri window")
            return
        }

        #expect(frame == CGRect(x: 240, y: 0, width: 1440, height: 1080))
    }

    @Test func singleWindowManualWidthOverrideKeepsWindowCenteredWhenAlwaysCenterSingleColumnDisabled() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.singleWindowAspectRatio = .ratio4x3
        engine.alwaysCenterSingleColumn = false
        engine.animationClock = AnimationClock()
        let wsId = UUID()
        let gap: CGFloat = 8
        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        let monitor = makeLayoutPlanTestMonitor()

        guard let column = engine.column(of: window) else {
            Issue.record("Expected a column for single-window manual width override test")
            return
        }

        var state = ViewportState()
        engine.toggleColumnWidth(
            column,
            forwards: true,
            in: wsId,
            state: &state,
            workingFrame: monitor.visibleFrame,
            gaps: gap
        )

        guard let settleBaseTime = engine.animationClock?.now() else {
            Issue.record("Expected animation clock for single-window manual width override test")
            return
        }

        let settleTime = settleBaseTime + 2.0
        let settledState = settledLayoutState(from: state, column: column, settleTime: settleTime)
        let layout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: gap, vertical: gap),
            state: settledState,
            animationTime: settleTime
        )

        guard let frame = layout.frames[window.token] else {
            Issue.record("Expected a rendered frame for single-window manual width override test")
            return
        }

        #expect(column.hasManualSingleWindowWidthOverride)
        #expect(abs(frame.width - 956) < 0.6)
        #expect(abs(frame.midX - monitor.visibleFrame.midX) < 0.6)
        #expect(frame.height == monitor.visibleFrame.height)
    }

    @Test func singleWindowFullWidthRoundTripRestoresPriorManualWidthAndCentering() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.singleWindowAspectRatio = .ratio4x3
        engine.alwaysCenterSingleColumn = false
        engine.animationClock = AnimationClock()
        let wsId = UUID()
        let gap: CGFloat = 8
        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        let monitor = makeLayoutPlanTestMonitor()

        guard let column = engine.column(of: window) else {
            Issue.record("Expected a column for single-window full-width round-trip test")
            return
        }

        var state = ViewportState()
        engine.toggleColumnWidth(
            column,
            forwards: true,
            in: wsId,
            state: &state,
            workingFrame: monitor.visibleFrame,
            gaps: gap
        )

        guard let firstBaseTime = engine.animationClock?.now() else {
            Issue.record("Expected animation clock for single-window full-width round-trip test")
            return
        }

        let firstSettleTime = firstBaseTime + 2.0
        state = settledLayoutState(from: state, column: column, settleTime: firstSettleTime)
        let resizedLayout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: gap, vertical: gap),
            state: state,
            animationTime: firstSettleTime
        )

        guard let resizedFrame = resizedLayout.frames[window.token] else {
            Issue.record("Expected a resized frame before toggling full width")
            return
        }

        engine.toggleFullWidth(
            column,
            in: wsId,
            state: &state,
            workingFrame: monitor.visibleFrame,
            gaps: gap
        )

        guard let secondBaseTime = engine.animationClock?.now() else {
            Issue.record("Expected animation clock after enabling full width")
            return
        }

        let secondSettleTime = secondBaseTime + 2.0
        state = settledLayoutState(from: state, column: column, settleTime: secondSettleTime)
        let fullWidthLayout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: gap, vertical: gap),
            state: state,
            animationTime: secondSettleTime
        )

        guard let fullWidthFrame = fullWidthLayout.frames[window.token] else {
            Issue.record("Expected a full-width frame for single-window round-trip test")
            return
        }

        engine.toggleFullWidth(
            column,
            in: wsId,
            state: &state,
            workingFrame: monitor.visibleFrame,
            gaps: gap
        )

        guard let thirdBaseTime = engine.animationClock?.now() else {
            Issue.record("Expected animation clock after disabling full width")
            return
        }

        let thirdSettleTime = thirdBaseTime + 2.0
        state = settledLayoutState(from: state, column: column, settleTime: thirdSettleTime)
        let restoredLayout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: gap, vertical: gap),
            state: state,
            animationTime: thirdSettleTime
        )

        guard let restoredFrame = restoredLayout.frames[window.token] else {
            Issue.record("Expected a restored frame after full-width round-trip")
            return
        }

        #expect(abs(fullWidthFrame.minX - monitor.visibleFrame.minX) < 0.6)
        #expect(abs(fullWidthFrame.maxX - monitor.visibleFrame.maxX) < 0.6)
        #expect(abs(restoredFrame.width - resizedFrame.width) < 0.6)
        #expect(abs(restoredFrame.midX - monitor.visibleFrame.midX) < 0.6)
    }

    @Test func singleWindowManualWidthTargetFrameMatchesRenderedFrame() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.singleWindowAspectRatio = .ratio4x3
        engine.alwaysCenterSingleColumn = false
        engine.animationClock = AnimationClock()
        let wsId = UUID()
        let gap: CGFloat = 8
        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        let monitor = makeLayoutPlanTestMonitor()

        guard let column = engine.column(of: window) else {
            Issue.record("Expected a column for single-window target-frame regression test")
            return
        }

        var state = ViewportState()
        engine.toggleColumnWidth(
            column,
            forwards: true,
            in: wsId,
            state: &state,
            workingFrame: monitor.visibleFrame,
            gaps: gap
        )

        guard let settleBaseTime = engine.animationClock?.now() else {
            Issue.record("Expected animation clock for single-window target-frame regression test")
            return
        }

        let settleTime = settleBaseTime + 2.0
        state = settledLayoutState(from: state, column: column, settleTime: settleTime)
        let layout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: gap, vertical: gap),
            state: state,
            animationTime: settleTime
        )

        guard let renderedFrame = layout.frames[window.token],
              let targetFrame = engine.targetFrameForWindow(
                  window.token,
                  in: wsId,
                  state: state,
                  workingFrame: monitor.visibleFrame,
                  gaps: gap
              )
        else {
            Issue.record("Expected rendered and target frames for single-window target-frame regression test")
            return
        }

        #expect(renderedFrame == targetFrame)
    }

    @Test func defaultColumnWidthMatchingPresetKeepsSingleWindowAspectRatioUntilManualResize() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.presetColumnWidths = [
            .proportion(0.85),
            .proportion(1.0),
            .proportion(0.5)
        ]
        engine.defaultColumnWidth = 0.85
        engine.singleWindowAspectRatio = .ratio4x3
        engine.alwaysCenterSingleColumn = false
        let wsId = UUID()
        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        let monitor = makeLayoutPlanTestMonitor()

        guard let column = engine.column(of: window) else {
            Issue.record("Expected a column for preset-matching single-window ratio test")
            return
        }

        let layout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: 8, vertical: 8),
            state: ViewportState()
        )

        guard let frame = layout.frames[window.token] else {
            Issue.record("Expected a rendered frame for preset-matching single-window ratio test")
            return
        }

        #expect(column.presetWidthIdx == 0)
        #expect(!column.hasManualSingleWindowWidthOverride)
        #expect(frame == CGRect(x: 240, y: 0, width: 1440, height: 1080))
    }

    @Test func addingSecondWindowReturnsToNormalColumnSizingAfterSingleWindowOverride() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.singleWindowAspectRatio = .ratio4x3
        engine.alwaysCenterSingleColumn = false
        let wsId = UUID()
        let gap: CGFloat = 8
        let firstWindow = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        let monitor = makeLayoutPlanTestMonitor()

        let singleWindowLayout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: gap, vertical: gap),
            state: ViewportState()
        )

        let secondWindow = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: firstWindow.id)
        let twoWindowLayout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: gap, vertical: gap),
            state: ViewportState()
        )

        guard let singleFrame = singleWindowLayout.frames[firstWindow.token],
              let firstFrame = twoWindowLayout.frames[firstWindow.token],
              let secondFrame = twoWindowLayout.frames[secondWindow.token]
        else {
            Issue.record("Expected rendered frames before and after adding a second Niri window")
            return
        }

        let expectedColumnWidth = ((monitor.visibleFrame.width - gap) / 3).roundedToPhysicalPixel(scale: 2.0)

        #expect(engine.columns(in: wsId).count == 2)
        #expect(firstFrame.width < singleFrame.width)
        #expect(abs(firstFrame.width - expectedColumnWidth) < 0.6)
        #expect(abs(secondFrame.width - expectedColumnWidth) < 0.6)
        #expect(firstFrame.height == monitor.visibleFrame.height)
        #expect(secondFrame.height == monitor.visibleFrame.height)
    }

    @Test func additionalWindowUsesExplicitDefaultWidthWhenCreatingNewColumn() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.presetColumnWidths = [.proportion(0.85), .proportion(1.0), .proportion(0.5)]
        engine.defaultColumnWidth = 0.6
        let wsId = UUID()

        let firstWindow = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        let secondWindow = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: firstWindow.id)

        guard let column = engine.column(of: secondWindow) else {
            Issue.record("Expected new column for second window")
            return
        }

        #expect(engine.columns(in: wsId).count == 2)
        #expect(column.width == .proportion(0.6))
        #expect(column.presetWidthIdx == nil)
    }

    @Test func selectionFallbackAfterColumnRemoval() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)
        let w3 = engine.addWindow(handle: h3, to: wsId, afterSelection: w2.id)

        let cols = engine.columns(in: wsId)
        #expect(cols.count == 3)

        let middleColIdx = 1
        var state = ViewportState()
        state.activeColumnIndex = 0

        let result = engine.animateColumnsForRemoval(
            columnIndex: middleColIdx,
            in: wsId,
            state: &state,
            gaps: 8
        )

        #expect(result.fallbackSelectionId != nil)
        let fallbackNode = engine.findNode(by: result.fallbackSelectionId!)
        #expect(fallbackNode != nil)
        #expect(result.fallbackSelectionId != w2.id)
        let isW1OrW3 = result.fallbackSelectionId == w1.id || result.fallbackSelectionId == w3.id
        #expect(isW1OrW3)
    }

    @Test func viewportOffsetAdjustsForInsertionBeforeActive() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let _ = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)

        let cols = engine.columns(in: wsId)
        #expect(cols.count == 2)

        let workingWidth: CGFloat = 1000
        let gap: CGFloat = 8
        for col in cols {
            col.resolveAndCacheWidth(workingAreaWidth: workingWidth, gaps: gap)
        }

        var state = ViewportState()
        state.activeColumnIndex = 1
        state.viewOffsetPixels = .static(0)

        let h3 = makeTestHandle()
        engine.syncWindows(
            [h3, h1, h2],
            in: wsId,
            selectedNodeId: w1.id,
            focusedHandle: nil
        )

        let colsAfter = engine.columns(in: wsId)
        #expect(colsAfter.count == 3)

        let newNode = engine.findNode(for: h3)
        #expect(newNode != nil)

        if let newCol = engine.column(of: newNode!),
           let newColIdx = engine.columnIndex(of: newCol, in: wsId)
        {
            if newColIdx <= state.activeColumnIndex {
                newCol.resolveAndCacheWidth(workingAreaWidth: workingWidth, gaps: gap)
                let shiftAmount = newCol.cachedWidth + gap
                state.viewOffsetPixels.offset(delta: Double(-shiftAmount))
                state.activeColumnIndex += 1
            }
        }

        #expect(state.viewOffsetPixels.current() < 0)
        #expect(state.activeColumnIndex == 2)
    }

    @Test func constraintApplicationRespectsBounds() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()

        let h1 = makeTestHandle()
        let _ = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)

        let constraints = WindowSizeConstraints(
            minSize: CGSize(width: 400, height: 300),
            maxSize: CGSize(width: 800, height: 600),
            isFixed: false
        )
        engine.updateWindowConstraints(for: h1, constraints: constraints)

        let window = engine.findNode(for: h1)!
        #expect(window.constraints == constraints)
        #expect(window.constraints.minSize.width == 400)
        #expect(window.constraints.maxSize.width == 800)
    }

    @Test func solverRedistributesSpaceAfterMaxCapsWithoutReviolatingThem() {
        let outputs = NiriAxisSolver.solve(
            windows: [
                .init(
                    weight: 1,
                    minConstraint: 0,
                    maxConstraint: 100,
                    hasMaxConstraint: true,
                    isConstraintFixed: false,
                    hasFixedValue: false,
                    fixedValue: nil
                ),
                .init(
                    weight: 1,
                    minConstraint: 0,
                    maxConstraint: 400,
                    hasMaxConstraint: true,
                    isConstraintFixed: false,
                    hasFixedValue: false,
                    fixedValue: nil
                ),
                .init(
                    weight: 1,
                    minConstraint: 0,
                    maxConstraint: 0,
                    hasMaxConstraint: false,
                    isConstraintFixed: false,
                    hasFixedValue: false,
                    fixedValue: nil
                ),
            ],
            availableSpace: 1200,
            gapSize: 0
        )

        #expect(outputs.count == 3)
        #expect(abs(outputs[0].value - 100) < 0.001)
        #expect(abs(outputs[1].value - 400) < 0.001)
        #expect(abs(outputs[2].value - 700) < 0.001)
    }

    @Test func solverFixedOverflowDoesNotOverallocateAutoWindows() {
        let outputs = NiriAxisSolver.solve(
            windows: [
                .init(
                    weight: 0,
                    minConstraint: 80,
                    maxConstraint: 0,
                    hasMaxConstraint: false,
                    isConstraintFixed: false,
                    hasFixedValue: true,
                    fixedValue: 80
                ),
                .init(
                    weight: 1,
                    minConstraint: 0,
                    maxConstraint: 0,
                    hasMaxConstraint: false,
                    isConstraintFixed: false,
                    hasFixedValue: false,
                    fixedValue: nil
                ),
            ],
            availableSpace: 50,
            gapSize: 0
        )

        #expect(outputs.count == 2)
        #expect(abs(outputs[0].value - 50) < 0.001)
        #expect(outputs[0].wasConstrained == true)
        #expect(outputs[1].value == 0)
        #expect(outputs[1].wasConstrained == false)
        #expect(abs(outputs.map(\.value).reduce(0, +) - 50) < 0.001)
    }

    @Test func columnWidthDoesNotShrinkBelowRequiredFixedChildWidth() {
        let column = NiriContainer()

        let locked = NiriWindow(token: WindowToken(pid: 41, windowId: 4101))
        locked.constraints = .fixed(size: CGSize(width: 700, height: 320))

        let capped = NiriWindow(token: WindowToken(pid: 41, windowId: 4102))
        capped.constraints = WindowSizeConstraints(
            minSize: CGSize(width: 1, height: 1),
            maxSize: CGSize(width: 500, height: 0),
            isFixed: false
        )

        column.appendChild(locked)
        column.appendChild(capped)
        column.width = .proportion(1.0)
        column.resolveAndCacheWidth(workingAreaWidth: 1200, gaps: 0)

        #expect(abs(column.cachedWidth - 700) < 0.001)
    }

    @Test func syncWindowsIdempotency() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()

        engine.syncWindows([h1, h2, h3], in: wsId, selectedNodeId: nil)

        let colCount1 = engine.columns(in: wsId).count
        let windowIds1 = engine.root(for: wsId)!.windowIdSet

        engine.syncWindows([h1, h2, h3], in: wsId, selectedNodeId: nil)

        let colCount2 = engine.columns(in: wsId).count
        let windowIds2 = engine.root(for: wsId)!.windowIdSet

        #expect(colCount1 == colCount2)
        #expect(windowIds1 == windowIds2)
    }

    @Test func syncWindowsKeepsStableNodeForReobservedToken() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()

        let original = makeTestHandle(pid: 21)
        let refreshed = WindowHandle(
            id: original.id,
            pid: original.pid,
            axElement: AXUIElementCreateSystemWide()
        )

        engine.syncWindows([original], in: wsId, selectedNodeId: nil)
        let originalNodeId = engine.findNode(for: original.id)?.id

        engine.syncWindows([refreshed], in: wsId, selectedNodeId: nil)

        #expect(engine.root(for: wsId)?.allWindows.count == 1)
        #expect(engine.root(for: wsId)?.windowIdSet == Set([original.id]))
        #expect(engine.findNode(for: refreshed.id)?.id == originalNodeId)
    }

    @Test func rekeyWindowKeepsNodeAndSelectionStableAcrossSync() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()

        let handle1 = makeTestHandle(pid: 61)
        let handle2 = makeTestHandle(pid: 62)
        let handle3 = makeTestHandle(pid: 63)

        let firstWindow = engine.addWindow(handle: handle1, to: wsId, afterSelection: nil)
        let rekeyedWindow = engine.addWindow(handle: handle2, to: wsId, afterSelection: firstWindow.id)
        let _ = engine.addWindow(handle: handle3, to: wsId, afterSelection: rekeyedWindow.id)

        let replacementToken = WindowToken(pid: handle2.pid, windowId: handle2.windowId + 1000)
        let originalNodeId = rekeyedWindow.id

        #expect(engine.rekeyWindow(from: handle2.id, to: replacementToken))

        let removed = engine.syncWindows(
            [handle1.id, replacementToken, handle3.id],
            in: wsId,
            selectedNodeId: originalNodeId,
            focusedToken: handle3.id
        )

        #expect(removed.isEmpty)
        #expect(engine.findNode(for: handle2.id) == nil)
        #expect(engine.findNode(for: replacementToken)?.id == originalNodeId)
        #expect(engine.validateSelection(originalNodeId, in: wsId) == originalNodeId)
        #expect(engine.root(for: wsId)?.windowIdSet == Set([handle1.id, replacementToken, handle3.id]))
    }

    @Test func ensureSelectionVisibleMovesViewport() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)
        let w3 = engine.addWindow(handle: h3, to: wsId, afterSelection: w2.id)

        let workingFrame = CGRect(x: 0, y: 0, width: 500, height: 900)
        let gap: CGFloat = 8
        for col in engine.columns(in: wsId) {
            col.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gap)
        }

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        engine.ensureSelectionVisible(
            node: w3,
            in: wsId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )

        #expect(state.activeColumnIndex == 2)
    }

    @Test func ensureSelectionVisibleDoesNotShiftFullyVisibleViewportInNeverMode() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        engine.centerFocusedColumn = .never
        engine.alwaysCenterSingleColumn = false
        let wsId = UUID()

        let first = engine.addWindow(handle: makeTestHandle(pid: 301), to: wsId, afterSelection: nil)
        let second = engine.addWindow(handle: makeTestHandle(pid: 302), to: wsId, afterSelection: first.id)
        _ = engine.addWindow(handle: makeTestHandle(pid: 303), to: wsId, afterSelection: second.id)

        let workingFrame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let gap: CGFloat = 8
        let leftWidth = (workingFrame.width - gap) * (2.0 / 3.0)
        let rightWidth = (workingFrame.width - gap) / 3.0
        assignWidths(
            engine.columns(in: wsId),
            widths: [leftWidth, rightWidth, rightWidth]
        )

        var state = ViewportState()
        state.selectedNodeId = first.id
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        engine.ensureSelectionVisible(
            node: second,
            in: wsId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )

        let columns = engine.columns(in: wsId)
        let viewStart = state.columnX(at: state.activeColumnIndex, columns: columns, gap: gap)
            + state.viewOffsetPixels.target()

        #expect(state.activeColumnIndex == 1)
        #expect(abs(viewStart) < 0.1)
        #expect(abs(state.viewOffsetPixels.target() + leftWidth + gap) < 0.1)
    }

    @Test func ensureSelectionVisibleDoesNotShiftFullyVisibleViewportInOnOverflowMode() {
        struct Scenario {
            let label: String
            let visibleCount: Int
            let extraColumns: Int
            let initialActiveIndex: Int
            let targetIndex: Int
            let expectedViewStartIndex: Int
        }

        let scenarios = [
            Scenario(
                label: "visibleCount=2 first pair",
                visibleCount: 2,
                extraColumns: 2,
                initialActiveIndex: 0,
                targetIndex: 1,
                expectedViewStartIndex: 0
            ),
            Scenario(
                label: "visibleCount=2 middle pair forward",
                visibleCount: 2,
                extraColumns: 2,
                initialActiveIndex: 1,
                targetIndex: 2,
                expectedViewStartIndex: 1
            ),
            Scenario(
                label: "visibleCount=2 middle pair backward",
                visibleCount: 2,
                extraColumns: 2,
                initialActiveIndex: 2,
                targetIndex: 1,
                expectedViewStartIndex: 1
            ),
            Scenario(
                label: "visibleCount=2 last pair",
                visibleCount: 2,
                extraColumns: 2,
                initialActiveIndex: 2,
                targetIndex: 3,
                expectedViewStartIndex: 2
            ),
            Scenario(
                label: "visibleCount=3 shifted visible span",
                visibleCount: 3,
                extraColumns: 2,
                initialActiveIndex: 1,
                targetIndex: 3,
                expectedViewStartIndex: 1
            )
        ]

        for scenario in scenarios {
            let fixture = makeVisibleColumnFixture(
                visibleCount: scenario.visibleCount,
                extraColumns: scenario.extraColumns
            )
            fixture.engine.centerFocusedColumn = .onOverflow
            fixture.engine.alwaysCenterSingleColumn = false

            let columns = fixture.engine.columns(in: fixture.workspaceId)
            guard let columnWidth = columns.first?.cachedWidth else {
                Issue.record("Expected equal-width columns for \(scenario.label)")
                continue
            }

            let columnStride = columnWidth + fixture.gap
            let expectedViewStart = columnStride * CGFloat(scenario.expectedViewStartIndex)

            var state = ViewportState()
            state.selectedNodeId = fixture.windows[scenario.initialActiveIndex].id
            state.activeColumnIndex = scenario.initialActiveIndex
            state.viewOffsetPixels = .static(
                expectedViewStart
                    - state.columnX(
                        at: scenario.initialActiveIndex,
                        columns: columns,
                        gap: fixture.gap
                    )
            )

            fixture.engine.ensureSelectionVisible(
                node: fixture.windows[scenario.targetIndex],
                in: fixture.workspaceId,
                state: &state,
                workingFrame: fixture.monitor.visibleFrame,
                gaps: fixture.gap
            )

            #expect(state.activeColumnIndex == scenario.targetIndex, Comment(rawValue: scenario.label))
            #expect(
                abs(viewportStart(for: state, columns: columns, gap: fixture.gap) - expectedViewStart) < 0.1,
                Comment(rawValue: scenario.label)
            )
        }
    }

    @Test func ensureSelectionVisibleAlignsOffscreenViewportToExactVisibleSet() {
        struct Scenario {
            let label: String
            let centerMode: CenterFocusedColumn
            let initialActiveIndex: Int
            let initialViewStartIndex: Int
            let targetIndex: Int
            let expectedViewStartIndex: Int
        }

        let scenarios: [Scenario] = [
            .init(
                label: "never right",
                centerMode: .never,
                initialActiveIndex: 1,
                initialViewStartIndex: 0,
                targetIndex: 2,
                expectedViewStartIndex: 1
            ),
            .init(
                label: "never left",
                centerMode: .never,
                initialActiveIndex: 3,
                initialViewStartIndex: 3,
                targetIndex: 2,
                expectedViewStartIndex: 2
            ),
            .init(
                label: "onOverflow right",
                centerMode: .onOverflow,
                initialActiveIndex: 1,
                initialViewStartIndex: 0,
                targetIndex: 2,
                expectedViewStartIndex: 1
            ),
            .init(
                label: "onOverflow left",
                centerMode: .onOverflow,
                initialActiveIndex: 3,
                initialViewStartIndex: 3,
                targetIndex: 2,
                expectedViewStartIndex: 2
            ),
        ]

        for scenario in scenarios {
            let fixture = makeVisibleColumnFixture(visibleCount: 2, extraColumns: 2)
            fixture.engine.centerFocusedColumn = scenario.centerMode
            fixture.engine.alwaysCenterSingleColumn = false

            let columns = fixture.engine.columns(in: fixture.workspaceId)
            guard let columnWidth = columns.first?.cachedWidth else {
                Issue.record("Expected equal-width columns for \(scenario.label) offscreen alignment test")
                continue
            }

            let columnStride = columnWidth + fixture.gap
            let initialViewStart = CGFloat(scenario.initialViewStartIndex) * columnStride

            var state = ViewportState()
            state.selectedNodeId = fixture.windows[scenario.initialActiveIndex].id
            state.activeColumnIndex = scenario.initialActiveIndex
            state.viewOffsetPixels = .static(
                initialViewStart
                    - state.columnX(at: scenario.initialActiveIndex, columns: columns, gap: fixture.gap)
            )

            fixture.engine.ensureSelectionVisible(
                node: fixture.windows[scenario.targetIndex],
                in: fixture.workspaceId,
                state: &state,
                workingFrame: fixture.monitor.visibleFrame,
                gaps: fixture.gap
            )

            let expectedViewStart = CGFloat(scenario.expectedViewStartIndex) * columnStride
            let expectedTargetOffset = expectedViewStart
                - state.columnX(at: scenario.targetIndex, columns: columns, gap: fixture.gap)

            #expect(state.activeColumnIndex == scenario.targetIndex, Comment(rawValue: scenario.label))
            #expect(state.viewOffsetPixels.isAnimating, Comment(rawValue: scenario.label))
            #expect(
                abs(state.viewOffsetPixels.target() - expectedTargetOffset) < 0.1,
                Comment(rawValue: scenario.label)
            )
            #expect(
                abs(viewportStart(for: state, columns: columns, gap: fixture.gap) - expectedViewStart) < 0.1,
                Comment(rawValue: scenario.label)
            )
        }
    }

    @Test func moveWindowHorizontalRightExpelsFocusedWindowIntoNewColumn() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let firstHandle = makeTestHandle(pid: 71)
        let focusedHandle = makeTestHandle(pid: 72)
        let rightHandle = makeTestHandle(pid: 73)
        let firstWindow = NiriWindow(token: firstHandle.id)
        let focusedWindow = NiriWindow(token: focusedHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(firstWindow)
        leftColumn.appendChild(focusedWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[firstHandle.id] = firstWindow
        engine.tokenToNode[focusedHandle.id] = focusedWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 0

        let moved = engine.moveWindow(
            focusedWindow,
            direction: .right,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(moved)
        #expect(columns.count == 3)
        #expect(columns[0].windowNodes.map(\.token) == [firstHandle.id])
        #expect(columns[1].windowNodes.map(\.token) == [focusedHandle.id])
        #expect(columns[2].windowNodes.map(\.token) == [rightHandle.id])
    }

    @Test func moveWindowHorizontalRightConsumesSingleWindowColumnIntoNeighbor() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let leftHandle = makeTestHandle(pid: 81)
        let rightHandle = makeTestHandle(pid: 82)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 0

        let moved = engine.moveWindow(
            leftWindow,
            direction: .right,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(moved)
        #expect(columns.count == 1)
        #expect(columns[0] === rightColumn)
        #expect(columns[0].windowNodes.map(\.token) == [leftHandle.id, rightHandle.id])
        #expect(columns[0].hasMoveAnimationRunning)

        let windowOffset = leftWindow.moveXAnimation?.fromOffset
        #expect(windowOffset != nil)
        #expect(windowOffset! < -300)

        let columnOffset = rightColumn.moveAnimation?.fromOffset
        #expect(columnOffset != nil)
        #expect(columnOffset! > 300)
    }

    @Test func moveWindowHorizontalRightConsumesSingleWindowColumnIntoNeighborWhenMonitorOverrideAllowsIt() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()
        let monitor = makeTestMonitor(displayId: 601, name: "Override", x: 0)
        attachWorkspace(
            wsId,
            to: monitor,
            engine: engine,
            resolvedSettings: resolvedSettings(for: engine, maxWindowsPerColumn: 2)
        )

        guard let root = engine.root(for: wsId),
              let leftColumn = root.columns.first
        else {
            Issue.record("Expected mapped workspace root for consume override test")
            return
        }

        let rightColumn = NiriContainer()
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let leftHandle = makeTestHandle(pid: 181)
        let rightHandle = makeTestHandle(pid: 182)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 0

        let moved = engine.moveWindow(
            leftWindow,
            direction: .right,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(moved)
        #expect(columns.count == 1)
        #expect(columns[0] === rightColumn)
        #expect(columns[0].windowNodes.map(\.token) == [leftHandle.id, rightHandle.id])
    }

    @Test func moveWindowHorizontalRightDoesNotConsumeSingleWindowColumnIntoNeighborWithoutMonitorOverride() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()
        let monitor = makeTestMonitor(displayId: 602, name: "GlobalOnly", x: 0)
        attachWorkspace(wsId, to: monitor, engine: engine)

        guard let root = engine.root(for: wsId),
              let leftColumn = root.columns.first
        else {
            Issue.record("Expected mapped workspace root for consume fallback test")
            return
        }

        let rightColumn = NiriContainer()
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let leftHandle = makeTestHandle(pid: 183)
        let rightHandle = makeTestHandle(pid: 184)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 0

        let moved = engine.moveWindow(
            leftWindow,
            direction: .right,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(!moved)
        #expect(columns.count == 2)
        #expect(columns[0].windowNodes.map(\.token) == [leftHandle.id])
        #expect(columns[1].windowNodes.map(\.token) == [rightHandle.id])
    }

    @Test func moveWindowHorizontalLeftConsumesSingleWindowColumnIntoNeighbor() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let leftHandle = makeTestHandle(pid: 83)
        let rightHandle = makeTestHandle(pid: 84)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 1

        let moved = engine.moveWindow(
            rightWindow,
            direction: .left,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(moved)
        #expect(columns.count == 1)
        #expect(columns[0] === leftColumn)
        #expect(columns[0].windowNodes.map(\.token) == [rightHandle.id, leftHandle.id])
        #expect(!columns[0].hasMoveAnimationRunning)

        let windowOffset = rightWindow.moveXAnimation?.fromOffset
        #expect(windowOffset != nil)
        #expect(windowOffset! > 300)
    }

    @Test func ensureSelectionVisibleUsesExplicitPreviousActivePositionAfterColumnRemoval() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        engine.centerFocusedColumn = .never
        engine.alwaysCenterSingleColumn = false
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)
        assignWidths(root.columns, widths: [300, 500])

        let leftHandle = makeTestHandle(pid: 85)
        let rightHandle = makeTestHandle(pid: 86)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 1
        state.viewOffsetPixels = .static(0)

        let previousActivePosition = state.columnX(
            at: state.activeColumnIndex,
            columns: engine.columns(in: wsId),
            gap: 8
        )

        leftColumn.remove()

        engine.ensureSelectionVisible(
            node: rightWindow,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 700, height: 900),
            gaps: 8,
            fromContainerIndex: 1,
            previousActiveContainerPosition: previousActivePosition
        )

        if case let .spring(animation) = state.viewOffsetPixels {
            #expect(abs(animation.from - Double(previousActivePosition)) < 0.1)
        } else {
            #expect(Bool(false))
        }
    }

    @Test func moveWindowHorizontalLeftNoOpsAtEdgeWithoutInfiniteLoop() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, infiniteLoop: false)
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let leftHandle = makeTestHandle(pid: 91)
        let rightHandle = makeTestHandle(pid: 92)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 0

        let moved = engine.moveWindow(
            leftWindow,
            direction: .left,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(!moved)
        #expect(columns.count == 2)
        #expect(columns[0].windowNodes.map(\.token) == [leftHandle.id])
        #expect(columns[1].windowNodes.map(\.token) == [rightHandle.id])
    }

    @Test func moveWindowHorizontalLeftWrapsAtEdgeWhenInfiniteLoopIsEnabled() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, infiniteLoop: true)
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let leftHandle = makeTestHandle(pid: 101)
        let rightHandle = makeTestHandle(pid: 102)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 0

        let moved = engine.moveWindow(
            leftWindow,
            direction: .left,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(moved)
        #expect(columns.count == 1)
        #expect(columns[0].windowNodes.map(\.token) == [leftHandle.id, rightHandle.id])
    }

    @Test func moveWindowHorizontalLeftWrapsAtEdgeWhenMonitorOverrideEnablesInfiniteLoop() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, infiniteLoop: false)
        let wsId = UUID()
        let monitor = makeTestMonitor(displayId: 701, name: "Wrap", x: 0)
        attachWorkspace(
            wsId,
            to: monitor,
            engine: engine,
            resolvedSettings: resolvedSettings(for: engine, infiniteLoop: true)
        )

        guard let root = engine.root(for: wsId),
              let leftColumn = root.columns.first
        else {
            Issue.record("Expected mapped workspace root for infinite-loop override test")
            return
        }

        let rightColumn = NiriContainer()
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let leftHandle = makeTestHandle(pid: 191)
        let rightHandle = makeTestHandle(pid: 192)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 0

        let moved = engine.moveWindow(
            leftWindow,
            direction: .left,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(moved)
        #expect(columns.count == 1)
        #expect(columns[0].windowNodes.map(\.token) == [leftHandle.id, rightHandle.id])
    }

    @Test func ensureSelectionVisibleUsesResolvedMonitorAlwaysCenterSingleColumn() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        engine.centerFocusedColumn = .never
        engine.alwaysCenterSingleColumn = false
        let wsId = UUID()
        let monitor = makeTestMonitor(displayId: 801, name: "CenterSingle", x: 0)
        attachWorkspace(
            wsId,
            to: monitor,
            engine: engine,
            resolvedSettings: resolvedSettings(
                for: engine,
                centerFocusedColumn: .never,
                alwaysCenterSingleColumn: true
            )
        )

        let window = engine.addWindow(handle: makeTestHandle(pid: 211), to: wsId, afterSelection: nil)
        assignFixedWidths(engine.columns(in: wsId))

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        engine.ensureSelectionVisible(
            node: window,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        #expect(abs(state.viewOffsetPixels.target() + 400) < 0.1)
    }

    @Test func ensureSelectionVisibleUsesResolvedMonitorCenterFocusedColumn() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        engine.centerFocusedColumn = .never
        engine.alwaysCenterSingleColumn = false
        let wsId = UUID()
        let monitor = makeTestMonitor(displayId: 802, name: "CenterMode", x: 0)
        attachWorkspace(
            wsId,
            to: monitor,
            engine: engine,
            resolvedSettings: resolvedSettings(
                for: engine,
                centerFocusedColumn: .always,
                alwaysCenterSingleColumn: false
            )
        )

        let first = engine.addWindow(handle: makeTestHandle(pid: 212), to: wsId, afterSelection: nil)
        let second = engine.addWindow(handle: makeTestHandle(pid: 213), to: wsId, afterSelection: first.id)
        assignFixedWidths(engine.columns(in: wsId))

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        engine.ensureSelectionVisible(
            node: second,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        #expect(abs(state.viewOffsetPixels.target() + 604) < 0.1)
    }

    @Test func moveWindowVerticalKeepsInColumnReorderBehavior() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let column = NiriContainer()
        root.appendChild(column)
        assignFixedWidths(root.columns)

        let firstHandle = makeTestHandle(pid: 111)
        let focusedHandle = makeTestHandle(pid: 112)
        let lastHandle = makeTestHandle(pid: 113)
        let firstWindow = NiriWindow(token: firstHandle.id)
        let focusedWindow = NiriWindow(token: focusedHandle.id)
        let lastWindow = NiriWindow(token: lastHandle.id)

        column.appendChild(firstWindow)
        column.appendChild(focusedWindow)
        column.appendChild(lastWindow)

        engine.tokenToNode[firstHandle.id] = firstWindow
        engine.tokenToNode[focusedHandle.id] = focusedWindow
        engine.tokenToNode[lastHandle.id] = lastWindow

        let beforeMove = column.windowNodes.map(\.token)
        var state = ViewportState()

        let moved = engine.moveWindow(
            focusedWindow,
            direction: .up,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let afterMove = column.windowNodes.map(\.token)
        #expect(moved)
        #expect(beforeMove == [firstHandle.id, focusedHandle.id, lastHandle.id])
        #expect(afterMove == [firstHandle.id, lastHandle.id, focusedHandle.id])
    }

    @Test @MainActor func horizontalConsumeStartsAnimationLoopAndSettlesMovedWindowFrame() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for horizontal consume regression test")
            return
        }

        controller.enableNiriLayout(
            maxWindowsPerColumn: 3,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        controller.updateNiriConfig(
            maxVisibleColumns: 3,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.layoutRefreshController.stopAllScrollAnimations()
        controller.syncMonitorsToNiriEngine()

        let leftWindowId = 811
        let focusedWindowId = 812
        let rightWindowId = 813

        let leftToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: leftWindowId)
        let focusedToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: focusedWindowId)
        let rightToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: rightWindowId)

        _ = controller.workspaceManager.setManagedFocus(focusedToken, in: workspaceId, onMonitor: monitor.id)

        guard let engine = controller.niriEngine,
              let focusedHandle = controller.workspaceManager.handle(for: focusedToken)
        else {
            Issue.record("Expected Niri engine and focused handle for horizontal consume regression test")
            return
        }

        let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
        _ = engine.syncWindows(
            handles,
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: focusedHandle
        )

        let columns = engine.columns(in: workspaceId)
        guard columns.count == 3 else {
            Issue.record("Expected three visible columns before consuming the focused window")
            return
        }
        assignFixedWidths(columns)

        guard let focusedNode = engine.findNode(for: focusedToken) else {
            Issue.record("Expected focused node in Niri engine before consuming window")
            return
        }

        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: focusedNode.id,
            focusedToken: focusedToken,
            in: workspaceId,
            onMonitor: monitor.id
        )
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = focusedNode.id
            state.activeColumnIndex = 1
            state.viewOffsetPixels = .static(0)
        }

        controller.commandHandler.handleCommand(.move(.right))

        #expect(controller.niriLayoutHandler.scrollAnimationByDisplay[monitor.displayId] == workspaceId)

        await waitForLayoutPlanRefreshWork(on: controller)

        let settleTime = (engine.animationClock?.now() ?? 0) + 5.0
        controller.niriLayoutHandler.tickScrollAnimation(targetTime: settleTime, displayId: monitor.displayId)

        let movedColumns = engine.columns(in: workspaceId)
        #expect(movedColumns.count == 2)
        #expect(movedColumns[0].windowNodes.map(\.token) == [leftToken])
        #expect(movedColumns[1].windowNodes.map(\.token) == [focusedToken, rightToken])
        #expect(controller.niriLayoutHandler.scrollAnimationByDisplay[monitor.displayId] == nil)

        guard let movedNode = engine.findNode(for: focusedToken),
              let settledFrame = movedNode.renderedFrame ?? movedNode.frame,
              let appliedFrame = controller.axManager.lastAppliedFrame(for: focusedWindowId)
        else {
            Issue.record("Expected the consumed focused window to receive a settled visible frame")
            return
        }

        let workingFrame = controller.insetWorkingFrame(for: monitor)
        #expect(appliedFrame == settledFrame)
        #expect(workingFrame.intersects(appliedFrame))
    }

    @Test @MainActor func horizontalConsumeIntoTabbedColumnBottomInsertsAndActivatesConsumedWindow() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for tabbed horizontal consume regression test")
            return
        }

        controller.enableNiriLayout(
            maxWindowsPerColumn: 4,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        controller.updateNiriConfig(
            maxVisibleColumns: 3,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.layoutRefreshController.stopAllScrollAnimations()
        controller.syncMonitorsToNiriEngine()

        let consumedWindowId = 821
        let existingBottomWindowId = 822
        let existingTopWindowId = 823

        let consumedToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: consumedWindowId)
        let existingBottomToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: existingBottomWindowId
        )
        let existingTopToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: existingTopWindowId
        )

        _ = controller.workspaceManager.setManagedFocus(consumedToken, in: workspaceId, onMonitor: monitor.id)

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri engine for tabbed horizontal consume regression test")
            return
        }

        let root = NiriRoot(workspaceId: workspaceId)
        engine.roots[workspaceId] = root
        engine.ensureMonitor(for: monitor.id, monitor: monitor).workspaceRoots[workspaceId] = root

        let sourceColumn = NiriContainer()
        let targetColumn = NiriContainer()
        targetColumn.displayMode = .tabbed
        root.appendChild(sourceColumn)
        root.appendChild(targetColumn)
        assignFixedWidths(root.columns)

        let consumedWindow = NiriWindow(token: consumedToken)
        let existingBottomWindow = NiriWindow(token: existingBottomToken)
        let existingTopWindow = NiriWindow(token: existingTopToken)

        sourceColumn.appendChild(consumedWindow)
        targetColumn.appendChild(existingBottomWindow)
        targetColumn.appendChild(existingTopWindow)
        targetColumn.setActiveTileIdx(1)
        engine.updateTabbedColumnVisibility(column: targetColumn)

        engine.tokenToNode[consumedToken] = consumedWindow
        engine.tokenToNode[existingBottomToken] = existingBottomWindow
        engine.tokenToNode[existingTopToken] = existingTopWindow

        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: consumedWindow.id,
            focusedToken: consumedToken,
            in: workspaceId,
            onMonitor: monitor.id
        )
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = consumedWindow.id
            state.activeColumnIndex = 0
            state.viewOffsetPixels = .static(0)
        }

        controller.commandHandler.handleCommand(.move(.right))
        await waitForLayoutPlanRefreshWork(on: controller)

        let columns = engine.columns(in: workspaceId)
        #expect(columns.count == 1)
        #expect(columns[0].windowNodes.map(\.token) == [consumedToken, existingBottomToken, existingTopToken])
        #expect(columns[0].activeTileIdx == 0)
        #expect(columns[0].activeWindow?.token == consumedToken)

        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(state.selectedNodeId == consumedWindow.id)
        #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == consumedToken)
        #expect(controller.workspaceManager.focusedToken == consumedToken)

        #expect(!consumedWindow.isHiddenInTabbedMode)
        #expect(existingBottomWindow.isHiddenInTabbedMode)
        #expect(existingTopWindow.isHiddenInTabbedMode)
    }

    @Test @MainActor func focusNeighborInTabbedColumnFollowsVisualTabOrder() async {
        let fixture = await makeSingleColumnFocusFixture(displayMode: .tabbed)

        fixture.controller.niriLayoutHandler.focusNeighbor(direction: .up)
        await waitForLayoutPlanRefreshWork(on: fixture.controller)

        #expect(fixture.controller.workspaceManager.preferredFocusToken(in: fixture.workspaceId) == fixture.topToken)
        #expect(fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId).selectedNodeId == fixture.topWindow.id)
        #expect(fixture.column.activeTileIdx == 2)
        #expect(fixture.column.activeVisualTileIdx == 0)
        #expect(!fixture.topWindow.isHiddenInTabbedMode)
        #expect(fixture.bottomWindow.isHiddenInTabbedMode)

        fixture.controller.niriLayoutHandler.focusNeighbor(direction: .down)
        await waitForLayoutPlanRefreshWork(on: fixture.controller)

        #expect(fixture.controller.workspaceManager.preferredFocusToken(in: fixture.workspaceId) == fixture.middleToken)
        #expect(fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId).selectedNodeId == fixture.middleWindow.id)
        #expect(fixture.column.activeTileIdx == 1)
        #expect(fixture.column.activeVisualTileIdx == 1)
        #expect(!fixture.middleWindow.isHiddenInTabbedMode)
    }

    @Test @MainActor func focusNeighborInNonTabbedColumnPreservesExistingInColumnOrder() async {
        let fixture = await makeSingleColumnFocusFixture(displayMode: .normal)

        fixture.controller.niriLayoutHandler.focusNeighbor(direction: .up)
        await waitForLayoutPlanRefreshWork(on: fixture.controller)

        #expect(fixture.controller.workspaceManager.preferredFocusToken(in: fixture.workspaceId) == fixture.topToken)
        #expect(fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId).selectedNodeId == fixture.topWindow.id)

        fixture.controller.niriLayoutHandler.focusNeighbor(direction: .down)
        await waitForLayoutPlanRefreshWork(on: fixture.controller)

        #expect(fixture.controller.workspaceManager.preferredFocusToken(in: fixture.workspaceId) == fixture.middleToken)
        #expect(fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId).selectedNodeId == fixture.middleWindow.id)
    }

    @Test @MainActor func selectTabInNiriMapsVisualOverlayIndicesBackToStorageOrder() async {
        let fixture = await makeSingleColumnFocusFixture(displayMode: .tabbed)

        fixture.column.setActiveTileIdx(0)
        fixture.engine.updateTabbedColumnVisibility(column: fixture.column)
        _ = fixture.controller.workspaceManager.setManagedFocus(
            fixture.bottomToken,
            in: fixture.workspaceId,
            onMonitor: fixture.monitor.id
        )
        _ = fixture.controller.workspaceManager.commitWorkspaceSelection(
            nodeId: fixture.bottomWindow.id,
            focusedToken: fixture.bottomToken,
            in: fixture.workspaceId,
            onMonitor: fixture.monitor.id
        )
        fixture.controller.workspaceManager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.selectedNodeId = fixture.bottomWindow.id
        }

        #expect(fixture.column.visualTileIndex(forStorageTileIndex: 0) == 2)
        #expect(fixture.column.storageTileIndex(forVisualTileIndex: 0) == 2)
        #expect(fixture.column.activeVisualTileIdx == 2)

        fixture.controller.niriLayoutHandler.selectTabInNiri(
            workspaceId: fixture.workspaceId,
            columnId: fixture.column.id,
            visualIndex: 0
        )

        #expect(fixture.column.activeTileIdx == 2)
        #expect(fixture.column.activeVisualTileIdx == 0)
        #expect(fixture.column.activeWindow?.token == fixture.topToken)
        #expect(fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId).selectedNodeId == fixture.topWindow.id)
        #expect(!fixture.topWindow.isHiddenInTabbedMode)
        #expect(fixture.bottomWindow.isHiddenInTabbedMode)
    }

    @Test func cleanupRemovedMonitorKeepsWorkspaceRootAuthoritativeForReattach() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let oldMonitor = makeTestMonitor(displayId: 100, name: "Old", x: 0)
        let newMonitor = makeTestMonitor(displayId: 200, name: "New", x: 1920)
        let wsId = UUID()

        let oldNiriMonitor = engine.ensureMonitor(for: oldMonitor.id, monitor: oldMonitor)
        let rescuedRoot = engine.ensureRoot(for: wsId)
        oldNiriMonitor.workspaceRoots[wsId] = rescuedRoot

        engine.cleanupRemovedMonitor(oldMonitor.id)
        #expect(engine.monitor(for: oldMonitor.id) == nil)
        #expect(engine.root(for: wsId) === rescuedRoot)

        engine.moveWorkspace(wsId, to: newMonitor.id, monitor: newMonitor)

        let newNiriMonitor = engine.monitor(for: newMonitor.id)
        #expect(newNiriMonitor != nil)
        #expect(newNiriMonitor?.workspaceRoots[wsId] != nil)
        if let restoredRoot = newNiriMonitor?.workspaceRoots[wsId] {
            #expect(restoredRoot === rescuedRoot)
        }
    }

    @Test @MainActor func syncMonitorsToNiriEngineRemovesStaleWorkspaceRootDuplicates() async {
        let primaryMonitor = makeLayoutPlanTestMonitor(displayId: 100, name: "Primary", x: 0, width: 1600, height: 900)
        let secondaryMonitor = makeLayoutPlanTestMonitor(displayId: 200, name: "Secondary", x: 1600, width: 1600, height: 900)
        let fixture = makeTwoMonitorLayoutPlanTestController(
            primaryMonitor: primaryMonitor,
            secondaryMonitor: secondaryMonitor
        )
        let controller = fixture.controller

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        guard let engine = controller.niriEngine,
              let primaryRoot = engine.root(for: fixture.primaryWorkspaceId),
              let secondaryRoot = engine.root(for: fixture.secondaryWorkspaceId),
              let primaryWorkspaceMonitorId = controller.workspaceManager.monitorId(for: fixture.primaryWorkspaceId),
              let secondaryWorkspaceMonitorId = controller.workspaceManager.monitorId(for: fixture.secondaryWorkspaceId),
              let primaryOwningMonitor = engine.monitor(for: primaryWorkspaceMonitorId),
              let secondaryOwningMonitor = engine.monitor(for: secondaryWorkspaceMonitorId),
              let primaryNonOwningMonitor = engine.monitors.values.first(where: { $0.id != primaryWorkspaceMonitorId }),
              let secondaryNonOwningMonitor = engine.monitors.values.first(where: { $0.id != secondaryWorkspaceMonitorId })
        else {
            Issue.record("Expected Niri engine and monitor roots for stale-root sync test")
            return
        }

        primaryNonOwningMonitor.workspaceRoots[fixture.primaryWorkspaceId] = primaryRoot
        secondaryNonOwningMonitor.workspaceRoots[fixture.secondaryWorkspaceId] = secondaryRoot
        #expect(primaryOwningMonitor.workspaceRoots[fixture.primaryWorkspaceId] === primaryRoot)
        #expect(primaryNonOwningMonitor.workspaceRoots[fixture.primaryWorkspaceId] === primaryRoot)
        #expect(secondaryOwningMonitor.workspaceRoots[fixture.secondaryWorkspaceId] === secondaryRoot)
        #expect(secondaryNonOwningMonitor.workspaceRoots[fixture.secondaryWorkspaceId] === secondaryRoot)

        controller.syncMonitorsToNiriEngine()

        #expect(engine.monitorContaining(workspace: fixture.primaryWorkspaceId) == controller.workspaceManager.monitorId(for: fixture.primaryWorkspaceId))
        #expect(engine.monitorContaining(workspace: fixture.secondaryWorkspaceId) == controller.workspaceManager.monitorId(for: fixture.secondaryWorkspaceId))
        #expect(engine.monitor(for: primaryWorkspaceMonitorId)?.workspaceRoots[fixture.primaryWorkspaceId] === primaryRoot)
        #expect(primaryNonOwningMonitor.workspaceRoots[fixture.primaryWorkspaceId] == nil)
        #expect(engine.monitor(for: secondaryWorkspaceMonitorId)?.workspaceRoots[fixture.secondaryWorkspaceId] === secondaryRoot)
        #expect(secondaryNonOwningMonitor.workspaceRoots[fixture.secondaryWorkspaceId] == nil)
    }

    @Test func syncWorkspaceAssignmentsPreservesNoOpOwnershipWhilePruningStaleCopies() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let monitors = makeVerticalStackedTestMonitors()
        let lowerWorkspaceId = UUID()
        let upperWorkspaceId = UUID()

        engine.moveWorkspace(lowerWorkspaceId, to: monitors.lower.id, monitor: monitors.lower)
        engine.moveWorkspace(upperWorkspaceId, to: monitors.upper.id, monitor: monitors.upper)

        guard let lowerRoot = engine.root(for: lowerWorkspaceId),
              let upperRoot = engine.root(for: upperWorkspaceId),
              let lowerMonitor = engine.monitor(for: monitors.lower.id),
              let upperMonitor = engine.monitor(for: monitors.upper.id)
        else {
            Issue.record("Expected existing monitor ownership before no-op sync test")
            return
        }

        upperMonitor.workspaceRoots[lowerWorkspaceId] = lowerRoot
        lowerMonitor.workspaceRoots[upperWorkspaceId] = upperRoot

        engine.syncWorkspaceAssignments([
            (workspaceId: lowerWorkspaceId, monitor: monitors.lower),
            (workspaceId: upperWorkspaceId, monitor: monitors.upper),
        ])

        #expect(lowerMonitor.workspaceRoots[lowerWorkspaceId] === lowerRoot)
        #expect(upperMonitor.workspaceRoots[upperWorkspaceId] === upperRoot)
        #expect(lowerMonitor.workspaceRoots[upperWorkspaceId] == nil)
        #expect(upperMonitor.workspaceRoots[lowerWorkspaceId] == nil)
    }

    @Test func moveWorkspaceDoesNotPruneUnrelatedWorkspaceRoots() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let monitors = makeHorizontalNeighboringTestMonitors()
        let movedWorkspaceId = UUID()
        let untouchedWorkspaceId = UUID()

        engine.moveWorkspace(movedWorkspaceId, to: monitors.primary.id, monitor: monitors.primary)
        engine.moveWorkspace(untouchedWorkspaceId, to: monitors.primary.id, monitor: monitors.primary)

        guard let movedRoot = engine.root(for: movedWorkspaceId),
              let untouchedRoot = engine.root(for: untouchedWorkspaceId),
              let primaryMonitor = engine.monitor(for: monitors.primary.id)
        else {
            Issue.record("Expected roots and primary monitor before single-workspace move regression test")
            return
        }

        engine.moveWorkspace(movedWorkspaceId, to: monitors.secondary.id, monitor: monitors.secondary)

        guard let secondaryMonitor = engine.monitor(for: monitors.secondary.id) else {
            Issue.record("Expected secondary monitor after moving one workspace")
            return
        }

        #expect(engine.monitorContaining(workspace: movedWorkspaceId) == monitors.secondary.id)
        #expect(engine.monitorContaining(workspace: untouchedWorkspaceId) == monitors.primary.id)
        #expect(primaryMonitor.workspaceRoots[movedWorkspaceId] == nil)
        #expect(primaryMonitor.workspaceRoots[untouchedWorkspaceId] === untouchedRoot)
        #expect(secondaryMonitor.workspaceRoots[movedWorkspaceId] === movedRoot)
        #expect(secondaryMonitor.workspaceRoots[untouchedWorkspaceId] == nil)
    }

    @Test func moveWindowToWorkspaceUsesExplicitDefaultWidthForTargetColumn() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.presetColumnWidths = [.proportion(0.85), .proportion(1.0), .proportion(0.5)]
        engine.defaultColumnWidth = 0.7
        let sourceWorkspaceId = UUID()
        let targetWorkspaceId = UUID()

        let window = engine.addWindow(handle: makeTestHandle(), to: sourceWorkspaceId, afterSelection: nil)
        var sourceState = ViewportState()
        var targetState = ViewportState()

        let moved = engine.moveWindowToWorkspace(
            window,
            from: sourceWorkspaceId,
            to: targetWorkspaceId,
            sourceState: &sourceState,
            targetState: &targetState
        )

        guard let targetColumn = engine.columns(in: targetWorkspaceId).first else {
            Issue.record("Expected target column after workspace move")
            return
        }

        #expect(moved != nil)
        #expect(targetColumn.width == .proportion(0.7))
        #expect(targetColumn.presetWidthIdx == nil)
    }

    @Test func workspaceSwitchAnimationUsesSnapshotOrdering() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let monitor = makeTestMonitor(displayId: 300, name: "Main", x: 0)
        let ws1 = UUID()
        let ws2 = UUID()
        let handle1 = makeTestHandle(pid: 11)
        let handle2 = makeTestHandle(pid: 12)

        let niriMonitor = engine.ensureMonitor(for: monitor.id, monitor: monitor)
        niriMonitor.animationClock = AnimationClock()

        _ = engine.addWindow(handle: handle1, to: ws1, afterSelection: nil)
        _ = engine.addWindow(handle: handle2, to: ws2, afterSelection: nil)
        engine.moveWorkspace(ws1, to: monitor.id, monitor: monitor)
        engine.moveWorkspace(ws2, to: monitor.id, monitor: monitor)

        niriMonitor.startWorkspaceSwitch(
            orderedWorkspaceIds: [ws1, ws2],
            from: ws1,
            to: ws2,
            animated: true
        )

        guard let time = niriMonitor.animationClock?.now() else {
            Issue.record("Expected animation clock for workspace switch test")
            return
        }
        let state = ViewportState()
        let gaps = LayoutGaps(horizontal: 8, vertical: 8)

        let layout1 = engine.calculateCombinedLayoutWithVisibility(
            in: ws1,
            monitor: monitor,
            gaps: gaps,
            state: state,
            animationTime: time
        )
        let layout2 = engine.calculateCombinedLayoutWithVisibility(
            in: ws2,
            monitor: monitor,
            gaps: gaps,
            state: state,
            animationTime: time
        )

        #expect(niriMonitor.workspaceSwitch?.fromWorkspaceId == ws1)
        #expect(niriMonitor.workspaceSwitch?.toWorkspaceId == ws2)
        #expect(niriMonitor.workspaceSwitch?.orderedWorkspaceIds == [ws1, ws2])
        #expect(layout1.frames[handle1.id]?.minX == 0)
        #expect((layout2.frames[handle2.id]?.minX ?? 0) > 0)
    }

    @Test @MainActor func relayoutPlanUsesResolvedMonitorSingleWindowAspectRatio() async throws {
        let monitor = makeLayoutPlanTestMonitor(name: "SquareTest")
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing active workspace for Niri settings test")
            return
        }

        controller.enableNiriLayout(
            maxWindowsPerColumn: 3,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        controller.updateNiriConfig(
            maxVisibleColumns: 3,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false,
            singleWindowAspectRatio: .ratio4x3
        )
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 881)

        let baselinePlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let baselinePlan = baselinePlans.first,
              let baselineFrame = baselinePlan.diff.frameChanges.first(where: { $0.token == token })?.frame
        else {
            Issue.record("Expected a baseline Niri frame for the single window")
            return
        }

        controller.settings.updateNiriSettings(
            MonitorNiriSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                singleWindowAspectRatio: .square
            )
        )
        controller.updateMonitorNiriSettings()

        let overridePlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let overridePlan = overridePlans.first,
              let overrideFrame = overridePlan.diff.frameChanges.first(where: { $0.token == token })?.frame
        else {
            Issue.record("Expected a Niri frame after applying monitor override settings")
            return
        }

        #expect(baselineFrame.width > overrideFrame.width)
        #expect(abs(overrideFrame.width - overrideFrame.height) < 0.5)
    }

    @Test @MainActor func snapshotPlanIncludesViewportPatchAndActivationForNewWindow() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for Niri plan test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()
        controller.niriEngine?.presetColumnWidths = [.proportion(1.0), .proportion(0.5)]

        let firstToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 401)
        _ = controller.workspaceManager.setManagedFocus(firstToken, in: workspaceId, onMonitor: monitor.id)

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        let newToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 402)

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let plan = plans.first else {
            Issue.record("Expected a Niri layout plan for the active workspace")
            return
        }

        #expect(plan.sessionPatch.viewportState != nil)
        #expect(plan.sessionPatch.rememberedFocusToken == newToken)
        #expect(hasNiriScrollDirective(plan.animationDirectives, workspaceId: workspaceId))
        #expect(hasActivationDirective(plan.animationDirectives, token: newToken))
    }

    @Test @MainActor func executingActivateWindowPlanPreservesPendingSelectionAndViewport() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for pending-focus relayout regression test")
            return
        }

        controller.setBordersEnabled(true)
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        controller.updateNiriConfig(
            maxVisibleColumns: 1,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()
        controller.niriEngine?.presetColumnWidths = [.proportion(1.0), .proportion(1.0)]

        let firstToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 403)
        _ = controller.workspaceManager.setManagedFocus(firstToken, in: workspaceId, onMonitor: monitor.id)

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)
        await waitForLayoutPlanRefreshWork(on: controller)

        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        let newToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 404)

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let plan = plans.first,
              let newNode = controller.niriEngine?.findNode(for: newToken)
        else {
            Issue.record("Expected a Niri plan and node for pending-focus relayout regression test")
            return
        }

        #expect(plan.sessionPatch.rememberedFocusToken == newToken)
        #expect(plan.sessionPatch.viewportState?.selectedNodeId == newNode.id)
        #expect(plan.sessionPatch.viewportState?.activeColumnIndex == 1)
        #expect(hasActivationDirective(plan.animationDirectives, token: newToken))

        controller.layoutRefreshController.executeLayoutPlans(plans)
        await waitForLayoutPlanRefreshWork(on: controller)

        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(controller.workspaceManager.focusedToken == firstToken)
        #expect(controller.workspaceManager.pendingFocusedToken == newToken)
        #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == newToken)
        #expect(state.selectedNodeId == newNode.id)
        #expect(state.activeColumnIndex == 1)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 403)
    }

    @Test @MainActor func snapshotPlanEmitsHideDiffForOffscreenWindows() async throws {
        let monitor = makeLayoutPlanTestMonitor(width: 1600, height: 900)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing active workspace for Niri hide-diff test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        for windowId in 501 ... 504 {
            _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId)
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .gesture(
                ViewGesture(currentViewOffset: -2500, isTrackpad: true)
            )
        }

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let plan = plans.first else {
            Issue.record("Expected a Niri layout plan after viewport shift")
            return
        }

        #expect(hasHiddenVisibilityChange(plan.diff.visibilityChanges))
        #expect(!hiddenVisibilitySides(plan.diff.visibilityChanges).isEmpty)
        let hiddenTokens = hiddenVisibilityTokens(plan.diff.visibilityChanges)
        #expect(!hiddenTokens.isEmpty)
        for token in hiddenTokens {
            #expect(!hasFrameChange(plan.diff.frameChanges, token: token))
        }
    }

    @Test @MainActor func snapshotPlanDoesNotHideFullscreenTokenOnRightVisibleColumn() async throws {
        let monitor = makeLayoutPlanTestMonitor(width: 1600, height: 900)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing active workspace for fullscreen hide-diff regression test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri engine for fullscreen hide-diff regression test")
            return
        }

        engine.maxVisibleColumns = 3
        engine.centerFocusedColumn = .never

        for windowId in 511 ... 515 {
            _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId)
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gap = CGFloat(controller.workspaceManager.gaps)
        let fixedWidth = (workingFrame.width - gap * CGFloat(engine.maxVisibleColumns - 1)) / CGFloat(engine.maxVisibleColumns)
        for column in engine.columns(in: workspaceId) {
            column.width = .fixed(fixedWidth)
            column.cachedWidth = fixedWidth
        }

        let columns = engine.columns(in: workspaceId)
        guard columns.indices.contains(engine.maxVisibleColumns - 1),
              let targetWindow = columns[engine.maxVisibleColumns - 1].windowNodes.first
        else {
            Issue.record("Expected a right visible-column target for fullscreen hide-diff regression test")
            return
        }

        var state = makeViewportStateForVisibleColumn(
            targetWindow: targetWindow,
            engine: engine,
            workspaceId: workspaceId,
            workingFrame: workingFrame,
            gap: gap
        )
        _ = controller.workspaceManager.setManagedFocus(targetWindow.token, in: workspaceId, onMonitor: monitor.id)
        engine.toggleFullscreen(targetWindow, state: &state)
        controller.workspaceManager.updateNiriViewportState(state, for: workspaceId)

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let plan = plans.first else {
            Issue.record("Expected a fullscreen Niri layout plan for hide-diff regression test")
            return
        }

        let expectedFullscreenFrame = workingFrame.roundedToPhysicalPixels(
            scale: controller.layoutRefreshController.backingScale(for: monitor)
        )
        #expect(!hasHideVisibilityChange(plan.diff.visibilityChanges, token: targetWindow.token))

        guard let frameChange = plan.diff.frameChanges.first(where: { $0.token == targetWindow.token }) else {
            Issue.record("Expected a frame change for the fullscreen token in hide-diff regression test")
            return
        }

        #expect(frameChange.forceApply)
        #expect(frameChange.frame == expectedFullscreenFrame)
    }

    @Test @MainActor func offscreenLeftPlaceholderFramesUseWorkingFrameOriginOnMonitorWithoutLeftNeighbor() async throws {
        let primaryMonitor = makeLayoutPlanTestMonitor(displayId: 100, name: "Primary", x: 0, width: 1600, height: 900)
        let secondaryMonitor = makeLayoutPlanTestMonitor(displayId: 200, name: "Secondary", x: 1600, width: 1600, height: 900)
        let fixture = makeTwoMonitorLayoutPlanTestController(
            primaryMonitor: primaryMonitor,
            secondaryMonitor: secondaryMonitor
        )
        let controller = fixture.controller
        let workspaceId = fixture.primaryWorkspaceId

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        var tokens: [WindowToken] = []
        for windowId in 701 ... 704 {
            tokens.append(addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId))
        }

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri engine for offscreen-left placeholder test")
            return
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .static(2500)
        }

        let gaps = LayoutGaps(
            horizontal: CGFloat(controller.workspaceManager.gaps),
            vertical: CGFloat(controller.workspaceManager.gaps),
            outer: controller.workspaceManager.outerGaps
        )
        let workingFrame = controller.insetWorkingFrame(for: primaryMonitor)
        let area = WorkingAreaContext(
            workingFrame: workingFrame,
            viewFrame: primaryMonitor.frame,
            scale: controller.layoutRefreshController.backingScale(for: primaryMonitor)
        )
        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let (frames, hiddenHandles) = engine.calculateCombinedLayoutUsingPools(
            in: workspaceId,
            monitor: primaryMonitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: nil
        )

        let hiddenLeftTokens = tokens.filter { hiddenHandles[$0] == .left }
        #expect(!hiddenLeftTokens.isEmpty)
        for token in hiddenLeftTokens {
            #expect(frames[token]?.origin.y == workingFrame.minY)
        }
    }

    @Test func hiddenLeftRevealPreservesBottomTileHeightOnFirstVisibleFrame() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 1)
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)

        let bottomHandle = makeTestHandle(pid: 41)
        let topHandle = makeTestHandle(pid: 42)
        let visibleHandle = makeTestHandle(pid: 43)

        let bottomWindow = NiriWindow(handle: bottomHandle)
        let topWindow = NiriWindow(handle: topHandle)
        let visibleWindow = NiriWindow(handle: visibleHandle)

        bottomWindow.height = .fixed(280)
        topWindow.height = .auto(weight: 1.0)

        leftColumn.appendChild(bottomWindow)
        leftColumn.appendChild(topWindow)
        rightColumn.appendChild(visibleWindow)

        engine.tokenToNode[bottomHandle.id] = bottomWindow
        engine.tokenToNode[topHandle.id] = topWindow
        engine.tokenToNode[visibleHandle.id] = visibleWindow

        let monitor = makeLayoutPlanTestMonitor(width: 960, height: 900)
        let gaps = LayoutGaps(horizontal: 8, vertical: 8)
        let area = WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )

        var hiddenState = ViewportState()
        hiddenState.activeColumnIndex = 1
        hiddenState.viewOffsetPixels = .static(0)

        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: hiddenState,
            workingArea: area,
            animationTime: nil
        )

        #expect(hiddenLayout.hiddenHandles[bottomHandle.id] == .left)
        guard let canonicalBottomFrame = bottomWindow.frame,
              let canonicalBottomHeight = bottomWindow.resolvedHeight
        else {
            Issue.record("Expected canonical bottom window geometry after hidden layout")
            return
        }

        var revealState = hiddenState
        revealState.viewOffsetPixels = .static(-20)

        let revealLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: revealState,
            workingArea: area,
            animationTime: nil
        )

        #expect(revealLayout.hiddenHandles[bottomHandle.id] == nil)
        #expect(bottomWindow.frame == canonicalBottomFrame)
        #expect(bottomWindow.resolvedHeight == canonicalBottomHeight)
        #expect(revealLayout.frames[bottomHandle.id]?.minY == canonicalBottomFrame.minY)
        #expect(revealLayout.frames[bottomHandle.id]?.height == canonicalBottomHeight)
    }

    @Test func fullscreenWindowsStayMonitorAnchoredAcrossVisibleColumns() {
        for visibleCount in 2 ... 5 {
            let fixture = makeVisibleColumnFixture(visibleCount: visibleCount)
            let expectedFullscreenFrame = fixture.monitor.visibleFrame.roundedToPhysicalPixels(scale: fixture.area.scale)

            var targetIndices = [visibleCount - 1]
            if visibleCount > 2 {
                targetIndices.append(1)
            }

            for targetIndex in targetIndices {
                let targetWindow = fixture.windows[targetIndex]
                var state = makeViewportStateForVisibleColumn(
                    targetWindow: targetWindow,
                    engine: fixture.engine,
                    workspaceId: fixture.workspaceId,
                    workingFrame: fixture.monitor.visibleFrame,
                    gap: fixture.gap
                )

                let tiledLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                    in: fixture.workspaceId,
                    monitor: fixture.monitor,
                    gaps: fixture.gaps,
                    state: state,
                    workingArea: fixture.area,
                    animationTime: nil
                )

                guard let tiledFrame = tiledLayout.frames[targetWindow.token] else {
                    Issue.record("Expected tiled frame for visibleCount=\(visibleCount) targetIndex=\(targetIndex)")
                    continue
                }

                #expect(tiledLayout.hiddenHandles[targetWindow.token] == nil)

                fixture.engine.toggleFullscreen(targetWindow, state: &state)
                let fullscreenLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                    in: fixture.workspaceId,
                    monitor: fixture.monitor,
                    gaps: fixture.gaps,
                    state: state,
                    workingArea: fixture.area,
                    animationTime: nil
                )

                #expect(fullscreenLayout.hiddenHandles[targetWindow.token] == nil)
                #expect(fullscreenLayout.frames[targetWindow.token] == expectedFullscreenFrame)
                #expect(targetWindow.renderedFrame == expectedFullscreenFrame)

                fixture.engine.toggleFullscreen(targetWindow, state: &state)
                let restoredLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                    in: fixture.workspaceId,
                    monitor: fixture.monitor,
                    gaps: fixture.gaps,
                    state: state,
                    workingArea: fixture.area,
                    animationTime: nil
                )

                #expect(restoredLayout.frames[targetWindow.token] == tiledFrame)
            }
        }
    }

    @Test func fullscreenBottomTileUsesFullMonitorHeightWithoutCarryoverOffset() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 1)
        engine.animationClock = AnimationClock()
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let column = NiriContainer()
        root.appendChild(column)

        let topHandle = makeTestHandle(pid: 71)
        let bottomHandle = makeTestHandle(pid: 72)
        let topWindow = NiriWindow(handle: topHandle)
        let bottomWindow = NiriWindow(handle: bottomHandle)

        topWindow.height = .auto(weight: 1.0)
        bottomWindow.height = .fixed(280)

        column.appendChild(topWindow)
        column.appendChild(bottomWindow)
        engine.tokenToNode[topHandle.id] = topWindow
        engine.tokenToNode[bottomHandle.id] = bottomWindow

        let monitor = makeLayoutPlanTestMonitor(width: 1200, height: 900)
        let gaps = LayoutGaps(horizontal: 8, vertical: 8)
        let area = WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )

        var state = ViewportState()
        state.selectedNodeId = bottomWindow.id
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        let tiledLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: nil
        )

        guard let tiledFrame = tiledLayout.frames[bottomHandle.id],
              let tiledHeight = bottomWindow.resolvedHeight
        else {
            Issue.record("Expected tiled frame for bottom-tile fullscreen regression test")
            return
        }

        bottomWindow.animateMoveFrom(
            displacement: CGPoint(x: 0, y: -220),
            clock: engine.animationClock,
            config: engine.windowMovementAnimationConfig,
            displayRefreshRate: engine.displayRefreshRate
        )

        engine.toggleFullscreen(bottomWindow, state: &state)
        let fullscreenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: engine.animationClock?.now()
        )

        let expectedFullscreenFrame = monitor.visibleFrame.roundedToPhysicalPixels(scale: area.scale)
        #expect(fullscreenLayout.frames[bottomHandle.id] == expectedFullscreenFrame)
        #expect(bottomWindow.resolvedHeight == monitor.visibleFrame.height)
        #expect(bottomWindow.hasMoveAnimationsRunning == false)

        engine.toggleFullscreen(bottomWindow, state: &state)
        let restoredLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: nil
        )

        #expect(restoredLayout.frames[bottomHandle.id] == tiledFrame)
        #expect(bottomWindow.resolvedHeight == tiledHeight)
    }

    @Test func focusHitTestPrefersFullscreenWindowOverCoveredTile() {
        let fixture = makeVisibleColumnFixture(visibleCount: 2, extraColumns: 0)
        let coveredWindow = fixture.windows[0]
        let fullscreenWindow = fixture.windows[1]

        var state = makeViewportStateForVisibleColumn(
            targetWindow: fullscreenWindow,
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            workingFrame: fixture.monitor.visibleFrame,
            gap: fixture.gap
        )

        _ = fixture.engine.calculateCombinedLayoutUsingPools(
            in: fixture.workspaceId,
            monitor: fixture.monitor,
            gaps: fixture.gaps,
            state: state,
            workingArea: fixture.area,
            animationTime: nil
        )

        fixture.engine.toggleFullscreen(fullscreenWindow, state: &state)
        _ = fixture.engine.calculateCombinedLayoutUsingPools(
            in: fixture.workspaceId,
            monitor: fixture.monitor,
            gaps: fixture.gaps,
            state: state,
            workingArea: fixture.area,
            animationTime: nil
        )

        guard let coveredFrame = coveredWindow.frame,
              let fullscreenFrame = fullscreenWindow.frame
        else {
            Issue.record("Expected frames for fullscreen focus hit-test regression")
            return
        }

        let overlapPoint = CGPoint(x: coveredFrame.midX, y: coveredFrame.midY)
        #expect(coveredFrame.contains(overlapPoint))
        #expect(fullscreenFrame.contains(overlapPoint))
        #expect(
            fixture.engine.hitTestFocusableWindow(point: overlapPoint, in: fixture.workspaceId)?.token == fullscreenWindow.token
        )
    }

    @Test func toggleFullWidthKeepsRightVisibleColumnInViewport() {
        for visibleCount in 2 ... 5 {
            let fixture = makeVisibleColumnFixture(visibleCount: visibleCount)
            fixture.engine.animationClock = AnimationClock()
            let targetWindow = fixture.windows[visibleCount - 1]
            guard let targetColumn = fixture.engine.column(of: targetWindow) else {
                Issue.record("Expected a target column for full-width visibility test visibleCount=\(visibleCount)")
                continue
            }

            var state = makeViewportStateForVisibleColumn(
                targetWindow: targetWindow,
                engine: fixture.engine,
                workspaceId: fixture.workspaceId,
                workingFrame: fixture.monitor.visibleFrame,
                gap: fixture.gap
            )
            let originalTargetOffset = state.viewOffsetPixels.target()

            fixture.engine.toggleFullWidth(
                targetColumn,
                in: fixture.workspaceId,
                state: &state,
                workingFrame: fixture.monitor.visibleFrame,
                gaps: fixture.gap
            )

            let widenedTargetOffset = state.viewOffsetPixels.target()
            #expect(widenedTargetOffset != originalTargetOffset)

            guard let settleBaseTime = fixture.engine.animationClock?.now() else {
                Issue.record("Expected animation clock for full-width visibility test visibleCount=\(visibleCount)")
                continue
            }
            let settleTime = settleBaseTime + 2.0
            let settledState = settledLayoutState(from: state, column: targetColumn, settleTime: settleTime)
            let settledLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                in: fixture.workspaceId,
                monitor: fixture.monitor,
                gaps: fixture.gaps,
                state: settledState,
                workingArea: fixture.area,
                animationTime: settleTime
            )

            guard let fullscreenWidthFrame = settledLayout.frames[targetWindow.token] else {
                Issue.record("Expected settled frame for full-width visibility test visibleCount=\(visibleCount)")
                continue
            }

            #expect(settledLayout.hiddenHandles[targetWindow.token] == nil)
            #expect(abs(fullscreenWidthFrame.minX - fixture.monitor.visibleFrame.minX) < 1.0)
            #expect(abs(fullscreenWidthFrame.maxX - fixture.monitor.visibleFrame.maxX) < 1.0)
        }
    }

    @Test func toggleColumnWidthKeepsRightVisibleColumnInViewport() {
        for visibleCount in 2 ... 5 {
            let fixture = makeVisibleColumnFixture(visibleCount: visibleCount)
            fixture.engine.animationClock = AnimationClock()
            let targetWindow = fixture.windows[visibleCount - 1]
            guard let targetColumn = fixture.engine.column(of: targetWindow) else {
                Issue.record("Expected a target column for cycle-width visibility test visibleCount=\(visibleCount)")
                continue
            }

            fixture.engine.presetColumnWidths = [
                .fixed(targetColumn.cachedWidth),
                .fixed(targetColumn.cachedWidth * 1.5)
            ]

            var state = makeViewportStateForVisibleColumn(
                targetWindow: targetWindow,
                engine: fixture.engine,
                workspaceId: fixture.workspaceId,
                workingFrame: fixture.monitor.visibleFrame,
                gap: fixture.gap
            )
            let originalLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                in: fixture.workspaceId,
                monitor: fixture.monitor,
                gaps: fixture.gaps,
                state: state,
                workingArea: fixture.area,
                animationTime: nil
            )
            let originalTargetOffset = state.viewOffsetPixels.target()

            fixture.engine.toggleColumnWidth(
                targetColumn,
                forwards: true,
                in: fixture.workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: fixture.monitor.visibleFrame,
                gaps: fixture.gap
            )

            let widenedTargetOffset = state.viewOffsetPixels.target()
            #expect(widenedTargetOffset != originalTargetOffset)

            guard let settleBaseTime = fixture.engine.animationClock?.now() else {
                Issue.record("Expected animation clock for cycle-width visibility test visibleCount=\(visibleCount)")
                continue
            }
            let settleTime = settleBaseTime + 2.0
            let settledState = settledLayoutState(from: state, column: targetColumn, settleTime: settleTime)
            let settledLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                in: fixture.workspaceId,
                monitor: fixture.monitor,
                gaps: fixture.gaps,
                state: settledState,
                workingArea: fixture.area,
                animationTime: settleTime
            )

            guard let originalFrame = originalLayout.frames[targetWindow.token],
                  let widenedFrame = settledLayout.frames[targetWindow.token]
            else {
                Issue.record("Expected original and widened frames for cycle-width visibility test visibleCount=\(visibleCount)")
                continue
            }

            #expect(settledLayout.hiddenHandles[targetWindow.token] == nil)
            #expect(widenedFrame.width > originalFrame.width)
            #expect(widenedFrame.maxX <= fixture.monitor.visibleFrame.maxX + 1.0)
        }
    }

    @Test func toggleColumnWidthForwardWithAnimationsDisabledAppliesWidthImmediately() {
        for visibleCount in 2 ... 5 {
            let fixture = makeVisibleColumnFixture(visibleCount: visibleCount)
            let targetWindow = fixture.windows[visibleCount - 1]
            guard let targetColumn = fixture.engine.column(of: targetWindow) else {
                Issue.record("Expected a target column for disabled cycle-width forward test visibleCount=\(visibleCount)")
                continue
            }

            let originalWidth = targetColumn.cachedWidth
            fixture.engine.presetColumnWidths = [
                .fixed(originalWidth),
                .fixed(originalWidth * 1.5)
            ]

            var state = makeViewportStateForVisibleColumn(
                targetWindow: targetWindow,
                engine: fixture.engine,
                workspaceId: fixture.workspaceId,
                workingFrame: fixture.monitor.visibleFrame,
                gap: fixture.gap
            )
            let originalLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                in: fixture.workspaceId,
                monitor: fixture.monitor,
                gaps: fixture.gaps,
                state: state,
                workingArea: fixture.area,
                animationTime: nil
            )

            fixture.engine.toggleColumnWidth(
                targetColumn,
                forwards: true,
                in: fixture.workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: fixture.monitor.visibleFrame,
                gaps: fixture.gap
            )

            let immediateLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                in: fixture.workspaceId,
                monitor: fixture.monitor,
                gaps: fixture.gaps,
                state: state,
                workingArea: fixture.area,
                animationTime: nil
            )

            guard let originalFrame = originalLayout.frames[targetWindow.token],
                  let updatedFrame = immediateLayout.frames[targetWindow.token]
            else {
                Issue.record("Expected original and updated frames for disabled cycle-width forward test visibleCount=\(visibleCount)")
                continue
            }

            #expect(abs(targetColumn.cachedWidth - (originalWidth * 1.5)) < 0.1)
            #expect(!targetColumn.hasWidthAnimationRunning)
            #expect(!state.viewOffsetPixels.isAnimating)
            #expect(immediateLayout.hiddenHandles[targetWindow.token] == nil)
            #expect(updatedFrame.width > originalFrame.width)
            #expect(updatedFrame.maxX <= fixture.monitor.visibleFrame.maxX + 1.0)
        }
    }

    @Test func toggleColumnWidthBackwardWithAnimationsDisabledAppliesWidthImmediately() {
        for visibleCount in 2 ... 5 {
            let fixture = makeVisibleColumnFixture(visibleCount: visibleCount)
            let targetWindow = fixture.windows[visibleCount - 1]
            guard let targetColumn = fixture.engine.column(of: targetWindow) else {
                Issue.record("Expected a target column for disabled cycle-width backward test visibleCount=\(visibleCount)")
                continue
            }

            let originalWidth = targetColumn.cachedWidth
            let targetWidth = originalWidth * 0.75
            fixture.engine.presetColumnWidths = [
                .fixed(targetWidth),
                .fixed(originalWidth)
            ]
            targetColumn.width = .fixed(originalWidth)
            targetColumn.presetWidthIdx = 1

            var state = makeViewportStateForVisibleColumn(
                targetWindow: targetWindow,
                engine: fixture.engine,
                workspaceId: fixture.workspaceId,
                workingFrame: fixture.monitor.visibleFrame,
                gap: fixture.gap
            )
            let originalLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                in: fixture.workspaceId,
                monitor: fixture.monitor,
                gaps: fixture.gaps,
                state: state,
                workingArea: fixture.area,
                animationTime: nil
            )

            fixture.engine.toggleColumnWidth(
                targetColumn,
                forwards: false,
                in: fixture.workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: fixture.monitor.visibleFrame,
                gaps: fixture.gap
            )

            let immediateLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                in: fixture.workspaceId,
                monitor: fixture.monitor,
                gaps: fixture.gaps,
                state: state,
                workingArea: fixture.area,
                animationTime: nil
            )

            guard let originalFrame = originalLayout.frames[targetWindow.token],
                  let updatedFrame = immediateLayout.frames[targetWindow.token]
            else {
                Issue.record("Expected original and updated frames for disabled cycle-width backward test visibleCount=\(visibleCount)")
                continue
            }

            #expect(abs(targetColumn.cachedWidth - targetWidth) < 0.1)
            #expect(!targetColumn.hasWidthAnimationRunning)
            #expect(!state.viewOffsetPixels.isAnimating)
            #expect(immediateLayout.hiddenHandles[targetWindow.token] == nil)
            #expect(updatedFrame.width < originalFrame.width)
            #expect(updatedFrame.maxX <= fixture.monitor.visibleFrame.maxX + 1.0)
        }
    }

    @Test func toggleFullWidthWithAnimationsDisabledAppliesWidthImmediately() {
        for visibleCount in 2 ... 5 {
            let fixture = makeVisibleColumnFixture(visibleCount: visibleCount)
            let targetWindow = fixture.windows[visibleCount - 1]
            guard let targetColumn = fixture.engine.column(of: targetWindow) else {
                Issue.record("Expected a target column for disabled full-width test visibleCount=\(visibleCount)")
                continue
            }

            var state = makeViewportStateForVisibleColumn(
                targetWindow: targetWindow,
                engine: fixture.engine,
                workspaceId: fixture.workspaceId,
                workingFrame: fixture.monitor.visibleFrame,
                gap: fixture.gap
            )
            fixture.engine.toggleFullWidth(
                targetColumn,
                in: fixture.workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: fixture.monitor.visibleFrame,
                gaps: fixture.gap
            )

            let immediateLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                in: fixture.workspaceId,
                monitor: fixture.monitor,
                gaps: fixture.gaps,
                state: state,
                workingArea: fixture.area,
                animationTime: nil
            )

            guard let updatedFrame = immediateLayout.frames[targetWindow.token] else {
                Issue.record("Expected updated frame for disabled full-width test visibleCount=\(visibleCount)")
                continue
            }

            #expect(abs(targetColumn.cachedWidth - fixture.monitor.visibleFrame.width) < 0.1)
            #expect(!targetColumn.hasWidthAnimationRunning)
            #expect(!state.viewOffsetPixels.isAnimating)
            #expect(immediateLayout.hiddenHandles[targetWindow.token] == nil)
            #expect(abs(updatedFrame.minX - fixture.monitor.visibleFrame.minX) < 1.0)
            #expect(abs(updatedFrame.maxX - fixture.monitor.visibleFrame.maxX) < 1.0)
        }
    }

    @Test @MainActor func cycleColumnWidthCommandWithAnimationsDisabledAppliesFrameWithoutStartingScrollAnimation() async throws {
        let fixture = try await makeDisabledMotionWidthCommandFixture()
        let targetWindow = fixture.windows[1]
        guard let targetColumn = fixture.engine.column(of: targetWindow) else {
            Issue.record("Expected target column for disabled cycle-width command test")
            return
        }

        let originalWidth = targetColumn.cachedWidth
        fixture.engine.presetColumnWidths = [
            .fixed(originalWidth),
            .fixed(originalWidth * 1.5)
        ]

        guard let originalFrame = fixture.controller.axManager.lastAppliedFrame(for: targetWindow.token.windowId) else {
            Issue.record("Expected an initial applied frame for disabled cycle-width command test")
            return
        }

        fixture.controller.commandHandler.handleCommand(.cycleColumnWidthForward)
        await waitForLayoutPlanRefreshWork(on: fixture.controller)

        guard let updatedFrame = fixture.controller.axManager.lastAppliedFrame(for: targetWindow.token.windowId) else {
            Issue.record("Expected an updated applied frame for disabled cycle-width command test")
            return
        }

        #expect(abs(targetColumn.cachedWidth - (originalWidth * 1.5)) < 0.1)
        #expect(!targetColumn.hasWidthAnimationRunning)
        #expect(updatedFrame.width > originalFrame.width)
        #expect(updatedFrame.maxX <= fixture.monitor.visibleFrame.maxX + 1.0)
        #expect(
            fixture.controller.niriLayoutHandler.scrollAnimationByDisplay[fixture.monitor.displayId] == nil
        )
    }

    @Test @MainActor func toggleColumnFullWidthCommandWithAnimationsDisabledAppliesFrameWithoutStartingScrollAnimation() async throws {
        let fixture = try await makeDisabledMotionWidthCommandFixture()
        let targetWindow = fixture.windows[1]
        guard let targetColumn = fixture.engine.column(of: targetWindow) else {
            Issue.record("Expected target column for disabled full-width command test")
            return
        }

        guard let originalFrame = fixture.controller.axManager.lastAppliedFrame(for: targetWindow.token.windowId) else {
            Issue.record("Expected an initial applied frame for disabled full-width command test")
            return
        }

        fixture.controller.commandHandler.handleCommand(.toggleColumnFullWidth)
        await waitForLayoutPlanRefreshWork(on: fixture.controller)

        guard let updatedFrame = fixture.controller.axManager.lastAppliedFrame(for: targetWindow.token.windowId) else {
            Issue.record("Expected an updated applied frame for disabled full-width command test")
            return
        }

        #expect(abs(targetColumn.cachedWidth - fixture.workingFrame.width) < 0.1)
        #expect(!targetColumn.hasWidthAnimationRunning)
        #expect(updatedFrame.width > originalFrame.width)
        #expect(abs(updatedFrame.minX - fixture.monitor.visibleFrame.minX) < 1.0)
        #expect(abs(updatedFrame.maxX - fixture.monitor.visibleFrame.maxX) < 1.0)
        #expect(
            fixture.controller.niriLayoutHandler.scrollAnimationByDisplay[fixture.monitor.displayId] == nil
        )
    }

    @Test func splitAndExpelColumnCreationUseExplicitDefaultWidth() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.presetColumnWidths = [.proportion(0.85), .proportion(1.0), .proportion(0.5)]
        engine.defaultColumnWidth = 0.7
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let sourceColumn = NiriContainer()
        root.appendChild(sourceColumn)

        let movedWindow = NiriWindow(token: makeTestHandle(pid: 31).id)
        let expelledWindow = NiriWindow(token: makeTestHandle(pid: 32).id)
        let stationaryWindow = NiriWindow(token: makeTestHandle(pid: 33).id)
        sourceColumn.appendChild(movedWindow)
        sourceColumn.appendChild(expelledWindow)
        sourceColumn.appendChild(stationaryWindow)
        engine.tokenToNode[movedWindow.token] = movedWindow
        engine.tokenToNode[expelledWindow.token] = expelledWindow
        engine.tokenToNode[stationaryWindow.token] = stationaryWindow

        var state = ViewportState()
        engine.createColumnAndMove(
            movedWindow,
            from: sourceColumn,
            direction: .right,
            in: wsId,
            state: &state,
            gaps: 8,
            workingAreaWidth: 1600
        )

        let columnsAfterSplit = engine.columns(in: wsId)
        guard columnsAfterSplit.count == 2 else {
            Issue.record("Expected split operation to create a second column")
            return
        }

        let splitColumn = columnsAfterSplit[1]
        #expect(splitColumn.width == .proportion(0.7))
        #expect(splitColumn.presetWidthIdx == nil)

        var expelState = ViewportState()
        let expelled = engine.expelWindow(
            expelledWindow,
            to: .left,
            in: wsId,
            state: &expelState,
            workingFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            gaps: 8
        )

        let columnsAfterExpel = engine.columns(in: wsId)
        guard columnsAfterExpel.count == 3 else {
            Issue.record("Expected expel operation to create a third column")
            return
        }

        #expect(expelled)
        #expect(columnsAfterExpel[0].width == .proportion(0.7))
        #expect(columnsAfterExpel[0].presetWidthIdx == nil)
    }

    @Test func insertWindowInNewColumnUsesExplicitDefaultWidth() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.presetColumnWidths = [.proportion(0.85), .proportion(1.0), .proportion(0.5)]
        engine.defaultColumnWidth = 0.7
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let sourceColumn = NiriContainer()
        root.appendChild(sourceColumn)

        let stationaryWindow = NiriWindow(token: makeTestHandle(pid: 41).id)
        let movedWindow = NiriWindow(token: makeTestHandle(pid: 42).id)
        sourceColumn.appendChild(stationaryWindow)
        sourceColumn.appendChild(movedWindow)
        engine.tokenToNode[stationaryWindow.token] = stationaryWindow
        engine.tokenToNode[movedWindow.token] = movedWindow

        var state = ViewportState()
        let inserted = engine.insertWindowInNewColumn(
            movedWindow,
            insertIndex: 1,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        guard columns.count == 2 else {
            Issue.record("Expected insert-window operation to create a second column")
            return
        }

        #expect(inserted)
        #expect(columns[1].width == .proportion(0.7))
        #expect(columns[1].presetWidthIdx == nil)
    }

    @Test func insertWindowInNewColumnPlacesWindowImmediatelyRightOfFocusedColumn() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let focusedColumn = NiriContainer()
        let trailingColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(focusedColumn)
        root.appendChild(trailingColumn)

        let targetWindow = NiriWindow(token: makeTestHandle(pid: 51).id)
        let focusedWindow = NiriWindow(token: makeTestHandle(pid: 52).id)
        let trailingWindow = NiriWindow(token: makeTestHandle(pid: 53).id)

        leftColumn.appendChild(targetWindow)
        focusedColumn.appendChild(focusedWindow)
        trailingColumn.appendChild(trailingWindow)

        engine.tokenToNode[targetWindow.token] = targetWindow
        engine.tokenToNode[focusedWindow.token] = focusedWindow
        engine.tokenToNode[trailingWindow.token] = trailingWindow

        var state = ViewportState()
        let inserted = engine.insertWindowInNewColumn(
            targetWindow,
            insertIndex: 2,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            gaps: 8
        )

        let orderedWindowIds = engine.columns(in: wsId).compactMap { $0.windowNodes.first?.token.windowId }

        #expect(inserted)
        #expect(orderedWindowIds == [focusedWindow.token.windowId, targetWindow.token.windowId, trailingWindow.token.windowId])
    }

    @Test func moveWindowToWorkspaceThenInsertColumnPreservesSourceFallbackSelection() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        let sourceWorkspaceId = UUID()
        let targetWorkspaceId = UUID()

        let targetWindow = engine.addWindow(handle: makeTestHandle(pid: 61), to: sourceWorkspaceId, afterSelection: nil)
        let fallbackWindow = engine.addWindow(
            handle: makeTestHandle(pid: 62),
            to: sourceWorkspaceId,
            afterSelection: targetWindow.id
        )
        let focusedWindow = engine.addWindow(handle: makeTestHandle(pid: 63), to: targetWorkspaceId, afterSelection: nil)

        var sourceState = ViewportState()
        sourceState.selectedNodeId = targetWindow.id
        var targetState = ViewportState()
        targetState.selectedNodeId = focusedWindow.id

        let moved = engine.moveWindowToWorkspace(
            targetWindow,
            from: sourceWorkspaceId,
            to: targetWorkspaceId,
            sourceState: &sourceState,
            targetState: &targetState
        )
        guard let movedWindow = engine.findNode(for: targetWindow.token) else {
            Issue.record("Expected moved window in target workspace")
            return
        }

        var targetInsertState = targetState
        let inserted = engine.insertWindowInNewColumn(
            movedWindow,
            insertIndex: 1,
            in: targetWorkspaceId,
            state: &targetInsertState,
            workingFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            gaps: 8
        )

        let orderedWindowIds = engine.columns(in: targetWorkspaceId).compactMap { $0.windowNodes.first?.token.windowId }

        #expect(moved?.newFocusNodeId == fallbackWindow.id)
        #expect(sourceState.selectedNodeId == fallbackWindow.id)
        #expect(inserted)
        #expect(orderedWindowIds == [focusedWindow.token.windowId, targetWindow.token.windowId])
    }

    @Test func toggleColumnWidthFollowsOrderedDuplicatePresetsFromExplicitDefaultMatch() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.presetColumnWidths = [
            .proportion(0.85),
            .proportion(1.0),
            .proportion(0.85),
            .proportion(0.5)
        ]
        engine.defaultColumnWidth = 0.85
        let wsId = UUID()

        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        guard let column = engine.column(of: window) else {
            Issue.record("Expected column for ordered preset cycle test")
            return
        }

        #expect(column.width == .proportion(0.85))
        #expect(column.presetWidthIdx == 0)

        var state = ViewportState()
        let workingFrame = CGRect(x: 0, y: 0, width: 1600, height: 900)

        engine.toggleColumnWidth(
            column,
            forwards: true,
            in: wsId,
            state: &state,
            workingFrame: workingFrame,
            gaps: 8
        )
        #expect(column.width == .proportion(1.0))
        #expect(column.presetWidthIdx == 1)

        engine.toggleColumnWidth(
            column,
            forwards: true,
            in: wsId,
            state: &state,
            workingFrame: workingFrame,
            gaps: 8
        )
        #expect(column.width == .proportion(0.85))
        #expect(column.presetWidthIdx == 2)

        engine.toggleColumnWidth(
            column,
            forwards: true,
            in: wsId,
            state: &state,
            workingFrame: workingFrame,
            gaps: 8
        )
        #expect(column.width == .proportion(0.5))
        #expect(column.presetWidthIdx == 3)
    }

    @Test func balanceSizesUsesExplicitDefaultWidthAndResetsManualState() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1, maxVisibleColumns: 3)
        engine.presetColumnWidths = [
            .proportion(0.85),
            .proportion(1.0),
            .proportion(0.5)
        ]
        engine.defaultColumnWidth = 0.85
        let wsId = UUID()

        let firstWindow = engine.addWindow(handle: makeTestHandle(pid: 411), to: wsId, afterSelection: nil)
        let secondWindow = engine.addWindow(handle: makeTestHandle(pid: 412), to: wsId, afterSelection: firstWindow.id)
        let _ = engine.addWindow(handle: makeTestHandle(pid: 413), to: wsId, afterSelection: secondWindow.id)

        let columns = engine.columns(in: wsId)
        guard columns.count == 3 else {
            Issue.record("Expected three columns for explicit default balance test")
            return
        }

        for (index, column) in columns.enumerated() {
            column.width = index == 0 ? .fixed(900) : .proportion(0.4 + CGFloat(index) * 0.1)
            column.presetWidthIdx = index
            column.isFullWidth = true
            column.savedWidth = .fixed(700 + CGFloat(index) * 25)
            column.hasManualSingleWindowWidthOverride = true
            for window in column.windowNodes {
                window.size = CGFloat(index + 2)
            }
        }

        engine.balanceSizes(in: wsId, workingAreaWidth: 1600, gaps: 8)

        for column in columns {
            #expect(column.width == .proportion(0.85))
            #expect(column.presetWidthIdx == 0)
            #expect(!column.isFullWidth)
            #expect(column.savedWidth == nil)
            #expect(!column.hasManualSingleWindowWidthOverride)
            for window in column.windowNodes {
                #expect(window.size == 1.0)
            }
        }
    }

    @Test func explicitDefaultOutsidePresetListReanchorsOnFirstResize() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.presetColumnWidths = [
            .proportion(0.5),
            .proportion(0.85),
            .proportion(1.0)
        ]
        engine.defaultColumnWidth = 0.6
        let wsId = UUID()

        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        guard let column = engine.column(of: window) else {
            Issue.record("Expected column for custom default reanchor test")
            return
        }

        #expect(column.width == .proportion(0.6))
        #expect(column.presetWidthIdx == nil)

        var state = ViewportState()
        engine.toggleColumnWidth(
            column,
            forwards: true,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            gaps: 8
        )

        #expect(column.width == .proportion(0.85))
        #expect(column.presetWidthIdx == 1)
    }

    @Test func balanceSizesFallsBackToAutoWidthWhenDefaultWidthIsAuto() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1, maxVisibleColumns: 4)
        engine.defaultColumnWidth = nil
        let wsId = UUID()

        let firstWindow = engine.addWindow(handle: makeTestHandle(pid: 421), to: wsId, afterSelection: nil)
        let secondWindow = engine.addWindow(handle: makeTestHandle(pid: 422), to: wsId, afterSelection: firstWindow.id)
        let _ = engine.addWindow(handle: makeTestHandle(pid: 423), to: wsId, afterSelection: secondWindow.id)

        let columns = engine.columns(in: wsId)
        guard columns.count == 3 else {
            Issue.record("Expected three columns for auto-width balance test")
            return
        }

        for column in columns {
            column.width = .fixed(777)
            column.presetWidthIdx = 2
        }

        engine.balanceSizes(in: wsId, workingAreaWidth: 1600, gaps: 8)

        let expectedWidth = 1.0 / CGFloat(engine.effectiveMaxVisibleColumns(in: wsId))
        for column in columns {
            #expect(column.width == .proportion(expectedWidth))
            #expect(column.presetWidthIdx == nil)
        }
    }

    @Test func balanceSizesUsesExplicitDefaultWidthWithoutPresetMatch() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1, maxVisibleColumns: 3)
        engine.presetColumnWidths = [
            .proportion(0.5),
            .proportion(0.85),
            .proportion(1.0)
        ]
        engine.defaultColumnWidth = 0.6
        let wsId = UUID()

        let firstWindow = engine.addWindow(handle: makeTestHandle(pid: 431), to: wsId, afterSelection: nil)
        let secondWindow = engine.addWindow(handle: makeTestHandle(pid: 432), to: wsId, afterSelection: firstWindow.id)
        let _ = engine.addWindow(handle: makeTestHandle(pid: 433), to: wsId, afterSelection: secondWindow.id)

        let columns = engine.columns(in: wsId)
        guard columns.count == 3 else {
            Issue.record("Expected three columns for custom non-preset balance test")
            return
        }

        engine.balanceSizes(in: wsId, workingAreaWidth: 1600, gaps: 8)

        for column in columns {
            #expect(column.width == .proportion(0.6))
            #expect(column.presetWidthIdx == nil)
        }
    }

    @Test func neighboringRightMonitorKeepsPartiallyRevealedColumnHiddenUntilFullyContained() {
        let fixture = makeHorizontalNeighboringRevealFixture(workspaceOnPrimary: true, pidBase: 51)
        let engine = fixture.engine
        let wsId = fixture.workspaceId
        let primaryMonitor = fixture.owningMonitor
        let secondaryMonitor = fixture.neighboringMonitor
        let leakingWindow = fixture.secondWindow

        var hiddenState = ViewportState()
        hiddenState.activeColumnIndex = 0
        hiddenState.viewOffsetPixels = .static(0)
        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: primaryMonitor,
            gaps: fixture.gaps,
            state: hiddenState,
            workingArea: fixture.area,
            animationTime: nil
        )
        #expect(hiddenLayout.hiddenHandles[leakingWindow.token] == .right)

        var partialRevealState = hiddenState
        partialRevealState.viewOffsetPixels = .static(20)
        let partialRevealLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: primaryMonitor,
            gaps: fixture.gaps,
            state: partialRevealState,
            workingArea: fixture.area,
            animationTime: nil
        )
        #expect(partialRevealLayout.hiddenHandles[leakingWindow.token] == .right)

        var fullRevealState = hiddenState
        fullRevealState.viewOffsetPixels = .static(primaryMonitor.visibleFrame.width + fixture.gap)
        let fullyContainedLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: primaryMonitor,
            gaps: fixture.gaps,
            state: fullRevealState,
            workingArea: fixture.area,
            animationTime: nil
        )
        guard let fullyContainedFrame = fullyContainedLayout.frames[leakingWindow.token] else {
            Issue.record("Expected a fully contained frame for the right-edge reveal test")
            return
        }

        #expect(fullyContainedLayout.hiddenHandles[leakingWindow.token] == nil)
        #expect(fullyContainedFrame.minX >= primaryMonitor.visibleFrame.minX)
        #expect(fullyContainedFrame.maxX <= primaryMonitor.visibleFrame.maxX)
        #expect(!fullyContainedFrame.intersects(secondaryMonitor.frame))
    }

    @Test func neighboringLeftMonitorKeepsPartiallyRevealedColumnHiddenUntilFullyContained() {
        let fixture = makeHorizontalNeighboringRevealFixture(workspaceOnPrimary: false, pidBase: 61)
        let engine = fixture.engine
        let wsId = fixture.workspaceId
        let secondaryMonitor = fixture.owningMonitor
        let primaryMonitor = fixture.neighboringMonitor
        let leakingWindow = fixture.firstWindow
        let focusedWindow = fixture.secondWindow

        var hiddenState = ViewportState()
        hiddenState.activeColumnIndex = 1
        hiddenState.selectedNodeId = focusedWindow.id
        hiddenState.viewOffsetPixels = .static(0)
        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: secondaryMonitor,
            gaps: fixture.gaps,
            state: hiddenState,
            workingArea: fixture.area,
            animationTime: nil
        )
        #expect(hiddenLayout.hiddenHandles[leakingWindow.token] == .left)

        var partialRevealState = hiddenState
        partialRevealState.viewOffsetPixels = .static(-20)
        let partialRevealLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: secondaryMonitor,
            gaps: fixture.gaps,
            state: partialRevealState,
            workingArea: fixture.area,
            animationTime: nil
        )
        #expect(partialRevealLayout.hiddenHandles[leakingWindow.token] == .left)

        var fullRevealState = hiddenState
        fullRevealState.viewOffsetPixels = .static(-(secondaryMonitor.visibleFrame.width + fixture.gap))
        let fullyContainedLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: secondaryMonitor,
            gaps: fixture.gaps,
            state: fullRevealState,
            workingArea: fixture.area,
            animationTime: nil
        )
        guard let fullyContainedFrame = fullyContainedLayout.frames[leakingWindow.token] else {
            Issue.record("Expected a fully contained frame for the left-edge reveal test")
            return
        }

        #expect(fullyContainedLayout.hiddenHandles[leakingWindow.token] == nil)
        #expect(fullyContainedFrame.minX >= secondaryMonitor.visibleFrame.minX)
        #expect(fullyContainedFrame.maxX <= secondaryMonitor.visibleFrame.maxX)
        #expect(!fullyContainedFrame.intersects(primaryMonitor.frame))
    }

    @Test func partialRevealRemainsVisibleWhenViewportEdgeHasNoNeighboringMonitor() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1, maxVisibleColumns: 1)
        let wsId = UUID()
        let monitor = makeLayoutPlanTestMonitor(width: 1600, height: 900)
        attachWorkspace(
            wsId,
            to: monitor,
            engine: engine,
            resolvedSettings: resolvedSettings(
                for: engine,
                maxVisibleColumns: 2,
                centerFocusedColumn: .always
            )
        )

        let visibleWindow = engine.addWindow(handle: makeTestHandle(pid: 71), to: wsId, afterSelection: nil)
        let revealedWindow = engine.addWindow(
            handle: makeTestHandle(pid: 72),
            to: wsId,
            afterSelection: visibleWindow.id
        )
        assignWidths(
            engine.columns(in: wsId),
            widths: [monitor.visibleFrame.width, monitor.visibleFrame.width]
        )

        let gaps = LayoutGaps(horizontal: 8, vertical: 8)
        let area = WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )

        var hiddenState = ViewportState()
        hiddenState.activeColumnIndex = 0
        hiddenState.viewOffsetPixels = .static(0)
        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: hiddenState,
            workingArea: area,
            animationTime: nil
        )
        #expect(hiddenLayout.hiddenHandles[revealedWindow.token] == .right)

        var partialRevealState = hiddenState
        partialRevealState.viewOffsetPixels = .static(20)
        let partialRevealLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: partialRevealState,
            workingArea: area,
            animationTime: nil
        )
        guard let partialFrame = partialRevealLayout.frames[revealedWindow.token] else {
            Issue.record("Expected a partially revealed frame on the open desktop edge")
            return
        }

        #expect(partialRevealLayout.hiddenHandles[revealedWindow.token] == nil)
        #expect(partialFrame.minX < monitor.visibleFrame.maxX)
        #expect(partialFrame.maxX > monitor.visibleFrame.maxX)
    }

    @Test func renderOffsetRevealRemainsVisibleWhenViewportEdgeHasNoNeighboringMonitor() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1, maxVisibleColumns: 1)
        engine.animationClock = AnimationClock()
        let wsId = UUID()
        let monitor = makeLayoutPlanTestMonitor(width: 1600, height: 900)
        attachWorkspace(
            wsId,
            to: monitor,
            engine: engine,
            resolvedSettings: resolvedSettings(
                for: engine,
                maxVisibleColumns: 2,
                centerFocusedColumn: .always
            )
        )

        let visibleWindow = engine.addWindow(handle: makeTestHandle(pid: 81), to: wsId, afterSelection: nil)
        let revealedWindow = engine.addWindow(
            handle: makeTestHandle(pid: 82),
            to: wsId,
            afterSelection: visibleWindow.id
        )
        assignWidths(
            engine.columns(in: wsId),
            widths: [monitor.visibleFrame.width, monitor.visibleFrame.width]
        )

        let gaps = LayoutGaps(horizontal: 8, vertical: 8)
        let area = WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        guard let revealedColumn = engine.columns(in: wsId).last,
              let baseTime = engine.animationClock?.now()
        else {
            Issue.record("Expected revealed column and animation clock for open-edge render-offset test")
            return
        }

        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: baseTime
        )
        #expect(hiddenLayout.hiddenHandles[revealedWindow.token] == .right)

        revealedColumn.animateMoveFrom(
            displacement: CGPoint(x: -40, y: 0),
            clock: engine.animationClock,
            config: engine.windowMovementAnimationConfig,
            displayRefreshRate: engine.displayRefreshRate
        )

        guard let animatedTime = engine.animationClock?.now() else {
            Issue.record("Expected animation clock after open-edge render-offset animation")
            return
        }
        let animatedLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: animatedTime
        )
        guard let partialFrame = animatedLayout.frames[revealedWindow.token] else {
            Issue.record("Expected a partially revealed frame from render offset on the open desktop edge")
            return
        }

        #expect(revealedColumn.renderOffset(at: animatedTime).x < -8)
        #expect(animatedLayout.hiddenHandles[revealedWindow.token] == nil)
        #expect(partialFrame.minX < monitor.visibleFrame.maxX)
        #expect(partialFrame.maxX > monitor.visibleFrame.maxX)
    }

    @Test func neighboringRightMonitorKeepsRenderOffsetRevealHiddenUntilFullyContained() {
        let fixture = makeHorizontalNeighboringRevealFixture(
            workspaceOnPrimary: true,
            withAnimationClock: true,
            pidBase: 91
        )
        let engine = fixture.engine
        let wsId = fixture.workspaceId
        let primaryMonitor = fixture.owningMonitor
        let secondaryMonitor = fixture.neighboringMonitor
        let leakingWindow = fixture.secondWindow

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        guard let leakingColumn = engine.columns(in: wsId).last,
              let baseTime = engine.animationClock?.now()
        else {
            Issue.record("Expected hidden column and animation clock for neighboring-monitor render-offset test")
            return
        }

        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: primaryMonitor,
            gaps: fixture.gaps,
            state: state,
            workingArea: fixture.area,
            animationTime: baseTime
        )
        #expect(hiddenLayout.hiddenHandles[leakingWindow.token] == .right)

        leakingColumn.animateMoveFrom(
            displacement: CGPoint(x: -40, y: 0),
            clock: engine.animationClock,
            config: engine.windowMovementAnimationConfig,
            displayRefreshRate: engine.displayRefreshRate
        )

        guard let partialTime = engine.animationClock?.now() else {
            Issue.record("Expected animation clock after neighboring-monitor render-offset animation")
            return
        }
        let partialLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: primaryMonitor,
            gaps: fixture.gaps,
            state: state,
            workingArea: fixture.area,
            animationTime: partialTime
        )
        guard let hiddenPlacementFrame = partialLayout.frames[leakingWindow.token] else {
            Issue.record("Expected hidden placement frame while neighboring monitor keeps render-offset reveal hidden")
            return
        }

        #expect(leakingColumn.renderOffset(at: partialTime).x < -8)
        #expect(partialLayout.hiddenHandles[leakingWindow.token] == .right)
        #expect(!hiddenPlacementFrame.intersects(secondaryMonitor.frame))

        leakingColumn.moveAnimation = nil
        leakingColumn.animateMoveFrom(
            displacement: CGPoint(x: -(primaryMonitor.visibleFrame.width + fixture.gap), y: 0),
            clock: engine.animationClock,
            config: engine.windowMovementAnimationConfig,
            displayRefreshRate: engine.displayRefreshRate
        )

        guard let fullyContainedTime = engine.animationClock?.now() else {
            Issue.record("Expected animation clock for full neighboring-monitor reveal")
            return
        }
        let fullyContainedLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: primaryMonitor,
            gaps: fixture.gaps,
            state: state,
            workingArea: fixture.area,
            animationTime: fullyContainedTime
        )
        guard let fullyContainedFrame = fullyContainedLayout.frames[leakingWindow.token] else {
            Issue.record("Expected a fully contained frame after render-offset reveal clears the monitor boundary")
            return
        }

        #expect(fullyContainedLayout.hiddenHandles[leakingWindow.token] == nil)
        #expect(fullyContainedFrame.minX >= primaryMonitor.visibleFrame.minX)
        #expect(fullyContainedFrame.maxX <= primaryMonitor.visibleFrame.maxX)
        #expect(!fullyContainedFrame.intersects(secondaryMonitor.frame))
    }

    @Test func neighboringUpperMonitorKeepsPartiallyRevealedRowHiddenUntilFullyContained() {
        let fixture = makeVerticalNeighboringRevealFixture(workspaceOnLowerMonitor: true, pidBase: 161)
        let engine = fixture.engine
        let wsId = fixture.workspaceId
        let lowerMonitor = fixture.owningMonitor
        let upperMonitor = fixture.neighboringMonitor
        let leakingWindow = fixture.secondWindow

        var hiddenState = ViewportState()
        hiddenState.activeColumnIndex = 0
        hiddenState.viewOffsetPixels = .static(0)
        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: lowerMonitor,
            gaps: fixture.gaps,
            state: hiddenState,
            workingArea: fixture.area,
            animationTime: nil
        )
        #expect(hiddenLayout.hiddenHandles[leakingWindow.token] == .right)

        var partialRevealState = hiddenState
        partialRevealState.viewOffsetPixels = .static(20)
        let partialRevealLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: lowerMonitor,
            gaps: fixture.gaps,
            state: partialRevealState,
            workingArea: fixture.area,
            animationTime: nil
        )
        #expect(partialRevealLayout.hiddenHandles[leakingWindow.token] == .right)

        var fullRevealState = hiddenState
        fullRevealState.viewOffsetPixels = .static(lowerMonitor.visibleFrame.height + fixture.gap)
        let fullyContainedLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: lowerMonitor,
            gaps: fixture.gaps,
            state: fullRevealState,
            workingArea: fixture.area,
            animationTime: nil
        )
        guard let fullyContainedFrame = fullyContainedLayout.frames[leakingWindow.token] else {
            Issue.record("Expected a fully contained frame for the upper-edge reveal test")
            return
        }

        #expect(fullyContainedLayout.hiddenHandles[leakingWindow.token] == nil)
        #expect(fullyContainedFrame.minY >= lowerMonitor.visibleFrame.minY)
        #expect(fullyContainedFrame.maxY <= lowerMonitor.visibleFrame.maxY)
        #expect(!fullyContainedFrame.intersects(upperMonitor.frame))
    }

    @Test func neighboringLowerMonitorKeepsPartiallyRevealedRowHiddenUntilFullyContained() {
        let fixture = makeVerticalNeighboringRevealFixture(workspaceOnLowerMonitor: false, pidBase: 171)
        let engine = fixture.engine
        let wsId = fixture.workspaceId
        let upperMonitor = fixture.owningMonitor
        let lowerMonitor = fixture.neighboringMonitor
        let leakingWindow = fixture.firstWindow
        let focusedWindow = fixture.secondWindow

        var hiddenState = ViewportState()
        hiddenState.activeColumnIndex = 1
        hiddenState.selectedNodeId = focusedWindow.id
        hiddenState.viewOffsetPixels = .static(0)
        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: upperMonitor,
            gaps: fixture.gaps,
            state: hiddenState,
            workingArea: fixture.area,
            animationTime: nil
        )
        #expect(hiddenLayout.hiddenHandles[leakingWindow.token] == .left)

        var partialRevealState = hiddenState
        partialRevealState.viewOffsetPixels = .static(-20)
        let partialRevealLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: upperMonitor,
            gaps: fixture.gaps,
            state: partialRevealState,
            workingArea: fixture.area,
            animationTime: nil
        )
        #expect(partialRevealLayout.hiddenHandles[leakingWindow.token] == .left)

        var fullRevealState = hiddenState
        fullRevealState.viewOffsetPixels = .static(-(upperMonitor.visibleFrame.height + fixture.gap))
        let fullyContainedLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: upperMonitor,
            gaps: fixture.gaps,
            state: fullRevealState,
            workingArea: fixture.area,
            animationTime: nil
        )
        guard let fullyContainedFrame = fullyContainedLayout.frames[leakingWindow.token] else {
            Issue.record("Expected a fully contained frame for the lower-edge reveal test")
            return
        }

        #expect(fullyContainedLayout.hiddenHandles[leakingWindow.token] == nil)
        #expect(fullyContainedFrame.minY >= upperMonitor.visibleFrame.minY)
        #expect(fullyContainedFrame.maxY <= upperMonitor.visibleFrame.maxY)
        #expect(!fullyContainedFrame.intersects(lowerMonitor.frame))
    }

    @Test func partialRevealRemainsVisibleAtOpenVerticalEdgesWithoutNeighboringMonitor() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1, maxVisibleColumns: 1)
        let wsId = UUID()
        let monitor = makeLayoutPlanTestMonitor(width: 900, height: 1600)
        attachWorkspace(
            wsId,
            to: monitor,
            engine: engine,
            resolvedSettings: resolvedSettings(
                for: engine,
                maxVisibleColumns: 2,
                centerFocusedColumn: .always
            )
        )

        let lowerWindow = engine.addWindow(handle: makeTestHandle(pid: 181), to: wsId, afterSelection: nil)
        let upperWindow = engine.addWindow(
            handle: makeTestHandle(pid: 182),
            to: wsId,
            afterSelection: lowerWindow.id
        )
        assignHeights(
            engine.columns(in: wsId),
            heights: [monitor.visibleFrame.height, monitor.visibleFrame.height]
        )

        let gaps = LayoutGaps(horizontal: 8, vertical: 8)
        let area = WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )

        var upperEdgeState = ViewportState()
        upperEdgeState.activeColumnIndex = 0
        upperEdgeState.viewOffsetPixels = .static(20)
        let upperEdgeLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: upperEdgeState,
            workingArea: area,
            animationTime: nil
        )
        guard let upperPartialFrame = upperEdgeLayout.frames[upperWindow.token] else {
            Issue.record("Expected a partially revealed upper row on the open vertical edge")
            return
        }

        #expect(upperEdgeLayout.hiddenHandles[upperWindow.token] == nil)
        #expect(upperPartialFrame.minY < monitor.visibleFrame.maxY)
        #expect(upperPartialFrame.maxY > monitor.visibleFrame.maxY)

        var lowerEdgeState = ViewportState()
        lowerEdgeState.activeColumnIndex = 1
        lowerEdgeState.selectedNodeId = upperWindow.id
        lowerEdgeState.viewOffsetPixels = .static(-20)
        let lowerEdgeLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: lowerEdgeState,
            workingArea: area,
            animationTime: nil
        )
        guard let lowerPartialFrame = lowerEdgeLayout.frames[lowerWindow.token] else {
            Issue.record("Expected a partially revealed lower row on the open vertical edge")
            return
        }

        #expect(lowerEdgeLayout.hiddenHandles[lowerWindow.token] == nil)
        #expect(lowerPartialFrame.minY < monitor.visibleFrame.minY)
        #expect(lowerPartialFrame.maxY > monitor.visibleFrame.minY)
    }

    @Test func neighboringUpperMonitorKeepsAnimatedVerticalRevealHiddenUntilFullyContained() {
        let fixture = makeVerticalNeighboringRevealFixture(
            workspaceOnLowerMonitor: true,
            withAnimationClock: true,
            pidBase: 191
        )
        let engine = fixture.engine
        let wsId = fixture.workspaceId
        let lowerMonitor = fixture.owningMonitor
        let upperMonitor = fixture.neighboringMonitor
        let leakingWindow = fixture.secondWindow

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)
        let baseTime = CACurrentMediaTime()

        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: lowerMonitor,
            gaps: fixture.gaps,
            state: state,
            workingArea: fixture.area,
            animationTime: baseTime
        )
        #expect(hiddenLayout.hiddenHandles[leakingWindow.token] == .right)

        let revealTarget = lowerMonitor.visibleFrame.height + fixture.gap
        var animatingState = state
        animatingState.viewOffsetPixels = .spring(
            SpringAnimation(
                from: 0,
                to: Double(revealTarget),
                startTime: baseTime,
                config: .snappy,
                displayRefreshRate: engine.displayRefreshRate
            )
        )
        let partialTime = baseTime + 0.05
        let partialLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: lowerMonitor,
            gaps: fixture.gaps,
            state: animatingState,
            workingArea: fixture.area,
            animationTime: partialTime
        )
        guard let hiddenPlacementFrame = partialLayout.frames[leakingWindow.token] else {
            Issue.record("Expected hidden placement frame while upper monitor keeps animated vertical reveal hidden")
            return
        }

        #expect(animatingState.viewOffsetPixels.value(at: partialTime) > 8)
        #expect(animatingState.viewOffsetPixels.value(at: partialTime) < revealTarget)
        #expect(partialLayout.hiddenHandles[leakingWindow.token] == .right)
        #expect(!hiddenPlacementFrame.intersects(upperMonitor.frame))

        var fullyContainedState = state
        fullyContainedState.viewOffsetPixels = .static(revealTarget)
        let fullyContainedLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: lowerMonitor,
            gaps: fixture.gaps,
            state: fullyContainedState,
            workingArea: fixture.area,
            animationTime: nil
        )
        guard let fullyContainedFrame = fullyContainedLayout.frames[leakingWindow.token] else {
            Issue.record("Expected a fully contained frame after animated vertical reveal clears the monitor boundary")
            return
        }

        #expect(fullyContainedLayout.hiddenHandles[leakingWindow.token] == nil)
        #expect(fullyContainedFrame.minY >= lowerMonitor.visibleFrame.minY)
        #expect(fullyContainedFrame.maxY <= lowerMonitor.visibleFrame.maxY)
        #expect(!fullyContainedFrame.intersects(upperMonitor.frame))
    }

    @Test @MainActor func visibilityChangesOnlyEmitOnActualTransitions() async throws {
        let monitor = makeLayoutPlanTestMonitor(width: 1600, height: 900)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing workspace for visibility-transition test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let firstToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 911)
        let transitioningToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 912)

        _ = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let engine = controller.niriEngine,
              let firstNode = engine.findNode(for: firstToken)
        else {
            Issue.record("Expected first node for visibility-transition test")
            return
        }

        let gap = CGFloat(controller.workspaceManager.gaps)
        let columnWidth = controller.insetWorkingFrame(for: monitor).width - gap
        for column in engine.columns(in: workspaceId) {
            column.width = .fixed(columnWidth)
            column.cachedWidth = columnWidth
        }

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = firstNode.id
            state.activeColumnIndex = 0
            state.viewOffsetPixels = .static(20)
        }

        let seededVisiblePlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard seededVisiblePlans.first != nil else {
            Issue.record("Expected visible seeding plan for visibility-transition test")
            return
        }
        controller.layoutRefreshController.executeLayoutPlans(seededVisiblePlans)

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .static(0)
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let initialPlan = initialPlans.first else {
            Issue.record("Expected hidden transition plan for visibility-transition test")
            return
        }

        #expect(hasHideVisibilityChange(initialPlan.diff.visibilityChanges, token: transitioningToken, side: .right))
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        let stableHiddenPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let stableHiddenPlan = stableHiddenPlans.first else {
            Issue.record("Expected repeated hidden-state plan for visibility-transition test")
            return
        }

        #expect(!hasAnyVisibilityChange(stableHiddenPlan.diff.visibilityChanges, token: transitioningToken))

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .static(20)
        }

        let revealPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let revealPlan = revealPlans.first else {
            Issue.record("Expected reveal plan for visibility-transition test")
            return
        }

        #expect(hasShowVisibilityChange(revealPlan.diff.visibilityChanges, token: transitioningToken))
        #expect(!hasHideVisibilityChange(revealPlan.diff.visibilityChanges, token: transitioningToken))
        controller.layoutRefreshController.executeLayoutPlans(revealPlans)

        let stableVisiblePlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let stableVisiblePlan = stableVisiblePlans.first else {
            Issue.record("Expected repeated visible-state plan for visibility-transition test")
            return
        }

        #expect(!hasAnyVisibilityChange(stableVisiblePlan.diff.visibilityChanges, token: transitioningToken))
    }

    @Test @MainActor func centeredColumnsDoNotEmitPrimaryWorkspaceFramesAcrossSecondaryMonitorBoundary() async throws {
        guard let fixture = await makeCenteredCrossMonitorFixture(
            workspaceSide: .primary,
            windowIds: 931 ... 934
        ) else {
            return
        }
        let controller = fixture.controller
        let activeWorkspaceIds: Set<WorkspaceDescriptor.ID> = [
            fixture.primaryWorkspaceId,
            fixture.secondaryWorkspaceId,
        ]

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: activeWorkspaceIds
        )
        await executeAndSettleLayoutPlans(initialPlans, on: controller)

        let primaryColumns = fixture.engine.columns(in: fixture.targetWorkspaceId)
        for column in primaryColumns {
            #expect(column.width == .proportion(0.85))
            #expect(column.presetWidthIdx == nil)
        }
        guard primaryColumns.count >= 3,
              let centeredWindow = primaryColumns[1].windowNodes.first,
              let leakingWindow = primaryColumns[2].windowNodes.first
        else {
            Issue.record("Expected at least three primary columns for cross-monitor leak regression test")
            return
        }

        selectWindowAndSettleViewport(
            leakingWindow,
            in: fixture.targetWorkspaceId,
            on: fixture.targetMonitor,
            engine: fixture.engine,
            controller: controller
        )
        let seededVisiblePlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: activeWorkspaceIds
        )
        await executeAndSettleLayoutPlans(seededVisiblePlans, on: controller)

        selectWindowAndSettleViewport(
            centeredWindow,
            in: fixture.targetWorkspaceId,
            on: fixture.targetMonitor,
            engine: fixture.engine,
            controller: controller
        )
        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: activeWorkspaceIds
        )
        guard let primaryPlan = plans.first(where: { $0.workspaceId == fixture.targetWorkspaceId }) else {
            Issue.record("Expected a primary-workspace plan for cross-monitor leak regression test")
            return
        }

        assertHideOnlyMonitorBoundaryDiff(
            primaryPlan,
            token: leakingWindow.token,
            side: .right,
            disallowedMonitor: fixture.neighboringMonitor
        )
    }

    @Test @MainActor func centeredColumnsDoNotEmitSecondaryWorkspaceFramesAcrossPrimaryMonitorBoundary() async throws {
        guard let fixture = await makeCenteredCrossMonitorFixture(
            workspaceSide: .secondary,
            windowIds: 941 ... 944
        ) else {
            return
        }
        let controller = fixture.controller
        let activeWorkspaceIds: Set<WorkspaceDescriptor.ID> = [
            fixture.primaryWorkspaceId,
            fixture.secondaryWorkspaceId,
        ]

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: activeWorkspaceIds
        )
        await executeAndSettleLayoutPlans(initialPlans, on: controller)

        let secondaryColumns = fixture.engine.columns(in: fixture.targetWorkspaceId)
        for column in secondaryColumns {
            #expect(column.width == .proportion(0.85))
            #expect(column.presetWidthIdx == nil)
        }
        guard secondaryColumns.count >= 4,
              let leakingWindow = secondaryColumns[0].windowNodes.first,
              let centeredWindow = secondaryColumns[2].windowNodes.first
        else {
            Issue.record("Expected at least four secondary columns for cross-monitor leak regression test")
            return
        }

        selectWindowAndSettleViewport(
            leakingWindow,
            in: fixture.targetWorkspaceId,
            on: fixture.targetMonitor,
            engine: fixture.engine,
            controller: controller
        )
        let seededVisiblePlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: activeWorkspaceIds
        )
        await executeAndSettleLayoutPlans(seededVisiblePlans, on: controller)

        selectWindowAndSettleViewport(
            centeredWindow,
            in: fixture.targetWorkspaceId,
            on: fixture.targetMonitor,
            engine: fixture.engine,
            controller: controller
        )
        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: activeWorkspaceIds
        )
        guard let secondaryPlan = plans.first(where: { $0.workspaceId == fixture.targetWorkspaceId }) else {
            Issue.record("Expected a secondary-workspace plan for cross-monitor leak regression test")
            return
        }

        assertHideOnlyMonitorBoundaryDiff(
            secondaryPlan,
            token: leakingWindow.token,
            side: .left,
            disallowedMonitor: fixture.neighboringMonitor
        )
    }

    @Test @MainActor func layoutHiddenPlacementMatchesLiveHideOriginForHiddenLeftColumn() async throws {
        let monitors = makeHorizontalNeighboringTestMonitors()
        let fixture = makeTwoMonitorLayoutPlanTestController(
            primaryMonitor: monitors.primary,
            secondaryMonitor: monitors.secondary
        )
        let controller = fixture.controller
        let workspaceId = fixture.primaryWorkspaceId

        suppressAutomaticRefreshExecution(on: controller)
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        var tokens: [WindowToken] = []
        for windowId in 921 ... 924 {
            tokens.append(addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId))
        }

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri engine for hidden-placement parity test")
            return
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        await executeAndSettleLayoutPlans(initialPlans, on: controller)

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .static(2500)
        }

        let (frames, hiddenHandles) = calculateCurrentLayout(
            controller: controller,
            engine: engine,
            workspaceId: workspaceId,
            monitor: monitors.primary
        )

        guard let token = tokens.first(where: { hiddenHandles[$0] == .left }),
              let canonicalFrame = engine.findNode(for: token)?.frame,
              let hiddenFrame = frames[token],
              let liveOrigin = controller.layoutRefreshController.liveFrameHideOrigin(
                  for: canonicalFrame,
                  monitor: monitors.primary,
                  side: .left,
                  pid: token.pid,
                  reason: .layoutTransient
              )
        else {
            Issue.record("Expected a hidden-left column and live hide origin for parity test")
            return
        }

        #expect(hiddenFrame.minX == liveOrigin.x)
        #expect(hiddenFrame.minY == liveOrigin.y)
    }

    @Test @MainActor func layoutHiddenPlacementMatchesLiveHideOriginForHiddenUpperRowInVerticalLayout() async throws {
        let monitors = makeVerticalStackedTestMonitors()
        let controller = makeLayoutPlanTestController(
            monitors: [monitors.lower, monitors.upper],
            workspaceConfigurations: [
                WorkspaceConfiguration(
                    name: "1",
                    monitorAssignment: .specificDisplay(OutputId(from: monitors.lower))
                ),
                WorkspaceConfiguration(
                    name: "2",
                    monitorAssignment: .specificDisplay(OutputId(from: monitors.upper))
                )
            ]
        )
        guard let workspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let upperWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Expected explicit stacked-monitor workspaces for vertical hidden-placement parity test")
            return
        }
        #expect(controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitors.lower.id))
        #expect(controller.workspaceManager.setActiveWorkspace(upperWorkspaceId, on: monitors.upper.id))
        _ = controller.workspaceManager.setInteractionMonitor(monitors.lower.id)

        suppressAutomaticRefreshExecution(on: controller)
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 951)
        let upperWindow = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 952)

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri engine for vertical hidden-placement parity test")
            return
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        await executeAndSettleLayoutPlans(initialPlans, on: controller)

        assignHeights(
            engine.columns(in: workspaceId),
            heights: [monitors.lower.visibleFrame.height, monitors.lower.visibleFrame.height]
        )

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.activeColumnIndex = 0
            state.viewOffsetPixels = .static(20)
        }

        let (frames, hiddenHandles) = calculateCurrentLayout(
            controller: controller,
            engine: engine,
            workspaceId: workspaceId,
            monitor: monitors.lower
        )

        guard hiddenHandles[upperWindow] == .right,
              let canonicalFrame = engine.findNode(for: upperWindow)?.frame,
              let hiddenFrame = frames[upperWindow],
              let liveOrigin = controller.layoutRefreshController.liveFrameHideOrigin(
                  for: canonicalFrame,
                  monitor: monitors.lower,
                  side: .right,
                  pid: upperWindow.pid,
                  reason: .layoutTransient
              )
        else {
            Issue.record("Expected a hidden upper row and live hide origin for vertical parity test")
            return
        }

        #expect(hiddenFrame.minX == liveOrigin.x)
        #expect(hiddenFrame.minY == liveOrigin.y)
    }

    @Test @MainActor func snapshotPlanUsesRemovalSeedForFallbackAndScrollParity() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for Niri removal-seed test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let removedToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 551)
        let survivingToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 552)
        _ = controller.workspaceManager.setManagedFocus(removedToken, in: workspaceId, onMonitor: monitor.id)

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        guard let engine = controller.niriEngine,
              let removedNodeId = engine.findNode(for: removedToken)?.id
        else {
            Issue.record("Expected Niri engine state for removal-seed test")
            return
        }

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = removedNodeId
        }
        let oldFrames = engine.captureWindowFrames(in: workspaceId)
        guard !oldFrames.isEmpty else {
            Issue.record("Expected non-empty Niri frame snapshot before removal")
            return
        }

        _ = controller.workspaceManager.removeWindow(pid: removedToken.pid, windowId: removedToken.windowId)

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId],
            useScrollAnimationPath: true,
            removalSeeds: [
                workspaceId: NiriWindowRemovalSeed(
                    removedNodeIds: [removedNodeId],
                    oldFrames: oldFrames
                )
            ]
        )
        guard let plan = plans.first else {
            Issue.record("Expected a Niri layout plan after removal")
            return
        }
        guard let survivingNodeId = engine.findNode(for: survivingToken)?.id else {
            Issue.record("Expected surviving node after Niri removal")
            return
        }

        #expect(!plan.diff.frameChanges.contains(where: { $0.token == removedToken }))
        #expect(
            plan.diff.frameChanges.contains(where: { $0.token == survivingToken }) ||
                hasAnyVisibilityChange(plan.diff.visibilityChanges, token: survivingToken)
        )
        #expect(plan.sessionPatch.rememberedFocusToken == survivingToken)
        #expect(plan.sessionPatch.viewportState?.selectedNodeId == survivingNodeId)
        #expect(hasNiriScrollDirective(plan.animationDirectives, workspaceId: workspaceId))
    }

    @Test @MainActor func nonFocusedWorkspacePlanDoesNotClearFocusedBorder() async throws {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        controller.setBordersEnabled(true)
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let primaryToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.primaryWorkspaceId,
            windowId: 601
        )
        _ = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.secondaryWorkspaceId,
            windowId: 602
        )
        _ = controller.workspaceManager.setManagedFocus(
            primaryToken,
            in: fixture.primaryWorkspaceId,
            onMonitor: fixture.primaryMonitor.id
        )

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [fixture.primaryWorkspaceId, fixture.secondaryWorkspaceId],
            useScrollAnimationPath: true
        )
        controller.layoutRefreshController.executeLayoutPlans(plans)

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 601)
    }

    @Test @MainActor func directBorderUpdateUsesConfirmedFocusInsteadOfRememberedFocus() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for direct border focus-source regression test")
            return
        }

        controller.setBordersEnabled(true)
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)

        let focusedToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: 609,
            pid: 8_101
        )
        let rememberedToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: 610,
            pid: 8_102
        )
        _ = controller.workspaceManager.setManagedFocus(focusedToken, in: workspaceId, onMonitor: monitor.id)
        _ = controller.workspaceManager.applySessionPatch(
            .init(workspaceId: workspaceId, rememberedFocusToken: rememberedToken)
        )

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId],
            useScrollAnimationPath: true
        )
        controller.layoutRefreshController.executeLayoutPlans(plans)

        #expect(controller.workspaceManager.focusedToken == focusedToken)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 609)
    }

    @Test @MainActor func focusNeighborUsesObservedGhosttyFrameForDirectBorderUpdatesFromEitherSide() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for Ghostty navigation border regression test")
            return
        }

        controller.setBordersEnabled(true)
        controller.enableNiriLayout(
            maxWindowsPerColumn: 1,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        controller.updateNiriConfig(
            maxVisibleColumns: 3,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.layoutRefreshController.stopAllScrollAnimations()
        controller.syncMonitorsToNiriEngine()

        let firstToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: 611,
            pid: 7_001
        )
        _ = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: 612,
            pid: 7_002
        )
        _ = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: 613,
            pid: 7_003
        )
        _ = controller.workspaceManager.setManagedFocus(firstToken, in: workspaceId, onMonitor: monitor.id)

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(plans)

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri window nodes for Ghostty navigation border regression test")
            return
        }

        let columns = engine.columns(in: workspaceId)

        guard columns.count == 3,
              let leftNode = columns[0].windowNodes.first,
              let ghosttyNode = columns[1].windowNodes.first,
              let rightNode = columns[2].windowNodes.first,
              let ghosttyLayoutFrame = ghosttyNode.renderedFrame ?? ghosttyNode.frame
        else {
            Issue.record("Expected three visible columns and a realized center frame for Ghostty navigation border regression test")
            return
        }

        let leftWindow = (token: leftNode.token, node: leftNode)
        let ghosttyWindow = (token: ghosttyNode.token, node: ghosttyNode)
        let rightWindow = (token: rightNode.token, node: rightNode)

        controller.appInfoCache.storeInfoForTests(
            pid: ghosttyWindow.token.pid,
            bundleId: "com.mitchellh.ghostty"
        )

        let observedFrame = CGRect(
            x: ghosttyLayoutFrame.minX,
            y: ghosttyLayoutFrame.minY - 24,
            width: ghosttyLayoutFrame.width,
            height: ghosttyLayoutFrame.height + 24
        )
        controller.borderCoordinator.observedFrameProviderForTests = { axRef in
            axRef.windowId == ghosttyWindow.token.windowId ? observedFrame : nil
        }
        defer {
            controller.borderCoordinator.observedFrameProviderForTests = nil
        }

        func primeNavigation(
            from token: WindowToken,
            node: NiriWindow
        ) {
            controller.layoutRefreshController.stopAllScrollAnimations()
            controller.borderManager.hideBorder()
            _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
            _ = controller.workspaceManager.commitWorkspaceSelection(
                nodeId: node.id,
                focusedToken: token,
                in: workspaceId,
                onMonitor: monitor.id
            )
            controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
                state.selectedNodeId = node.id
                engine.ensureSelectionVisible(
                    node: node,
                    in: workspaceId,
                    state: &state,
                    workingFrame: controller.insetWorkingFrame(for: monitor),
                    gaps: CGFloat(controller.workspaceManager.gaps)
                )
                state.viewOffsetPixels = .static(state.viewOffsetPixels.target())
            }
            node.animateMoveFrom(
                displacement: CGPoint(x: 18, y: 0),
                clock: engine.animationClock,
                config: engine.windowMovementAnimationConfig,
                displayRefreshRate: engine.displayRefreshRate
            )
            #expect(engine.hasAnyWindowAnimationsRunning(in: workspaceId))
            #expect(controller.niriLayoutHandler.registerScrollAnimation(workspaceId, on: monitor.displayId))
        }

        primeNavigation(from: leftWindow.token, node: leftWindow.node)
        controller.niriLayoutHandler.focusNeighbor(direction: .right)
        await waitForLayoutPlanRefreshWork(on: controller)

        #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == ghosttyWindow.token)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId == ghosttyWindow.node.id)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == ghosttyWindow.token.windowId)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == observedFrame)

        primeNavigation(from: rightWindow.token, node: rightWindow.node)
        controller.niriLayoutHandler.focusNeighbor(direction: .left)
        await waitForLayoutPlanRefreshWork(on: controller)

        #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == ghosttyWindow.token)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId == ghosttyWindow.node.id)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == ghosttyWindow.token.windowId)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == observedFrame)
    }

    @Test @MainActor func focusNeighborRoundTripDoesNotStartSecondSpringAfterSettledOffscreenMove() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for focus-neighbor round-trip regression test")
            return
        }

        controller.enableNiriLayout(
            maxWindowsPerColumn: 1,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        controller.updateNiriConfig(
            maxVisibleColumns: 2,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri engine for focus-neighbor round-trip regression test")
            return
        }

        for windowId in 641 ... 645 {
            _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId)
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        let gap = CGFloat(controller.workspaceManager.gaps)
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let fixedWidth = (workingFrame.width - gap) / 2
        for column in engine.columns(in: workspaceId) {
            column.width = .fixed(fixedWidth)
            column.cachedWidth = fixedWidth
        }

        let columns = engine.columns(in: workspaceId)
        let windows = columns.compactMap(\.windowNodes.first)
        guard windows.count >= 5 else {
            Issue.record("Expected five columns for focus-neighbor round-trip regression test")
            return
        }

        let columnStride = fixedWidth + gap

        func setSelection(activeIndex: Int, visibleStartIndex: Int) {
            let node = windows[activeIndex]
            let expectedViewStart = CGFloat(visibleStartIndex) * columnStride
            controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
                state.selectedNodeId = node.id
                state.activeColumnIndex = activeIndex
                state.viewOffsetPixels = .static(
                    expectedViewStart
                        - state.columnX(at: activeIndex, columns: columns, gap: gap)
                )
            }
            _ = controller.workspaceManager.setManagedFocus(node.token, in: workspaceId, onMonitor: monitor.id)
            _ = controller.workspaceManager.commitWorkspaceSelection(
                nodeId: node.id,
                focusedToken: node.token,
                in: workspaceId,
                onMonitor: monitor.id
            )
            controller.layoutRefreshController.stopAllScrollAnimations()
        }

        func settleViewport() {
            controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
                state.viewOffsetPixels = .static(state.viewOffsetPixels.target())
            }
            controller.layoutRefreshController.stopAllScrollAnimations()
        }

        setSelection(activeIndex: 1, visibleStartIndex: 0)
        controller.niriLayoutHandler.focusNeighbor(direction: .right)
        await waitForLayoutPlanRefreshWork(on: controller)

        let firstMoveState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == windows[2].token)
        #expect(firstMoveState.viewOffsetPixels.isAnimating)
        #expect(abs(viewportStart(for: firstMoveState, columns: columns, gap: gap) - columnStride) < 0.1)

        settleViewport()
        controller.niriLayoutHandler.focusNeighbor(direction: .left)
        await waitForLayoutPlanRefreshWork(on: controller)

        let firstReverseState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == windows[1].token)
        #expect(!firstReverseState.viewOffsetPixels.isAnimating)
        #expect(abs(viewportStart(for: firstReverseState, columns: columns, gap: gap) - columnStride) < 0.1)
    }

    @Test @MainActor func focusNeighborWithAnimationsDisabledUsesExactVisibleColumnOffsets() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for disabled focus-neighbor regression test")
            return
        }

        controller.enableNiriLayout(
            maxWindowsPerColumn: 1,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri engine for disabled focus-neighbor regression test")
            return
        }

        for windowId in 651 ... 656 {
            _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId)
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        let gap = CGFloat(controller.workspaceManager.gaps)
        let workingFrame = controller.insetWorkingFrame(for: monitor)

        struct Scenario {
            let visibleCount: Int
            let startingActiveIndex: Int
        }

        let scenarios = [
            Scenario(visibleCount: 2, startingActiveIndex: 1),
            Scenario(visibleCount: 3, startingActiveIndex: 2),
        ]

        controller.setAnimationsEnabled(false)

        for scenario in scenarios {
            let comment = Comment(rawValue: "maxVisibleColumns=\(scenario.visibleCount)")
            engine.maxVisibleColumns = scenario.visibleCount
            engine.centerFocusedColumn = .never
            engine.alwaysCenterSingleColumn = false

            let fixedWidth = (
                workingFrame.width - gap * CGFloat(scenario.visibleCount - 1)
            ) / CGFloat(scenario.visibleCount)
            for column in engine.columns(in: workspaceId) {
                column.width = .fixed(fixedWidth)
                column.cachedWidth = fixedWidth
            }

            let columns = engine.columns(in: workspaceId)
            let windows = columns.compactMap(\.windowNodes.first)
            guard windows.count >= scenario.visibleCount + 2 else {
                Issue.record("Expected enough columns for disabled focus-neighbor regression test")
                return
            }

            let columnStride = fixedWidth + gap

            func setSelection(activeIndex: Int, visibleStartIndex: Int) {
                let node = windows[activeIndex]
                let expectedViewStart = CGFloat(visibleStartIndex) * columnStride
                controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
                    state.selectedNodeId = node.id
                    state.activeColumnIndex = activeIndex
                    state.viewOffsetPixels = .static(
                        expectedViewStart
                            - state.columnX(at: activeIndex, columns: columns, gap: gap)
                    )
                }
                _ = controller.workspaceManager.setManagedFocus(node.token, in: workspaceId, onMonitor: monitor.id)
                _ = controller.workspaceManager.commitWorkspaceSelection(
                    nodeId: node.id,
                    focusedToken: node.token,
                    in: workspaceId,
                    onMonitor: monitor.id
                )
                controller.layoutRefreshController.stopAllScrollAnimations()
            }

            setSelection(activeIndex: scenario.startingActiveIndex, visibleStartIndex: 0)

            controller.niriLayoutHandler.focusNeighbor(direction: .right)
            await waitForLayoutPlanRefreshWork(on: controller)

            let movedState = controller.workspaceManager.niriViewportState(for: workspaceId)
            #expect(
                controller.workspaceManager.preferredFocusToken(in: workspaceId)
                    == windows[scenario.startingActiveIndex + 1].token,
                comment
            )
            #expect(!movedState.viewOffsetPixels.isAnimating, comment)
            #expect(abs(viewportStart(for: movedState, columns: columns, gap: gap) - columnStride) < 0.1, comment)

            for _ in 0..<windows.count {
                if controller.workspaceManager.preferredFocusToken(in: workspaceId) == windows[0].token {
                    break
                }

                controller.niriLayoutHandler.focusNeighbor(direction: .left)
                await waitForLayoutPlanRefreshWork(on: controller)

                let stepState = controller.workspaceManager.niriViewportState(for: workspaceId)
                #expect(!stepState.viewOffsetPixels.isAnimating, comment)
            }

            let finalState = controller.workspaceManager.niriViewportState(for: workspaceId)
            #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == windows[0].token, comment)
            #expect(abs(viewportStart(for: finalState, columns: columns, gap: gap)) < 0.1, comment)
        }
    }

    @Test @MainActor func turningAnimationsOffLeavesInFlightViewportMotionAloneAndMakesNextNavigationInstant() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for animation-toggle viewport semantics test")
            return
        }

        controller.enableNiriLayout(
            maxWindowsPerColumn: 1,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        controller.updateNiriConfig(
            maxVisibleColumns: 2,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri engine for animation-toggle viewport semantics test")
            return
        }

        for windowId in 661 ... 665 {
            _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId)
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        let gap = CGFloat(controller.workspaceManager.gaps)
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let fixedWidth = (workingFrame.width - gap) / 2
        for column in engine.columns(in: workspaceId) {
            column.width = .fixed(fixedWidth)
            column.cachedWidth = fixedWidth
        }

        let columns = engine.columns(in: workspaceId)
        let windows = columns.compactMap(\.windowNodes.first)
        guard windows.count >= 5 else {
            Issue.record("Expected five columns for animation-toggle viewport semantics test")
            return
        }

        let columnStride = fixedWidth + gap

        func setSelection(activeIndex: Int, visibleStartIndex: Int) {
            let node = windows[activeIndex]
            let expectedViewStart = CGFloat(visibleStartIndex) * columnStride
            controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
                state.selectedNodeId = node.id
                state.activeColumnIndex = activeIndex
                state.viewOffsetPixels = .static(
                    expectedViewStart
                        - state.columnX(at: activeIndex, columns: columns, gap: gap)
                )
            }
            _ = controller.workspaceManager.setManagedFocus(node.token, in: workspaceId, onMonitor: monitor.id)
            _ = controller.workspaceManager.commitWorkspaceSelection(
                nodeId: node.id,
                focusedToken: node.token,
                in: workspaceId,
                onMonitor: monitor.id
            )
            controller.layoutRefreshController.stopAllScrollAnimations()
        }

        setSelection(activeIndex: 1, visibleStartIndex: 0)
        controller.niriLayoutHandler.focusNeighbor(direction: .right)
        await waitForLayoutPlanRefreshWork(on: controller)

        let animatingState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(animatingState.viewOffsetPixels.isAnimating)

        controller.setAnimationsEnabled(false)

        let midToggleState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(midToggleState.viewOffsetPixels.isAnimating)

        controller.layoutRefreshController.settleAllAnimationsForTests()

        let settledState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(!settledState.viewOffsetPixels.isAnimating)
        #expect(abs(viewportStart(for: settledState, columns: columns, gap: gap) - columnStride) < 0.1)

        controller.niriLayoutHandler.focusNeighbor(direction: .left)
        await waitForLayoutPlanRefreshWork(on: controller)

        let nextState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == windows[1].token)
        #expect(!nextState.viewOffsetPixels.isAnimating)
        #expect(abs(viewportStart(for: nextState, columns: columns, gap: gap) - columnStride) < 0.1)
    }

    @Test @MainActor func visibleSecondaryWorkspacePlanRestoresInactiveHiddenWindows() async throws {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let token = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.secondaryWorkspaceId,
            windowId: 650
        )
        setWorkspaceInactiveHiddenStateForLayoutPlanTests(
            on: controller,
            token: token,
            monitor: fixture.secondaryMonitor
        )

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [fixture.primaryWorkspaceId, fixture.secondaryWorkspaceId],
            useScrollAnimationPath: true
        )
        guard let secondaryPlan = plans.first(where: { $0.workspaceId == fixture.secondaryWorkspaceId }) else {
            Issue.record("Expected a plan for the visible secondary workspace")
            return
        }

        #expect(secondaryPlan.diff.restoreChanges.contains { $0.token == token })
    }

    @Test @MainActor func staleScrollAnimationStopsBeforeRestoringInactiveWorkspaceWindows() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let originalWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let replacementWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing monitor or workspaces for stale Niri animation test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: originalWorkspaceId, windowId: 603)
        _ = controller.workspaceManager.setManagedFocus(token, in: originalWorkspaceId, onMonitor: monitor.id)

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [originalWorkspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(plans)

        setWorkspaceInactiveHiddenStateForLayoutPlanTests(on: controller, token: token, monitor: monitor)
        controller.layoutRefreshController.stopAllScrollAnimations()
        #expect(controller.niriLayoutHandler.registerScrollAnimation(originalWorkspaceId, on: monitor.displayId))
        _ = controller.workspaceManager.setActiveWorkspace(replacementWorkspaceId, on: monitor.id)

        controller.niriLayoutHandler.tickScrollAnimation(targetTime: 1, displayId: monitor.displayId)

        #expect(controller.niriLayoutHandler.scrollAnimationByDisplay[monitor.displayId] == nil)
        #expect(controller.workspaceManager.hiddenState(for: token)?.workspaceInactive == true)
    }
}
