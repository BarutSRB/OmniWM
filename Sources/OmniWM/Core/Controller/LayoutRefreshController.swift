import AppKit
import Foundation
import QuartzCore

@MainActor final class LayoutRefreshController: NSObject {
    weak var controller: WMController?
    static let hiddenWindowEdgeRevealEpsilon: CGFloat = 1.0

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
        var isIncrementalRefreshInProgress: Bool = false
        var isFullEnumerationInProgress: Bool = false
        var displayLinksByDisplay: [CGDirectDisplayID: CADisplayLink] = [:]
        var refreshRateByDisplay: [CGDirectDisplayID: Double] = [:]
        var closingAnimationsByDisplay: [CGDirectDisplayID: [Int: ClosingAnimation]] = [:]
        var screenChangeObserver: NSObjectProtocol?
        var hasCompletedInitialRefresh: Bool = false
    }

    var layoutState = LayoutState()

    private(set) lazy var niriHandler = NiriLayoutHandler(controller: controller)
    private(set) lazy var dwindleHandler = DwindleLayoutHandler(controller: controller)

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
            if let wsId = niriHandler.scrollAnimationByDisplay.removeValue(forKey: displayId) {
                startScrollAnimation(for: wsId)
            }
        } else {
            niriHandler.scrollAnimationByDisplay.removeValue(forKey: displayId)
        }
        dwindleHandler.dwindleAnimationByDisplay.removeValue(forKey: displayId)
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

        niriHandler.tickScrollAnimation(targetTime: displayLink.targetTimestamp, displayId: displayId)
        dwindleHandler.tickDwindleAnimation(targetTime: displayLink.targetTimestamp, displayId: displayId)
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

        guard niriHandler.registerScrollAnimation(workspaceId, on: targetDisplayId) else { return }

        if let displayLink = getOrCreateDisplayLink(for: targetDisplayId) {
            displayLink.add(to: .main, forMode: .common)
        }
    }

    func stopScrollAnimation(for displayId: CGDirectDisplayID) {
        niriHandler.scrollAnimationByDisplay.removeValue(forKey: displayId)
        stopDisplayLinkIfIdle(for: displayId)
    }

    func stopAllScrollAnimations() {
        let displayIds = Array(niriHandler.scrollAnimationByDisplay.keys)
        niriHandler.scrollAnimationByDisplay.removeAll()
        for displayId in displayIds {
            stopDisplayLinkIfIdle(for: displayId)
        }
    }

    func startDwindleAnimation(for workspaceId: WorkspaceDescriptor.ID, monitor: Monitor) {
        let targetDisplayId = monitor.displayId

        guard dwindleHandler.registerDwindleAnimation(workspaceId, monitor: monitor, on: targetDisplayId) else { return }

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
        dwindleHandler.dwindleAnimationByDisplay.removeValue(forKey: displayId)
        stopDisplayLinkIfIdle(for: displayId)
    }

    func stopAllDwindleAnimations() {
        let displayIds = Array(dwindleHandler.dwindleAnimationByDisplay.keys)
        dwindleHandler.dwindleAnimationByDisplay.removeAll()
        for displayId in displayIds {
            stopDisplayLinkIfIdle(for: displayId)
        }
    }

    func hasDwindleAnimationRunning(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        dwindleHandler.hasDwindleAnimationRunning(in: workspaceId)
    }

    private func stopDisplayLinkIfIdle(for displayId: CGDirectDisplayID) {
        if niriHandler.scrollAnimationByDisplay[displayId] == nil,
           dwindleHandler.dwindleAnimationByDisplay[displayId] == nil,
           layoutState.closingAnimationsByDisplay[displayId].map({ $0.isEmpty }) ?? true
        {
            layoutState.displayLinksByDisplay[displayId]?.remove(from: .main, forMode: .common)
        }
    }

    private func tickClosingAnimations(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard let animations = layoutState.closingAnimationsByDisplay[displayId], !animations.isEmpty else {
            return
        }

        var remaining: [Int: LayoutState.ClosingAnimation] = [:]

        for (windowId, animation) in animations {
            if animation.isComplete(at: targetTime) {
                continue
            }

            let frame = animation.currentFrame(at: targetTime)
            if (try? AXWindowService.setFrame(animation.axRef, frame: frame)) == nil {
                continue
            }
            remaining[windowId] = animation
        }

        if remaining.isEmpty {
            layoutState.closingAnimationsByDisplay.removeValue(forKey: displayId)
            stopDisplayLinkIfIdle(for: displayId)
        } else {
            layoutState.closingAnimationsByDisplay[displayId] = remaining
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

                niriHandler.applyFramesOnDemand(
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
        niriHandler.cancelActiveAnimations(for: workspaceId)
    }

    func refreshWindowsAndLayout() {
        scheduleRefreshSession(.timerRefresh)
    }

    func scheduleRefreshSession(_ event: RefreshSessionEvent) {
        guard !layoutState.isInLightSession else { return }
        if layoutState.isFullEnumerationInProgress {
            return
        }
        if case .axWindowChanged = event {
            if layoutState.isIncrementalRefreshInProgress || layoutState.isImmediateLayoutInProgress {
                return
            }
            if !niriHandler.scrollAnimationByDisplay.isEmpty
                || !dwindleHandler.dwindleAnimationByDisplay.isEmpty {
                return
            }
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
        guard !layoutState.isIncrementalRefreshInProgress else { return }
        guard !layoutState.isImmediateLayoutInProgress else { return }
        layoutState.isIncrementalRefreshInProgress = true
        defer { layoutState.isIncrementalRefreshInProgress = false }

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
            await niriHandler.layoutWithNiriEngine(activeWorkspaces: niriWorkspaces, useScrollAnimationPath: false)
        }
        if !dwindleWorkspaces.isEmpty {
            await dwindleHandler.layoutWithDwindleEngine(activeWorkspaces: dwindleWorkspaces)
        }

        hideInactiveWorkspaces(activeWorkspaceIds: activeWorkspaceIds)

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

    func executeLayoutRefreshImmediate(postLayout: (@MainActor () -> Void)? = nil) {
        Task { @MainActor [weak self] in
            await self?.executeLayoutRefreshImmediateCore()
            postLayout?()
        }
    }

    func hideInactiveWorkspacesSync() {
        guard let controller else { return }
        var activeWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        for monitor in controller.workspaceManager.monitors {
            if let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                activeWorkspaceIds.insert(workspace.id)
            }
        }
        hideInactiveWorkspaces(activeWorkspaceIds: activeWorkspaceIds)
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
            await niriHandler.layoutWithNiriEngine(activeWorkspaces: niriWorkspaces, useScrollAnimationPath: !niriHandler.scrollAnimationByDisplay.isEmpty)
        }
        if !dwindleWorkspaces.isEmpty {
            await dwindleHandler.layoutWithDwindleEngine(activeWorkspaces: dwindleWorkspaces)
        }

        hideInactiveWorkspaces(activeWorkspaceIds: activeWorkspaceIds)
    }

    func resetState() {
        layoutState.activeRefreshTask?.cancel()
        layoutState.activeRefreshTask = nil
        layoutState.isInLightSession = false

        for (_, link) in layoutState.displayLinksByDisplay {
            link.invalidate()
        }
        layoutState.displayLinksByDisplay.removeAll()
        niriHandler.scrollAnimationByDisplay.removeAll()
        dwindleHandler.dwindleAnimationByDisplay.removeAll()
        layoutState.closingAnimationsByDisplay.removeAll()

        controller?.axManager.clearInactiveWorkspaceWindows()

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
            await niriHandler.layoutWithNiriEngine(activeWorkspaces: niriWorkspaces, useScrollAnimationPath: false)
        }
        if !dwindleWorkspaces.isEmpty {
            await dwindleHandler.layoutWithDwindleEngine(activeWorkspaces: dwindleWorkspaces)
        }
        // Rebuild workspace-level frame suppression (executeFullRefresh has its own hide loop)
        var allEntries: [(workspaceId: WorkspaceDescriptor.ID, windowId: Int)] = []
        for ws in controller.workspaceManager.workspaces {
            for entry in controller.workspaceManager.entries(in: ws.id) {
                allEntries.append((ws.id, entry.windowId))
            }
        }
        controller.axManager.updateInactiveWorkspaceWindows(
            allEntries: allEntries,
            activeWorkspaceIds: activeWorkspaceIds
        )

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
        await niriHandler.layoutWithNiriEngine(activeWorkspaces: activeWorkspaces, useScrollAnimationPath: useScrollAnimationPath, removedNodeId: removedNodeId)
    }

    func updateTabbedColumnOverlays() {
        niriHandler.updateTabbedColumnOverlays()
    }

    func selectTabInNiri(workspaceId: WorkspaceDescriptor.ID, columnId: NodeId, index: Int) {
        niriHandler.selectTabInNiri(workspaceId: workspaceId, columnId: columnId, index: index)
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

    func backingScale(for monitor: Monitor) -> CGFloat {
        NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?.backingScaleFactor ?? 2.0
    }

    func hideInactiveWorkspaces(activeWorkspaceIds: Set<WorkspaceDescriptor.ID>) {
        guard let controller else { return }

        // Rebuild the workspace-level frame suppression set (live check in applyFramesParallel)
        var allEntries: [(workspaceId: WorkspaceDescriptor.ID, windowId: Int)] = []
        for ws in controller.workspaceManager.workspaces {
            for entry in controller.workspaceManager.entries(in: ws.id) {
                allEntries.append((ws.id, entry.windowId))
            }
        }
        controller.axManager.updateInactiveWorkspaceWindows(
            allEntries: allEntries,
            activeWorkspaceIds: activeWorkspaceIds
        )

        // Bulk cancel in-flight frame jobs for all inactive workspace windows upfront,
        // before the per-window hide loop, to prevent AX batch races with SkyLight moves.
        var inactiveWindowJobs: [(pid: pid_t, windowId: Int)] = []
        for ws in controller.workspaceManager.workspaces where !activeWorkspaceIds.contains(ws.id) {
            for entry in controller.workspaceManager.entries(in: ws.id) {
                inactiveWindowJobs.append((entry.handle.pid, entry.windowId))
            }
        }
        if !inactiveWindowJobs.isEmpty {
            controller.axManager.cancelPendingFrameJobs(inactiveWindowJobs)
        }

        for ws in controller.workspaceManager.workspaces where !activeWorkspaceIds.contains(ws.id) {
            guard let monitor = controller.workspaceManager.monitor(for: ws.id) else { continue }
            hideWorkspace(ws.id, monitor: monitor)
        }
    }

    func unhideWorkspace(_ workspaceId: WorkspaceDescriptor.ID, monitor: Monitor) {
        guard let controller else { return }
        let entries = controller.workspaceManager.entries(in: workspaceId)
        for entry in entries {
            controller.axManager.markWindowActive(entry.windowId)
            unhideWindow(entry, monitor: monitor)
        }
    }

    private func hideWorkspace(_ workspaceId: WorkspaceDescriptor.ID, monitor: Monitor) {
        guard let controller else { return }
        for entry in controller.workspaceManager.entries(in: workspaceId) {
            controller.axManager.markWindowInactive(entry.windowId)
            hideWindow(entry, monitor: monitor, side: .right, targetY: nil)
        }
    }

    func hideWindow(_ entry: WindowModel.Entry, monitor: Monitor, side: HideSide, targetY: CGFloat?) {
        guard let controller else { return }
        guard let frame = AXWindowService.framePreferFast(entry.axRef) else { return }
        let frameEntry = (pid: entry.handle.pid, windowId: entry.windowId)
        if !controller.workspaceManager.isHiddenInCorner(entry.handle) {
            let center = frame.center
            let referenceFrame = center.monitorApproximation(in: controller.workspaceManager.monitors)?
                .frame ?? monitor.frame
            let proportional = proportionalPosition(topLeft: frame.topLeftCorner, in: referenceFrame)
            controller.workspaceManager.setHiddenProportionalPosition(proportional, for: entry.handle)
        }
        controller.axManager.suppressFrameWrites([frameEntry])
        controller.axManager.cancelPendingFrameJobs([frameEntry])
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
        let moveEpsilon: CGFloat = 0.01
        if abs(frame.origin.x - origin.x) < moveEpsilon {
            return
        }
        controller.axManager.applyPositionsViaSkyLight([(entry.windowId, origin)], allowInactive: true)

        let verifyEpsilon: CGFloat = 1.0
        var observedOrigin: CGPoint?
        if let wsRect = SkyLight.shared.getWindowBounds(UInt32(entry.windowId)) {
            let appKitRect = ScreenCoordinateSpace.toAppKit(rect: wsRect)
            observedOrigin = appKitRect.origin
        } else if let axFrame = AXWindowService.framePreferFast(entry.axRef) {
            observedOrigin = axFrame.origin
        }

        if let observedOrigin,
           abs(observedOrigin.x - origin.x) > verifyEpsilon
            || abs(observedOrigin.y - origin.y) > verifyEpsilon
        {
            let fallbackFrame = CGRect(origin: origin, size: frame.size)
            try? AXWindowService.setFrame(entry.axRef, frame: fallbackFrame)
        }
    }

    func unhideWindow(_ entry: WindowModel.Entry, monitor: Monitor) {
        guard let controller else { return }
        controller.workspaceManager.setHiddenProportionalPosition(nil, for: entry.handle)
        controller.axManager.unsuppressFrameWrites([(entry.handle.pid, entry.windowId)])
    }

    func proportionalPosition(topLeft: CGPoint, in frame: CGRect) -> CGPoint {
        let width = max(1, frame.width)
        let height = max(1, frame.height)
        let x = (topLeft.x - frame.minX) / width
        let y = (frame.maxY - topLeft.y) / height
        return CGPoint(x: min(max(0, x), 1), y: min(max(0, y), 1))
    }

    func hiddenOrigin(
        for size: CGSize,
        edgeFrame: CGRect,
        scale: CGFloat,
        side: HideSide,
        pid: pid_t,
        targetY: CGFloat,
        monitor: Monitor,
        monitors: [Monitor]
    ) -> CGPoint {
        let edgeReveal = Self.hiddenEdgeReveal(isZoomApp: isZoomApp(pid))
        _ = scale

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

    static func hiddenEdgeReveal(isZoomApp: Bool) -> CGFloat {
        isZoomApp ? 0 : hiddenWindowEdgeRevealEpsilon
    }

    func isZoomApp(_ pid: pid_t) -> Bool {
        controller?.appInfoCache.bundleId(for: pid) == "us.zoom.xos"
    }

    func updateWindowConstraints(
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
}
