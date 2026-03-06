import AppKit
import Foundation
import QuartzCore

@MainActor
final class NiriLayoutHandler {
    weak var controller: WMController?
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
        guard let controller,
              let monitor = controller.workspaceManager.monitors.first(where: { $0.displayId == displayId })
        else {
            controller?.layoutRefreshController.stopScrollAnimation(for: displayId)
            return
        }

        controller.workspaceManager.withNiriViewportState(for: wsId) { state in
            let viewportAnimationRunning = state.advanceAnimations(at: targetTime)
            let structuralAnimationRunning = controller.zigNiriEngine?.hasActiveStructuralAnimation(
                in: wsId,
                at: targetTime
            ) ?? false
            applyFramesOnDemand(
                wsId: wsId,
                state: state,
                monitor: monitor,
                animationTime: targetTime
            )

            if !viewportAnimationRunning && !structuralAnimationRunning {
                finalizeAnimation(for: wsId)
                var activeIds = Set<WorkspaceDescriptor.ID>()
                for mon in controller.workspaceManager.monitors {
                    if let ws = controller.workspaceManager.activeWorkspaceOrFirst(on: mon.id) {
                        activeIds.insert(ws.id)
                    }
                }
                controller.layoutRefreshController.hideInactiveWorkspaces(activeWorkspaceIds: activeIds)
                controller.layoutRefreshController.stopScrollAnimation(for: displayId)
            }
        }
    }

    func applyFramesOnDemand(
        wsId: WorkspaceDescriptor.ID,
        state: ViewportState,
        monitor: Monitor,
        animationTime: TimeInterval? = nil
    ) {
        guard let controller,
              let zig = controller.zigNiriEngine
        else {
            return
        }

        let orientation = controller.settings.effectiveOrientation(for: monitor)
        let gaps = ZigNiriGaps(
            horizontal: CGFloat(controller.workspaceManager.gaps),
            vertical: CGFloat(controller.workspaceManager.gaps)
        )
        let lrc = controller.layoutRefreshController
        let insetFrame = controller.insetWorkingFrame(for: monitor)

        let area = ZigNiriWorkingAreaContext(
            workingFrame: insetFrame,
            viewFrame: monitor.frame,
            scale: lrc.backingScale(for: monitor)
        )

        let now = animationTime ?? CACurrentMediaTime()
        let layoutResult = zig.calculateLayout(
            ZigNiriLayoutRequest(
                workspaceId: wsId,
                monitorFrame: monitor.visibleFrame,
                screenFrame: monitor.frame,
                gaps: gaps,
                scale: area.scale,
                workingArea: area,
                orientation: orientation,
                viewportOffset: state.viewOffsetPixels.value(at: now),
                animationTime: now
            )
        )

        let frames = layoutResult.frames
        let hiddenHandles = layoutResult.hiddenHandles

        var hiddenWindowJobs: [(pid: pid_t, windowId: Int)] = []
        var visibleWindowJobs: [(pid: pid_t, windowId: Int)] = []

        let workspaceEntries = controller.workspaceManager.entries(in: wsId)
        for entry in workspaceEntries {
            if hiddenHandles[entry.handle] != nil {
                hiddenWindowJobs.append((entry.handle.pid, entry.windowId))
            } else {
                visibleWindowJobs.append((entry.handle.pid, entry.windowId))
            }
        }

        if !hiddenWindowJobs.isEmpty {
            controller.axManager.suppressFrameWrites(hiddenWindowJobs)
            controller.axManager.cancelPendingFrameJobs(hiddenWindowJobs)
        }

        for entry in workspaceEntries {
            if let side = hiddenHandles[entry.handle] {
                let targetY = frames[entry.handle]?.origin.y
                lrc.hideWindow(entry, monitor: monitor, side: side, targetY: targetY, reason: .layoutTransient)
            } else {
                lrc.unhideWindow(entry, monitor: monitor)
            }
        }

        var frameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []
        for (handle, frame) in frames {
            if hiddenHandles[handle] != nil { continue }
            if let entry = controller.workspaceManager.entry(for: handle) {
                if let nodeId = zig.nodeId(for: handle),
                   let workspaceView = zig.workspaceView(for: wsId),
                   workspaceView.windowsById[nodeId]?.sizingMode == .fullscreen
                {
                    controller.axManager.forceApplyNextFrame(for: entry.windowId)
                }
                frameUpdates.append((handle.pid, entry.windowId, frame))
            }
        }

        if !visibleWindowJobs.isEmpty {
            let activeJobs = visibleWindowJobs.filter { !controller.axManager.inactiveWorkspaceWindowIds.contains($0.windowId) }
            if !activeJobs.isEmpty {
                controller.axManager.unsuppressFrameWrites(activeJobs)
            }
        }

        controller.axManager.applyFramesParallel(frameUpdates)
        updateBorderDuringLayout(frames: frames, hiddenHandles: hiddenHandles, direct: animationTime != nil)
    }

    private func updateBorderDuringLayout(
        frames: [WindowHandle: CGRect],
        hiddenHandles: [WindowHandle: HideSide],
        direct: Bool
    ) {
        guard let controller,
              let focusedHandle = controller.focusedHandle
        else {
            return
        }

        if hiddenHandles[focusedHandle] != nil {
            controller.borderManager.hideBorder()
            return
        }

        guard let frame = frames[focusedHandle],
              let entry = controller.workspaceManager.entry(for: focusedHandle)
        else {
            return
        }

        if direct {
            controller.borderManager.updateFocusedWindow(frame: frame, windowId: entry.windowId)
        } else {
            controller.borderCoordinator.updateBorderIfAllowed(handle: focusedHandle, frame: frame, windowId: entry.windowId)
        }
    }

    private func finalizeAnimation(for workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }

        if let focusedHandle = controller.focusedHandle,
           let entry = controller.workspaceManager.entry(for: focusedHandle),
           let workspaceView = controller.syncZigNiriWorkspace(workspaceId: workspaceId),
           let nodeId = controller.zigNodeId(for: focusedHandle),
           let frame = workspaceView.windowsById[nodeId]?.frame
        {
            controller.borderCoordinator.updateBorderIfAllowed(handle: focusedHandle, frame: frame, windowId: entry.windowId)
        }

        if controller.moveMouseToFocusedWindowEnabled,
           let focusedHandle = controller.focusedHandle
        {
            controller.moveMouseToWindow(focusedHandle)
        }
    }

    func cancelActiveAnimations(for workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        for (displayId, wsId) in scrollAnimationByDisplay where wsId == workspaceId {
            controller.layoutRefreshController.stopScrollAnimation(for: displayId)
        }
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.cancelAnimation()
        }
        controller.zigNiriEngine?.cancelStructuralAnimation(in: workspaceId)
    }

    func layoutWithNiriEngine(
        activeWorkspaces: Set<WorkspaceDescriptor.ID>,
        useScrollAnimationPath: Bool = false,
        removedNodeId _: NodeId? = nil
    ) async {
        guard let controller,
              let zig = controller.zigNiriEngine
        else {
            return
        }

        var processed: Set<WorkspaceDescriptor.ID> = []

        for monitor in controller.workspaceManager.monitors {
            guard let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) else { continue }
            let wsId = workspace.id
            guard activeWorkspaces.contains(wsId) else { continue }
            guard !processed.contains(wsId) else { continue }
            processed.insert(wsId)

            let handles = controller.workspaceManager.entries(in: wsId).map(\.handle)
            controller.workspaceManager.withNiriViewportState(for: wsId) { state in
                _ = zig.syncWindows(
                    handles,
                    in: wsId,
                    selectedNodeId: state.selectedNodeId,
                    focusedHandle: controller.focusedHandle
                )

                if let selection = zig.workspaceView(for: wsId)?.selection?.selectedNodeId {
                    state.selectedNodeId = selection
                    controller.workspaceManager.setSelection(selection, for: wsId)
                }

                state.displayRefreshRate = controller.layoutRefreshController.layoutState.refreshRateByDisplay[monitor.displayId] ?? 60.0
                applyFramesOnDemand(wsId: wsId, state: state, monitor: monitor)

                if !useScrollAnimationPath,
                   (state.viewOffsetPixels.isAnimating
                       || zig.hasActiveStructuralAnimation(in: wsId))
                {
                    controller.layoutRefreshController.startScrollAnimation(for: wsId)
                }
            }

            await Task.yield()
        }

        updateTabbedColumnOverlays()
        controller.updateWorkspaceBar()
    }

    func updateTabbedColumnOverlays() {
        guard let controller,
              let zig = controller.zigNiriEngine
        else {
            controller?.tabbedOverlayManager.removeAll()
            return
        }

        var infos: [TabbedColumnOverlayInfo] = []
        for monitor in controller.workspaceManager.monitors {
            guard let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) else { continue }
            guard let view = controller.syncZigNiriWorkspace(workspaceId: workspace.id) else { continue }

            for column in view.columns where column.display == .tabbed {
                let visibleWindows = column.windowIds.compactMap { view.windowsById[$0] }
                guard !visibleWindows.isEmpty else { continue }

                let frames = visibleWindows.compactMap(\.frame)
                guard !frames.isEmpty else { continue }

                let unionFrame = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
                guard TabbedColumnOverlayManager.shouldShowOverlay(
                    columnFrame: unionFrame,
                    visibleFrame: monitor.visibleFrame
                ) else { continue }

                let clampedIndex = min(max(0, column.activeWindowIndex ?? 0), visibleWindows.count - 1)
                let activeHandle = visibleWindows[clampedIndex].handle
                let activeWindowId = controller.workspaceManager.entry(for: activeHandle)?.windowId

                infos.append(
                    TabbedColumnOverlayInfo(
                        workspaceId: workspace.id,
                        columnId: column.nodeId,
                        columnFrame: unionFrame,
                        tabCount: visibleWindows.count,
                        activeIndex: clampedIndex,
                        activeWindowId: activeWindowId
                    )
                )
            }
        }

        _ = zig
        controller.tabbedOverlayManager.updateOverlays(infos)
    }

    func selectTabInNiri(workspaceId: WorkspaceDescriptor.ID, columnId: NodeId, index: Int) {
        guard let controller,
              let zig = controller.zigNiriEngine
        else {
            return
        }

        guard let view = controller.syncZigNiriWorkspace(workspaceId: workspaceId),
              let column = view.columns.first(where: { $0.nodeId == columnId }),
              column.windowIds.indices.contains(index)
        else {
            return
        }

        let selectedWindowId = column.windowIds[index]
        _ = zig.applyMutation(
            .setColumnActiveWindow(columnId: columnId, windowIndex: index),
            in: workspaceId
        )

        let selection = ZigNiriSelection(selectedNodeId: selectedWindowId, focusedWindowId: selectedWindowId)
        _ = zig.applyWorkspace(.setSelection(selection), in: workspaceId)

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = selectedWindowId
            controller.workspaceManager.setSelection(selectedWindowId, for: workspaceId)
        }

        if let handle = controller.zigWindowHandle(for: selectedWindowId, workspaceId: workspaceId) {
            controller.focusManager.setFocus(handle, in: workspaceId)
        }

        controller.layoutRefreshController.executeLayoutRefreshImmediate()
        updateTabbedColumnOverlays()
    }

    func focusPrevious() {
        guard let controller else { return }

        var appliedFromHistory = false
        withActiveWorkspaceContext { wsId, monitor, _, state, zig in
            _ = controller.syncZigNiriWorkspace(workspaceId: wsId, selectedNodeId: state.selectedNodeId)
            guard let previousHandle = controller.focusManager.previousFocusedHandle(
                in: wsId,
                excluding: controller.focusedHandle,
                isValid: { handle in
                    controller.workspaceManager.entry(for: handle)?.workspaceId == wsId
                        && controller.zigNodeId(for: handle, workspaceId: wsId) != nil
                }
            ),
                let previousNodeId = controller.zigNodeId(for: previousHandle, workspaceId: wsId)
            else {
                return
            }

            let selection = ZigNiriSelection(
                selectedNodeId: previousNodeId,
                focusedWindowId: previousNodeId
            )
            let result = zig.applyWorkspace(.setSelection(selection), in: wsId)

            applySelection(
                result.selection ?? selection,
                workspaceId: wsId,
                monitor: monitor,
                state: &state,
                focusWindow: true,
                animateViewport: true
            )
            appliedFromHistory = true
        }

        if !appliedFromHistory {
            focusUsing(.focusWindowTop)
        }
    }

    func focusDownOrLeft() {
        focusUsing(.focusDownOrLeft)
    }

    func focusUpOrRight() {
        focusUsing(.focusUpOrRight)
    }

    func focusColumnFirst() {
        focusUsing(.focusColumnFirst)
    }

    func focusColumnLast() {
        focusUsing(.focusColumnLast)
    }

    func focusColumn(index: Int) {
        focusUsing(.focusColumn(index: index))
    }

    func focusWindowTop() {
        focusUsing(.focusWindowTop)
    }

    func focusWindowBottom() {
        focusUsing(.focusWindowBottom)
    }

    private func focusUsing(_ request: ZigNiriNavigationRequest) {
        guard let controller else { return }

        withActiveWorkspaceContext { wsId, monitor, orientation, state, zig in
            _ = controller.syncZigNiriWorkspace(workspaceId: wsId, selectedNodeId: state.selectedNodeId)
            let result = zig.applyNavigation(
                request,
                in: wsId,
                orientation: orientation,
                selection: currentSelection(workspaceId: wsId, state: state)
            )
            applySelection(
                result.selection,
                workspaceId: wsId,
                monitor: monitor,
                state: &state,
                focusWindow: true,
                animateViewport: true
            )
        }
    }

    func moveWindow(direction: Direction) {
        withActiveWorkspaceContext { wsId, monitor, orientation, state, zig in
            guard let selectedWindowId = selectedWindowId(in: wsId, state: state) else { return }

            let result = zig.applyMutation(
                .moveWindow(windowId: selectedWindowId, direction: direction, orientation: orientation),
                in: wsId,
                selection: currentSelection(workspaceId: wsId, state: state)
            )
            applyMutationSelection(
                result,
                workspaceId: wsId,
                monitor: monitor,
                state: &state,
                animateViewport: true
            )
        }
    }

    func swapWindow(direction: Direction) {
        withActiveWorkspaceContext { wsId, monitor, orientation, state, zig in
            guard let selectedWindowId = selectedWindowId(in: wsId, state: state) else { return }

            let result = zig.applyMutation(
                .swapWindow(windowId: selectedWindowId, direction: direction, orientation: orientation),
                in: wsId,
                selection: currentSelection(workspaceId: wsId, state: state)
            )
            applyMutationSelection(
                result,
                workspaceId: wsId,
                monitor: monitor,
                state: &state,
                animateViewport: true
            )
        }
    }

    func moveColumn(direction: Direction) {
        guard let controller else { return }

        withActiveWorkspaceContext { wsId, monitor, _, state, zig in
            guard let view = controller.syncZigNiriWorkspace(workspaceId: wsId, selectedNodeId: state.selectedNodeId),
                  let column = columnForSelection(selectionNodeId: state.selectedNodeId, in: view)
            else {
                return
            }

            let result = zig.applyMutation(
                .moveColumn(columnId: column.nodeId, direction: direction),
                in: wsId,
                selection: currentSelection(workspaceId: wsId, state: state)
            )
            applyMutationSelection(
                result,
                workspaceId: wsId,
                monitor: monitor,
                state: &state,
                animateViewport: true
            )
        }
    }

    func consumeWindow(direction: Direction) {
        withActiveWorkspaceContext { wsId, monitor, _, state, zig in
            guard let selectedWindowId = selectedWindowId(in: wsId, state: state) else { return }

            let result = zig.applyMutation(
                .consumeWindow(windowId: selectedWindowId, direction: direction),
                in: wsId,
                selection: currentSelection(workspaceId: wsId, state: state)
            )
            applyMutationSelection(
                result,
                workspaceId: wsId,
                monitor: monitor,
                state: &state,
                animateViewport: true
            )
        }
    }

    func expelWindow(direction: Direction) {
        withActiveWorkspaceContext { wsId, monitor, _, state, zig in
            guard let selectedWindowId = selectedWindowId(in: wsId, state: state) else { return }

            let result = zig.applyMutation(
                .expelWindow(windowId: selectedWindowId, direction: direction),
                in: wsId,
                selection: currentSelection(workspaceId: wsId, state: state)
            )
            applyMutationSelection(
                result,
                workspaceId: wsId,
                monitor: monitor,
                state: &state,
                animateViewport: true
            )
        }
    }

    func toggleColumnTabbed() {
        guard let controller else { return }

        withActiveWorkspaceContext { wsId, monitor, _, state, zig in
            guard let view = controller.syncZigNiriWorkspace(workspaceId: wsId, selectedNodeId: state.selectedNodeId),
                  let column = columnForSelection(selectionNodeId: state.selectedNodeId, in: view)
            else {
                return
            }

            let nextDisplay: ColumnDisplay = column.display == .tabbed ? .normal : .tabbed
            let result = zig.applyMutation(
                .setColumnDisplay(columnId: column.nodeId, display: nextDisplay),
                in: wsId,
                selection: currentSelection(workspaceId: wsId, state: state)
            )
            guard result.applied else { return }
            applyMutationSelection(
                result,
                workspaceId: wsId,
                monitor: monitor,
                state: &state,
                animateViewport: false
            )
            updateTabbedColumnOverlays()
        }
    }

    func toggleColumnFullWidth() {
        guard let controller else { return }

        withActiveWorkspaceContext { wsId, monitor, _, state, zig in
            guard let view = controller.syncZigNiriWorkspace(workspaceId: wsId, selectedNodeId: state.selectedNodeId),
                  let column = columnForSelection(selectionNodeId: state.selectedNodeId, in: view)
            else {
                return
            }

            let result = zig.applyMutation(
                .toggleColumnFullWidth(columnId: column.nodeId),
                in: wsId,
                selection: currentSelection(workspaceId: wsId, state: state)
            )
            applyMutationSelection(
                result,
                workspaceId: wsId,
                monitor: monitor,
                state: &state,
                animateViewport: false
            )
        }
    }

    func toggleFullscreen() {
        guard let controller else { return }

        withActiveWorkspaceContext { wsId, monitor, _, state, zig in
            guard let selectedWindowId = selectedWindowId(in: wsId, state: state),
                  let view = controller.syncZigNiriWorkspace(workspaceId: wsId, selectedNodeId: selectedWindowId),
                  let currentMode = view.windowsById[selectedWindowId]?.sizingMode
            else {
                return
            }

            let nextMode: SizingMode = currentMode == .fullscreen ? .normal : .fullscreen
            let result = zig.applyMutation(
                .setWindowSizing(windowId: selectedWindowId, mode: nextMode),
                in: wsId,
                selection: currentSelection(workspaceId: wsId, state: state)
            )
            applyMutationSelection(
                result,
                workspaceId: wsId,
                monitor: monitor,
                state: &state,
                animateViewport: false
            )
        }
    }

    func cycleSize(forward: Bool) {
        guard let controller else { return }

        withActiveWorkspaceContext { wsId, monitor, orientation, state, zig in
            guard let view = controller.syncZigNiriWorkspace(workspaceId: wsId, selectedNodeId: state.selectedNodeId),
                  let column = columnForSelection(selectionNodeId: state.selectedNodeId, in: view)
            else {
                return
            }

            let presets = controller.settings.niriColumnWidthPresets
            guard !presets.isEmpty else { return }

            let monitorSpan = orientation == .horizontal
                ? controller.insetWorkingFrame(for: monitor).width
                : controller.insetWorkingFrame(for: monitor).height
            let currentNormalizedWidth = normalizedColumnWidth(
                column.width,
                primarySpan: monitorSpan
            )
            let currentIndex = nearestPresetIndex(
                to: currentNormalizedWidth,
                presets: presets
            )
            let nextIndex = forward
                ? min(presets.count - 1, currentIndex + 1)
                : max(0, currentIndex - 1)
            let nextWidth = ProportionalSize.proportion(CGFloat(presets[nextIndex]))

            let result = zig.applyMutation(
                .setColumnWidth(columnId: column.nodeId, width: nextWidth),
                in: wsId,
                selection: currentSelection(workspaceId: wsId, state: state)
            )
            applyMutationSelection(
                result,
                workspaceId: wsId,
                monitor: monitor,
                state: &state,
                animateViewport: false
            )
        }
    }

    func balanceSizes() {
        withActiveWorkspaceContext { wsId, monitor, _, state, zig in
            let result = zig.applyMutation(
                .balanceSizes,
                in: wsId,
                selection: currentSelection(workspaceId: wsId, state: state)
            )
            applyMutationSelection(
                result,
                workspaceId: wsId,
                monitor: monitor,
                state: &state,
                animateViewport: false
            )
        }
    }

    func overviewInsertWindow(
        handle: WindowHandle,
        targetHandle: WindowHandle,
        position: InsertPosition,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller,
              let zig = controller.zigNiriEngine,
              let sourceId = controller.zigNodeId(for: handle, workspaceId: workspaceId),
              let targetId = controller.zigNodeId(for: targetHandle, workspaceId: workspaceId)
        else {
            return
        }

        let result = zig.applyMutation(
            .insertWindowByMove(sourceWindowId: sourceId, targetWindowId: targetId, position: position),
            in: workspaceId
        )
        guard result.applied else { return }

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = result.selection?.selectedNodeId
            controller.workspaceManager.setSelection(result.selection?.selectedNodeId, for: workspaceId)
        }
    }

    func overviewInsertWindowInNewColumn(
        handle: WindowHandle,
        insertIndex: Int,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller,
              let zig = controller.zigNiriEngine,
              let sourceId = controller.zigNodeId(for: handle, workspaceId: workspaceId)
        else {
            return
        }

        let result = zig.applyMutation(
            .insertWindowInNewColumn(windowId: sourceId, insertIndex: insertIndex),
            in: workspaceId
        )
        guard result.applied else { return }

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = result.selection?.selectedNodeId
            controller.workspaceManager.setSelection(result.selection?.selectedNodeId, for: workspaceId)
        }
    }

    func enableNiriLayout(
        maxWindowsPerColumn: Int = 3,
        centerFocusedColumn _: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn _: Bool = false
    ) {
        guard let controller else { return }

        if controller.zigNiriEngine == nil {
            controller.zigNiriEngine = ZigNiriEngine(
                maxWindowsPerColumn: maxWindowsPerColumn,
                maxVisibleColumns: controller.settings.niriMaxVisibleColumns,
                infiniteLoop: controller.settings.niriInfiniteLoop
            )
        } else {
            controller.zigNiriEngine?.updateConfiguration(maxWindowsPerColumn: maxWindowsPerColumn)
        }

        syncMonitorsToNiriEngine()
        controller.layoutRefreshController.refreshWindowsAndLayout()
    }

    func syncMonitorsToNiriEngine() {
        // Zig runtime stores workspace state keyed by workspace id and does not require
        // monitor registration. Keep this method as an explicit no-op for call-site parity.
    }

    func updateNiriConfig(
        maxWindowsPerColumn: Int? = nil,
        maxVisibleColumns: Int? = nil,
        infiniteLoop: Bool? = nil,
        centerFocusedColumn _: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn _: Bool? = nil,
        singleWindowAspectRatio _: SingleWindowAspectRatio? = nil,
        columnWidthPresets _: [Double]? = nil
    ) {
        guard let controller else { return }
        controller.zigNiriEngine?.updateConfiguration(
            maxWindowsPerColumn: maxWindowsPerColumn,
            maxVisibleColumns: maxVisibleColumns,
            infiniteLoop: infiniteLoop
        )
        controller.layoutRefreshController.refreshWindowsAndLayout()
    }

    private func applyMutationSelection(
        _ result: ZigNiriMutationResult,
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        state: inout ViewportState,
        animateViewport: Bool
    ) {
        guard let controller, result.applied else { return }

        applySelection(
            result.selection,
            workspaceId: workspaceId,
            monitor: monitor,
            state: &state,
            focusWindow: true,
            animateViewport: animateViewport
        )
        controller.layoutRefreshController.executeLayoutRefreshImmediate()
        if result.structuralAnimationActive
            || (controller.zigNiriEngine?.hasActiveStructuralAnimation(in: workspaceId) ?? false)
        {
            controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
        }
    }

    private func normalizedColumnWidth(
        _ width: ProportionalSize,
        primarySpan: CGFloat
    ) -> Double {
        switch width {
        case let .proportion(value):
            return Double(max(0.05, min(1.0, value)))
        case let .fixed(value):
            guard primarySpan > 0 else { return 1.0 }
            return Double(max(0.05, min(1.0, value / primarySpan)))
        }
    }

    private func nearestPresetIndex(
        to widthValue: Double,
        presets: [Double]
    ) -> Int {
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, preset) in presets.enumerated() {
            let distance = abs(preset - widthValue)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func withActiveWorkspaceContext(
        _ perform: (WorkspaceDescriptor.ID, Monitor, Monitor.Orientation, inout ViewportState, ZigNiriEngine) -> Void
    ) {
        guard let controller,
              let zig = controller.zigNiriEngine
        else {
            return
        }

        controller.layoutRefreshController.runLightSession {
            guard let workspace = controller.activeWorkspace(),
                  let monitor = controller.workspaceManager.monitor(for: workspace.id)
            else {
                return
            }
            let orientation = controller.settings.effectiveOrientation(for: monitor)

            controller.workspaceManager.withNiriViewportState(for: workspace.id) { state in
                perform(workspace.id, monitor, orientation, &state, zig)
            }
        }
    }

    private func currentSelection(workspaceId: WorkspaceDescriptor.ID, state: ViewportState) -> ZigNiriSelection? {
        guard let controller else { return nil }
        let focusedWindowId = controller.focusedHandle.flatMap { controller.zigNodeId(for: $0, workspaceId: workspaceId) }
        return ZigNiriSelection(
            selectedNodeId: state.selectedNodeId,
            focusedWindowId: focusedWindowId
        )
    }

    private func selectedWindowId(
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState
    ) -> NodeId? {
        guard let view = controller?.syncZigNiriWorkspace(workspaceId: workspaceId, selectedNodeId: state.selectedNodeId) else {
            return nil
        }
        return Self.resolveActionableWindowId(
            for: state.selectedNodeId,
            in: view
        )
    }

    static func resolveActionableWindowId(
        for selectedNodeId: NodeId?,
        in view: ZigNiriWorkspaceView
    ) -> NodeId? {
        ZigNiriSelectionResolver.actionableWindowId(
            for: selectedNodeId,
            in: view
        )
    }

    private func columnForSelection(
        selectionNodeId: NodeId?,
        in workspaceView: ZigNiriWorkspaceView
    ) -> ZigNiriColumnView? {
        let selectedNodeId = selectionNodeId ?? workspaceView.selection?.selectedNodeId
        guard let selectedNodeId else {
            return workspaceView.columns.first
        }
        if let selectedColumn = workspaceView.columns.first(where: { $0.nodeId == selectedNodeId }) {
            return selectedColumn
        }
        return workspaceView.columns.first(where: { $0.windowIds.contains(selectedNodeId) })
    }

    private func applySelection(
        _ selection: ZigNiriSelection?,
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        state: inout ViewportState,
        focusWindow: Bool,
        animateViewport: Bool
    ) {
        guard let controller,
              let zig = controller.zigNiriEngine
        else { return }
        state.selectedNodeId = selection?.selectedNodeId
        controller.workspaceManager.setSelection(selection?.selectedNodeId, for: workspaceId)

        let workspaceView = controller.syncZigNiriWorkspace(
            workspaceId: workspaceId,
            selectedNodeId: selection?.selectedNodeId
        )
        let actionableNodeId = workspaceView.flatMap { view in
            Self.resolveActionableWindowId(
                for: selection?.selectedNodeId,
                in: view
            )
        }

        if let handle = actionableNodeId.flatMap({ controller.zigWindowHandle(for: $0, workspaceId: workspaceId) }) {
            controller.focusManager.setFocus(handle, in: workspaceId)
            if focusWindow {
                controller.focusWindow(handle)
            }
        }

        guard animateViewport,
              let view = workspaceView,
              let selectedNodeId = selection?.selectedNodeId ?? actionableNodeId,
              let selectedColumnIndex = view.columns.firstIndex(where: { column in
                  column.nodeId == selectedNodeId || column.windowIds.contains(selectedNodeId)
              })
        else {
            return
        }

        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let orientation = controller.settings.effectiveOrientation(for: monitor)
        let resolved = controller.settings.resolvedNiriSettings(for: monitor)
        let viewportSpan = orientation == .horizontal ? workingFrame.width : workingFrame.height
        let columnSpans = zig.resolvedColumnSpans(
            for: view,
            primarySpan: viewportSpan,
            primaryGap: CGFloat(controller.workspaceManager.gaps)
        )
        guard !columnSpans.isEmpty else { return }

        state.transitionToColumn(
            selectedColumnIndex,
            columnSpans: columnSpans,
            gap: CGFloat(controller.workspaceManager.gaps),
            viewportSpan: viewportSpan,
            animate: true,
            centerMode: resolved.centerFocusedColumn,
            alwaysCenterSingleColumn: resolved.alwaysCenterSingleColumn,
            fromColumnIndex: state.activeColumnIndex,
            scale: controller.layoutRefreshController.backingScale(for: monitor)
        )

        if state.viewOffsetPixels.isAnimating {
            controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
        }
    }
}

extension NiriLayoutHandler: LayoutFocusable, LayoutSwappable, LayoutSizable {
    func focusNeighbor(direction: Direction) {
        focusUsing(.focus(direction: direction))
    }
}
