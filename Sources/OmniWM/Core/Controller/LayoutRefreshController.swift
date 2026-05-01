// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation
import OSLog
import QuartzCore

private let niriRemovalDiagnosticsLog = Logger(
    subsystem: "com.barut.OmniWM",
    category: "niri-removal"
)

private let layoutShutdownRaceLog = Logger(
    subsystem: "com.omniwm.core",
    category: "LayoutRefreshController.ShutdownRace"
)

@MainActor final class LayoutRefreshController: NSObject {
    typealias PostLayoutAction = RefreshScheduler.PostLayoutAction

    enum RefreshRoute: Equatable {
        case relayout
        case immediateRelayout
        case visibilityRefresh
        case windowRemoval
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
        var onRefreshEnqueued: ((ScheduledRefresh) -> Void)?
        var onRelayout: ((RefreshReason, RefreshRoute) async -> Bool)?
        var onVisibilityRefresh: ((RefreshReason) async -> Bool)?
        var onWindowRemoval: ((RefreshReason, [WindowRemovalPayload]) -> Bool)?
        var onWorkspaceLayoutPlanBuilt: ((LayoutType, WorkspaceDescriptor.ID) async -> Void)?
        var onNiriRemovalAnimationDiagnostic: ((NiriRemovalAnimationDiagnostic) -> Void)?
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
        var token: WindowToken
        var pid: pid_t
        var windowId: Int
        let targetFrame: CGRect
        let targetMonitorId: Monitor.ID
        let hiddenState: WindowModel.HiddenState
        var postSuccessActions: [PostLayoutAction]
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
        var displayIdByLink: [ObjectIdentifier: CGDirectDisplayID] = [:]
        var scheduledDisplayLinkDisplayIds: Set<CGDirectDisplayID> = []
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
    private var pendingRevealTransactionsByWindowId: [Int: PendingRevealTransaction] = [:]
    private var pendingRevealVerificationTasksByWindowId: [Int: Task<Void, Never>] = [:]
    private var pendingRevealWindowIdRedirects: [Int: Int] = [:]
    private var lastAppliedHideOrigins: [WindowToken: CGPoint] = [:]
    private var verifiedHideOriginTokens: Set<WindowToken> = []
    private var workspaceInactiveHideRetryCountByWindowId: [Int: Int] = [:]
    private var workspaceInactiveHideAwaitingFreshFrameWindowIds: Set<Int> = []
    private let refreshScheduler = RefreshScheduler()
    var displayLinkScheduleHookForTests: ((CGDirectDisplayID) -> Void)?

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
        ScreenLookupCache.shared.refresh()
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
            layoutState.displayIdByLink[ObjectIdentifier(existing)] = displayId
            return existing
        }

