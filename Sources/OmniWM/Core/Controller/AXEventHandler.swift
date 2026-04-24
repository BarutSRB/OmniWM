// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation

enum ActivationRetryReason: String, Equatable {
    case missingFocusedWindow = "missing_focused_window"
    case pendingFocusMismatch = "pending_focus_mismatch"
    case pendingFocusUnmanagedToken = "pending_focus_unmanaged_token"
    case retryExhausted = "retry_exhausted"
}

enum ActivationCallOrigin: String, Equatable {
    case external
    case probe
    case retry
}

@MainActor
final class AXEventHandler: CGSEventDelegate {
    struct DebugCounters {
        var geometryRelayoutRequests = 0
        var geometryRelayoutsSuppressedDuringGesture = 0
    }

    private struct PreparedCreate {
        let windowId: UInt32
        let token: WindowToken
        let axRef: AXWindowRef
        let ruleEffects: ManagedWindowRuleEffects
        let replacementMetadata: ManagedReplacementMetadata

        var bundleId: String? { replacementMetadata.bundleId }
        var workspaceId: WorkspaceDescriptor.ID { replacementMetadata.workspaceId }
        var mode: TrackedWindowMode { replacementMetadata.mode }
    }

    private struct PreparedDestroy {
        let token: WindowToken
        let replacementMetadata: ManagedReplacementMetadata

        var bundleId: String? { replacementMetadata.bundleId }
        var workspaceId: WorkspaceDescriptor.ID { replacementMetadata.workspaceId }
        var mode: TrackedWindowMode { replacementMetadata.mode }
    }

    private struct FocusedRemovalActivationSuppression {
        let refreshCycleId: RefreshCycleId
        let workspaceId: WorkspaceDescriptor.ID
        let suppressedActivationPid: pid_t
        var expectedRecoveryToken: WindowToken?
        var didRequestRecoveryFocus: Bool
    }

    private struct SameAppFocusPreemption {
        let preemptedToken: WindowToken
        let activatedToken: WindowToken
        let workspaceId: WorkspaceDescriptor.ID
        let recordedUptimeSeconds: TimeInterval
    }

    private struct ManagedReplacementKey: Hashable {
        let pid: pid_t
        let workspaceId: WorkspaceDescriptor.ID
    }

    private enum ManagedReplacementCorrelationPolicy {
        case structural
    }

    private struct PendingManagedCreate {
        let sequence: UInt64
        let candidate: PreparedCreate
    }

    private struct PendingManagedDestroy {
        let sequence: UInt64
        let candidate: PreparedDestroy
    }

    private enum PendingManagedReplacementEvent {
        case create(PendingManagedCreate)
        case destroy(PendingManagedDestroy)

        var sequence: UInt64 {
            switch self {
            case let .create(create): create.sequence
            case let .destroy(destroy): destroy.sequence
            }
        }
    }

    private struct PendingManagedReplacementBurst {
        let policy: ManagedReplacementCorrelationPolicy
        let firstEventUptime: TimeInterval
        var creates: [PendingManagedCreate] = []
        var destroys: [PendingManagedDestroy] = []

        mutating func append(create: PendingManagedCreate) {
            guard !creates.contains(where: { $0.candidate.token == create.candidate.token }) else { return }
            creates.append(create)
        }

        mutating func append(destroy: PendingManagedDestroy) {
            guard !destroys.contains(where: { $0.candidate.token == destroy.candidate.token }) else { return }
            destroys.append(destroy)
        }

        var orderedEvents: [PendingManagedReplacementEvent] {
            let events = creates.map(PendingManagedReplacementEvent.create) + destroys.map(PendingManagedReplacementEvent.destroy)
            return events.sorted { $0.sequence < $1.sequence }
        }

        func orderedEvents(excludingSequences sequences: Set<UInt64>) -> [PendingManagedReplacementEvent] {
            orderedEvents.filter { !sequences.contains($0.sequence) }
        }
    }

    private struct MatchedManagedReplacementPair {
        let destroy: PendingManagedDestroy
        let create: PendingManagedCreate

        var excludedSequences: Set<UInt64> {
            [destroy.sequence, create.sequence]
        }
    }

    private static let managedReplacementGraceDelay: Duration = .milliseconds(150)
    private static let nativeFullscreenFollowupDelay: Duration = .seconds(1)
    private static let nativeFullscreenStaleCleanupDelay: Duration = .seconds(
        Int64(WorkspaceManager.staleUnavailableNativeFullscreenTimeout)
    )
    private static let stabilizationRetryDelay: Duration = .milliseconds(100)
    private static let createdWindowRetryLimit = 5

    /// Same-app focus can move to a sibling immediately before the window
    /// server reports the previously focused window as destroyed. Keep only
    /// a short, exact-token candidate so ordinary later background closes do
    /// not inherit focused-removal recovery policy.
    private static let sameAppFocusPreemptionMaxAgeSeconds: TimeInterval = 0.75

    /// After a CGS `windowDestroyed` notification, AX enumeration for the
    /// same `windowId` can briefly continue to return the destroyed ref.
    /// That happens most visibly during native-FS space transitions, where
    /// macOS thrashes a window's AX identity: destroy → enumeration still
    /// shows it → second destroy → fresh create. The full-rescan path is
    /// driven by AX enumeration, so it would re-admit the zombie entry
    /// between the two destroys. Suppressing re-admission makes the
    /// follow-up `windowCreated` notification the single source of truth
    /// for the replacement window.
    ///
    /// The TTL is the upper bound the guard can survive without a
    /// confirming `windowCreated` signal. `trackPreparedCreate` clears
    /// the mark as soon as a replacement admission is observed, so the
    /// TTL only matters when macOS never sends the matching create —
    /// e.g. the window was actually destroyed for good. Two seconds
    /// comfortably covers the observed space-transition thrash window
    /// without pinning stale ids forever.
    private static let recentlyDestroyedWindowTTL: Duration = .seconds(2)
    private var recentlyDestroyedWindowIds: [Int: ContinuousClock.Instant] = [:]

    weak var controller: WMController?
    private var deferredCreatedWindowIds: Set<UInt32> = []
    private var deferredCreatedWindowOrder: [UInt32] = []
    private var pendingManagedReplacementBursts: [ManagedReplacementKey: PendingManagedReplacementBurst] = [:]
    private var pendingManagedReplacementTasks: [ManagedReplacementKey: Task<Void, Never>] = [:]
    private var pendingNativeFullscreenFollowupTasks: [WindowToken: Task<Void, Never>] = [:]
    private var pendingNativeFullscreenStaleCleanupTasks: [WindowToken: Task<Void, Never>] = [:]
    private var pendingWindowRuleReevaluationTask: Task<Void, Never>?
    private var pendingWindowRuleReevaluationTargets: Set<WindowRuleReevaluationTarget> = []
    private var pendingWindowStabilizationTasks: [WindowToken: Task<Void, Never>] = [:]
    private var pendingCreatedWindowRetryTasks: [UInt32: Task<Void, Never>] = [:]
    private var createdWindowRetryCountById: [UInt32: Int] = [:]
    private var pendingActivationRetryTask: Task<Void, Never>?
    private var pendingActivationRetryRequestId: UInt64?
    private var focusedRemovalActivationSuppression: FocusedRemovalActivationSuppression?
    private var sameAppFocusPreemptionsByToken: [WindowToken: SameAppFocusPreemption] = [:]
    private var nextManagedReplacementEventSequence: UInt64 = 0
    var windowInfoProvider: ((UInt32) -> WindowServerInfo?)?
    var axWindowRefProvider: ((UInt32, pid_t) -> AXWindowRef?)?
    var bundleIdProvider: ((pid_t) -> String?)?
    var windowSubscriptionHandler: (([UInt32]) -> Void)?
    var windowUnsubscriptionHandler: (([UInt32]) -> Set<UInt32>)?
    var focusedWindowValueProvider: ((pid_t) -> CFTypeRef?)?
    var focusedWindowRefProvider: ((pid_t) -> AXWindowRef?)?
    var windowFactsProvider: ((AXWindowRef, pid_t) -> WindowRuleFacts?)?
    var frameProvider: ((AXWindowRef) -> CGRect?)?
    var fastFrameProvider: ((AXWindowRef) -> CGRect?)?
    var isFullscreenProvider: ((AXWindowRef) -> Bool)?
    var managedReplacementTimeSourceForTests: (() -> TimeInterval)?
    private(set) var debugCounters = DebugCounters()

    init(
        controller: WMController
    ) {
        self.controller = controller
    }

    func setup() {
        CGSEventObserver.shared.delegate = self
        CGSEventObserver.shared.start()
    }

    func cleanup() {
        resetManagedReplacementState()
        resetNativeFullscreenReplacementState()
        resetWindowStabilizationState()
        resetCreatedWindowRetryState()
        resetActivationRetryState()
        resetFocusedRemovalActivationSuppression()
        resetSameAppFocusPreemptions()
        pendingWindowRuleReevaluationTask?.cancel()
        pendingWindowRuleReevaluationTask = nil
        pendingWindowRuleReevaluationTargets.removeAll()
        CGSEventObserver.shared.delegate = nil
        CGSEventObserver.shared.stop()
    }

    func cgsEventObserver(_: CGSEventObserver, didReceive event: CGSWindowEvent) {
        guard let controller else { return }

        switch event {
        case let .created(windowId, _):
            handleCGSWindowCreated(windowId: windowId)

        case let .destroyed(windowId, _):
            _ = controller.borderCoordinator.reconcile(event: .cgsDestroyed(windowId: windowId))
            handleCGSWindowDestroyed(windowId: windowId)

        case let .closed(windowId):
            _ = controller.borderCoordinator.reconcile(event: .cgsClosed(windowId: windowId))
            handleCGSWindowDestroyed(windowId: windowId)

        case let .frameChanged(windowId):
            handleFrameChanged(windowId: windowId)

        case let .frontAppChanged(pid):
            handleAppActivation(pid: pid, source: .cgsFrontAppChanged)

        case let .titleChanged(windowId):
            AXWindowService.refreshCachedTitle(windowId: windowId)
            controller.requestWorkspaceBarRefresh()
            if let token = resolveTrackedToken(windowId) {
                updateManagedReplacementTitle(windowId: windowId, token: token)
                scheduleWindowRuleReevaluationIfNeeded(targets: [.window(token)])
            }
        }
    }

