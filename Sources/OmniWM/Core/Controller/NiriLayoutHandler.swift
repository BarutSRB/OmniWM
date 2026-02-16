import AppKit
import Foundation
import QuartzCore

@MainActor final class NiriLayoutHandler {
    weak var controller: WMController?

    struct NiriLayoutPass {
        let wsId: WorkspaceDescriptor.ID
        let engine: NiriLayoutEngine
        let monitor: Monitor
        let insetFrame: CGRect
        let gap: CGFloat
    }

    struct RemovalContext {
        var existingHandleIds: Set<UUID>
        var wasEmptyBeforeSync: Bool
        var columnRemovalResult: NiriLayoutEngine.ColumnRemovalResult?
        var precomputedFallback: NodeId?
        var originalColumnIndex: Int?
    }

    var scrollAnimationByDisplay: [CGDirectDisplayID: WorkspaceDescriptor.ID] = [:]

    init(controller: WMController?) {
        self.controller = controller
    }

    func registerScrollAnimation(_ workspaceId: WorkspaceDescriptor.ID, on displayId: CGDirectDisplayID) -> Bool {
        if scrollAnimationByDisplay[displayId] == workspaceId {
            return false
        }
        scrollAnimationByDisplay[displayId] = workspaceId
        return true
    }

    func tickScrollAnimation(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard let wsId = scrollAnimationByDisplay[displayId] else { return }
        guard let controller, let engine = controller.niriEngine else {
            controller?.layoutRefreshController.stopScrollAnimation(for: displayId)
            return
        }

        var state = controller.workspaceManager.niriViewportState(for: wsId)

        let viewportAnimationRunning = state.advanceAnimations(at: targetTime)
        let windowAnimationsRunning = engine.tickAllWindowAnimations(in: wsId, at: targetTime)
        let columnAnimationsRunning = engine.tickAllColumnAnimations(in: wsId, at: targetTime)
        let workspaceSwitchRunning = engine.tickWorkspaceSwitchAnimation(for: wsId, at: targetTime)

        guard let monitor = controller.workspaceManager.monitors.first(where: { $0.displayId == displayId }) else {
            controller.workspaceManager.updateNiriViewportState(state, for: wsId)
            controller.layoutRefreshController.stopScrollAnimation(for: displayId)
            return
        }

        applyFramesOnDemand(
            wsId: wsId,
            state: state,
            engine: engine,
            monitor: monitor,
            animationTime: targetTime
        )

        let animationsOngoing = viewportAnimationRunning
            || windowAnimationsRunning
            || columnAnimationsRunning
            || workspaceSwitchRunning

        controller.workspaceManager.updateNiriViewportState(state, for: wsId)

        if !animationsOngoing {
            finalizeAnimation()
            controller.layoutRefreshController.stopScrollAnimation(for: displayId)
        }
    }

    func applyFramesOnDemand(
        wsId: WorkspaceDescriptor.ID,
        state: ViewportState,
        engine: NiriLayoutEngine,
        monitor: Monitor,
        animationTime: TimeInterval? = nil
    ) {
        guard let controller else { return }
        let lrc = controller.layoutRefreshController

        let gaps = LayoutGaps(
            horizontal: CGFloat(controller.workspaceManager.gaps),
            vertical: CGFloat(controller.workspaceManager.gaps),
            outer: controller.workspaceManager.outerGaps
        )

        let insetFrame = controller.insetWorkingFrame(for: monitor)
        let area = WorkingAreaContext(
            workingFrame: insetFrame,
            viewFrame: monitor.frame,
            scale: lrc.backingScale(for: monitor)
        )
        let edgeFrame = monitor.visibleFrame
        let monitors = controller.workspaceManager.monitors

        let (frames, hiddenHandles) = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: animationTime
        )

        var positionUpdates: [(windowId: Int, origin: CGPoint)] = []
        var frameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []
        var alphaUpdates: [(windowId: UInt32, alpha: Float)] = []

        let time = animationTime ?? CACurrentMediaTime()

