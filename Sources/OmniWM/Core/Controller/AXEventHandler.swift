import AppKit
import Foundation

enum ActivationRetryReason: String, Equatable {
    case missingFocusedWindow = "missing_focused_window"
    case pendingFocusMismatch = "pending_focus_mismatch"
    case pendingFocusUnmanagedToken = "pending_focus_unmanaged_token"
    case retryExhausted = "retry_exhausted"
}

private enum ActivationRequestDisposition {
    case matchesActiveRequest(ManagedFocusRequest)
    case conflictsWithPendingRequest(ManagedFocusRequest)
    case unrelatedNoRequest
}

enum ActivationCallOrigin: String {
    case external
    case probe
    case retry
}

struct NiriCreateFocusTraceEvent: Equatable {
    enum Kind: Equatable {
        case createSeen(windowId: UInt32)
        case createRetryScheduled(windowId: UInt32, pid: pid_t, attempt: Int)
        case candidateTracked(token: WindowToken, workspaceId: WorkspaceDescriptor.ID)
        case relayoutActivatedWindow(token: WindowToken, workspaceId: WorkspaceDescriptor.ID)
        case pendingFocusStarted(requestId: UInt64, token: WindowToken, workspaceId: WorkspaceDescriptor.ID)
        case activationSourceObserved(pid: pid_t, source: ActivationEventSource)
        case activationDeferred(
            requestId: UInt64,
            token: WindowToken,
            source: ActivationEventSource,
            reason: ActivationRetryReason,
            attempt: Int
        )
        case focusConfirmed(token: WindowToken, workspaceId: WorkspaceDescriptor.ID, source: ActivationEventSource)
        case borderReapplied(token: WindowToken, phase: ManagedBorderReapplyPhase)
        case nonManagedFallbackEntered(pid: pid_t, source: ActivationEventSource)
    }

    let timestamp: Date
    let kind: Kind

    init(
        timestamp: Date = Date(),
        kind: Kind
    ) {
        self.timestamp = timestamp
        self.kind = kind
    }
}

extension NiriCreateFocusTraceEvent: CustomStringConvertible {
    var description: String {
        switch kind {
        case let .createSeen(windowId):
            "create_seen window=\(windowId)"
        case let .createRetryScheduled(windowId, pid, attempt):
            "create_retry_scheduled window=\(windowId) pid=\(pid) attempt=\(attempt)"
        case let .candidateTracked(token, workspaceId):
            "candidate_tracked token=\(token) workspace=\(workspaceId.uuidString)"
        case let .relayoutActivatedWindow(token, workspaceId):
            "relayout_activated_window token=\(token) workspace=\(workspaceId.uuidString)"
        case let .pendingFocusStarted(requestId, token, workspaceId):
            "pending_focus_started request=\(requestId) token=\(token) workspace=\(workspaceId.uuidString)"
        case let .activationSourceObserved(pid, source):
            "activation_source_observed pid=\(pid) source=\(source.rawValue)"
        case let .activationDeferred(requestId, token, source, reason, attempt):
            "activation_deferred request=\(requestId) token=\(token) source=\(source.rawValue) reason=\(reason.rawValue) attempt=\(attempt)"
        case let .focusConfirmed(token, workspaceId, source):
            "focus_confirmed token=\(token) workspace=\(workspaceId.uuidString) source=\(source.rawValue)"
        case let .borderReapplied(token, phase):
            "border_reapplied token=\(token) phase=\(phase.rawValue)"
        case let .nonManagedFallbackEntered(pid, source):
            "non_managed_fallback_entered pid=\(pid) source=\(source.rawValue)"
        }
    }
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

    private struct ManagedReplacementKey: Hashable {
        let pid: pid_t
        let workspaceId: WorkspaceDescriptor.ID
    }

    private enum ManagedReplacementCorrelationPolicy {
        case ghostty
        case strictMetadata
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
        var creates: [PendingManagedCreate] = []
        var destroys: [PendingManagedDestroy] = []
        var ghosttyDestroyHoldCount = 0

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

