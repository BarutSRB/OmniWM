import AppKit
import Foundation
import QuartzCore

@MainActor final class LayoutRefreshController: NSObject {
    weak var controller: WMController?

    struct LayoutState {
        struct ClosingAnimation {
            let windowId: Int
            let axRef: AXWindowRef
            let fromFrame: CGRect
            let displacement: CGPoint
            let animation: SpringAnimation

            func progress(at time: TimeInterval) -> Double {
                animation.value(at: time)
            }

            func isComplete(at time: TimeInterval) -> Bool {
                animation.isComplete(at: time)
            }

            func currentAlpha(at time: TimeInterval) -> CGFloat {
                let clamped = min(max(progress(at: time), 0), 1)
                return CGFloat(1.0 - clamped)
            }

            func currentFrame(at time: TimeInterval) -> CGRect {
                let clamped = min(max(progress(at: time), 0), 1)
                let offset = CGPoint(
                    x: displacement.x * CGFloat(clamped),
                    y: displacement.y * CGFloat(clamped)
                )
                return fromFrame.offsetBy(dx: offset.x, dy: offset.y)
            }
        }

        var activeRefreshTask: Task<Void, Never>?
        var isInLightSession: Bool = false
        var isImmediateLayoutInProgress: Bool = false
        var isFullEnumerationInProgress: Bool = false
        var displayLinksByDisplay: [CGDirectDisplayID: CADisplayLink] = [:]
        var scrollAnimationByDisplay: [CGDirectDisplayID: WorkspaceDescriptor.ID] = [:]
        var dwindleAnimationByDisplay: [CGDirectDisplayID: (WorkspaceDescriptor.ID, Monitor)] = [:]
        var refreshRateByDisplay: [CGDirectDisplayID: Double] = [:]
        var closingAnimationsByDisplay: [CGDirectDisplayID: [Int: ClosingAnimation]] = [:]
        var screenChangeObserver: NSObjectProtocol?
        var hasCompletedInitialRefresh: Bool = false
    }

    private struct NiriLayoutPass {
        let wsId: WorkspaceDescriptor.ID
        let engine: NiriLayoutEngine
        let monitor: Monitor
        let insetFrame: CGRect
        let gap: CGFloat
    }

    private struct RemovalContext {
        var existingHandleIds: Set<UUID>
        var wasEmptyBeforeSync: Bool
        var columnRemovalResult: NiriLayoutEngine.ColumnRemovalResult?
        var precomputedFallback: NodeId?
        var originalColumnIndex: Int?
    }

    var layoutState = LayoutState()

    var isDiscoveryInProgress: Bool { layoutState.isFullEnumerationInProgress }

    init(controller: WMController) {
        self.controller = controller
        super.init()
    }

