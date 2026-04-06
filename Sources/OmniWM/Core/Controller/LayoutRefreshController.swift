import AppKit
import Foundation
import QuartzCore

@MainActor final class LayoutRefreshController: NSObject {
    typealias PostLayoutAction = @MainActor () -> Void

    enum RefreshRoute: Equatable {
        case relayout
        case immediateRelayout
        case visibilityRefresh
        case windowRemoval
    }

    enum ScheduledRefreshKind: Int {
        case relayout
        case immediateRelayout
        case visibilityRefresh
        case windowRemoval
        case fullRescan
    }

    struct WindowRemovalPayload {
        let workspaceId: WorkspaceDescriptor.ID
        let layoutType: LayoutType
        let removedNodeId: NodeId?
        let niriOldFrames: [WindowToken: CGRect]
        let shouldRecoverFocus: Bool
    }

    struct FollowUpRefresh {
        var kind: ScheduledRefreshKind
        var reason: RefreshReason
        var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
    }

    struct ScheduledRefresh {
        var kind: ScheduledRefreshKind
        var reason: RefreshReason
        var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        var postLayoutActions: [PostLayoutAction] = []
        var windowRemovalPayloads: [WindowRemovalPayload] = []
        var followUpRefresh: FollowUpRefresh?
        var needsVisibilityReconciliation: Bool = false
        var visibilityReason: RefreshReason?

        init(
            kind: ScheduledRefreshKind,
            reason: RefreshReason,
            affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = [],
            postLayout: PostLayoutAction? = nil,
            windowRemovalPayload: WindowRemovalPayload? = nil
        ) {
            self.kind = kind
            self.reason = reason
            self.affectedWorkspaceIds = affectedWorkspaceIds
            if let postLayout {
                postLayoutActions = [postLayout]
            }
            if let windowRemovalPayload {
                windowRemovalPayloads = [windowRemovalPayload]
            }
        }
    }

    struct RefreshDebugCounters {
        var fullRescanExecutions: Int = 0
        var relayoutExecutions: Int = 0
        var immediateRelayoutExecutions: Int = 0
        var visibilityExecutions: Int = 0
        var windowRemovalExecutions: Int = 0
        var requestedByReason: [RefreshReason: Int] = [:]
        var executedByReason: [RefreshReason: Int] = [:]
    }

    struct RefreshDebugHooks {
        var onFullRescan: ((RefreshReason) async throws -> Bool)?
        var onRelayout: ((RefreshReason, RefreshRoute) async -> Bool)?
        var onVisibilityRefresh: ((RefreshReason) async -> Bool)?
        var onWindowRemoval: ((RefreshReason, [WindowRemovalPayload]) -> Bool)?
    }

    @MainActor
    private final class RefreshFrameContext {
        private var cache: [WindowToken: CGRect?] = [:]
        private(set) var requests = 0
        private(set) var hits = 0

        func fastFrame(for token: WindowToken, axRef: AXWindowRef) -> CGRect? {
            requests += 1
            if let cached = cache[token] {
                hits += 1
                return cached
            }
            let frame = AXWindowService.framePreferFast(axRef)
            cache[token] = .some(frame)
            return frame
        }
    }

    weak var controller: WMController?
    static let hiddenWindowEdgeRevealEpsilon: CGFloat = 1.0