    private static let ghosttyBundleId = "com.mitchellh.ghostty"
    private static let replacementCorrelationBundleIds: Set<String> = [
        ghosttyBundleId,
        "com.apple.safari",
        "com.brave.browser",
        "com.google.chrome",
        "com.microsoft.edgemac",
        "com.vivaldi.vivaldi",
        "company.thebrowser.browser",
        "company.thebrowser.dia",
        "org.mozilla.firefox",
        "app.zen-browser.zen"
    ]
    private static let managedReplacementGraceDelay: Duration = .milliseconds(150)
    private static let nativeFullscreenFollowupDelay: Duration = .seconds(1)
    private static let nativeFullscreenStaleCleanupDelay: Duration = .seconds(
        Int64(WorkspaceManager.staleUnavailableNativeFullscreenTimeout)
    )
    private static let stabilizationRetryDelay: Duration = .milliseconds(100)
    private static let createdWindowRetryLimit = 5
    private static let activationRetryLimit = 5
    private static let createFocusTraceLimit = 128
    private static let createFocusTraceLoggingEnabled =
        ProcessInfo.processInfo.environment["OMNIWM_DEBUG_NIRI_CREATE_FOCUS"] == "1"

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
    private var createFocusTrace: [NiriCreateFocusTraceEvent] = []
    private var nextManagedReplacementEventSequence: UInt64 = 0
    var windowInfoProvider: ((UInt32) -> WindowServerInfo?)?
    var axWindowRefProvider: ((UInt32, pid_t) -> AXWindowRef?)?
    var bundleIdProvider: ((pid_t) -> String?)?
    var windowSubscriptionHandler: (([UInt32]) -> Void)?
    var focusedWindowValueProvider: ((pid_t) -> CFTypeRef?)?
    var focusedWindowRefProvider: ((pid_t) -> AXWindowRef?)?
    var windowFactsProvider: ((AXWindowRef, pid_t) -> WindowRuleFacts?)?
    var frameProvider: ((AXWindowRef) -> CGRect?)?
    var fastFrameProvider: ((AXWindowRef) -> CGRect?)?
    var isFullscreenProvider: ((AXWindowRef) -> Bool)?
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
            handleCGSWindowDestroyed(windowId: windowId)

        case let .closed(windowId):
            handleCGSWindowDestroyed(windowId: windowId)

        case let .frameChanged(windowId):
            handleFrameChanged(windowId: windowId)

        case let .frontAppChanged(pid):
            handleAppActivation(pid: pid, source: .cgsFrontAppChanged)

        case let .titleChanged(windowId):
            AXWindowService.invalidateCachedTitle(windowId: windowId)
            controller.requestWorkspaceBarRefresh()
            if let token = resolveWindowToken(windowId) ?? resolveTrackedToken(windowId) {
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
        recordNiriCreateFocusTrace(.init(kind: .createSeen(windowId: windowId)))
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
        controller?.focusBridge.reset()
        createFocusTrace.removeAll(keepingCapacity: true)
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

    func niriCreateFocusTraceSnapshotForTests() -> [NiriCreateFocusTraceEvent] {
        createFocusTrace
    }

    func recordNiriCreateFocusTrace(_ event: NiriCreateFocusTraceEvent) {
        if createFocusTrace.count == Self.createFocusTraceLimit {
            createFocusTrace.removeFirst()
        }
        createFocusTrace.append(event)

        if Self.createFocusTraceLoggingEnabled {
            fputs("[NiriCreateFocus] \(event.description)\n", stderr)
        }
    }

    private func handleFrameChanged(windowId: UInt32) {
        guard let controller else { return }
        guard let token = resolveTrackedToken(windowId) else { return }
        guard let entry = controller.workspaceManager.entry(for: token) else { return }

        guard isWindowDisplayable(token: token) else {
            return
        }

        updateFocusedBorderForFrameChange(token: token)

        if entry.mode == .floating {
            if let frame = frameProvider?(entry.axRef)
                ?? fastFrameProvider?(entry.axRef)
                ?? AXWindowService.framePreferFast(entry.axRef)
                ?? (try? AXWindowService.frame(entry.axRef))
            {
                controller.workspaceManager.updateFloatingGeometry(frame: frame, for: token)
            }
            return
        }

        if controller.isInteractiveGestureActive {
            debugCounters.geometryRelayoutsSuppressedDuringGesture += 1
            return
        }

        debugCounters.geometryRelayoutRequests += 1
        controller.layoutRefreshController.requestRelayout(reason: .axWindowChanged)
    }

    private func updateFocusedBorderForFrameChange(token: WindowToken) {
        guard let controller else { return }
        guard let target = controller.currentKeyboardFocusTargetForRendering(),
              target.token == token,
              let entry = controller.workspaceManager.entry(for: token)
        else { return }

        if let frame = frameProvider?(entry.axRef)
            ?? fastFrameProvider?(entry.axRef)
            ?? AXWindowService.framePreferFast(entry.axRef)
            ?? (try? AXWindowService.frame(entry.axRef))
        {
            updateManagedReplacementFrame(frame, for: entry)
            _ = controller.renderKeyboardFocusBorder(
                for: target,
                preferredFrame: frame,
                policy: .coordinated
            )
        }
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

    func drainDeferredCreatedWindows() async {
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
        recordNiriCreateFocusTrace(
            .init(
                kind: .candidateTracked(
                    token: candidate.token,
                    workspaceId: candidate.workspaceId
                )
            )
        )

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

        _ = controller.workspaceManager.addWindow(
            candidate.axRef,
            pid: candidate.token.pid,
            windowId: candidate.token.windowId,
            to: candidate.workspaceId,
            mode: candidate.mode,
            ruleEffects: candidate.ruleEffects,
            managedReplacementMetadata: candidate.replacementMetadata
        )

        var floatingTargetFrame: CGRect?
        if candidate.mode == .floating,
           let frame = frameProvider?(candidate.axRef)
            ?? fastFrameProvider?(candidate.axRef)
            ?? AXWindowService.framePreferFast(candidate.axRef)
            ?? (try? AXWindowService.frame(candidate.axRef))
        {
            if let entry = controller.workspaceManager.entry(for: candidate.token) {
                updateManagedReplacementFrame(frame, for: entry)
            }
            controller.workspaceManager.updateFloatingGeometry(
                frame: frame,
                for: candidate.token,
                referenceMonitor: controller.workspaceManager.monitor(for: candidate.workspaceId)
            )
            floatingTargetFrame = controller.workspaceManager.resolvedFloatingFrame(
                for: candidate.token,
                preferredMonitor: controller.workspaceManager.monitor(for: candidate.workspaceId)
            )
        }

        if let floatingTargetFrame,
           shouldApplyFloatingCreateFrameImmediately(for: candidate.workspaceId)
        {
            scheduleFloatingCreateFrameApplication(
                floatingTargetFrame,
                for: candidate
            )
        } else {
            scheduleAXContextWarmup(for: candidate.token.pid)
        }

        controller.layoutRefreshController.requestRelayout(
            reason: .axWindowCreated,
            affectedWorkspaceIds: [candidate.workspaceId]
        )
        scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(candidate.token.pid)])
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
        for candidate: PreparedCreate
    ) {
        guard let controller else { return }
        let windowId = Int(candidate.windowId)
        let canApplySynchronously = controller.axManager.hasContext(for: candidate.token.pid)
            || controller.axManager.usesFrameApplyOverrideForTests

        if canApplySynchronously {
            applyFloatingCreateFrame(targetFrame, for: candidate)
            if controller.axManager.recentFrameWriteFailure(for: windowId) == .contextUnavailable {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.warmAXContextIfNeeded(for: candidate.token.pid)
                    self.applyFloatingCreateFrame(targetFrame, for: candidate)
                }
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.warmAXContextIfNeeded(for: candidate.token.pid)
            self.applyFloatingCreateFrame(targetFrame, for: candidate)
            if self.controller?.axManager.recentFrameWriteFailure(for: windowId) == .contextUnavailable {
                await self.warmAXContextIfNeeded(for: candidate.token.pid)
                self.applyFloatingCreateFrame(targetFrame, for: candidate)
            }
        }
    }