    func setup() {
        detectRefreshRates()
        layoutState.screenChangeObserver = NotificationCenter.default.addObserver(
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
        if let existing = layoutState.displayLinksByDisplay[displayId] {
            return existing
        }

        guard let screen = NSScreen.screens.first(where: { $0.displayId == displayId }) else {
            return nil
        }
        let link = screen.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        layoutState.displayLinksByDisplay[displayId] = link
        return link
    }

    private func handleScreenParametersChanged() {
        detectRefreshRates()
    }

    func cleanupForMonitorDisconnect(displayId: CGDirectDisplayID, migrateAnimations: Bool) {
        if let link = layoutState.displayLinksByDisplay.removeValue(forKey: displayId) {
            link.invalidate()
        }

        layoutState.closingAnimationsByDisplay.removeValue(forKey: displayId)

        if migrateAnimations {
            if let wsId = layoutState.scrollAnimationByDisplay.removeValue(forKey: displayId) {
                startScrollAnimation(for: wsId)
            }
        } else {
            layoutState.scrollAnimationByDisplay.removeValue(forKey: displayId)
        }
        layoutState.dwindleAnimationByDisplay.removeValue(forKey: displayId)
    }

    private func detectRefreshRates() {
        layoutState.refreshRateByDisplay.removeAll()
        for screen in NSScreen.screens {
            guard let displayId = screen.displayId else { continue }
            if let mode = CGDisplayCopyDisplayMode(displayId) {
                let rate = mode.refreshRate > 0 ? mode.refreshRate : 60.0
                layoutState.refreshRateByDisplay[displayId] = rate
            } else {
                layoutState.refreshRateByDisplay[displayId] = 60.0
            }
        }
    }

    @objc private func displayLinkFired(_ displayLink: CADisplayLink) {
        guard let displayId = layoutState.displayLinksByDisplay.first(where: { $0.value === displayLink })?.key
        else { return }

        tickScrollAnimation(targetTime: displayLink.targetTimestamp, displayId: displayId)
        tickDwindleAnimation(targetTime: displayLink.targetTimestamp, displayId: displayId)
        tickClosingAnimations(targetTime: displayLink.targetTimestamp, displayId: displayId)
    }

    func startScrollAnimation(for workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        let targetDisplayId: CGDirectDisplayID
        if let monitor = controller.workspaceManager.monitor(for: workspaceId) {
            targetDisplayId = monitor.displayId
        } else if let mainDisplayId = NSScreen.main?.displayId {
            targetDisplayId = mainDisplayId
        } else {
            return
        }

        if layoutState.scrollAnimationByDisplay[targetDisplayId] == workspaceId {
            return
        }

        layoutState.scrollAnimationByDisplay[targetDisplayId] = workspaceId

        if let displayLink = getOrCreateDisplayLink(for: targetDisplayId) {
            displayLink.add(to: .main, forMode: .common)
        }
    }

    func stopScrollAnimation(for displayId: CGDirectDisplayID) {
        layoutState.scrollAnimationByDisplay.removeValue(forKey: displayId)
        stopDisplayLinkIfIdle(for: displayId)
    }

    func stopAllScrollAnimations() {
        let displayIds = Array(layoutState.scrollAnimationByDisplay.keys)
        layoutState.scrollAnimationByDisplay.removeAll()
        for displayId in displayIds {
            stopDisplayLinkIfIdle(for: displayId)
        }
    }

    func startDwindleAnimation(for workspaceId: WorkspaceDescriptor.ID, monitor: Monitor) {
        let targetDisplayId = monitor.displayId

        if layoutState.dwindleAnimationByDisplay[targetDisplayId]?.0 == workspaceId {
            return
        }

        layoutState.dwindleAnimationByDisplay[targetDisplayId] = (workspaceId, monitor)

        if let displayLink = getOrCreateDisplayLink(for: targetDisplayId) {
            displayLink.add(to: .main, forMode: .common)
        }
    }

    func startWindowCloseAnimation(entry: WindowModel.Entry, monitor: Monitor) {
        guard let controller else { return }
        guard controller.settings.animationsEnabled else { return }
        guard let frame = AXWindowService.framePreferFast(entry.axRef) else { return }

        let reduceMotionScale: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.25 : 1.0
        let closeOffset = 12.0 * reduceMotionScale
        let displacement = CGPoint(x: 0, y: -closeOffset)

        let now = CACurrentMediaTime()
        let refreshRate = layoutState.refreshRateByDisplay[monitor.displayId] ?? 60.0
        let animation = SpringAnimation(
            from: 0,
            to: 1,
            startTime: now,
            config: .balanced.with(epsilon: 0.01, velocityEpsilon: 0.1),
            displayRefreshRate: refreshRate
        )

        var animations = layoutState.closingAnimationsByDisplay[monitor.displayId] ?? [:]
        guard animations[entry.windowId] == nil else { return }
        animations[entry.windowId] = LayoutState.ClosingAnimation(
            windowId: entry.windowId,
            axRef: entry.axRef,
            fromFrame: frame,
            displacement: displacement,
            animation: animation
        )
        layoutState.closingAnimationsByDisplay[monitor.displayId] = animations

        if let displayLink = getOrCreateDisplayLink(for: monitor.displayId) {
            displayLink.add(to: .main, forMode: .common)
        }
    }

    func stopDwindleAnimation(for displayId: CGDirectDisplayID) {
        layoutState.dwindleAnimationByDisplay.removeValue(forKey: displayId)
        stopDisplayLinkIfIdle(for: displayId)
    }

    func stopAllDwindleAnimations() {
        let displayIds = Array(layoutState.dwindleAnimationByDisplay.keys)
        layoutState.dwindleAnimationByDisplay.removeAll()
        for displayId in displayIds {
            stopDisplayLinkIfIdle(for: displayId)
        }
    }

    func hasDwindleAnimationRunning(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        layoutState.dwindleAnimationByDisplay.values.contains { $0.0 == workspaceId }
    }

    private func stopDisplayLinkIfIdle(for displayId: CGDirectDisplayID) {
        if layoutState.scrollAnimationByDisplay[displayId] == nil,
           layoutState.dwindleAnimationByDisplay[displayId] == nil,
           layoutState.closingAnimationsByDisplay[displayId].map({ $0.isEmpty }) ?? true
        {
            layoutState.displayLinksByDisplay[displayId]?.remove(from: .main, forMode: .common)
        }
    }

    private func tickDwindleAnimation(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard let (wsId, monitor) = layoutState.dwindleAnimationByDisplay[displayId] else { return }
        guard let controller, let engine = controller.dwindleEngine else {
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

        for (handle, frame) in animatedFrames {
            if let entry = controller.workspaceManager.entry(for: handle) {
                frameUpdates.append((handle.pid, entry.windowId, frame))
            }
        }

        controller.axManager.applyFramesParallel(frameUpdates)

        if !engine.hasActiveAnimations(in: wsId, at: targetTime) {
            if let focusedHandle = controller.focusedHandle,
               let frame = animatedFrames[focusedHandle],
               let entry = controller.workspaceManager.entry(for: focusedHandle) {
                controller.updateBorderIfAllowed(handle: focusedHandle, frame: frame, windowId: entry.windowId)
            }
            stopDwindleAnimation(for: displayId)
        }
    }

    private func tickScrollAnimation(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard let wsId = layoutState.scrollAnimationByDisplay[displayId] else { return }
        guard let controller, let engine = controller.niriEngine else {
            stopScrollAnimation(for: displayId)
            return
        }

        var state = controller.workspaceManager.niriViewportState(for: wsId)

        let viewportAnimationRunning = state.advanceAnimations(at: targetTime)
        let windowAnimationsRunning = engine.tickAllWindowAnimations(in: wsId, at: targetTime)
        let columnAnimationsRunning = engine.tickAllColumnAnimations(in: wsId, at: targetTime)
        let workspaceSwitchRunning = engine.tickWorkspaceSwitchAnimation(for: wsId, at: targetTime)

        guard let monitor = controller.workspaceManager.monitors.first(where: { $0.displayId == displayId }) else {
            controller.workspaceManager.updateNiriViewportState(state, for: wsId)
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

        let animationsOngoing = viewportAnimationRunning
            || windowAnimationsRunning
            || columnAnimationsRunning
            || workspaceSwitchRunning

        controller.workspaceManager.updateNiriViewportState(state, for: wsId)

        if !animationsOngoing {
            finalizeAnimation()
            stopScrollAnimation(for: displayId)
        }
    }

    private func tickClosingAnimations(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard let animations = layoutState.closingAnimationsByDisplay[displayId], !animations.isEmpty else {
            return
        }

        var remaining: [Int: LayoutState.ClosingAnimation] = [:]

        for (windowId, animation) in animations {
            if animation.isComplete(at: targetTime) {
                SkyLight.shared.setWindowAlpha(UInt32(windowId), alpha: 0)
                continue
            }

            let frame = animation.currentFrame(at: targetTime)
            if (try? AXWindowService.setFrame(animation.axRef, frame: frame)) == nil {
                continue
            }
            let alpha = animation.currentAlpha(at: targetTime)
            SkyLight.shared.setWindowAlpha(UInt32(windowId), alpha: Float(alpha))
            remaining[windowId] = animation
        }

        if remaining.isEmpty {
            layoutState.closingAnimationsByDisplay.removeValue(forKey: displayId)
            stopDisplayLinkIfIdle(for: displayId)
        } else {
            layoutState.closingAnimationsByDisplay[displayId] = remaining
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

        let gaps = LayoutGaps(
            horizontal: CGFloat(controller.workspaceManager.gaps),
            vertical: CGFloat(controller.workspaceManager.gaps),
            outer: controller.workspaceManager.outerGaps
        )

        let insetFrame = controller.insetWorkingFrame(for: monitor)
        let area = WorkingAreaContext(
            workingFrame: insetFrame,
            viewFrame: monitor.frame,
            scale: backingScale(for: monitor)
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
                let hiddenOrigin = hiddenOrigin(
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

    func applyLayoutForWorkspaces(_ workspaceIds: Set<WorkspaceDescriptor.ID>) {
        guard let controller else { return }

        for monitor in controller.workspaceManager.monitors {
            guard let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) else { continue }
            let wsId = workspace.id
            guard workspaceIds.contains(wsId) else { continue }

            let layoutType = controller.settings.layoutType(for: workspace.name)

            switch layoutType {
            case .niri, .defaultLayout:
                guard let engine = controller.niriEngine else { continue }
                let state = controller.workspaceManager.niriViewportState(for: wsId)

                applyFramesOnDemand(
                    wsId: wsId,
                    state: state,
                    engine: engine,
                    monitor: monitor,
                    animationTime: nil
                )

            case .dwindle:
                guard let engine = controller.dwindleEngine else { continue }
                let insetFrame = controller.insetWorkingFrame(for: monitor)
                let frames = engine.calculateLayout(for: wsId, screen: insetFrame)

                var frameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []
                for (handle, frame) in frames {
                    if let entry = controller.workspaceManager.entry(for: handle) {
                        frameUpdates.append((handle.pid, entry.windowId, frame))
                    }
                }
                controller.axManager.applyFramesParallel(frameUpdates)
            }
        }

        for ws in controller.workspaceManager.workspaces where workspaceIds.contains(ws.id) {
            guard let monitor = controller.workspaceManager.monitor(for: ws.id) else { continue }
            let isActive = controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == ws.id
            if !isActive {
                hideWorkspace(ws.id, monitor: monitor)
            }
        }
    }

    func cancelActiveAnimations(for workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }

        for (displayId, wsId) in layoutState.scrollAnimationByDisplay where wsId == workspaceId {
            stopScrollAnimation(for: displayId)
        }

        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        state.cancelAnimation()
        controller.workspaceManager.updateNiriViewportState(state, for: workspaceId)
    }

    func refreshWindowsAndLayout() {
        scheduleRefreshSession(.timerRefresh)
    }

    func scheduleRefreshSession(_ event: RefreshSessionEvent) {
        guard !layoutState.isInLightSession else { return }
        if layoutState.isFullEnumerationInProgress {
            return
        }
        layoutState.activeRefreshTask?.cancel()
        layoutState.activeRefreshTask = Task { @MainActor [weak self] in
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

        if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
            return
        }

        var activeWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        for monitor in controller.workspaceManager.monitors {
            if let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
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

        for ws in controller.workspaceManager.workspaces where !activeWorkspaceIds.contains(ws.id) {
            guard let monitor = controller.workspaceManager.monitor(for: ws.id) else { continue }
            hideWorkspace(ws.id, monitor: monitor)
        }

        if let focusedWorkspaceId = controller.activeWorkspace()?.id {
            controller.focusManager.ensureFocusedHandleValid(
                in: focusedWorkspaceId,
                engine: controller.niriEngine,
                workspaceManager: controller.workspaceManager,
                focusWindowAction: { [weak controller] handle in controller?.focusWindow(handle) }
            )
        }
    }

    func runLightSession(_ body: () -> Void) {
        layoutState.activeRefreshTask?.cancel()
        layoutState.activeRefreshTask = nil
        layoutState.isInLightSession = true

        if let controller {
            let focused = controller.focusedHandle
            for monitor in controller.workspaceManager.monitors {
                if let ws = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                    let handles = controller.workspaceManager.entries(in: ws.id).map(\.handle)
                    let layoutType = controller.settings.layoutType(for: ws.name)

                    switch layoutType {
                    case .dwindle:
                        if let dwindleEngine = controller.dwindleEngine {
                            _ = dwindleEngine.syncWindows(handles, in: ws.id, focusedHandle: focused)
                        }
                    case .niri, .defaultLayout:
                        if let niriEngine = controller.niriEngine {
                            let selection = controller.workspaceManager.niriViewportState(for: ws.id).selectedNodeId
                            _ = niriEngine.syncWindows(handles, in: ws.id, selectedNodeId: selection, focusedHandle: focused)
                        }
                    }
                }
            }
        }

        body()
        layoutState.isInLightSession = false
        refreshWindowsAndLayout()
    }

    func executeLayoutRefreshImmediate() {
        Task { @MainActor [weak self] in
            await self?.executeLayoutRefreshImmediateCore()
        }
    }

    private func executeLayoutRefreshImmediateCore() async {
        guard !layoutState.isImmediateLayoutInProgress else { return }
        layoutState.isImmediateLayoutInProgress = true
        defer { layoutState.isImmediateLayoutInProgress = false }

        guard let controller else { return }

        var activeWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        for monitor in controller.workspaceManager.monitors {
            if let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                activeWorkspaceIds.insert(workspace.id)
            }
        }

        let (niriWorkspaces, dwindleWorkspaces) = partitionWorkspacesByLayoutType(activeWorkspaceIds)

        if !niriWorkspaces.isEmpty {
            await layoutWithNiriEngine(activeWorkspaces: niriWorkspaces, useScrollAnimationPath: !layoutState.scrollAnimationByDisplay.isEmpty)
        }
        if !dwindleWorkspaces.isEmpty {
            await layoutWithDwindleEngine(activeWorkspaces: dwindleWorkspaces)
        }
    }

    func resetState() {
        layoutState.activeRefreshTask?.cancel()
        layoutState.activeRefreshTask = nil
        layoutState.isInLightSession = false

        for (_, link) in layoutState.displayLinksByDisplay {
            link.invalidate()
        }
        layoutState.displayLinksByDisplay.removeAll()
        layoutState.scrollAnimationByDisplay.removeAll()
        layoutState.dwindleAnimationByDisplay.removeAll()
        layoutState.closingAnimationsByDisplay.removeAll()

        if let observer = layoutState.screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            layoutState.screenChangeObserver = nil
        }
    }

    private func executeFullRefresh() async throws {
        layoutState.isFullEnumerationInProgress = true
        defer { layoutState.isFullEnumerationInProgress = false }

        guard let controller else { return }

        if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
            return
        }

        let windows = await controller.axManager.currentWindowsAsync()
        try Task.checkCancellation()
        var seenKeys: Set<WindowModel.WindowKey> = []
        let focusedWorkspaceId = controller.activeWorkspace()?.id

        for (ax, pid, winId) in windows {
            if let bundleId = controller.appInfoCache.bundleId(for: pid) {
                if bundleId == LockScreenObserver.lockScreenAppBundleId {
                    continue
                }
                if controller.appRulesByBundleId[bundleId]?.alwaysFloat == true {
                    continue
                }
            }

            let defaultWorkspace = controller.resolveWorkspaceForNewWindow(
                axRef: ax,
                pid: pid,
                fallbackWorkspaceId: focusedWorkspaceId
            )
            let existingAssignment = controller.workspaceAssignment(pid: pid, windowId: winId)
            let wsForWindow = existingAssignment ?? defaultWorkspace

            _ = controller.workspaceManager.addWindow(ax, pid: pid, windowId: winId, to: wsForWindow)
            seenKeys.insert(.init(pid: pid, windowId: winId))
        }
        controller.workspaceManager.removeMissing(keys: seenKeys)
        controller.workspaceManager.garbageCollectUnusedWorkspaces(focusedWorkspaceId: focusedWorkspaceId)

        try Task.checkCancellation()

        var activeWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        for monitor in controller.workspaceManager.monitors {
            if let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
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
        for ws in controller.workspaceManager.workspaces where !activeWorkspaceIds.contains(ws.id) {
            guard let monitor = controller.workspaceManager.monitor(for: ws.id) else { continue }
            hideWorkspace(ws.id, monitor: monitor)
        }
        controller.updateWorkspaceBar()

        if let focusedWorkspaceId {
            controller.focusManager.ensureFocusedHandleValid(
                in: focusedWorkspaceId,
                engine: controller.niriEngine,
                workspaceManager: controller.workspaceManager,
                focusWindowAction: { [weak controller] handle in controller?.focusWindow(handle) }
            )
        }

        layoutState.hasCompletedInitialRefresh = true
        controller.axEventHandler.subscribeToManagedWindows()
    }

    func layoutWithNiriEngine(activeWorkspaces: Set<WorkspaceDescriptor.ID>, useScrollAnimationPath: Bool = false, removedNodeId: NodeId? = nil) async {
        guard let controller, let engine = controller.niriEngine else { return }

        for monitor in controller.workspaceManager.monitors {
            guard let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) else { continue }
            unhideWorkspace(workspace.id, monitor: monitor)
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

            updateWindowConstraints(in: wsId) { engine.updateWindowConstraints(for: $0, constraints: $1) }

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

        state.displayRefreshRate = layoutState.refreshRateByDisplay[pass.monitor.displayId] ?? 60.0

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

        let wasEmpty = existingHandleIds.isEmpty

        var newWindowHandle: WindowHandle?
        if layoutState.hasCompletedInitialRefresh,
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

        if layoutState.hasCompletedInitialRefresh,
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

        let gaps = LayoutGaps(
            horizontal: pass.gap,
            vertical: pass.gap,
            outer: controller.workspaceManager.outerGaps
        )

        let area = WorkingAreaContext(
            workingFrame: pass.insetFrame,
            viewFrame: pass.monitor.frame,
            scale: backingScale(for: pass.monitor)
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
                startScrollAnimation(for: pass.wsId)
            } else if hasColumnAnimations {
                startScrollAnimation(for: pass.wsId)
            }
        }

        if let newHandle = newWindowHandle {
            startScrollAnimation(for: pass.wsId)
            controller.focusWindow(newHandle)
        }

        for entry in controller.workspaceManager.entries(in: pass.wsId) {
            if let side = hiddenHandles[entry.handle] {
                let targetY = frames[entry.handle]?.origin.y
                hideWindow(entry, monitor: pass.monitor, side: side, targetY: targetY)
            } else {
                unhideWindow(entry, monitor: pass.monitor)
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

    private func layoutWithDwindleEngine(activeWorkspaces: Set<WorkspaceDescriptor.ID>) async {
        guard let controller, let engine = controller.dwindleEngine else { return }

        for monitor in controller.workspaceManager.monitors {
            guard let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) else { continue }
            let wsId = workspace.id

            guard activeWorkspaces.contains(wsId) else { continue }

            let wsName = workspace.name
            let layoutType = controller.settings.layoutType(for: wsName)
            guard layoutType == .dwindle else { continue }

            let oldFrames = engine.currentFrames(in: wsId)

            let windowHandles = controller.workspaceManager.entries(in: wsId).map(\.handle)
            let currentFocusedHandle = controller.focusedHandle

            _ = engine.syncWindows(windowHandles, in: wsId, focusedHandle: currentFocusedHandle)

            updateWindowConstraints(in: wsId) { engine.updateWindowConstraints(for: $0, constraints: $1) }

            let insetFrame = controller.insetWorkingFrame(for: monitor)

            let newFrames = engine.calculateLayout(for: wsId, screen: insetFrame)

            for entry in controller.workspaceManager.entries(in: wsId) {
                if newFrames[entry.handle] != nil {
                    unhideWindow(entry, monitor: monitor)
                }
            }

            if let selected = engine.selectedNode(in: wsId),
               case let .leaf(handle, _) = selected.kind,
               let handle {
                controller.focusManager.updateWorkspaceFocusMemory(handle, for: wsId)
                if let currentFocused = controller.focusedHandle {
                    if controller.workspaceManager.workspace(for: currentFocused) == wsId {
                        controller.focusManager.setFocus(handle, in: wsId)
                    }
                } else {
                    controller.focusManager.setFocus(handle, in: wsId)
                }
            }

            if controller.settings.animationsEnabled {
                engine.animateWindowMovements(oldFrames: oldFrames, newFrames: newFrames)
            }

            let now = CACurrentMediaTime()
            if controller.settings.animationsEnabled, engine.hasActiveAnimations(in: wsId, at: now) {
                startDwindleAnimation(for: wsId, monitor: monitor)

                if let focusedHandle = controller.focusedHandle,
                   let frame = newFrames[focusedHandle],
                   let entry = controller.workspaceManager.entry(for: focusedHandle) {
                    controller.borderManager.updateFocusedWindow(frame: frame, windowId: entry.windowId)
                }
            } else {
                var frameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []

                for (handle, frame) in newFrames {
                    if let entry = controller.workspaceManager.entry(for: handle) {
                        frameUpdates.append((handle.pid, entry.windowId, frame))
                    }
                }

                controller.axManager.applyFramesParallel(frameUpdates)

                if let focusedHandle = controller.focusedHandle,
                   let frame = newFrames[focusedHandle],
                   let entry = controller.workspaceManager.entry(for: focusedHandle) {
                    controller.updateBorderIfAllowed(handle: focusedHandle, frame: frame, windowId: entry.windowId)
                }
            }

            await Task.yield()
        }

        controller.updateWorkspaceBar()
    }

    private func updateWindowConstraints(
        in wsId: WorkspaceDescriptor.ID,
        updateEngine: (WindowHandle, WindowSizeConstraints) -> Void
    ) {
        guard let controller else { return }
        for entry in controller.workspaceManager.entries(in: wsId) {
            let currentSize = (AXWindowService.framePreferFast(entry.axRef))?.size
            var constraints: WindowSizeConstraints
            if let cached = controller.workspaceManager.cachedConstraints(for: entry.handle) {
                constraints = cached
            } else {
                constraints = AXWindowService.sizeConstraints(entry.axRef, currentSize: currentSize)
                controller.workspaceManager.setCachedConstraints(constraints, for: entry.handle)
            }

            if let bundleId = controller.appInfoCache.bundleId(for: entry.handle.pid),
               let rule = controller.appRulesByBundleId[bundleId]
            {
                if let minW = rule.minWidth {
                    constraints.minSize.width = max(constraints.minSize.width, minW)
                }
                if let minH = rule.minHeight {
                    constraints.minSize.height = max(constraints.minSize.height, minH)
                }
            }

            updateEngine(entry.handle, constraints)
        }
    }

    private func partitionWorkspacesByLayoutType(
        _ workspaces: Set<WorkspaceDescriptor.ID>
    ) -> (niri: Set<WorkspaceDescriptor.ID>, dwindle: Set<WorkspaceDescriptor.ID>) {
        guard let controller else { return ([], []) }

        var niriWorkspaces: Set<WorkspaceDescriptor.ID> = []
        var dwindleWorkspaces: Set<WorkspaceDescriptor.ID> = []

        for wsId in workspaces {
            guard let ws = controller.workspaceManager.descriptor(for: wsId) else {
                niriWorkspaces.insert(wsId)
                continue
            }
            let layoutType = controller.settings.layoutType(for: ws.name)
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
        for entry in controller.workspaceManager.entries(in: workspaceId) {
            unhideWindow(entry, monitor: monitor)
        }
    }

    private func hideWorkspace(_ workspaceId: WorkspaceDescriptor.ID, monitor: Monitor) {
        guard let controller else { return }
        for entry in controller.workspaceManager.entries(in: workspaceId) {
            hideWindow(entry, monitor: monitor, side: .right, targetY: nil)
        }
    }

    private func hideWindow(_ entry: WindowModel.Entry, monitor: Monitor, side: HideSide, targetY: CGFloat?) {
        guard let controller else { return }
        guard let frame = AXWindowService.framePreferFast(entry.axRef) else { return }
        if !controller.workspaceManager.isHiddenInCorner(entry.handle) {
            let center = frame.center
            let referenceFrame = center.monitorApproximation(in: controller.workspaceManager.monitors)?
                .frame ?? monitor.frame
            let proportional = proportionalPosition(topLeft: frame.topLeftCorner, in: referenceFrame)
            controller.workspaceManager.setHiddenProportionalPosition(proportional, for: entry.handle)
        }
        let yPos = targetY ?? frame.origin.y
        let scale = backingScale(for: monitor)
        let origin = hiddenOrigin(
            for: frame.size,
            edgeFrame: monitor.visibleFrame,
            scale: scale,
            side: side,
            pid: entry.handle.pid,
            targetY: yPos,
            monitor: monitor,
            monitors: controller.workspaceManager.monitors
        )
        try? AXWindowService.setFrame(entry.axRef, frame: CGRect(origin: origin, size: frame.size))
    }

    private func unhideWindow(_ entry: WindowModel.Entry, monitor: Monitor) {
        guard let controller else { return }
        controller.workspaceManager.setHiddenProportionalPosition(nil, for: entry.handle)
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
        edgeFrame: CGRect,
        scale: CGFloat,
        side: HideSide,
        pid: pid_t,
        targetY: CGFloat,
        monitor: Monitor,
        monitors: [Monitor]
    ) -> CGPoint {
        let edgeReveal: CGFloat = isZoomApp(pid) ? 0 : 1.0 / max(1.0, scale)

        func origin(for side: HideSide) -> CGPoint {
            switch side {
            case .left:
                return CGPoint(x: edgeFrame.minX - size.width + edgeReveal, y: targetY)
            case .right:
                return CGPoint(x: edgeFrame.maxX - edgeReveal, y: targetY)
            }
        }

        func overlapArea(for origin: CGPoint) -> CGFloat {
            let rect = CGRect(origin: origin, size: size)
            var area: CGFloat = 0
            for other in monitors where other.id != monitor.id {
                let intersection = rect.intersection(other.frame)
                if intersection.isNull { continue }
                area += intersection.width * intersection.height
            }
            return area
        }

        let primaryOrigin = origin(for: side)
        let primaryOverlap = overlapArea(for: primaryOrigin)
        if primaryOverlap == 0 {
            return primaryOrigin
        }

        let alternateSide: HideSide = side == .left ? .right : .left
        let alternateOrigin = origin(for: alternateSide)
        let alternateOverlap = overlapArea(for: alternateOrigin)
        if alternateOverlap < primaryOverlap {
            return alternateOrigin
        }

        return primaryOrigin
    }

    private func isZoomApp(_ pid: pid_t) -> Bool {
        controller?.appInfoCache.bundleId(for: pid) == "us.zoom.xos"
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
            startScrollAnimation(for: workspaceId)
        }
        updateTabbedColumnOverlays()
    }
}