    enum HideReason {
        case workspaceInactive
        case layoutTransient
        case scratchpad
    }

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
        var activeRefresh: ScheduledRefresh?
        var pendingRefresh: ScheduledRefresh?
        var isImmediateLayoutInProgress: Bool = false
        var isIncrementalRefreshInProgress: Bool = false
        var isFullEnumerationInProgress: Bool = false
        var displayLinksByDisplay: [CGDirectDisplayID: CADisplayLink] = [:]
        var refreshRateByDisplay: [CGDirectDisplayID: Double] = [:]
        var closingAnimationsByDisplay: [CGDirectDisplayID: [Int: ClosingAnimation]] = [:]
        var screenChangeObserver: NSObjectProtocol?
        var hasCompletedInitialRefresh: Bool = false
        var didExecuteRefreshExecutionPlan: Bool = false
    }

    var layoutState = LayoutState()
    var debugCounters = RefreshDebugCounters()
    var debugHooks = RefreshDebugHooks()
    private var activeFrameContext: RefreshFrameContext?

    func fastFrame(for token: WindowToken, axRef: AXWindowRef) -> CGRect? {
        activeFrameContext?.fastFrame(for: token, axRef: axRef)
            ?? AXWindowService.framePreferFast(axRef)
    }

    private(set) lazy var niriHandler = NiriLayoutHandler(controller: controller)
    private(set) lazy var dwindleHandler = DwindleLayoutHandler(controller: controller)
    private lazy var diffExecutor = LayoutDiffExecutor(refreshController: self)

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
        guard controller?.motionPolicy.animationsEnabled != false else { return }
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
        guard controller?.motionPolicy.animationsEnabled != false else { return }
        let targetDisplayId = monitor.displayId

        guard dwindleHandler.registerDwindleAnimation(workspaceId, monitor: monitor, on: targetDisplayId) else { return }

        if let displayLink = getOrCreateDisplayLink(for: targetDisplayId) {
            displayLink.add(to: .main, forMode: .common)
        }
    }

    func startWindowCloseAnimation(entry: WindowModel.Entry, monitor: Monitor) {
        guard controller?.motionPolicy.animationsEnabled != false else { return }
        guard controller != nil else { return }
        guard let frame = fastFrame(for: entry.token, axRef: entry.axRef) else { return }

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
            // Idle display links must not remain cached after teardown.
            if let link = layoutState.displayLinksByDisplay.removeValue(forKey: displayId) {
                link.invalidate()
            }
        }
    }

    private func tickClosingAnimations(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard let animations = layoutState.closingAnimationsByDisplay[displayId], !animations.isEmpty else {
            return
        }

        var remaining: [Int: LayoutState.ClosingAnimation] = [:]

        for (windowId, animation) in animations {
            if animation.isComplete(at: targetTime) {
                _ = AXWindowService.setFrame(
                    animation.axRef,
                    frame: animation.currentFrame(at: targetTime)
                )
                continue
            }

            let frame = animation.currentFrame(at: targetTime)
            if !AXWindowService.setFrame(animation.axRef, frame: frame).isVerifiedSuccess {
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
                dwindleHandler.applyFramesOnDemand(workspaceId: wsId, monitor: monitor)
            }
        }

        let preferredSides = preferredHideSides(for: controller.workspaceManager.monitors)
        for ws in controller.workspaceManager.workspaces where workspaceIds.contains(ws.id) {
            guard let monitor = controller.workspaceManager.monitor(for: ws.id) else { continue }
            let isActive = controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == ws.id
            if !isActive {
                let preferredSide = preferredSides[monitor.id] ?? .right
                hideWorkspace(
                    controller.workspaceManager.entries(in: ws.id),
                    monitor: monitor,
                    preferredSide: preferredSide
                )
            }
        }
    }

    func executeLayoutPlans(_ plans: [WorkspaceLayoutPlan]) {
        for plan in plans {
            executeLayoutPlan(plan)
        }
    }

    func executeLayoutPlan(_ plan: WorkspaceLayoutPlan) {
        applySessionPatch(plan.sessionPatch)
        diffExecutor.execute(plan)
        applyAnimationDirectives(
            plan.animationDirectives,
            focusedFrame: plan.diff.focusedFrame
        )
    }

    private func executeRefreshExecutionPlan(_ plan: RefreshExecutionPlan) async {
        guard let controller else { return }

        layoutState.didExecuteRefreshExecutionPlan = true
        activeFrameContext = RefreshFrameContext()
        defer { activeFrameContext = nil }

        // Rebuild the inactive-workspace window set BEFORE executing layout plans
        // so that applyFramesParallel (inside executeLayoutPlans) uses the correct
        // active/inactive classification. Without this, windows on a newly-active
        // workspace are still marked inactive from the previous cycle, causing their
        // frame writes to be silently skipped and leaving blank gaps on screen.
        if let visibility = plan.effects.visibility {
            rebuildInactiveWorkspaceWindowSet(activeWorkspaceIds: visibility.activeWorkspaceIds)
        }

        executeLayoutPlans(plan.workspacePlans)

        if let visibility = plan.effects.visibility {
            hideInactiveWorkspaces(activeWorkspaceIds: visibility.activeWorkspaceIds)
        }

        if plan.effects.updateTabbedOverlays {
            niriHandler.updateTabbedColumnOverlays()
        }

        if plan.effects.refreshFocusedBorderForVisibilityState {
            refreshFocusedBorderForVisibilityState(on: controller)
        }

        for workspaceId in plan.effects.focusValidationWorkspaceIds {
            controller.ensureFocusedTokenValid(in: workspaceId)
        }

        for postLayoutAction in plan.postLayoutActions {
            postLayoutAction()
        }

        if plan.effects.requestWorkspaceBarRefresh {
            controller.requestWorkspaceBarRefresh()
        }

        if plan.effects.markInitialRefreshComplete {
            layoutState.hasCompletedInitialRefresh = true
        }

        if plan.effects.drainDeferredCreatedWindows {
            await controller.axEventHandler.drainDeferredCreatedWindows()
        }

        if plan.effects.subscribeManagedWindows {
            controller.axEventHandler.subscribeToManagedWindows()
        }
    }

    func buildWindowSnapshots(
        for entries: [WindowModel.Entry],
        resolveConstraints: Bool = true
    ) -> [LayoutWindowSnapshot] {
        guard let controller else { return [] }

        var snapshots: [LayoutWindowSnapshot] = []
        snapshots.reserveCapacity(entries.count)

        for entry in entries {
            let constraints: WindowSizeConstraints
            if !resolveConstraints {
                constraints = controller.workspaceManager.cachedConstraints(for: entry.token) ?? .unconstrained
            } else {
                let currentSize = fastFrame(for: entry.token, axRef: entry.axRef)?.size
                if let cached = controller.workspaceManager.cachedConstraints(for: entry.token) {
                    constraints = cached
                } else {
                    let resolved = AXWindowService.sizeConstraints(entry.axRef, currentSize: currentSize)
                    controller.workspaceManager.setCachedConstraints(resolved, for: entry.token)
                    constraints = resolved
                }
            }

            var mergedConstraints = constraints
            if resolveConstraints {
                if let minW = entry.ruleEffects.minWidth {
                    mergedConstraints.minSize.width = max(mergedConstraints.minSize.width, minW)
                }
                if let minH = entry.ruleEffects.minHeight {
                    mergedConstraints.minSize.height = max(mergedConstraints.minSize.height, minH)
                }
                mergedConstraints = mergedConstraints.normalized()
            }

            snapshots.append(
                LayoutWindowSnapshot(
                    token: entry.token,
                    constraints: mergedConstraints,
                    hiddenState: controller.workspaceManager.hiddenState(for: entry.token),
                    layoutReason: controller.workspaceManager.layoutReason(for: entry.token)
                )
            )
        }

        return snapshots
    }

    func buildMonitorSnapshot(
        for monitor: Monitor,
        orientation: Monitor.Orientation? = nil
    ) -> LayoutMonitorSnapshot {
        LayoutMonitorSnapshot(
            monitorId: monitor.id,
            displayId: monitor.displayId,
            frame: monitor.frame,
            visibleFrame: monitor.visibleFrame,
            workingFrame: controller?.insetWorkingFrame(for: monitor) ?? monitor.visibleFrame,
            scale: backingScale(for: monitor),
            orientation: orientation ?? monitor.autoOrientation
        )
    }

    func buildRefreshInput(
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        resolveConstraints: Bool,
        orientation: Monitor.Orientation? = nil,
        isActiveWorkspace: Bool
    ) -> WorkspaceRefreshInput? {
        guard let controller else { return nil }

        let entries = controller.workspaceManager.tiledEntries(in: workspaceId)
        let windows = buildWindowSnapshots(for: entries, resolveConstraints: resolveConstraints)
        let monitorSnapshot = buildMonitorSnapshot(for: monitor, orientation: orientation)

        return WorkspaceRefreshInput(
            workspaceId: workspaceId,
            monitor: monitorSnapshot,
            windows: windows,
            isActiveWorkspace: isActiveWorkspace
        )
    }

    private func applySessionPatch(_ patch: WorkspaceSessionPatch) {
        controller?.workspaceManager.applySessionPatch(patch)
    }

    private func applyAnimationDirectives(
        _ directives: [AnimationDirective],
        focusedFrame: LayoutFocusedFrame?
    ) {
        guard let controller else { return }

        for directive in directives {
            switch directive {
            case .none:
                continue
            case let .startNiriScroll(workspaceId):
                startScrollAnimation(for: workspaceId)
            case let .startDwindleAnimation(workspaceId, monitorId):
                guard let monitor = controller.workspaceManager.monitor(byId: monitorId) else { continue }
                startDwindleAnimation(for: workspaceId, monitor: monitor)
            case let .activateWindow(token):
                guard !controller.shouldSuppressManagedFocusRecovery,
                      !controller.workspaceManager.hasPendingNativeFullscreenTransition
                else { continue }
                if let workspaceId = controller.workspaceManager.workspace(for: token) {
                    controller.recordNiriCreateFocusTrace(
                        .relayoutActivatedWindow(
                            token: token,
                            workspaceId: workspaceId
                        )
                    )
                }
                controller.focusWindow(token)
            case .updateTabbedOverlays:
                niriHandler.updateTabbedColumnOverlays()
            }
        }
    }

    func cancelActiveAnimations(for workspaceId: WorkspaceDescriptor.ID) {
        niriHandler.cancelActiveAnimations(for: workspaceId)
    }

    func resetDebugState() {
        debugCounters = RefreshDebugCounters()
        debugHooks = RefreshDebugHooks()
    }

    func refreshDebugSnapshot() -> RefreshDebugCounters {
        debugCounters
    }

    func requestFullRescan(reason: RefreshReason) {
        assert(reason.requestRoute == .fullRescan, "Invalid full-rescan reason: \(reason)")
        scheduleFullRescan(reason: reason)
    }

    func requestRelayout(
        reason: RefreshReason,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
    ) {
        assert(reason.requestRoute == .relayout, "Invalid relayout reason: \(reason)")
        scheduleRefreshSession(
            reason.relayoutSchedulingPolicy,
            reason: reason,
            affectedWorkspaceIds: affectedWorkspaceIds
        )
    }

    func requestImmediateRelayout(
        reason: RefreshReason,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = [],
        postLayout: PostLayoutAction? = nil
    ) {
        assert(reason.requestRoute == .immediateRelayout, "Invalid immediate-relayout reason: \(reason)")
        enqueueRefresh(
            .init(
                kind: .immediateRelayout,
                reason: reason,
                affectedWorkspaceIds: affectedWorkspaceIds,
                postLayout: postLayout
            )
        )
    }

    func requestVisibilityRefresh(
        reason: RefreshReason,
        postLayout: PostLayoutAction? = nil
    ) {
        assert(reason.requestRoute == .visibilityRefresh, "Invalid visibility-refresh reason: \(reason)")
        enqueueRefresh(.init(kind: .visibilityRefresh, reason: reason, postLayout: postLayout))
    }

    func requestWindowRemoval(
        workspaceId: WorkspaceDescriptor.ID,
        layoutType: LayoutType,
        removedNodeId: NodeId?,
        niriOldFrames: [WindowToken: CGRect],
        shouldRecoverFocus: Bool,
        postLayout: PostLayoutAction? = nil
    ) {
        assert(RefreshReason.windowDestroyed.requestRoute == .windowRemoval, "Invalid window-removal reason")
        enqueueRefresh(
            .init(
                kind: .windowRemoval,
                reason: .windowDestroyed,
                postLayout: postLayout,
                windowRemovalPayload: .init(
                    workspaceId: workspaceId,
                    layoutType: layoutType,
                    removedNodeId: removedNodeId,
                    niriOldFrames: niriOldFrames,
                    shouldRecoverFocus: shouldRecoverFocus
                )
            )
        )
    }

    func commitWorkspaceTransition(
        affectedWorkspaces: Set<WorkspaceDescriptor.ID> = [],
        reason: RefreshReason = .workspaceTransition,
        postLayout: PostLayoutAction? = nil
    ) {
        requestImmediateRelayout(
            reason: reason,
            affectedWorkspaceIds: affectedWorkspaces,
            postLayout: postLayout
        )
    }

    private func scheduleFullRescan(reason: RefreshReason) {
        enqueueRefresh(.init(kind: .fullRescan, reason: reason))
    }

    private func scheduleRefreshSession(
        _ policy: RelayoutSchedulingPolicy,
        reason: RefreshReason,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
    ) {
        if policy.shouldDropWhileBusy {
            if layoutState.isIncrementalRefreshInProgress || layoutState.isImmediateLayoutInProgress {
                return
            }
            if !niriHandler.scrollAnimationByDisplay.isEmpty
                || !dwindleHandler.dwindleAnimationByDisplay.isEmpty {
                return
            }
        }
        enqueueRefresh(
            .init(kind: .relayout, reason: reason, affectedWorkspaceIds: affectedWorkspaceIds)
        )
    }

    private func executeScheduledRelayout(refresh: ScheduledRefresh) async -> Bool {
        guard !layoutState.isIncrementalRefreshInProgress else { return false }
        guard !layoutState.isImmediateLayoutInProgress else { return false }
        layoutState.isIncrementalRefreshInProgress = true
        defer { layoutState.isIncrementalRefreshInProgress = false }
        return await executeRelayout(
            refresh: refresh,
            route: .relayout,
            useScrollAnimationPath: false,
            recoverFocus: true
        )
    }

    private func executeRelayout(
        refresh: ScheduledRefresh,
        route: RefreshRoute,
        useScrollAnimationPath: Bool,
        recoverFocus: Bool
    ) async -> Bool {
        let reason = refresh.reason
        recordRefreshExecution(route, reason: reason)
        if await debugHooks.onRelayout?(reason, route) == true {
            return true
        }

        guard let controller else { return false }

        if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
            return false
        }

        do {
            var plan = try await buildRelayoutExecutionPlan(
                useScrollAnimationPath: useScrollAnimationPath,
                recoverFocus: recoverFocus,
                affectedWorkspaceIds: refresh.affectedWorkspaceIds
            )
            applyRefreshMetadata(refresh, to: &plan)
            try Task.checkCancellation()
            await executeRefreshExecutionPlan(plan)
        } catch {
            return false
        }

        return true
    }

    private func executeVisibilityRefresh(refresh: ScheduledRefresh) async -> Bool {
        let reason = refresh.reason
        recordRefreshExecution(.visibilityRefresh, reason: reason)
        if await debugHooks.onVisibilityRefresh?(reason) == true {
            return true
        }

        guard let controller else { return false }

        if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
            return false
        }

        var plan = buildVisibilityExecutionPlan()
        applyRefreshMetadata(refresh, to: &plan)
        guard !Task.isCancelled else { return false }
        await executeRefreshExecutionPlan(plan)

        return true
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

    private func executeImmediateRelayout(refresh: ScheduledRefresh) async -> Bool {
        guard !layoutState.isImmediateLayoutInProgress else { return false }
        layoutState.isImmediateLayoutInProgress = true
        defer { layoutState.isImmediateLayoutInProgress = false }
        return await executeRelayout(
            refresh: refresh,
            route: .immediateRelayout,
            useScrollAnimationPath: !niriHandler.scrollAnimationByDisplay.isEmpty,
            recoverFocus: false
        )
    }

    private func executeWindowRemoval(refresh: ScheduledRefresh) async -> Bool {
        let reason = refresh.reason
        let payloads = refresh.windowRemovalPayloads
        recordRefreshExecution(.windowRemoval, reason: reason)
        if debugHooks.onWindowRemoval?(reason, payloads) == true {
            return true
        }

        guard let controller else { return false }
        if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
            return false
        }

        do {
            var plan = try await buildWindowRemovalExecutionPlan(payloads: payloads)
            applyRefreshMetadata(refresh, to: &plan)
            try Task.checkCancellation()
            await executeRefreshExecutionPlan(plan)
        } catch {
            return false
        }

        return true
    }

    private func refreshFocusedBorderForVisibilityState(on controller: WMController) {
        _ = controller.renderKeyboardFocusBorder(policy: .coordinated)
    }

    func waitForRefreshWorkForTests() async {
        while let task = layoutState.activeRefreshTask {
            await task.value
        }
    }

    private func settleAllAnimations() {
        let settleTime = CACurrentMediaTime() + 10.0

        for displayId in Array(niriHandler.scrollAnimationByDisplay.keys) {
            niriHandler.tickScrollAnimation(targetTime: settleTime, displayId: displayId)
        }

        for displayId in Array(dwindleHandler.dwindleAnimationByDisplay.keys) {
            dwindleHandler.tickDwindleAnimation(targetTime: settleTime, displayId: displayId)
        }

        for displayId in Array(layoutState.closingAnimationsByDisplay.keys) {
            tickClosingAnimations(targetTime: settleTime, displayId: displayId)
        }
    }

    func settleAllAnimationsForTests() {
        settleAllAnimations()
    }

    func waitForSettledRefreshWorkForTests() async {
        await waitForRefreshWorkForTests()
        settleAllAnimationsForTests()
    }

    func resetState() {
        layoutState.activeRefreshTask?.cancel()
        layoutState.activeRefreshTask = nil
        layoutState.activeRefresh = nil
        layoutState.pendingRefresh = nil
        layoutState.didExecuteRefreshExecutionPlan = false

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

    private func executeFullRefresh(refresh: ScheduledRefresh) async throws -> Bool {
        let reason = refresh.reason
        debugCounters.fullRescanExecutions += 1
        debugCounters.executedByReason[reason, default: 0] += 1
        if try await debugHooks.onFullRescan?(reason) == true {
            return true
        }
        layoutState.isFullEnumerationInProgress = true
        defer { layoutState.isFullEnumerationInProgress = false }

        guard let controller else { return false }
        controller.axEventHandler.resetManagedReplacementState()

        if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
            return false
        }

        var plan = try await buildFullRefreshExecutionPlan()
        applyRefreshMetadata(refresh, to: &plan)
        try Task.checkCancellation()
        await executeRefreshExecutionPlan(plan)
        return true
    }

    func updateTabbedColumnOverlays() {
        niriHandler.updateTabbedColumnOverlays()
    }

    func selectTabInNiri(workspaceId: WorkspaceDescriptor.ID, columnId: NodeId, visualIndex: Int) {
        niriHandler.selectTabInNiri(workspaceId: workspaceId, columnId: columnId, visualIndex: visualIndex)
    }

    private func applyRefreshMetadata(_ refresh: ScheduledRefresh, to plan: inout RefreshExecutionPlan) {
        if !refresh.postLayoutActions.isEmpty {
            plan.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
        }

        if refresh.kind != .visibilityRefresh, refresh.needsVisibilityReconciliation {
            plan.effects.requestWorkspaceBarRefresh = true
            plan.effects.updateTabbedOverlays = true
            plan.effects.refreshFocusedBorderForVisibilityState = true
        }
    }

    private func buildVisibilityExecutionPlan() -> RefreshExecutionPlan {
        var effects = RefreshExecutionEffects()
        effects.requestWorkspaceBarRefresh = true
        effects.updateTabbedOverlays = true
        effects.refreshFocusedBorderForVisibilityState = true
        return RefreshExecutionPlan(effects: effects)
    }

    private func buildRelayoutExecutionPlan(
        useScrollAnimationPath: Bool,
        recoverFocus: Bool,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
    ) async throws -> RefreshExecutionPlan {
        guard let controller else { return .init() }

        let activeWorkspaceIds = currentActiveWorkspaceIds()
        let layoutWorkspaceIds = affectedWorkspaceIds.isEmpty ? activeWorkspaceIds : affectedWorkspaceIds
        let (niriWorkspaces, dwindleWorkspaces) = partitionWorkspacesByLayoutType(layoutWorkspaceIds)
        var workspacePlans: [WorkspaceLayoutPlan] = []
        workspacePlans.reserveCapacity(niriWorkspaces.count + dwindleWorkspaces.count)

        var updateTabbedOverlays = false

        if !niriWorkspaces.isEmpty {
            try Task.checkCancellation()
            let plans = try await niriHandler.layoutWithNiriEngine(
                activeWorkspaces: niriWorkspaces,
                useScrollAnimationPath: useScrollAnimationPath
            )
            try Task.checkCancellation()
            workspacePlans.append(contentsOf: plans)
            updateTabbedOverlays = !plans.isEmpty
        }

        if !dwindleWorkspaces.isEmpty {
            try Task.checkCancellation()
            let plans = try await dwindleHandler.layoutWithDwindleEngine(activeWorkspaces: dwindleWorkspaces)
            try Task.checkCancellation()
            workspacePlans.append(contentsOf: plans)
        }

        var effects = RefreshExecutionEffects()
        effects.visibility = .init(activeWorkspaceIds: activeWorkspaceIds)
        effects.requestWorkspaceBarRefresh = true
        effects.updateTabbedOverlays = updateTabbedOverlays
        if recoverFocus,
           !controller.workspaceManager.isAppFullscreenActive,
           !controller.workspaceManager.hasPendingNativeFullscreenTransition,
           !controller.shouldSuppressManagedFocusRecovery,
           let focusedWorkspaceId = controller.activeWorkspace()?.id
        {
            effects.focusValidationWorkspaceIds = [focusedWorkspaceId]
        }

        return RefreshExecutionPlan(workspacePlans: workspacePlans, effects: effects)
    }

    private func buildWindowRemovalExecutionPlan(
        payloads: [WindowRemovalPayload]
    ) async throws -> RefreshExecutionPlan {
        guard let controller else { return .init() }

        var dwindleWorkspaces: Set<WorkspaceDescriptor.ID> = []
        var focusedWorkspacesToRecover: Set<WorkspaceDescriptor.ID> = []
        var niriRemovalSeeds: [WorkspaceDescriptor.ID: NiriWindowRemovalSeed] = [:]

        for payload in payloads {
            switch payload.layoutType {
            case .dwindle:
                dwindleWorkspaces.insert(payload.workspaceId)
            case .niri, .defaultLayout:
                var removedNodeIds = niriRemovalSeeds[payload.workspaceId]?.removedNodeIds ?? []
                if let removedNodeId = payload.removedNodeId {
                    removedNodeIds.append(removedNodeId)
                }
                let existingOldFrames = niriRemovalSeeds[payload.workspaceId]?.oldFrames ?? [:]
                niriRemovalSeeds[payload.workspaceId] = NiriWindowRemovalSeed(
                    removedNodeIds: removedNodeIds,
                    oldFrames: existingOldFrames.merging(payload.niriOldFrames) { current, _ in current }
                )
            }

            if payload.shouldRecoverFocus {
                focusedWorkspacesToRecover.insert(payload.workspaceId)
            }
        }

        var workspacePlans: [WorkspaceLayoutPlan] = []
        workspacePlans.reserveCapacity(dwindleWorkspaces.count + niriRemovalSeeds.count)
        var updateTabbedOverlays = false

        if !niriRemovalSeeds.isEmpty {
            try Task.checkCancellation()
            let plans = try await niriHandler.layoutWithNiriEngine(
                activeWorkspaces: Set(niriRemovalSeeds.keys),
                useScrollAnimationPath: true,
                removalSeeds: niriRemovalSeeds
            )
            try Task.checkCancellation()
            workspacePlans.append(contentsOf: plans)
            updateTabbedOverlays = !plans.isEmpty
        }

        if !dwindleWorkspaces.isEmpty {
            try Task.checkCancellation()
            let plans = try await dwindleHandler.layoutWithDwindleEngine(activeWorkspaces: dwindleWorkspaces)
            try Task.checkCancellation()
            workspacePlans.append(contentsOf: plans)
        }

        let activeWorkspaceIds = currentActiveWorkspaceIds()
        let focusValidationWorkspaceIds: [WorkspaceDescriptor.ID]
        if controller.workspaceManager.isAppFullscreenActive
            || controller.workspaceManager.hasPendingNativeFullscreenTransition
            || controller.shouldSuppressManagedFocusRecovery
        {
            focusValidationWorkspaceIds = []
        } else {
            focusValidationWorkspaceIds = focusedWorkspacesToRecover
                .intersection(activeWorkspaceIds)
                .sorted { $0.uuidString < $1.uuidString }
        }

        var effects = RefreshExecutionEffects()
        effects.visibility = .init(activeWorkspaceIds: activeWorkspaceIds)
        effects.requestWorkspaceBarRefresh = true
        effects.updateTabbedOverlays = updateTabbedOverlays
        effects.focusValidationWorkspaceIds = focusValidationWorkspaceIds

        return RefreshExecutionPlan(workspacePlans: workspacePlans, effects: effects)
    }

    private func buildFullRefreshExecutionPlan() async throws -> RefreshExecutionPlan {
        guard let controller else { return .init() }

        let enumerationSnapshot = await controller.axManager.fullRescanEnumerationSnapshot()
        let windows = enumerationSnapshot.windows
        try Task.checkCancellation()
        var seenKeys: Set<WindowModel.WindowKey> = []
        var decisionBasedRemovals: [WindowToken] = []
        let focusedWorkspaceId = controller.activeWorkspace()?.id

        for (ax, pid, winId) in windows {
            let bundleId = controller.appInfoCache.bundleId(for: pid)
                ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            if let bundleId {
                if bundleId == LockScreenObserver.lockScreenAppBundleId {
                    continue
                }
            }

            let token = WindowToken(pid: pid, windowId: winId)
            let appFullscreen = controller.axEventHandler.isFullscreenProvider?(ax) ?? AXWindowService.isFullscreen(ax)
            let evaluation = controller.evaluateWindowDisposition(
                axRef: ax,
                pid: pid,
                appFullscreen: appFullscreen
            )
            let decision = evaluation.decision
            let existingEntry = controller.workspaceManager.entry(for: token)
            let temporarilyUnavailableRecord: WorkspaceManager.NativeFullscreenRecord? = if let existingEntry,
                let record = controller.workspaceManager.nativeFullscreenRecord(for: existingEntry.token),
                record.availability == .temporarilyUnavailable
            {
                record
            } else {
                nil
            }
            if let temporarilyUnavailableRecord {
                controller.axEventHandler.cancelNativeFullscreenLifecycleTasks(
                    containing: temporarilyUnavailableRecord.currentToken
                )
            }
            let shouldPreservePreFullscreenState = existingEntry.map { existingEntry in
                !appFullscreen
                    && (
                        controller.workspaceManager.nativeFullscreenRecord(for: existingEntry.token) != nil
                            || existingEntry.layoutReason == .nativeFullscreen
                    )
            } ?? false
            let effectiveTrackedMode = shouldPreservePreFullscreenState
                ? existingEntry?.mode
                : controller.trackedModeForLifecycle(
                    decision: decision,
                    existingEntry: existingEntry
                )

            guard let trackedMode = effectiveTrackedMode else {
                if existingEntry != nil {
                    decisionBasedRemovals.append(token)
                }
                continue
            }

            let defaultWorkspace = controller.resolvedWorkspaceId(
                for: evaluation,
                axRef: ax,
                pid: pid,
                existingEntry: existingEntry,
                fallbackWorkspaceId: focusedWorkspaceId
            )
            if controller.workspaceAssignment(pid: pid, windowId: winId) == nil,
               controller.axEventHandler.restoreNativeFullscreenReplacementIfNeeded(
                    token: token,
                    windowId: UInt32(winId),
                    axRef: ax,
                    workspaceId: defaultWorkspace,
                    appFullscreen: appFullscreen
                )
            {
                seenKeys.insert(token)
                continue
            }

            let wsForWindow: WorkspaceDescriptor.ID
            let ruleEffects: ManagedWindowRuleEffects
            if let existingEntry {
                if shouldPreservePreFullscreenState {
                    _ = controller.workspaceManager.restoreNativeFullscreenRecord(for: existingEntry.token)
                    wsForWindow = existingEntry.workspaceId
                    ruleEffects = existingEntry.ruleEffects
                } else if appFullscreen {
                    _ = controller.workspaceManager.markNativeFullscreenSuspended(existingEntry.token)
                    let existingAssignment = controller.workspaceAssignment(pid: pid, windowId: winId)
                    wsForWindow = existingAssignment ?? defaultWorkspace
                    ruleEffects = decision.ruleEffects
                } else {
                    let existingAssignment = controller.workspaceAssignment(pid: pid, windowId: winId)
                    wsForWindow = existingAssignment ?? defaultWorkspace
                    ruleEffects = decision.ruleEffects
                }
            } else {
                let existingAssignment = controller.workspaceAssignment(pid: pid, windowId: winId)
                wsForWindow = existingAssignment ?? defaultWorkspace
                ruleEffects = decision.ruleEffects
            }
            let oldMode = existingEntry?.mode

            _ = controller.workspaceManager.addWindow(
                ax,
                pid: pid,
                windowId: winId,
                to: wsForWindow,
                mode: oldMode ?? trackedMode,
                ruleEffects: ruleEffects
            )

            if shouldPreservePreFullscreenState {
                seenKeys.insert(token)
                continue
            }

            if let oldMode, oldMode != trackedMode {
                _ = controller.transitionWindowMode(
                    for: token,
                    to: trackedMode,
                    preferredMonitor: controller.workspaceManager.monitor(for: wsForWindow),
                    applyFloatingFrame: false
                )
            } else if trackedMode == .floating {
                controller.seedFloatingGeometryIfNeeded(
                    for: token,
                    preferredMonitor: controller.workspaceManager.monitor(for: wsForWindow)
                )
            }
            seenKeys.insert(token)
        }

        for token in decisionBasedRemovals {
            _ = controller.workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
        }

        let shouldPreserveMissingWindows = shouldPreserveMissingWindowsDuringNativeFullscreen(
            controller: controller
        )
        if shouldPreserveMissingWindows {
            // Native macOS fullscreen moves the app onto its own Space, so visible-window
            // enumeration temporarily excludes the rest of the managed workspace.
            for entry in controller.workspaceManager.allEntries() {
                seenKeys.insert(.init(pid: entry.handle.pid, windowId: entry.windowId))
            }
        } else {
            for entry in controller.workspaceManager.allEntries()
            where controller.hiddenAppPIDs.contains(entry.handle.pid)
                || controller.workspaceManager.layoutReason(for: entry.token) == .macosHiddenApp
                || controller.workspaceManager.layoutReason(for: entry.token) == .nativeFullscreen
            {
                seenKeys.insert(.init(pid: entry.handle.pid, windowId: entry.windowId))
            }

            for entry in controller.workspaceManager.allEntries()
            where enumerationSnapshot.failedPIDs.contains(entry.handle.pid)
            {
                seenKeys.insert(.init(pid: entry.handle.pid, windowId: entry.windowId))
            }
        }

        controller.workspaceManager.removeMissing(keys: seenKeys, requiredConsecutiveMisses: 1)
        controller.workspaceManager.garbageCollectUnusedWorkspaces(focusedWorkspaceId: focusedWorkspaceId)

        try Task.checkCancellation()

        let activeWorkspaceIds = currentActiveWorkspaceIds()
        let (niriWorkspaces, dwindleWorkspaces) = partitionWorkspacesByLayoutType(activeWorkspaceIds)
        var workspacePlans: [WorkspaceLayoutPlan] = []
        workspacePlans.reserveCapacity(niriWorkspaces.count + dwindleWorkspaces.count)

        var updateTabbedOverlays = false

        if !niriWorkspaces.isEmpty {
            try Task.checkCancellation()
            let plans = try await niriHandler.layoutWithNiriEngine(
                activeWorkspaces: niriWorkspaces,
                useScrollAnimationPath: false
            )
            try Task.checkCancellation()
            workspacePlans.append(contentsOf: plans)
            updateTabbedOverlays = !plans.isEmpty
        }

        if !dwindleWorkspaces.isEmpty {
            try Task.checkCancellation()
            let plans = try await dwindleHandler.layoutWithDwindleEngine(activeWorkspaces: dwindleWorkspaces)
            try Task.checkCancellation()
            workspacePlans.append(contentsOf: plans)
        }

        var effects = RefreshExecutionEffects()
        effects.visibility = .init(activeWorkspaceIds: activeWorkspaceIds)
        effects.requestWorkspaceBarRefresh = true
        effects.updateTabbedOverlays = updateTabbedOverlays
        if !controller.workspaceManager.isAppFullscreenActive,
           !controller.workspaceManager.hasPendingNativeFullscreenTransition,
           !controller.shouldSuppressManagedFocusRecovery,
           let focusedWorkspaceId
        {
            effects.focusValidationWorkspaceIds = [focusedWorkspaceId]
        }
        effects.markInitialRefreshComplete = true
        effects.drainDeferredCreatedWindows = true
        effects.subscribeManagedWindows = true

        return RefreshExecutionPlan(workspacePlans: workspacePlans, effects: effects)
    }

    private func shouldPreserveMissingWindowsDuringNativeFullscreen(
        controller: WMController
    ) -> Bool {
        controller.workspaceManager.hasNativeFullscreenLifecycleContext
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

    private func currentActiveWorkspaceIds() -> Set<WorkspaceDescriptor.ID> {
        guard let controller else { return [] }

        var activeWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        for monitor in controller.workspaceManager.monitors {
            if let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                activeWorkspaceIds.insert(workspace.id)
            }
        }
        return activeWorkspaceIds
    }

    private func enqueueRefresh(_ refresh: ScheduledRefresh) {
        recordRefreshRequest(refresh.reason)
        if let activeRefresh = layoutState.activeRefresh {
            handleRefresh(refresh, whileActive: activeRefresh)
            return
        }

        mergePendingRefresh(refresh)
        startNextRefreshIfNeeded()
    }

    private func handleRefresh(_ refresh: ScheduledRefresh, whileActive activeRefresh: ScheduledRefresh) {
        switch (activeRefresh.kind, refresh.kind) {
        case (.fullRescan, .fullRescan):
            mergePendingRefresh(refresh)
        case (.fullRescan, .visibilityRefresh):
            absorbIntoActiveFullRescan(refresh)
        case (.fullRescan, .windowRemoval),
             (.fullRescan, .immediateRelayout),
             (.fullRescan, .relayout):
            mergePendingRefresh(refresh)
        case (.visibilityRefresh, .visibilityRefresh):
            mergePendingRefresh(refresh)
        case (.visibilityRefresh, .fullRescan),
             (.visibilityRefresh, .windowRemoval),
             (.visibilityRefresh, .immediateRelayout),
             (.visibilityRefresh, .relayout):
            mergePendingRefresh(refresh)
            layoutState.activeRefreshTask?.cancel()
        case (.windowRemoval, .fullRescan):
            mergePendingRefresh(refresh)
        case (.windowRemoval, _):
            mergePendingRefresh(refresh)
        case (.immediateRelayout, .fullRescan):
            mergePendingRefresh(refresh)
            layoutState.activeRefreshTask?.cancel()
        case (.immediateRelayout, .immediateRelayout):
            mergePendingRefresh(refresh)
            layoutState.activeRefreshTask?.cancel()
        case (.immediateRelayout, .relayout):
            mergePendingRefresh(refresh)
        case (.immediateRelayout, .visibilityRefresh):
            mergePendingRefresh(refresh)
        case (.immediateRelayout, .windowRemoval):
            mergePendingRefresh(refresh)
            layoutState.activeRefreshTask?.cancel()
        case (.relayout, .fullRescan),
             (.relayout, .immediateRelayout),
             (.relayout, .relayout),
             (.relayout, .windowRemoval):
            mergePendingRefresh(refresh)
            layoutState.activeRefreshTask?.cancel()
        case (.relayout, .visibilityRefresh):
            mergePendingRefresh(refresh)
        }
    }

    private func absorbIntoActiveFullRescan(_ refresh: ScheduledRefresh) {
        guard var activeRefresh = layoutState.activeRefresh else { return }
        activeRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
        mergeAbsorbedVisibility(into: &activeRefresh, from: refresh)
        layoutState.activeRefresh = activeRefresh
    }

    private func mergePendingRefresh(_ refresh: ScheduledRefresh) {
        guard var pendingRefresh = layoutState.pendingRefresh else {
            layoutState.pendingRefresh = refresh
            return
        }

        let existingAffectedWorkspaceIds = pendingRefresh.affectedWorkspaceIds

        switch (pendingRefresh.kind, refresh.kind) {
        case (.fullRescan, .fullRescan):
            pendingRefresh.reason = refresh.reason
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.fullRescan, _):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.visibilityRefresh, .fullRescan),
             (.visibilityRefresh, .windowRemoval),
             (.visibilityRefresh, .immediateRelayout),
             (.visibilityRefresh, .relayout):
            var upgradedRefresh = refresh
            upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
            pendingRefresh = upgradedRefresh
        case (.visibilityRefresh, .visibilityRefresh):
            pendingRefresh.reason = refresh.reason
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
        case (.windowRemoval, .fullRescan),
             (.immediateRelayout, .fullRescan),
             (.relayout, .fullRescan):
            var upgradedRefresh = refresh
            upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
            pendingRefresh = upgradedRefresh
        case (.windowRemoval, .windowRemoval):
            pendingRefresh.reason = refresh.reason
            pendingRefresh.windowRemovalPayloads = mergeWindowRemovalPayloads(
                pendingRefresh.windowRemovalPayloads,
                with: refresh.windowRemovalPayloads
            )
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.windowRemoval, .immediateRelayout):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeFollowUp(
                into: &pendingRefresh,
                kind: .immediateRelayout,
                reason: refresh.reason,
                affectedWorkspaceIds: refresh.affectedWorkspaceIds
            )
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.windowRemoval, .relayout):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeFollowUp(
                into: &pendingRefresh,
                kind: .relayout,
                reason: refresh.reason,
                affectedWorkspaceIds: refresh.affectedWorkspaceIds
            )
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.windowRemoval, .visibilityRefresh):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.immediateRelayout, .windowRemoval):
            var upgradedRefresh = refresh
            upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
            upgradedRefresh.followUpRefresh = pendingRefresh.followUpRefresh
            mergeFollowUp(
                into: &upgradedRefresh,
                kind: .immediateRelayout,
                reason: pendingRefresh.reason,
                affectedWorkspaceIds: pendingRefresh.affectedWorkspaceIds
            )
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
            pendingRefresh = upgradedRefresh
        case (.relayout, .windowRemoval):
            var upgradedRefresh = refresh
            upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
            mergeFollowUp(
                into: &upgradedRefresh,
                kind: .relayout,
                reason: pendingRefresh.reason,
                affectedWorkspaceIds: pendingRefresh.affectedWorkspaceIds
            )
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
            pendingRefresh = upgradedRefresh
        case (.immediateRelayout, .visibilityRefresh),
             (.relayout, .visibilityRefresh):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.immediateRelayout, .immediateRelayout),
             (.relayout, .relayout):
            pendingRefresh.reason = refresh.reason
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            pendingRefresh.followUpRefresh = mergeFollowUpRefresh(
                pendingRefresh.followUpRefresh,
                with: refresh.followUpRefresh
            )
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.immediateRelayout, .relayout):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeFollowUp(
                into: &pendingRefresh,
                kind: .relayout,
                reason: refresh.reason,
                affectedWorkspaceIds: refresh.affectedWorkspaceIds
            )
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.relayout, .immediateRelayout):
            var upgradedRefresh = refresh
            upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
            upgradedRefresh.followUpRefresh = mergeFollowUpRefresh(
                pendingRefresh.followUpRefresh,
                with: refresh.followUpRefresh
            )
            mergeFollowUp(
                into: &upgradedRefresh,
                kind: .relayout,
                reason: pendingRefresh.reason,
                affectedWorkspaceIds: pendingRefresh.affectedWorkspaceIds
            )
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
            pendingRefresh = upgradedRefresh
        }

        pendingRefresh.affectedWorkspaceIds.formUnion(existingAffectedWorkspaceIds)
        pendingRefresh.affectedWorkspaceIds.formUnion(refresh.affectedWorkspaceIds)

        layoutState.pendingRefresh = pendingRefresh
    }

    private func startNextRefreshIfNeeded() {
        guard layoutState.activeRefreshTask == nil, let refresh = layoutState.pendingRefresh else { return }

        layoutState.pendingRefresh = nil
        layoutState.activeRefresh = refresh
        layoutState.didExecuteRefreshExecutionPlan = false
        layoutState.activeRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let didComplete = await self.execute(refresh)
            self.finishRefresh(refresh, didComplete: didComplete)
        }
    }

    private func execute(_ refresh: ScheduledRefresh) async -> Bool {
        do {
            switch refresh.kind {
            case .fullRescan:
                return try await executeFullRefresh(refresh: refresh)
            case .relayout:
                let policy = refresh.reason.relayoutSchedulingPolicy
                if policy.debounceInterval > 0 {
                    try await Task.sleep(nanoseconds: policy.debounceInterval)
                }
                try Task.checkCancellation()
                return await executeScheduledRelayout(refresh: refresh)
            case .immediateRelayout:
                return await executeImmediateRelayout(refresh: refresh)
            case .visibilityRefresh:
                return await executeVisibilityRefresh(refresh: refresh)
            case .windowRemoval:
                return await executeWindowRemoval(refresh: refresh)
            }
        } catch {
            return false
        }
    }

    private func finishRefresh(_ refresh: ScheduledRefresh, didComplete: Bool) {
        let completedRefresh = layoutState.activeRefresh ?? refresh
        let didExecuteRefreshExecutionPlan = layoutState.didExecuteRefreshExecutionPlan

        if !didComplete {
            preserveCancelledRefreshState(completedRefresh)
        }

        layoutState.activeRefreshTask = nil
        layoutState.activeRefresh = nil
        layoutState.didExecuteRefreshExecutionPlan = false

        if didComplete {
            if !didExecuteRefreshExecutionPlan, let controller {
                let shouldRequestWorkspaceBarRefresh =
                    completedRefresh.kind != .visibilityRefresh && completedRefresh.needsVisibilityReconciliation

                if completedRefresh.kind != .visibilityRefresh, completedRefresh.needsVisibilityReconciliation {
                    performVisibilitySideEffects(on: controller)
                }
                for postLayoutAction in completedRefresh.postLayoutActions {
                    postLayoutAction()
                }
                if shouldRequestWorkspaceBarRefresh {
                    controller.requestWorkspaceBarRefresh()
                }
            }
            if let followUpRefresh = completedRefresh.followUpRefresh {
                enqueueRefresh(
                    .init(
                        kind: followUpRefresh.kind,
                        reason: followUpRefresh.reason,
                        affectedWorkspaceIds: followUpRefresh.affectedWorkspaceIds
                    )
                )
            }
        }

        startNextRefreshIfNeeded()
    }

    private func recordRefreshExecution(_ route: RefreshRoute, reason: RefreshReason) {
        debugCounters.executedByReason[reason, default: 0] += 1
        switch route {
        case .relayout:
            debugCounters.relayoutExecutions += 1
        case .immediateRelayout:
            debugCounters.immediateRelayoutExecutions += 1
        case .visibilityRefresh:
            debugCounters.visibilityExecutions += 1
        case .windowRemoval:
            debugCounters.windowRemovalExecutions += 1
        }
    }

    private func recordRefreshRequest(_ reason: RefreshReason) {
        debugCounters.requestedByReason[reason, default: 0] += 1
    }

    private func mergeWindowRemovalPayloads(
        _ existingPayloads: [WindowRemovalPayload],
        with incomingPayloads: [WindowRemovalPayload]
    ) -> [WindowRemovalPayload] {
        existingPayloads + incomingPayloads
    }

    private func mergeFollowUp(
        into refresh: inout ScheduledRefresh,
        kind: ScheduledRefreshKind,
        reason: RefreshReason,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
    ) {
        refresh.followUpRefresh = mergeFollowUpRefresh(
            refresh.followUpRefresh,
            with: .init(kind: kind, reason: reason, affectedWorkspaceIds: affectedWorkspaceIds)
        )
    }

    private func mergeAbsorbedVisibility(into refresh: inout ScheduledRefresh, from incoming: ScheduledRefresh) {
        switch incoming.kind {
        case .visibilityRefresh:
            refresh.needsVisibilityReconciliation = true
            refresh.visibilityReason = incoming.reason
        case .fullRescan, .windowRemoval, .immediateRelayout, .relayout:
            guard incoming.needsVisibilityReconciliation else { return }
            refresh.needsVisibilityReconciliation = true
            refresh.visibilityReason = incoming.visibilityReason ?? refresh.visibilityReason
        }
    }

    private func mergeFollowUpRefresh(
        _ existing: FollowUpRefresh?,
        with incoming: FollowUpRefresh?
    ) -> FollowUpRefresh? {
        switch (existing, incoming) {
        case (nil, nil):
            return nil
        case let (value?, nil), let (nil, value?):
            return value
        case let (existing?, incoming?):
            var merged = incoming
            merged.affectedWorkspaceIds.formUnion(existing.affectedWorkspaceIds)
            if existing.kind == .immediateRelayout || incoming.kind == .immediateRelayout {
                if incoming.kind == .immediateRelayout {
                    return merged
                }
                var kept = existing
                kept.affectedWorkspaceIds.formUnion(incoming.affectedWorkspaceIds)
                return kept
            }
            return merged
        }
    }

    private func preserveCancelledRefreshState(_ refresh: ScheduledRefresh) {
        guard var pendingRefresh = layoutState.pendingRefresh else {
            layoutState.pendingRefresh = refresh
            return
        }

        if !refresh.postLayoutActions.isEmpty {
            pendingRefresh.postLayoutActions.insert(contentsOf: refresh.postLayoutActions, at: 0)
        }

        pendingRefresh.affectedWorkspaceIds.formUnion(refresh.affectedWorkspaceIds)

        if refresh.kind == .windowRemoval, !refresh.windowRemovalPayloads.isEmpty {
            pendingRefresh.windowRemovalPayloads = mergeWindowRemovalPayloads(
                refresh.windowRemovalPayloads,
                with: pendingRefresh.windowRemovalPayloads
            )
            if pendingRefresh.kind != .fullRescan, pendingRefresh.kind != .windowRemoval {
                pendingRefresh.kind = .windowRemoval
                pendingRefresh.reason = refresh.reason
            }
        }

        mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        pendingRefresh.followUpRefresh = mergeFollowUpRefresh(
            refresh.followUpRefresh,
            with: pendingRefresh.followUpRefresh
        )

        layoutState.pendingRefresh = pendingRefresh
    }

    private func performVisibilitySideEffects(on controller: WMController) {
        controller.niriLayoutHandler.updateTabbedColumnOverlays()
        refreshFocusedBorderForVisibilityState(on: controller)
    }

    func backingScale(for monitor: Monitor) -> CGFloat {
        NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?.backingScaleFactor ?? 2.0
    }

    private func workspaceEntriesSnapshot(
        on controller: WMController
    ) -> [(workspace: WorkspaceDescriptor, entries: [WindowModel.Entry])] {
        controller.workspaceManager.workspaces.map { workspace in
            (workspace, controller.workspaceManager.entries(in: workspace.id))
        }
    }

    private func rebuildInactiveWorkspaceWindowSet(activeWorkspaceIds: Set<WorkspaceDescriptor.ID>) {
        guard let controller else { return }
        var allEntries: [(workspaceId: WorkspaceDescriptor.ID, windowId: Int)] = []
        for workspace in controller.workspaceManager.workspaces {
            for entry in controller.workspaceManager.entries(in: workspace.id) {
                allEntries.append((workspace.id, entry.windowId))
            }
        }
        controller.axManager.updateInactiveWorkspaceWindows(
            allEntries: allEntries,
            activeWorkspaceIds: activeWorkspaceIds
        )
    }

    func hideInactiveWorkspaces(activeWorkspaceIds: Set<WorkspaceDescriptor.ID>) {
        guard let controller else { return }
        let workspaceEntries = workspaceEntriesSnapshot(on: controller)

        // Rebuild the workspace-level frame suppression set (live check in applyFramesParallel).
        // Note: this is also called earlier in executeRefreshExecutionPlan to unblock frame
        // writes for newly-active workspaces. The rebuild here keeps the set consistent with
        // the snapshot used for the hide pass below.
        var allEntries: [(workspaceId: WorkspaceDescriptor.ID, windowId: Int)] = []
        allEntries.reserveCapacity(workspaceEntries.reduce(into: 0) { $0 += $1.entries.count })
        for snapshot in workspaceEntries {
            for entry in snapshot.entries {
                allEntries.append((snapshot.workspace.id, entry.windowId))
            }
        }
        controller.axManager.updateInactiveWorkspaceWindows(
            allEntries: allEntries,
            activeWorkspaceIds: activeWorkspaceIds
        )

        // Bulk cancel in-flight frame jobs for all inactive workspace windows upfront,
        // before the per-window hide loop, to prevent AX batch races with SkyLight moves.
        var inactiveWindowJobs: [(pid: pid_t, windowId: Int)] = []
        let hiddenPlacementMonitors = controller.workspaceManager.monitors.map(HiddenPlacementMonitorContext.init)
        for snapshot in workspaceEntries where !activeWorkspaceIds.contains(snapshot.workspace.id) {
            for entry in snapshot.entries {
                inactiveWindowJobs.append((entry.handle.pid, entry.windowId))
            }
        }
        if !inactiveWindowJobs.isEmpty {
            controller.axManager.cancelPendingFrameJobs(inactiveWindowJobs)
        }

        let preferredSides = preferredHideSides(for: controller.workspaceManager.monitors)
        for snapshot in workspaceEntries where !activeWorkspaceIds.contains(snapshot.workspace.id) {
            guard let monitor = controller.workspaceManager.monitor(for: snapshot.workspace.id) else { continue }
            let preferredSide = preferredSides[monitor.id] ?? .right
            hideWorkspace(
                snapshot.entries,
                monitor: monitor,
                preferredSide: preferredSide,
                hiddenPlacementMonitors: hiddenPlacementMonitors
            )
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

    private func hideWorkspace(
        _ entries: [WindowModel.Entry],
        monitor: Monitor,
        preferredSide: HideSide,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]? = nil
    ) {
        guard let controller else { return }
        for entry in entries {
            controller.axManager.markWindowInactive(entry.windowId)
            hideWindow(
                entry,
                monitor: monitor,
                side: preferredSide,
                reason: .workspaceInactive,
                hiddenPlacementMonitors: hiddenPlacementMonitors
            )
        }
    }

    fileprivate struct WindowPositionPlan {
        let entry: WindowModel.Entry
        let origin: CGPoint
        let frameSize: CGSize
    }

    fileprivate enum HideOperationResolution {
        case movable(WindowPositionPlan, hiddenState: WindowModel.HiddenState)
        case alreadyHidden(hiddenState: WindowModel.HiddenState)
        case unavailable
    }

    fileprivate func applyPositionPlans(_ plans: [WindowPositionPlan]) {
        guard let controller, !plans.isEmpty else { return }

        controller.axManager.applyPositionsViaSkyLight(
            plans.map { (windowId: $0.entry.windowId, origin: $0.origin) },
            allowInactive: true
        )

        let verifyEpsilon: CGFloat = 1.0
        for plan in plans {
            if let observedOrigin = observedWindowOrigin(plan.entry),
               abs(observedOrigin.x - plan.origin.x) > verifyEpsilon
                || abs(observedOrigin.y - plan.origin.y) > verifyEpsilon
            {
                let fallbackFrame = CGRect(origin: plan.origin, size: plan.frameSize)
                _ = AXWindowService.setFrame(plan.entry.axRef, frame: fallbackFrame)
            }
        }
    }

    fileprivate func resolveHideOperation(
        for entry: WindowModel.Entry,
        monitor: Monitor,
        side: HideSide,
        reason: HideReason,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]? = nil
    ) -> HideOperationResolution {
        guard let controller else { return .unavailable }
        guard let frame = fastFrame(for: entry.token, axRef: entry.axRef)
            ?? controller.axManager.lastAppliedFrame(for: entry.windowId)
            ?? (try? AXWindowService.frame(entry.axRef))
        else {
            return .unavailable
        }
        let hiddenState = updatedHiddenState(
            for: entry,
            frame: frame,
            monitor: monitor,
            side: side,
            reason: reason
        )

        guard let origin = liveFrameHideOrigin(
            for: frame,
            monitor: monitor,
            side: side,
            pid: entry.handle.pid,
            reason: reason,
            hiddenPlacementMonitors: hiddenPlacementMonitors
        ) else {
            return .unavailable
        }

        let moveEpsilon: CGFloat = 0.01
        if abs(frame.origin.x - origin.x) < moveEpsilon,
           abs(frame.origin.y - origin.y) < moveEpsilon
        {
            return .alreadyHidden(hiddenState: hiddenState)
        }

        return .movable(
            WindowPositionPlan(
                entry: entry,
                origin: origin,
                frameSize: frame.size
            ),
            hiddenState: hiddenState
        )
    }

    private func updatedHiddenState(
        for entry: WindowModel.Entry,
        frame: CGRect,
        monitor: Monitor,
        side: HideSide,
        reason: HideReason
    ) -> WindowModel.HiddenState {
        guard let controller else {
            return WindowModel.HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: hiddenWindowReason(for: reason, side: side, existingState: nil)
            )
        }

        let existingState = controller.workspaceManager.hiddenState(for: entry.token)
        let proportionalPosition: CGPoint
        let referenceMonitorId: Monitor.ID?

        if let existingState {
            proportionalPosition = existingState.proportionalPosition
            referenceMonitorId = existingState.referenceMonitorId
        } else {
            let center = frame.center
            let referenceMonitor = center.monitorApproximation(in: controller.workspaceManager.monitors) ?? monitor
            proportionalPosition = self.proportionalPosition(topLeft: frame.topLeftCorner, in: referenceMonitor.frame)
            referenceMonitorId = referenceMonitor.id
        }

        return WindowModel.HiddenState(
            proportionalPosition: proportionalPosition,
            referenceMonitorId: referenceMonitorId,
            reason: hiddenWindowReason(for: reason, side: side, existingState: existingState)
        )
    }

    private func hiddenWindowReason(
        for reason: HideReason,
        side: HideSide,
        existingState: WindowModel.HiddenState?
    ) -> WindowModel.HiddenReason {
        if existingState?.isScratchpad == true, reason != .scratchpad {
            return .scratchpad
        }

        if existingState?.workspaceInactive == true, reason == .layoutTransient {
            return .workspaceInactive
        }

        switch reason {
        case .workspaceInactive:
            return .workspaceInactive
        case .layoutTransient:
            return .layoutTransient(side)
        case .scratchpad:
            return .scratchpad
        }
    }

    func hideWindow(
        _ entry: WindowModel.Entry,
        monitor: Monitor,
        side: HideSide,
        reason: HideReason,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]? = nil
    ) {
        guard let controller else { return }
        let frameEntry = (pid: entry.handle.pid, windowId: entry.windowId)
        switch resolveHideOperation(
            for: entry,
            monitor: monitor,
            side: side,
            reason: reason,
            hiddenPlacementMonitors: hiddenPlacementMonitors
        ) {
        case let .movable(plan, hiddenState):
            controller.workspaceManager.setHiddenState(hiddenState, for: entry.token)
            controller.axManager.cancelPendingFrameJobs([frameEntry])
            controller.axManager.suppressFrameWrites([frameEntry])
            applyPositionPlans([plan])
        case let .alreadyHidden(hiddenState):
            controller.workspaceManager.setHiddenState(hiddenState, for: entry.token)
            controller.axManager.cancelPendingFrameJobs([frameEntry])
            controller.axManager.suppressFrameWrites([frameEntry])
        case .unavailable:
            break
        }
    }

    func liveFrameHideOrigin(
        for frame: CGRect,
        monitor: Monitor,
        side: HideSide,
        pid: pid_t,
        reason: HideReason,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]? = nil
    ) -> CGPoint? {
        guard let controller else { return nil }
        let scale = backingScale(for: monitor)
        let baseReveal = Self.hiddenEdgeReveal(isZoomApp: isZoomApp(pid))
        let hiddenPlacementMonitor = HiddenPlacementMonitorContext(monitor)
        let resolvedHiddenPlacementMonitors = hiddenPlacementMonitors
            ?? controller.workspaceManager.monitors.map(HiddenPlacementMonitorContext.init)

        switch reason {
        case .workspaceInactive, .scratchpad:
            return HiddenWindowPlacementResolver.physicalScreenEdgeOrigin(
                for: frame.size,
                requestedSide: side,
                targetY: frame.origin.y,
                baseReveal: baseReveal,
                scale: scale,
                monitor: hiddenPlacementMonitor,
                monitors: resolvedHiddenPlacementMonitors
            )
        case .layoutTransient:
            let orientation = controller.settings.effectiveOrientation(for: monitor)
            let orthogonalOrigin: CGFloat = switch orientation {
            case .horizontal: frame.origin.y
            case .vertical: frame.origin.x
            }
            let requestedEdge = AxisHideEdge(encodedHideSide: side)
            let placement = HiddenWindowPlacementResolver.placement(
                for: frame.size,
                requestedEdge: requestedEdge,
                orthogonalOrigin: orthogonalOrigin,
                baseReveal: baseReveal,
                scale: scale,
                orientation: orientation,
                monitor: hiddenPlacementMonitor,
                monitors: resolvedHiddenPlacementMonitors
            )
            return placement.origin
        }
    }

    func unhideWindow(_ entry: WindowModel.Entry, monitor: Monitor) {
        guard let controller else { return }
        guard let hiddenState = controller.workspaceManager.hiddenState(for: entry.token) else {
            controller.axManager.unsuppressFrameWrites([(entry.handle.pid, entry.windowId)])
            return
        }
        guard hiddenState.workspaceInactive else { return }

        restoreWindowFromHiddenState(entry, monitor: monitor, hiddenState: hiddenState)
        controller.workspaceManager.setHiddenState(nil, for: entry.token)
        controller.axManager.unsuppressFrameWrites([(entry.handle.pid, entry.windowId)])
    }

    func restoreScratchpadWindow(_ entry: WindowModel.Entry, monitor: Monitor) {
        guard let controller,
              let hiddenState = controller.workspaceManager.hiddenState(for: entry.token),
              hiddenState.isScratchpad
        else {
            return
        }

        restoreWindowFromHiddenState(entry, monitor: monitor, hiddenState: hiddenState)
        controller.workspaceManager.setHiddenState(nil, for: entry.token)
        controller.axManager.unsuppressFrameWrites([(entry.handle.pid, entry.windowId)])
    }

    func proportionalPosition(topLeft: CGPoint, in frame: CGRect) -> CGPoint {
        let width = max(1, frame.width)
        let height = max(1, frame.height)
        let x = (topLeft.x - frame.minX) / width
        let y = (frame.maxY - topLeft.y) / height
        return CGPoint(x: min(max(0, x), 1), y: min(max(0, y), 1))
    }

    private func preferredHideSides(for monitors: [Monitor]) -> [Monitor.ID: HideSide] {
        let important = 10
        var preferredSides: [Monitor.ID: HideSide] = [:]

        for monitor in monitors {
            let monitorFrame = monitor.frame
            let xOff = monitorFrame.width * 0.1
            let yOff = monitorFrame.height * 0.1

            let bottomRight = CGPoint(x: monitorFrame.maxX, y: monitorFrame.minY)
            let bottomLeft = CGPoint(x: monitorFrame.minX, y: monitorFrame.minY)

            let rightPoints = [
                CGPoint(x: bottomRight.x + 2, y: bottomRight.y - yOff),
                CGPoint(x: bottomRight.x - xOff, y: bottomRight.y + 2),
                CGPoint(x: bottomRight.x + 2, y: bottomRight.y + 2)
            ]

            let leftPoints = [
                CGPoint(x: bottomLeft.x - 2, y: bottomLeft.y - yOff),
                CGPoint(x: bottomLeft.x + xOff, y: bottomLeft.y + 2),
                CGPoint(x: bottomLeft.x - 2, y: bottomLeft.y + 2)
            ]

            func sideScore(_ points: [CGPoint]) -> Int {
                monitors.reduce(0) { partial, other in
                    let c1 = other.frame.contains(points[0]) ? 1 : 0
                    let c2 = other.frame.contains(points[1]) ? 1 : 0
                    let c3 = other.frame.contains(points[2]) ? 1 : 0
                    return partial + c1 + c2 + important * c3
                }
            }

            let leftScore = sideScore(leftPoints)
            let rightScore = sideScore(rightPoints)
            preferredSides[monitor.id] = leftScore < rightScore ? .left : .right
        }

        return preferredSides
    }

    func preferredHideSide(for monitor: Monitor) -> HideSide {
        guard let controller else { return .right }
        return preferredHideSides(for: controller.workspaceManager.monitors)[monitor.id] ?? .right
    }

    private func restoreWindowFromHiddenState(
        _ entry: WindowModel.Entry,
        monitor: Monitor,
        hiddenState: WindowModel.HiddenState
    ) {
        if entry.mode == .floating,
           hiddenState.restoresViaFloatingState,
           let controller,
           let frame = controller.workspaceManager.resolvedFloatingFrame(
               for: entry.token,
               preferredMonitor: monitor
           )
        {
            controller.axManager.forceApplyNextFrame(for: entry.windowId)
            controller.axManager.applyFramesParallel([(entry.pid, entry.windowId, frame)])
            return
        }

        if let plan = makeRestorePositionPlan(
            for: entry,
            monitor: monitor,
            hiddenState: hiddenState
        ) {
            applyPositionPlans([plan])
        }
    }

    fileprivate func makeRestorePositionPlan(
        for entry: WindowModel.Entry,
        monitor: Monitor,
        hiddenState: WindowModel.HiddenState
    ) -> WindowPositionPlan? {
        guard let controller else { return nil }
        guard let frame = fastFrame(for: entry.token, axRef: entry.axRef)
            ?? controller.axManager.lastAppliedFrame(for: entry.windowId)
        else {
            return nil
        }

        let fallbackMonitor = hiddenState.referenceMonitorId
            .flatMap { controller.workspaceManager.monitor(byId: $0) }
        let restoreFrame: CGRect
        if monitor.frame.width > 1, monitor.frame.height > 1 {
            restoreFrame = monitor.frame
        } else {
            restoreFrame = fallbackMonitor?.frame ?? monitor.frame
        }

        let topLeft = topLeftPoint(from: hiddenState.proportionalPosition, in: restoreFrame)
        let restoredOrigin = clampedOrigin(forTopLeft: topLeft, windowSize: frame.size, in: restoreFrame)
        let moveEpsilon: CGFloat = 0.01
        if abs(frame.origin.x - restoredOrigin.x) < moveEpsilon,
           abs(frame.origin.y - restoredOrigin.y) < moveEpsilon
        {
            return nil
        }

        return WindowPositionPlan(
            entry: entry,
            origin: restoredOrigin,
            frameSize: frame.size
        )
    }

    private func topLeftPoint(from proportionalPosition: CGPoint, in frame: CGRect) -> CGPoint {
        let xRatio = min(max(proportionalPosition.x, 0), 1)
        let yRatio = min(max(proportionalPosition.y, 0), 1)
        return CGPoint(
            x: frame.minX + frame.width * xRatio,
            y: frame.maxY - frame.height * yRatio
        )
    }

    private func clampedOrigin(forTopLeft topLeft: CGPoint, windowSize: CGSize, in frame: CGRect) -> CGPoint {
        let minX = frame.minX
        let maxX = frame.maxX - windowSize.width
        let clampedX: CGFloat
        if maxX >= minX {
            clampedX = min(max(topLeft.x, minX), maxX)
        } else {
            clampedX = minX
        }

        let minTopLeftY = frame.minY + windowSize.height
        let maxTopLeftY = frame.maxY
        let clampedTopLeftY: CGFloat
        if maxTopLeftY >= minTopLeftY {
            clampedTopLeftY = min(max(topLeft.y, minTopLeftY), maxTopLeftY)
        } else {
            clampedTopLeftY = maxTopLeftY
        }

        return CGPoint(x: clampedX, y: clampedTopLeftY - windowSize.height)
    }

    private func observedWindowOrigin(_ entry: WindowModel.Entry) -> CGPoint? {
        if let wsRect = SkyLight.shared.getWindowBounds(UInt32(entry.windowId)) {
            let appKitRect = ScreenCoordinateSpace.toAppKit(rect: wsRect)
            return appKitRect.origin
        }
        return fastFrame(for: entry.token, axRef: entry.axRef)?.origin
    }

    static func hiddenEdgeReveal(isZoomApp: Bool) -> CGFloat {
        isZoomApp ? 0 : hiddenWindowEdgeRevealEpsilon
    }

    func isZoomApp(_ pid: pid_t) -> Bool {
        controller?.appInfoCache.bundleId(for: pid) == "us.zoom.xos"
    }

    func updateWindowConstraints(
        in wsId: WorkspaceDescriptor.ID,
        updateEngine: (WindowToken, WindowSizeConstraints) -> Void
    ) {
        guard let controller else { return }
        let snapshots = buildWindowSnapshots(for: controller.workspaceManager.tiledEntries(in: wsId))
        for snapshot in snapshots {
            updateEngine(snapshot.token, snapshot.constraints)
        }
    }
}