    private func applyFloatingCreateFrame(
        _ targetFrame: CGRect,
        for candidate: PreparedCreate
    ) {
        guard let controller,
              controller.workspaceManager.entry(for: candidate.token) != nil,
              shouldApplyFloatingCreateFrameImmediately(for: candidate.workspaceId)
        else {
            return
        }

        let windowId = Int(candidate.windowId)
        controller.axManager.forceApplyNextFrame(for: windowId)
        controller.axManager.applyFramesParallel([(candidate.token.pid, windowId, targetFrame)])
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
        let removedHandle = entry?.handle

        if let removed = removedHandle {
            controller.focusBridge.discardPendingFocus(removed.id)
        }

        let canceledRequest = controller.focusBridge.cancelManagedRequest(
            matching: token,
            workspaceId: affectedWorkspaceId
        )
        _ = controller.workspaceManager.cancelManagedFocusRequest(
            matching: token,
            workspaceId: affectedWorkspaceId
        )
        if let canceledRequest {
            cancelActivationRetry(requestId: canceledRequest.requestId)
        }
        controller.clearKeyboardFocusTarget(
            matching: token,
            restoreCurrentBorder: false
        )

        if handleNativeFullscreenDestroy(token) {
            return
        }

        let shouldRecoverFocus = token == controller.workspaceManager.focusedToken
        let layoutType = affectedWorkspaceId
            .flatMap { controller.workspaceManager.descriptor(for: $0)?.name }
            .map { controller.settings.layoutType(for: $0) } ?? .defaultLayout

        if let entry,
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
            }
        }

        var oldFrames: [WindowToken: CGRect] = [:]
        var removedNodeId: NodeId?
        if let wsId = affectedWorkspaceId, layoutType != .dwindle, let engine = controller.niriEngine {
            oldFrames = engine.captureWindowFrames(in: wsId)
            removedNodeId = engine.findNode(for: token)?.id
        }

        _ = controller.workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
        controller.clearManualWindowOverride(for: token)
        _ = controller.renderKeyboardFocusBorder(policy: .direct)