        guard let screen = ScreenLookupCache.shared.screen(for: displayId) else {
            return nil
        }
        let link = screen.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        cacheDisplayLink(link, for: displayId)
        return link
    }

    private func cacheDisplayLink(_ link: CADisplayLink, for displayId: CGDirectDisplayID) {
        layoutState.displayLinksByDisplay[displayId] = link
        layoutState.displayIdByLink[ObjectIdentifier(link)] = displayId
    }

    @discardableResult
    private func removeCachedDisplayLink(for displayId: CGDirectDisplayID) -> CADisplayLink? {
        guard let link = layoutState.displayLinksByDisplay.removeValue(forKey: displayId) else {
            return nil
        }
        layoutState.displayIdByLink.removeValue(forKey: ObjectIdentifier(link))
        layoutState.scheduledDisplayLinkDisplayIds.remove(displayId)
        return link
    }

    private func scheduleDisplayLinkIfNeeded(for displayId: CGDirectDisplayID) {
        guard let displayLink = getOrCreateDisplayLink(for: displayId) else { return }
        guard layoutState.scheduledDisplayLinkDisplayIds.insert(displayId).inserted else { return }
        displayLink.add(to: .main, forMode: .common)
        displayLinkScheduleHookForTests?(displayId)
    }

    private func handleScreenParametersChanged() {
        ScreenLookupCache.shared.refresh()
        detectRefreshRates()
    }

    func cleanupForMonitorDisconnect(displayId: CGDirectDisplayID, migrateAnimations: Bool) {
        if let link = removeCachedDisplayLink(for: displayId) {
            link.invalidate()
        }

        layoutState.closingAnimationsByDisplay.removeValue(forKey: displayId)
        lastAppliedHideOrigins.removeAll()
        verifiedHideOriginTokens.removeAll()
        workspaceInactiveHideRetryCountByWindowId.removeAll()
        workspaceInactiveHideAwaitingFreshFrameWindowIds.removeAll()

        if migrateAnimations {
            if let wsId = niriHandler.unregisterScrollAnimation(on: displayId) {
                startScrollAnimation(for: wsId)
            }
        } else {
            niriHandler.unregisterScrollAnimation(on: displayId)
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
        guard let displayId = layoutState.displayIdByLink[ObjectIdentifier(displayLink)] else { return }

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
        scheduleDisplayLinkIfNeeded(for: targetDisplayId)
    }

    func stopScrollAnimation(for displayId: CGDirectDisplayID) {
        niriHandler.unregisterScrollAnimation(on: displayId)
        stopDisplayLinkIfIdle(for: displayId)
    }

    func stopAllScrollAnimations() {
        let displayIds = niriHandler.clearScrollAnimations()
        for displayId in displayIds {
            stopDisplayLinkIfIdle(for: displayId)
        }
    }

    func emitNiriRemovalAnimationDiagnostic(_ diagnostic: NiriRemovalAnimationDiagnostic) {
        niriRemovalDiagnosticsLog.info(
            """
            phase=\(String(describing: diagnostic.phase), privacy: .public) \
            workspace=\(diagnostic.workspaceId.uuidString, privacy: .private) \
            removedWindow=\(diagnostic.removedWindow?.windowId ?? 0, privacy: .private) \
            recoveryWindow=\(diagnostic.recoveryTarget?.windowId ?? 0, privacy: .private) \
            policy=\(String(describing: diagnostic.animationPolicy), privacy: .public) \
            viewport=\(String(describing: diagnostic.viewportAction), privacy: .public) \
            scroll=\(diagnostic.startNiriScroll, privacy: .public) \
            skipFrames=\(diagnostic.skipFrameApplicationForAnimation, privacy: .public)
            """
        )
        debugHooks.onNiriRemovalAnimationDiagnostic?(diagnostic)
    }

    func startDwindleAnimation(for workspaceId: WorkspaceDescriptor.ID, monitor: Monitor) {
        guard controller?.motionPolicy.animationsEnabled != false else { return }
        let targetDisplayId = monitor.displayId

        guard dwindleHandler.registerDwindleAnimation(workspaceId, monitor: monitor, on: targetDisplayId)
        else { return }
        scheduleDisplayLinkIfNeeded(for: targetDisplayId)
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
            config: .snappy,
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
        scheduleDisplayLinkIfNeeded(for: monitor.displayId)
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
           layoutState.closingAnimationsByDisplay[displayId].map(\.isEmpty) ?? true
        {

            if let link = removeCachedDisplayLink(for: displayId) {
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
            case .defaultLayout, .niri:
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

        let preferredSides = preferredHideSides()
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
        if let diagnostic = plan.niriRemovalAnimationDiagnostic {
            emitNiriRemovalAnimationDiagnostic(
                diagnostic.withPhase(
                    .frameApplication,
                    skipFrameApplicationForAnimation: plan.skipFrameApplicationForAnimation
                )
            )
        }
        diffExecutor.execute(plan)
        applyAnimationDirectives(
            plan.animationDirectives,
            focusedFrame: plan.diff.focusedFrame
        )
        applyFocusIntents(plan.focusIntents)
    }

    private func executeRefreshExecutionPlan(_ plan: RefreshExecutionPlan) {
        guard let controller else { return }

        layoutState.didExecuteRefreshExecutionPlan = true
        activeFrameContext = RefreshFrameContext()
        defer { activeFrameContext = nil }






        let visibilityWorkspaceEntries: [(workspace: WorkspaceDescriptor, entries: [WindowModel.Entry])]?
        if let visibility = plan.effects.visibility {
            let workspaceEntries = workspaceEntriesSnapshot(on: controller)
            rebuildInactiveWorkspaceWindowSet(
                activeWorkspaceIds: visibility.activeWorkspaceIds,
                workspaceEntries: workspaceEntries
            )
            visibilityWorkspaceEntries = workspaceEntries
        } else {
            visibilityWorkspaceEntries = nil
        }

        executeLayoutPlans(plan.workspacePlans)

        if let visibility = plan.effects.visibility {
            hideInactiveWorkspaces(
                activeWorkspaceIds: visibility.activeWorkspaceIds,
                workspaceEntries: visibilityWorkspaceEntries,
                rebuildInactiveWorkspaceWindowSet: false
            )
        }

        let canValidateFocus = controller.runtime != nil
        if canValidateFocus,
           !plan.effects.nativeFullscreenRestoreWorkspaceIds.isEmpty,
           !controller.workspaceManager.isAppFullscreenActive,
           !controller.workspaceManager.hasPendingNativeFullscreenTransition,
           !controller.shouldSuppressManagedFocusRecovery
        {
            for workspaceId in plan.effects.nativeFullscreenRestoreWorkspaceIds {
                controller.ensureFocusedTokenValid(in: workspaceId)
            }
            refreshFocusedBorderForVisibilityState(on: controller)
        }

        if plan.effects.updateTabbedOverlays {
            niriHandler.updateTabbedColumnOverlays()
        }

        if plan.effects.refreshFocusedBorderForVisibilityState {
            refreshFocusedBorderForVisibilityState(on: controller)
        }

        if canValidateFocus {
            for workspaceId in plan.effects.focusValidationWorkspaceIds {
                controller.ensureFocusedTokenValid(in: workspaceId)
            }
        }

        for postLayoutAction in plan.postLayoutActions {
            postLayoutAction()
        }

        if plan.effects.requestWorkspaceBarRefresh {
            controller.requestWorkspaceBarRefresh()
            controller.niriEngine?.clearWorkspaceBarProjectionInvalidations(
                for: plan.effects.workspaceBarProjectionInvalidatedWorkspaceIds
            )
        }

        if plan.effects.markInitialRefreshComplete {
            layoutState.hasCompletedInitialRefresh = true
        }

        if plan.effects.drainDeferredCreatedWindows {
            controller.axEventHandler.drainDeferredCreatedWindows()
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

            let mergedConstraints = constraints.applyingRuleMinimumSizeEffects(
                LayoutConstraintRuleEffects(ruleEffects: entry.ruleEffects)
            )

            snapshots.append(
                LayoutWindowSnapshot(
                    logicalId: controller.workspaceManager
                        .logicalWindowRegistry
                        .resolveForRead(token: entry.token) ?? .invalid,
                    token: entry.token,
                    constraints: mergedConstraints,
                    hiddenState: controller.workspaceManager.hiddenState(for: entry.token),
                    layoutReason: controller.workspaceManager.layoutReason(for: entry.token),
                    nativeFullscreenRestore: controller.workspaceManager.nativeFullscreenRestoreContext(
                        for: entry.token
                    )
                )
            )
        }

        return snapshots
    }

    @discardableResult
    func warmWindowConstraints(
        for entries: [WorkspaceGraph.WindowEntry],
        resolveConstraints: Bool
    ) -> Bool {
        guard let controller else { return false }
        guard resolveConstraints else { return true }

        for entry in entries {
            if controller.workspaceManager.cachedConstraints(for: entry.token) != nil {
                continue
            }
            guard let windowEntry = controller.workspaceManager.entry(for: entry.token) else {
                continue
            }
            let currentSize = fastFrame(
                for: windowEntry.token,
                axRef: windowEntry.axRef
            )?.size
            let resolved = AXWindowService.sizeConstraints(
                windowEntry.axRef,
                currentSize: currentSize
            )
            controller.workspaceManager.setCachedConstraints(
                resolved,
                for: windowEntry.token
            )
        }

        return true
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

        let graph = controller.workspaceManager.workspaceGraphSnapshot()
        let entries = graph.tiledMembership(in: workspaceId).compactMap {
            controller.workspaceManager.entry(for: $0.token)
        }
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
        guard let controller else { return }
        // `WMController.runtime` is `weak`. `executeLayoutPlan` always calls
        // `applySessionPatch`, so a teardown that releases the runtime
        // between scheduler tick and apply would crash the WM here. Soft-
        // return preserves the AppKit-shutdown ordering without a no-op
        // hazard at runtime nominal operation: under nominal operation the
        // runtime is always attached.
        guard let runtime = controller.runtime else {
            layoutShutdownRaceLog.notice("LayoutRefreshController.applySessionPatch: WMRuntime detached during shutdown; skipping session patch")
            return
        }
        _ = runtime.applySessionPatch(patch, source: .service)
    }

    private func setHiddenState(_ state: WindowModel.HiddenState?, for token: WindowToken) {
        guard let controller else { return }
        guard let runtime = controller.runtime else {
            preconditionFailure("LayoutRefreshController.setHiddenState requires WMRuntime to be attached")
        }
        runtime.setHiddenState(state, for: token, source: .service)
    }

    private func applyAnimationDirectives(
        _ directives: [AnimationDirective],
        focusedFrame _: LayoutFocusedFrame?
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
                applyManagedFocus(token, on: controller)
            case .updateTabbedOverlays:
                niriHandler.updateTabbedColumnOverlays()
            }
        }
    }

    private func applyFocusIntents(_ intents: [LayoutFocusIntent]) {
        guard let controller else { return }

        for intent in intents {
            switch intent {
            case let .focusWindow(token):
                applyManagedFocus(token, on: controller)
            case let .completeFocusedRemovalRecovery(workspaceId, target):
                controller.axEventHandler.completeFocusedRemovalRecovery(
                    workspaceId: workspaceId,
                    target: target
                )
            }
        }
    }

    private func applyManagedFocus(_ token: WindowToken, on controller: WMController) {
        guard let entry = controller.workspaceManager.entry(for: token) else { return }
        guard !controller.shouldSuppressManagedFocusRecovery,
              !controller.workspaceManager.hasPendingNativeFullscreenTransition
        else {
            controller.axEventHandler.completeFocusedRemovalRecovery(
                workspaceId: entry.workspaceId,
                target: token
            )
            return
        }

        controller.axEventHandler.noteFocusedRemovalRecoveryFocusRequested(token)
        controller.focusWindow(token, source: .focusPolicy)
        if controller.focusBridge.activeManagedRequest(for: token) == nil {
            controller.axEventHandler.completeFocusedRemovalRecovery(
                workspaceId: entry.workspaceId,
                target: token
            )
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
            makeScheduledRefresh(
                kind: .immediateRelayout,
                reason: reason,
                affectedWorkspaceIds: affectedWorkspaceIds,
                postLayoutAttachmentIds: registerPostLayoutAttachments(postLayout)
            )
        )
    }

    func requestVisibilityRefresh(
        reason: RefreshReason,
        postLayout: PostLayoutAction? = nil
    ) {
        assert(reason.requestRoute == .visibilityRefresh, "Invalid visibility-refresh reason: \(reason)")
        enqueueRefresh(
            makeScheduledRefresh(
                kind: .visibilityRefresh,
                reason: reason,
                postLayoutAttachmentIds: registerPostLayoutAttachments(postLayout)
            )
        )
    }

    @discardableResult
    func requestWindowRemoval(
        workspaceId: WorkspaceDescriptor.ID,
        layoutType: LayoutType,
        removedNodeId: NodeId?,
        removedWindow: WindowToken? = nil,
        niriOldFrames: [WindowToken: CGRect],
        niriRevealSide: NiriRemovalRevealSide? = nil,
        shouldRecoverFocus: Bool,
        niriAnimationPolicy: NiriRemovalAnimationPolicy = .ordinary,
        postLayout: PostLayoutAction? = nil
    ) -> RefreshCycleId? {
        assert(RefreshReason.windowDestroyed.requestRoute == .windowRemoval, "Invalid window-removal reason")
        let refresh = makeScheduledRefresh(
            kind: .windowRemoval,
            reason: .windowDestroyed,
            postLayoutAttachmentIds: registerPostLayoutAttachments(postLayout),
            windowRemovalPayload: .init(
                workspaceId: workspaceId,
                layoutType: layoutType,
                removedNodeId: removedNodeId,
                removedWindow: removedWindow,
                niriOldFrames: niriOldFrames,
                niriRevealSide: niriRevealSide,
                shouldRecoverFocus: shouldRecoverFocus,
                niriAnimationPolicy: niriAnimationPolicy
            )
        )
        guard let result = enqueueRefresh(refresh) else { return nil }
        return scheduledWindowRemovalCycleId(from: result)
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
        enqueueRefresh(
            makeScheduledRefresh(
                kind: .fullRescan,
                reason: reason
            )
        )
    }

    private func makeScheduledRefresh(
        kind: ScheduledRefreshKind,
        reason: RefreshReason,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = [],
        postLayoutAttachmentIds: [RefreshAttachmentId] = [],
        windowRemovalPayload: WindowRemovalPayload? = nil
    ) -> ScheduledRefresh {
        refreshScheduler.makeScheduledRefresh(
            kind: kind,
            reason: reason,
            affectedWorkspaceIds: affectedWorkspaceIds,
            postLayoutAttachmentIds: postLayoutAttachmentIds,
            windowRemovalPayload: windowRemovalPayload
        )
    }

    private func registerPostLayoutAttachments(
        _ postLayout: PostLayoutAction?
    ) -> [RefreshAttachmentId] {
        refreshScheduler.registerPostLayoutAttachments(postLayout)
    }

    private func resolvePostLayoutActions(
        attachmentIds: [RefreshAttachmentId]
    ) -> [PostLayoutAction] {
        refreshScheduler.resolvePostLayoutActions(attachmentIds: attachmentIds)
    }

    private func runPostLayoutActions(
        attachmentIds: [RefreshAttachmentId]
    ) {
        refreshScheduler.runPostLayoutActions(attachmentIds: attachmentIds)
    }

    private func discardPostLayoutActions(
        attachmentIds: [RefreshAttachmentId]
    ) {
        refreshScheduler.discardPostLayoutActions(attachmentIds: attachmentIds)
    }

    private func scheduleRefreshSession(
        _ policy: RelayoutSchedulingPolicy,
        reason: RefreshReason,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
    ) {
        enqueueRefresh(
            makeScheduledRefresh(
                kind: .relayout,
                reason: reason,
                affectedWorkspaceIds: affectedWorkspaceIds
            ),
            shouldDropWhileBusy: policy.shouldDropWhileBusy
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

        if controller.isLockScreenActive
            || (controller.hasStartedServices && controller.isFrontmostAppLockScreen())
        {
            return false
        }

        do {
            var plan = try await buildRelayoutExecutionPlan(
                refresh: refresh,
                useScrollAnimationPath: useScrollAnimationPath,
                recoverFocus: recoverFocus,
                affectedWorkspaceIds: refresh.affectedWorkspaceIds
            )
            applyRefreshMetadata(refresh, to: &plan)
            try Task.checkCancellation()
            executeRefreshExecutionPlan(plan)
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

        if controller.isLockScreenActive
            || (controller.hasStartedServices && controller.isFrontmostAppLockScreen())
        {
            return false
        }

        var plan = buildVisibilityExecutionPlan()
        applyRefreshMetadata(refresh, to: &plan)
        guard !Task.isCancelled else { return false }
        executeRefreshExecutionPlan(plan)

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
        if controller.isLockScreenActive
            || (controller.hasStartedServices && controller.isFrontmostAppLockScreen())
        {
            return false
        }

        do {
            var plan = try await buildWindowRemovalExecutionPlan(payloads: payloads)
            applyRefreshMetadata(refresh, to: &plan)
            try Task.checkCancellation()
            executeRefreshExecutionPlan(plan)
        } catch {
            return false
        }

        return true
    }

    func buildWindowRemovalExecutionPlanForTests(
        payloads: [WindowRemovalPayload]
    ) async throws -> RefreshExecutionPlan {
        try await buildWindowRemovalExecutionPlan(payloads: payloads)
    }

    private func refreshFocusedBorderForVisibilityState(on controller: WMController) {
        _ = controller.renderKeyboardFocusBorder(
            policy: .coordinated,
            source: .borderReapplyPostLayout
        )
    }

    func waitForRefreshWorkForTests() async {
        while let task = layoutState.activeRefreshTask {
            await task.value
        }
    }

    private func refreshPlanningSnapshot() -> RefreshOrchestrationSnapshot {
        if let runtime = controller?.runtime {
            return runtime.refreshSnapshot
        }
        return .init(
            activeRefresh: layoutState.activeRefresh,
            pendingRefresh: layoutState.pendingRefresh
        )
    }

    private func storeRefreshPlanningSnapshot(_ snapshot: RefreshOrchestrationSnapshot) {
        layoutState.activeRefresh = snapshot.activeRefresh
        layoutState.pendingRefresh = snapshot.pendingRefresh
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
        let refreshSnapshot = refreshPlanningSnapshot()
        if let activeRefresh = refreshSnapshot.activeRefresh {
            discardPostLayoutActions(attachmentIds: activeRefresh.postLayoutAttachmentIds)
        }
        if let pendingRefresh = refreshSnapshot.pendingRefresh {
            discardPostLayoutActions(attachmentIds: pendingRefresh.postLayoutAttachmentIds)
        }
        layoutState.activeRefreshTask = nil
        layoutState.activeRefresh = nil
        layoutState.pendingRefresh = nil
        layoutState.didExecuteRefreshExecutionPlan = false
        refreshScheduler.clearPostLayoutActions()
        controller?.runtime?.resetRefreshOrchestration()

        for displayId in Array(layoutState.displayLinksByDisplay.keys) {
            removeCachedDisplayLink(for: displayId)?.invalidate()
        }
        _ = niriHandler.clearScrollAnimations()
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

        if controller.isLockScreenActive
            || (controller.hasStartedServices && controller.isFrontmostAppLockScreen())
        {
            return false
        }

        var plan = try await buildFullRefreshExecutionPlan()
        applyRefreshMetadata(refresh, to: &plan)
        try Task.checkCancellation()
        executeRefreshExecutionPlan(plan)
        return true
    }

    func updateTabbedColumnOverlays() {
        niriHandler.updateTabbedColumnOverlays()
    }

    func selectTabInNiri(workspaceId: WorkspaceDescriptor.ID, columnId: NodeId, visualIndex: Int) {
        niriHandler.selectTabInNiri(workspaceId: workspaceId, columnId: columnId, visualIndex: visualIndex)
    }

    private func applyRefreshMetadata(_ refresh: ScheduledRefresh, to plan: inout RefreshExecutionPlan) {
        if !refresh.postLayoutAttachmentIds.isEmpty {
            plan.postLayoutActions.append(
                contentsOf: resolvePostLayoutActions(attachmentIds: refresh.postLayoutAttachmentIds)
            )
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
        refresh: ScheduledRefresh,
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

        let postRescanRegistry = controller.workspaceManager.logicalWindowRegistry
        controller.niriEngine?.syncLogicalIds(from: postRescanRegistry)
        controller.dwindleEngine?.syncLogicalIds(from: postRescanRegistry)

        var effects = RefreshExecutionEffects()
        let pendingBarProjectionInvalidations =
            controller.niriEngine?.pendingWorkspaceBarProjectionInvalidationIds() ?? []
        effects.visibility = .init(activeWorkspaceIds: activeWorkspaceIds)
        effects.workspaceBarProjectionInvalidatedWorkspaceIds = pendingBarProjectionInvalidations
        effects.requestWorkspaceBarRefresh = shouldRequestWorkspaceBarRefresh(
            for: refresh,
            workspacePlans: workspacePlans,
            workspaceBarProjectionInvalidatedWorkspaceIds: pendingBarProjectionInvalidations
        )
        effects.updateTabbedOverlays = updateTabbedOverlays
        effects.nativeFullscreenRestoreWorkspaceIds = nativeFullscreenRestoreWorkspaceIds(
            from: workspacePlans
        )
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

    private func shouldRequestWorkspaceBarRefresh(
        for refresh: ScheduledRefresh,
        workspacePlans: [WorkspaceLayoutPlan],
        workspaceBarProjectionInvalidatedWorkspaceIds: Set<WorkspaceDescriptor.ID>
    ) -> Bool {
        if !workspaceBarProjectionInvalidatedWorkspaceIds.isEmpty {
            return true
        }

        switch refresh.reason {
        case .workspaceTransition,
             .appActivationTransition,
             .overviewMutation,
             .axWindowCreated,
             .windowRuleReevaluation:
            return true

        case .layoutCommand:

            if !refresh.postLayoutAttachmentIds.isEmpty {
                return true
            }

            return workspacePlans.contains { plan in
                !plan.focusIntents.isEmpty || plan.animationDirectives.contains { directive in
                    if case .activateWindow = directive {
                        return true
                    }
                    return false
                }
            }

        case .layoutConfigChanged,
             .monitorSettingsChanged,
             .gapsChanged,
             .workspaceLayoutToggled,
             .axWindowChanged,
             .interactiveGesture:
            return false

        default:
            return false
        }
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
            case .defaultLayout, .niri:
                niriRemovalSeeds[payload.workspaceId] = mergedNiriRemovalSeed(
                    existing: niriRemovalSeeds[payload.workspaceId],
                    payload: payload
                )
            }

            if payload.shouldRecoverFocus,
               payload.layoutType == .dwindle || payload.removedNodeId == nil
            {
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
        let focusValidationWorkspaceIds: [WorkspaceDescriptor.ID] = if controller.workspaceManager.isAppFullscreenActive
            || controller.workspaceManager.hasPendingNativeFullscreenTransition
            || controller.shouldSuppressManagedFocusRecovery
        {
            []
        } else {
            focusedWorkspacesToRecover
                .intersection(activeWorkspaceIds)
                .sorted { $0.uuidString < $1.uuidString }
        }

        var effects = RefreshExecutionEffects()
        effects.visibility = .init(activeWorkspaceIds: activeWorkspaceIds)
        effects.requestWorkspaceBarRefresh = true
        effects.updateTabbedOverlays = updateTabbedOverlays
        effects.nativeFullscreenRestoreWorkspaceIds = nativeFullscreenRestoreWorkspaceIds(
            from: workspacePlans
        )
        effects.focusValidationWorkspaceIds = focusValidationWorkspaceIds

        return RefreshExecutionPlan(workspacePlans: workspacePlans, effects: effects)
    }

    private func mergedNiriRemovalSeed(
        existing: NiriWindowRemovalSeed?,
        payload: WindowRemovalPayload
    ) -> NiriWindowRemovalSeed {
        var removedNodeIds = existing?.removedNodeIds ?? []
        if let removedNodeId = payload.removedNodeId {
            removedNodeIds.append(removedNodeId)
        }

        let payloadSuppliesRecoveryPolicy = payload.shouldRecoverFocus
            || payload.niriAnimationPolicy == .staticViewportPreserving
        let selectedRemovalAnchorNodeId = if payload.shouldRecoverFocus {
            payload.removedNodeId ?? existing?.selectedRemovalAnchorNodeId
        } else {
            existing?.selectedRemovalAnchorNodeId
        }
        let diagnosticRemovedNodeId = if payloadSuppliesRecoveryPolicy {
            payload.removedNodeId ?? existing?.diagnosticRemovedNodeId
        } else {
            existing?.diagnosticRemovedNodeId ?? payload.removedNodeId
        }
        let removedWindow = if payloadSuppliesRecoveryPolicy {
            payload.removedWindow ?? existing?.removedWindow
        } else {
            existing?.removedWindow ?? payload.removedWindow
        }
        let revealSide = if payload.shouldRecoverFocus {
            payload.niriRevealSide ?? existing?.revealSide
        } else {
            existing?.revealSide ?? payload.niriRevealSide
        }

        return NiriWindowRemovalSeed(
            removedNodeIds: removedNodeIds,
            oldFrames: (existing?.oldFrames ?? [:])
                .merging(payload.niriOldFrames) { current, _ in current },
            removedWindow: removedWindow,
            selectedRemovalAnchorNodeId: selectedRemovalAnchorNodeId,
            revealSide: revealSide,
            shouldRecoverFocus: existing?.shouldRecoverFocus == true || payload.shouldRecoverFocus,
            animationPolicy: existing?.animationPolicy
                .merging(payload.niriAnimationPolicy)
                ?? payload.niriAnimationPolicy,
            diagnosticRemovedNodeId: diagnosticRemovedNodeId
        )
    }

    private func buildFullRefreshExecutionPlan() async throws -> RefreshExecutionPlan {
        guard let controller else { return .init() }
        guard let runtime = controller.runtime else {
            preconditionFailure("LayoutRefreshController.performFullRescan requires WMRuntime to be attached")
        }

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

            if controller.workspaceManager.entry(forPid: pid, windowId: winId) == nil,
               controller.axEventHandler.isWindowRecentlyDestroyed(windowId: winId)
            {
                continue
            }

            let token = WindowToken(pid: pid, windowId: winId)
            let appFullscreen = controller.axEventHandler.isFullscreenProvider?(ax) ?? AXWindowService.isFullscreen(ax)
            let evaluation = controller.evaluateWindowDisposition(
                axRef: ax,
                pid: pid,
                appFullscreen: appFullscreen
            )
            let decision = evaluation.decision
            var existingEntry = controller.workspaceManager.entry(for: token)
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
                fallbackWorkspaceId: focusedWorkspaceId
            )
            if controller.workspaceAssignment(pid: pid, windowId: winId) == nil,
               controller.axEventHandler.restoreNativeFullscreenReplacementIfNeeded(
                   token: token,
                   windowId: UInt32(winId),
                   axRef: ax,
                   workspaceId: replacementWorkspace,
                   appFullscreen: appFullscreen
               )
            {
                seenKeys.insert(token)
                existingEntry = controller.workspaceManager.entry(for: token)
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
                existingEntry: existingEntry,
                fallbackWorkspaceId: focusedWorkspaceId
            )

            let wsForWindow: WorkspaceDescriptor.ID
            let ruleEffects: ManagedWindowRuleEffects
            if let existingEntry {
                if shouldPreservePreFullscreenState {
                    if controller.workspaceManager.nativeFullscreenRecord(for: existingEntry.token) != nil {
                        _ = controller.ensureNativeFullscreenRestoreSnapshot(
                            for: existingEntry.token,
                            path: .fullRescanNativeFullscreenRestore
                        )
                        controller.routeBeginNativeFullscreenRestore(for: existingEntry.token)
                    } else {
                        controller.routeRestoreNativeFullscreenRecord(for: existingEntry.token)
                    }
                    wsForWindow = existingEntry.workspaceId
                    ruleEffects = existingEntry.ruleEffects
                } else if appFullscreen {
                    _ = controller.suspendManagedWindowForNativeFullscreen(
                        existingEntry.token,
                        path: .fullRescanExistingEntryFullscreen
                    )
                    let existingAssignment = controller.workspaceAssignment(pid: pid, windowId: winId)
                    let nativeFullscreenWorkspace = controller.workspaceManager
                        .nativeFullscreenRecord(for: existingEntry.token)?
                        .workspaceId
                    wsForWindow = existingAssignment ?? nativeFullscreenWorkspace ?? defaultWorkspace
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

            _ = runtime.admitWindow(
                ax,
                pid: pid,
                windowId: winId,
                to: wsForWindow,
                mode: oldMode ?? trackedMode,
                ruleEffects: ruleEffects,
                source: .ax
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
            discardHiddenTracking(for: token)
            _ = runtime.removeWindow(
                pid: token.pid,
                windowId: token.windowId,
                source: .ax
            )
        }

        let shouldPreserveMissingWindows = shouldPreserveMissingWindowsDuringNativeFullscreen(
            controller: controller
        )
        if shouldPreserveMissingWindows {


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

        runtime.removeMissingWindows(
            keys: seenKeys,
            requiredConsecutiveMisses: 2,
            source: .service
        )
        runtime.garbageCollectUnusedWorkspaces(
            focusedWorkspaceId: focusedWorkspaceId,
            source: .service
        )

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

        let postRescanRegistry = controller.workspaceManager.logicalWindowRegistry
        controller.niriEngine?.syncLogicalIds(from: postRescanRegistry)
        controller.dwindleEngine?.syncLogicalIds(from: postRescanRegistry)

        var effects = RefreshExecutionEffects()
        effects.visibility = .init(activeWorkspaceIds: activeWorkspaceIds)
        effects.requestWorkspaceBarRefresh = true
        effects.updateTabbedOverlays = updateTabbedOverlays
        effects.nativeFullscreenRestoreWorkspaceIds = nativeFullscreenRestoreWorkspaceIds(
            from: workspacePlans
        )
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
            || controller.workspaceManager.isWithinNativeFullscreenLifecycleGrace
    }

    private func nativeFullscreenRestoreWorkspaceIds(
        from workspacePlans: [WorkspaceLayoutPlan]
    ) -> [WorkspaceDescriptor.ID] {
        Array(
            Set(
                workspacePlans.compactMap { plan in
                    plan.nativeFullscreenRestoreFinalizeTokens.isEmpty ? nil : plan.workspaceId
                }
            )
        )
        .sorted { $0.uuidString < $1.uuidString }
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
            case .defaultLayout, .niri:
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

    func workspaceIsCurrentlyActive(_ workspaceId: WorkspaceDescriptor.ID) -> Bool {
        currentActiveWorkspaceIds().contains(workspaceId)
    }

    func lastAppliedHideOrigin(for token: WindowToken) -> CGPoint? {
        lastAppliedHideOrigins[token]
    }

    func lastVerifiedHideOrigin(for token: WindowToken) -> CGPoint? {
        guard verifiedHideOriginTokens.contains(token) else { return nil }
        return lastAppliedHideOrigins[token]
    }

    func hiddenOriginForComparison(_ origin: CGPoint, token: WindowToken) -> CGPoint {
        roundedHiddenOrigin(origin, for: token)
    }

    func workspaceInactiveHideRetryCount(for windowId: Int) -> Int? {
        workspaceInactiveHideRetryCountByWindowId[windowId]
    }

    func isAwaitingFreshFrameAfterWorkspaceHideFailure(for windowId: Int) -> Bool {
        workspaceInactiveHideAwaitingFreshFrameWindowIds.contains(windowId)
    }

    fileprivate func rememberHiddenOrigin(
        for token: WindowToken,
        origin: CGPoint,
        verified: Bool = true
    ) {
        lastAppliedHideOrigins[token] = roundedHiddenOrigin(origin, for: token)
        if verified {
            verifiedHideOriginTokens.insert(token)
        } else {
            verifiedHideOriginTokens.remove(token)
        }
        resetWorkspaceInactiveHideRetryState(forWindowId: token.windowId)
    }

    fileprivate func clearHiddenOrigin(for token: WindowToken) {
        lastAppliedHideOrigins.removeValue(forKey: token)
        verifiedHideOriginTokens.remove(token)
    }

    fileprivate func clearHiddenRecord(for token: WindowToken) {
        clearHiddenOrigin(for: token)
        resetWorkspaceInactiveHideRetryState(forWindowId: token.windowId)
        setHiddenState(nil, for: token)
    }

    func discardHiddenTracking(for token: WindowToken) {
        clearHiddenOrigin(for: token)
        resetWorkspaceInactiveHideRetryState(forWindowId: token.windowId)
    }

    @discardableResult
    func handleFreshFrameEvent(for token: WindowToken) -> Bool {
        guard workspaceInactiveHideAwaitingFreshFrameWindowIds.remove(token.windowId) != nil else {
            return false
        }
        resetWorkspaceInactiveHideRetryState(forWindowId: token.windowId)
        return true
    }

    private func resetWorkspaceInactiveHideRetryState(forWindowId windowId: Int) {
        workspaceInactiveHideRetryCountByWindowId.removeValue(forKey: windowId)
        workspaceInactiveHideAwaitingFreshFrameWindowIds.remove(windowId)
    }

    private func roundedHiddenOrigin(_ origin: CGPoint, for token: WindowToken) -> CGPoint {
        origin.roundedToPhysicalPixels(scale: hiddenOriginScale(for: token))
    }

    private func hiddenOriginScale(for token: WindowToken) -> CGFloat {
        guard let controller,
              let entry = controller.workspaceManager.entry(for: token),
              let monitor = controller.workspaceManager.monitor(for: entry.workspaceId)
        else {
            return 2.0
        }

        return backingScale(for: monitor)
    }

    @discardableResult
    private func enqueueRefresh(
        _ refresh: ScheduledRefresh,
        shouldDropWhileBusy: Bool = false
    ) -> OrchestrationResult? {
        recordRefreshRequest(refresh.reason)
        debugHooks.onRefreshEnqueued?(refresh)
        if let runtime = controller?.runtime {
            return runtime.requestRefresh(
                .init(
                    refresh: refresh,
                    shouldDropWhileBusy: shouldDropWhileBusy,
                    isIncrementalRefreshInProgress: layoutState.isIncrementalRefreshInProgress,
                    isImmediateLayoutInProgress: layoutState.isImmediateLayoutInProgress,
                    hasActiveAnimationRefreshes: !niriHandler.scrollAnimationByDisplay.isEmpty
                        || !dwindleHandler.dwindleAnimationByDisplay.isEmpty
                )
            )
        }

        let refreshSnapshot = refreshPlanningSnapshot()
        let result = OrchestrationCore.step(
            snapshot: orchestrationSnapshot(refresh: refreshSnapshot),
            event: .refreshRequested(
                .init(
                    refresh: refresh,
                    shouldDropWhileBusy: shouldDropWhileBusy,
                    isIncrementalRefreshInProgress: layoutState.isIncrementalRefreshInProgress,
                    isImmediateLayoutInProgress: layoutState.isImmediateLayoutInProgress,
                    hasActiveAnimationRefreshes: !niriHandler.scrollAnimationByDisplay.isEmpty
                        || !dwindleHandler.dwindleAnimationByDisplay.isEmpty
                )
            )
        )
        applyRuntimeRefreshResult(result)
        return result
    }

    private func scheduledWindowRemovalCycleId(from result: OrchestrationResult) -> RefreshCycleId? {
        switch result.decision {
        case let .refreshQueued(cycleId, kind),
             let .refreshMerged(cycleId, kind):
            return kind == .windowRemoval ? cycleId : nil

        case let .refreshSuperseded(_, pendingCycleId):
            let pending = result.snapshot.refresh.pendingRefresh
            return pending?.kind == .windowRemoval && pending?.cycleId == pendingCycleId
                ? pendingCycleId
                : nil

        default:
            return nil
        }
    }

    func applyRuntimeRefreshResult(_ result: OrchestrationResult) {
        applyResolvedRefreshPlan(
            snapshot: result.snapshot.refresh,
            actions: result.plan.actions
        )
    }

    private func applyResolvedRefreshPlan(
        snapshot: RefreshOrchestrationSnapshot,
        actions: [OrchestrationPlan.Action]
    ) {
        if controller?.runtime == nil {
            storeRefreshPlanningSnapshot(snapshot)
        }
        synchronizeRefreshCycleCounter()
        controller?.axEventHandler.reconcileFocusedRemovalActivationSuppression(
            activeCycleId: snapshot.activeRefresh?.cycleId,
            pendingCycleId: snapshot.pendingRefresh?.cycleId
        )

        for action in actions {
            switch action {
            case let .cancelActiveRefresh(cycleId):
                guard refreshPlanningSnapshot().activeRefresh?.cycleId == cycleId else { continue }
                controller?.axEventHandler.cancelFocusedRemovalActivationSuppression(refreshCycleId: cycleId)
                layoutState.activeRefreshTask?.cancel()
            case let .startRefresh(refresh):
                startRefreshTask(refresh)
            case let .runPostLayoutAttachments(attachmentIds):
                runPostLayoutActions(attachmentIds: attachmentIds)
            case let .discardPostLayoutAttachments(attachmentIds):
                discardPostLayoutActions(attachmentIds: attachmentIds)
            case .performVisibilitySideEffects:
                guard let controller else { continue }
                performVisibilitySideEffects(on: controller)
            case .requestWorkspaceBarRefresh:
                controller?.requestWorkspaceBarRefresh()
            case .beginManagedFocusRequest,
                 .beginNativeFullscreenRestoreActivation,
                 .cancelActivationRetry,
                 .clearManagedFocusState,
                 .confirmManagedActivation,
                 .continueManagedFocusRequest,
                 .enterNonManagedFallback,
                 .enterOwnedApplicationFallback,
                 .frontManagedWindow:
                preconditionFailure("Refresh orchestration emitted non-refresh action \(action)")
            }
        }
    }

    private func orchestrationSnapshot(refresh: RefreshOrchestrationSnapshot) -> OrchestrationSnapshot {
        controller?.orchestrationSnapshot(refresh: refresh)
            ?? .init(
                refresh: refresh,
                focus: .init(
                    nextManagedRequestId: 0,
                    activeManagedRequest: nil,
                    pendingFocusedToken: nil,
                    pendingFocusedWorkspaceId: nil,
                    isNonManagedFocusActive: false,
                    isAppFullscreenActive: false
                )
            )
    }

    private func synchronizeRefreshCycleCounter() {
        let snapshot = refreshPlanningSnapshot()
        refreshScheduler.synchronizeCycleCounter(
            activeRefresh: snapshot.activeRefresh,
            pendingRefresh: snapshot.pendingRefresh
        )
    }

    private func startRefreshTask(_ refresh: ScheduledRefresh) {
        guard layoutState.activeRefreshTask == nil else { return }
        layoutState.didExecuteRefreshExecutionPlan = false
        layoutState.activeRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let didComplete = await execute(refresh)
            finishRefresh(refresh, didComplete: didComplete)
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
        let didExecuteRefreshExecutionPlan = layoutState.didExecuteRefreshExecutionPlan
        layoutState.activeRefreshTask = nil
        layoutState.didExecuteRefreshExecutionPlan = false
        if let runtime = controller?.runtime {
            _ = runtime.completeRefresh(
                .init(
                    refresh: refresh,
                    didComplete: didComplete,
                    didExecutePlan: didExecuteRefreshExecutionPlan
                )
            )
            return
        }

        let refreshSnapshot = refreshPlanningSnapshot()
        let result = OrchestrationCore.step(
            snapshot: orchestrationSnapshot(refresh: refreshSnapshot),
            event: .refreshCompleted(
                .init(
                    refresh: refresh,
                    didComplete: didComplete,
                    didExecutePlan: didExecuteRefreshExecutionPlan
                )
            )
        )
        applyRuntimeRefreshResult(result)
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

    private func performVisibilitySideEffects(on controller: WMController) {
        controller.niriLayoutHandler.updateTabbedColumnOverlays()
        refreshFocusedBorderForVisibilityState(on: controller)
    }

    func backingScale(for monitor: Monitor) -> CGFloat {
        ScreenLookupCache.shared.backingScale(for: monitor.displayId)
    }

    private func workspaceEntriesSnapshot(
        on controller: WMController
    ) -> [(workspace: WorkspaceDescriptor, entries: [WindowModel.Entry])] {
        controller.workspaceManager.workspaces.map { workspace in
            (workspace, controller.workspaceManager.entries(in: workspace.id))
        }
    }

    private func rebuildInactiveWorkspaceWindowSet(
        activeWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        workspaceEntries: [(workspace: WorkspaceDescriptor, entries: [WindowModel.Entry])]
    ) {
        guard let controller else { return }
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
    }

    func hideInactiveWorkspaces(
        activeWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        workspaceEntries: [(workspace: WorkspaceDescriptor, entries: [WindowModel.Entry])]? = nil,
        rebuildInactiveWorkspaceWindowSet shouldRebuildInactiveWorkspaceWindowSet: Bool = true
    ) {
        guard let controller else { return }
        let resolvedWorkspaceEntries = workspaceEntries ?? workspaceEntriesSnapshot(on: controller)

        if shouldRebuildInactiveWorkspaceWindowSet {
            rebuildInactiveWorkspaceWindowSet(
                activeWorkspaceIds: activeWorkspaceIds,
                workspaceEntries: resolvedWorkspaceEntries
            )
        }



        var inactiveWindowJobs: [(pid: pid_t, windowId: Int)] = []
        let topology = projectedTopology(controller: controller)
        let hiddenPlacementMonitors = hiddenPlacementMonitorContexts(from: topology)
        for snapshot in resolvedWorkspaceEntries where !activeWorkspaceIds.contains(snapshot.workspace.id) {
            for entry in snapshot.entries {
                inactiveWindowJobs.append((entry.handle.pid, entry.windowId))
            }
        }
        if !inactiveWindowJobs.isEmpty {
            controller.axManager.cancelPendingFrameJobs(inactiveWindowJobs)
        }

        let preferredSides = topology.preferredHideSides()
        for snapshot in resolvedWorkspaceEntries where !activeWorkspaceIds.contains(snapshot.workspace.id) {
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
        case alreadyHidden(hiddenState: WindowModel.HiddenState, origin: CGPoint)
        case unavailable
    }

    fileprivate func applyPositionPlans(_ plans: [WindowPositionPlan]) {
        guard let controller, !plans.isEmpty else { return }
        guard let runtime = controller.runtime else {
            preconditionFailure("LayoutRefreshController.applyPositionPlans requires WMRuntime to be attached")
        }

        controller.axManager.applyPositionsViaSkyLight(
            plans.map { (windowId: $0.entry.windowId, origin: $0.origin) },
            allowInactive: true
        )

        let verifyEpsilon: CGFloat = 1.0
        let shouldUseTestPositionOverride = controller.axManager
            .frameApplyOverrideConfirmsPositionPlansForTests
        for plan in plans {
            let targetFrame = CGRect(origin: plan.origin, size: plan.frameSize)
            if shouldUseTestPositionOverride {
                controller.axManager.confirmFrameWrite(
                    for: plan.entry.windowId,
                    pid: plan.entry.pid,
                    frame: targetFrame
                )
                continue
            }
            if let observedOrigin = observedWindowOrigin(plan.entry),
               abs(observedOrigin.x - plan.origin.x) <= verifyEpsilon,
               abs(observedOrigin.y - plan.origin.y) <= verifyEpsilon
            {
                controller.axManager.confirmFrameWrite(
                    for: plan.entry.windowId,
                    pid: plan.entry.pid,
                    frame: targetFrame
                )
                continue
            }

            let pendingWrite = runtime.recordPendingFrameWrite(
                frame: .init(rect: targetFrame, space: .appKit, isVisibleFrame: true),
                for: plan.entry.token
            )
            let result = AXWindowService.setFrame(plan.entry.axRef, frame: targetFrame)
            runtime.submitAXFrameWriteOutcome(
                for: plan.entry.token,
                requestId: pendingWrite.requestId,
                axFailure: result.failureReason,
                source: .ax
            )
            if result.isVerifiedSuccess {
                controller.axManager.confirmFrameWrite(
                    for: plan.entry.windowId,
                    pid: plan.entry.pid,
                    frame: result.observedFrame ?? targetFrame
                )
            }
        }
    }

    @discardableResult
    fileprivate func applyHidePositionPlans(_ plans: [WindowPositionPlan]) -> Set<WindowToken> {
        applyPositionPlans(plans)

        var verifiedTokens: Set<WindowToken> = []
        verifiedTokens.reserveCapacity(plans.count)
        for plan in plans {
            if verifyAppliedHideOrigin(for: plan.entry, expectedOrigin: plan.origin) {
                verifiedTokens.insert(plan.entry.token)
            }
        }
        return verifiedTokens
    }

    private func resolvedHideSourceFrame(
        for entry: WindowModel.Entry,
        frameHint: CGRect? = nil,
        treatLastAppliedFrameAsLive: Bool = true
    ) -> (liveFrame: CGRect?, sourceFrame: CGRect)? {
        let observedFrame = fastFrame(for: entry.token, axRef: entry.axRef)
            ?? (try? AXWindowService.frame(entry.axRef))
        let liveFrame = observedFrame
            ?? (treatLastAppliedFrameAsLive ? controller?.axManager.lastAppliedFrame(for: entry.windowId) : nil)
        guard let sourceFrame = liveFrame ?? frameHint else {
            return nil
        }
        return (liveFrame, sourceFrame)
    }

    private func buildHideRequest(
        for entry: WindowModel.Entry,
        monitor: Monitor,
        side: HideSide,
        reason: HideReason,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]? = nil,
        frameHint: CGRect? = nil,
        treatLastAppliedFrameAsLive: Bool = true
    ) -> LayoutHideRequest? {
        guard let source = resolvedHideSourceFrame(
            for: entry,
            frameHint: frameHint,
            treatLastAppliedFrameAsLive: treatLastAppliedFrameAsLive
        ),
              let origin = liveFrameHideOrigin(
                  for: source.sourceFrame,
                  monitor: monitor,
                  side: side,
                  pid: entry.handle.pid,
                  reason: reason,
                  hiddenPlacementMonitors: hiddenPlacementMonitors
              )
        else {
            return nil
        }

        return LayoutHideRequest(
            token: entry.token,
            side: side,
            hiddenFrame: CGRect(origin: origin, size: source.sourceFrame.size)
        )
    }

    fileprivate func resolveHideOperation(
        for entry: WindowModel.Entry,
        monitor: Monitor,
        request: LayoutHideRequest,
        reason: HideReason,
        frameHint: CGRect? = nil,
        workspaceIsCurrentlyActive: Bool,
        treatLastAppliedFrameAsLive: Bool = true
    ) -> HideOperationResolution {
        guard let source = resolvedHideSourceFrame(
            for: entry,
            frameHint: frameHint,
            treatLastAppliedFrameAsLive: treatLastAppliedFrameAsLive
        ) else {
            return .unavailable
        }

        let hiddenState = updatedHiddenState(
            for: entry,
            frame: source.sourceFrame,
            monitor: monitor,
            side: request.side,
            reason: reason,
            workspaceIsCurrentlyActive: workspaceIsCurrentlyActive
        )

        let moveEpsilon: CGFloat = 0.01
        if let liveFrame = source.liveFrame,
           abs(liveFrame.origin.x - request.hiddenFrame.origin.x) < moveEpsilon,
           abs(liveFrame.origin.y - request.hiddenFrame.origin.y) < moveEpsilon
        {
            return .alreadyHidden(
                hiddenState: hiddenState,
                origin: roundedHiddenOrigin(request.hiddenFrame.origin, for: entry.token)
            )
        }

        return .movable(
            WindowPositionPlan(
                entry: entry,
                origin: request.hiddenFrame.origin,
                frameSize: request.hiddenFrame.size
            ),
            hiddenState: hiddenState
        )
    }

    fileprivate func resolveHideOperation(
        for entry: WindowModel.Entry,
        monitor: Monitor,
        side: HideSide,
        reason: HideReason,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]? = nil,
        frameHint: CGRect? = nil,
        workspaceIsCurrentlyActive: Bool,
        treatLastAppliedFrameAsLive: Bool = true
    ) -> HideOperationResolution {
        guard let request = buildHideRequest(
            for: entry,
            monitor: monitor,
            side: side,
            reason: reason,
            hiddenPlacementMonitors: hiddenPlacementMonitors,
            frameHint: frameHint,
            treatLastAppliedFrameAsLive: treatLastAppliedFrameAsLive
        ) else {
            return .unavailable
        }

        return resolveHideOperation(
            for: entry,
            monitor: monitor,
            request: request,
            reason: reason,
            frameHint: frameHint,
            workspaceIsCurrentlyActive: workspaceIsCurrentlyActive,
            treatLastAppliedFrameAsLive: treatLastAppliedFrameAsLive
        )
    }

    private func updatedHiddenState(
        for entry: WindowModel.Entry,
        frame: CGRect,
        monitor: Monitor,
        side: HideSide,
        reason: HideReason,
        workspaceIsCurrentlyActive: Bool
    ) -> WindowModel.HiddenState {
        guard let controller else {
            return WindowModel.HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: hiddenWindowReason(
                    for: reason,
                    side: side,
                    existingState: nil,
                    workspaceIsCurrentlyActive: workspaceIsCurrentlyActive
                )
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
            reason: hiddenWindowReason(
                for: reason,
                side: side,
                existingState: existingState,
                workspaceIsCurrentlyActive: workspaceIsCurrentlyActive
            )
        )
    }

    private func hiddenWindowReason(
        for reason: HideReason,
        side: HideSide,
        existingState: WindowModel.HiddenState?,
        workspaceIsCurrentlyActive: Bool
    ) -> WindowModel.HiddenReason {
        if existingState?.isScratchpad == true, reason != .scratchpad {
            return .scratchpad
        }

        if existingState?.workspaceInactive == true,
           reason == .layoutTransient,
           !workspaceIsCurrentlyActive
        {
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
        let frameHint: CGRect? = if reason == .workspaceInactive {
            workspaceInactiveFrameHint(for: entry)
        } else {
            nil
        }
        let workspaceIsCurrentlyActive = workspaceIsCurrentlyActive(entry.workspaceId)
        let treatLastAppliedFrameAsLive = reason != .workspaceInactive
        let usingWorkspaceInactiveFrameHint = reason == .workspaceInactive
            && frameHint != nil
            && resolvedHideSourceFrame(
                for: entry,
                frameHint: frameHint,
                treatLastAppliedFrameAsLive: treatLastAppliedFrameAsLive
            )?.liveFrame == nil
        switch resolveHideOperation(
            for: entry,
            monitor: monitor,
            side: side,
            reason: reason,
            hiddenPlacementMonitors: hiddenPlacementMonitors,
            frameHint: frameHint,
            workspaceIsCurrentlyActive: workspaceIsCurrentlyActive,
            treatLastAppliedFrameAsLive: treatLastAppliedFrameAsLive
        ) {
        case let .movable(plan, hiddenState):
            let normalizedHiddenState = normalizedHiddenStateForCurrentWorkspace(
                hiddenState,
                workspaceIsCurrentlyActive: workspaceIsCurrentlyActive,
                side: side
            )
            controller.axManager.cancelPendingFrameJobs([frameEntry])
            if usingWorkspaceInactiveFrameHint {
                applyPositionPlans([plan])
                guard verifyAppliedHideOrigin(for: entry, expectedOrigin: plan.origin) else {
                    handleUnavailableWorkspaceInactiveHide(entry)
                    return
                }
                setHiddenState(normalizedHiddenState, for: entry.token)
                controller.axManager.suppressFrameWrites([frameEntry])
                rememberHiddenOrigin(for: entry.token, origin: plan.origin)
                return
            }

            setHiddenState(
                normalizedHiddenState,
                for: entry.token
            )
            controller.axManager.suppressFrameWrites([frameEntry])
            let verifiedHideTokens = applyHidePositionPlans([plan])
            rememberHiddenOrigin(
                for: entry.token,
                origin: plan.origin,
                verified: verifiedHideTokens.contains(entry.token)
            )
        case let .alreadyHidden(hiddenState, origin):
            setHiddenState(
                normalizedHiddenStateForCurrentWorkspace(
                    hiddenState,
                    workspaceIsCurrentlyActive: workspaceIsCurrentlyActive,
                    side: side
                ),
                for: entry.token
            )
            controller.axManager.cancelPendingFrameJobs([frameEntry])
            controller.axManager.suppressFrameWrites([frameEntry])
            rememberHiddenOrigin(for: entry.token, origin: origin)
        case .unavailable:
            guard reason == .workspaceInactive else { break }
            handleUnavailableWorkspaceInactiveHide(entry)
        }
    }

    private func workspaceInactiveFrameHint(for entry: WindowModel.Entry) -> CGRect? {
        guard let controller else { return nil }
        return controller.axManager.lastAppliedFrame(for: entry.windowId)
            ?? controller.workspaceManager.managedRestoreSnapshot(for: entry.token)?.frame
            ?? controller.workspaceManager.nativeFullscreenRestoreContext(for: entry.token)?.restoreFrame
    }

    fileprivate func normalizedHiddenStateForCurrentWorkspace(
        _ hiddenState: WindowModel.HiddenState,
        workspaceIsCurrentlyActive: Bool,
        side: HideSide
    ) -> WindowModel.HiddenState {
        guard workspaceIsCurrentlyActive, hiddenState.workspaceInactive else {
            return hiddenState
        }

        return WindowModel.HiddenState(
            proportionalPosition: hiddenState.proportionalPosition,
            referenceMonitorId: hiddenState.referenceMonitorId,
            reason: .layoutTransient(side)
        )
    }

    private func handleUnavailableWorkspaceInactiveHide(_ entry: WindowModel.Entry) {
        guard let controller else { return }

        let frameEntry = [(entry.handle.pid, entry.windowId)]
        controller.axManager.cancelPendingFrameJobs(frameEntry)
        controller.axManager.suppressFrameWrites(frameEntry)

        let remainingRetries = workspaceInactiveHideRetryCountByWindowId[entry.windowId] ?? 1
        guard remainingRetries > 0 else {
            workspaceInactiveHideAwaitingFreshFrameWindowIds.insert(entry.windowId)
            return
        }

        workspaceInactiveHideRetryCountByWindowId[entry.windowId] = remainingRetries - 1
        requestRelayout(
            reason: .axWindowChanged,
            affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    private func verifyAppliedHideOrigin(
        for entry: WindowModel.Entry,
        expectedOrigin: CGPoint
    ) -> Bool {
        let verifyEpsilon: CGFloat = 1.0
        let candidateOrigins = [
            observedWindowOrigin(entry),
            controller?.axManager.lastAppliedFrame(for: entry.windowId)?.origin,
            (try? AXWindowService.frame(entry.axRef))?.origin,
        ].compactMap { $0 }
        return candidateOrigins.contains { observedOrigin in
            abs(observedOrigin.x - expectedOrigin.x) <= verifyEpsilon
                && abs(observedOrigin.y - expectedOrigin.y) <= verifyEpsilon
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
            ?? hiddenPlacementMonitorContexts(from: projectedTopology(controller: controller))

        switch reason {
        case .scratchpad, .workspaceInactive:
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

    func unhideWindow(
        _ entry: WindowModel.Entry,
        monitor: Monitor,
        onSuccess: PostLayoutAction? = nil
    ) {
        guard let controller else { return }
        guard let hiddenState = controller.workspaceManager.hiddenState(for: entry.token) else {
            controller.axManager.unsuppressFrameWrites([(entry.handle.pid, entry.windowId)])
            return
        }
        guard hiddenState.workspaceInactive else { return }

        executeHiddenReveal(
            entry,
            monitor: monitor,
            hiddenState: hiddenState,
            onSuccess: onSuccess
        )
    }

    func restoreScratchpadWindow(
        _ entry: WindowModel.Entry,
        monitor: Monitor,
        onSuccess: PostLayoutAction? = nil
    ) {
        guard let controller,
              let hiddenState = controller.workspaceManager.hiddenState(for: entry.token),
              hiddenState.isScratchpad
        else {
            return
        }

        executeHiddenReveal(
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

    private func preferredHideSides() -> [Monitor.ID: HideSide] {
        guard let controller else { return [:] }
        return projectedTopology(controller: controller).preferredHideSides()
    }

    func preferredHideSide(for monitor: Monitor) -> HideSide {
        guard let controller else { return .right }
        return projectedTopology(controller: controller)
            .preferredHideSides()[monitor.id] ?? .right
    }

    private func projectedTopology(controller: WMController) -> MonitorTopologyState {
        MonitorTopologyState.project(
            manager: controller.workspaceManager,
            settings: controller.settings,
            epoch: controller.runtime?.currentTopologyEpoch ?? .invalid,
            insetWorkingFrame: { mon in
                controller.insetWorkingFrame(for: mon)
            }
        )
    }

    private func hiddenPlacementMonitorContexts(
        from topology: MonitorTopologyState
    ) -> [HiddenPlacementMonitorContext] {
        topology.order.compactMap { monitorId in
            topology.node(monitorId).map(HiddenPlacementMonitorContext.init)
        }
    }

    fileprivate func hasPendingRevealTransaction(for windowId: Int) -> Bool {
        pendingRevealTransactionsByWindowId[windowId] != nil
    }

    fileprivate func shouldUsePendingRevealTransaction(
        for entry: WindowModel.Entry,
        hiddenState: WindowModel.HiddenState
    ) -> Bool {
        !hiddenState.workspaceInactive
            && entry.mode == .floating
            && hiddenState.restoresViaFloatingState
    }

    fileprivate func beginPendingRevealTransaction(
        for entry: WindowModel.Entry,
        hiddenState: WindowModel.HiddenState,
        targetFrame: CGRect,
        monitor: Monitor,
        onSuccess: PostLayoutAction? = nil
    ) -> Bool {
        if var pendingTransaction = pendingRevealTransactionsByWindowId[entry.windowId] {
            if let onSuccess {
                pendingTransaction.postSuccessActions.append(onSuccess)
                pendingRevealTransactionsByWindowId[entry.windowId] = pendingTransaction
            }
            return false
        }

        pendingRevealTransactionsByWindowId[entry.windowId] = PendingRevealTransaction(
            token: entry.token,
            pid: entry.pid,
            windowId: entry.windowId,
            targetFrame: targetFrame,
            targetMonitorId: monitor.id,
            hiddenState: hiddenState,
            postSuccessActions: onSuccess.map { [$0] } ?? []
        )
        return true
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
        pendingRevealTransactionsByWindowId[newWindowId] = transaction
        pendingRevealWindowIdRedirects[oldWindowId] = newWindowId
        for (sourceWindowId, targetWindowId) in pendingRevealWindowIdRedirects where targetWindowId == oldWindowId {
            pendingRevealWindowIdRedirects[sourceWindowId] = newWindowId
        }
        pendingRevealWindowIdRedirects.removeValue(forKey: newWindowId)

        if let verificationTask = pendingRevealVerificationTasksByWindowId.removeValue(forKey: oldWindowId) {
            verificationTask.cancel()
            if transaction.delayedVerificationScheduled {
                scheduleDelayedRevealVerification(forWindowId: newWindowId)
            }
        }

    }

    fileprivate func completePendingRevealTransaction(with result: AXFrameApplyResult) {
        guard let windowId = resolvedPendingRevealWindowId(for: result.windowId) else {
            return
        }


        switch hiddenRevealTerminalOutcome(for: result) {
        case .success:
            finalizePendingRevealTransactionSuccess(
                forWindowId: windowId,
                confirmedFrame: result.confirmedFrame
            )
        case .delayedVerification:
            guard var pendingTransaction = pendingRevealTransactionsByWindowId[windowId],
                  !pendingTransaction.delayedVerificationScheduled
            else {
                return
            }
            pendingTransaction.delayedVerificationScheduled = true
            pendingRevealTransactionsByWindowId[windowId] = pendingTransaction
            scheduleDelayedRevealVerification(forWindowId: windowId)
        case .failure:
            finalizePendingRevealTransactionFailure(forWindowId: windowId)
        }
    }

    private func resolvedPendingRevealWindowId(for windowId: Int) -> Int? {
        if pendingRevealTransactionsByWindowId[windowId] != nil {
            return windowId
        }
        guard let redirectedWindowId = pendingRevealWindowIdRedirects[windowId] else {
            return nil
        }
        if pendingRevealTransactionsByWindowId[redirectedWindowId] != nil {
            return redirectedWindowId
        }
        pendingRevealWindowIdRedirects.removeValue(forKey: windowId)
        return nil
    }

    private func hiddenRevealTerminalOutcome(for result: AXFrameApplyResult) -> HiddenRevealTerminalOutcome {
        if result.confirmedFrame != nil {
            return .success
        }

        switch result.writeResult.failureReason {
        case .readbackFailed, .verificationMismatch:
            return .delayedVerification
        default:
            return .failure
        }
    }

    private func finalizePendingRevealTransactionSuccess(
        forWindowId windowId: Int,
        confirmedFrame: CGRect?
    ) {
        guard let controller,
              let pendingTransaction = pendingRevealTransactionsByWindowId.removeValue(forKey: windowId)
        else {
            return
        }
        pendingRevealVerificationTasksByWindowId.removeValue(forKey: windowId)?.cancel()
        clearPendingRevealRedirects(forWindowId: windowId)

        clearHiddenRecord(for: pendingTransaction.token)
        if let confirmedFrame {
            controller.axManager.confirmFrameWrite(
                for: pendingTransaction.windowId,
                pid: pendingTransaction.pid,
                frame: confirmedFrame
            )
        }
        for action in pendingTransaction.postSuccessActions {
            action()
        }
    }

    private func finalizePendingRevealTransactionFailure(forWindowId windowId: Int) {
        guard let controller,
              let pendingTransaction = pendingRevealTransactionsByWindowId.removeValue(forKey: windowId)
        else {
            return
        }
        pendingRevealVerificationTasksByWindowId.removeValue(forKey: windowId)?.cancel()
        clearPendingRevealRedirects(forWindowId: windowId)
        let frameEntry = [(pendingTransaction.pid, pendingTransaction.windowId)]

        if pendingTransaction.hiddenState.workspaceInactive {
            clearHiddenRecord(for: pendingTransaction.token)
            controller.axManager.unsuppressFrameWrites(frameEntry)
            return
        }

        if controller.workspaceManager.hiddenState(for: pendingTransaction.token) == nil {
            setHiddenState(pendingTransaction.hiddenState, for: pendingTransaction.token)
        }
        if controller.workspaceManager.hiddenState(for: pendingTransaction.token) != nil {
            controller.axManager.suppressFrameWrites(frameEntry)
        }
    }

    private func scheduleDelayedRevealVerification(forWindowId windowId: Int) {
        pendingRevealVerificationTasksByWindowId[windowId]?.cancel()
        pendingRevealVerificationTasksByWindowId[windowId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.delayedRevealVerificationDelay)
            guard let self else { return }
            let verifiedFrame = delayedVerifiedRevealFrame(forWindowId: windowId)
            if let verifiedFrame {
                finalizePendingRevealTransactionSuccess(
                    forWindowId: windowId,
                    confirmedFrame: verifiedFrame
                )
            } else {
                finalizePendingRevealTransactionFailure(forWindowId: windowId)
            }
        }
    }

    private func clearPendingRevealRedirects(forWindowId windowId: Int) {
        pendingRevealWindowIdRedirects.removeValue(forKey: windowId)
        pendingRevealWindowIdRedirects = pendingRevealWindowIdRedirects.filter { sourceWindowId, targetWindowId in
            sourceWindowId != windowId && targetWindowId != windowId
        }
    }

    private func delayedVerifiedRevealFrame(forWindowId windowId: Int) -> CGRect? {
        guard let controller,
              let pendingTransaction = pendingRevealTransactionsByWindowId[windowId],
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
    ) {
        guard let controller else { return }
        let frameEntry = [(entry.handle.pid, entry.windowId)]
        switch restoreWindowFromHiddenState(entry, monitor: monitor, hiddenState: hiddenState) {
        case .none:
            if hiddenState.workspaceInactive {
                clearHiddenRecord(for: entry.token)
                controller.axManager.unsuppressFrameWrites(frameEntry)
                onSuccess?()
            } else {
                controller.axManager.suppressFrameWrites(frameEntry)
            }
        case let .positionPlan(plan):
            applyPositionPlans([plan])
            clearHiddenRecord(for: entry.token)
            controller.axManager.unsuppressFrameWrites(frameEntry)
            onSuccess?()
        case let .asyncFrame(frame):
            if !shouldUsePendingRevealTransaction(for: entry, hiddenState: hiddenState) {
                clearHiddenRecord(for: entry.token)
                controller.axManager.unsuppressFrameWrites(frameEntry)
                controller.axManager.forceApplyNextFrame(for: entry.windowId)
                controller.axManager.applyFramesParallel([(entry.pid, entry.windowId, frame)])
                onSuccess?()
                return
            }
            guard beginPendingRevealTransaction(
                for: entry,
                hiddenState: hiddenState,
                targetFrame: frame,
                monitor: monitor,
                onSuccess: onSuccess
            ) else {
                return
            }
            controller.axManager.unsuppressFrameWrites(frameEntry)
            controller.axManager.forceApplyNextFrame(for: entry.windowId)
            controller.axManager.applyFramesParallel(
                [(entry.pid, entry.windowId, frame)],
                terminalObserver: { [weak self] result in
                    self?.completePendingRevealTransaction(with: result)
                }
            )
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
        guard var frame = fastFrame(for: entry.token, axRef: entry.axRef)
            ?? controller.axManager.lastAppliedFrame(for: entry.windowId)
        else {
            return nil
        }

        if let hiddenOrigin = lastAppliedHideOrigin(for: entry.token) {
            frame.origin = hiddenOrigin
        }

        let fallbackMonitor = hiddenState.referenceMonitorId
            .flatMap { controller.workspaceManager.monitor(byId: $0) }
        let restoreFrame: CGRect = if monitor.frame.width > 1, monitor.frame.height > 1 {
            monitor.frame
        } else {
            fallbackMonitor?.frame ?? monitor.frame
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

    func restoredFrameForHiddenEntry(
        _ entry: WindowModel.Entry,
        monitor: Monitor,
        hiddenState: WindowModel.HiddenState
    ) -> CGRect? {
        makeRestorePositionPlan(
            for: entry,
            monitor: monitor,
            hiddenState: hiddenState
        ).map { CGRect(origin: $0.origin, size: $0.frameSize) }
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
        let clampedX: CGFloat = if maxX >= minX {
            min(max(topLeft.x, minX), maxX)
        } else {
            minX
        }

        let minTopLeftY = frame.minY + windowSize.height
        let maxTopLeftY = frame.maxY
        let clampedTopLeftY: CGFloat = if maxTopLeftY >= minTopLeftY {
            min(max(topLeft.y, minTopLeftY), maxTopLeftY)
        } else {
            maxTopLeftY
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

    func updateWindowConstraints(
        in wsId: WorkspaceDescriptor.ID,
        updateEngine: (WindowToken, WindowSizeConstraints) -> Void
    ) {
        guard let controller else { return }
        let graph = controller.workspaceManager.workspaceGraphSnapshot()
        let entries = graph.tiledMembership(in: wsId).compactMap {
            controller.workspaceManager.entry(for: $0.token)
        }
        let snapshots = buildWindowSnapshots(for: entries)
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

    // swiftlint:disable:next function_body_length
    func execute(_ plan: WorkspaceLayoutPlan) {
        guard let controller = refreshController.controller,
              let monitor = resolveMonitor(from: plan.monitor, controller: controller)
        else {
            return
        }

        let diff = plan.diff

        var resolvedEntries: [WindowToken: WindowModel.Entry] = [:]
        var hiddenEntries: [(entry: WindowModel.Entry, request: LayoutHideRequest)] = []
        var hiddenTokens: Set<WindowToken> = []
        var shownEntries: [(entry: WindowModel.Entry, hiddenState: WindowModel.HiddenState?)] = []
        var restoreEntries: [(entry: WindowModel.Entry, hiddenState: WindowModel.HiddenState)] = []
        var restoreTokens: Set<WindowToken> = []
        var frameChangeByToken: [WindowToken: CGRect] = [:]
        var pendingRevealTokens: Set<WindowToken> = []
        var blockedRevealTokens: Set<WindowToken> = []
        let nativeFullscreenRestoreFinalizeTokens = Set(plan.nativeFullscreenRestoreFinalizeTokens)
        var nativeFullscreenRestoreFramesByToken: [WindowToken: CGRect] = [:]
        for change in diff.frameChanges {
            frameChangeByToken[change.token] = change.frame
        }

        func handleNativeFullscreenRestoreTerminalResult(_ result: AXFrameApplyResult) {
            let token = WindowToken(pid: result.pid, windowId: result.windowId)
            guard let restoreFrame = nativeFullscreenRestoreFramesByToken[token],
                  let confirmedFrame = result.confirmedFrame,
                  confirmedFrame.approximatelyEqual(to: restoreFrame, tolerance: 1.0)
            else {
                return
            }
            guard let runtime = controller.runtime else {
                preconditionFailure("LayoutRefreshController.finalizeNativeFullscreenRestore (frame-confirm) requires WMRuntime to be attached")
            }
            _ = runtime.finalizeNativeFullscreenRestore(for: token, source: .service)
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

        for change in diff.visibilityChanges {
            switch change {
            case let .show(token):
                guard let entry = resolveEntry(for: token) else { continue }
                guard entry.layoutReason != .nativeFullscreen else { continue }
                shownEntries.append((entry, controller.workspaceManager.hiddenState(for: token)))
            case let .hide(request):
                hiddenTokens.insert(request.token)
                guard let entry = resolveEntry(for: request.token) else { continue }
                guard entry.layoutReason != .nativeFullscreen else { continue }
                hiddenEntries.append((entry, request))
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

        if !nativeFullscreenRestoreFinalizeTokens.isEmpty {
            let shownTokens = Set(shownEntries.map(\.entry.token))
            let stableHiddenJobs = controller.workspaceManager.entries(in: plan.workspaceId)
                .compactMap { entry -> (pid: pid_t, windowId: Int)? in
                    guard controller.workspaceManager.hiddenState(for: entry.token) != nil,
                          !nativeFullscreenRestoreFinalizeTokens.contains(entry.token),
                          !hiddenTokens.contains(entry.token),
                          !shownTokens.contains(entry.token),
                          !restoreTokens.contains(entry.token)
                    else {
                        return nil
                    }
                    return (entry.pid, entry.windowId)
                }
            if !stableHiddenJobs.isEmpty {
                // Native fullscreen restore may apply frames to a focused
                // sibling while unchanged Niri hidden columns stay suppressed.
                // Refreshing suppression clears stale AX frame cache without
                // issuing another offscreen move.
                controller.axManager.suppressFrameWrites(stableHiddenJobs)
            }
        }

        for (entry, hiddenState) in restoreEntries {
            guard refreshController.shouldUsePendingRevealTransaction(
                for: entry,
                hiddenState: hiddenState
            ) else {
                continue
            }
            if let targetFrame = frameChangeByToken[entry.token] {
                if refreshController.beginPendingRevealTransaction(
                    for: entry,
                    hiddenState: hiddenState,
                    targetFrame: targetFrame,
                    monitor: monitor
                ) {
                    pendingRevealTokens.insert(entry.token)
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
                if refreshController.beginPendingRevealTransaction(
                    for: entry,
                    hiddenState: hiddenState,
                    targetFrame: targetFrame,
                    monitor: monitor
                ) {
                    pendingRevealTokens.insert(entry.token)
                } else {
                    blockedRevealTokens.insert(entry.token)
                }
            } else if refreshController.hasPendingRevealTransaction(for: entry.windowId) {
                blockedRevealTokens.insert(entry.token)
            }
        }

        let preExistingHiddenEntryTokens = Set(
            hiddenEntries.compactMap { entry, _ in
                controller.workspaceManager.hiddenState(for: entry.token) == nil ? nil : entry.token
            }
        )
        if !hiddenEntries.isEmpty {
            applyHiddenEntryUpdates(
                hiddenEntries,
                controller: controller,
                monitor: monitor,
                nativeFullscreenRestoreFinalizeTokens: nativeFullscreenRestoreFinalizeTokens
            )
        }

        if !restoreEntries.isEmpty {
            let restorePlans: [LayoutRefreshController.WindowPositionPlan] = restoreEntries
                .compactMap { entry, hiddenState in
                    guard !blockedRevealTokens.contains(entry.token),
                          !pendingRevealTokens.contains(entry.token),
                          frameChangeByToken[entry.token] == nil
                    else { return nil }
                    return refreshController.makeRestorePositionPlan(
                        for: entry,
                        monitor: monitor,
                        hiddenState: hiddenState
                    )
                }
            refreshController.applyPositionPlans(restorePlans)

            for (entry, _) in restoreEntries
                where !pendingRevealTokens.contains(entry.token)
                && !blockedRevealTokens.contains(entry.token)
            {
                refreshController.clearHiddenRecord(for: entry.token)
            }
        }

        if !shownEntries.isEmpty {
            for (entry, _) in shownEntries
                where !restoreTokens.contains(entry.token)
                && !pendingRevealTokens.contains(entry.token)
                && !blockedRevealTokens.contains(entry.token)
            {
                refreshController.clearHiddenRecord(for: entry.token)
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
        var revealFrameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []
        revealFrameUpdates.reserveCapacity(pendingRevealTokens.count)
        let hiddenEntryTokens = Set(hiddenEntries.map { $0.entry.token })

        for change in diff.frameChanges {
            guard !hiddenTokens.contains(change.token),
                  let entry = resolveEntry(for: change.token),
                  !blockedRevealTokens.contains(change.token)
            else {
                continue
            }
            guard entry.layoutReason != .nativeFullscreen
                || nativeFullscreenRestoreFinalizeTokens.contains(change.token)
            else {
                continue
            }
            if pendingRevealTokens.contains(change.token) {
                controller.axManager.forceApplyNextFrame(for: entry.windowId)
            }
            if pendingRevealTokens.contains(change.token) {
                revealFrameUpdates.append((entry.pid, entry.windowId, change.frame))
            } else {
                if change.forceApply {
                    controller.axManager.forceApplyNextFrame(for: entry.windowId)
                }
                frameUpdates.append((entry.pid, entry.windowId, change.frame))
            }
            if nativeFullscreenRestoreFinalizeTokens.contains(change.token) {
                nativeFullscreenRestoreFramesByToken[change.token] = change.frame
            }
        }

        for token in nativeFullscreenRestoreFinalizeTokens
            where nativeFullscreenRestoreFramesByToken[token] == nil
        {
            let nativeFullscreenRecord = controller.workspaceManager.nativeFullscreenRecord(for: token)
            let isReplacementRestore = nativeFullscreenRecord.map { $0.originalToken != token } ?? false
            guard !(hiddenEntryTokens.contains(token)
                    && controller.workspaceManager.hiddenState(for: token) != nil
                    && !isReplacementRestore
                    && !preExistingHiddenEntryTokens.contains(token)
                    && refreshController.lastVerifiedHideOrigin(for: token) == nil),
                  !blockedRevealTokens.contains(token),
                  let entry = resolveEntry(for: token),
                  let restoreFrame = controller.workspaceManager.nativeFullscreenRestoreContext(for: token)?
                      .restoreFrame
            else {
                continue
            }
            if hiddenTokens.contains(token) {
                setHiddenState(nil, for: token, controller: controller)
                controller.axManager.unsuppressFrameWrites([(entry.pid, entry.windowId)])
            }
            controller.axManager.forceApplyNextFrame(for: entry.windowId)
            frameUpdates.append((entry.pid, entry.windowId, restoreFrame))
            nativeFullscreenRestoreFramesByToken[token] = restoreFrame
        }

        var appliedFrameTokens: Set<WindowToken> = []
        let mustApplyForNativeFullscreenRestore = !nativeFullscreenRestoreFramesByToken.isEmpty
        if (mustApplyForNativeFullscreenRestore || !plan.skipFrameApplicationForAnimation)
            && !frameUpdates.isEmpty
        {
            appliedFrameTokens.formUnion(
                frameUpdates.map { WindowToken(pid: $0.pid, windowId: $0.windowId) }
            )
            let terminalObserver: AXManager.FrameApplicationTerminalObserver? = if nativeFullscreenRestoreFramesByToken
                .isEmpty
            {
                nil
            } else {
                { @MainActor @Sendable result in
                    handleNativeFullscreenRestoreTerminalResult(result)
                }
            }
            controller.axManager.applyFramesParallel(
                frameUpdates,
                terminalObserver: terminalObserver
            )
        }

        if !revealFrameUpdates.isEmpty {
            appliedFrameTokens.formUnion(
                revealFrameUpdates.map { WindowToken(pid: $0.pid, windowId: $0.windowId) }
            )
            controller.axManager.applyFramesParallel(
                revealFrameUpdates,
                terminalObserver: { [weak refreshController] result in
                    refreshController?.completePendingRevealTransaction(with: result)
                    handleNativeFullscreenRestoreTerminalResult(result)
                }
            )
        }

        applyManagedRestoreMaterialStateChanges(
            plan.managedRestoreMaterialStateChanges,
            excluding: appliedFrameTokens,
            controller: controller
        )

        switch diff.borderMode {
        case .none:
            break
        case .hidden:
            controller.hideKeyboardFocusBorder(
                source: .borderReapplyPostLayout,
                reason: "layout requested focused border hide"
            )
        case .direct:
            applyDirectBorderUpdate(diff.focusedFrame)
        case .coordinated:
            applyCoordinatedBorderUpdate(diff.focusedFrame)
        }
    }

    private func setHiddenState(
        _ state: WindowModel.HiddenState?,
        for token: WindowToken,
        controller: WMController
    ) {
        guard let runtime = controller.runtime else {
            preconditionFailure("LayoutRefreshController.setHiddenState (controller-scoped) requires WMRuntime to be attached")
        }
        runtime.setHiddenState(state, for: token, source: .service)
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

    private func applyManagedRestoreMaterialStateChanges(
        _ changes: [ManagedRestoreMaterialStateChange],
        excluding appliedFrameTokens: Set<WindowToken>,
        controller: WMController
    ) {
        guard !changes.isEmpty else { return }

        var seenTokens: Set<WindowToken> = []
        for change in changes
            where !appliedFrameTokens.contains(change.token)
            && seenTokens.insert(change.token).inserted
        {
            controller.recordManagedRestoreGeometryIfMaterialStateChanged(
                for: CGWindowID(change.token.windowId),
                reason: change.reason
            )
        }
    }

    private func applyHiddenEntryUpdates(
        _ hiddenEntries: [(entry: WindowModel.Entry, request: LayoutHideRequest)],
        controller: WMController,
        monitor: Monitor,
        nativeFullscreenRestoreFinalizeTokens: Set<WindowToken>
    ) {
        var hiddenJobs: [(pid: pid_t, windowId: Int)] = []
        hiddenJobs.reserveCapacity(hiddenEntries.count)
        var hidePlans: [LayoutRefreshController.WindowPositionPlan] = []
        var hideOriginsToRemember: [(token: WindowToken, origin: CGPoint)] = []
        var finalizeTokensAlreadyHidden: Set<WindowToken> = []
        var finalizeTokensMovable: Set<WindowToken> = []

        for (entry, request) in hiddenEntries {
            let nativeFullscreenRestoreFrameHint: CGRect? = if nativeFullscreenRestoreFinalizeTokens
                .contains(entry.token)
            {
                controller.workspaceManager
                    .nativeFullscreenRestoreContext(for: entry.token)?.restoreFrame
            } else {
                nil
            }
            let workspaceIsCurrentlyActive = refreshController.workspaceIsCurrentlyActive(entry.workspaceId)
            switch refreshController.resolveHideOperation(
                for: entry,
                monitor: monitor,
                request: request,
                reason: .layoutTransient,
                frameHint: nativeFullscreenRestoreFrameHint,
                workspaceIsCurrentlyActive: workspaceIsCurrentlyActive
            ) {
            case let .movable(plan, hiddenState):
                let normalizedHiddenState = refreshController.normalizedHiddenStateForCurrentWorkspace(
                    hiddenState,
                    workspaceIsCurrentlyActive: workspaceIsCurrentlyActive,
                    side: request.side
                )
                setHiddenState(normalizedHiddenState, for: entry.token, controller: controller)
                hiddenJobs.append((entry.handle.pid, entry.windowId))
                hidePlans.append(plan)
                hideOriginsToRemember.append((token: entry.token, origin: plan.origin))
                if nativeFullscreenRestoreFinalizeTokens.contains(entry.token) {
                    finalizeTokensMovable.insert(entry.token)
                }
            case let .alreadyHidden(hiddenState, origin):
                let normalizedHiddenState = refreshController.normalizedHiddenStateForCurrentWorkspace(
                    hiddenState,
                    workspaceIsCurrentlyActive: workspaceIsCurrentlyActive,
                    side: request.side
                )
                setHiddenState(normalizedHiddenState, for: entry.token, controller: controller)
                hiddenJobs.append((entry.handle.pid, entry.windowId))
                refreshController.rememberHiddenOrigin(for: entry.token, origin: origin)
                if nativeFullscreenRestoreFinalizeTokens.contains(entry.token) {
                    finalizeTokensAlreadyHidden.insert(entry.token)
                }
            case .unavailable:
                continue
            }
        }

        if !hiddenJobs.isEmpty {
            controller.axManager.cancelPendingFrameJobs(hiddenJobs)
            controller.axManager.suppressFrameWrites(hiddenJobs)
        }
        if !hidePlans.isEmpty {
            let verifiedHideTokens = refreshController.applyHidePositionPlans(hidePlans)
            for hideOrigin in hideOriginsToRemember {
                refreshController.rememberHiddenOrigin(
                    for: hideOrigin.token,
                    origin: hideOrigin.origin,
                    verified: verifiedHideTokens.contains(hideOrigin.token)
                )
            }
            finalizeTokensMovable.formIntersection(verifiedHideTokens)
        }
        guard let runtime = controller.runtime else {
            preconditionFailure("LayoutRefreshController.applyFinalizeMovableVisibilityTransitions requires WMRuntime to be attached")
        }
        for token in finalizeTokensAlreadyHidden.union(finalizeTokensMovable) {
            _ = runtime.finalizeNativeFullscreenRestore(for: token, source: .service)
        }
    }

    private func applyDirectBorderUpdate(_ focusedFrame: LayoutFocusedFrame?) {
        guard let controller = refreshController.controller else { return }
        let target = resolvedBorderRenderTarget(controller: controller, focusedFrame: focusedFrame)
        let fallbackPreferredFrame: CGRect? = if let target, target.isManaged {
            controller.preferredKeyboardFocusFrame(for: target.token)
        } else {
            nil
        }
        if target?.isManaged == true,
           focusedFrame == nil,
           fallbackPreferredFrame == nil
        {
            if shouldPreserveManagedBorderDuringPendingActivation(target: target, controller: controller) {
                return
            }
            controller.hideKeyboardFocusBorder(
                source: .borderReapplyPostLayout,
                reason: "managed direct border update had no frame"
            )
            return
        }
        guard !shouldIgnoreStaleManagedBorderUpdate(target: target, focusedFrame: focusedFrame) else {
            return
        }
        let preferredFrame: CGRect? = if let target,
                                         target.isManaged,
                                         focusedFrame?.token == target.token
        {
            focusedFrame?.frame
        } else {
            fallbackPreferredFrame
        }
        _ = controller.renderKeyboardFocusBorder(
            for: target,
            preferredFrame: preferredFrame,
            policy: .direct,
            source: .borderReapplyPostLayout
        )
    }

    private func applyCoordinatedBorderUpdate(_ focusedFrame: LayoutFocusedFrame?) {
        guard let controller = refreshController.controller else { return }
        let target = resolvedBorderRenderTarget(controller: controller, focusedFrame: focusedFrame)
        let fallbackPreferredFrame: CGRect? = if let target, target.isManaged {
            controller.preferredKeyboardFocusFrame(for: target.token)
        } else {
            nil
        }
        if target?.isManaged == true,
           focusedFrame == nil,
           fallbackPreferredFrame == nil
        {
            if shouldPreserveManagedBorderDuringPendingActivation(target: target, controller: controller) {
                return
            }
            controller.hideKeyboardFocusBorder(
                source: .borderReapplyPostLayout,
                reason: "managed coordinated border update had no frame"
            )
            return
        }
        guard !shouldIgnoreStaleManagedBorderUpdate(target: target, focusedFrame: focusedFrame) else {
            return
        }
        let preferredFrame: CGRect? = if let target,
                                         target.isManaged,
                                         focusedFrame?.token == target.token
        {
            focusedFrame?.frame
        } else {
            fallbackPreferredFrame
        }
        _ = controller.renderKeyboardFocusBorder(
            for: target,
            preferredFrame: preferredFrame,
            policy: .coordinated,
            source: .borderReapplyPostLayout
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

    private func shouldPreserveManagedBorderDuringPendingActivation(
        target: KeyboardFocusTarget?,
        controller: WMController
    ) -> Bool {
        guard let target,
              target.isManaged,
              controller.workspaceManager.pendingFocusedToken != nil
        else {
            return false
        }
        return controller.workspaceManager.focusedToken == target.token
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