@MainActor
final class LayoutDiffExecutor {
    private unowned let refreshController: LayoutRefreshController

    init(refreshController: LayoutRefreshController) {
        self.refreshController = refreshController
    }

    func execute(_ plan: WorkspaceLayoutPlan) {
        guard let controller = refreshController.controller,
              let monitor = resolveMonitor(from: plan.monitor, controller: controller)
        else {
            return
        }

        let diff = plan.diff

        var resolvedEntries: [WindowToken: WindowModel.Entry] = [:]
        var hiddenEntries: [(entry: WindowModel.Entry, side: HideSide)] = []
        var hiddenTokens: Set<WindowToken> = []
        var shownEntries: [WindowModel.Entry] = []
        var restoreEntries: [(entry: WindowModel.Entry, hiddenState: WindowModel.HiddenState)] = []
        var restoreTokens: Set<WindowToken> = []

        func resolveEntry(for token: WindowToken) -> WindowModel.Entry? {
            if let cached = resolvedEntries[token] {
                return cached
            }
            guard let entry = controller.workspaceManager.entry(for: token) else {
                return nil
            }
            resolvedEntries[token] = entry
            return entry
        }

        for change in diff.visibilityChanges {
            switch change {
            case let .show(token):
                guard let entry = resolveEntry(for: token) else { continue }
                guard entry.layoutReason != .nativeFullscreen else { continue }
                shownEntries.append(entry)
            case let .hide(token, side):
                hiddenTokens.insert(token)
                guard let entry = resolveEntry(for: token) else { continue }
                guard entry.layoutReason != .nativeFullscreen else { continue }
                hiddenEntries.append((entry, side))
            }
        }

        for restoreChange in diff.restoreChanges where !hiddenTokens.contains(restoreChange.token) {
            guard restoreTokens.insert(restoreChange.token).inserted,
                  let entry = resolveEntry(for: restoreChange.token)
            else {
                continue
            }
            guard entry.layoutReason != .nativeFullscreen else { continue }
            restoreEntries.append((entry, restoreChange.hiddenState))
        }

        if !hiddenEntries.isEmpty {
            var hiddenJobs: [(pid: pid_t, windowId: Int)] = []
            hiddenJobs.reserveCapacity(hiddenEntries.count)
            var hidePlans: [LayoutRefreshController.WindowPositionPlan] = []

            for (entry, side) in hiddenEntries {
                switch refreshController.resolveHideOperation(
                    for: entry,
                    monitor: monitor,
                    side: side,
                    reason: .layoutTransient
                ) {
                case let .movable(plan, hiddenState):
                    controller.workspaceManager.setHiddenState(hiddenState, for: entry.token)
                    hiddenJobs.append((entry.handle.pid, entry.windowId))
                    hidePlans.append(plan)
                case let .alreadyHidden(hiddenState):
                    controller.workspaceManager.setHiddenState(hiddenState, for: entry.token)
                    hiddenJobs.append((entry.handle.pid, entry.windowId))
                case .unavailable:
                    continue
                }
            }

            if !hiddenJobs.isEmpty {
                controller.axManager.cancelPendingFrameJobs(hiddenJobs)
                controller.axManager.suppressFrameWrites(hiddenJobs)
            }
            if !hidePlans.isEmpty {
                refreshController.applyPositionPlans(hidePlans)
            }
        }

        if !restoreEntries.isEmpty {
            let restorePlans: [LayoutRefreshController.WindowPositionPlan] = restoreEntries.compactMap { entry, hiddenState in
                refreshController.makeRestorePositionPlan(
                    for: entry,
                    monitor: monitor,
                    hiddenState: hiddenState
                )
            }
            refreshController.applyPositionPlans(restorePlans)

            for (entry, _) in restoreEntries {
                controller.workspaceManager.setHiddenState(nil, for: entry.token)
            }
        }

        if !shownEntries.isEmpty {
            for entry in shownEntries where !restoreTokens.contains(entry.token) {
                controller.workspaceManager.setHiddenState(nil, for: entry.token)
            }
        }

        if !restoreEntries.isEmpty || !shownEntries.isEmpty {
            var visibleJobs: [(pid: pid_t, windowId: Int)] = []
            visibleJobs.reserveCapacity(restoreEntries.count + shownEntries.count)
            var seenTokens: Set<WindowToken> = []

            for (entry, _) in restoreEntries where seenTokens.insert(entry.token).inserted {
                visibleJobs.append((entry.handle.pid, entry.windowId))
            }

            for entry in shownEntries where seenTokens.insert(entry.token).inserted {
                visibleJobs.append((entry.handle.pid, entry.windowId))
            }

            if !visibleJobs.isEmpty {
                controller.axManager.unsuppressFrameWrites(visibleJobs)
            }
        }

        var frameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []
        frameUpdates.reserveCapacity(diff.frameChanges.count)

        for change in diff.frameChanges {
            guard !hiddenTokens.contains(change.token),
                  let entry = resolveEntry(for: change.token)
            else {
                continue
            }
            guard entry.layoutReason != .nativeFullscreen else { continue }
            if change.forceApply {
                controller.axManager.forceApplyNextFrame(for: entry.windowId)
            }
            frameUpdates.append((entry.pid, entry.windowId, change.frame))
        }

        if !frameUpdates.isEmpty {
            controller.axManager.applyFramesParallel(frameUpdates)
        }

        switch diff.borderMode {
        case .none:
            break
        case .direct:
            applyDirectBorderUpdate(diff.focusedFrame)
        case .coordinated:
            applyCoordinatedBorderUpdate(diff.focusedFrame)
        }
    }