        if let wsId = affectedWorkspaceId {
            controller.layoutRefreshController.requestWindowRemoval(
                workspaceId: wsId,
                layoutType: layoutType,
                removedNodeId: removedNodeId,
                niriOldFrames: oldFrames,
                shouldRecoverFocus: shouldRecoverFocus
            )
        }
        scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(token.pid)])
    }

    func handleAppActivation(
        pid: pid_t,
        source: ActivationEventSource = .workspaceDidActivateApplication,
        origin: ActivationCallOrigin = .external
    ) {
        guard let controller else { return }
        recordNiriCreateFocusTrace(
            .init(
                kind: .activationSourceObserved(
                    pid: pid,
                    source: source
                )
            )
        )
        guard controller.hasStartedServices else { return }

        let activeRequest = controller.focusBridge.activeManagedRequest

        if pid == getpid(), (controller.hasFrontmostOwnedWindow || controller.hasVisibleOwnedWindow) {
            if let activeRequest, activeRequest.token.pid == pid {
                _ = controller.focusBridge.cancelManagedRequest(requestId: activeRequest.requestId)
                cancelActivationRetry(requestId: activeRequest.requestId)
            }
            controller.clearKeyboardFocusTarget(pid: pid)
            _ = controller.workspaceManager.enterNonManagedFocus(
                appFullscreen: false,
                preserveFocusedToken: true
            )
            controller.borderManager.hideBorder()
            return
        }

        let axRef = resolveFocusedAXWindowRef(pid: pid)
        let observedToken = axRef.map { WindowToken(pid: pid, windowId: $0.windowId) }
        let requestDisposition = activationRequestDisposition(
            for: pid,
            token: observedToken,
            activeRequest: activeRequest
        )

        guard let axRef else {
            handleMissingFocusedWindow(
                pid: pid,
                source: source,
                origin: origin,
                requestDisposition: requestDisposition
            )
            return
        }
        let token = WindowToken(pid: pid, windowId: axRef.windowId)

        let appFullscreen = isFullscreenProvider?(axRef) ?? AXWindowService.isFullscreen(axRef)

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

            switch requestDisposition {
            case .matchesActiveRequest:
                break
            case let .conflictsWithPendingRequest(request):
                continueManagedFocusRequest(
                    request,
                    source: source,
                    origin: origin,
                    reason: .pendingFocusMismatch
                )
                return
            case .unrelatedNoRequest:
                guard source.isAuthoritative || isWorkspaceActive else { return }
            }

            handleManagedAppActivation(
                entry: entry,
                isWorkspaceActive: isWorkspaceActive,
                appFullscreen: appFullscreen,
                source: source,
                confirmRequest: true,
                origin: origin
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

            switch requestDisposition {
            case .matchesActiveRequest:
                break
            case let .conflictsWithPendingRequest(request):
                continueManagedFocusRequest(
                    request,
                    source: source,
                    origin: origin,
                    reason: .pendingFocusMismatch
                )
                return
            case .unrelatedNoRequest:
                guard source.isAuthoritative || isWorkspaceActive else { return }
            }

            handleManagedAppActivation(
                entry: restoredEntry,
                isWorkspaceActive: isWorkspaceActive,
                appFullscreen: appFullscreen,
                source: source,
                confirmRequest: true,
                origin: origin
            )
            return
        }

        switch requestDisposition {
        case let .matchesActiveRequest(request), let .conflictsWithPendingRequest(request):
            continueManagedFocusRequest(
                request,
                source: source,
                origin: origin,
                reason: .pendingFocusUnmanagedToken
            )
            return
        case .unrelatedNoRequest:
            let target = controller.keyboardFocusTarget(for: token, axRef: axRef)
            controller.focusBridge.setFocusedTarget(target)
            let fallbackFullscreen = appFullscreenForFallbackLifecyclePreservation(
                observedAppFullscreen: appFullscreen
            )
            _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: fallbackFullscreen)
            _ = controller.renderKeyboardFocusBorder(for: target, policy: .direct)
        }

        recordNiriCreateFocusTrace(
            .init(
                kind: .nonManagedFallbackEntered(
                    pid: pid,
                    source: source
                )
            )
        )
    }

    func handleManagedAppActivation(
        entry: WindowModel.Entry,
        isWorkspaceActive: Bool,
        appFullscreen: Bool,
        source: ActivationEventSource = .focusedWindowChanged,
        confirmRequest: Bool? = nil,
        origin: ActivationCallOrigin = .external
    ) {
        guard let controller else { return }
        if appFullscreen {
            suspendManagedWindowForNativeFullscreen(entry)
            return
        }

        _ = restoreManagedWindowFromNativeFullscreen(entry)
        let wsId = entry.workspaceId
        let monitorId = controller.workspaceManager.monitorId(for: wsId)
        let shouldActivateWorkspace = !isWorkspaceActive && !controller.isTransferringWindow
        let activeRequest = controller.focusBridge.activeManagedRequest(for: entry.pid)
        let shouldConfirmRequest = confirmRequest ?? (activeRequest?.token == entry.token || activeRequest == nil)
        let preservePendingSelection = !shouldConfirmRequest && activeRequest != nil

        if shouldConfirmRequest {
            _ = controller.workspaceManager.confirmManagedFocus(
                entry.token,
                in: wsId,
                onMonitor: monitorId,
                appFullscreen: appFullscreen,
                activateWorkspaceOnMonitor: shouldActivateWorkspace
            )
            if let confirmedRequest = controller.focusBridge.confirmManagedRequest(
                token: entry.token,
                source: source
            ) {
                cancelActivationRetry(requestId: confirmedRequest.requestId)
                recordNiriCreateFocusTrace(
                    .init(
                        kind: .focusConfirmed(
                            token: entry.token,
                            workspaceId: wsId,
                            source: source
                        )
                    )
                )
            }
        } else {
            _ = controller.workspaceManager.setManagedFocus(
                entry.token,
                in: wsId,
                onMonitor: monitorId
            )
        }

        let target = controller.keyboardFocusTarget(for: entry.token, axRef: entry.axRef)
        controller.focusBridge.setFocusedTarget(target)

        if let engine = controller.niriEngine,
           let node = engine.findNode(for: entry.handle),
           let _ = controller.workspaceManager.monitor(for: wsId)
        {
            if !preservePendingSelection {
                var state = controller.workspaceManager.niriViewportState(for: wsId)
                controller.niriLayoutHandler.activateNode(
                    node, in: wsId, state: &state,
                    options: .init(layoutRefresh: isWorkspaceActive, axFocus: false)
                )
                _ = controller.workspaceManager.applySessionPatch(
                    .init(
                        workspaceId: wsId,
                        viewportState: state,
                        rememberedFocusToken: nil
                    )
                )
            }

            _ = controller.renderKeyboardFocusBorder(
                for: target,
                preferredFrame: node.renderedFrame ?? node.frame,
                policy: .direct
            )
        } else {
            _ = controller.renderKeyboardFocusBorder(
                for: target,
                policy: .direct
            )
        }

        if !shouldConfirmRequest,
           let activeRequest,
           activeRequest.token != entry.token
        {
            continueManagedFocusRequest(
                activeRequest,
                source: source,
                origin: origin,
                reason: .pendingFocusMismatch
            )
        }

        controller.niriLayoutHandler.updateTabbedColumnOverlays()
        if shouldActivateWorkspace, shouldConfirmRequest {
            controller.syncMonitorsToNiriEngine()
            controller.layoutRefreshController.commitWorkspaceTransition(
                reason: .appActivationTransition
            )
        }
        if shouldConfirmRequest,
           controller.moveMouseToFocusedWindowEnabled,
           controller.workspaceManager.focusedToken == entry.token,
           !controller.workspaceManager.isNonManagedFocusActive
        {
            controller.moveMouseToWindow(entry.token)
        }
    }

    func focusedWindowToken(for pid: pid_t) -> WindowToken? {
        guard let axRef = resolveFocusedAXWindowRef(pid: pid) else { return nil }
        return WindowToken(pid: pid, windowId: axRef.windowId)
    }

    @discardableResult
    private func suspendManagedWindowForNativeFullscreen(_ entry: WindowModel.Entry) -> Bool {
        guard let controller else { return false }
        cancelNativeFullscreenLifecycleTasks(containing: entry.token)
        let changed = controller.workspaceManager.markNativeFullscreenSuspended(entry.token)
        controller.borderManager.hideBorder()
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
        return controller.workspaceManager.restoreNativeFullscreenRecord(for: entry.token) != nil || hadRecord
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
        guard let record = controller.workspaceManager.nativeFullscreenUnavailableCandidate(
            for: token.pid,
            activeWorkspaceId: workspaceId
        ) else {
            return false
        }
        if record.currentToken == token {
            guard controller.workspaceManager.entry(for: token) != nil else {
                return false
            }
            cancelNativeFullscreenLifecycleTasks(for: record.originalToken)
            if appFullscreen {
                _ = controller.workspaceManager.markNativeFullscreenSuspended(token)
            } else {
                _ = controller.workspaceManager.restoreNativeFullscreenRecord(for: token)
            }
            return true
        }
        guard rekeyManagedWindowIdentity(from: record.currentToken, to: token, windowId: windowId, axRef: axRef) != nil else {
            return false
        }

        cancelNativeFullscreenLifecycleTasks(for: record.originalToken)

        if appFullscreen {
            _ = controller.workspaceManager.markNativeFullscreenSuspended(token)
        } else {
            _ = controller.workspaceManager.restoreNativeFullscreenRecord(for: token)
        }

        return true
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
        AXWindowService.invalidateCachedTitles(windowIds: [UInt32(oldToken.windowId), windowId])
        subscribeToWindows([windowId])
        controller.requestWorkspaceBarRefresh()
        controller.niriLayoutHandler.updateTabbedColumnOverlays()
        refreshBorderAfterManagedRekey(entry: entry)

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

        controller.borderManager.hideBorder()
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
            controller.borderManager.hideBorder()
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
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appUnhidden)
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

        let bundleId = resolveBundleId(token.pid)
        let windowInfo = resolveWindowInfo(windowId)
        let facts = managedReplacementFacts(
            for: entry.axRef,
            pid: token.pid,
            bundleId: bundleId,
            windowInfo: windowInfo
        )

        let liveMetadata = makeManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: entry.workspaceId,
            mode: entry.mode,
            facts: facts
        )
        let replacementMetadata = if let cachedMetadata = entry.managedReplacementMetadata {
            cachedMetadata.mergingNonNilValues(from: liveMetadata)
        } else {
            liveMetadata
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
        let resolvedToken = resolveWindowToken(windowId)
            ?? resolveTrackedToken(windowId)
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
        guard managedReplacementCorrelationPolicy(for: candidate.bundleId) != nil else {
            return false
        }

        let key = ManagedReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        if pendingManagedReplacementBursts[key] != nil {
            return true
        }

        return hasTrackedSiblingEntry(
            for: candidate.token.pid,
            in: candidate.workspaceId,
            excluding: candidate.token
        )
    }

    private func shouldDelayManagedReplacementDestroy(_ candidate: PreparedDestroy) -> Bool {
        managedReplacementCorrelationPolicy(for: candidate.bundleId) != nil
    }

    private func enqueueManagedReplacementCreate(_ candidate: PreparedCreate) {
        let key = ManagedReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        var burst = pendingManagedReplacementBursts[key] ?? PendingManagedReplacementBurst()
        let pendingCreate = PendingManagedCreate(sequence: nextManagedReplacementSequence(), candidate: candidate)
        burst.append(create: pendingCreate)
        pendingManagedReplacementBursts[key] = burst
        scheduleManagedReplacementFlush(for: key)
    }

    private func enqueueManagedReplacementDestroy(_ candidate: PreparedDestroy) {
        let key = ManagedReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        var burst = pendingManagedReplacementBursts[key] ?? PendingManagedReplacementBurst()
        let pendingDestroy = PendingManagedDestroy(sequence: nextManagedReplacementSequence(), candidate: candidate)
        burst.append(destroy: pendingDestroy)
        pendingManagedReplacementBursts[key] = burst
        scheduleManagedReplacementFlush(for: key)
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

    private func managedReplacementFacts(
        for axRef: AXWindowRef,
        pid: pid_t,
        bundleId: String?,
        windowInfo: WindowServerInfo?
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
                includeTitle: true
            ),
            sizeConstraints: nil,
            windowServer: windowInfo
        )
    }

    private func hasTrackedSiblingEntry(
        for pid: pid_t,
        in workspaceId: WorkspaceDescriptor.ID,
        excluding token: WindowToken
    ) -> Bool {
        guard let controller else { return false }
        return controller.workspaceManager.entries(forPid: pid).contains {
            $0.workspaceId == workspaceId && $0.token != token
        }
    }

    private func managedReplacementCorrelationPolicy(
        for bundleId: String?
    ) -> ManagedReplacementCorrelationPolicy? {
        guard let bundleId = bundleId?.lowercased() else { return nil }
        if bundleId == Self.ghosttyBundleId {
            return .ghostty
        }
        if Self.replacementCorrelationBundleIds.contains(bundleId) {
            return .strictMetadata
        }
        return nil
    }

    private func managedReplacementMetadataMatches(
        old: ManagedReplacementMetadata,
        new: ManagedReplacementMetadata
    ) -> Bool {
        guard let oldBundleId = old.bundleId?.lowercased(),
              let newBundleId = new.bundleId?.lowercased(),
              oldBundleId == newBundleId,
              let policy = managedReplacementCorrelationPolicy(for: oldBundleId),
              policy == managedReplacementCorrelationPolicy(for: newBundleId),
              old.workspaceId == new.workspaceId,
              old.role == new.role,
              old.subrole == new.subrole
        else {
            return false
        }

        switch policy {
        case .ghostty:
            return ghosttyManagedReplacementMetadataMatches(old: old, new: new)

        case .strictMetadata:
            return strictManagedReplacementMetadataMatches(old: old, new: new)
        }
    }

    private func ghosttyManagedReplacementMetadataMatches(
        old: ManagedReplacementMetadata,
        new: ManagedReplacementMetadata
    ) -> Bool {
        if let oldLevel = old.windowLevel,
           let newLevel = new.windowLevel,
           oldLevel != newLevel
        {
            return false
        }

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

    private func shouldApplySecondaryGhosttyDestroyHold(
        to burst: PendingManagedReplacementBurst
    ) -> Bool {
        guard burst.ghosttyDestroyHoldCount == 0,
              burst.creates.isEmpty,
              !burst.destroys.isEmpty
        else {
            return false
        }

        return burst.destroys.allSatisfy {
            managedReplacementCorrelationPolicy(for: $0.candidate.bundleId) == .ghostty
        }
    }

    private func strictManagedReplacementMetadataMatches(
        old: ManagedReplacementMetadata,
        new: ManagedReplacementMetadata
    ) -> Bool {
        guard old.mode == new.mode else {
            return false
        }

        let oldTitle = normalizedTitleIdentity(old.title)
        let newTitle = normalizedTitleIdentity(new.title)
        if let oldTitle, let newTitle {
            return oldTitle == newTitle
        }

        guard oldTitle == nil,
              newTitle == nil,
              old.windowLevel == new.windowLevel,
              old.parentWindowId == new.parentWindowId,
              framesAreCloseForManagedReplacement(old.frame, new.frame)
        else {
            return false
        }

        return true
    }

    private func normalizedTitleIdentity(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else {
            return nil
        }
        return title
    }

    private func framesAreCloseForManagedReplacement(_ lhs: CGRect?, _ rhs: CGRect?) -> Bool {
        guard let lhs, let rhs else { return false }

        return abs(lhs.midX - rhs.midX) <= 96
            && abs(lhs.midY - rhs.midY) <= 96
            && abs(lhs.width - rhs.width) <= 64
            && abs(lhs.height - rhs.height) <= 64
    }

    private func refreshBorderAfterManagedRekey(entry: WindowModel.Entry) {
        guard let controller else { return }
        guard controller.currentKeyboardFocusTargetForRendering()?.token == entry.token else { return }

        let preferredFrame = controller.niriEngine?.findNode(for: entry.token).flatMap { $0.renderedFrame ?? $0.frame }
            ?? frameProvider?(entry.axRef)
        _ = controller.renderKeyboardFocusBorder(
            preferredFrame: preferredFrame,
            policy: .coordinated
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

    private func scheduleManagedReplacementFlush(for key: ManagedReplacementKey) {
        pendingManagedReplacementTasks.removeValue(forKey: key)?.cancel()
        pendingManagedReplacementTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.managedReplacementGraceDelay)
            guard !Task.isCancelled else { return }
            self?.flushManagedReplacementBurst(for: key)
        }
    }

    private func flushManagedReplacementBurst(for key: ManagedReplacementKey) {
        pendingManagedReplacementTasks.removeValue(forKey: key)?.cancel()
        guard var burst = pendingManagedReplacementBursts.removeValue(forKey: key) else { return }

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

        if shouldApplySecondaryGhosttyDestroyHold(to: burst) {
            burst.ghosttyDestroyHoldCount = 1
            pendingManagedReplacementBursts[key] = burst
            scheduleManagedReplacementFlush(for: key)
            return
        }

        replayManagedReplacementEvents(burst.orderedEvents)
    }

    private func nextManagedReplacementSequence() -> UInt64 {
        defer { nextManagedReplacementEventSequence += 1 }
        return nextManagedReplacementEventSequence
    }

    private func updateManagedReplacementFrame(_ frame: CGRect, for entry: WindowModel.Entry) {
        entry.managedReplacementMetadata?.frame = frame
    }

    private func updateManagedReplacementTitle(windowId: UInt32, token: WindowToken) {
        guard let controller,
              let entry = controller.workspaceManager.entry(for: token),
              let title = resolveWindowInfo(windowId)?.title ?? AXWindowService.titlePreferFast(windowId: windowId)
        else {
            return
        }
        entry.managedReplacementMetadata?.title = title
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
        recordNiriCreateFocusTrace(
            .init(
                kind: .createRetryScheduled(
                    windowId: windowId,
                    pid: pid,
                    attempt: attempt
                )
            )
        )
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

    private func resetCreatedWindowRetryState() {
        for (_, task) in pendingCreatedWindowRetryTasks {
            task.cancel()
        }
        pendingCreatedWindowRetryTasks.removeAll()
        createdWindowRetryCountById.removeAll()
    }

    private func handleMissingFocusedWindow(
        pid: pid_t,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        requestDisposition: ActivationRequestDisposition
    ) {
        guard let controller else { return }

        switch requestDisposition {
        case let .matchesActiveRequest(request), let .conflictsWithPendingRequest(request):
            continueManagedFocusRequest(
                request,
                source: source,
                origin: origin,
                reason: .missingFocusedWindow
            )
            return
        case .unrelatedNoRequest:
            break
        }

        cancelActivationRetry()
        controller.focusBridge.setFocusedTarget(nil)
        let fallbackFullscreen = appFullscreenForFallbackLifecyclePreservation(
            observedAppFullscreen: false
        )
        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: fallbackFullscreen)
        recordNiriCreateFocusTrace(
            .init(
                kind: .nonManagedFallbackEntered(
                    pid: pid,
                    source: source
                )
            )
        )
        controller.borderManager.hideBorder()
    }

    private func appFullscreenForFallbackLifecyclePreservation(
        observedAppFullscreen: Bool
    ) -> Bool {
        guard let controller else { return observedAppFullscreen }

        let hasLifecycleContext = controller.workspaceManager.hasNativeFullscreenLifecycleContext
        return observedAppFullscreen || hasLifecycleContext
    }

    private func activationRequestDisposition(
        for pid: pid_t,
        token: WindowToken?,
        activeRequest: ManagedFocusRequest?
    ) -> ActivationRequestDisposition {
        guard let activeRequest else { return .unrelatedNoRequest }
        guard activeRequest.token.pid == pid else {
            return .conflictsWithPendingRequest(activeRequest)
        }
        guard let token else {
            return .matchesActiveRequest(activeRequest)
        }
        return activeRequest.token == token
            ? .matchesActiveRequest(activeRequest)
            : .conflictsWithPendingRequest(activeRequest)
    }

    private func continueManagedFocusRequest(
        _ request: ManagedFocusRequest,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        reason: ActivationRetryReason
    ) {
        if scheduleActivationRetryIfNeeded(
            request: request,
            source: source,
            origin: origin,
            reason: reason
        ) {
            return
        }
        guard origin != .probe else {
            return
        }
        handleActivationRetryExhausted(
            request: request,
            source: source,
            origin: origin
        )
    }

    private func scheduleActivationRetryIfNeeded(
        request: ManagedFocusRequest,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        reason: ActivationRetryReason
    ) -> Bool {
        guard let controller,
              let updatedRequest = controller.focusBridge.recordRetry(
                  for: request.token,
                  source: source,
                  retryLimit: Self.activationRetryLimit
              )
        else {
            return false
        }

        cancelActivationRetry()
        pendingActivationRetryRequestId = updatedRequest.requestId
        recordNiriCreateFocusTrace(
            .init(
                kind: .activationDeferred(
                    requestId: updatedRequest.requestId,
                    token: updatedRequest.token,
                    source: source,
                    reason: reason,
                    attempt: updatedRequest.retryCount
                )
            )
        )
        let retryOrigin: ActivationCallOrigin = origin == .probe ? .probe : .retry
        pendingActivationRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.stabilizationRetryDelay)
            guard !Task.isCancelled, let self else { return }
            let requestId = updatedRequest.requestId
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
        return true
    }

    private func handleActivationRetryExhausted(
        request: ManagedFocusRequest,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) {
        guard let controller else { return }

        cancelActivationRetry(requestId: request.requestId)
        _ = controller.focusBridge.cancelManagedRequest(requestId: request.requestId)
        _ = controller.workspaceManager.cancelManagedFocusRequest(
            matching: request.token,
            workspaceId: request.workspaceId
        )

        if let target = controller.currentKeyboardFocusTargetForRendering(),
           controller.renderKeyboardFocusBorder(
               for: target,
               preferredFrame: controller.preferredKeyboardFocusFrame(for: target.token),
               policy: .direct
           )
        {
            recordNiriCreateFocusTrace(
                .init(
                    kind: .borderReapplied(
                        token: target.token,
                        phase: .retryExhaustedFallback
                    )
                )
            )
        } else {
            recordNiriCreateFocusTrace(
                .init(
                    kind: .nonManagedFallbackEntered(
                        pid: request.token.pid,
                        source: source
                    )
                )
            )
            controller.borderManager.hideBorder()
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
        if let token = resolveWindowToken(windowId) {
            return token
        }
        guard let controller else { return nil }
        let matches = controller.workspaceManager.allEntries().filter { $0.windowId == Int(windowId) }
        guard matches.count == 1 else { return nil }
        return matches[0].token
    }

    private func resolveAXWindowRef(windowId: UInt32, pid: pid_t) -> AXWindowRef? {
        axWindowRefProvider?(windowId, pid) ?? AXWindowService.axWindowRef(for: windowId, pid: pid)
    }

    private func subscribeToWindows(_ windowIds: [UInt32]) {
        if let windowSubscriptionHandler {
            windowSubscriptionHandler(windowIds)
            return
        }
        CGSEventObserver.shared.subscribeToWindows(windowIds)
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
