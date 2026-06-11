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
        var workspaceId: WorkspaceDescriptor.ID
        let layoutType: LayoutType
        let removedNodeId: NodeId?
        let niriOldFrames: [WindowToken: CGRect]
        let shouldRecoverFocus: Bool
        let allowsPreferredRecoveryToken: Bool
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
        var postLayoutActions: [RefreshPostLayoutAction] = []
        var windowRemovalPayloads: [WindowRemovalPayload] = []
        var followUpRefresh: FollowUpRefresh?
        var needsVisibilityReconciliation: Bool = false
        var visibilityReason: RefreshReason?

        init(
            kind: ScheduledRefreshKind,
            reason: RefreshReason,
            affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = [],
            postLayout: RefreshPostLayoutAction? = nil,
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

    private struct LayoutPlanExecutionResult {
        var didExecute = false
        var rejectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        var acceptedRevisions: [WorkspaceDescriptor.ID: AcceptedRuntimeRevision] = [:]
    }

    private struct CurrentLayoutPlans {
        var plans: [WorkspaceLayoutPlan] = []
        var rejectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
    }

    weak var controller: WMController?
    static let hiddenWindowEdgeRevealEpsilon: CGFloat = 1.0
    private static let delayedRevealVerificationDelay: Duration = .milliseconds(50)

    enum HideReason {
        case workspaceInactive
        case layoutTransient
        case scratchpad
    }

    private enum HiddenRevealOperation {
        case none
        case positionPlan(WindowPositionPlan)
        case asyncFrame(CGRect)
    }

    private enum HiddenRevealTerminalOutcome {
        case success
        case delayedVerification
        case failure
    }

    private struct PendingRevealTransaction {
        let id: UInt64
        var token: WindowToken
        var pid: pid_t
        var windowId: Int
        var workspaceId: WorkspaceDescriptor.ID
        var runtimeRevision: RuntimeRevision
        let targetFrame: CGRect
        let targetMonitorId: Monitor.ID
        let hiddenState: WindowModel.HiddenState
        var postSuccessActions: [RefreshPostLayoutAction]
        var delayedVerificationScheduled: Bool = false
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
        var refreshGeneration: UInt64 = 0
    }

    var layoutState = LayoutState()
    private var activeFrameContext: RefreshFrameContext?
    private var nextPendingRevealTransactionId: UInt64 = 1
    private var pendingRevealTransactionsByWindowId: [Int: PendingRevealTransaction] = [:]
    private var pendingRevealVerificationTasksByWindowId: [Int: Task<Void, Never>] = [:]
    private var nativeFullscreenRestoredFrameApplyTokens: Set<WindowToken> = []

    func fastFrame(for token: WindowToken, axRef: AXWindowRef) -> CGRect? {
        activeFrameContext?.fastFrame(for: token, axRef: axRef)
            ?? AXWindowService.framePreferFast(axRef)
    }

    private(set) lazy var niriHandler = NiriLayoutHandler(controller: controller)
    private(set) lazy var dwindleHandler = DwindleLayoutHandler(controller: controller)
    private lazy var diffExecutor = LayoutDiffExecutor(refreshController: self)

    var isDiscoveryInProgress: Bool {
        layoutState.isFullEnumerationInProgress
    }

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
        controller?.surfaceReconciler.reconcileNow()
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

        guard let displayLink = getOrCreateDisplayLink(for: targetDisplayId) else { return }
        guard niriHandler.registerScrollAnimation(workspaceId, on: targetDisplayId) else {
            return
        }
        displayLink.add(to: .main, forMode: .common)
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

        guard dwindleHandler.registerDwindleAnimation(workspaceId, monitor: monitor, on: targetDisplayId)
        else { return }

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
            case .niri,
                 .defaultLayout:
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

    @discardableResult
    private func executeLayoutPlans(_ plans: [WorkspaceLayoutPlan]) -> LayoutPlanExecutionResult {
        var result = LayoutPlanExecutionResult()
        for plan in plans {
            if let acceptedRevision = executeLayoutPlanReturningAcceptedRevision(plan) {
                result.didExecute = true
                result.acceptedRevisions[plan.workspaceId] = acceptedRevision
            } else {
                result.rejectedWorkspaceIds.insert(plan.workspaceId)
            }
        }
        return result
    }

    private func currentLayoutPlans(
        _ plans: [WorkspaceLayoutPlan],
        controller: WMController
    ) -> CurrentLayoutPlans {
        var current = CurrentLayoutPlans()
        current.plans.reserveCapacity(plans.count)
        for plan in plans {
            if controller.workspaceManager.isRuntimeRevisionCurrent(
                plan.runtimeRevision,
                for: plan.workspaceId,
                domains: .layoutCommit
            ) {
                current.plans.append(plan)
            } else {
                current.rejectedWorkspaceIds.insert(plan.workspaceId)
            }
        }
        return current
    }

    @discardableResult
    func executeLayoutPlan(_ plan: WorkspaceLayoutPlan) -> Bool {
        executeLayoutPlanReturningAcceptedRevision(plan) != nil
    }

    func executeLayoutPlanReturningAcceptedRevision(_ plan: WorkspaceLayoutPlan) -> AcceptedRuntimeRevision? {
        guard let controller else { return nil }
        guard controller.workspaceManager.isRuntimeRevisionCurrent(
            plan.runtimeRevision,
            for: plan.workspaceId,
            domains: .layoutCommit
        ) else {
            return nil
        }

        let focusRevisionAccepted = controller.workspaceManager.isRuntimeRevisionCurrent(
            plan.runtimeRevision,
            for: plan.workspaceId,
            domains: .focusCommit
        )
        var acceptedRevision = controller.workspaceManager.runtimeRevision(for: plan.workspaceId)
        controller.withRuntimeFrameJobCancellationSuppressed {
            applySessionPatch(plan.sessionPatch)
            diffExecutor.execute(plan)
            controller.workspaceManager.setNiriRestorePlacements(plan.niriRestorePlacements)
        }
        applyAnimationDirectives(
            plan.animationDirectives,
            workspaceId: plan.workspaceId,
            focusRevisionAccepted: focusRevisionAccepted
        )
        acceptedRevision = controller.workspaceManager.runtimeRevision(for: plan.workspaceId)
        controller.surfaceReconciler.noteWorldChanged()
        return AcceptedRuntimeRevision(
            before: plan.runtimeRevision,
            after: acceptedRevision,
            domains: focusRevisionAccepted ? .layoutCommit.union(.focusCommit) : .layoutCommit
        )
    }

    private func executeRefreshExecutionPlan(_ plan: RefreshExecutionPlan, generation: UInt64) async -> Bool {
        guard let controller else { return false }
        guard isCurrentRefreshGeneration(generation) else { return false }

        let currentPlans = currentLayoutPlans(plan.workspacePlans, controller: controller)
        var rejectedWorkspaceIds = currentPlans.rejectedWorkspaceIds
        if !plan.workspacePlans.isEmpty, currentPlans.plans.isEmpty {
            enqueueRefresh(
                staleLayoutRefresh(
                    affectedWorkspaceIds: currentPlans.rejectedWorkspaceIds,
                    postLayoutActions: plan.postLayoutActions
                )
            )
            layoutState.didExecuteRefreshExecutionPlan = true
            if var activeRefresh = layoutState.activeRefresh {
                activeRefresh.postLayoutActions.removeAll()
                activeRefresh.followUpRefresh = nil
                activeRefresh.needsVisibilityReconciliation = false
                layoutState.activeRefresh = activeRefresh
            }
            return true
        }

        activeFrameContext = RefreshFrameContext()
        defer { activeFrameContext = nil }

        // Rebuild the inactive-workspace window set BEFORE executing layout plans
        // so that applyFramesParallel (inside executeLayoutPlans) uses the correct
        // active/inactive classification. Without this, windows on a newly-active
        // workspace are still marked inactive from the previous cycle, causing their
        // frame writes to be silently skipped and leaving blank gaps on screen.
        var currentEffectActiveWorkspaceIds: Set<WorkspaceDescriptor.ID>?
        if plan.effects.visibility != nil {
            let activeWorkspaceIds = currentActiveWorkspaceIds()
            currentEffectActiveWorkspaceIds = activeWorkspaceIds
            rebuildInactiveWorkspaceWindowSet(activeWorkspaceIds: activeWorkspaceIds)
        }

        let layoutResult = executeLayoutPlans(currentPlans.plans)
        var acceptedRevisions = layoutResult.acceptedRevisions
        if !plan.workspacePlans.isEmpty, !layoutResult.didExecute {
            return false
        }
        if !layoutResult.rejectedWorkspaceIds.isEmpty {
            rejectedWorkspaceIds.formUnion(layoutResult.rejectedWorkspaceIds)
        }

        layoutState.didExecuteRefreshExecutionPlan = true

        if plan.effects.visibility != nil {
            let activeWorkspaceIds = currentEffectActiveWorkspaceIds ?? currentActiveWorkspaceIds()
            currentEffectActiveWorkspaceIds = activeWorkspaceIds
            controller.withRuntimeFrameJobCancellationSuppressed {
                restoreWorkspaceInactiveFloatingWindows(activeWorkspaceIds: activeWorkspaceIds)
                hideInactiveWorkspaces(activeWorkspaceIds: activeWorkspaceIds)
            }
            for workspaceId in Array(acceptedRevisions.keys) {
                guard let accepted = acceptedRevisions[workspaceId] else { continue }
                acceptedRevisions[workspaceId] = AcceptedRuntimeRevision(
                    before: accepted.before,
                    after: controller.workspaceManager.runtimeRevision(for: workspaceId),
                    domains: accepted.domains
                )
            }
        }

        if !rejectedWorkspaceIds.isEmpty {
            let stalePostLayoutActions = plan.postLayoutActions.map {
                $0.refreshingAcceptedRevisions(acceptedRevisions)
            }
            enqueueRefresh(
                staleLayoutRefresh(
                    affectedWorkspaceIds: rejectedWorkspaceIds,
                    postLayoutActions: stalePostLayoutActions
                )
            )
        }

        let activeWorkspaceIdsForFocusValidation = currentEffectActiveWorkspaceIds ?? currentActiveWorkspaceIds()
        for workspaceId in plan.effects.focusValidationWorkspaceIds
            where activeWorkspaceIdsForFocusValidation.contains(workspaceId)
            && !rejectedWorkspaceIds.contains(workspaceId)
        {
            let preferredRecoveryToken = plan.effects.focusValidationPreferredTokens[workspaceId]
            controller.ensureFocusedTokenValid(
                in: workspaceId,
                preferredRecoveryToken: preferredRecoveryToken
            )
        }

        let acceptedPostLayoutActions = plan.postLayoutActions.map {
            $0.refreshingAcceptedRevisions(acceptedRevisions)
        }
        for postLayoutAction in acceptedPostLayoutActions
            where !postLayoutAction.hasWorkspace(in: rejectedWorkspaceIds)
        {
            postLayoutAction.runIfCurrent(using: controller.workspaceManager)
        }

        if plan.effects.updateTabbedOverlays {
            niriHandler.updateTabbedColumnOverlays(forceOrdering: true)
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

        return true
    }

    func buildWindowSnapshots(
        for entries: [WindowModel.Entry],
        resolveConstraints: Bool = true,
        workingFrame: CGRect? = nil
    ) -> [LayoutWindowSnapshot] {
        guard let controller else { return [] }

        var snapshots: [LayoutWindowSnapshot] = []
        snapshots.reserveCapacity(entries.count)

        for entry in entries {
            let layoutReason = controller.workspaceManager.layoutReason(for: entry.token)
            let constraints: WindowSizeConstraints
            if !resolveConstraints || layoutReason == .nativeFullscreen {
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
                if let observedMin = entry.observedMinSize {
                    mergedConstraints.minSize.width = max(mergedConstraints.minSize.width, observedMin.width)
                    mergedConstraints.minSize.height = max(mergedConstraints.minSize.height, observedMin.height)
                }
                mergedConstraints = mergedConstraints.normalized()
            }

            let hiddenState = controller.workspaceManager.hiddenState(for: entry.token)
            let layoutConstraints = resolvedLayoutConstraints(
                for: mergedConstraints,
                layoutReason: layoutReason,
                hiddenState: hiddenState,
                workingFrame: workingFrame
            )

            snapshots.append(
                LayoutWindowSnapshot(
                    token: entry.token,
                    constraints: mergedConstraints,
                    layoutConstraints: layoutConstraints,
                    hiddenState: hiddenState,
                    layoutReason: layoutReason,
                    showsNativeFullscreenPlaceholder: controller.workspaceManager
                        .showsNativeFullscreenPlaceholder(for: entry.token)
                )
            )
        }

        return snapshots
    }

    private func resolvedLayoutConstraints(
        for constraints: WindowSizeConstraints,
        layoutReason: LayoutReason,
        hiddenState: WindowModel.HiddenState?,
        workingFrame: CGRect?
    ) -> WindowSizeConstraints {
        let effectiveConstraints = constraints.normalized()

        if effectiveConstraints.isFixed || layoutReason == .nativeFullscreen {
            return effectiveConstraints
        }

        guard layoutReason == .standard,
              hiddenState == nil,
              let workingFrame
        else {
            return effectiveConstraints.relaxedForOversizedMinimum()
        }

        let tolerance: CGFloat = 0.5
        if effectiveConstraints.minSize.width <= workingFrame.width + tolerance,
           effectiveConstraints.minSize.height <= workingFrame.height + tolerance
        {
            return effectiveConstraints
        }

        return effectiveConstraints.relaxedForOversizedMinimum()
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

        let monitorSnapshot = buildMonitorSnapshot(for: monitor, orientation: orientation)
        let entries = controller.workspaceManager.tiledEntries(in: workspaceId)
        let windows = buildWindowSnapshots(
            for: entries,
            resolveConstraints: resolveConstraints,
            workingFrame: monitorSnapshot.workingFrame
        )

        return WorkspaceRefreshInput(
            workspaceId: workspaceId,
            monitor: monitorSnapshot,
            windows: windows,
            isActiveWorkspace: isActiveWorkspace,
            runtimeRevision: controller.workspaceManager.runtimeRevision(for: workspaceId)
        )
    }

    private func applySessionPatch(_ patch: WorkspaceSessionPatch) {
        controller?.workspaceManager.applySessionPatch(patch)
    }

    private func applyAnimationDirectives(
        _ directives: [AnimationDirective],
        workspaceId: WorkspaceDescriptor.ID,
        focusRevisionAccepted: Bool
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
                      !controller.workspaceManager.hasPendingNativeFullscreenTransition,
                      focusRevisionAccepted
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
                niriHandler.updateTabbedColumnOverlays(forceOrdering: true)
            }
        }
    }

    func cancelActiveAnimations(for workspaceId: WorkspaceDescriptor.ID) {
        niriHandler.cancelActiveAnimations(for: workspaceId)
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
        postLayout: PostLayoutAction? = nil,
        postLayoutDomains: RuntimeRevisionDomain = [.workspace, .layout, .focus, .fullscreen]
    ) {
        assert(reason.requestRoute == .immediateRelayout, "Invalid immediate-relayout reason: \(reason)")
        let postLayoutWorkspaceIds = self.postLayoutWorkspaceIds(for: affectedWorkspaceIds)
        let postLayoutAction = makePostLayoutAction(
            postLayout,
            workspaceIds: postLayoutWorkspaceIds,
            domains: postLayoutDomains
        )
        enqueueRefresh(
            .init(
                kind: .immediateRelayout,
                reason: reason,
                affectedWorkspaceIds: affectedWorkspaceIds,
                postLayout: postLayoutAction
            )
        )
    }

    func requestLayoutCommandRelayout(
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        postLayout: PostLayoutAction? = nil,
        postLayoutDomains: RuntimeRevisionDomain = [.workspace, .layout, .focus, .fullscreen]
    ) {
        assert(!affectedWorkspaceIds.isEmpty, "Layout command relayout must name affected workspaces")
        controller?.workspaceManager.invalidateLayoutRevision(for: affectedWorkspaceIds)
        requestImmediateRelayout(
            reason: .layoutCommand,
            affectedWorkspaceIds: affectedWorkspaceIds,
            postLayout: postLayout,
            postLayoutDomains: postLayoutDomains
        )
    }

    func requestVisibilityRefresh(
        reason: RefreshReason,
        postLayout: PostLayoutAction? = nil
    ) {
        assert(reason.requestRoute == .visibilityRefresh, "Invalid visibility-refresh reason: \(reason)")
        enqueueRefresh(
            .init(
                kind: .visibilityRefresh,
                reason: reason,
                postLayout: makePostLayoutAction(postLayout, workspaceIds: currentActiveWorkspaceIds())
            )
        )
    }

    func requestWindowRemoval(
        workspaceId: WorkspaceDescriptor.ID,
        layoutType: LayoutType,
        removedNodeId: NodeId?,
        niriOldFrames: [WindowToken: CGRect],
        shouldRecoverFocus: Bool,
        allowsPreferredRecoveryToken: Bool = false,
        postLayout: PostLayoutAction? = nil
    ) {
        assert(RefreshReason.windowDestroyed.requestRoute == .windowRemoval, "Invalid window-removal reason")
        enqueueRefresh(
            .init(
                kind: .windowRemoval,
                reason: .windowDestroyed,
                postLayout: makePostLayoutAction(postLayout, workspaceIds: [workspaceId]),
                windowRemovalPayload: .init(
                    workspaceId: workspaceId,
                    layoutType: layoutType,
                    removedNodeId: removedNodeId,
                    niriOldFrames: niriOldFrames,
                    shouldRecoverFocus: shouldRecoverFocus,
                    allowsPreferredRecoveryToken: allowsPreferredRecoveryToken
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

    private func makePostLayoutAction(
        _ postLayout: PostLayoutAction?,
        workspaceIds: Set<WorkspaceDescriptor.ID>,
        domains: RuntimeRevisionDomain = [.workspace, .layout, .focus, .fullscreen]
    ) -> RefreshPostLayoutAction? {
        guard let postLayout else { return nil }
        guard let controller, !workspaceIds.isEmpty else { return nil }
        var revisions: [WorkspaceDescriptor.ID: RuntimeRevision] = [:]
        revisions.reserveCapacity(workspaceIds.count)
        for workspaceId in workspaceIds {
            revisions[workspaceId] = controller.workspaceManager.runtimeRevision(for: workspaceId)
        }
        return RefreshPostLayoutAction(
            workspaceRevisions: revisions,
            domains: domains,
            action: postLayout
        )
    }

    private func acceptedPostLayoutAction(
        _ postLayout: PostLayoutAction?,
        workspaceIds: Set<WorkspaceDescriptor.ID>
    ) -> RefreshPostLayoutAction? {
        guard let action = makePostLayoutAction(postLayout, workspaceIds: workspaceIds),
              let controller,
              action.isCurrent(using: controller.workspaceManager)
        else {
            return nil
        }
        return action
    }

    private func postLayoutWorkspaceIds(
        for affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
    ) -> Set<WorkspaceDescriptor.ID> {
        affectedWorkspaceIds.isEmpty ? currentActiveWorkspaceIds() : affectedWorkspaceIds
    }

    private func staleLayoutRefresh(
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        postLayoutActions: [RefreshPostLayoutAction]
    ) -> ScheduledRefresh {
        var refresh = ScheduledRefresh(
            kind: .relayout,
            reason: .staleLayoutPlan,
            affectedWorkspaceIds: affectedWorkspaceIds
        )
        refresh.postLayoutActions = postLayoutActions.filter { $0.hasWorkspace(in: affectedWorkspaceIds) }
        return refresh
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
                || !dwindleHandler.dwindleAnimationByDisplay.isEmpty
            {
                return
            }
        }
        enqueueRefresh(
            .init(kind: .relayout, reason: reason, affectedWorkspaceIds: affectedWorkspaceIds)
        )
    }

    private func executeScheduledRelayout(refresh: ScheduledRefresh, generation: UInt64) async -> Bool {
        guard !layoutState.isIncrementalRefreshInProgress else { return false }
        guard !layoutState.isImmediateLayoutInProgress else { return false }
        layoutState.isIncrementalRefreshInProgress = true
        defer { layoutState.isIncrementalRefreshInProgress = false }
        return await executeRelayout(
            refresh: refresh,
            route: .relayout,
            useScrollAnimationPath: false,
            recoverFocus: true,
            generation: generation
        )
    }

    private func executeRelayout(
        refresh: ScheduledRefresh,
        route: RefreshRoute,
        useScrollAnimationPath: Bool,
        recoverFocus: Bool,
        generation: UInt64
    ) async -> Bool {
        guard let controller else { return false }
        guard isCurrentRefreshGeneration(generation) else { return false }

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
            guard isCurrentRefreshGeneration(generation) else { return false }
            return await executeRefreshExecutionPlan(plan, generation: generation)
        } catch {
            return false
        }
    }

    private func executeVisibilityRefresh(refresh: ScheduledRefresh, generation: UInt64) async -> Bool {
        guard let controller else { return false }
        guard isCurrentRefreshGeneration(generation) else { return false }

        if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
            return false
        }

        var plan = buildVisibilityExecutionPlan()
        applyRefreshMetadata(refresh, to: &plan)
        guard !Task.isCancelled else { return false }
        guard isCurrentRefreshGeneration(generation) else { return false }
        return await executeRefreshExecutionPlan(plan, generation: generation)
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

    private func executeImmediateRelayout(refresh: ScheduledRefresh, generation: UInt64) async -> Bool {
        guard !layoutState.isImmediateLayoutInProgress else { return false }
        layoutState.isImmediateLayoutInProgress = true
        defer { layoutState.isImmediateLayoutInProgress = false }
        return await executeRelayout(
            refresh: refresh,
            route: .immediateRelayout,
            useScrollAnimationPath: !niriHandler.scrollAnimationByDisplay.isEmpty,
            recoverFocus: false,
            generation: generation
        )
    }

    private func executeWindowRemoval(refresh: ScheduledRefresh, generation: UInt64) async -> Bool {
        let payloads = refresh.windowRemovalPayloads
        guard let controller else { return false }
        guard isCurrentRefreshGeneration(generation) else { return false }
        if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
            return false
        }

        do {
            var plan = try await buildWindowRemovalExecutionPlan(payloads: payloads)
            applyRefreshMetadata(refresh, to: &plan)
            try Task.checkCancellation()
            guard isCurrentRefreshGeneration(generation) else { return false }
            return await executeRefreshExecutionPlan(plan, generation: generation)
        } catch {
            return false
        }
    }

    func resetState() {
        layoutState.activeRefreshTask?.cancel()
        layoutState.activeRefreshTask = nil
        layoutState.activeRefresh = nil
        layoutState.pendingRefresh = nil
        layoutState.didExecuteRefreshExecutionPlan = false
        layoutState.refreshGeneration &+= 1
        for (_, task) in pendingRevealVerificationTasksByWindowId {
            task.cancel()
        }
        pendingRevealVerificationTasksByWindowId.removeAll()
        pendingRevealTransactionsByWindowId.removeAll()
        nextPendingRevealTransactionId = 1
        nativeFullscreenRestoredFrameApplyTokens.removeAll()

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

    private func executeFullRefresh(refresh: ScheduledRefresh, generation: UInt64) async throws -> Bool {
        layoutState.isFullEnumerationInProgress = true
        defer { layoutState.isFullEnumerationInProgress = false }

        guard let controller else { return false }
        guard isCurrentRefreshGeneration(generation) else { return false }
        controller.axEventHandler.resetManagedReplacementState()

        if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
            return false
        }

        var plan = try await buildFullRefreshExecutionPlan()
        applyRefreshMetadata(refresh, to: &plan)
        try Task.checkCancellation()
        guard isCurrentRefreshGeneration(generation) else { return false }
        return await executeRefreshExecutionPlan(plan, generation: generation)
    }

    func updateTabbedColumnOverlays() {
        niriHandler.updateTabbedColumnOverlays()
    }

    func selectTabInNiri(
        info: TabbedColumnOverlayInfo,
        visualIndex: Int,
        expectedToken: WindowToken?
    ) {
        niriHandler.selectTabInNiri(
            info: info,
            visualIndex: visualIndex,
            expectedToken: expectedToken
        )
    }

    private func applyRefreshMetadata(_ refresh: ScheduledRefresh, to plan: inout RefreshExecutionPlan) {
        if !refresh.postLayoutActions.isEmpty {
            plan.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
        }

        if refresh.kind != .visibilityRefresh, refresh.needsVisibilityReconciliation {
            plan.effects.requestWorkspaceBarRefresh = true
            plan.effects.updateTabbedOverlays = true
        }
    }

    private func buildVisibilityExecutionPlan() -> RefreshExecutionPlan {
        var effects = RefreshExecutionEffects()
        effects.requestWorkspaceBarRefresh = true
        effects.updateTabbedOverlays = true
        return RefreshExecutionPlan(effects: effects)
    }

    private func buildRelayoutExecutionPlan(
        useScrollAnimationPath: Bool,
        recoverFocus: Bool,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
    ) async throws -> RefreshExecutionPlan {
        guard let controller else { return .init() }

        let activeWorkspaceIds = currentActiveWorkspaceIds()
        let layoutWorkspaceIds = affectedWorkspaceIds.isEmpty
            ? activeWorkspaceIds
            : liveLayoutWorkspaceIds(affectedWorkspaceIds, controller: controller)
        if !affectedWorkspaceIds.isEmpty, layoutWorkspaceIds.isEmpty {
            return .init()
        }
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
        effects.visibility = .init()
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
        var workspacesAllowingPreferredRecovery: Set<WorkspaceDescriptor.ID> = []
        var niriRemovalSeeds: [WorkspaceDescriptor.ID: NiriWindowRemovalSeed] = [:]

        for payload in payloads {
            switch payload.layoutType {
            case .dwindle:
                dwindleWorkspaces.insert(payload.workspaceId)
            case .niri,
                 .defaultLayout:
                var removedNodeIds = niriRemovalSeeds[payload.workspaceId]?.removedNodeIds ?? []
                if let removedNodeId = payload.removedNodeId {
                    removedNodeIds.append(removedNodeId)
                }
                let existingOldFrames = niriRemovalSeeds[payload.workspaceId]?.oldFrames ?? [:]
                let mergedOldFrames = existingOldFrames.merging(payload.niriOldFrames) { current, _ in current }
                niriRemovalSeeds[payload.workspaceId] = NiriWindowRemovalSeed(
                    removedNodeIds: removedNodeIds,
                    oldFrames: mergedOldFrames
                )
            }

            if payload.shouldRecoverFocus {
                focusedWorkspacesToRecover.insert(payload.workspaceId)
            }
            if payload.allowsPreferredRecoveryToken {
                workspacesAllowingPreferredRecovery.insert(payload.workspaceId)
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

        let focusValidationPreferredTokens = workspacePlans.reduce(
            into: [WorkspaceDescriptor.ID: WindowToken]()
        ) { result, plan in
            guard let rememberedFocusToken = plan.sessionPatch.rememberedFocusToken,
                  focusValidationWorkspaceIds.contains(plan.workspaceId),
                  workspacesAllowingPreferredRecovery.contains(plan.workspaceId)
            else {
                return
            }
            result[plan.workspaceId] = rememberedFocusToken
        }

        var effects = RefreshExecutionEffects()
        effects.visibility = .init()
        effects.requestWorkspaceBarRefresh = true
        effects.updateTabbedOverlays = updateTabbedOverlays
        effects.focusValidationWorkspaceIds = focusValidationWorkspaceIds
        effects.focusValidationPreferredTokens = focusValidationPreferredTokens

        return RefreshExecutionPlan(workspacePlans: workspacePlans, effects: effects)
    }

    private func buildFullRefreshExecutionPlan() async throws -> RefreshExecutionPlan {
        guard let controller else { return .init() }

        let rescanEpochDomains: RuntimeRevisionDomain = .layoutCommit
        let rescanEpoch = controller.workspaceManager.runtimeEpoch(for: rescanEpochDomains)
        let hadNativeFullscreenLifecycleContextAtStart = controller.workspaceManager.hasNativeFullscreenLifecycleContext
        let enumerationSnapshot = await controller.axManager.fullRescanEnumerationSnapshot()
        try Task.checkCancellation()
        guard controller.workspaceManager.isRuntimeEpochCurrent(rescanEpoch, domains: rescanEpochDomains) else {
            requestFullRescan(reason: .staleFullRescan)
            throw CancellationError()
        }
        let windows = enumerationSnapshot.windows
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
            let appFullscreen = AXWindowService.isFullscreen(ax)
            let evaluation = controller.evaluateWindowDisposition(
                axRef: ax,
                pid: pid,
                appFullscreen: appFullscreen
            )
            let decision = evaluation.decision
            var existingEntry = controller.workspaceManager.entry(for: token)
            let createPlacementContext = existingEntry == nil
                ? controller.axEventHandler.pendingCreatePlacementContext(for: winId)
                : nil
            let temporarilyUnavailableRecord: WorkspaceManager.NativeFullscreenRecord? = if let existingEntry,
                                                                                            let record = controller
                                                                                            .workspaceManager
                                                                                            .nativeFullscreenRecord(
                                                                                                for: existingEntry
                                                                                                    .token
                                                                                            ),
                                                                                            record
                                                                                            .availability ==
                                                                                            .temporarilyUnavailable
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
            let replacementWorkspace = controller.resolvedWorkspaceId(
                for: evaluation,
                axRef: ax,
                existingEntry: existingEntry,
                fallbackWorkspaceId: focusedWorkspaceId,
                restrictWorkspaceRuleToPlacementMonitor: false,
                createPlacementContext: createPlacementContext
            )
            var restoredNativeFullscreenReplacement = false
            if controller.workspaceAssignment(pid: pid, windowId: winId) == nil,
               controller.axEventHandler.restoreNativeFullscreenReplacementIfNeeded(
                   token: token,
                   windowId: UInt32(winId),
                   axRef: ax,
                   workspaceId: replacementWorkspace,
                   appFullscreen: appFullscreen
               )
            {
                restoredNativeFullscreenReplacement = true
                seenKeys.insert(token)
                existingEntry = controller.workspaceManager.entry(for: token)
                controller.axEventHandler.discardCreatePlacementContext(for: winId)
            }
            let shouldPreservePreFullscreenState = existingEntry.map { existingEntry in
                !appFullscreen
                    && (
                        controller.workspaceManager.nativeFullscreenRecord(for: existingEntry.token) != nil
                            || existingEntry.layoutReason == .nativeFullscreen
                    )
            } ?? false
            let effectiveTrackedMode: TrackedWindowMode?
            if shouldPreservePreFullscreenState {
                effectiveTrackedMode = existingEntry?.mode
            } else if restoredNativeFullscreenReplacement {
                effectiveTrackedMode = controller.trackedModeForLifecycle(
                    decision: decision,
                    existingEntry: existingEntry
                )
            } else {
                effectiveTrackedMode = controller.trackedModePreservingAutomaticFallbackState(
                    decision: decision,
                    existingEntry: existingEntry,
                    context: .automatic
                )
            }

            guard let trackedMode = effectiveTrackedMode else {
                if existingEntry != nil {
                    decisionBasedRemovals.append(token)
                } else {
                    controller.axEventHandler.discardCreatePlacementContext(for: winId)
                }
                continue
            }

            let structuralReplacementWorkspaceId = existingEntry == nil
                ? controller.axEventHandler.structuralReplacementWorkspaceIdForCreate(
                    token: token,
                    bundleId: bundleId ?? evaluation.facts.ax.bundleId,
                    mode: trackedMode,
                    facts: evaluation.facts
                )
                : nil
            if existingEntry == nil,
               let windowId = UInt32(exactly: winId),
               controller.axEventHandler.rekeyStructuralManagedReplacementIfNeeded(
                   token: token,
                   windowId: windowId,
                   axRef: ax,
                   bundleId: bundleId ?? evaluation.facts.ax.bundleId,
                   mode: trackedMode,
                   facts: evaluation.facts
               )
            {
                seenKeys.insert(token)
                controller.axEventHandler.discardCreatePlacementContext(for: winId)
                continue
            }

            let defaultWorkspace = controller.resolvedWorkspaceId(
                for: evaluation,
                axRef: ax,
                existingEntry: existingEntry,
                fallbackWorkspaceId: focusedWorkspaceId,
                structuralReplacementWorkspaceId: structuralReplacementWorkspaceId,
                restrictWorkspaceRuleToPlacementMonitor: trackedMode != .floating,
                createPlacementContext: createPlacementContext
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
                controller.axEventHandler.discardCreatePlacementContext(for: winId)
                continue
            }

            let wsForWindow: WorkspaceDescriptor.ID
            let ruleEffects: ManagedWindowRuleEffects
            if let existingEntry {
                if shouldPreservePreFullscreenState {
                    _ = controller.workspaceManager.restoreNativeFullscreenRecord(for: existingEntry.token)
                    markNativeFullscreenRestoredForFrameApply(existingEntry.token)
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
            let admittedMode = oldMode ?? trackedMode
            let parentWindowId = if let windowServer = evaluation.facts.windowServer {
                windowServer.parentId == 0 ? nil : windowServer.parentId
            } else {
                existingEntry?.managedReplacementMetadata?.parentWindowId
            }
            let managedReplacementMetadata = ManagedReplacementMetadata(
                bundleId: evaluation.facts.ax.bundleId ?? bundleId ?? existingEntry?.managedReplacementMetadata?
                    .bundleId,
                workspaceId: wsForWindow,
                mode: admittedMode,
                role: evaluation.facts.ax.role ?? existingEntry?.managedReplacementMetadata?.role,
                subrole: evaluation.facts.ax.subrole ?? existingEntry?.managedReplacementMetadata?.subrole,
                title: evaluation.facts.ax.title ?? existingEntry?.managedReplacementMetadata?.title,
                windowLevel: evaluation.facts.windowServer?.level ?? existingEntry?.managedReplacementMetadata?
                    .windowLevel,
                parentWindowId: parentWindowId,
                frame: evaluation.facts.windowServer?.frame ?? existingEntry?.managedReplacementMetadata?.frame,
                transientWindowServerEvidence: existingEntry?.managedReplacementMetadata?
                    .transientWindowServerEvidence == true
                    || evaluation.facts.windowServer?.hasTransientSurfaceEvidence == true,
                degradedWindowServerChildEvidence: existingEntry?.managedReplacementMetadata?
                    .degradedWindowServerChildEvidence == true
                    || evaluation.facts.degradedWindowServerChildEvidence
            )

            _ = controller.workspaceManager.addWindow(
                ax,
                pid: pid,
                windowId: winId,
                to: wsForWindow,
                mode: admittedMode,
                ruleEffects: ruleEffects,
                managedReplacementMetadata: managedReplacementMetadata
            )
            if existingEntry == nil {
                controller.axEventHandler.discardCreatePlacementContext(for: winId)
            }

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
            controller.nativeFullscreenPlaceholderManager.remove(token)
            controller.cleanupScratchpadWindowResourcesIfNeeded(for: token)
            controller.axManager.removeWindowState(pid: token.pid, windowId: token.windowId)
            _ = controller.workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
            controller.workspaceManager.clearNonManagedFocusTarget(matching: token)
        }

        let shouldPreserveMissingWindows = shouldPreserveMissingWindowsDuringNativeFullscreen(
            controller: controller,
            hadLifecycleContextAtStart: hadNativeFullscreenLifecycleContextAtStart
        )
        let trackedEntries = controller.workspaceManager.allEntries()
        if shouldPreserveMissingWindows {
            // Native macOS fullscreen moves the app onto its own Space, so visible-window
            // enumeration temporarily excludes the rest of the managed workspace.
            for entry in trackedEntries {
                seenKeys.insert(.init(pid: entry.handle.pid, windowId: entry.windowId))
            }
        } else {
            for entry in trackedEntries
                where controller.hiddenAppPIDs.contains(entry.handle.pid)
                || controller.workspaceManager.layoutReason(for: entry.token) == .macosHiddenApp
                || controller.workspaceManager.layoutReason(for: entry.token) == .nativeFullscreen
            {
                seenKeys.insert(.init(pid: entry.handle.pid, windowId: entry.windowId))
            }

            for entry in trackedEntries
                where enumerationSnapshot.failedPIDs.contains(entry.handle.pid)
            {
                seenKeys.insert(.init(pid: entry.handle.pid, windowId: entry.windowId))
            }

            preserveScratchpadHiddenWindowsDuringFullRescan(
                trackedEntries,
                seenKeys: &seenKeys
            )
        }

        let scratchpadTokenBeforeRemove = controller.workspaceManager.scratchpadToken()
        let removedEntries = controller.workspaceManager.removeMissing(keys: seenKeys, requiredConsecutiveMisses: 2)
        for entry in removedEntries {
            controller.nativeFullscreenPlaceholderManager.remove(entry.token)
            controller.axManager.removeWindowState(pid: entry.pid, windowId: entry.windowId)
            controller.workspaceManager.clearNonManagedFocusTarget(matching: entry.token)
        }
        if let scratchpadTokenBeforeRemove,
           controller.workspaceManager.entry(for: scratchpadTokenBeforeRemove) == nil
        {
            controller.cleanupScratchpadWindowResources(for: scratchpadTokenBeforeRemove)
        }
        if !shouldPreserveMissingWindows {
            controller.workspaceManager.garbageCollectUnusedWorkspaces(focusedWorkspaceId: focusedWorkspaceId)
        }

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
        effects.visibility = .init()
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
        controller: WMController,
        hadLifecycleContextAtStart: Bool
    ) -> Bool {
        hadLifecycleContextAtStart || controller.workspaceManager.hasNativeFullscreenLifecycleContext
    }

    private enum ScratchpadRescanEvidence {
        case visibleFrame
        case orderedOut
        case orderedIn
        case windowServer
        case pinnedAX
    }

    private struct ScratchpadRescanObservation {
        let evidence: ScratchpadRescanEvidence
        let visibleFrame: CGRect?
    }

    private func preserveScratchpadHiddenWindowsDuringFullRescan(
        _ entries: [WindowModel.Entry],
        seenKeys: inout Set<WindowModel.WindowKey>
    ) {
        guard let controller else { return }
        for entry in entries where controller.workspaceManager.hiddenState(for: entry.token)?.isScratchpad == true {
            let observation = scratchpadRescanObservation(for: entry)
            switch observation?.evidence {
            case .visibleFrame:
                if pendingRevealTransactionsByWindowId[entry.windowId]?.token == entry.token,
                   let visibleFrame = observation?.visibleFrame
                {
                    finalizePendingRevealTransactionSuccess(
                        forWindowId: entry.windowId,
                        confirmedFrame: visibleFrame
                    )
                } else {
                    cancelPendingScratchpadReveal(for: entry.token)
                    controller.workspaceManager.setHiddenState(nil, for: entry.token)
                    controller.axManager.unsuppressFrameWrites([(entry.pid, entry.windowId)])
                }
                seenKeys.insert(entry.token)
            case .orderedOut,
                 .orderedIn,
                 .windowServer,
                 .pinnedAX:
                seenKeys.insert(entry.token)
            case nil:
                break
            }
        }
    }

    private func scratchpadRescanObservation(for entry: WindowModel.Entry) -> ScratchpadRescanObservation? {
        guard controller != nil else { return nil }
        guard let windowId = UInt32(exactly: entry.windowId) else { return nil }

        if let windowInfo = SkyLight.shared.queryWindowInfo(windowId) {
            guard windowInfo.pid == entry.pid else { return nil }
            if let visibleFrame = scratchpadVisibleWindowServerFrame(windowInfo.frame, for: entry) {
                return ScratchpadRescanObservation(evidence: .visibleFrame, visibleFrame: visibleFrame)
            }
            return ScratchpadRescanObservation(evidence: .windowServer, visibleFrame: nil)
        }

        if let observedFrame = observedWindowFrame(entry),
           scratchpadFrameIsVisible(observedFrame, for: entry)
        {
            return ScratchpadRescanObservation(evidence: .visibleFrame, visibleFrame: observedFrame)
        }

        switch SkyLight.shared.isWindowOrderedIn(windowId) {
        case .some(true):
            return ScratchpadRescanObservation(evidence: .orderedIn, visibleFrame: nil)
        case .some(false):
            return ScratchpadRescanObservation(evidence: .orderedOut, visibleFrame: nil)
        case nil:
            break
        }

        if AXWindowService.pinnedWindowId(for: windowId) == CGWindowID(windowId) {
            return ScratchpadRescanObservation(evidence: .pinnedAX, visibleFrame: nil)
        }

        return nil
    }

    private func scratchpadVisibleWindowServerFrame(_ frame: CGRect, for entry: WindowModel.Entry) -> CGRect? {
        if scratchpadFrameIsVisible(frame, for: entry) {
            return frame
        }
        let appKitFrame = ScreenCoordinateSpace.toAppKit(rect: frame)
        return scratchpadFrameIsVisible(appKitFrame, for: entry) ? appKitFrame : nil
    }

    private func scratchpadFrameIsVisible(_ frame: CGRect, for entry: WindowModel.Entry) -> Bool {
        guard let controller else { return false }
        if let floatingFrame = controller.workspaceManager.floatingState(for: entry.token)?.lastFrame,
           frame.approximatelyEqual(to: floatingFrame, tolerance: FrameTolerance.screenMatch)
        {
            return true
        }
        return controller.workspaceManager.monitors.contains { monitor in
            frame.intersects(monitor.visibleFrame)
                && monitor.visibleFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
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
                continue
            }
            let layoutType = controller.settings.layoutType(for: ws.name)
            switch layoutType {
            case .dwindle:
                dwindleWorkspaces.insert(wsId)
            case .niri,
                 .defaultLayout:
                niriWorkspaces.insert(wsId)
            }
        }

        return (niriWorkspaces, dwindleWorkspaces)
    }

    private func liveLayoutWorkspaceIds(
        _ workspaceIds: Set<WorkspaceDescriptor.ID>,
        controller: WMController
    ) -> Set<WorkspaceDescriptor.ID> {
        var liveWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        liveWorkspaceIds.reserveCapacity(workspaceIds.count)
        for workspaceId in workspaceIds
            where controller.workspaceManager.descriptor(for: workspaceId) != nil
            && controller.workspaceManager.monitor(for: workspaceId) != nil
        {
            liveWorkspaceIds.insert(workspaceId)
        }
        return liveWorkspaceIds
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
        case (.immediateRelayout, .relayout):
            mergePendingRefresh(refresh)
        case (.immediateRelayout, .visibilityRefresh):
            mergePendingRefresh(refresh)
        case (.immediateRelayout, .windowRemoval):
            mergePendingRefresh(refresh)
            layoutState.activeRefreshTask?.cancel()
        case (.relayout, .fullRescan),
             (.relayout, .immediateRelayout),
             (.relayout, .windowRemoval):
            mergePendingRefresh(refresh)
            layoutState.activeRefreshTask?.cancel()
        case (.relayout, .relayout):
            mergePendingRefresh(refresh)
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

        pendingRefresh.affectedWorkspaceIds = mergedAffectedWorkspaceIds(
            pendingRefresh.affectedWorkspaceIds,
            existingAffectedWorkspaceIds
        )
        pendingRefresh.affectedWorkspaceIds = mergedAffectedWorkspaceIds(
            pendingRefresh.affectedWorkspaceIds,
            refresh.affectedWorkspaceIds
        )

        layoutState.pendingRefresh = pendingRefresh
    }

    private func startNextRefreshIfNeeded() {
        guard layoutState.activeRefreshTask == nil, let refresh = layoutState.pendingRefresh else { return }

        layoutState.pendingRefresh = nil
        layoutState.activeRefresh = refresh
        layoutState.didExecuteRefreshExecutionPlan = false
        let refreshGeneration = layoutState.refreshGeneration
        layoutState.activeRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let didComplete = await self.execute(refresh, generation: refreshGeneration)
            self.finishRefresh(refresh, didComplete: didComplete, generation: refreshGeneration)
        }
    }

    private func isCurrentRefreshGeneration(_ generation: UInt64) -> Bool {
        generation == layoutState.refreshGeneration
    }

    private func execute(_ refresh: ScheduledRefresh, generation: UInt64) async -> Bool {
        guard isCurrentRefreshGeneration(generation) else { return false }
        do {
            switch refresh.kind {
            case .fullRescan:
                return try await executeFullRefresh(refresh: refresh, generation: generation)
            case .relayout:
                let policy = refresh.reason.relayoutSchedulingPolicy
                if policy.debounceInterval > 0 {
                    try await Task.sleep(nanoseconds: policy.debounceInterval)
                }
                try Task.checkCancellation()
                guard isCurrentRefreshGeneration(generation) else { return false }
                return await executeScheduledRelayout(refresh: refresh, generation: generation)
            case .immediateRelayout:
                return await executeImmediateRelayout(refresh: refresh, generation: generation)
            case .visibilityRefresh:
                return await executeVisibilityRefresh(refresh: refresh, generation: generation)
            case .windowRemoval:
                return await executeWindowRemoval(refresh: refresh, generation: generation)
            }
        } catch {
            return false
        }
    }

    private func finishRefresh(_ refresh: ScheduledRefresh, didComplete: Bool, generation: UInt64) {
        guard generation == layoutState.refreshGeneration else { return }
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
                    postLayoutAction.runIfCurrent(using: controller.workspaceManager)
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

    private func mergeWindowRemovalPayloads(
        _ existingPayloads: [WindowRemovalPayload],
        with incomingPayloads: [WindowRemovalPayload]
    ) -> [WindowRemovalPayload] {
        existingPayloads + incomingPayloads
    }

    private func mergedAffectedWorkspaceIds(
        _ existing: Set<WorkspaceDescriptor.ID>,
        _ incoming: Set<WorkspaceDescriptor.ID>
    ) -> Set<WorkspaceDescriptor.ID> {
        guard !existing.isEmpty, !incoming.isEmpty else { return [] }
        return existing.union(incoming)
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
        case .fullRescan,
             .windowRemoval,
             .immediateRelayout,
             .relayout:
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
        case let (value?, nil),
             let (nil, value?):
            return value
        case let (existing?, incoming?):
            var merged = incoming
            merged.affectedWorkspaceIds = mergedAffectedWorkspaceIds(
                existing.affectedWorkspaceIds,
                incoming.affectedWorkspaceIds
            )
            if existing.kind == .immediateRelayout || incoming.kind == .immediateRelayout {
                if incoming.kind == .immediateRelayout {
                    return merged
                }
                var kept = existing
                kept.affectedWorkspaceIds = mergedAffectedWorkspaceIds(
                    existing.affectedWorkspaceIds,
                    incoming.affectedWorkspaceIds
                )
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

        pendingRefresh.postLayoutActions.insert(contentsOf: refresh.postLayoutActions, at: 0)
        pendingRefresh.affectedWorkspaceIds = mergedAffectedWorkspaceIds(
            pendingRefresh.affectedWorkspaceIds,
            refresh.affectedWorkspaceIds
        )

        if refresh.kind == .fullRescan {
            pendingRefresh.kind = .fullRescan
            pendingRefresh.reason = refresh.reason
        }

        if refresh.kind == .immediateRelayout,
           pendingRefresh.kind != .fullRescan,
           pendingRefresh.kind != .windowRemoval
        {
            pendingRefresh.kind = .immediateRelayout
            pendingRefresh.reason = refresh.reason
        }

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
        controller.niriLayoutHandler.updateTabbedColumnOverlays(forceOrdering: true)
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

    func hasWorkspaceInactiveFloatingWindows(activeWorkspaceIds: Set<WorkspaceDescriptor.ID>) -> Bool {
        guard let controller else { return false }
        for workspaceId in activeWorkspaceIds {
            guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else { continue }
            for entry in controller.workspaceManager.floatingEntries(in: workspaceId)
                where workspaceInactiveFloatingRestoreFrame(for: entry, monitor: monitor) != nil
            {
                return true
            }
        }
        return false
    }

    @discardableResult
    func restoreWorkspaceInactiveFloatingWindows(activeWorkspaceIds: Set<WorkspaceDescriptor.ID>) -> Int {
        guard let controller else { return 0 }
        var frameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []
        var visibleJobs: [(pid: pid_t, windowId: Int)] = []

        for workspaceId in activeWorkspaceIds {
            guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else { continue }
            for entry in controller.workspaceManager.floatingEntries(in: workspaceId) {
                guard let frame = workspaceInactiveFloatingRestoreFrame(for: entry, monitor: monitor) else { continue }
                controller.workspaceManager.setHiddenState(nil, for: entry.token)
                visibleJobs.append((entry.pid, entry.windowId))
                controller.axManager.markWindowActive(entry.windowId)
                controller.axManager.forceApplyNextFrame(for: entry.windowId)
                frameUpdates.append((entry.pid, entry.windowId, frame))
            }
        }

        if !visibleJobs.isEmpty {
            controller.axManager.unsuppressFrameWrites(visibleJobs)
        }
        controller.axManager.applyFramesParallel(frameUpdates)
        return frameUpdates.count
    }

    private func workspaceInactiveFloatingRestoreFrame(
        for entry: WindowModel.Entry,
        monitor: Monitor
    ) -> CGRect? {
        guard let controller else { return nil }
        guard entry.mode == .floating,
              entry.layoutReason == .standard,
              controller.workspaceManager.hiddenState(for: entry.token)?.workspaceInactive == true
        else {
            return nil
        }
        return controller.workspaceManager.resolvedFloatingFrame(for: entry.token, preferredMonitor: monitor)
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
            for entry in snapshot.entries {
                controller.nativeFullscreenPlaceholderManager.remove(entry.token)
            }
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
            guard controller.workspaceManager.layoutReason(for: entry.token) != .nativeFullscreen else {
                continue
            }
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
        case .workspaceInactive,
             .scratchpad:
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

    @discardableResult
    func unhideWindow(
        _ entry: WindowModel.Entry,
        monitor: Monitor,
        onSuccess: PostLayoutAction? = nil
    ) -> Bool {
        guard let controller else { return false }
        guard let hiddenState = controller.workspaceManager.hiddenState(for: entry.token) else {
            controller.axManager.unsuppressFrameWrites([(entry.handle.pid, entry.windowId)])
            return true
        }
        guard hiddenState.workspaceInactive else { return false }

        return executeHiddenReveal(
            entry,
            monitor: monitor,
            hiddenState: hiddenState,
            onSuccess: onSuccess
        )
    }

    @discardableResult
    func restoreScratchpadWindow(
        _ entry: WindowModel.Entry,
        monitor: Monitor,
        onSuccess: PostLayoutAction? = nil
    ) -> Bool {
        guard let controller,
              let hiddenState = controller.workspaceManager.hiddenState(for: entry.token),
              hiddenState.isScratchpad
        else {
            return false
        }

        return executeHiddenReveal(
            entry,
            monitor: monitor,
            hiddenState: hiddenState,
            onSuccess: onSuccess
        )
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

    fileprivate func hasPendingRevealTransaction(for windowId: Int) -> Bool {
        pendingRevealTransactionsByWindowId[windowId] != nil
    }

    fileprivate func pendingRevealTransactionId(forWindowId windowId: Int) -> UInt64? {
        pendingRevealTransactionsByWindowId[windowId]?.id
    }

    fileprivate func shouldUsePendingRevealTransaction(
        for entry: WindowModel.Entry,
        hiddenState: WindowModel.HiddenState
    ) -> Bool {
        !hiddenState.workspaceInactive
            && entry.mode == .floating
            && hiddenState.restoresViaFloatingState
    }

    func beginPendingRevealTransaction(
        for entry: WindowModel.Entry,
        hiddenState: WindowModel.HiddenState,
        targetFrame: CGRect,
        monitor: Monitor,
        onSuccess: PostLayoutAction? = nil
    ) -> UInt64? {
        guard let controller else { return nil }
        let entry = controller.workspaceManager.entry(for: entry.token) ?? entry
        if var pendingTransaction = pendingRevealTransactionsByWindowId[entry.windowId] {
            if let onSuccess = makePostLayoutAction(
                onSuccess,
                workspaceIds: [entry.workspaceId]
            ) {
                if !pendingTransaction.hiddenState.isScratchpad || pendingTransaction.postSuccessActions.isEmpty {
                    pendingTransaction.postSuccessActions.append(onSuccess)
                    pendingRevealTransactionsByWindowId[entry.windowId] = pendingTransaction
                }
            }
            return nil
        }

        let transactionId = nextPendingRevealTransactionId
        pendingRevealTransactionsByWindowId[entry.windowId] = PendingRevealTransaction(
            id: transactionId,
            token: entry.token,
            pid: entry.pid,
            windowId: entry.windowId,
            workspaceId: entry.workspaceId,
            runtimeRevision: controller.workspaceManager.runtimeRevision(for: entry.workspaceId),
            targetFrame: targetFrame,
            targetMonitorId: monitor.id,
            hiddenState: hiddenState,
            postSuccessActions: makePostLayoutAction(
                onSuccess,
                workspaceIds: [entry.workspaceId]
            ).map { [$0] } ?? []
        )
        nextPendingRevealTransactionId &+= 1
        return transactionId
    }

    func rekeyPendingRevealTransaction(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        entry: WindowModel.Entry
    ) {
        let oldWindowId = oldToken.windowId
        let newWindowId = newToken.windowId
        guard oldWindowId != newWindowId || oldToken != newToken else { return }
        guard var transaction = pendingRevealTransactionsByWindowId.removeValue(forKey: oldWindowId) else {
            return
        }

        transaction.token = newToken
        transaction.pid = entry.pid
        transaction.windowId = entry.windowId
        transaction.workspaceId = entry.workspaceId
        if let controller {
            transaction.runtimeRevision = controller.workspaceManager.runtimeRevision(for: entry.workspaceId)
        }
        pendingRevealTransactionsByWindowId[newWindowId] = transaction

        if let verificationTask = pendingRevealVerificationTasksByWindowId.removeValue(forKey: oldWindowId) {
            verificationTask.cancel()
            if transaction.delayedVerificationScheduled {
                scheduleDelayedRevealVerification(forWindowId: newWindowId)
            }
        }
    }

    fileprivate func refreshPendingRevealTransactionRuntimeRevision(
        forWindowId windowId: Int,
        transactionId: UInt64
    ) {
        guard let controller,
              var transaction = pendingRevealTransactionsByWindowId[windowId],
              transaction.id == transactionId
        else {
            return
        }
        transaction.runtimeRevision = controller.workspaceManager.runtimeRevision(for: transaction.workspaceId)
        pendingRevealTransactionsByWindowId[windowId] = transaction
    }

    func cancelPendingScratchpadReveal(for token: WindowToken) {
        guard let transaction = pendingRevealTransactionsByWindowId[token.windowId],
              transaction.token == token,
              transaction.hiddenState.isScratchpad
        else {
            return
        }
        pendingRevealTransactionsByWindowId.removeValue(forKey: token.windowId)
        pendingRevealVerificationTasksByWindowId.removeValue(forKey: token.windowId)?.cancel()
        controller?.axManager.cancelPendingFrameJobs([(transaction.pid, transaction.windowId)])
    }

    func completePendingRevealTransaction(
        with result: AXFrameApplyResult,
        transactionId: UInt64
    ) {
        guard let transaction = pendingRevealTransactionsByWindowId[result.windowId],
              transaction.id == transactionId
        else {
            return
        }

        let outcome = hiddenRevealTerminalOutcome(for: result, transaction: transaction)

        switch outcome {
        case .success:
            finalizePendingRevealTransactionSuccess(
                forWindowId: result.windowId,
                confirmedFrame: result.confirmedFrame,
                transactionId: transaction.id
            )
        case .delayedVerification:
            guard var pendingTransaction = pendingRevealTransactionsByWindowId[result.windowId],
                  !pendingTransaction.delayedVerificationScheduled
            else {
                return
            }
            pendingTransaction.delayedVerificationScheduled = true
            pendingRevealTransactionsByWindowId[result.windowId] = pendingTransaction
            scheduleDelayedRevealVerification(forWindowId: result.windowId)
        case .failure:
            finalizePendingRevealTransactionFailure(
                forWindowId: result.windowId,
                transactionId: transaction.id
            )
        }
    }

    private func hiddenRevealTerminalOutcome(
        for result: AXFrameApplyResult,
        transaction: PendingRevealTransaction
    ) -> HiddenRevealTerminalOutcome {
        if result.confirmedFrame != nil {
            guard let failureReason = result.writeResult.failureReason else {
                return .success
            }
            if isConfirmedRevealFailureTerminal(failureReason) {
                return .failure
            }
            if transaction.hiddenState.isScratchpad {
                return .delayedVerification
            }
            return .success
        }

        guard let failureReason = result.writeResult.failureReason else {
            return .failure
        }

        return isDelayedRevealRecoverable(failureReason) ? .delayedVerification : .failure
    }

    private func isDelayedRevealRecoverable(_ failureReason: AXFrameWriteFailureReason) -> Bool {
        switch failureReason {
        case .verificationMismatch,
             .readbackFailed,
             .sizeWriteFailed,
             .positionWriteFailed:
            return true
        default:
            return false
        }
    }

    private func isConfirmedRevealFailureTerminal(_ failureReason: AXFrameWriteFailureReason) -> Bool {
        switch failureReason {
        case .cancelled,
             .suppressed:
            return true
        default:
            return false
        }
    }

    private func finalizePendingRevealTransactionSuccess(
        forWindowId windowId: Int,
        confirmedFrame: CGRect?,
        transactionId: UInt64? = nil
    ) {
        guard let controller,
              let pendingTransaction = pendingRevealTransactionsByWindowId.removeValue(forKey: windowId)
        else {
            return
        }
        if let transactionId, pendingTransaction.id != transactionId {
            pendingRevealTransactionsByWindowId[windowId] = pendingTransaction
            return
        }
        pendingRevealVerificationTasksByWindowId.removeValue(forKey: windowId)?.cancel()

        guard pendingRevealTransactionIsCurrent(pendingTransaction, using: controller.workspaceManager) else {
            restoreStalePendingRevealSideEffects(pendingTransaction, using: controller)
            requestRelayout(
                reason: .staleLayoutPlan,
                affectedWorkspaceIds: stalePendingRevealWorkspaceIds(pendingTransaction, using: controller)
            )
            return
        }
        let preSuccessRevision = controller.workspaceManager.runtimeRevision(for: pendingTransaction.workspaceId)
        controller.withRuntimeFrameJobCancellationSuppressed {
            controller.workspaceManager.setHiddenState(nil, for: pendingTransaction.token)
        }
        if pendingTransaction.hiddenState.isScratchpad {
            controller.requestWorkspaceBarRefresh()
        }
        if let confirmedFrame {
            controller.axManager.confirmFrameWrite(for: pendingTransaction.windowId, frame: confirmedFrame)
        }
        let acceptedRevisions = acceptedPendingRevealPostSuccessRevisions(
            pendingTransaction,
            preSuccessRevision: preSuccessRevision,
            using: controller
        )
        for action in pendingTransaction.postSuccessActions {
            action
                .refreshingAcceptedRevisions(acceptedRevisions)
                .runIfCurrent(using: controller.workspaceManager)
        }
    }

    private func finalizePendingRevealTransactionFailure(
        forWindowId windowId: Int,
        transactionId: UInt64? = nil
    ) {
        guard let controller,
              let pendingTransaction = pendingRevealTransactionsByWindowId.removeValue(forKey: windowId)
        else {
            return
        }
        if let transactionId, pendingTransaction.id != transactionId {
            pendingRevealTransactionsByWindowId[windowId] = pendingTransaction
            return
        }
        pendingRevealVerificationTasksByWindowId.removeValue(forKey: windowId)?.cancel()
        let frameEntry = [(pendingTransaction.pid, pendingTransaction.windowId)]

        guard pendingRevealTransactionIsCurrent(pendingTransaction, using: controller.workspaceManager) else {
            restoreStalePendingRevealSideEffects(pendingTransaction, using: controller)
            requestRelayout(
                reason: .staleLayoutPlan,
                affectedWorkspaceIds: stalePendingRevealWorkspaceIds(pendingTransaction, using: controller)
            )
            return
        }

        if pendingTransaction.hiddenState.isScratchpad,
           controller.workspaceManager.hiddenState(for: pendingTransaction.token)?.isScratchpad != true
        {
            controller.axManager.unsuppressFrameWrites(frameEntry)
            return
        }

        if pendingTransaction.hiddenState.workspaceInactive {
            controller.withRuntimeFrameJobCancellationSuppressed {
                controller.workspaceManager.setHiddenState(nil, for: pendingTransaction.token)
            }
            controller.axManager.unsuppressFrameWrites(frameEntry)
            return
        }

        if controller.workspaceManager.hiddenState(for: pendingTransaction.token) == nil {
            controller.withRuntimeFrameJobCancellationSuppressed {
                controller.workspaceManager.setHiddenState(
                    pendingTransaction.hiddenState,
                    for: pendingTransaction.token
                )
            }
        }
        if controller.workspaceManager.hiddenState(for: pendingTransaction.token) != nil {
            controller.axManager.suppressFrameWrites(frameEntry)
        }
    }

    private func restoreStalePendingRevealSideEffects(
        _ transaction: PendingRevealTransaction,
        using controller: WMController
    ) {
        let pendingFrameEntry = (pid: transaction.pid, windowId: transaction.windowId)
        guard let entry = controller.workspaceManager.entry(for: transaction.token) else {
            controller.axManager.suppressFrameWrites([pendingFrameEntry])
            return
        }

        let liveFrameEntry = (pid: entry.pid, windowId: entry.windowId)
        let frameEntries = liveFrameEntry.windowId == pendingFrameEntry.windowId
            ? [liveFrameEntry]
            : [pendingFrameEntry, liveFrameEntry]

        guard let hiddenState = controller.workspaceManager.hiddenState(for: transaction.token) else {
            controller.axManager.unsuppressFrameWrites(frameEntries)
            return
        }

        controller.axManager.cancelPendingFrameJobs(frameEntries)
        controller.axManager.suppressFrameWrites(frameEntries)

        let monitor = stalePendingRevealMonitor(
            for: entry,
            hiddenState: hiddenState,
            transaction: transaction,
            using: controller
        )
        hideWindow(
            entry,
            monitor: monitor,
            side: hiddenState.offscreenSide ?? preferredHideSide(for: monitor),
            reason: hideReason(for: hiddenState)
        )
    }

    private func acceptedPendingRevealPostSuccessRevisions(
        _ transaction: PendingRevealTransaction,
        preSuccessRevision: RuntimeRevision,
        using controller: WMController
    ) -> [WorkspaceDescriptor.ID: AcceptedRuntimeRevision] {
        let after = controller.workspaceManager.runtimeRevision(for: transaction.workspaceId)
        var domains: RuntimeRevisionDomain = .layoutCommit
        if transaction.runtimeRevision.matches(preSuccessRevision, domains: .focusCommit) {
            domains.insert(.focus)
        }
        return [
            transaction.workspaceId: AcceptedRuntimeRevision(
                before: transaction.runtimeRevision,
                after: after,
                domains: domains
            )
        ]
    }

    private func stalePendingRevealWorkspaceIds(
        _ transaction: PendingRevealTransaction,
        using controller: WMController
    ) -> Set<WorkspaceDescriptor.ID> {
        var workspaceIds: Set<WorkspaceDescriptor.ID> = [transaction.workspaceId]
        if let currentWorkspaceId = controller.workspaceManager.entry(for: transaction.token)?.workspaceId {
            workspaceIds.insert(currentWorkspaceId)
        }
        return workspaceIds
    }

    private func stalePendingRevealMonitor(
        for entry: WindowModel.Entry,
        hiddenState: WindowModel.HiddenState,
        transaction: PendingRevealTransaction,
        using controller: WMController
    ) -> Monitor {
        hiddenState.referenceMonitorId.flatMap { controller.workspaceManager.monitor(byId: $0) }
            ?? controller.workspaceManager.monitor(byId: transaction.targetMonitorId)
            ?? controller.workspaceManager.monitor(for: entry.workspaceId)
            ?? Monitor.fallback()
    }

    private func hideReason(for hiddenState: WindowModel.HiddenState) -> HideReason {
        switch hiddenState.reason {
        case .workspaceInactive:
            .workspaceInactive
        case .layoutTransient:
            .layoutTransient
        case .scratchpad:
            .scratchpad
        }
    }

    private func pendingRevealTransactionIsCurrent(
        _ transaction: PendingRevealTransaction,
        using workspaceManager: WorkspaceManager
    ) -> Bool {
        workspaceManager.isRuntimeRevisionCurrent(
            transaction.runtimeRevision,
            for: transaction.workspaceId,
            domains: .layoutCommit
        )
    }

    private func scheduleDelayedRevealVerification(forWindowId windowId: Int) {
        pendingRevealVerificationTasksByWindowId[windowId]?.cancel()
        guard let transactionId = pendingRevealTransactionsByWindowId[windowId]?.id else { return }
        pendingRevealVerificationTasksByWindowId[windowId] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.delayedRevealVerificationDelay)
            } catch {
                return
            }
            guard let self else { return }
            let verifiedFrame = self.delayedVerifiedRevealFrame(
                forWindowId: windowId,
                transactionId: transactionId
            )
            if let verifiedFrame {
                self.finalizePendingRevealTransactionSuccess(
                    forWindowId: windowId,
                    confirmedFrame: verifiedFrame,
                    transactionId: transactionId
                )
            } else {
                self.finalizePendingRevealTransactionFailure(
                    forWindowId: windowId,
                    transactionId: transactionId
                )
            }
        }
    }

    private func delayedVerifiedRevealFrame(
        forWindowId windowId: Int,
        transactionId: UInt64
    ) -> CGRect? {
        guard let controller,
              let pendingTransaction = pendingRevealTransactionsByWindowId[windowId],
              pendingTransaction.id == transactionId,
              let entry = controller.workspaceManager.entry(for: pendingTransaction.token),
              let observedFrame = observedWindowFrame(entry)
        else {
            return nil
        }

        let monitor = controller.workspaceManager.monitor(byId: pendingTransaction.targetMonitorId)
            ?? controller.workspaceManager.monitor(for: entry.workspaceId)
        guard let monitor else { return nil }
        guard observedFrame.intersects(monitor.visibleFrame),
              monitor.visibleFrame.contains(CGPoint(x: observedFrame.midX, y: observedFrame.midY))
        else {
            return nil
        }

        return observedFrame
    }

    private func executeHiddenReveal(
        _ entry: WindowModel.Entry,
        monitor: Monitor,
        hiddenState: WindowModel.HiddenState,
        onSuccess: PostLayoutAction? = nil
    ) -> Bool {
        guard let controller else { return false }
        let entry = controller.workspaceManager.entry(for: entry.token) ?? entry
        let frameEntry = [(entry.handle.pid, entry.windowId)]
        switch restoreWindowFromHiddenState(entry, monitor: monitor, hiddenState: hiddenState) {
        case .none:
            if hiddenState.workspaceInactive {
                controller.withRuntimeFrameJobCancellationSuppressed {
                    controller.workspaceManager.setHiddenState(nil, for: entry.token)
                }
                if hiddenState.isScratchpad {
                    controller.requestWorkspaceBarRefresh()
                }
                controller.axManager.unsuppressFrameWrites(frameEntry)
                acceptedPostLayoutAction(
                    onSuccess,
                    workspaceIds: [entry.workspaceId]
                )?.runIfCurrent(using: controller.workspaceManager)
                return true
            } else {
                controller.axManager.suppressFrameWrites(frameEntry)
                return false
            }
        case let .positionPlan(plan):
            applyPositionPlans([plan])
            controller.withRuntimeFrameJobCancellationSuppressed {
                controller.workspaceManager.setHiddenState(nil, for: entry.token)
            }
            if hiddenState.isScratchpad {
                controller.requestWorkspaceBarRefresh()
            }
            controller.axManager.unsuppressFrameWrites(frameEntry)
            acceptedPostLayoutAction(
                onSuccess,
                workspaceIds: [entry.workspaceId]
            )?.runIfCurrent(using: controller.workspaceManager)
            return true
        case let .asyncFrame(frame):
            if !shouldUsePendingRevealTransaction(for: entry, hiddenState: hiddenState) {
                controller.withRuntimeFrameJobCancellationSuppressed {
                    controller.workspaceManager.setHiddenState(nil, for: entry.token)
                }
                if hiddenState.isScratchpad {
                    controller.requestWorkspaceBarRefresh()
                }
                controller.axManager.unsuppressFrameWrites(frameEntry)
                controller.axManager.forceApplyNextFrame(for: entry.windowId)
                controller.axManager.applyFramesParallel([(entry.pid, entry.windowId, frame)])
                acceptedPostLayoutAction(
                    onSuccess,
                    workspaceIds: [entry.workspaceId]
                )?.runIfCurrent(using: controller.workspaceManager)
                return true
            }
            guard let transactionId = beginPendingRevealTransaction(
                for: entry,
                hiddenState: hiddenState,
                targetFrame: frame,
                monitor: monitor,
                onSuccess: onSuccess
            ) else {
                return true
            }
            controller.axManager.unsuppressFrameWrites(frameEntry)
            controller.axManager.forceApplyNextFrame(for: entry.windowId)
            controller.axManager.applyFramesParallel(
                [(entry.pid, entry.windowId, frame)],
                terminalObserver: { [weak self] result in
                    self?.completePendingRevealTransaction(
                        with: result,
                        transactionId: transactionId
                    )
                }
            )
            return true
        }
    }

    private func restoreWindowFromHiddenState(
        _ entry: WindowModel.Entry,
        monitor: Monitor,
        hiddenState: WindowModel.HiddenState
    ) -> HiddenRevealOperation {
        if entry.mode == .floating,
           hiddenState.restoresViaFloatingState,
           let controller,
           let frame = controller.workspaceManager.resolvedFloatingFrame(
               for: entry.token,
               preferredMonitor: monitor
           )
        {
            return .asyncFrame(frame)
        }

        if let plan = makeRestorePositionPlan(
            for: entry,
            monitor: monitor,
            hiddenState: hiddenState
        ) {
            return .positionPlan(plan)
        }

        return .none
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

    private func observedWindowFrame(_ entry: WindowModel.Entry) -> CGRect? {
        fastFrame(for: entry.token, axRef: entry.axRef)
    }

    private func observedWindowOrigin(_ entry: WindowModel.Entry) -> CGPoint? {
        observedWindowFrame(entry)?.origin
    }

    static func hiddenEdgeReveal(isZoomApp: Bool) -> CGFloat {
        isZoomApp ? 0 : hiddenWindowEdgeRevealEpsilon
    }

    func isZoomApp(_ pid: pid_t) -> Bool {
        controller?.appInfoCache.bundleId(for: pid) == "us.zoom.xos"
    }

    func markNativeFullscreenRestoredForFrameApply(_ token: WindowToken) {
        nativeFullscreenRestoredFrameApplyTokens.insert(token)
    }

    func consumeNativeFullscreenRestoredFrameApply(for token: WindowToken) -> Bool {
        nativeFullscreenRestoredFrameApplyTokens.remove(token) != nil
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
        var shownEntries: [(entry: WindowModel.Entry, hiddenState: WindowModel.HiddenState?)] = []
        var restoreEntries: [(entry: WindowModel.Entry, hiddenState: WindowModel.HiddenState)] = []
        var restoreTokens: Set<WindowToken> = []
        var frameChangeByToken: [WindowToken: CGRect] = [:]
        var pendingRevealTransactionIdsByToken: [WindowToken: UInt64] = [:]
        var blockedRevealTokens: Set<WindowToken> = []

        for change in diff.frameChanges {
            frameChangeByToken[change.token] = change.frame
        }

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

        let placeholderUpdates = diff.nativeFullscreenPlaceholders
            .compactMap { change -> NativeFullscreenPlaceholderUpdate? in
                guard let entry = resolveEntry(for: change.token),
                      entry.workspaceId == plan.workspaceId,
                      entry.layoutReason == .nativeFullscreen,
                      controller.workspaceManager.showsNativeFullscreenPlaceholder(for: change.token)
                else {
                    return nil
                }
                let appInfo = controller.appInfoCache.info(for: entry.pid)
                return NativeFullscreenPlaceholderUpdate(
                    token: change.token,
                    workspaceId: plan.workspaceId,
                    frame: change.frame,
                    selected: change.selected,
                    appName: appInfo?.name,
                    icon: appInfo?.icon
                )
            }
        controller.nativeFullscreenPlaceholderManager.update(
            placeholders: placeholderUpdates,
            in: plan.workspaceId
        )

        for change in diff.visibilityChanges {
            switch change {
            case let .show(token):
                guard let entry = resolveEntry(for: token) else { continue }
                guard entry.layoutReason != .nativeFullscreen else { continue }
                shownEntries.append((entry, controller.workspaceManager.hiddenState(for: token)))
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

        for (entry, hiddenState) in restoreEntries {
            guard refreshController.shouldUsePendingRevealTransaction(
                for: entry,
                hiddenState: hiddenState
            ) else {
                continue
            }
            if let targetFrame = frameChangeByToken[entry.token] {
                if let transactionId = refreshController.beginPendingRevealTransaction(
                    for: entry,
                    hiddenState: hiddenState,
                    targetFrame: targetFrame,
                    monitor: monitor
                ) {
                    pendingRevealTransactionIdsByToken[entry.token] = transactionId
                } else {
                    blockedRevealTokens.insert(entry.token)
                }
            } else if refreshController.hasPendingRevealTransaction(for: entry.windowId) {
                blockedRevealTokens.insert(entry.token)
            }
        }

        for (entry, hiddenState) in shownEntries {
            guard let hiddenState else { continue }
            guard refreshController.shouldUsePendingRevealTransaction(
                for: entry,
                hiddenState: hiddenState
            ) else {
                continue
            }
            if let targetFrame = frameChangeByToken[entry.token] {
                if let transactionId = refreshController.beginPendingRevealTransaction(
                    for: entry,
                    hiddenState: hiddenState,
                    targetFrame: targetFrame,
                    monitor: monitor
                ) {
                    pendingRevealTransactionIdsByToken[entry.token] = transactionId
                } else {
                    blockedRevealTokens.insert(entry.token)
                }
            } else if refreshController.hasPendingRevealTransaction(for: entry.windowId) {
                blockedRevealTokens.insert(entry.token)
            }
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
            let restorePlans: [LayoutRefreshController.WindowPositionPlan] = restoreEntries
                .compactMap { entry, hiddenState in
                    guard !blockedRevealTokens.contains(entry.token),
                          pendingRevealTransactionIdsByToken[entry.token] == nil
                    else { return nil }
                    return refreshController.makeRestorePositionPlan(
                        for: entry,
                        monitor: monitor,
                        hiddenState: hiddenState
                    )
                }
            refreshController.applyPositionPlans(restorePlans)

            for (entry, _) in restoreEntries
                where pendingRevealTransactionIdsByToken[entry.token] == nil
                && !blockedRevealTokens.contains(entry.token)
            {
                controller.workspaceManager.setHiddenState(nil, for: entry.token)
            }
        }

        if !shownEntries.isEmpty {
            for (entry, _) in shownEntries
                where !restoreTokens.contains(entry.token)
                && pendingRevealTransactionIdsByToken[entry.token] == nil
                && !blockedRevealTokens.contains(entry.token)
            {
                controller.workspaceManager.setHiddenState(nil, for: entry.token)
            }
        }

        if !restoreEntries.isEmpty || !shownEntries.isEmpty {
            var visibleJobs: [(pid: pid_t, windowId: Int)] = []
            visibleJobs.reserveCapacity(restoreEntries.count + shownEntries.count)
            var seenTokens: Set<WindowToken> = []

            for (entry, _) in restoreEntries
                where !blockedRevealTokens.contains(entry.token)
                && seenTokens.insert(entry.token).inserted
            {
                visibleJobs.append((entry.handle.pid, entry.windowId))
            }

            for (entry, _) in shownEntries
                where !blockedRevealTokens.contains(entry.token)
                && seenTokens.insert(entry.token).inserted
            {
                visibleJobs.append((entry.handle.pid, entry.windowId))
            }

            if !visibleJobs.isEmpty {
                controller.axManager.unsuppressFrameWrites(visibleJobs)
            }
        }

        var frameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []
        frameUpdates.reserveCapacity(diff.frameChanges.count)
        var revealFrameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect, transactionId: UInt64)] = []
        revealFrameUpdates.reserveCapacity(pendingRevealTransactionIdsByToken.count)

        for change in diff.frameChanges {
            guard !hiddenTokens.contains(change.token),
                  let entry = resolveEntry(for: change.token),
                  !blockedRevealTokens.contains(change.token)
            else {
                continue
            }
            guard entry.layoutReason != .nativeFullscreen else { continue }
            if pendingRevealTransactionIdsByToken[change.token] != nil {
                controller.axManager.forceApplyNextFrame(for: entry.windowId)
            }
            if let transactionId = pendingRevealTransactionIdsByToken[change.token] {
                revealFrameUpdates.append((entry.pid, entry.windowId, change.frame, transactionId))
            } else {
                let forceNativeFullscreenRestoreApply = refreshController
                    .consumeNativeFullscreenRestoredFrameApply(for: change.token)
                if change.forceApply {
                    controller.axManager.forceApplyNextFrame(for: entry.windowId)
                }
                if forceNativeFullscreenRestoreApply {
                    controller.axManager.forceApplyNextFrame(for: entry.windowId)
                }
                frameUpdates.append((entry.pid, entry.windowId, change.frame))
            }
        }

        if !frameUpdates.isEmpty {
            controller.axManager.applyFramesParallel(frameUpdates, verify: !plan.isAnimationTick)
        }

        if !revealFrameUpdates.isEmpty {
            var revealTransactionIdsByWindowId: [Int: UInt64] = [:]
            revealTransactionIdsByWindowId.reserveCapacity(revealFrameUpdates.count)
            for update in revealFrameUpdates {
                refreshController.refreshPendingRevealTransactionRuntimeRevision(
                    forWindowId: update.windowId,
                    transactionId: update.transactionId
                )
                revealTransactionIdsByWindowId[update.windowId] = update.transactionId
            }
            controller.axManager.applyFramesParallel(
                revealFrameUpdates.map { ($0.pid, $0.windowId, $0.frame) },
                terminalObserver: { [weak refreshController, revealTransactionIdsByWindowId] result in
                    guard let refreshController,
                          let transactionId = revealTransactionIdsByWindowId[result.windowId]
                          ?? refreshController.pendingRevealTransactionId(forWindowId: result.windowId)
                    else {
                        return
                    }
                    refreshController.completePendingRevealTransaction(
                        with: result,
                        transactionId: transactionId
                    )
                }
            )
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
}