    private func resolveMonitor(
        from snapshot: LayoutMonitorSnapshot,
        controller: WMController
    ) -> Monitor? {
        if let monitor = controller.workspaceManager.monitor(byId: snapshot.monitorId) {
            return monitor
        }

        return controller.workspaceManager.monitors.first(where: { $0.displayId == snapshot.displayId })
    }

    private func applyDirectBorderUpdate(_ focusedFrame: LayoutFocusedFrame?) {
        guard let controller = refreshController.controller else { return }
        let target = resolvedBorderRenderTarget(controller: controller, focusedFrame: focusedFrame)
        let fallbackPreferredFrame: CGRect?
        if let target, target.isManaged {
            fallbackPreferredFrame = controller.preferredKeyboardFocusFrame(for: target.token)
        } else {
            fallbackPreferredFrame = nil
        }
        if target?.isManaged == true,
           focusedFrame == nil,
           fallbackPreferredFrame == nil
        {
            controller.borderManager.hideBorder()
            return
        }
        guard !shouldIgnoreStaleManagedBorderUpdate(target: target, focusedFrame: focusedFrame) else {
            return
        }
        let preferredFrame: CGRect? = if let target,
                                         target.isManaged,
                                         focusedFrame?.token == target.token {
            focusedFrame?.frame
        } else {
            fallbackPreferredFrame
        }
        _ = controller.renderKeyboardFocusBorder(
            for: target,
            preferredFrame: preferredFrame,
            policy: .direct
        )
    }

