import AppKit
import Foundation
import QuartzCore

@MainActor
final class LayoutRefreshController {
    private weak var controller: WMController?

    private var activeRefreshTask: Task<Void, Never>?
    private var isInLightSession: Bool = false
    private var isImmediateLayoutInProgress: Bool = false
    private var isFullEnumerationInProgress: Bool = false

    private var displayLinksByDisplay: [CGDirectDisplayID: CADisplayLink] = [:]
    private var scrollAnimationByDisplay: [CGDirectDisplayID: WorkspaceDescriptor.ID] = [:]
    private var dwindleAnimationByDisplay: [CGDirectDisplayID: (WorkspaceDescriptor.ID, Monitor)] = [:]
    private var refreshRateByDisplay: [CGDirectDisplayID: Double] = [:]
    private var screenChangeObserver: NSObjectProtocol?
    private var hasCompletedInitialRefresh: Bool = false

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
        if let existing = displayLinksByDisplay[displayId] {
            return existing
        }

        guard let screen = NSScreen.screens.first(where: { $0.displayId == displayId }) else {
            return nil
        }
        let link = screen.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        displayLinksByDisplay[displayId] = link
        return link
    }

    private func handleScreenParametersChanged() {
        detectRefreshRates()

        let currentDisplayIds = Set(NSScreen.screens.compactMap(\.displayId))

        let removedDisplayIds = displayLinksByDisplay.keys.filter { !currentDisplayIds.contains($0) }

        for displayId in removedDisplayIds {
            if let link = displayLinksByDisplay.removeValue(forKey: displayId) {
                link.invalidate()
            }

            if let wsId = scrollAnimationByDisplay.removeValue(forKey: displayId) {
                startScrollAnimation(for: wsId)
            }
            dwindleAnimationByDisplay.removeValue(forKey: displayId)
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

    @objc private func displayLinkFired(_ displayLink: CADisplayLink) {
        guard let displayId = displayLinksByDisplay.first(where: { $0.value === displayLink })?.key
        else { return }

        tickScrollAnimation(targetTime: displayLink.targetTimestamp, displayId: displayId)
        tickDwindleAnimation(targetTime: displayLink.targetTimestamp, displayId: displayId)
    }

    func startScrollAnimation(for workspaceId: WorkspaceDescriptor.ID) {
        let targetDisplayId: CGDirectDisplayID
        if let controller,
           let monitor = controller.internalWorkspaceManager.monitor(for: workspaceId)
        {
            targetDisplayId = monitor.displayId
        } else if let mainDisplayId = NSScreen.main?.displayId {
            targetDisplayId = mainDisplayId
        } else {
            return
        }

        if scrollAnimationByDisplay[targetDisplayId] == workspaceId {
            return
        }

        scrollAnimationByDisplay[targetDisplayId] = workspaceId

        if let displayLink = getOrCreateDisplayLink(for: targetDisplayId) {
            displayLink.add(to: .main, forMode: .common)
        }
    }

    func stopScrollAnimation(for displayId: CGDirectDisplayID) {
        scrollAnimationByDisplay.removeValue(forKey: displayId)
        stopDisplayLinkIfIdle(for: displayId)
    }

    func stopAllScrollAnimations() {
        let displayIds = Array(scrollAnimationByDisplay.keys)
        scrollAnimationByDisplay.removeAll()
        for displayId in displayIds {
            stopDisplayLinkIfIdle(for: displayId)
        }
    }

    func startDwindleAnimation(for workspaceId: WorkspaceDescriptor.ID, monitor: Monitor) {
        let targetDisplayId = monitor.displayId

        if dwindleAnimationByDisplay[targetDisplayId]?.0 == workspaceId {
            return
        }

        dwindleAnimationByDisplay[targetDisplayId] = (workspaceId, monitor)

        if let displayLink = getOrCreateDisplayLink(for: targetDisplayId) {
            displayLink.add(to: .main, forMode: .common)
        }
    }

    func stopDwindleAnimation(for displayId: CGDirectDisplayID) {
        dwindleAnimationByDisplay.removeValue(forKey: displayId)
        stopDisplayLinkIfIdle(for: displayId)
    }

    func stopAllDwindleAnimations() {
        let displayIds = Array(dwindleAnimationByDisplay.keys)
        dwindleAnimationByDisplay.removeAll()
        for displayId in displayIds {
            stopDisplayLinkIfIdle(for: displayId)
        }
    }

    func hasDwindleAnimationRunning(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        dwindleAnimationByDisplay.values.contains { $0.0 == workspaceId }
    }

    private func stopDisplayLinkIfIdle(for displayId: CGDirectDisplayID) {
        if scrollAnimationByDisplay[displayId] == nil && dwindleAnimationByDisplay[displayId] == nil {
            displayLinksByDisplay[displayId]?.remove(from: .main, forMode: .common)
        }
    }

    private func tickDwindleAnimation(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard let (wsId, monitor) = dwindleAnimationByDisplay[displayId] else { return }
        guard let controller,
              let engine = controller.internalDwindleEngine else {
            stopDwindleAnimation(for: displayId)
            return
        }

        engine.tickAnimations(at: targetTime, in: wsId)

        let insetFrame = controller.insetWorkingFrame(for: monitor)
        let baseFrames = engine.calculateLayout(for: wsId, screen: insetFrame)
        let animatedFrames = engine.calculateAnimatedFrames(
            baseFrames: baseFrames,
            in: wsId,
            at: targetTime
        )

        var frameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []
        let workspaceManager = controller.internalWorkspaceManager

        for (handle, frame) in animatedFrames {
            if let entry = workspaceManager.entry(for: handle) {
                frameUpdates.append((handle.pid, entry.windowId, frame))
            }
        }

        controller.internalAXManager.applyFramesParallel(frameUpdates)

        if !engine.hasActiveAnimations(in: wsId, at: targetTime) {
            if let focusedHandle = controller.internalFocusedHandle,
               let frame = animatedFrames[focusedHandle],
               let entry = workspaceManager.entry(for: focusedHandle) {
                controller.updateBorderIfAllowed(handle: focusedHandle, frame: frame, windowId: entry.windowId)
            }
            stopDwindleAnimation(for: displayId)
        }
    }

    private func tickScrollAnimation(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard let wsId = scrollAnimationByDisplay[displayId] else { return }
        guard let controller else {
            stopScrollAnimation(for: displayId)
            return
        }
        guard let engine = controller.internalNiriEngine else {
            stopScrollAnimation(for: displayId)
            return
        }

        var state = controller.internalWorkspaceManager.niriViewportState(for: wsId)

        let viewportAnimationRunning = state.advanceAnimations(at: targetTime)
        let windowAnimationsRunning = engine.tickAllWindowAnimations(in: wsId, at: targetTime)
        let columnAnimationsRunning = engine.tickAllColumnAnimations(in: wsId, at: targetTime)

        guard let monitor = controller.internalWorkspaceManager.monitor(for: wsId) else {
            controller.internalWorkspaceManager.updateNiriViewportState(state, for: wsId)
            stopScrollAnimation(for: displayId)
            return
        }

        applyFramesOnDemand(
            wsId: wsId,
            state: state,
            engine: engine,
            monitor: monitor,
            animationTime: targetTime
        )

        let animationsOngoing = viewportAnimationRunning || windowAnimationsRunning || columnAnimationsRunning

        controller.internalWorkspaceManager.updateNiriViewportState(state, for: wsId)

        if !animationsOngoing {
            finalizeAnimation()
            stopScrollAnimation(for: displayId)
        }
    }

    private func applyFramesOnDemand(
        wsId: WorkspaceDescriptor.ID,
        state: ViewportState,
        engine: NiriLayoutEngine,
        monitor: Monitor,
        animationTime: TimeInterval? = nil
    ) {
        guard let controller else { return }
        let workspaceManager = controller.internalWorkspaceManager

        let gaps = LayoutGaps(
            horizontal: CGFloat(workspaceManager.gaps),
            vertical: CGFloat(workspaceManager.gaps),
            outer: workspaceManager.outerGaps
        )

        let insetFrame = controller.insetWorkingFrame(for: monitor)
        let area = WorkingAreaContext(
            workingFrame: insetFrame,
            viewFrame: monitor.frame,
            scale: backingScale(for: monitor)
        )

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
            guard let entry = workspaceManager.entry(for: handle) else { continue }

            if let node = engine.findNode(for: handle) {
                let alpha = node.renderAlpha(at: time)
                let needsReset = node.consumeAlphaReset()
                if alpha < 0.999 || node.hasAlphaAnimationRunning || needsReset {
                    alphaUpdates.append((UInt32(entry.windowId), Float(alpha)))
                }
            }

            if let side = hiddenHandles[handle] {
                let hiddenOrigin = hiddenOrigin(
                    for: frame.size,
                    monitor: monitor,
                    side: side,
                    pid: handle.pid,
                    targetY: frame.origin.y
                )
                positionUpdates.append((entry.windowId, hiddenOrigin))
                continue
            }

            frameUpdates.append((handle.pid, entry.windowId, frame))
        }

        if !positionUpdates.isEmpty {
            controller.internalAXManager.applyPositionsViaSkyLight(positionUpdates)
        }
        if !frameUpdates.isEmpty {
            controller.internalAXManager.applyFramesParallel(frameUpdates)
        }
        for (windowId, alpha) in alphaUpdates {
            SkyLight.shared.setWindowAlpha(windowId, alpha: alpha)
        }
    }

    private func finalizeAnimation() {
        guard let controller,
              let focusedHandle = controller.internalFocusedHandle,
              let entry = controller.internalWorkspaceManager.entry(for: focusedHandle),
              let engine = controller.internalNiriEngine
        else { return }

        if let node = engine.findNode(for: focusedHandle),
           let frame = node.frame {
            controller.updateBorderIfAllowed(handle: focusedHandle, frame: frame, windowId: entry.windowId)
        }

        if controller.internalMoveMouseToFocusedWindowEnabled {
            controller.moveMouseToWindow(focusedHandle)
        }
    }

    func cancelActiveAnimations(for workspaceId: WorkspaceDescriptor.ID) {
        for (displayId, wsId) in scrollAnimationByDisplay where wsId == workspaceId {
            stopScrollAnimation(for: displayId)
        }

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
        if isFullEnumerationInProgress {
            return
        }
        activeRefreshTask?.cancel()
        activeRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let baseDebounce = event.debounceInterval
                if baseDebounce > 0 {
                    try await Task.sleep(nanoseconds: baseDebounce)
                }
                try Task.checkCancellation()
                if event.requiresFullEnumeration {
                    try await executeFullRefresh()
                } else {
                    await executeIncrementalRefresh()
                }
            } catch {
                return
            }
        }
    }

    private func executeIncrementalRefresh() async {
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

        let (niriWorkspaces, dwindleWorkspaces) = partitionWorkspacesByLayoutType(activeWorkspaceIds)

        if !niriWorkspaces.isEmpty {
            await layoutWithNiriEngine(activeWorkspaces: niriWorkspaces, useScrollAnimationPath: false)
        }
        if !dwindleWorkspaces.isEmpty {
            await layoutWithDwindleEngine(activeWorkspaces: dwindleWorkspaces)
        }

        for ws in controller.internalWorkspaceManager.workspaces where !activeWorkspaceIds.contains(ws.id) {
            guard let monitor = controller.internalWorkspaceManager.monitor(for: ws.id) else { continue }
            hideWorkspace(ws.id, monitor: monitor)
        }

        if let focusedWorkspaceId = controller.activeWorkspace()?.id {
            controller.ensureFocusedHandleValid(in: focusedWorkspaceId)
        }
    }

    func runLightSession(_ body: () -> Void) {
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        isInLightSession = true

        if let controller {
            let focused = controller.internalFocusedHandle
            for monitor in controller.internalWorkspaceManager.monitors {
                if let ws = controller.internalWorkspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                    let handles = controller.internalWorkspaceManager.entries(in: ws.id).map(\.handle)
                    let layoutType = controller.internalSettings.layoutType(for: ws.name)

                    switch layoutType {
                    case .dwindle:
                        if let dwindleEngine = controller.internalDwindleEngine {
                            _ = dwindleEngine.syncWindows(handles, in: ws.id, focusedHandle: focused)
                        }
                    case .niri, .defaultLayout:
                        if let niriEngine = controller.internalNiriEngine {
                            let selection = controller.internalWorkspaceManager.niriViewportState(for: ws.id).selectedNodeId
                            _ = niriEngine.syncWindows(handles, in: ws.id, selectedNodeId: selection, focusedHandle: focused)
                        }
                    }
                }
            }
        }

        body()
        isInLightSession = false
        refreshWindowsAndLayout()
    }

    func executeLayoutRefreshImmediate() {
        Task { @MainActor [weak self] in
            await self?.executeLayoutRefreshImmediateCore()
        }
    }

    private func executeLayoutRefreshImmediateCore() async {
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

        let (niriWorkspaces, dwindleWorkspaces) = partitionWorkspacesByLayoutType(activeWorkspaceIds)

        if !niriWorkspaces.isEmpty {
            await layoutWithNiriEngine(activeWorkspaces: niriWorkspaces, useScrollAnimationPath: !scrollAnimationByDisplay.isEmpty)
        }
        if !dwindleWorkspaces.isEmpty {
            await layoutWithDwindleEngine(activeWorkspaces: dwindleWorkspaces)
        }
    }

    func resetState() {
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        isInLightSession = false

        for (_, link) in displayLinksByDisplay {
            link.invalidate()
        }
        displayLinksByDisplay.removeAll()
        scrollAnimationByDisplay.removeAll()
        dwindleAnimationByDisplay.removeAll()

        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            screenChangeObserver = nil
        }
    }

    var isDiscoveryInProgress: Bool {
        isFullEnumerationInProgress
    }

    private func executeFullRefresh() async throws {
        isFullEnumerationInProgress = true
        defer { isFullEnumerationInProgress = false }
        guard let controller else {
            return
        }

        if controller.internalLockScreenObserver.isFrontmostAppLockScreen() || controller.internalIsLockScreenActive {
            return
        }

        let windows = await controller.internalAXManager.currentWindowsAsync()
        try Task.checkCancellation()
        var seenKeys: Set<WindowModel.WindowKey> = []
        let focusedWorkspaceId = controller.activeWorkspace()?.id

        for (ax, pid, winId) in windows {
            if let bundleId = controller.appInfoCache.bundleId(for: pid) {
                if bundleId == LockScreenObserver.lockScreenAppBundleId {
                    continue
                }
                if controller.internalAppRulesByBundleId[bundleId]?.alwaysFloat == true {
                    continue
                }
            }

            let defaultWorkspace = controller.resolveWorkspaceForNewWindow(
                axRef: ax,
                pid: pid,
                fallbackWorkspaceId: focusedWorkspaceId
            )
            let wsForWindow = controller.workspaceAssignment(pid: pid, windowId: winId) ?? defaultWorkspace

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

        let (niriWorkspaces, dwindleWorkspaces) = partitionWorkspacesByLayoutType(activeWorkspaceIds)

        if !niriWorkspaces.isEmpty {
            await layoutWithNiriEngine(activeWorkspaces: niriWorkspaces, useScrollAnimationPath: false)
        }
        if !dwindleWorkspaces.isEmpty {
            await layoutWithDwindleEngine(activeWorkspaces: dwindleWorkspaces)
        }
        controller.updateWorkspaceBar()

        if let focusedWorkspaceId {
            controller.ensureFocusedHandleValid(in: focusedWorkspaceId)
        }

        hasCompletedInitialRefresh = true
        controller.internalAXEventHandler?.subscribeToManagedWindows()
    }

    func layoutWithNiriEngine(activeWorkspaces: Set<WorkspaceDescriptor.ID>, useScrollAnimationPath: Bool = false, removedNodeId: NodeId? = nil) async {
        guard let controller else { return }
        guard let engine = controller.internalNiriEngine else { return }
        let workspaceManager = controller.internalWorkspaceManager

        var hiddenHandlesByWorkspace = [WorkspaceDescriptor.ID: [WindowHandle: HideSide]]()

        for monitor in workspaceManager.monitors {
            guard let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id) else { continue }
            unhideWorkspace(workspace.id, monitor: monitor)
        }

        var processedWorkspaces: Set<WorkspaceDescriptor.ID> = []
        for iterationMonitor in workspaceManager.monitors {
            guard let workspace = workspaceManager.activeWorkspaceOrFirst(on: iterationMonitor.id) else { continue }
            let wsId = workspace.id
            guard !processedWorkspaces.contains(wsId) else { continue }
            processedWorkspaces.insert(wsId)

            guard let monitor = workspaceManager.monitor(for: wsId) else { continue }

            let windowHandles = workspaceManager.entries(in: wsId).map(\.handle)
            let existingHandleIds = engine.root(for: wsId)?.windowIdSet ?? []
            var currentHandleIds = Set<UUID>(minimumCapacity: windowHandles.count)
            for handle in windowHandles {
                currentHandleIds.insert(handle.id)
            }
            let currentSelection = workspaceManager.niriViewportState(for: wsId).selectedNodeId
            let removedHandleIds = existingHandleIds.subtracting(currentHandleIds)

            var precomputedFallback: NodeId?
            var originalColumnIndex: Int?
            var columnRemovalResult: NiriLayoutEngine.ColumnRemovalResult?
            var state = workspaceManager.niriViewportState(for: wsId)

            let wasEmptyBeforeSync = engine.columns(in: wsId).isEmpty

            for removedHandleId in removedHandleIds {
                guard let window = engine.root(for: wsId)?.allWindows.first(where: { $0.handle.id == removedHandleId }),
                      let col = engine.column(of: window),
                      let colIdx = engine.columnIndex(of: col, in: wsId) else { continue }

                let allWindowsInColumnRemoved = col.windowNodes.allSatisfy { w in
                    !currentHandleIds.contains(w.handle.id)
                }

                if allWindowsInColumnRemoved && columnRemovalResult == nil {
                    originalColumnIndex = colIdx
                    let gap = CGFloat(workspaceManager.gaps)
                    columnRemovalResult = engine.animateColumnsForRemoval(
                        columnIndex: colIdx,
                        in: wsId,
                        state: &state,
                        gaps: gap
                    )
                }

                let nodeIdForFallback = removedNodeId ?? currentSelection
                if window.id == nodeIdForFallback {
                    precomputedFallback = engine.fallbackSelectionOnRemoval(
                        removing: window.id,
                        in: wsId
                    )
                }
            }

            _ = engine.syncWindows(
                windowHandles,
                in: wsId,
                selectedNodeId: currentSelection,
                focusedHandle: controller.internalFocusedHandle
            )
            let newHandles = windowHandles.filter { !existingHandleIds.contains($0.id) }

            let earlyGap = CGFloat(workspaceManager.gaps)
            let earlyInsetFrame = controller.insetWorkingFrame(for: monitor)
            for col in engine.columns(in: wsId) {
                if col.cachedWidth <= 0 {
                    col.resolveAndCacheWidth(workingAreaWidth: earlyInsetFrame.width, gaps: earlyGap)
                }
            }

            if !wasEmptyBeforeSync, !newHandles.isEmpty {
                let gap = earlyGap
                let workingWidth = earlyInsetFrame.width

                var newColumnData: [(col: NiriContainer, colIdx: Int)] = []
                for newHandle in newHandles {
                    if let node = engine.findNode(for: newHandle),
                       let col = engine.column(of: node),
                       let colIdx = engine.columnIndex(of: col, in: wsId)
                    {
                        if !newColumnData.contains(where: { $0.col.id == col.id }) {
                            newColumnData.append((col, colIdx))
                        }
                    }
                }

                let originalActiveIdx = state.activeColumnIndex
                let insertedBeforeActive = newColumnData.filter { $0.colIdx <= originalActiveIdx }
                if !insertedBeforeActive.isEmpty, columnRemovalResult == nil {
                    let totalInsertedWidth = insertedBeforeActive.reduce(CGFloat(0)) { total, data in
                        total + data.col.cachedWidth + gap
                    }
                    state.viewOffsetPixels.offset(delta: Double(-totalInsertedWidth))
                    state.activeColumnIndex = originalActiveIdx + insertedBeforeActive.count
                }

                let sortedNewColumns = newColumnData.sorted { $0.colIdx < $1.colIdx }
                for addedData in sortedNewColumns {
                    engine.animateColumnsForAddition(
                        columnIndex: addedData.colIdx,
                        in: wsId,
                        state: state,
                        gaps: gap,
                        workingAreaWidth: workingWidth
                    )
                }

            }

            for entry in workspaceManager.entries(in: wsId) {
                let currentSize = (AXWindowService.framePreferFast(entry.axRef))?.size
                var constraints: WindowSizeConstraints
                if let cached = workspaceManager.cachedConstraints(for: entry.handle) {
                    constraints = cached
                } else {
                    constraints = AXWindowService.sizeConstraints(entry.axRef, currentSize: currentSize)
                    workspaceManager.setCachedConstraints(constraints, for: entry.handle)
                }

                if let bundleId = controller.appInfoCache.bundleId(for: entry.handle.pid),
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

            state.displayRefreshRate = refreshRateByDisplay[monitor.displayId] ?? 60.0

            if let result = columnRemovalResult {
                if let prevOffset = state.activatePrevColumnOnRemoval {
                    state.viewOffsetPixels = .static(prevOffset)
                    state.activatePrevColumnOnRemoval = nil
                }

                if let fallback = result.fallbackSelectionId {
                    state.selectedNodeId = fallback
                } else if let selectedId = state.selectedNodeId, engine.findNode(by: selectedId) == nil {
                    state.selectedNodeId = precomputedFallback
                        ?? engine.validateSelection(selectedId, in: wsId)
                }
            } else {
                if let selectedId = state.selectedNodeId {
                    if engine.findNode(by: selectedId) == nil {
                        state.selectedNodeId = precomputedFallback
                            ?? engine.validateSelection(selectedId, in: wsId)
                    }
                }
            }

            if state.selectedNodeId == nil {
                if let firstHandle = windowHandles.first,
                   let firstNode = engine.findNode(for: firstHandle)
                {
                    state.selectedNodeId = firstNode.id
                }
            }

            let offsetBefore = state.viewOffsetPixels.current()
            var viewportNeedsRecalc = false

            let isGestureOrAnimation = state.viewOffsetPixels.isGesture || state.viewOffsetPixels.isAnimating

            let gap = CGFloat(workspaceManager.gaps)
            let insetFrame = controller.insetWorkingFrame(for: monitor)

            for col in engine.columns(in: wsId) {
                if col.cachedWidth <= 0 {
                    col.resolveAndCacheWidth(workingAreaWidth: insetFrame.width, gaps: gap)
                }
            }

            if !isGestureOrAnimation,
               wsId == controller.activeWorkspace()?.id,
               let selectedId = state.selectedNodeId,
               let selectedNode = engine.findNode(by: selectedId)
            {
                if let restoreOffset = columnRemovalResult?.restorePreviousViewOffset {
                    state.viewOffsetPixels = .static(restoreOffset)
                } else {
                    engine.ensureSelectionVisible(
                        node: selectedNode,
                        in: wsId,
                        state: &state,
                        edge: .left,
                        workingFrame: insetFrame,
                        gaps: gap,
                        alwaysCenterSingleColumn: engine.alwaysCenterSingleColumn,
                        fromColumnIndex: originalColumnIndex
                    )
                }
                if abs(state.viewOffsetPixels.current() - offsetBefore) > 1 {
                    workspaceManager.updateNiriViewportState(state, for: wsId)
                    viewportNeedsRecalc = true
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

            let area = WorkingAreaContext(
                workingFrame: insetFrame,
                viewFrame: monitor.frame,
                scale: backingScale(for: monitor)
            )

            let wasEmpty = existingHandleIds.isEmpty

            var newWindowHandle: WindowHandle?
            if hasCompletedInitialRefresh,
               let newHandle = newHandles.last,
               let newNode = engine.findNode(for: newHandle),
               wsId == controller.activeWorkspace()?.id
            {
                state.selectedNodeId = newNode.id

                if wasEmpty {
                    let cols = engine.columns(in: wsId)
                    state.transitionToColumn(
                        0,
                        columns: cols,
                        gap: gap,
                        viewportWidth: insetFrame.width,
                        animate: false,
                        centerMode: engine.centerFocusedColumn
                    )
                } else if let newCol = engine.column(of: newNode),
                          let newColIdx = engine.columnIndex(of: newCol, in: wsId) {
                    if newCol.cachedWidth <= 0 {
                        newCol.resolveAndCacheWidth(workingAreaWidth: insetFrame.width, gaps: gap)
                    }

                    let shouldRestorePrevOffset = newColIdx == state.activeColumnIndex + 1
                    let offsetBeforeActivation = state.stationary()

                    engine.ensureSelectionVisible(
                        node: newNode,
                        in: wsId,
                        state: &state,
                        edge: .right,
                        workingFrame: insetFrame,
                        gaps: gap,
                        alwaysCenterSingleColumn: engine.alwaysCenterSingleColumn,
                        fromColumnIndex: state.activeColumnIndex
                    )

                    if shouldRestorePrevOffset {
                        state.activatePrevColumnOnRemoval = offsetBeforeActivation
                    }
                }
                controller.internalFocusedHandle = newHandle
                controller.internalLastFocusedByWorkspace[wsId] = newHandle
                engine.updateFocusTimestamp(for: newNode.id)
                workspaceManager.updateNiriViewportState(state, for: wsId)
                newWindowHandle = newHandle
            }

            let (frames, hiddenHandles) = engine.calculateCombinedLayoutUsingPools(
                in: wsId,
                monitor: monitor,
                gaps: gaps,
                state: state,
                workingArea: area,
                animationTime: nil
            )

            let hasColumnAnimations = engine.hasAnyColumnAnimationsRunning(in: wsId)

            if !useScrollAnimationPath {
                if viewportNeedsRecalc, newWindowHandle == nil {
                    startScrollAnimation(for: wsId)
                } else if hasColumnAnimations {
                    startScrollAnimation(for: wsId)
                }
            }

            if let newHandle = newWindowHandle {
                startScrollAnimation(for: wsId)
                controller.focusWindow(newHandle)
            }

            hiddenHandlesByWorkspace[wsId] = hiddenHandles

            for entry in workspaceManager.entries(in: wsId) {
                if let side = hiddenHandles[entry.handle] {
                    let targetY = frames[entry.handle]?.origin.y
                    hideWindow(entry, monitor: monitor, side: side, targetY: targetY)
                } else {
                    unhideWindow(entry, monitor: monitor)
                }
            }

            var frameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []

            for (handle, frame) in frames {
                if hiddenHandles[handle] != nil { continue }
                if let entry = workspaceManager.entry(for: handle) {
                    frameUpdates.append((handle.pid, entry.windowId, frame))
                }
            }

            controller.internalAXManager.applyFramesParallel(frameUpdates)

            if !useScrollAnimationPath, let focusedHandle = controller.internalFocusedHandle {
                if hiddenHandles[focusedHandle] != nil {
                    controller.internalBorderManager.hideBorder()
                } else if let frame = frames[focusedHandle],
                          let entry = workspaceManager.entry(for: focusedHandle)
                {
                    controller.updateBorderIfAllowed(handle: focusedHandle, frame: frame, windowId: entry.windowId)
                }
            }

            workspaceManager.updateNiriViewportState(state, for: wsId)

            await Task.yield()
        }

        updateTabbedColumnOverlays()
        controller.updateWorkspaceBar()
    }

    func layoutWithDwindleEngine(activeWorkspaces: Set<WorkspaceDescriptor.ID>) async {
        guard let controller else { return }
        guard let engine = controller.internalDwindleEngine else { return }
        let workspaceManager = controller.internalWorkspaceManager

        for monitor in workspaceManager.monitors {
            guard let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id) else { continue }
            let wsId = workspace.id

            guard activeWorkspaces.contains(wsId) else { continue }

            let wsName = workspace.name
            let layoutType = controller.internalSettings.layoutType(for: wsName)
            guard layoutType == .dwindle else { continue }

            let oldFrames = engine.currentFrames(in: wsId)

            let windowHandles = workspaceManager.entries(in: wsId).map(\.handle)
            let focusedHandle = controller.internalFocusedHandle

            _ = engine.syncWindows(windowHandles, in: wsId, focusedHandle: focusedHandle)

            for entry in workspaceManager.entries(in: wsId) {
                let currentSize = (AXWindowService.framePreferFast(entry.axRef))?.size
                var constraints: WindowSizeConstraints
                if let cached = workspaceManager.cachedConstraints(for: entry.handle) {
                    constraints = cached
                } else {
                    constraints = AXWindowService.sizeConstraints(entry.axRef, currentSize: currentSize)
                    workspaceManager.setCachedConstraints(constraints, for: entry.handle)
                }

                if let bundleId = controller.appInfoCache.bundleId(for: entry.handle.pid),
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

            let insetFrame = controller.insetWorkingFrame(for: monitor)

            let newFrames = engine.calculateLayout(for: wsId, screen: insetFrame)

            for entry in workspaceManager.entries(in: wsId) {
                if newFrames[entry.handle] != nil {
                    unhideWindow(entry, monitor: monitor)
                }
            }

            if let selected = engine.selectedNode(in: wsId),
               case let .leaf(handle, _) = selected.kind,
               let handle {
                controller.internalLastFocusedByWorkspace[wsId] = handle
                if let currentFocused = controller.internalFocusedHandle {
                    if workspaceManager.workspace(for: currentFocused) == wsId {
                        controller.internalFocusedHandle = handle
                    }
                } else {
                    controller.internalFocusedHandle = handle
                }
            }

            if controller.internalAnimationsEnabled {
                engine.animateWindowMovements(oldFrames: oldFrames, newFrames: newFrames)
            }

            let now = CACurrentMediaTime()
            if controller.internalAnimationsEnabled, engine.hasActiveAnimations(in: wsId, at: now) {
                startDwindleAnimation(for: wsId, monitor: monitor)

                if let focusedHandle = controller.internalFocusedHandle,
                   let frame = newFrames[focusedHandle],
                   let entry = workspaceManager.entry(for: focusedHandle) {
                    controller.internalBorderManager.updateFocusedWindow(frame: frame, windowId: entry.windowId)
                }
            } else {
                var frameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []

                for (handle, frame) in newFrames {
                    if let entry = workspaceManager.entry(for: handle) {
                        frameUpdates.append((handle.pid, entry.windowId, frame))
                    }
                }

                controller.internalAXManager.applyFramesParallel(frameUpdates)

                if let focusedHandle = controller.internalFocusedHandle,
                   let frame = newFrames[focusedHandle],
                   let entry = workspaceManager.entry(for: focusedHandle) {
                    controller.updateBorderIfAllowed(handle: focusedHandle, frame: frame, windowId: entry.windowId)
                }
            }

            await Task.yield()
        }

        controller.updateWorkspaceBar()
    }

    private func partitionWorkspacesByLayoutType(
        _ workspaces: Set<WorkspaceDescriptor.ID>
    ) -> (niri: Set<WorkspaceDescriptor.ID>, dwindle: Set<WorkspaceDescriptor.ID>) {
        guard let controller else { return (workspaces, []) }

        var niriWorkspaces: Set<WorkspaceDescriptor.ID> = []
        var dwindleWorkspaces: Set<WorkspaceDescriptor.ID> = []

        for wsId in workspaces {
            guard let ws = controller.internalWorkspaceManager.descriptor(for: wsId) else {
                niriWorkspaces.insert(wsId)
                continue
            }
            let layoutType = controller.internalSettings.layoutType(for: ws.name)
            switch layoutType {
            case .dwindle:
                dwindleWorkspaces.insert(wsId)
            case .niri, .defaultLayout:
                niriWorkspaces.insert(wsId)
            }
        }

        return (niriWorkspaces, dwindleWorkspaces)
    }

    private func backingScale(for monitor: Monitor) -> CGFloat {
        NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?.backingScaleFactor ?? 2.0
    }

    private func unhideWorkspace(_ workspaceId: WorkspaceDescriptor.ID, monitor: Monitor) {
        guard let controller else { return }
        for entry in controller.internalWorkspaceManager.entries(in: workspaceId) {
            unhideWindow(entry, monitor: monitor)
        }
    }

    private func hideWorkspace(_ workspaceId: WorkspaceDescriptor.ID, monitor: Monitor) {
        guard let controller else { return }
        for entry in controller.internalWorkspaceManager.entries(in: workspaceId) {
            hideWindow(entry, monitor: monitor, side: .right, targetY: nil)
        }
    }

    private func hideWindow(_ entry: WindowModel.Entry, monitor: Monitor, side: HideSide, targetY: CGFloat?) {
        guard let controller else { return }
        guard let frame = AXWindowService.framePreferFast(entry.axRef) else { return }
        if !controller.internalWorkspaceManager.isHiddenInCorner(entry.handle) {
            let center = frame.center
            let referenceFrame = center.monitorApproximation(in: controller.internalWorkspaceManager.monitors)?
                .frame ?? monitor.frame
            let proportional = proportionalPosition(topLeft: frame.topLeftCorner, in: referenceFrame)
            controller.internalWorkspaceManager.setHiddenProportionalPosition(proportional, for: entry.handle)
        }
        let yPos = targetY ?? frame.origin.y
        let origin = hiddenOrigin(for: frame.size, monitor: monitor, side: side, pid: entry.handle.pid, targetY: yPos)
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
        side: HideSide,
        pid: pid_t,
        targetY: CGFloat
    ) -> CGPoint {
        let visible = monitor.visibleFrame
        let offset: CGFloat = isZoomApp(pid) ? 0 : 1
        switch side {
        case .left:
            return CGPoint(x: visible.minX - size.width + offset, y: targetY)
        case .right:
            return CGPoint(x: visible.maxX - offset, y: targetY)
        }
    }

    private func isZoomApp(_ pid: pid_t) -> Bool {
        controller?.appInfoCache.bundleId(for: pid) == "us.zoom.xos"
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
                gaps: gap,
                alwaysCenterSingleColumn: engine.alwaysCenterSingleColumn
            )
        }
        controller.internalWorkspaceManager.updateNiriViewportState(state, for: workspaceId)

        controller.internalFocusedHandle = target.handle
        engine.updateFocusTimestamp(for: target.id)
        controller.focusWindow(target.handle)
        updateTabbedColumnOverlays()
    }
}
