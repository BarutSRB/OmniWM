import AppKit
import Foundation
import QuartzCore

@MainActor
final class LayoutRefreshController {
    private weak var controller: WMController?

    private var activeRefreshTask: Task<Void, Never>?
    private var isInLightSession: Bool = false
    private var isImmediateLayoutInProgress: Bool = false
    private var refreshTimer: Timer?

    private var activeDisplayLink: CADisplayLink?
    private var activeDisplayId: CGDirectDisplayID?
    private var scrollAnimationWorkspaceId: WorkspaceDescriptor.ID?
    private var isScrollAnimationRunning: Bool = false
    private var cachedWindowSizes: [Int: CGSize] = [:]
    private var refreshRateByDisplay: [CGDirectDisplayID: Double] = [:]
    private var screenChangeObserver: NSObjectProtocol?
    private var hasCompletedInitialRefresh: Bool = false

    private var activeSnapshot: AnimationSnapshot?
    private var layoutDirtyFlag: Bool = false
    private var sizesAppliedForAnimation: Bool = false

    init(controller: WMController) {
        self.controller = controller
        detectRefreshRates()
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenParametersChanged()
            }
        }
    }

    private func getOrCreateDisplayLink(for displayId: CGDirectDisplayID) -> CADisplayLink? {
        if activeDisplayId == displayId, let link = activeDisplayLink {
            return link
        }
        activeDisplayLink?.invalidate()
        activeDisplayLink = nil
        activeDisplayId = nil

        guard let screen = NSScreen.screens.first(where: { $0.displayId == displayId }) else {
            return nil
        }
        let link = screen.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        activeDisplayLink = link
        activeDisplayId = displayId
        return link
    }

    private func handleScreenParametersChanged() {
        detectRefreshRates()

        guard let activeId = activeDisplayId else { return }

        let displayStillExists = NSScreen.screens.contains(where: { $0.displayId == activeId })
        if !displayStillExists {
            activeDisplayLink?.invalidate()
            activeDisplayLink = nil
            activeDisplayId = nil

            if let wsId = scrollAnimationWorkspaceId {
                isScrollAnimationRunning = false
                startScrollAnimation(for: wsId)
            }
        }
    }

    private func detectRefreshRates() {
        refreshRateByDisplay.removeAll()
        for screen in NSScreen.screens {
            guard let displayId = screen.displayId else { continue }
            if let mode = CGDisplayCopyDisplayMode(displayId) {
                let rate = mode.refreshRate > 0 ? mode.refreshRate : 60.0
                refreshRateByDisplay[displayId] = rate
            } else {
                refreshRateByDisplay[displayId] = 60.0
            }
        }
    }

    func refreshRate(for displayId: CGDirectDisplayID) -> Double {
        refreshRateByDisplay[displayId] ?? 60.0
    }

    @objc private func displayLinkFired(_ displayLink: CADisplayLink) {
        tickScrollAnimation(targetTime: displayLink.targetTimestamp)
    }

    func startScrollAnimation(for workspaceId: WorkspaceDescriptor.ID) {
        if scrollAnimationWorkspaceId != workspaceId {
            activeSnapshot = nil
            sizesAppliedForAnimation = false
        }
        scrollAnimationWorkspaceId = workspaceId
        if isScrollAnimationRunning { return }
        isScrollAnimationRunning = true
        layoutDirtyFlag = false

        let targetDisplayId: CGDirectDisplayID
        if let controller,
           let monitor = controller.internalWorkspaceManager.monitor(for: workspaceId) {
            targetDisplayId = monitor.id.displayId
        } else if let mainDisplayId = NSScreen.main?.displayId {
            targetDisplayId = mainDisplayId
        } else {
            return
        }

        if let displayLink = getOrCreateDisplayLink(for: targetDisplayId) {
            displayLink.add(to: .main, forMode: .common)
        }
    }

    func stopScrollAnimation() {
        activeDisplayLink?.remove(from: .main, forMode: .common)
        isScrollAnimationRunning = false
        scrollAnimationWorkspaceId = nil
    }

    private func tickScrollAnimation(targetTime: CFTimeInterval) {
        guard isScrollAnimationRunning else { return }
        guard let controller, let wsId = scrollAnimationWorkspaceId else {
            stopScrollAnimation()
            return
        }
        guard let engine = controller.internalNiriEngine else {
            stopScrollAnimation()
            return
        }

        var state = controller.internalWorkspaceManager.niriViewportState(for: wsId)

        let viewportAnimationRunning = state.tickAnimation(at: targetTime)
        let windowAnimationsRunning = engine.tickAllWindowAnimations(in: wsId, at: targetTime)

        controller.internalWorkspaceManager.updateNiriViewportState(state, for: wsId)

        if let snapshot = activeSnapshot, snapshot.workspaceId == wsId, !layoutDirtyFlag {
            executeAnimationTickFast(snapshot: snapshot, state: state, engine: engine, time: targetTime)
        } else {
            executeLayoutRefreshImmediate()
        }

        if !viewportAnimationRunning && !windowAnimationsRunning {
            finalizeAnimation()
            stopScrollAnimation()
        }
    }

    private func executeAnimationTickFast(
        snapshot: AnimationSnapshot,
        state: ViewportState,
        engine: NiriLayoutEngine,
        time: TimeInterval
    ) {
        guard let controller else { return }

        let currentViewportOffset = state.viewOffsetPixels.current()
        let visibleCount = snapshot.targetFrames.count - snapshot.hiddenHandles.count
        var positionUpdates: [(windowId: Int, origin: CGPoint)] = []
        positionUpdates.reserveCapacity(visibleCount)
        var frameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []
        frameUpdates.reserveCapacity(visibleCount)

        for (handle, _) in snapshot.targetFrames {
            guard snapshot.isWindowVisible(handle) else { continue }
            guard let entry = controller.internalWorkspaceManager.entry(for: handle) else { continue }

            let window = engine.findNode(for: handle)
            let moveOffset = window?.renderOffset(at: time) ?? .zero

            guard let frame = snapshot.interpolatedFrame(
                for: handle,
                currentViewportOffset: currentViewportOffset,
                moveOffset: moveOffset
            ) else { continue }

            if sizesAppliedForAnimation {
                positionUpdates.append((entry.windowId, frame.origin))
            } else {
                frameUpdates.append((handle.pid, entry.windowId, frame))
                cachedWindowSizes[entry.windowId] = frame.size
            }
        }

        if sizesAppliedForAnimation {
            controller.internalAXManager.applyPositionsViaSkyLight(positionUpdates)
        } else {
            controller.internalAXManager.applyFramesParallel(frameUpdates)
            sizesAppliedForAnimation = true
        }
    }

    private func finalizeAnimation() {
        if let controller,
           let focusedHandle = controller.internalFocusedHandle,
           let entry = controller.internalWorkspaceManager.entry(for: focusedHandle),
           let frame = try? AXWindowService.frame(entry.axRef)
        {
            controller.updateBorderIfAllowed(handle: focusedHandle, frame: frame, windowId: entry.windowId)
        }

        activeSnapshot = nil
        layoutDirtyFlag = false
        sizesAppliedForAnimation = false
    }

    func invalidateLayout() {
        layoutDirtyFlag = true
    }

    func cancelActiveAnimations(for workspaceId: WorkspaceDescriptor.ID) {
        if scrollAnimationWorkspaceId == workspaceId || scrollAnimationWorkspaceId == nil {
            stopScrollAnimation()
        }
        activeSnapshot = nil
        layoutDirtyFlag = false
        sizesAppliedForAnimation = false

        guard let controller else { return }
        var state = controller.internalWorkspaceManager.niriViewportState(for: workspaceId)
        state.cancelAnimation()
        controller.internalWorkspaceManager.updateNiriViewportState(state, for: workspaceId)
    }

    func refreshWindowsAndLayout() {
        scheduleRefreshSession(.timerRefresh)
    }

    func scheduleRefreshSession(_ event: RefreshSessionEvent) {
        guard !isInLightSession else { return }
        activeRefreshTask?.cancel()
        activeRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let baseDebounce = event.debounceInterval
                if baseDebounce > 0 {
                    let mainDisplayId = NSScreen.main?.displayId ?? 0
                    let refreshRate = refreshRateByDisplay[mainDisplayId] ?? 60.0
                    let scaledDebounce = UInt64(Double(baseDebounce) * (60.0 / refreshRate))
                    try await Task.sleep(nanoseconds: scaledDebounce)
                }
                try Task.checkCancellation()
                if event.requiresFullEnumeration {
                    try await executeFullRefresh()
                } else {
                    executeIncrementalRefresh()
                }
            } catch {
                return
            }
        }
    }

    private func executeIncrementalRefresh() {
        guard let controller else { return }

        if controller.internalLockScreenObserver.isFrontmostAppLockScreen() || controller.internalIsLockScreenActive {
            return
        }

        var activeWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        for monitor in controller.internalWorkspaceManager.monitors {
            if let workspace = controller.internalWorkspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                activeWorkspaceIds.insert(workspace.id)
            }
        }

        layoutWithNiriEngine(activeWorkspaces: activeWorkspaceIds, useScrollAnimationPath: false)

        if let focusedWorkspaceId = controller.activeWorkspace()?.id {
            controller.ensureFocusedHandleValid(in: focusedWorkspaceId)
        }
    }

    func runLightSession(_ body: () -> Void) {
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        isInLightSession = true

        if let controller = controller, let engine = controller.internalNiriEngine {
            let focused = controller.internalFocusedHandle
            for monitor in controller.internalWorkspaceManager.monitors {
                if let ws = controller.internalWorkspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                    let handles = controller.internalWorkspaceManager.entries(in: ws.id).map(\.handle)
                    let selection = controller.internalWorkspaceManager.niriViewportState(for: ws.id).selectedNodeId
                    _ = engine.syncWindows(handles, in: ws.id, selectedNodeId: selection, focusedHandle: focused)
                }
            }
        }

        body()
        isInLightSession = false
        refreshWindowsAndLayout()
    }

    func executeLayoutRefreshImmediate() {
        guard !isImmediateLayoutInProgress else { return }
        guard let controller else { return }
        isImmediateLayoutInProgress = true
        defer { isImmediateLayoutInProgress = false }

        var activeWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        for monitor in controller.internalWorkspaceManager.monitors {
            if let workspace = controller.internalWorkspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                activeWorkspaceIds.insert(workspace.id)
            }
        }

        layoutWithNiriEngine(activeWorkspaces: activeWorkspaceIds, useScrollAnimationPath: isScrollAnimationRunning)
    }

    func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshWindowsAndLayout()
            }
        }
        if let timer = refreshTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func resetState() {
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        isInLightSession = false
        stopScrollAnimation()
        activeDisplayLink?.invalidate()
        activeDisplayLink = nil
        activeDisplayId = nil
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            screenChangeObserver = nil
        }
    }

    private func executeFullRefresh() async throws {
        guard let controller else { return }
        let interval = signpostInterval("executeLayoutRefresh")
        defer { interval.end() }

        if controller.internalLockScreenObserver.isFrontmostAppLockScreen() || controller.internalIsLockScreenActive {
            return
        }

        let windows = await controller.internalAXManager.currentWindowsAsync()
        try Task.checkCancellation()
        var seenKeys: Set<WindowModel.WindowKey> = []
        let focusedWorkspaceId = controller.activeWorkspace()?.id

        controller.internalWindowStateCache.captureState(
            workspaceManager: controller.internalWorkspaceManager,
            niriEngine: controller.internalNiriEngine
        )

        for (ax, pid, winId) in windows {
            if let bundleId = controller.internalAppInfoCache.bundleId(for: pid) {
                if bundleId == LockScreenObserver.lockScreenAppBundleId {
                    continue
                }
                if controller.internalAppRulesByBundleId[bundleId]?.alwaysFloat == true {
                    continue
                }
            }

            let wsForWindow: WorkspaceDescriptor.ID
            if let cachedWsId = controller.internalWindowStateCache.frozenWorkspaceId(for: winId) {
                wsForWindow = cachedWsId
            } else {
                let defaultWorkspace = controller.resolveWorkspaceForNewWindow(
                    axRef: ax,
                    pid: pid,
                    fallbackWorkspaceId: focusedWorkspaceId
                )
                wsForWindow = controller.workspaceAssignment(pid: pid, windowId: winId) ?? defaultWorkspace
            }

            _ = controller.internalWorkspaceManager.addWindow(ax, pid: pid, windowId: winId, to: wsForWindow)
            seenKeys.insert(.init(pid: pid, windowId: winId))
        }
        controller.internalWorkspaceManager.removeMissing(keys: seenKeys)
        controller.internalWorkspaceManager.garbageCollectUnusedWorkspaces(focusedWorkspaceId: focusedWorkspaceId)

        try Task.checkCancellation()

        var activeWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        for monitor in controller.internalWorkspaceManager.monitors {
            if let workspace = controller.internalWorkspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                activeWorkspaceIds.insert(workspace.id)
            }
        }

        layoutWithNiriEngine(activeWorkspaces: activeWorkspaceIds, useScrollAnimationPath: false)

        if let focusedWorkspaceId {
            controller.ensureFocusedHandleValid(in: focusedWorkspaceId)
        }

        hasCompletedInitialRefresh = true
    }

    func layoutWithNiriEngine(activeWorkspaces: Set<WorkspaceDescriptor.ID>, useScrollAnimationPath: Bool = false) {
        guard let controller else { return }
        guard let engine = controller.internalNiriEngine else { return }
        let workspaceManager = controller.internalWorkspaceManager

        let cornersByMonitor = CornerHidingService.calculateOptimalCorners(for: workspaceManager.monitors)

        for monitor in workspaceManager.monitors {
            guard let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id) else { continue }
            unhideWorkspace(workspace.id, monitor: monitor)
        }

        for monitor in workspaceManager.monitors {
            guard let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id) else { continue }
            let wsId = workspace.id

            let windowHandles = workspaceManager.entries(in: wsId).map(\.handle)
            let existingHandleIds = Set(engine.root(for: wsId)?.allWindows.map(\.handle.id) ?? [])
            let currentSelection = workspaceManager.niriViewportState(for: wsId).selectedNodeId
            _ = engine.syncWindows(windowHandles, in: wsId, selectedNodeId: currentSelection, focusedHandle: controller.internalFocusedHandle)
            let newHandles = windowHandles.filter { !existingHandleIds.contains($0.id) }

            for entry in workspaceManager.entries(in: wsId) {
                let currentSize = (try? AXWindowService.frame(entry.axRef))?.size
                var constraints = AXWindowService.sizeConstraints(entry.axRef, currentSize: currentSize)

                if let bundleId = controller.internalAppInfoCache.bundleId(for: entry.handle.pid),
                   let rule = controller.internalAppRulesByBundleId[bundleId]
                {
                    if let minW = rule.minWidth {
                        constraints.minSize.width = max(constraints.minSize.width, minW)
                    }
                    if let minH = rule.minHeight {
                        constraints.minSize.height = max(constraints.minSize.height, minH)
                    }
                }

                engine.updateWindowConstraints(for: entry.handle, constraints: constraints)
            }

            var state = workspaceManager.niriViewportState(for: wsId)
            state.displayRefreshRate = refreshRateByDisplay[monitor.id.displayId] ?? 60.0

            if let selectedId = state.selectedNodeId {
                if engine.findNode(by: selectedId) == nil {
                    state.selectedNodeId = engine.validateSelection(selectedId, in: wsId)
                }
            }

            if state.selectedNodeId == nil {
                if let firstHandle = windowHandles.first,
                   let firstNode = engine.findNode(for: firstHandle)
                {
                    state.selectedNodeId = firstNode.id
                }
            }

            if let selectedId = state.selectedNodeId,
               let selectedNode = engine.findNode(by: selectedId) as? NiriWindow
            {
                controller.internalLastFocusedByWorkspace[wsId] = selectedNode.handle
                if let currentFocused = controller.internalFocusedHandle {
                    if workspaceManager.workspace(for: currentFocused) == wsId {
                        controller.internalFocusedHandle = selectedNode.handle
                    }
                } else {
                    controller.internalFocusedHandle = selectedNode.handle
                }
            }

            let gaps = LayoutGaps(
                horizontal: CGFloat(workspaceManager.gaps),
                vertical: CGFloat(workspaceManager.gaps),
                outer: workspaceManager.outerGaps
            )

            let insetFrame = controller.insetWorkingFrame(from: monitor.visibleFrame)
            let area = WorkingAreaContext(
                workingFrame: insetFrame,
                viewFrame: monitor.frame,
                scale: backingScale(for: monitor)
            )

            var newWindowHandle: WindowHandle?
            if hasCompletedInitialRefresh,
               let newHandle = newHandles.last,
               let newNode = engine.findNode(for: newHandle),
               wsId == controller.activeWorkspace()?.id
            {
                state.selectedNodeId = newNode.id
                let gap = CGFloat(workspaceManager.gaps)
                engine.ensureSelectionVisible(
                    node: newNode,
                    in: wsId,
                    state: &state,
                    edge: .right,
                    workingFrame: insetFrame,
                    gaps: gap
                )
                controller.internalFocusedHandle = newHandle
                controller.internalLastFocusedByWorkspace[wsId] = newHandle
                engine.updateFocusTimestamp(for: newNode.id)
                workspaceManager.updateNiriViewportState(state, for: wsId)
                newWindowHandle = newHandle
            }

            let frames = engine.calculateCombinedLayout(
                in: wsId,
                monitor: monitor,
                gaps: gaps,
                state: state,
                workingArea: area
            )

            if let newHandle = newWindowHandle {
                startScrollAnimation(for: wsId)
                controller.focusWindow(newHandle)
            }

            let hiddenHandles = engine.hiddenWindowHandles(in: wsId, state: state, workingFrame: insetFrame)
            let corner = cornersByMonitor[monitor.id] ?? .bottomRightCorner

            if useScrollAnimationPath && activeSnapshot == nil {
                let orientation = engine.monitor(for: monitor.id)?.orientation ?? monitor.autoOrientation
                activeSnapshot = AnimationSnapshot(
                    workspaceId: wsId,
                    targetFrames: frames,
                    targetViewportOffset: state.viewOffsetPixels.current(),
                    workingFrame: insetFrame,
                    hiddenHandles: hiddenHandles,
                    orientation: orientation
                )
                sizesAppliedForAnimation = false
            }

            for entry in workspaceManager.entries(in: wsId) {
                if hiddenHandles.contains(entry.handle) {
                    hideWindow(entry, monitor: monitor, corner: corner)
                } else {
                    unhideWindow(entry, monitor: monitor)
                }
            }

            var frameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []
            var positionOnlyUpdates: [(windowId: Int, origin: CGPoint)] = []
            var needsFullUpdate = false

            for (handle, frame) in frames {
                if hiddenHandles.contains(handle) { continue }
                if let entry = workspaceManager.entry(for: handle) {
                    frameUpdates.append((handle.pid, entry.windowId, frame))

                    if useScrollAnimationPath {
                        if let cachedSize = cachedWindowSizes[entry.windowId],
                           abs(cachedSize.width - frame.size.width) < 1 &&
                           abs(cachedSize.height - frame.size.height) < 1
                        {
                            positionOnlyUpdates.append((entry.windowId, frame.origin))
                        } else {
                            needsFullUpdate = true
                        }
                    }
                    cachedWindowSizes[entry.windowId] = frame.size
                }
            }

            if useScrollAnimationPath && !needsFullUpdate && !positionOnlyUpdates.isEmpty {
                controller.internalAXManager.applyPositionsViaSkyLight(positionOnlyUpdates)
            } else {
                controller.internalAXManager.applyFramesParallel(frameUpdates)
            }

            if let focusedHandle = controller.internalFocusedHandle {
                if hiddenHandles.contains(focusedHandle) {
                    controller.internalBorderManager.hideBorder()
                } else if let frame = frames[focusedHandle],
                          let entry = workspaceManager.entry(for: focusedHandle)
                {
                    controller.updateBorderIfAllowed(handle: focusedHandle, frame: frame, windowId: entry.windowId)
                }
            }

            workspaceManager.updateNiriViewportState(state, for: wsId)
        }

        updateTabbedColumnOverlays()
        controller.updateWorkspaceBar()

        for ws in workspaceManager.workspaces where !activeWorkspaces.contains(ws.id) {
            guard let monitor = workspaceManager.monitor(for: ws.id) else { continue }
            guard let corner = cornersByMonitor[monitor.id] else { continue }
            hideWorkspace(ws.id, monitor: monitor, corner: corner)
        }
    }

    private func backingScale(for monitor: Monitor) -> CGFloat {
        NSScreen.screens.first(where: { $0.displayId == monitor.id.displayId })?.backingScaleFactor ?? 2.0
    }

    private func unhideWorkspace(_ workspaceId: WorkspaceDescriptor.ID, monitor: Monitor) {
        guard let controller else { return }
        for entry in controller.internalWorkspaceManager.entries(in: workspaceId) {
            unhideWindow(entry, monitor: monitor)
        }
    }

    private func hideWorkspace(_ workspaceId: WorkspaceDescriptor.ID, monitor: Monitor, corner: OptimalHideCorner) {
        guard let controller else { return }
        for entry in controller.internalWorkspaceManager.entries(in: workspaceId) {
            hideWindow(entry, monitor: monitor, corner: corner)
        }
    }

    private func hideWindow(_ entry: WindowModel.Entry, monitor: Monitor, corner: OptimalHideCorner) {
        guard let controller else { return }
        guard let frame = try? AXWindowService.frame(entry.axRef) else { return }
        if !controller.internalWorkspaceManager.isHiddenInCorner(entry.handle) {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let referenceFrame = center.monitorApproximation(in: controller.internalWorkspaceManager.monitors)?
                .frame ?? monitor.frame
            let proportional = proportionalPosition(topLeft: frame.topLeftCorner, in: referenceFrame)
            controller.internalWorkspaceManager.setHiddenProportionalPosition(proportional, for: entry.handle)
        }
        let origin = hiddenOrigin(for: frame.size, monitor: monitor, corner: corner, pid: entry.handle.pid)
        try? AXWindowService.setFrame(entry.axRef, frame: CGRect(origin: origin, size: frame.size))
    }

    private func unhideWindow(_ entry: WindowModel.Entry, monitor _: Monitor) {
        guard let controller else { return }
        controller.internalWorkspaceManager.setHiddenProportionalPosition(nil, for: entry.handle)
    }

    private func proportionalPosition(topLeft: CGPoint, in frame: CGRect) -> CGPoint {
        let width = max(1, frame.width)
        let height = max(1, frame.height)
        let x = (topLeft.x - frame.minX) / width
        let y = (frame.maxY - topLeft.y) / height
        return CGPoint(x: min(max(0, x), 1), y: min(max(0, y), 1))
    }

    private func hiddenOrigin(
        for size: CGSize,
        monitor: Monitor,
        corner: OptimalHideCorner,
        pid: pid_t
    ) -> CGPoint {
        let visible = monitor.visibleFrame
        let offset: CGFloat = isZoomApp(pid) ? 0 : 1
        switch corner {
        case .bottomLeftCorner:
            return CGPoint(x: visible.minX - size.width + offset, y: visible.minY + offset - size.height)
        case .bottomRightCorner:
            return CGPoint(x: visible.maxX - offset, y: visible.minY + offset - size.height)
        }
    }

    private func isZoomApp(_ pid: pid_t) -> Bool {
        controller?.internalAppInfoCache.bundleId(for: pid) == "us.zoom.xos"
    }

    func updateTabbedColumnOverlays() {
        guard let controller else { return }
        guard let engine = controller.internalNiriEngine else {
            controller.internalTabbedOverlayManager.removeAll()
            return
        }

        var infos: [TabbedColumnOverlayInfo] = []
        for monitor in controller.internalWorkspaceManager.monitors {
            guard let workspace = controller.internalWorkspaceManager.activeWorkspaceOrFirst(on: monitor.id)
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
                let activeWindowId = controller.internalWorkspaceManager.entry(for: activeHandle)?.windowId

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

        controller.internalTabbedOverlayManager.updateOverlays(infos)
    }

    func selectTabInNiri(workspaceId: WorkspaceDescriptor.ID, columnId: NodeId, index: Int) {
        guard let controller else { return }
        guard let engine = controller.internalNiriEngine else { return }
        guard let column = engine.columns(in: workspaceId).first(where: { $0.id == columnId }) else { return }

        let windows = column.windowNodes
        guard windows.indices.contains(index) else { return }

        column.setActiveTileIdx(index)
        engine.updateTabbedColumnVisibility(column: column)

        let target = windows[index]
        var state = controller.internalWorkspaceManager.niriViewportState(for: workspaceId)
        state.selectedNodeId = target.id
        if let monitor = controller.internalWorkspaceManager.monitor(for: workspaceId) {
            let gap = CGFloat(controller.internalWorkspaceManager.gaps)
            engine.ensureSelectionVisible(
                node: target,
                in: workspaceId,
                state: &state,
                edge: .left,
                workingFrame: monitor.visibleFrame,
                gaps: gap
            )
        }
        controller.internalWorkspaceManager.updateNiriViewportState(state, for: workspaceId)

        controller.internalFocusedHandle = target.handle
        engine.updateFocusTimestamp(for: target.id)
        controller.focusWindow(target.handle)
        updateTabbedColumnOverlays()
    }
}