    private func scheduleWindowRuleReevaluationIfNeeded(
        targets: Set<WindowRuleReevaluationTarget>
    ) {
        guard let controller,
              controller.windowRuleEngine.needsWindowReevaluation,
              !targets.isEmpty
        else {
            return
        }

        pendingWindowRuleReevaluationTargets.formUnion(targets)
        pendingWindowRuleReevaluationTask?.cancel()
        pendingWindowRuleReevaluationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(25))
            guard let self, let controller = self.controller else { return }
            let targets = self.pendingWindowRuleReevaluationTargets
            self.pendingWindowRuleReevaluationTargets.removeAll()
            _ = await controller.reevaluateWindowRules(for: targets)
        }
    }

    private func isWindowDisplayable(token: WindowToken) -> Bool {
        guard let controller else { return false }
        guard let entry = controller.workspaceManager.entry(for: token) else {
            return false
        }
        return controller.isManagedWindowDisplayable(entry.handle)
    }

    private func handleCGSWindowCreated(windowId: UInt32) {
        processCreatedWindow(windowId: windowId)
    }

    private func processCreatedWindow(windowId: UInt32) {
        guard let controller else { return }
        if controller.isDiscoveryInProgress {
            deferCreatedWindow(windowId)
            return
        }

        let windowInfo = resolveWindowInfo(windowId)
        guard let candidate = prepareCreateCandidate(
            windowId: windowId,
            windowInfo: windowInfo
        ) else {
            if let windowInfo {
                _ = scheduleCreatedWindowRetryIfNeeded(
                    windowId: windowId,
                    pid: pid_t(windowInfo.pid)
                )
                scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(pid_t(windowInfo.pid))])
            }
            return
        }

        cancelCreatedWindowRetry(windowId: windowId)
        if shouldDelayManagedReplacementCreate(candidate) {
            enqueueManagedReplacementCreate(candidate)
            return
        }

        trackPreparedCreate(candidate)
    }

    func resetDebugStateForTests() {
        debugCounters = .init()
        resetManagedReplacementState()
        resetNativeFullscreenReplacementState()
        resetWindowStabilizationState()
        resetCreatedWindowRetryState()
        resetActivationRetryState()
        resetFocusedRemovalActivationSuppression()
        resetSameAppFocusPreemptions()
        controller?.focusBridge.reset()
        pendingWindowRuleReevaluationTask?.cancel()
        pendingWindowRuleReevaluationTask = nil
        pendingWindowRuleReevaluationTargets.removeAll()
    }

    func probeFocusedWindowAfterFronting(
        expectedToken: WindowToken,
        workspaceId _: WorkspaceDescriptor.ID
    ) {
        let requestId = controller?.focusBridge.activeManagedRequest(for: expectedToken)?.requestId
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let requestId,
               self.controller?.focusBridge.activeManagedRequest(requestId: requestId) == nil
            {
                return
            }
            self.handleAppActivation(
                pid: expectedToken.pid,
                source: .focusedWindowChanged,
                origin: .probe
            )
        }
    }

    private func managedReplacementCurrentUptime() -> TimeInterval {
        managedReplacementTimeSourceForTests?() ?? ProcessInfo.processInfo.systemUptime
    }

    private func handleFrameChanged(windowId: UInt32) {
        guard let controller else { return }
        _ = controller.borderCoordinator.reconcile(event: .cgsFrameChanged(windowId: windowId))
        guard let token = resolveTrackedToken(windowId) else { return }
        guard let entry = controller.workspaceManager.entry(for: token) else { return }

        guard isWindowDisplayable(token: token) else {
            return
        }

        let observedFrame = frameProvider?(entry.axRef)
            ?? fastFrameProvider?(entry.axRef)
            ?? AXWindowService.framePreferFast(entry.axRef)
            ?? (try? AXWindowService.frame(entry.axRef))
        let hasPendingFrameWrite = controller.axManager.hasPendingFrameWrite(for: entry.windowId)

        if let frame = observedFrame, !hasPendingFrameWrite {
            updateManagedReplacementFrame(frame, for: entry)
        }

        if entry.mode == .floating {
            if let frame = observedFrame {
                controller.workspaceManager.updateFloatingGeometry(frame: frame, for: token)
            }
            let shouldRetryWorkspaceHide = controller.layoutRefreshController.handleFreshFrameEvent(for: token)
            if hasPendingFrameWrite, let frame = observedFrame {
                controller.axManager.confirmFrameWrite(for: entry.windowId, pid: entry.pid, frame: frame)
            }
            if shouldRetryWorkspaceHide {
                debugCounters.geometryRelayoutRequests += 1
                controller.layoutRefreshController.requestRelayout(
                    reason: .axWindowChanged,
                    affectedWorkspaceIds: [entry.workspaceId]
                )
            }
            return
        }

        if controller.isInteractiveGestureActive {
            debugCounters.geometryRelayoutsSuppressedDuringGesture += 1
            return
        }

        let shouldRetryWorkspaceHide = controller.layoutRefreshController.handleFreshFrameEvent(for: token)
        if hasPendingFrameWrite {
            if let frame = observedFrame {
                controller.axManager.confirmFrameWrite(for: entry.windowId, pid: entry.pid, frame: frame)
            }
            if shouldRetryWorkspaceHide {
                debugCounters.geometryRelayoutRequests += 1
                controller.layoutRefreshController.requestRelayout(
                    reason: .axWindowChanged,
                    affectedWorkspaceIds: [entry.workspaceId]
                )
            }
            return
        }

        debugCounters.geometryRelayoutRequests += 1
        controller.layoutRefreshController.requestRelayout(
            reason: .axWindowChanged,
            affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    private func handleCGSWindowDestroyed(windowId: UInt32) {
        AXWindowService.invalidateCachedTitle(windowId: windowId)
        cancelCreatedWindowRetry(windowId: windowId)
        removeDeferredCreatedWindow(windowId)
        handleWindowDestroyed(windowId: windowId, pidHint: nil)
    }

    func subscribeToManagedWindows() {
        guard let controller else { return }
        let windowIds = controller.workspaceManager.allEntries().compactMap { entry -> UInt32? in
            UInt32(entry.windowId)
        }
        subscribeToWindows(windowIds)
    }

    func drainDeferredCreatedWindows() {
        guard !deferredCreatedWindowOrder.isEmpty else { return }

        let deferredWindowIds = deferredCreatedWindowOrder
        deferredCreatedWindowOrder.removeAll()
        deferredCreatedWindowIds.removeAll()

        for windowId in deferredWindowIds {
            guard let controller else { return }
            guard let token = resolveWindowToken(windowId) else {
                continue
            }
            if controller.workspaceManager.entry(for: token) != nil {
                continue
            }
            guard let candidate = prepareCreateCandidate(
                windowId: windowId,
                windowInfo: resolveWindowInfo(windowId)
            ) else {
                if let windowInfo = resolveWindowInfo(windowId) {
                    _ = scheduleCreatedWindowRetryIfNeeded(
                        windowId: windowId,
                        pid: pid_t(windowInfo.pid)
                    )
                }
                continue
            }
            cancelCreatedWindowRetry(windowId: windowId)
            if shouldDelayManagedReplacementCreate(candidate) {
                enqueueManagedReplacementCreate(candidate)
            } else {
                trackPreparedCreate(candidate)
            }
        }
    }

    private func trackPreparedCreate(_ candidate: PreparedCreate) {
        guard let controller else { return }
        cancelCreatedWindowRetry(windowId: candidate.windowId)

        // A genuine AX create notification is the authoritative "the
        // replacement window is here" signal; drop the recently-destroyed
        // guard immediately so subsequent rescans admit this window
        // normally instead of waiting out the remainder of the TTL.
        clearRecentlyDestroyedWindow(windowId: candidate.token.windowId)

        if restoreNativeFullscreenReplacementIfNeeded(
            token: candidate.token,
            windowId: candidate.windowId,
            axRef: candidate.axRef,
            workspaceId: candidate.workspaceId,
            appFullscreen: isFullscreenProvider?(candidate.axRef) ?? AXWindowService.isFullscreen(candidate.axRef)
        ) {
            controller.layoutRefreshController.requestRelayout(reason: .axWindowCreated)
            return
        }

        let trackedToken = controller.workspaceManager.addWindow(
            candidate.axRef,
            pid: candidate.token.pid,
            windowId: candidate.token.windowId,
            to: candidate.workspaceId,
            mode: candidate.mode,
            ruleEffects: candidate.ruleEffects,
            managedReplacementMetadata: candidate.replacementMetadata
        )
        guard let trackedEntry = controller.workspaceManager.entry(for: trackedToken) else {
            scheduleAXContextWarmup(for: candidate.token.pid)
            return
        }

        if trackedEntry.mode == .floating {
            controller.focusPolicyEngine.beginLease(
                owner: .ruleCreatedFloatingWindow,
                reason: "floating_window_create",
                suppressesFocusFollowsMouse: true,
                duration: 0.35
            )
        }

        var floatingTargetFrame: CGRect?
        if trackedEntry.mode == .floating {
            let observedFrame = frameProvider?(candidate.axRef)
                ?? fastFrameProvider?(candidate.axRef)
                ?? AXWindowService.framePreferFast(candidate.axRef)
                ?? (try? AXWindowService.frame(candidate.axRef))
            let preferredMonitor = controller.workspaceManager.monitor(for: trackedEntry.workspaceId)

            if let observedFrame {
                updateManagedReplacementFrame(observedFrame, for: trackedEntry)
                if controller.workspaceManager.floatingState(for: trackedToken) == nil {
                    controller.workspaceManager.updateFloatingGeometry(
                        frame: observedFrame,
                        for: trackedToken,
                        referenceMonitor: preferredMonitor
                    )
                }
            }

            floatingTargetFrame = controller.workspaceManager.resolvedFloatingFrame(
                for: trackedToken,
                preferredMonitor: preferredMonitor
            )
        }

        if let floatingTargetFrame,
           shouldApplyFloatingCreateFrameImmediately(for: trackedEntry.workspaceId)
        {
            scheduleFloatingCreateFrameApplication(
                floatingTargetFrame,
                token: trackedToken,
                pid: trackedEntry.pid,
                windowId: trackedEntry.windowId,
                workspaceId: trackedEntry.workspaceId
            )
        } else {
            scheduleAXContextWarmup(for: trackedEntry.pid)
        }

        controller.layoutRefreshController.requestRelayout(
            reason: .axWindowCreated,
            affectedWorkspaceIds: [trackedEntry.workspaceId]
        )
        scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(trackedEntry.pid)])
    }

    private func shouldApplyFloatingCreateFrameImmediately(
        for workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            return false
        }
        return controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == workspaceId
    }

    private func scheduleAXContextWarmup(for pid: pid_t) {
        Task { @MainActor [weak self] in
            await self?.warmAXContextIfNeeded(for: pid)
        }
    }

    private func warmAXContextIfNeeded(for pid: pid_t) async {
        guard let controller,
              let app = NSRunningApplication(processIdentifier: pid)
        else {
            return
        }
        _ = await controller.axManager.windowsForApp(app)
    }

    private func scheduleFloatingCreateFrameApplication(
        _ targetFrame: CGRect,
        token: WindowToken,
        pid: pid_t,
        windowId: Int,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller else { return }
        let canApplySynchronously = controller.axManager.hasContext(for: pid)
            || controller.axManager.usesFrameApplyOverrideForTests

        if canApplySynchronously {
            applyFloatingCreateFrame(
                targetFrame,
                token: token,
                pid: pid,
                windowId: windowId,
                workspaceId: workspaceId
            )
            if controller.axManager.recentFrameWriteFailure(for: windowId) == .contextUnavailable {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.warmAXContextIfNeeded(for: pid)
                    self.applyFloatingCreateFrame(
                        targetFrame,
                        token: token,
                        pid: pid,
                        windowId: windowId,
                        workspaceId: workspaceId
                    )
                }
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.warmAXContextIfNeeded(for: pid)
            self.applyFloatingCreateFrame(
                targetFrame,
                token: token,
                pid: pid,
                windowId: windowId,
                workspaceId: workspaceId
            )
            if self.controller?.axManager.recentFrameWriteFailure(for: windowId) == .contextUnavailable {
                await self.warmAXContextIfNeeded(for: pid)
                self.applyFloatingCreateFrame(
                    targetFrame,
                    token: token,
                    pid: pid,
                    windowId: windowId,
                    workspaceId: workspaceId
                )
            }
        }
    }

    private func applyFloatingCreateFrame(
        _ targetFrame: CGRect,
        token: WindowToken,
        pid: pid_t,
        windowId: Int,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller,
              controller.workspaceManager.entry(for: token) != nil,
              shouldApplyFloatingCreateFrameImmediately(for: workspaceId)
        else {
            return
        }

        controller.axManager.forceApplyNextFrame(for: windowId)
        controller.axManager.applyFramesParallel([(pid, windowId, targetFrame)])
    }

    func handleRemoved(pid: pid_t, winId: Int) {
        guard let windowId = UInt32(exactly: winId) else { return }
        AXWindowService.invalidateCachedTitle(windowId: windowId)
        cancelCreatedWindowRetry(windowId: windowId)
        removeDeferredCreatedWindow(windowId)
        handleWindowDestroyed(windowId: windowId, pidHint: pid)
    }

    func handleRemoved(token: WindowToken) {
        guard let controller else { return }
        let entry = controller.workspaceManager.entry(for: token)
        let affectedWorkspaceId = entry?.workspaceId
        let focusedTokenBeforeRemoval = controller.workspaceManager.focusedToken
        clearManagedFocusState(matching: token, workspaceId: affectedWorkspaceId)

        if handleNativeFullscreenDestroy(token) {
            return
        }

        let layoutType = affectedWorkspaceId
            .flatMap { controller.workspaceManager.descriptor(for: $0)?.name }
            .map { controller.settings.layoutType(for: $0) } ?? .defaultLayout

        var oldFrames: [WindowToken: CGRect] = [:]
        var removedNodeId: NodeId?
        var niriRevealSide: NiriRemovalRevealSide?
        var niriStrictRecoveryToken: WindowToken?
        var niriViewportStateBeforeRemoval: ViewportState?
        if let wsId = affectedWorkspaceId, layoutType != .dwindle, let engine = controller.niriEngine {
            niriViewportStateBeforeRemoval = controller.workspaceManager.niriViewportState(for: wsId)
            oldFrames = engine.captureWindowFrames(in: wsId)
            if let removedNode = engine.findNode(for: token) {
                removedNodeId = removedNode.id
                niriStrictRecoveryToken = strictLeftRecoveryToken(for: removedNode, workspaceId: wsId)
                let removedFrame = removedColumnFrame(
                    for: removedNode,
                    oldFrames: oldFrames
                ) ?? oldFrames[token]
                if let removedFrame,
                   let monitor = controller.workspaceManager.monitor(for: wsId)
                {
                    niriRevealSide = NiriRemovalRevealSide.closestHorizontalEdge(
                        to: removedFrame,
                        in: monitor.visibleFrame
                    )
                }
            }
        }
        let isSelectedNiriRemoval = affectedWorkspaceId.map { wsId in
            layoutType != .dwindle
                && removedNodeId != nil
                && controller.workspaceManager.niriViewportState(for: wsId).selectedNodeId == removedNodeId
        } ?? false
        let sameAppFocusedPreemption = consumeSameAppFocusPreemption(
            for: token,
            workspaceId: affectedWorkspaceId
        )
        let shouldRecoverFocus = token == focusedTokenBeforeRemoval
            || isSelectedNiriRemoval
            || sameAppFocusedPreemption != nil
        let niriAnimationPolicy: NiriRemovalAnimationPolicy = if shouldRecoverFocus,
                                                                 layoutType != .dwindle,
                                                                 removedNodeId != nil
        {
            .staticViewportPreserving
        } else {
            .ordinary
        }
        var didStartCloseAnimation = false
        if niriAnimationPolicy.shouldStartCloseAnimation,
           let entry,
           let wsId = affectedWorkspaceId,
           let monitor = controller.workspaceManager.monitor(for: wsId),
           controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == wsId,
           layoutType != .dwindle
        {
            let shouldAnimate = if let engine = controller.niriEngine,
                                   let windowNode = engine.findNode(for: token)
            {
                !windowNode.isHiddenInTabbedMode
            } else {
                true
            }
            if shouldAnimate {
                controller.layoutRefreshController.startWindowCloseAnimation(
                    entry: entry,
                    monitor: monitor
                )
                didStartCloseAnimation = true
            }
        }
        if let wsId = affectedWorkspaceId,
           layoutType != .dwindle,
           removedNodeId != nil
        {
            controller.layoutRefreshController.emitNiriRemovalAnimationDiagnostic(
                NiriRemovalAnimationDiagnostic(
                    phase: .intake,
                    workspaceId: wsId,
                    removedNodeId: removedNodeId,
                    removedWindow: token,
                    recoveryTarget: niriStrictRecoveryToken,
                    revealSide: niriRevealSide,
                    activeColumnBefore: niriViewportStateBeforeRemoval?.activeColumnIndex,
                    activeColumnAfter: nil,
                    currentOffset: niriViewportStateBeforeRemoval?.viewOffsetPixels.current(),
                    targetOffset: niriViewportStateBeforeRemoval?.viewOffsetPixels.target(),
                    stationaryOffset: niriViewportStateBeforeRemoval?.stationary(),
                    viewportAction: .none,
                    animationPolicy: niriAnimationPolicy,
                    closeAnimation: didStartCloseAnimation,
                    survivorMoveAnimation: false,
                    columnAnimation: false,
                    viewportAnimation: niriViewportStateBeforeRemoval?.viewOffsetPixels.isAnimating ?? false,
                    startNiriScroll: false,
                    skipFrameApplicationForAnimation: false
                )
            )
        }
        let isAffectedWorkspaceActive = affectedWorkspaceId.map { wsId in
            controller.workspaceManager.monitor(for: wsId).map { monitor in
                controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == wsId
            } ?? false
        } ?? false
        controller.layoutRefreshController.discardHiddenTracking(for: token)
        _ = controller.workspaceManager.removeWindow(
            pid: token.pid,
            windowId: token.windowId
        )
        markWindowRecentlyDestroyed(windowId: token.windowId)
        controller.clearManualWindowOverride(for: token)
        _ = controller.renderKeyboardFocusBorder(
            policy: .direct,
            source: .cgsDestroyed
        )

        if let wsId = affectedWorkspaceId {
            let refreshCycleId = controller.layoutRefreshController.requestWindowRemoval(
                workspaceId: wsId,
                layoutType: layoutType,
                removedNodeId: removedNodeId,
                removedWindow: token,
                niriOldFrames: oldFrames,
                niriRevealSide: niriRevealSide,
                shouldRecoverFocus: shouldRecoverFocus,
                niriAnimationPolicy: niriAnimationPolicy
            )
            if shouldRecoverFocus,
               layoutType != .dwindle,
               isAffectedWorkspaceActive,
               let refreshCycleId
            {
                prepareFocusedRemovalActivationSuppression(
                    refreshCycleId: refreshCycleId,
                    workspaceId: wsId,
                    suppressedActivationPid: token.pid,
                    expectedRecoveryToken: niriStrictRecoveryToken
                )
            }
        }
        scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(token.pid)])
    }

    private func removedColumnFrame(
        for node: NiriWindow,
        oldFrames: [WindowToken: CGRect]
    ) -> CGRect? {
        guard let controller,
              let engine = controller.niriEngine,
              let column = engine.column(of: node)
        else {
            return oldFrames[node.token]
        }

        return column.windowNodes
            .compactMap { oldFrames[$0.token] }
            .reduce(nil) { partial, frame in
                partial.map { $0.union(frame) } ?? frame
            }
    }

    private func prepareFocusedRemovalActivationSuppression(
        refreshCycleId: RefreshCycleId,
        workspaceId: WorkspaceDescriptor.ID,
        suppressedActivationPid: pid_t,
        expectedRecoveryToken: WindowToken?
    ) {
        focusedRemovalActivationSuppression = FocusedRemovalActivationSuppression(
            refreshCycleId: refreshCycleId,
            workspaceId: workspaceId,
            suppressedActivationPid: suppressedActivationPid,
            expectedRecoveryToken: expectedRecoveryToken,
            didRequestRecoveryFocus: false
        )
    }

    private func resetFocusedRemovalActivationSuppression() {
        focusedRemovalActivationSuppression = nil
    }

    private func resetSameAppFocusPreemptions() {
        sameAppFocusPreemptionsByToken.removeAll()
    }

    private func resetSameAppFocusState(for pid: pid_t) {
        sameAppFocusPreemptionsByToken = sameAppFocusPreemptionsByToken.filter { entry in
            entry.key.pid != pid
                && entry.value.preemptedToken.pid != pid
                && entry.value.activatedToken.pid != pid
        }
    }

    private func pruneExpiredSameAppFocusPreemptions(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        sameAppFocusPreemptionsByToken = sameAppFocusPreemptionsByToken.filter { entry in
            now - entry.value.recordedUptimeSeconds <= Self.sameAppFocusPreemptionMaxAgeSeconds
        }
    }

    private func consumeSameAppFocusPreemption(
        for token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID?
    ) -> SameAppFocusPreemption? {
        let now = ProcessInfo.processInfo.systemUptime
        pruneExpiredSameAppFocusPreemptions(now: now)
        guard let preemption = sameAppFocusPreemptionsByToken.removeValue(forKey: token),
              preemption.preemptedToken == token,
              preemption.workspaceId == workspaceId,
              isSameAppFocusPreemptionStillCurrent(preemption),
              now - preemption.recordedUptimeSeconds <= Self.sameAppFocusPreemptionMaxAgeSeconds
        else {
            return nil
        }
        return preemption
    }

    private func isSameAppFocusPreemptionStillCurrent(_ preemption: SameAppFocusPreemption) -> Bool {
        guard let controller,
              !controller.workspaceManager.isNonManagedFocusActive,
              controller.workspaceManager.focusedToken == preemption.activatedToken,
              let activatedEntry = controller.workspaceManager.entry(for: preemption.activatedToken),
              activatedEntry.workspaceId == preemption.workspaceId,
              let workspaceName = controller.workspaceManager.descriptor(for: preemption.workspaceId)?.name,
              controller.settings.layoutType(for: workspaceName) != .dwindle
        else {
            return false
        }
        return true
    }

    private func recordSameAppFocusPreemptionIfNeeded(
        previousFocusedToken: WindowToken?,
        activatedToken: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        source: ActivationEventSource
    ) {
        sameAppFocusPreemptionsByToken.removeValue(forKey: activatedToken)
        pruneExpiredSameAppFocusPreemptions()

        guard source == .focusedWindowChanged else {
            resetSameAppFocusPreemptions()
            return
        }
        guard let previousFocusedToken else {
            resetSameAppFocusPreemptions()
            return
        }
        if previousFocusedToken == activatedToken {
            return
        }

        guard previousFocusedToken.pid == activatedToken.pid,
              let controller,
              let previousEntry = controller.workspaceManager.entry(for: previousFocusedToken),
              previousEntry.workspaceId == workspaceId,
              let workspaceName = controller.workspaceManager.descriptor(for: workspaceId)?.name,
              controller.settings.layoutType(for: workspaceName) != .dwindle
        else {
            resetSameAppFocusPreemptions()
            return
        }

        sameAppFocusPreemptionsByToken = sameAppFocusPreemptionsByToken.filter { entry in
            entry.key.pid == activatedToken.pid && entry.value.workspaceId == workspaceId
        }

        sameAppFocusPreemptionsByToken[previousFocusedToken] = SameAppFocusPreemption(
            preemptedToken: previousFocusedToken,
            activatedToken: activatedToken,
            workspaceId: workspaceId,
            recordedUptimeSeconds: ProcessInfo.processInfo.systemUptime
        )
    }

    func cancelFocusedRemovalActivationSuppression(refreshCycleId: RefreshCycleId) {
        guard focusedRemovalActivationSuppression?.refreshCycleId == refreshCycleId else { return }
        resetFocusedRemovalActivationSuppression()
    }

    func reconcileFocusedRemovalActivationSuppression(
        activeCycleId: RefreshCycleId?,
        pendingCycleId: RefreshCycleId?
    ) {
        guard let suppression = focusedRemovalActivationSuppression else { return }
        if suppression.refreshCycleId == activeCycleId || suppression.refreshCycleId == pendingCycleId {
            return
        }
        if suppression.didRequestRecoveryFocus {
            guard let expectedRecoveryToken = suppression.expectedRecoveryToken,
                  let controller,
                  controller.workspaceManager.entry(for: expectedRecoveryToken) != nil,
                  controller.focusBridge.activeManagedRequest(for: expectedRecoveryToken) != nil
            else {
                resetFocusedRemovalActivationSuppression()
                return
            }
            return
        }
        resetFocusedRemovalActivationSuppression()
    }

    private func strictLeftRecoveryToken(
        for node: NiriWindow,
        workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        guard let controller,
              let engine = controller.niriEngine,
              let column = engine.column(of: node),
              let columnIndex = engine.columnIndex(of: column, in: workspaceId),
              columnIndex > 0
        else {
            return nil
        }

        let leftColumn = engine.columns(in: workspaceId)[columnIndex - 1]
        return leftColumn.activeWindow?.token ?? leftColumn.windowNodes.first?.token
    }

    func noteFocusedRemovalRecoveryFocusRequested(_ token: WindowToken) {
        guard var suppression = focusedRemovalActivationSuppression else { return }
        if let expectedRecoveryToken = suppression.expectedRecoveryToken,
           expectedRecoveryToken != token
        {
            return
        }
        suppression.expectedRecoveryToken = token
        suppression.didRequestRecoveryFocus = true
        focusedRemovalActivationSuppression = suppression
    }

    func completeFocusedRemovalRecovery(
        workspaceId: WorkspaceDescriptor.ID,
        target: WindowToken?
    ) {
        guard let suppression = focusedRemovalActivationSuppression,
              suppression.workspaceId == workspaceId
        else { return }

        if let target,
           let expectedRecoveryToken = suppression.expectedRecoveryToken,
           target != expectedRecoveryToken
        {
            return
        }
        resetFocusedRemovalActivationSuppression()
    }

    @discardableResult
    private func completeFocusedRemovalRecoveryIfExpected(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let suppression = focusedRemovalActivationSuppression,
              suppression.workspaceId == workspaceId,
              suppression.expectedRecoveryToken == token
        else { return false }

        resetFocusedRemovalActivationSuppression()
        return true
    }

    private func shouldIgnoreActivationDuringFocusedRemovalSuppression(
        token: WindowToken
    ) -> Bool {
        guard let suppression = focusedRemovalActivationSuppression,
              token.pid == suppression.suppressedActivationPid
        else {
            return false
        }

        if suppression.expectedRecoveryToken == token {
            return false
        }
        return true
    }

    private func shouldIgnoreActivationDuringFocusedRemovalSuppression(
        pid: pid_t
    ) -> Bool {
        focusedRemovalActivationSuppression?.suppressedActivationPid == pid
    }

    func handleAppActivation(
        pid: pid_t,
        source: ActivationEventSource = .workspaceDidActivateApplication,
        origin: ActivationCallOrigin = .external
    ) {
        guard let controller else { return }
        guard controller.focusPolicyEngine.evaluate(
            .managedAppActivation(source: source)
        ).allowsFocusChange else {
            return
        }
        guard controller.hasStartedServices else { return }

        if source != .focusedWindowChanged {
            controller.focusPolicyEngine.beginLease(
                owner: .nativeAppSwitch,
                reason: source.rawValue,
                suppressesFocusFollowsMouse: true,
                duration: 0.4
            )
        }

        if pid == getpid(), controller.hasFrontmostOwnedWindow || controller.hasVisibleOwnedWindow {
            applyActivationObservation(
                source: source,
                origin: origin,
                match: .ownedApplication(pid: pid),
                observedAXRef: nil,
                managedEntry: nil
            )
            return
        }

        let axRef = resolveFocusedAXWindowRef(pid: pid)

        guard let axRef else {
            if shouldIgnoreActivationDuringFocusedRemovalSuppression(pid: pid) {
                return
            }
            applyActivationObservation(
                source: source,
                origin: origin,
                match: .missingFocusedWindow(
                    pid: pid,
                    fallbackFullscreen: appFullscreenForFallbackLifecyclePreservation(
                        observedAppFullscreen: false
                    )
                ),
                observedAXRef: nil,
                managedEntry: nil
            )
            return
        }
        let token = WindowToken(pid: pid, windowId: axRef.windowId)

        let appFullscreen = isFullscreenProvider?(axRef) ?? AXWindowService.isFullscreen(axRef)

        if shouldIgnoreActivationDuringFocusedRemovalSuppression(token: token) {
            return
        }

        if let entry = controller.workspaceManager.entry(for: token) {
            if appFullscreen {
                suspendManagedWindowForNativeFullscreen(entry)
                return
            }
            _ = restoreManagedWindowFromNativeFullscreen(entry)
            let wsId = entry.workspaceId

            let targetMonitor = controller.workspaceManager.monitor(for: wsId)
            let isWorkspaceActive = targetMonitor.map { monitor in
                controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == wsId
            } ?? false
            applyActivationObservation(
                source: source,
                origin: origin,
                match: .managed(
                    token: entry.token,
                    workspaceId: wsId,
                    monitorId: targetMonitor?.id,
                    isWorkspaceActive: isWorkspaceActive,
                    appFullscreen: appFullscreen,
                    requiresNativeFullscreenRestoreRelayout: controller.workspaceManager
                        .nativeFullscreenRestoreContext(for: entry.token) != nil
                ),
                observedAXRef: axRef,
                managedEntry: entry
            )
            return
        }

        if restoreNativeFullscreenReplacementIfNeeded(
            token: token,
            windowId: UInt32(axRef.windowId),
            axRef: axRef,
            workspaceId: controller.activeWorkspace()?.id,
            appFullscreen: appFullscreen
        ),
            let restoredEntry = controller.workspaceManager.entry(for: token)
        {
            let wsId = restoredEntry.workspaceId
            let targetMonitor = controller.workspaceManager.monitor(for: wsId)
            let isWorkspaceActive = targetMonitor.map { monitor in
                controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == wsId
            } ?? false
            applyActivationObservation(
                source: source,
                origin: origin,
                match: .managed(
                    token: restoredEntry.token,
                    workspaceId: wsId,
                    monitorId: targetMonitor?.id,
                    isWorkspaceActive: isWorkspaceActive,
                    appFullscreen: appFullscreen,
                    requiresNativeFullscreenRestoreRelayout: controller.workspaceManager
                        .nativeFullscreenRestoreContext(for: restoredEntry.token) != nil
                ),
                observedAXRef: axRef,
                managedEntry: restoredEntry
            )
            return
        }

        // Some apps (e.g. WeChat) close windows via NSWindow.orderOut and reopen via
        // orderFront, which produces no kCGSpaceWindowCreated event. Activation is then
        // the only signal that a manageable window exists, so attempt admission here
        // before falling back to the unmanaged path.
        processCreatedWindow(windowId: UInt32(axRef.windowId))
        if let admittedEntry = controller.workspaceManager.entry(for: token) {
            if appFullscreen {
                suspendManagedWindowForNativeFullscreen(admittedEntry)
                return
            }
            _ = restoreManagedWindowFromNativeFullscreen(admittedEntry)
            let wsId = admittedEntry.workspaceId
            let targetMonitor = controller.workspaceManager.monitor(for: wsId)
            let isWorkspaceActive = targetMonitor.map { monitor in
                controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == wsId
            } ?? false
            applyActivationObservation(
                source: source,
                origin: origin,
                match: .managed(
                    token: admittedEntry.token,
                    workspaceId: wsId,
                    monitorId: targetMonitor?.id,
                    isWorkspaceActive: isWorkspaceActive,
                    appFullscreen: appFullscreen,
                    requiresNativeFullscreenRestoreRelayout: controller.workspaceManager
                        .nativeFullscreenRestoreContext(for: admittedEntry.token) != nil
                ),
                observedAXRef: axRef,
                managedEntry: admittedEntry
            )
            return
        }

        applyActivationObservation(
            source: source,
            origin: origin,
            match: .unmanaged(
                pid: pid,
                token: token,
                appFullscreen: appFullscreen,
                fallbackFullscreen: appFullscreenForFallbackLifecyclePreservation(
                    observedAppFullscreen: appFullscreen
                )
            ),
            observedAXRef: axRef,
            managedEntry: nil
        )
    }

    private func activationOrchestrationResult(
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        match: ManagedActivationMatch
    ) -> OrchestrationResult? {
        guard let controller else { return nil }
        return OrchestrationCore.step(
            snapshot: controller.orchestrationSnapshot(
                refresh: .init(
                    activeRefresh: controller.layoutRefreshController.layoutState.activeRefresh,
                    pendingRefresh: controller.layoutRefreshController.layoutState.pendingRefresh
                )
            ),
            event: .activationObserved(
                .init(
                    source: source,
                    origin: origin,
                    match: match
                )
            )
        )
    }

    private func applyActivationObservation(
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        match: ManagedActivationMatch,
        observedAXRef: AXWindowRef?,
        managedEntry: WindowModel.Entry?,
        confirmRequest: Bool = true
    ) {
        guard let controller else { return }
        if let runtime = controller.runtime {
            _ = runtime.observeActivation(
                .init(
                    source: source,
                    origin: origin,
                    match: match
                ),
                observedAXRef: observedAXRef,
                managedEntry: managedEntry,
                confirmRequest: confirmRequest
            )
            return
        }

        guard let result = activationOrchestrationResult(
            source: source,
            origin: origin,
            match: match
        ) else {
            return
        }
        applyActivationOrchestrationResult(
            result,
            observedAXRef: observedAXRef,
            managedEntry: managedEntry,
            source: source,
            confirmRequest: confirmRequest
        )
    }

    func handleManagedAppActivation(
        entry: WindowModel.Entry,
        isWorkspaceActive: Bool,
        appFullscreen: Bool,
        source: ActivationEventSource = .focusedWindowChanged,
        confirmRequest: Bool? = nil
    ) {
        guard let controller else { return }
        if appFullscreen {
            suspendManagedWindowForNativeFullscreen(entry)
            return
        }

        _ = restoreManagedWindowFromNativeFullscreen(entry)
        if shouldIgnoreActivationDuringFocusedRemovalSuppression(
            token: entry.token
        ) {
            return
        }
        let requiresNativeFullscreenRestoreRelayout =
            controller.workspaceManager.nativeFullscreenRestoreContext(for: entry.token) != nil
        applyActivationObservation(
            source: source,
            origin: .external,
            match: .managed(
                token: entry.token,
                workspaceId: entry.workspaceId,
                monitorId: controller.workspaceManager.monitorId(for: entry.workspaceId),
                isWorkspaceActive: isWorkspaceActive,
                appFullscreen: appFullscreen,
                requiresNativeFullscreenRestoreRelayout: requiresNativeFullscreenRestoreRelayout
            ),
            observedAXRef: entry.axRef,
            managedEntry: entry,
            confirmRequest: confirmRequest ?? true
        )
    }

    private func confirmManagedActivation(
        entry: WindowModel.Entry,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        isWorkspaceActive: Bool,
        appFullscreen: Bool,
        source: ActivationEventSource,
        confirmRequest: Bool
    ) {
        guard let controller else { return }
        assert(entry.workspaceId == workspaceId, "Activation workspace drift for \(entry.token)")
        let wsId = workspaceId
        let shouldActivateWorkspace = !isWorkspaceActive && !controller.isTransferringWindow
        let preActivationHiddenState = controller.workspaceManager.hiddenState(for: entry.token)
        let previousFocusedToken = controller.workspaceManager.focusedToken

        if confirmRequest {
            _ = controller.workspaceManager.confirmManagedFocus(
                entry.token,
                in: wsId,
                onMonitor: monitorId,
                appFullscreen: appFullscreen,
                activateWorkspaceOnMonitor: shouldActivateWorkspace
            )
            cancelActivationRetry()
        } else {
            _ = controller.workspaceManager.setManagedFocus(
                entry.token,
                in: wsId,
                onMonitor: monitorId
            )
        }
        recordSameAppFocusPreemptionIfNeeded(
            previousFocusedToken: previousFocusedToken,
            activatedToken: entry.token,
            workspaceId: wsId,
            source: source
        )
        let isCompletingFocusedRemovalRecovery = completeFocusedRemovalRecoveryIfExpected(
            token: entry.token,
            workspaceId: wsId
        )

        let target = controller.keyboardFocusTarget(for: entry.token, axRef: entry.axRef)
        controller.focusBridge.setFocusedTarget(target)

        let shouldForceWorkspaceInactiveRevealFrame = preActivationHiddenState?.workspaceInactive == true
        func activationRevealFrame(
            preferredFrame: CGRect?,
            hiddenState: WindowModel.HiddenState?,
            monitor: Monitor
        ) -> CGRect? {
            guard shouldForceWorkspaceInactiveRevealFrame else { return preferredFrame }
            guard let preferredFrame else {
                return hiddenState.flatMap {
                    controller.layoutRefreshController.restoredFrameForHiddenEntry(
                        entry,
                        monitor: monitor,
                        hiddenState: $0
                    )
                }
            }
            let midpoint = CGPoint(x: preferredFrame.midX, y: preferredFrame.midY)
            guard !monitor.visibleFrame.contains(midpoint) else { return preferredFrame }
            return hiddenState.flatMap {
                controller.layoutRefreshController.restoredFrameForHiddenEntry(
                    entry,
                    monitor: monitor,
                    hiddenState: $0
                )
            } ?? preferredFrame
        }
        if let hiddenState = preActivationHiddenState,
           hiddenState.workspaceInactive,
           let monitor = controller.workspaceManager.monitor(for: wsId)
        {
            if controller.workspaceManager.hiddenState(for: entry.token) == nil {
                controller.workspaceManager.setHiddenState(hiddenState, for: entry.token)
            }
            controller.axManager.markWindowActive(entry.windowId)
            controller.layoutRefreshController.unhideWindow(entry, monitor: monitor)
        }

        if let engine = controller.niriEngine,
           let node = engine.findNode(for: entry.handle),
           let monitor = controller.workspaceManager.monitor(for: wsId)
        {
            var state = controller.workspaceManager.niriViewportState(for: wsId)
            controller.niriLayoutHandler.activateNode(
                node, in: wsId, state: &state,
                options: isCompletingFocusedRemovalRecovery
                    ? .init(
                        ensureVisible: false,
                        layoutRefresh: false,
                        axFocus: false,
                        startAnimation: false
                    )
                    : .init(layoutRefresh: isWorkspaceActive, axFocus: false)
            )
            _ = controller.workspaceManager.applySessionPatch(
                .init(
                    workspaceId: wsId,
                    viewportState: state,
                    rememberedFocusToken: nil
                )
            )

            let preferredFrame = activationRevealFrame(
                preferredFrame: node.renderedFrame ?? node.frame,
                hiddenState: preActivationHiddenState,
                monitor: monitor
            )
            let cachedFrame = controller.axManager.lastAppliedFrame(for: entry.windowId)
            let needsActivationRevealFrame = shouldForceWorkspaceInactiveRevealFrame
                || (shouldActivateWorkspace && cachedFrame.map {
                    !monitor.visibleFrame.contains(CGPoint(x: $0.midX, y: $0.midY))
                } ?? false)
            if needsActivationRevealFrame,
               let preferredFrame
            {
                controller.axManager.forceApplyNextFrame(for: entry.windowId)
                controller.axManager.applyFramesParallel([(entry.pid, entry.windowId, preferredFrame)])
            }

            _ = controller.renderKeyboardFocusBorder(
                for: target,
                preferredFrame: preferredFrame,
                policy: .direct,
                source: borderReconcileSource(for: source)
            )
        } else {
            let monitor = controller.workspaceManager.monitor(for: wsId)
            let cachedFrame = controller.axManager.lastAppliedFrame(for: entry.windowId)
            let needsActivationRevealFrame = shouldForceWorkspaceInactiveRevealFrame
                || (shouldActivateWorkspace && cachedFrame.map { frame in
                    monitor.map { !($0.visibleFrame.contains(CGPoint(x: frame.midX, y: frame.midY))) } ?? false
                } ?? false)
            if needsActivationRevealFrame,
               let monitor,
               let preferredFrame = activationRevealFrame(
                   preferredFrame: controller.preferredKeyboardFocusFrame(for: entry.token),
                   hiddenState: preActivationHiddenState,
                   monitor: monitor
               )
            {
                controller.axManager.forceApplyNextFrame(for: entry.windowId)
                controller.axManager.applyFramesParallel([(entry.pid, entry.windowId, preferredFrame)])
            }
            _ = controller.renderKeyboardFocusBorder(
                for: target,
                policy: .direct,
                source: borderReconcileSource(for: source)
            )
        }

        controller.niriLayoutHandler.updateTabbedColumnOverlays()
        if shouldActivateWorkspace, confirmRequest {
            controller.syncMonitorsToNiriEngine()
            controller.layoutRefreshController.commitWorkspaceTransition(
                affectedWorkspaces: [wsId],
                reason: .appActivationTransition
            )
        }
        if confirmRequest,
           controller.moveMouseToFocusedWindowEnabled,
           controller.workspaceManager.focusedToken == entry.token,
           !controller.workspaceManager.isNonManagedFocusActive
        {
            controller.moveMouseToWindow(entry.token)
        }
    }

    private func beginNativeFullscreenRestoreActivation(
        entry: WindowModel.Entry,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        isWorkspaceActive: Bool
    ) {
        guard let controller else { return }

        assert(entry.workspaceId == workspaceId, "Activation workspace drift for \(entry.token)")
        let wsId = workspaceId
        let shouldActivateWorkspace = !isWorkspaceActive && !controller.isTransferringWindow
        if shouldActivateWorkspace, let monitorId {
            _ = controller.workspaceManager.setActiveWorkspace(wsId, on: monitorId)
        }
        _ = controller.workspaceManager.beginManagedFocusRequest(
            entry.token,
            in: wsId,
            onMonitor: monitorId
        )
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .appActivationTransition,
            affectedWorkspaceIds: [wsId]
        )
    }

    func focusedWindowToken(for pid: pid_t) -> WindowToken? {
        guard let axRef = resolveFocusedAXWindowRef(pid: pid) else { return nil }
        return WindowToken(pid: pid, windowId: axRef.windowId)
    }

    @discardableResult
    private func suspendManagedWindowForNativeFullscreen(_ entry: WindowModel.Entry) -> Bool {
        guard let controller else { return false }
        cancelNativeFullscreenLifecycleTasks(containing: entry.token)
        let changed = controller.suspendManagedWindowForNativeFullscreen(
            entry.token,
            path: .directActivationEnter
        )
        controller.hideKeyboardFocusBorder(
            source: .nativeFullscreenEnter,
            reason: "managed window entered native fullscreen",
            matchingToken: entry.token
        )
        return changed
    }

    @discardableResult
    private func restoreManagedWindowFromNativeFullscreen(_ entry: WindowModel.Entry) -> Bool {
        guard let controller else { return false }
        let hadRecord = controller.workspaceManager.nativeFullscreenRecord(for: entry.token) != nil
        guard hadRecord || controller.workspaceManager.layoutReason(for: entry.token) == .nativeFullscreen else {
            return false
        }
        cancelNativeFullscreenLifecycleTasks(containing: entry.token)
        if hadRecord {
            _ = controller.ensureNativeFullscreenRestoreSnapshot(
                for: entry.token,
                path: .fullRescanNativeFullscreenRestore
            )
            return controller.workspaceManager.beginNativeFullscreenRestore(for: entry.token) != nil
        }
        return controller.workspaceManager.restoreNativeFullscreenRecord(for: entry.token) != nil
    }

    @discardableResult
    func restoreNativeFullscreenReplacementIfNeeded(
        token: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef,
        workspaceId: WorkspaceDescriptor.ID?,
        appFullscreen: Bool
    ) -> Bool {
        guard let controller else { return false }
        let replacementMetadata = nativeFullscreenReplacementMetadata(
            token: token,
            windowId: windowId,
            axRef: axRef,
            workspaceId: workspaceId
        )
        let match = controller.workspaceManager.nativeFullscreenUnavailableCandidate(
            for: token,
            activeWorkspaceId: workspaceId,
            replacementMetadata: replacementMetadata
        )
        let record: WorkspaceManager.NativeFullscreenRecord
        switch match {
        case let .matched(matchedRecord):
            record = matchedRecord
        case .ambiguous, .none:
            return false
        }
        let normalizedReplacementMetadata = normalizedNativeFullscreenReplacementMetadata(
            replacementMetadata,
            for: record
        )
        if record.currentToken == token {
            guard controller.workspaceManager.entry(for: token) != nil else {
                return false
            }
            if let normalizedReplacementMetadata {
                _ = controller.workspaceManager.setManagedReplacementMetadata(
                    normalizedReplacementMetadata,
                    for: token
                )
            }
            cancelNativeFullscreenLifecycleTasks(for: record.originalToken)
            if appFullscreen {
                _ = controller.suspendManagedWindowForNativeFullscreen(
                    token,
                    path: .delayedSameTokenFullscreenReappearance
                )
            } else {
                _ = controller.ensureNativeFullscreenRestoreSnapshot(
                    for: token,
                    path: .fullRescanNativeFullscreenRestore
                )
                _ = controller.workspaceManager.beginNativeFullscreenRestore(for: token)
            }
            return true
        }
        guard rekeyManagedWindowIdentity(
            from: record.currentToken,
            to: token,
            windowId: windowId,
            axRef: axRef,
            managedReplacementMetadata: normalizedReplacementMetadata
        ) != nil else {
            return false
        }

        cancelNativeFullscreenLifecycleTasks(for: record.originalToken)

        if appFullscreen {
            _ = controller.suspendManagedWindowForNativeFullscreen(
                token,
                path: .delayedReplacementTokenFullscreenReappearance
            )
        } else {
            _ = controller.ensureNativeFullscreenRestoreSnapshot(
                for: token,
                path: .fullRescanNativeFullscreenRestore
            )
            _ = controller.workspaceManager.beginNativeFullscreenRestore(for: token)
        }

        return true
    }

    private func normalizedNativeFullscreenReplacementMetadata(
        _ metadata: ManagedReplacementMetadata?,
        for record: WorkspaceManager.NativeFullscreenRecord
    ) -> ManagedReplacementMetadata? {
        guard let controller else { return metadata }
        guard var normalized = metadata
            ?? record.restoreSnapshot?.replacementMetadata
            ?? controller.workspaceManager.managedReplacementMetadata(for: record.currentToken)
            ?? controller.workspaceManager.managedRestoreSnapshot(for: record.currentToken)?.replacementMetadata
            ?? controller.workspaceManager.managedRestoreSnapshot(for: record.originalToken)?.replacementMetadata
        else {
            return nil
        }

        normalized.workspaceId = record.workspaceId
        if let capturedMode = controller.workspaceManager.windowMode(for: record.currentToken) {
            normalized.mode = capturedMode
        } else if let restoreMode = record.restoreSnapshot?.replacementMetadata?.mode {
            normalized.mode = restoreMode
        }
        return normalized
    }

    private func nativeFullscreenReplacementMetadata(
        token: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef,
        workspaceId: WorkspaceDescriptor.ID?
    ) -> ManagedReplacementMetadata? {
        guard let controller, let workspaceId else { return nil }
        let windowInfo = resolveWindowInfo(windowId)
        let bundleId = resolveBundleId(token.pid)
            ?? NSRunningApplication(processIdentifier: token.pid)?.bundleIdentifier
        let facts = managedReplacementFacts(
            for: axRef,
            pid: token.pid,
            bundleId: bundleId,
            windowInfo: windowInfo,
            includeTitle: true
        )
        return makeManagedReplacementMetadata(
            bundleId: bundleId ?? facts.ax.bundleId,
            workspaceId: workspaceId,
            mode: controller.trackedModeForLifecycle(
                decision: controller.evaluateWindowDisposition(
                    axRef: axRef,
                    pid: token.pid,
                    appFullscreen: isFullscreenProvider?(axRef) ?? AXWindowService.isFullscreen(axRef),
                    windowInfo: windowInfo
                ).decision,
                existingEntry: nil
            ) ?? .tiling,
            facts: facts
        )
    }

    @discardableResult
    func rekeyManagedWindowIdentity(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> WindowModel.Entry? {
        guard let controller,
              let entry = controller.workspaceManager.rekeyWindow(
                  from: oldToken,
                  to: newToken,
                  newAXRef: axRef,
                  managedReplacementMetadata: managedReplacementMetadata
              )
        else {
            return nil
        }

        _ = controller.niriEngine?.rekeyWindow(from: oldToken, to: newToken)
        if let workspaceId = controller.workspaceManager.workspace(for: newToken) {
            _ = controller.dwindleEngine?.rekeyWindow(from: oldToken, to: newToken, in: workspaceId)
        }

        controller.focusBridge.rekeyPendingFocus(from: oldToken, to: newToken)
        controller.focusBridge.rekeyManagedRequest(from: oldToken, to: newToken)
        controller.focusBridge.rekeyFocusedTarget(
            from: oldToken,
            to: newToken,
            axRef: axRef,
            workspaceId: entry.workspaceId
        )
        controller.axManager.rekeyWindowState(
            pid: newToken.pid,
            oldWindowId: oldToken.windowId,
            newWindow: axRef
        )
        controller.layoutRefreshController.rekeyPendingRevealTransaction(
            from: oldToken,
            to: newToken,
            entry: entry
        )
        AXWindowService.invalidateCachedTitles(windowIds: [UInt32(oldToken.windowId), windowId])
        subscribeToWindows([windowId])
        controller.requestWorkspaceBarRefresh()
        controller.niriLayoutHandler.updateTabbedColumnOverlays()
        refreshBorderAfterManagedRekey(from: oldToken, entry: entry)

        Task { @MainActor [weak self] in
            guard let self, let controller = self.controller else { return }
            if let app = NSRunningApplication(processIdentifier: newToken.pid) {
                _ = await controller.axManager.windowsForApp(app)
            }
        }

        return entry
    }

    private func handleNativeFullscreenDestroy(_ token: WindowToken) -> Bool {
        guard let controller,
              let record = controller.workspaceManager.nativeFullscreenRecord(for: token),
              record.currentToken == token
        else {
            return false
        }

        guard let unavailableRecord = controller.workspaceManager.markNativeFullscreenTemporarilyUnavailable(
            token
        ) else {
            return false
        }

        controller.hideKeyboardFocusBorder(
            source: .nativeFullscreenEnter,
            reason: "native fullscreen window destroyed",
            matchingToken: token
        )
        scheduleNativeFullscreenFollowup(for: unavailableRecord.originalToken)
        return true
    }

    func handleAppHidden(pid: pid_t) {
        guard let controller else { return }
        controller.hiddenAppPIDs.insert(pid)

        if let activeRequest = controller.focusBridge.activeManagedRequest,
           activeRequest.token.pid == pid
        {
            _ = controller.focusBridge.cancelManagedRequest(requestId: activeRequest.requestId)
            cancelActivationRetry(requestId: activeRequest.requestId)
            controller.focusBridge.discardPendingFocus(activeRequest.token)
        }
        if controller.currentKeyboardFocusTargetForRendering()?.pid == pid {
            controller.clearKeyboardFocusTarget(pid: pid)
            _ = controller.workspaceManager.enterNonManagedFocus(
                appFullscreen: false,
                preserveFocusedToken: true
            )
            controller.hideKeyboardFocusBorder(
                source: .appHide,
                reason: "focused app hidden",
                matchingPid: pid
            )
        }

        for entry in controller.workspaceManager.entries(forPid: pid) {
            controller.workspaceManager.setLayoutReason(.macosHiddenApp, for: entry.token)
        }
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appHidden)
    }

    func handleAppUnhidden(pid: pid_t) {
        guard let controller else { return }
        controller.hiddenAppPIDs.remove(pid)

        for entry in controller.workspaceManager.entries(forPid: pid) {
            if controller.workspaceManager.layoutReason(for: entry.token) == .macosHiddenApp {
                _ = controller.workspaceManager.restoreFromNativeState(for: entry.token)
            }
        }
        _ = controller.renderKeyboardFocusBorder(
            policy: .direct,
            source: .appUnhide
        )
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appUnhidden)
    }

    func handleWindowMinimizedChanged(pid: pid_t, windowId: Int, isMinimized: Bool) {
        guard let controller else { return }

        if isMinimized {
            _ = controller.hideKeyboardFocusBorder(
                source: .windowMinimizedChanged,
                reason: "window minimized",
                matchingPid: pid,
                matchingWindowId: windowId
            )
            return
        }

        _ = controller.renderKeyboardFocusBorder(
            policy: .direct,
            source: .windowMinimizedChanged
        )
    }

    func resetManagedReplacementState() {
        for (_, task) in pendingManagedReplacementTasks {
            task.cancel()
        }
        pendingManagedReplacementTasks.removeAll()
        pendingManagedReplacementBursts.removeAll()
        nextManagedReplacementEventSequence = 0
    }

    func resetWindowStabilizationState() {
        for (_, task) in pendingWindowStabilizationTasks {
            task.cancel()
        }
        pendingWindowStabilizationTasks.removeAll()
    }

    func flushPendingManagedReplacementEventsForTests() {
        let keys = pendingManagedReplacementBursts.keys.sorted {
            ($0.pid, $0.workspaceId.uuidString) < ($1.pid, $1.workspaceId.uuidString)
        }
        for key in keys {
            pendingManagedReplacementTasks.removeValue(forKey: key)?.cancel()
            flushManagedReplacementBurst(for: key)
        }
    }

    func flushPendingNativeFullscreenFollowupsForTests() {
        let tokens = pendingNativeFullscreenFollowupTasks.keys.sorted {
            ($0.pid, $0.windowId) < ($1.pid, $1.windowId)
        }
        for originalToken in tokens {
            pendingNativeFullscreenFollowupTasks.removeValue(forKey: originalToken)?.cancel()
            guard let controller,
                  let record = controller.workspaceManager.nativeFullscreenRecord(for: originalToken),
                  record.originalToken == originalToken,
                  record.availability == .temporarilyUnavailable
            else {
                continue
            }
            controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        }
    }

    private func prepareCreateCandidate(
        windowId: UInt32,
        windowInfo: WindowServerInfo?
    ) -> PreparedCreate? {
        guard let controller else { return nil }
        let ownedWindow = controller.isOwnedWindow(windowNumber: Int(windowId))
        guard let token = windowInfo.map({ WindowToken(pid: pid_t($0.pid), windowId: Int(windowId)) }) else { return nil }
        if controller.workspaceManager.entry(for: token) != nil { return nil }

        if !ownedWindow {
            subscribeToWindows([windowId])
        }

        guard let axRef = resolveAXWindowRef(windowId: windowId, pid: token.pid) else { return nil }

        let app = NSRunningApplication(processIdentifier: token.pid)
        let bundleId = resolveBundleId(token.pid) ?? app?.bundleIdentifier
        let appFullscreen = isFullscreenProvider?(axRef) ?? AXWindowService.isFullscreen(axRef)
        let evaluation = controller.evaluateWindowDisposition(
            axRef: axRef,
            pid: token.pid,
            appFullscreen: appFullscreen,
            windowInfo: windowInfo
        )

        let trackedMode = controller.trackedModeForLifecycle(
            decision: evaluation.decision,
            existingEntry: nil
        )

        if ownedWindow { return nil }

        if trackedMode == nil {
            scheduleWindowStabilizationRetryIfNeeded(
                token: token,
                decision: evaluation.decision
            )
        }

        guard let trackedMode else { return nil }

        let workspaceId = controller.resolveWorkspaceForNewWindow(
            workspaceName: evaluation.decision.workspaceName,
            axRef: axRef,
            pid: token.pid,
            fallbackWorkspaceId: controller.activeWorkspace()?.id
        )

        return PreparedCreate(
            windowId: windowId,
            token: token,
            axRef: axRef,
            ruleEffects: evaluation.decision.ruleEffects,
            replacementMetadata: makeManagedReplacementMetadata(
                bundleId: bundleId ?? evaluation.facts.ax.bundleId,
                workspaceId: workspaceId,
                mode: trackedMode,
                facts: evaluation.facts
            )
        )
    }

    private func prepareDestroyCandidate(
        windowId: UInt32,
        pidHint: pid_t?
    ) -> PreparedDestroy? {
        guard let controller else { return nil }

        let hintedToken = pidHint.flatMap { hintedPid -> WindowToken? in
            let token = WindowToken(pid: hintedPid, windowId: Int(windowId))
            return controller.workspaceManager.entry(for: token) != nil ? token : nil
        }
        let resolvedToken = hintedToken
            ?? resolveTrackedToken(windowId)
            ?? pidHint.map { WindowToken(pid: $0, windowId: Int(windowId)) }

        guard let token = resolvedToken,
              let entry = controller.workspaceManager.entry(for: token)
        else {
            return nil
        }

        let bundleId = resolveBundleId(token.pid) ?? entry.managedReplacementMetadata?.bundleId
        let windowInfo = resolveWindowInfo(windowId)
        let cachedMetadata = overlayWindowServerInfo(
            windowInfo,
            onto: cachedManagedReplacementMetadata(
                for: entry,
                fallbackBundleId: bundleId
            )
        )
        let replacementMetadata: ManagedReplacementMetadata
        if managedReplacementNeedsLiveAXFacts(cachedMetadata) {
            let facts = managedReplacementFacts(
                for: entry.axRef,
                pid: token.pid,
                bundleId: cachedMetadata.bundleId,
                windowInfo: windowInfo,
                includeTitle: false
            )
            let liveMetadata = makeManagedReplacementMetadata(
                bundleId: cachedMetadata.bundleId,
                workspaceId: entry.workspaceId,
                mode: entry.mode,
                facts: facts
            )
            replacementMetadata = cachedMetadata.mergingNonNilValues(from: liveMetadata)
        } else {
            replacementMetadata = cachedMetadata
        }

        return PreparedDestroy(
            token: token,
            replacementMetadata: replacementMetadata
        )
    }

    private func handleWindowDestroyed(
        windowId: UInt32,
        pidHint: pid_t?
    ) {
        // Refresh the recently-destroyed mark for every destroy signal,
        // even ones that don't reach `handleRemoved(token:)` (e.g. the
        // second destroy of a native-FS ping-pong, where the entry is
        // already gone and no candidate can be prepared). Without this,
        // a later full rescan would re-admit a windowId whose
        // destruction macOS kept repeating.
        markWindowRecentlyDestroyed(windowId: Int(windowId))

        let resolvedToken = resolveTrackedToken(windowId)
            ?? pidHint.map { WindowToken(pid: $0, windowId: Int(windowId)) }
        if let resolvedToken {
            cancelWindowStabilizationRetry(for: resolvedToken)
            controller?.clearManualWindowOverride(for: resolvedToken)
        }

        guard let candidate = prepareDestroyCandidate(windowId: windowId, pidHint: pidHint) else {
            if let resolvedToken {
                scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(resolvedToken.pid)])
            } else if let pid = pidHint ?? resolveWindowInfo(windowId)?.pid {
                scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(pid_t(pid))])
            }
            return
        }

        if shouldDelayManagedReplacementDestroy(candidate) {
            enqueueManagedReplacementDestroy(candidate)
            return
        }

        processPreparedDestroy(candidate)
    }

    private func processPreparedDestroy(_ candidate: PreparedDestroy) {
        handleRemoved(token: candidate.token)
    }

    private func shouldDelayManagedReplacementCreate(_ candidate: PreparedCreate) -> Bool {
        guard let _ = managedReplacementCorrelationPolicy(for: candidate.replacementMetadata) else {
            return false
        }

        let key = ManagedReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        if pendingManagedReplacementBursts[key] != nil {
            return true
        }

        return hasPotentialStructuralReplacementSibling(for: candidate)
    }

    private func shouldDelayManagedReplacementDestroy(_ candidate: PreparedDestroy) -> Bool {
        managedReplacementCorrelationPolicy(for: candidate.replacementMetadata) != nil
    }

    private func enqueueManagedReplacementCreate(_ candidate: PreparedCreate) {
        guard let policy = managedReplacementCorrelationPolicy(for: candidate.replacementMetadata) else { return }
        let key = ManagedReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        let isNewBurst = pendingManagedReplacementBursts[key] == nil
        var burst = pendingManagedReplacementBursts[key] ?? PendingManagedReplacementBurst(
            policy: policy,
            firstEventUptime: managedReplacementCurrentUptime()
        )
        let pendingCreate = PendingManagedCreate(sequence: nextManagedReplacementSequence(), candidate: candidate)
        burst.append(create: pendingCreate)
        pendingManagedReplacementBursts[key] = burst
        let resetExistingDeadline = isNewBurst
        scheduleManagedReplacementFlush(
            for: key,
            policy: policy,
            resetExistingDeadline: resetExistingDeadline
        )
    }

    private func enqueueManagedReplacementDestroy(_ candidate: PreparedDestroy) {
        guard let policy = managedReplacementCorrelationPolicy(for: candidate.replacementMetadata) else { return }
        let key = ManagedReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        let isNewBurst = pendingManagedReplacementBursts[key] == nil
        var burst = pendingManagedReplacementBursts[key] ?? PendingManagedReplacementBurst(
            policy: policy,
            firstEventUptime: managedReplacementCurrentUptime()
        )
        let pendingDestroy = PendingManagedDestroy(sequence: nextManagedReplacementSequence(), candidate: candidate)
        burst.append(destroy: pendingDestroy)
        pendingManagedReplacementBursts[key] = burst
        let resetExistingDeadline = isNewBurst
        scheduleManagedReplacementFlush(
            for: key,
            policy: policy,
            resetExistingDeadline: resetExistingDeadline
        )
    }

    private func matchedManagedReplacementPair(
        in burst: PendingManagedReplacementBurst
    ) -> MatchedManagedReplacementPair? {
        var matchedPair: MatchedManagedReplacementPair?

        for destroy in burst.destroys {
            for create in burst.creates {
                guard destroy.candidate.token != create.candidate.token,
                      managedReplacementMetadataMatches(
                          old: destroy.candidate.replacementMetadata,
                          new: create.candidate.replacementMetadata
                      )
                else {
                    continue
                }

                if matchedPair != nil {
                    return nil
                }
                matchedPair = MatchedManagedReplacementPair(destroy: destroy, create: create)
            }
        }

        return matchedPair
    }

    @discardableResult
    private func completeManagedReplacement(
        destroy: PendingManagedDestroy,
        create: PendingManagedCreate
    ) -> Bool {
        rekeyManagedReplacement(from: destroy.candidate.token, to: create.candidate)
    }

    private func replayManagedReplacementEvents(_ events: [PendingManagedReplacementEvent]) {
        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            switch event {
            case let .create(create):
                trackPreparedCreate(create.candidate)
            case let .destroy(destroy):
                processPreparedDestroy(destroy.candidate)
            }
        }
    }

    @discardableResult
    private func rekeyManagedReplacement(from oldToken: WindowToken, to create: PreparedCreate) -> Bool {
        rekeyManagedWindowIdentity(
            from: oldToken,
            to: create.token,
            windowId: create.windowId,
            axRef: create.axRef,
            managedReplacementMetadata: create.replacementMetadata
        ) != nil
    }

    private func makeManagedReplacementMetadata(
        bundleId: String?,
        workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode,
        facts: WindowRuleFacts
    ) -> ManagedReplacementMetadata {
        ManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: workspaceId,
            mode: mode,
            role: facts.ax.role,
            subrole: facts.ax.subrole,
            title: facts.ax.title,
            windowLevel: facts.windowServer?.level,
            parentWindowId: facts.windowServer?.parentId,
            frame: facts.windowServer?.frame
        )
    }

    private func cachedManagedReplacementMetadata(
        for entry: WindowModel.Entry,
        fallbackBundleId: String?
    ) -> ManagedReplacementMetadata {
        var metadata = entry.managedReplacementMetadata ?? ManagedReplacementMetadata(
            bundleId: fallbackBundleId,
            workspaceId: entry.workspaceId,
            mode: entry.mode,
            role: nil,
            subrole: nil,
            title: nil,
            windowLevel: nil,
            parentWindowId: nil,
            frame: nil
        )
        metadata.bundleId = metadata.bundleId ?? fallbackBundleId
        metadata.workspaceId = entry.workspaceId
        metadata.mode = entry.mode
        return metadata
    }

    private func overlayWindowServerInfo(
        _ windowInfo: WindowServerInfo?,
        onto metadata: ManagedReplacementMetadata
    ) -> ManagedReplacementMetadata {
        guard let windowInfo else { return metadata }
        var metadata = metadata
        metadata.title = windowInfo.title ?? metadata.title
        metadata.windowLevel = windowInfo.level
        metadata.parentWindowId = windowInfo.parentId == 0 ? metadata.parentWindowId : windowInfo.parentId
        metadata.frame = windowInfo.frame
        return metadata
    }

    private func managedReplacementFacts(
        for axRef: AXWindowRef,
        pid: pid_t,
        bundleId: String?,
        windowInfo: WindowServerInfo?,
        includeTitle: Bool
    ) -> WindowRuleFacts {
        if let providedFacts = windowFactsProvider?(axRef, pid) {
            return WindowRuleFacts(
                appName: providedFacts.appName,
                ax: providedFacts.ax,
                sizeConstraints: providedFacts.sizeConstraints,
                windowServer: providedFacts.windowServer ?? windowInfo
            )
        }

        let app = NSRunningApplication(processIdentifier: pid)
        return WindowRuleFacts(
            appName: app?.localizedName,
            ax: AXWindowService.collectWindowFacts(
                axRef,
                appPolicy: app?.activationPolicy,
                bundleId: bundleId,
                includeTitle: includeTitle
            ),
            sizeConstraints: nil,
            windowServer: windowInfo
        )
    }

    private func managedReplacementNeedsLiveAXFacts(
        _ metadata: ManagedReplacementMetadata
    ) -> Bool {
        guard metadata.role != nil, metadata.subrole != nil else {
            return true
        }
        return !managedReplacementHasStructuralAnchor(metadata)
    }

    private func hasPotentialStructuralReplacementSibling(for candidate: PreparedCreate) -> Bool {
        guard let controller else { return false }
        return controller.workspaceManager.entries(forPid: candidate.token.pid).contains { entry in
            guard entry.workspaceId == candidate.workspaceId,
                  entry.token != candidate.token
            else {
                return false
            }

            let siblingMetadata = overlayWindowServerInfo(
                resolveWindowInfo(UInt32(entry.windowId)),
                onto: cachedManagedReplacementMetadata(
                    for: entry,
                    fallbackBundleId: candidate.bundleId
                )
            )
            guard managedReplacementCorrelationPolicy(for: siblingMetadata) != nil else {
                return false
            }
            return managedReplacementMetadataMatches(
                old: siblingMetadata,
                new: candidate.replacementMetadata
            )
        }
    }

    private func managedReplacementCorrelationPolicy(
        for metadata: ManagedReplacementMetadata
    ) -> ManagedReplacementCorrelationPolicy? {
        guard metadata.role != nil,
              metadata.subrole != nil,
              managedReplacementHasStructuralAnchor(metadata)
        else { return nil }
        return .structural
    }

    private func managedReplacementMetadataMatches(
        old: ManagedReplacementMetadata,
        new: ManagedReplacementMetadata
    ) -> Bool {
        guard managedReplacementCorrelationPolicy(for: old) != nil,
              managedReplacementCorrelationPolicy(for: new) != nil,
              managedReplacementBundleIdsMatch(old.bundleId, new.bundleId),
              old.workspaceId == new.workspaceId,
              old.role == new.role,
              old.subrole == new.subrole,
              managedReplacementWindowLevelsMatch(old.windowLevel, new.windowLevel)
        else {
            return false
        }

        return managedReplacementStructuralAnchorsMatch(old: old, new: new)
    }

    private func managedReplacementHasStructuralAnchor(
        _ metadata: ManagedReplacementMetadata
    ) -> Bool {
        metadata.parentWindowId != nil || metadata.frame != nil
    }

    private func managedReplacementBundleIdsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs?.lowercased(), rhs?.lowercased()) {
        case let (lhs?, rhs?):
            return lhs == rhs
        default:
            return true
        }
    }

    private func managedReplacementWindowLevelsMatch(_ lhs: Int32?, _ rhs: Int32?) -> Bool {
        guard let lhs, let rhs else { return true }
        return lhs == rhs
    }

    private func managedReplacementStructuralAnchorsMatch(
        old: ManagedReplacementMetadata,
        new: ManagedReplacementMetadata
    ) -> Bool {
        var hasStructuralEvidence = false
        if let oldParentWindowId = old.parentWindowId,
           let newParentWindowId = new.parentWindowId
        {
            guard oldParentWindowId == newParentWindowId else {
                return false
            }
            hasStructuralEvidence = true
        }

        if let oldFrame = old.frame,
           let newFrame = new.frame
        {
            guard framesAreCloseForManagedReplacement(oldFrame, newFrame) else {
                return false
            }
            hasStructuralEvidence = true
        }

        return hasStructuralEvidence
    }

    private func framesAreCloseForManagedReplacement(_ lhs: CGRect?, _ rhs: CGRect?) -> Bool {
        guard let lhs, let rhs else { return false }

        return abs(lhs.midX - rhs.midX) <= 96
            && abs(lhs.midY - rhs.midY) <= 96
            && abs(lhs.width - rhs.width) <= 64
            && abs(lhs.height - rhs.height) <= 64
    }

    private func refreshBorderAfterManagedRekey(
        from oldToken: WindowToken,
        entry: WindowModel.Entry
    ) {
        guard let controller else { return }
        guard controller.currentKeyboardFocusTargetForRendering()?.token == entry.token else { return }

        let preferredFrame = controller.niriEngine?.findNode(for: entry.token).flatMap { $0.renderedFrame ?? $0.frame }
            ?? frameProvider?(entry.axRef)
        _ = controller.borderCoordinator.reconcile(
            event: .managedRekey(
                from: oldToken,
                to: entry.token,
                workspaceId: entry.workspaceId,
                axRef: entry.axRef,
                preferredFrame: preferredFrame,
                policy: .coordinated
            )
        )
    }

    private func resetNativeFullscreenReplacementState() {
        for (_, task) in pendingNativeFullscreenFollowupTasks {
            task.cancel()
        }
        pendingNativeFullscreenFollowupTasks.removeAll()
        for (_, task) in pendingNativeFullscreenStaleCleanupTasks {
            task.cancel()
        }
        pendingNativeFullscreenStaleCleanupTasks.removeAll()
    }

    private func scheduleNativeFullscreenFollowup(for originalToken: WindowToken) {
        cancelNativeFullscreenLifecycleTasks(for: originalToken)
        pendingNativeFullscreenFollowupTasks[originalToken] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.nativeFullscreenFollowupDelay)
            guard !Task.isCancelled, let self, let controller = self.controller else { return }
            defer { self.pendingNativeFullscreenFollowupTasks.removeValue(forKey: originalToken) }
            guard let record = controller.workspaceManager.nativeFullscreenRecord(for: originalToken),
                  record.originalToken == originalToken,
                  record.availability == .temporarilyUnavailable
            else {
                return
            }
            controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        }
        pendingNativeFullscreenStaleCleanupTasks[originalToken] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.nativeFullscreenStaleCleanupDelay)
            guard !Task.isCancelled, let self, let controller = self.controller else { return }
            defer { self.pendingNativeFullscreenStaleCleanupTasks.removeValue(forKey: originalToken) }
            guard let record = controller.workspaceManager.nativeFullscreenRecord(for: originalToken),
                  record.originalToken == originalToken,
                  record.availability == .temporarilyUnavailable
            else {
                return
            }
            let removedEntries = controller.workspaceManager.expireStaleTemporarilyUnavailableNativeFullscreenRecords()
            guard !removedEntries.isEmpty else { return }
            controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        }
    }

    func cancelNativeFullscreenLifecycleTasks(for originalToken: WindowToken) {
        pendingNativeFullscreenFollowupTasks.removeValue(forKey: originalToken)?.cancel()
        pendingNativeFullscreenStaleCleanupTasks.removeValue(forKey: originalToken)?.cancel()
    }

    func cancelNativeFullscreenLifecycleTasks(containing token: WindowToken) {
        if let controller,
           let originalToken = controller.workspaceManager.nativeFullscreenRecord(for: token)?.originalToken
        {
            cancelNativeFullscreenLifecycleTasks(for: originalToken)
            return
        }
        cancelNativeFullscreenLifecycleTasks(for: token)
    }

    private func managedReplacementGraceDelay(for policy: ManagedReplacementCorrelationPolicy) -> Duration {
        switch policy {
        case .structural:
            Self.managedReplacementGraceDelay
        }
    }

    private func scheduleManagedReplacementFlush(
        for key: ManagedReplacementKey,
        policy: ManagedReplacementCorrelationPolicy,
        resetExistingDeadline: Bool
    ) {
        if resetExistingDeadline {
            pendingManagedReplacementTasks.removeValue(forKey: key)?.cancel()
        } else if pendingManagedReplacementTasks[key] != nil {
            return
        }

        let delay = managedReplacementGraceDelay(for: policy)
        pendingManagedReplacementTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flushManagedReplacementBurst(for: key)
        }
    }

    private func flushManagedReplacementBurst(for key: ManagedReplacementKey) {
        pendingManagedReplacementTasks.removeValue(forKey: key)?.cancel()
        guard let burst = pendingManagedReplacementBursts.removeValue(forKey: key) else { return }

        if let pair = matchedManagedReplacementPair(in: burst) {
            if completeManagedReplacement(destroy: pair.destroy, create: pair.create) {
                replayManagedReplacementEvents(
                    burst.orderedEvents(excludingSequences: pair.excludedSequences)
                )
            } else {
                replayManagedReplacementEvents(burst.orderedEvents)
            }
            return
        }

        replayManagedReplacementEvents(burst.orderedEvents)
    }

    private func nextManagedReplacementSequence() -> UInt64 {
        defer { nextManagedReplacementEventSequence += 1 }
        return nextManagedReplacementEventSequence
    }

    private func updateManagedReplacementFrame(_ frame: CGRect, for entry: WindowModel.Entry) {
        guard let controller else { return }
        _ = controller.workspaceManager.updateManagedReplacementFrame(frame, for: entry.token)
    }

    private func updateManagedReplacementTitle(windowId: UInt32, token: WindowToken) {
        guard let controller,
              let entry = controller.workspaceManager.entry(for: token),
              let title = resolveWindowInfo(windowId)?.title ?? AXWindowService.titlePreferFast(windowId: windowId)
        else {
            return
        }
        _ = controller.workspaceManager.updateManagedReplacementTitle(title, for: entry.token)
    }

    private func scheduleWindowStabilizationRetryIfNeeded(
        token: WindowToken,
        decision: WindowDecision
    ) {
        guard decision.disposition == .undecided,
              decision.deferredReason != nil
        else {
            return
        }

        pendingWindowStabilizationTasks[token]?.cancel()
        pendingWindowStabilizationTasks[token] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.stabilizationRetryDelay)
            guard !Task.isCancelled, let self, let controller = self.controller else { return }
            self.pendingWindowStabilizationTasks.removeValue(forKey: token)
            _ = await controller.reevaluateWindowRules(for: [.window(token)])
        }
    }

    private func cancelWindowStabilizationRetry(for token: WindowToken) {
        pendingWindowStabilizationTasks.removeValue(forKey: token)?.cancel()
    }

    private func scheduleCreatedWindowRetryIfNeeded(
        windowId: UInt32,
        pid: pid_t
    ) -> Bool {
        guard let controller else { return false }
        let token = WindowToken(pid: pid, windowId: Int(windowId))
        guard controller.workspaceManager.entry(for: token) == nil else {
            cancelCreatedWindowRetry(windowId: windowId)
            return false
        }
        guard !controller.isOwnedWindow(windowNumber: Int(windowId)) else {
            cancelCreatedWindowRetry(windowId: windowId)
            return false
        }
        guard resolveAXWindowRef(windowId: windowId, pid: pid) == nil else {
            return false
        }

        let attempt = createdWindowRetryCountById[windowId, default: 0] + 1
        guard attempt <= Self.createdWindowRetryLimit else { return false }

        createdWindowRetryCountById[windowId] = attempt
        pendingCreatedWindowRetryTasks.removeValue(forKey: windowId)?.cancel()
        pendingCreatedWindowRetryTasks[windowId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.stabilizationRetryDelay)
            guard !Task.isCancelled, let self else { return }
            self.pendingCreatedWindowRetryTasks.removeValue(forKey: windowId)
            self.processCreatedWindow(windowId: windowId)
        }
        return true
    }

    private func cancelCreatedWindowRetry(windowId: UInt32) {
        pendingCreatedWindowRetryTasks.removeValue(forKey: windowId)?.cancel()
        createdWindowRetryCountById.removeValue(forKey: windowId)
    }

    private func markWindowRecentlyDestroyed(windowId: Int) {
        recentlyDestroyedWindowIds[windowId] = ContinuousClock.now
        pruneRecentlyDestroyedWindowIds()
    }

    private func clearRecentlyDestroyedWindow(windowId: Int) {
        recentlyDestroyedWindowIds.removeValue(forKey: windowId)
    }

    /// Returns true if the given windowId was destroyed via a CGS
    /// `windowDestroyed` notification within
    /// `recentlyDestroyedWindowTTL`. The full-rescan admission path uses
    /// this to ignore stale AX enumeration hits during native-FS space
    /// transitions, letting the follow-up `windowCreated` notification
    /// be the single source of truth.
    func isWindowRecentlyDestroyed(windowId: Int) -> Bool {
        guard let destroyedAt = recentlyDestroyedWindowIds[windowId] else {
            return false
        }
        let elapsed = ContinuousClock.now - destroyedAt
        if elapsed >= Self.recentlyDestroyedWindowTTL {
            recentlyDestroyedWindowIds.removeValue(forKey: windowId)
            return false
        }
        return true
    }

    private func pruneRecentlyDestroyedWindowIds() {
        guard !recentlyDestroyedWindowIds.isEmpty else { return }
        let now = ContinuousClock.now
        recentlyDestroyedWindowIds = recentlyDestroyedWindowIds.filter { _, timestamp in
            now - timestamp < Self.recentlyDestroyedWindowTTL
        }
    }

    private func resetCreatedWindowRetryState() {
        for (_, task) in pendingCreatedWindowRetryTasks {
            task.cancel()
        }
        pendingCreatedWindowRetryTasks.removeAll()
        createdWindowRetryCountById.removeAll()
    }

    func applyActivationOrchestrationResult(
        _ result: OrchestrationResult,
        observedAXRef: AXWindowRef?,
        managedEntry: WindowModel.Entry?,
        source: ActivationEventSource,
        confirmRequest: Bool = true
    ) {
        guard let controller else { return }
        controller.focusBridge.applyOrchestrationState(
            nextManagedRequestId: result.snapshot.focus.nextManagedRequestId,
            activeManagedRequest: result.snapshot.focus.activeManagedRequest
        )
        _ = controller.workspaceManager.applyOrchestrationFocusState(result.snapshot.focus)

        for action in result.plan.actions {
            switch action {
            case let .clearManagedFocusState(requestId, token, workspaceId):
                clearManagedFocusState(
                    requestId: requestId,
                    matching: token,
                    workspaceId: workspaceId
                )
            case let .continueManagedFocusRequest(requestId, reason, source, origin):
                guard let request = controller.focusBridge.activeManagedRequest(requestId: requestId) else {
                    continue
                }
                continueManagedFocusRequest(
                    request,
                    source: source,
                    origin: origin,
                    reason: reason
                )
            case let .confirmManagedActivation(token, workspaceId, monitorId, isWorkspaceActive, appFullscreen, source):
                guard let entry = managedEntry ?? controller.workspaceManager.entry(for: token) else {
                    continue
                }
                confirmManagedActivation(
                    entry: entry,
                    workspaceId: workspaceId,
                    monitorId: monitorId,
                    isWorkspaceActive: isWorkspaceActive,
                    appFullscreen: appFullscreen,
                    source: source,
                    confirmRequest: confirmRequest
                )
            case let .beginNativeFullscreenRestoreActivation(token, workspaceId, monitorId, isWorkspaceActive, _):
                guard let entry = managedEntry ?? controller.workspaceManager.entry(for: token) else {
                    continue
                }
                beginNativeFullscreenRestoreActivation(
                    entry: entry,
                    workspaceId: workspaceId,
                    monitorId: monitorId,
                    isWorkspaceActive: isWorkspaceActive
                )
            case let .enterNonManagedFallback(pid, token, appFullscreen, source):
                resetSameAppFocusPreemptions()
                if let token {
                    let resolvedAXRef = observedAXRef ?? resolveFocusedAXWindowRef(pid: pid)
                    if let resolvedAXRef {
                        let target = controller.keyboardFocusTarget(for: token, axRef: resolvedAXRef)
                        controller.focusBridge.setFocusedTarget(target)
                        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: appFullscreen)
                        _ = controller.renderKeyboardFocusBorder(
                            for: target,
                            policy: .direct,
                            source: borderReconcileSource(for: source)
                        )
                    }
                } else {
                    cancelActivationRetry()
                    controller.focusBridge.setFocusedTarget(nil)
                    _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: appFullscreen)
                    controller.hideKeyboardFocusBorder(
                        source: borderReconcileSource(for: source),
                        reason: "missing focused window during fallback transition",
                        matchingPid: pid
                    )
                }

            case let .cancelActivationRetry(requestId):
                if let requestId {
                    cancelActivationRetry(requestId: requestId)
                } else {
                    cancelActivationRetry()
                }
            case let .enterOwnedApplicationFallback(pid, source):
                resetSameAppFocusPreemptions()
                controller.clearKeyboardFocusTarget(pid: pid)
                controller.hideKeyboardFocusBorder(
                    source: borderReconcileSource(for: source),
                    reason: "owned window became frontmost",
                    matchingPid: pid
                )
            case .beginManagedFocusRequest,
                 .cancelActiveRefresh,
                 .discardPostLayoutAttachments,
                 .frontManagedWindow,
                 .performVisibilitySideEffects,
                 .requestWorkspaceBarRefresh,
                 .runPostLayoutAttachments,
                 .startRefresh:
                continue
            }
        }

        if case let .focusRequestCancelled(_, token) = result.decision,
           let token
        {
            handleActivationRetryExhausted(pid: token.pid, source: source)
        }
    }

    private func appFullscreenForFallbackLifecyclePreservation(
        observedAppFullscreen: Bool
    ) -> Bool {
        guard let controller else { return observedAppFullscreen }

        let hasLifecycleContext = controller.workspaceManager.hasNativeFullscreenLifecycleContext
        return observedAppFullscreen || hasLifecycleContext
    }

    private func borderReconcileSource(for source: ActivationEventSource) -> BorderReconcileSource {
        switch source {
        case .focusedWindowChanged:
            .focusedWindowChanged
        case .workspaceDidActivateApplication:
            .frontmostAppChanged
        case .cgsFrontAppChanged:
            .frontmostAppChanged
        }
    }

    func cleanupFocusStateForTerminatedApp(pid: pid_t) {
        guard let controller else { return }

        if focusedRemovalActivationSuppression?.suppressedActivationPid == pid {
            resetFocusedRemovalActivationSuppression()
        }
        resetSameAppFocusState(for: pid)

        let entries = controller.workspaceManager.entries(forPid: pid)
        for entry in entries {
            clearManagedFocusState(
                matching: entry.token,
                workspaceId: entry.workspaceId
            )
        }

        if let activeRequest = controller.focusBridge.activeManagedRequest,
           activeRequest.token.pid == pid
        {
            clearManagedFocusState(
                matching: activeRequest.token,
                workspaceId: activeRequest.workspaceId
            )
        }

        controller.clearKeyboardFocusTarget(pid: pid, restoreCurrentBorder: false)
        controller.focusBridge.clearFocusedTarget(pid: pid)
    }

    private func clearManagedFocusState(
        requestId: UInt64? = nil,
        matching token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID?
    ) {
        guard let controller else { return }

        controller.focusBridge.discardPendingFocus(token)
        let canceledRequest = controller.focusBridge.cancelManagedRequest(
            matching: token,
            workspaceId: workspaceId
        )
        if let requestId {
            cancelActivationRetry(requestId: requestId)
        } else if let canceledRequest {
            cancelActivationRetry(requestId: canceledRequest.requestId)
        }
        _ = controller.workspaceManager.cancelManagedFocusRequest(
            matching: token,
            workspaceId: workspaceId
        )
        if let workspaceId {
            completeFocusedRemovalRecoveryIfExpected(token: token, workspaceId: workspaceId)
        } else if focusedRemovalActivationSuppression?.expectedRecoveryToken == token {
            resetFocusedRemovalActivationSuppression()
        }
        controller.clearKeyboardFocusTarget(
            matching: token,
            restoreCurrentBorder: false
        )
    }

    func clearManagedFocusStateForOrchestration(
        requestId: UInt64,
        matching token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID?
    ) {
        clearManagedFocusState(
            requestId: requestId,
            matching: token,
            workspaceId: workspaceId
        )
    }

    private func continueManagedFocusRequest(
        _ request: ManagedFocusRequest,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        reason: ActivationRetryReason
    ) {
        scheduleActivationRetry(
            request: request,
            source: source,
            origin: origin,
            reason: reason
        )
    }

    private func scheduleActivationRetry(
        request: ManagedFocusRequest,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        reason: ActivationRetryReason
    ) {
        guard controller != nil else { return }
        cancelActivationRetry()
        pendingActivationRetryRequestId = request.requestId
        let retryOrigin: ActivationCallOrigin = origin == .probe ? .probe : .retry
        pendingActivationRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.stabilizationRetryDelay)
            guard !Task.isCancelled, let self else { return }
            let requestId = request.requestId
            guard self.pendingActivationRetryRequestId == requestId else { return }
            self.pendingActivationRetryTask = nil
            self.pendingActivationRetryRequestId = nil
            guard let controller = self.controller,
                  let liveRequest = controller.focusBridge.activeManagedRequest(requestId: requestId)
            else {
                return
            }
            self.handleAppActivation(
                pid: liveRequest.token.pid,
                source: source,
                origin: retryOrigin
            )
        }
    }

    private func handleActivationRetryExhausted(
        pid: pid_t,
        source: ActivationEventSource
    ) {
        guard let controller else { return }

        cancelActivationRetry()

        if let target = controller.currentKeyboardFocusTargetForRendering(),
           controller.renderKeyboardFocusBorder(
               for: target,
               preferredFrame: controller.preferredKeyboardFocusFrame(for: target.token),
               policy: .direct,
               source: .borderReapplyRetryExhaustedFallback
           )
        {
        } else {
            controller.hideKeyboardFocusBorder(
                source: .borderReapplyRetryExhaustedFallback,
                reason: "retry exhausted without renderable target",
                matchingPid: pid
            )
        }
    }

    private func cancelActivationRetry() {
        pendingActivationRetryTask?.cancel()
        pendingActivationRetryTask = nil
        pendingActivationRetryRequestId = nil
    }

    private func cancelActivationRetry(requestId: UInt64) {
        guard pendingActivationRetryRequestId == requestId else { return }
        cancelActivationRetry()
    }

    private func resetActivationRetryState() {
        cancelActivationRetry()
    }

    private func deferCreatedWindow(_ windowId: UInt32) {
        guard deferredCreatedWindowIds.insert(windowId).inserted else { return }
        deferredCreatedWindowOrder.append(windowId)
    }

    private func removeDeferredCreatedWindow(_ windowId: UInt32) {
        guard deferredCreatedWindowIds.remove(windowId) != nil else { return }
        deferredCreatedWindowOrder.removeAll { $0 == windowId }
    }

    private func resolveWindowInfo(_ windowId: UInt32) -> WindowServerInfo? {
        windowInfoProvider?(windowId) ?? SkyLight.shared.queryWindowInfo(windowId)
    }

    private func resolveWindowToken(_ windowId: UInt32) -> WindowToken? {
        guard let windowInfo = resolveWindowInfo(windowId) else { return nil }
        return .init(pid: windowInfo.pid, windowId: Int(windowId))
    }

    private func resolveTrackedToken(_ windowId: UInt32) -> WindowToken? {
        if let entry = controller?.workspaceManager.entry(forWindowId: Int(windowId)) {
            return entry.token
        }
        return resolveWindowToken(windowId)
    }

    private func resolveAXWindowRef(windowId: UInt32, pid: pid_t) -> AXWindowRef? {
        axWindowRefProvider?(windowId, pid) ?? AXWindowService.axWindowRef(for: windowId, pid: pid)
    }

    @discardableResult
    private func subscribeToWindows(_ windowIds: [UInt32]) -> Bool {
        if let windowSubscriptionHandler {
            windowSubscriptionHandler(windowIds)
            return true
        }
        return CGSEventObserver.shared.subscribeToWindows(windowIds)
    }

    @discardableResult
    private func retainWindowNotificationSubscriptions(_ windowIds: [UInt32]) -> Bool {
        if let windowSubscriptionHandler {
            windowSubscriptionHandler(windowIds)
            return true
        }
        return CGSEventObserver.shared.retainWindowNotificationSubscriptions(windowIds)
    }

    @discardableResult
    private func releaseWindowNotificationSubscriptions(_ windowIds: [UInt32]) -> Set<UInt32> {
        if let windowUnsubscriptionHandler {
            return windowUnsubscriptionHandler(windowIds)
        }
        return CGSEventObserver.shared.releaseWindowNotificationSubscriptions(windowIds)
    }

    @discardableResult
    func requestWindowNotificationSubscription(_ windowIds: [UInt32]) -> Bool {
        retainWindowNotificationSubscriptions(windowIds)
    }

    @discardableResult
    func releaseWindowNotificationSubscription(_ windowIds: [UInt32]) -> Set<UInt32> {
        releaseWindowNotificationSubscriptions(windowIds)
    }

    private func resolveFocusedWindowValue(pid: pid_t) -> CFTypeRef? {
        if let focusedWindowValueProvider {
            return focusedWindowValueProvider(pid)
        }

        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard result == .success else { return nil }
        return focusedWindow
    }

    private func resolveFocusedAXWindowRef(pid: pid_t) -> AXWindowRef? {
        if let focusedWindowRefProvider {
            return focusedWindowRefProvider(pid)
        }
        guard let windowElement = resolveFocusedWindowValue(pid: pid) else {
            return nil
        }
        guard CFGetTypeID(windowElement) == AXUIElementGetTypeID() else {
            return nil
        }
        let axElement = unsafeDowncast(windowElement, to: AXUIElement.self)
        return try? AXWindowRef(element: axElement)
    }

    private func resolveBundleId(_ pid: pid_t) -> String? {
        guard let controller else { return nil }
        if let bundleIdProvider {
            return bundleIdProvider(pid)
        }
        return controller.appInfoCache.bundleId(for: pid) ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}