        for (handle, frame) in frames {
            guard let entry = controller.workspaceManager.entry(for: handle) else { continue }

            if let node = engine.findNode(for: handle) {
                let alpha = node.renderAlpha(at: time)
                let needsReset = node.consumeAlphaReset()
                if alpha < 0.999 || node.hasAlphaAnimationRunning || needsReset {
                    alphaUpdates.append((UInt32(entry.windowId), Float(alpha)))
                }
            }

            if let side = hiddenHandles[handle] {
                let actualSize = AXWindowService.framePreferFast(entry.axRef)?.size ?? frame.size
                let hiddenOrigin = lrc.hiddenOrigin(
                    for: actualSize,
                    edgeFrame: edgeFrame,
                    scale: area.scale,
                    side: side,
                    pid: handle.pid,
                    targetY: frame.origin.y,
                    monitor: monitor,
                    monitors: monitors
                )
                positionUpdates.append((entry.windowId, hiddenOrigin))
                continue
            }

            frameUpdates.append((handle.pid, entry.windowId, frame))
        }

        if !positionUpdates.isEmpty {
            controller.axManager.applyPositionsViaSkyLight(positionUpdates)
        }
        if !frameUpdates.isEmpty {
            controller.axManager.applyFramesParallel(frameUpdates)
        }
        for (windowId, alpha) in alphaUpdates {
            SkyLight.shared.setWindowAlpha(windowId, alpha: alpha)
        }
    }

    private func finalizeAnimation() {
        guard let controller,
              let focusedHandle = controller.focusedHandle,
              let entry = controller.workspaceManager.entry(for: focusedHandle),
              let engine = controller.niriEngine
        else { return }

        if let node = engine.findNode(for: focusedHandle),
           let frame = node.frame {
            controller.updateBorderIfAllowed(handle: focusedHandle, frame: frame, windowId: entry.windowId)
        }

        if controller.moveMouseToFocusedWindowEnabled {
            controller.moveMouseToWindow(focusedHandle)
        }
    }

    func cancelActiveAnimations(for workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }

        for (displayId, wsId) in scrollAnimationByDisplay where wsId == workspaceId {
            controller.layoutRefreshController.stopScrollAnimation(for: displayId)
        }

        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        state.cancelAnimation()
        controller.workspaceManager.updateNiriViewportState(state, for: workspaceId)
    }

    func layoutWithNiriEngine(activeWorkspaces: Set<WorkspaceDescriptor.ID>, useScrollAnimationPath: Bool = false, removedNodeId: NodeId? = nil) async {
        guard let controller, let engine = controller.niriEngine else { return }
        let lrc = controller.layoutRefreshController

        for monitor in controller.workspaceManager.monitors {
            guard let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) else { continue }
            lrc.unhideWorkspace(workspace.id, monitor: monitor)
        }

        var processedWorkspaces: Set<WorkspaceDescriptor.ID> = []
        for monitor in controller.workspaceManager.monitors {
            guard let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) else { continue }
            let wsId = workspace.id
            guard !processedWorkspaces.contains(wsId) else { continue }
            processedWorkspaces.insert(wsId)

            let layoutType = controller.settings.layoutType(for: workspace.name)
            if layoutType == .dwindle { continue }

            let windowHandles = controller.workspaceManager.entries(in: wsId).map(\.handle)
            let currentSelection = controller.workspaceManager.niriViewportState(for: wsId).selectedNodeId
            var state = controller.workspaceManager.niriViewportState(for: wsId)

            let pass = NiriLayoutPass(
                wsId: wsId,
                engine: engine,
                monitor: monitor,
                insetFrame: controller.insetWorkingFrame(for: monitor),
                gap: CGFloat(controller.workspaceManager.gaps)
            )

            let removal = processWindowRemovals(
                pass: pass,
                state: &state,
                windowHandles: windowHandles,
                currentSelection: currentSelection,
                removedNodeId: removedNodeId
            )

            let newHandles = syncAndInsert(
                pass: pass,
                state: &state,
                windowHandles: windowHandles,
                removal: removal
            )

            lrc.updateWindowConstraints(in: wsId) { engine.updateWindowConstraints(for: $0, constraints: $1) }

            let viewportNeedsRecalc = resolveSelection(
                pass: pass,
                state: &state,
                windowHandles: windowHandles,
                removal: removal
            )

            let newWindowHandle = handleNewWindowArrival(
                pass: pass,
                state: &state,
                newHandles: newHandles,
                existingHandleIds: removal.existingHandleIds
            )

            computeAndApplyLayout(
                pass: pass,
                state: state,
                newWindowHandle: newWindowHandle,
                viewportNeedsRecalc: viewportNeedsRecalc,
                useScrollAnimationPath: useScrollAnimationPath
            )

            await Task.yield()
        }

        updateTabbedColumnOverlays()
        controller.updateWorkspaceBar()
    }

    private func processWindowRemovals(
        pass: NiriLayoutPass,
        state: inout ViewportState,
        windowHandles: [WindowHandle],
        currentSelection: NodeId?,
        removedNodeId: NodeId?
    ) -> RemovalContext {
        let existingHandleIds = pass.engine.root(for: pass.wsId)?.windowIdSet ?? []
        var currentHandleIds = Set<UUID>(minimumCapacity: windowHandles.count)
        for handle in windowHandles {
            currentHandleIds.insert(handle.id)
        }
        let removedHandleIds = existingHandleIds.subtracting(currentHandleIds)

        var precomputedFallback: NodeId?
        var originalColumnIndex: Int?
        var columnRemovalResult: NiriLayoutEngine.ColumnRemovalResult?

        let wasEmptyBeforeSync = pass.engine.columns(in: pass.wsId).isEmpty

        for removedHandleId in removedHandleIds {
            guard let window = pass.engine.root(for: pass.wsId)?.allWindows.first(where: { $0.handle.id == removedHandleId }),
                  let col = pass.engine.column(of: window),
                  let colIdx = pass.engine.columnIndex(of: col, in: pass.wsId) else { continue }

            let allWindowsInColumnRemoved = col.windowNodes.allSatisfy { w in
                !currentHandleIds.contains(w.handle.id)
            }

            if allWindowsInColumnRemoved && columnRemovalResult == nil {
                originalColumnIndex = colIdx
                columnRemovalResult = pass.engine.animateColumnsForRemoval(
                    columnIndex: colIdx,
                    in: pass.wsId,
                    state: &state,
                    gaps: pass.gap
                )
            }

            let nodeIdForFallback = removedNodeId ?? currentSelection
            if window.id == nodeIdForFallback {
                precomputedFallback = pass.engine.fallbackSelectionOnRemoval(
                    removing: window.id,
                    in: pass.wsId
                )
            }
        }

        return RemovalContext(
            existingHandleIds: existingHandleIds,
            wasEmptyBeforeSync: wasEmptyBeforeSync,
            columnRemovalResult: columnRemovalResult,
            precomputedFallback: precomputedFallback,
            originalColumnIndex: originalColumnIndex
        )
    }

    private func syncAndInsert(
        pass: NiriLayoutPass,
        state: inout ViewportState,
        windowHandles: [WindowHandle],
        removal: RemovalContext
    ) -> [WindowHandle] {
        guard let controller else { return [] }

        let currentSelection = state.selectedNodeId
        _ = pass.engine.syncWindows(
            windowHandles,
            in: pass.wsId,
            selectedNodeId: currentSelection,
            focusedHandle: controller.focusedHandle
        )
        let newHandles = windowHandles.filter { !removal.existingHandleIds.contains($0.id) }

        for col in pass.engine.columns(in: pass.wsId) {
            if col.cachedWidth <= 0 {
                col.resolveAndCacheWidth(workingAreaWidth: pass.insetFrame.width, gaps: pass.gap)
            }
        }

        if !removal.wasEmptyBeforeSync, !newHandles.isEmpty {
            var newColumnData: [(col: NiriContainer, colIdx: Int)] = []
            for newHandle in newHandles {
                if let node = pass.engine.findNode(for: newHandle),
                   let col = pass.engine.column(of: node),
                   let colIdx = pass.engine.columnIndex(of: col, in: pass.wsId)
                {
                    if !newColumnData.contains(where: { $0.col.id == col.id }) {
                        newColumnData.append((col, colIdx))
                    }
                }
            }

            let originalActiveIdx = state.activeColumnIndex
            let insertedBeforeActive = newColumnData.filter { $0.colIdx <= originalActiveIdx }
            if !insertedBeforeActive.isEmpty, removal.columnRemovalResult == nil {
                let totalInsertedWidth = insertedBeforeActive.reduce(CGFloat(0)) { total, data in
                    total + data.col.cachedWidth + pass.gap
                }
                state.viewOffsetPixels.offset(delta: Double(-totalInsertedWidth))
                state.activeColumnIndex = originalActiveIdx + insertedBeforeActive.count
            }

            let sortedNewColumns = newColumnData.sorted { $0.colIdx < $1.colIdx }
            for addedData in sortedNewColumns {
                pass.engine.animateColumnsForAddition(
                    columnIndex: addedData.colIdx,
                    in: pass.wsId,
                    state: state,
                    gaps: pass.gap,
                    workingAreaWidth: pass.insetFrame.width
                )
            }
        }

        return newHandles
    }

    private func resolveSelection(
        pass: NiriLayoutPass,
        state: inout ViewportState,
        windowHandles: [WindowHandle],
        removal: RemovalContext
    ) -> Bool {
        guard let controller else { return false }
        let lrc = controller.layoutRefreshController

        state.displayRefreshRate = lrc.layoutState.refreshRateByDisplay[pass.monitor.displayId] ?? 60.0

        if let result = removal.columnRemovalResult {
            if let prevOffset = state.activatePrevColumnOnRemoval {
                state.viewOffsetPixels = .static(prevOffset)
                state.activatePrevColumnOnRemoval = nil
            }

            if let fallback = result.fallbackSelectionId {
                state.selectedNodeId = fallback
            } else if let selectedId = state.selectedNodeId, pass.engine.findNode(by: selectedId) == nil {
                state.selectedNodeId = removal.precomputedFallback
                    ?? pass.engine.validateSelection(selectedId, in: pass.wsId)
            }
        } else {
            if let selectedId = state.selectedNodeId {
                if pass.engine.findNode(by: selectedId) == nil {
                    state.selectedNodeId = removal.precomputedFallback
                        ?? pass.engine.validateSelection(selectedId, in: pass.wsId)
                }
            }
        }

        if state.selectedNodeId == nil {
            if let firstHandle = windowHandles.first,
               let firstNode = pass.engine.findNode(for: firstHandle)
            {
                state.selectedNodeId = firstNode.id
            }
        }

        let offsetBefore = state.viewOffsetPixels.current()
        var viewportNeedsRecalc = false

        let isGestureOrAnimation = state.viewOffsetPixels.isGesture || state.viewOffsetPixels.isAnimating

        for col in pass.engine.columns(in: pass.wsId) {
            if col.cachedWidth <= 0 {
                col.resolveAndCacheWidth(workingAreaWidth: pass.insetFrame.width, gaps: pass.gap)
            }
        }

        if !isGestureOrAnimation,
           pass.wsId == controller.activeWorkspace()?.id,
           let selectedId = state.selectedNodeId,
           let selectedNode = pass.engine.findNode(by: selectedId)
        {
            if let restoreOffset = removal.columnRemovalResult?.restorePreviousViewOffset {
                state.viewOffsetPixels = .static(restoreOffset)
            } else {
                pass.engine.ensureSelectionVisible(
                    node: selectedNode,
                    in: pass.wsId,
                    state: &state,
                    workingFrame: pass.insetFrame,
                    gaps: pass.gap,
                    alwaysCenterSingleColumn: pass.engine.alwaysCenterSingleColumn,
                    fromContainerIndex: removal.originalColumnIndex
                )
            }
            if abs(state.viewOffsetPixels.current() - offsetBefore) > 1 {
                controller.workspaceManager.updateNiriViewportState(state, for: pass.wsId)
                viewportNeedsRecalc = true
            }
        }

        if let selectedId = state.selectedNodeId,
           let selectedNode = pass.engine.findNode(by: selectedId) as? NiriWindow
        {
            controller.focusManager.updateWorkspaceFocusMemory(selectedNode.handle, for: pass.wsId)
            if let currentFocused = controller.focusedHandle {
                if controller.workspaceManager.workspace(for: currentFocused) == pass.wsId {
                    controller.focusManager.setFocus(selectedNode.handle, in: pass.wsId)
                }
            } else {
                controller.focusManager.setFocus(selectedNode.handle, in: pass.wsId)
            }
        }

        return viewportNeedsRecalc
    }

    private func handleNewWindowArrival(
        pass: NiriLayoutPass,
        state: inout ViewportState,
        newHandles: [WindowHandle],
        existingHandleIds: Set<UUID>
    ) -> WindowHandle? {
        guard let controller else { return nil }
        let lrc = controller.layoutRefreshController

        let wasEmpty = existingHandleIds.isEmpty

        var newWindowHandle: WindowHandle?
        if lrc.layoutState.hasCompletedInitialRefresh,
           let newHandle = newHandles.last,
           let newNode = pass.engine.findNode(for: newHandle),
           pass.wsId == controller.activeWorkspace()?.id
        {
            state.selectedNodeId = newNode.id

            if wasEmpty {
                let cols = pass.engine.columns(in: pass.wsId)
                state.transitionToColumn(
                    0,
                    columns: cols,
                    gap: pass.gap,
                    viewportWidth: pass.insetFrame.width,
                    animate: false,
                    centerMode: pass.engine.centerFocusedColumn
                )
            } else if let newCol = pass.engine.column(of: newNode),
                      let newColIdx = pass.engine.columnIndex(of: newCol, in: pass.wsId) {
                if newCol.cachedWidth <= 0 {
                    newCol.resolveAndCacheWidth(workingAreaWidth: pass.insetFrame.width, gaps: pass.gap)
                }

                let shouldRestorePrevOffset = newColIdx == state.activeColumnIndex + 1
                let offsetBeforeActivation = state.stationary()

                pass.engine.ensureSelectionVisible(
                    node: newNode,
                    in: pass.wsId,
                    state: &state,
                    workingFrame: pass.insetFrame,
                    gaps: pass.gap,
                    alwaysCenterSingleColumn: pass.engine.alwaysCenterSingleColumn,
                    fromContainerIndex: state.activeColumnIndex
                )

                if shouldRestorePrevOffset {
                    state.activatePrevColumnOnRemoval = offsetBeforeActivation
                }
            }
            controller.focusManager.setFocus(newHandle, in: pass.wsId)
            pass.engine.updateFocusTimestamp(for: newNode.id)
            controller.workspaceManager.updateNiriViewportState(state, for: pass.wsId)
            newWindowHandle = newHandle
        }

        if lrc.layoutState.hasCompletedInitialRefresh,
           pass.wsId == controller.activeWorkspace()?.id,
           !newHandles.isEmpty
        {
            let reduceMotionScale: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.25 : 1.0
            let appearOffset = 16.0 * reduceMotionScale

            for handle in newHandles {
                guard let window = pass.engine.findNode(for: handle),
                      !window.isHiddenInTabbedMode else { continue }

                window.animateAlpha(
                    from: 0.0,
                    to: 1.0,
                    clock: pass.engine.animationClock,
                    config: pass.engine.windowMovementAnimationConfig,
                    displayRefreshRate: state.displayRefreshRate,
                    animationsEnabled: pass.engine.animationsEnabled
                )

                if abs(appearOffset) > 0.1 {
                    window.animateMoveFrom(
                        displacement: CGPoint(x: 0, y: -appearOffset),
                        clock: pass.engine.animationClock,
                        config: pass.engine.windowMovementAnimationConfig,
                        displayRefreshRate: state.displayRefreshRate,
                        animationsEnabled: pass.engine.animationsEnabled
                    )
                }
            }
        }

        return newWindowHandle
    }

    private func computeAndApplyLayout(
        pass: NiriLayoutPass,
        state: ViewportState,
        newWindowHandle: WindowHandle?,
        viewportNeedsRecalc: Bool,
        useScrollAnimationPath: Bool
    ) {
        guard let controller else { return }
        let lrc = controller.layoutRefreshController

        let gaps = LayoutGaps(
            horizontal: pass.gap,
            vertical: pass.gap,
            outer: controller.workspaceManager.outerGaps
        )

        let area = WorkingAreaContext(
            workingFrame: pass.insetFrame,
            viewFrame: pass.monitor.frame,
            scale: lrc.backingScale(for: pass.monitor)
        )

        let (frames, hiddenHandles) = pass.engine.calculateCombinedLayoutUsingPools(
            in: pass.wsId,
            monitor: pass.monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: nil
        )

        let hasColumnAnimations = pass.engine.hasAnyColumnAnimationsRunning(in: pass.wsId)

        if !useScrollAnimationPath {
            if viewportNeedsRecalc, newWindowHandle == nil {
                lrc.startScrollAnimation(for: pass.wsId)
            } else if hasColumnAnimations {
                lrc.startScrollAnimation(for: pass.wsId)
            }
        }

        if let newHandle = newWindowHandle {
            lrc.startScrollAnimation(for: pass.wsId)
            controller.focusWindow(newHandle)
        }

        for entry in controller.workspaceManager.entries(in: pass.wsId) {
            if let side = hiddenHandles[entry.handle] {
                let targetY = frames[entry.handle]?.origin.y
                lrc.hideWindow(entry, monitor: pass.monitor, side: side, targetY: targetY)
            } else {
                lrc.unhideWindow(entry, monitor: pass.monitor)
            }
        }

        var frameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []

        for (handle, frame) in frames {
            if hiddenHandles[handle] != nil { continue }
            if let entry = controller.workspaceManager.entry(for: handle) {
                frameUpdates.append((handle.pid, entry.windowId, frame))
            }
        }

        controller.axManager.applyFramesParallel(frameUpdates)

        if !useScrollAnimationPath, let focusedHandle = controller.focusedHandle {
            if hiddenHandles[focusedHandle] != nil {
                controller.borderManager.hideBorder()
            } else if let frame = frames[focusedHandle],
                      let entry = controller.workspaceManager.entry(for: focusedHandle)
            {
                controller.updateBorderIfAllowed(handle: focusedHandle, frame: frame, windowId: entry.windowId)
            }
        }

        controller.workspaceManager.updateNiriViewportState(state, for: pass.wsId)
    }

    func updateTabbedColumnOverlays() {
        guard let controller else { return }
        guard let engine = controller.niriEngine else {
            controller.tabbedOverlayManager.removeAll()
            return
        }

        var infos: [TabbedColumnOverlayInfo] = []
        for monitor in controller.workspaceManager.monitors {
            guard let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
            else { continue }

            for column in engine.columns(in: workspace.id) where column.isTabbed {
                guard let frame = column.frame else { continue }
                guard TabbedColumnOverlayManager.shouldShowOverlay(
                    columnFrame: frame,
                    visibleFrame: monitor.visibleFrame
                ) else { continue }

                let windows = column.windowNodes
                guard !windows.isEmpty else { continue }

                let activeIndex = min(max(0, column.activeTileIdx), windows.count - 1)
                let activeHandle = windows[activeIndex].handle
                let activeWindowId = controller.workspaceManager.entry(for: activeHandle)?.windowId

                infos.append(
                    TabbedColumnOverlayInfo(
                        workspaceId: workspace.id,
                        columnId: column.id,
                        columnFrame: frame,
                        tabCount: windows.count,
                        activeIndex: activeIndex,
                        activeWindowId: activeWindowId
                    )
                )
            }
        }

        controller.tabbedOverlayManager.updateOverlays(infos)
    }

    func selectTabInNiri(workspaceId: WorkspaceDescriptor.ID, columnId: NodeId, index: Int) {
        guard let controller, let engine = controller.niriEngine else { return }
        guard let column = engine.columns(in: workspaceId).first(where: { $0.id == columnId }) else { return }

        let windows = column.windowNodes
        guard windows.indices.contains(index) else { return }

        column.setActiveTileIdx(index)
        engine.updateTabbedColumnVisibility(column: column)

        let target = windows[index]
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        if let monitor = controller.workspaceManager.monitor(for: workspaceId) {
            let gap = CGFloat(controller.workspaceManager.gaps)
            engine.ensureSelectionVisible(
                node: target,
                in: workspaceId,
                state: &state,
                workingFrame: monitor.visibleFrame,
                gaps: gap,
                alwaysCenterSingleColumn: engine.alwaysCenterSingleColumn
            )
        }
        controller.activateNode(
            target, in: workspaceId, state: &state,
            options: .init(activateWindow: false, ensureVisible: false, startAnimation: false)
        )
        let updatedState = controller.workspaceManager.niriViewportState(for: workspaceId)
        if updatedState.viewOffsetPixels.isAnimating || engine.hasAnyWindowAnimationsRunning(in: workspaceId) {
            controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
        }
        updateTabbedColumnOverlays()
    }
}