    private func applyCoordinatedBorderUpdate(_ focusedFrame: LayoutFocusedFrame?) {
        guard let controller = refreshController.controller else { return }
        let target = resolvedBorderRenderTarget(controller: controller, focusedFrame: focusedFrame)
        let fallbackPreferredFrame: CGRect?
        if let target, target.isManaged {
            fallbackPreferredFrame = controller.preferredKeyboardFocusFrame(for: target.token)
        } else {
            fallbackPreferredFrame = nil
        }
        if target?.isManaged == true,
           focusedFrame == nil,
           fallbackPreferredFrame == nil
        {
            controller.borderManager.hideBorder()
            return
        }
        guard !shouldIgnoreStaleManagedBorderUpdate(target: target, focusedFrame: focusedFrame) else {
            return
        }
        let preferredFrame: CGRect? = if let target,
                                         target.isManaged,
                                         focusedFrame?.token == target.token {
            focusedFrame?.frame
        } else {
            fallbackPreferredFrame
        }
        _ = controller.renderKeyboardFocusBorder(
            for: target,
            preferredFrame: preferredFrame,
            policy: .coordinated
        )
    }

    private func shouldIgnoreStaleManagedBorderUpdate(
        target: KeyboardFocusTarget?,
        focusedFrame: LayoutFocusedFrame?
    ) -> Bool {
        guard let target,
              target.isManaged,
              let focusedFrame
        else {
            return false
        }

        return focusedFrame.token != target.token
    }

    private func resolvedBorderRenderTarget(
        controller: WMController,
        focusedFrame: LayoutFocusedFrame?
    ) -> KeyboardFocusTarget? {
        let currentTarget = controller.currentKeyboardFocusTargetForRendering()
        guard let focusedFrame,
              controller.workspaceManager.pendingFocusedToken == focusedFrame.token
        else {
            return currentTarget
        }

        return controller.managedKeyboardFocusTarget(for: focusedFrame.token) ?? currentTarget
    }
}
