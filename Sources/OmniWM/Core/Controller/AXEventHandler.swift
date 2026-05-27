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

private enum NativeFullscreenReplacementRestoreResult {
    case notRestored
    case restored(scheduledRelayout: Bool)

    var restored: Bool {
        switch self {
        case .notRestored:
            false
        case .restored:
            true
        }
    }
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
        case createPlacementResolved(
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID,
            pendingWorkspaceId: WorkspaceDescriptor.ID?,
            pendingMonitorId: Monitor.ID?,
            focusedWorkspaceId: WorkspaceDescriptor.ID?,
            focusedMonitorId: Monitor.ID?,
            nativeSpaceMonitorId: Monitor.ID?,
            frameMonitorId: Monitor.ID?,
            interactionMonitorId: Monitor.ID?
        )
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

struct WindowCreatePlacementContext: Equatable {
    let nativeSpaceMonitorId: Monitor.ID?
    let pendingFocusedWorkspaceId: WorkspaceDescriptor.ID?
    let pendingFocusedMonitorId: Monitor.ID?
    let focusedWorkspaceId: WorkspaceDescriptor.ID?
    let focusedMonitorId: Monitor.ID?
    let interactionMonitorId: Monitor.ID?
    let createdAt: Date
}

extension NiriCreateFocusTraceEvent: CustomStringConvertible {
    var description: String {
        switch kind {
        case let .createSeen(windowId):
            "create_seen window=\(windowId)"
        case let .createRetryScheduled(windowId, pid, attempt):
            "create_retry_scheduled window=\(windowId) pid=\(pid) attempt=\(attempt)"
        case let .createPlacementResolved(
            token,
            workspaceId,
            pendingWorkspaceId,
            pendingMonitorId,
            focusedWorkspaceId,
            focusedMonitorId,
            nativeSpaceMonitorId,
            frameMonitorId,
            interactionMonitorId
        ):
            "create_placement_resolved token=\(token) workspace=\(workspaceId.uuidString) pending_workspace=\(pendingWorkspaceId?.uuidString ?? "nil") pending_monitor=\(String(describing: pendingMonitorId)) focused_workspace=\(focusedWorkspaceId?.uuidString ?? "nil") focused_monitor=\(String(describing: focusedMonitorId)) native_monitor=\(String(describing: nativeSpaceMonitorId)) frame_monitor=\(String(describing: frameMonitorId)) interaction_monitor=\(String(describing: interactionMonitorId))"
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
        var geometryRelayoutsSuppressedForOwnFrameWrites = 0
        var scopedGeometryRelayoutRequests = 0
    }

    struct ManagedReplacementTraceEvent: Equatable {
        enum Kind: Equatable {
            case enqueued(
                policy: String,
                createCount: Int,
                destroyCount: Int,
                holdCount: Int,
                deadlineReset: Bool
            )
            case flushed(
                policy: String,
                createCount: Int,
                destroyCount: Int,
                holdCount: Int,
                elapsedMillis: Int
            )
            case matched(policy: String, elapsedMillis: Int)
        }

        let timestamp: TimeInterval
        let pid: pid_t
        let workspaceId: WorkspaceDescriptor.ID
        let kind: Kind
    }

    private struct PreparedCreate {
        let windowId: UInt32
        let token: WindowToken
        let axRef: AXWindowRef
        let ruleEffects: ManagedWindowRuleEffects
        let replacementMetadata: ManagedReplacementMetadata
        let hasStructuralReplacementWorkspaceMatch: Bool
        let requiresPostCreateLifecycleVerification: Bool

        var bundleId: String? {
            replacementMetadata.bundleId
        }

        var workspaceId: WorkspaceDescriptor.ID {
            replacementMetadata.workspaceId
        }

        var mode: TrackedWindowMode {
            replacementMetadata.mode
        }
    }

    private struct PreparedDestroy {
        let token: WindowToken
        let replacementMetadata: ManagedReplacementMetadata

        var bundleId: String? {
            replacementMetadata.bundleId
        }

        var workspaceId: WorkspaceDescriptor.ID {
            replacementMetadata.workspaceId
        }

        var mode: TrackedWindowMode {
            replacementMetadata.mode
        }
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
            let events = creates.map(PendingManagedReplacementEvent.create) + destroys
                .map(PendingManagedReplacementEvent.destroy)
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

    private struct StructuralReplacementMatch {
        let token: WindowToken
        let workspaceId: WorkspaceDescriptor.ID
    }

    private static let managedReplacementGraceDelay: Duration = .milliseconds(150)
    private static let nativeFullscreenFollowupDelay: Duration = .seconds(1)
    private static let nativeFullscreenStaleCleanupDelay: Duration = .seconds(
        Int64(WorkspaceManager.staleUnavailableNativeFullscreenTimeout)
    )
    private static let stabilizationRetryDelay: Duration = .milliseconds(100)
    private static let postCreateLifecycleVerificationDelay: Duration = .milliseconds(75)
    private static let createdWindowRetryLimit = 5
    private static let createPlacementContextTTL: TimeInterval = 15
    private static let activationRetryLimit = 5
    private static let createFocusTraceLimit = 128
    private static let managedReplacementTraceLimit = 128
    private static let createFocusTraceLoggingEnabled =
        ProcessInfo.processInfo.environment["OMNIWM_DEBUG_NIRI_CREATE_FOCUS"] == "1"
    private static let managedReplacementTraceLoggingEnabled =
        ProcessInfo.processInfo.environment["OMNIWM_DEBUG_MANAGED_REPLACEMENT"] == "1"

    weak var controller: WMController?
    private var deferredCreatedWindowIds: Set<UInt32> = []
    private var deferredCreatedWindowOrder: [UInt32] = []
    private var createPlacementContextsByWindowId: [UInt32: WindowCreatePlacementContext] = [:]
    private var pendingManagedReplacementBursts: [ManagedReplacementKey: PendingManagedReplacementBurst] = [:]
    private var pendingManagedReplacementTasks: [ManagedReplacementKey: Task<Void, Never>] = [:]
    private var pendingNativeFullscreenFollowupTasks: [WindowToken: Task<Void, Never>] = [:]
    private var pendingNativeFullscreenStaleCleanupTasks: [WindowToken: Task<Void, Never>] = [:]
    private var pendingWindowRuleReevaluationTask: Task<Void, Never>?
    private var pendingWindowRuleReevaluationTargets: Set<WindowRuleReevaluationTarget> = []
    private var pendingWindowStabilizationTasks: [WindowToken: Task<Void, Never>] = [:]
    private var pendingPostCreateLifecycleVerificationTasks: [WindowToken: Task<Void, Never>] = [:]
    private var pendingCreatedWindowRetryTasks: [UInt32: Task<Void, Never>] = [:]
    private var createdWindowRetryCountById: [UInt32: Int] = [:]
    private var pendingActivationRetryTask: Task<Void, Never>?
    private var pendingActivationRetryRequestId: UInt64?
    private var createFocusTrace: [NiriCreateFocusTraceEvent] = []
    private var managedReplacementTrace: [ManagedReplacementTraceEvent] = []
    private var nextManagedReplacementEventSequence: UInt64 = 0
    var windowInfoProvider: ((UInt32) -> WindowServerInfo?)?
    var windowInfoProviderIsAuthoritativeForTests = false
    var axWindowRefProvider: ((UInt32, pid_t) -> AXWindowRef?)?
    var bundleIdProvider: ((pid_t) -> String?)?
    var windowSubscriptionHandler: (([UInt32]) -> Void)?
    var focusedWindowValueProvider: ((pid_t) -> CFTypeRef?)?
    var focusedWindowRefProvider: ((pid_t) -> AXWindowRef?)?
    var windowFactsProvider: ((AXWindowRef, pid_t) -> WindowRuleFacts?)?
    var frameProvider: ((AXWindowRef) -> CGRect?)?
    var fastFrameProvider: ((AXWindowRef) -> CGRect?)?
    var isFullscreenProvider: ((AXWindowRef) -> Bool)?
    var spaceDisplayResolver: ((UInt64, [Monitor]) -> CGDirectDisplayID?)?
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
        resetCreatePlacementContextState()
        resetManagedReplacementState()
        resetNativeFullscreenReplacementState()
        resetWindowStabilizationState()
        resetPostCreateLifecycleVerificationState()
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
        case let .created(windowId, spaceId):
            handleCGSWindowCreated(windowId: windowId, spaceId: spaceId)

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

    private func handleCGSWindowCreated(windowId: UInt32, spaceId: UInt64) {
        captureCreatePlacementContext(windowId: windowId, spaceId: spaceId)
        recordNiriCreateFocusTrace(.init(kind: .createSeen(windowId: windowId)))
        processCreatedWindow(windowId: windowId)
    }

    private func processCreatedWindow(windowId: UInt32) {
        guard let controller else { return }
        if controller.isDiscoveryInProgress {
            deferCreatedWindow(windowId)
            return
        }
        if controller.isOwnedWindow(windowNumber: Int(windowId)) {
            cancelCreatedWindowRetry(windowId: windowId)
            discardCreatePlacementContext(windowId: windowId)
            removeDeferredCreatedWindow(windowId)
            return
        }

        let windowInfo = resolveWindowInfo(windowId)
        guard let candidate = prepareCreateCandidate(
            windowId: windowId,
            windowInfo: windowInfo,
            createPlacementContext: createPlacementContextsByWindowId[windowId]
        ) else {
            if let windowInfo {
                _ = scheduleCreatedWindowRetryIfNeeded(
                    windowId: windowId,
                    pid: pid_t(windowInfo.pid)
                )
                scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(pid_t(windowInfo.pid))])
            } else {
                _ = scheduleCreatedWindowInfoRetryIfNeeded(windowId: windowId)
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
        resetPostCreateLifecycleVerificationState()
        resetCreatedWindowRetryState()
        resetCreatePlacementContextState()
        resetActivationRetryState()
        controller?.focusBridge.reset()
        createFocusTrace.removeAll(keepingCapacity: true)
        managedReplacementTrace.removeAll(keepingCapacity: true)
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

    func managedReplacementTraceSnapshotForTests() -> [ManagedReplacementTraceEvent] {
        managedReplacementTrace
    }

    func pendingCreatePlacementContext(for windowId: Int) -> WindowCreatePlacementContext? {
        guard let windowId = UInt32(exactly: windowId) else { return nil }
        pruneExpiredCreatePlacementContexts()
        return createPlacementContextsByWindowId[windowId]
    }

    func discardCreatePlacementContext(for windowId: Int) {
        guard let windowId = UInt32(exactly: windowId) else { return }
        discardCreatePlacementContext(windowId: windowId)
    }

    func structuralReplacementWorkspaceIdForCreate(
        token: WindowToken,
        bundleId: String?,
        mode: TrackedWindowMode,
        facts: WindowRuleFacts
    ) -> WorkspaceDescriptor.ID? {
        structuralReplacementMatch(
            token: token,
            bundleId: bundleId,
            mode: mode,
            facts: facts
        )?.workspaceId
    }

    @discardableResult
    func rekeyStructuralManagedReplacementIfNeeded(
        token: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef,
        bundleId: String?,
        mode: TrackedWindowMode,
        facts: WindowRuleFacts
    ) -> Bool {
        guard let match = structuralReplacementMatch(
            token: token,
            bundleId: bundleId,
            mode: mode,
            facts: facts
        ) else {
            return false
        }

        let metadata = makeManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: match.workspaceId,
            mode: mode,
            facts: facts
        )
        guard rekeyManagedWindowIdentity(
            from: match.token,
            to: token,
            windowId: windowId,
            axRef: axRef,
            managedReplacementMetadata: metadata
        ) != nil else {
            return false
        }

        discardCreatePlacementContext(windowId: windowId)
        return true
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

    private func managedReplacementCurrentUptime() -> TimeInterval {
        managedReplacementTimeSourceForTests?() ?? ProcessInfo.processInfo.systemUptime
    }

    private func managedReplacementPolicyName(_ policy: ManagedReplacementCorrelationPolicy) -> String {
        switch policy {
        case .structural:
            "structural"
        }
    }

    private func recordManagedReplacementTrace(
        key: ManagedReplacementKey,
        kind: ManagedReplacementTraceEvent.Kind
    ) {
        let event = ManagedReplacementTraceEvent(
            timestamp: managedReplacementCurrentUptime(),
            pid: key.pid,
            workspaceId: key.workspaceId,
            kind: kind
        )
        if managedReplacementTrace.count == Self.managedReplacementTraceLimit {
            managedReplacementTrace.removeFirst()
        }
        managedReplacementTrace.append(event)

        if Self.managedReplacementTraceLoggingEnabled {
            fputs(
                "[ManagedReplacement] pid=\(key.pid) workspace=\(key.workspaceId.uuidString) kind=\(String(describing: kind))\n",
                stderr
            )
        }
    }

    private func handleFrameChanged(windowId: UInt32) {
        guard let controller else { return }
        let windowServerToken = resolveWindowToken(windowId)
        let resolvedToken = resolveTrackedToken(
            windowId,
            resolvedWindowToken: windowServerToken
        )
        let focusedObservedFrame = updateFocusedBorderForFrameChange(
            resolvedToken: windowServerToken
        )
        guard let token = resolvedToken else { return }
        guard let entry = controller.workspaceManager.entry(for: token) else { return }

        guard isWindowDisplayable(token: token) else {
            return
        }

        if entry.mode == .floating {
            if let frame = focusedObservedFrame ?? observedFrame(for: entry) {
                controller.workspaceManager.updateFloatingGeometry(frame: frame, for: token)
            }
            return
        }

        if controller.isInteractiveGestureActive {
            debugCounters.geometryRelayoutsSuppressedDuringGesture += 1
            return
        }

        if controller.niriLayoutHandler.hasScrollAnimation(for: entry.workspaceId) {
            debugCounters.geometryRelayoutsSuppressedDuringGesture += 1
            return
        }

        if shouldSuppressFrameChangedRelayout(
            for: entry,
            observedFrame: focusedObservedFrame
        ) {
            return
        }

        let suppressionObservedFrame = focusedObservedFrame
            ?? (controller.axManager.lastAppliedFrame(for: entry.windowId) == nil ? nil : observedFrame(for: entry))
        if suppressionObservedFrame != focusedObservedFrame,
           shouldSuppressFrameChangedRelayout(
               for: entry,
               observedFrame: suppressionObservedFrame
           )
        {
            return
        }

        debugCounters.geometryRelayoutRequests += 1
        debugCounters.scopedGeometryRelayoutRequests += 1
        controller.layoutRefreshController.requestRelayout(
            reason: .axWindowChanged,
            affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    private func shouldSuppressFrameChangedRelayout(
        for entry: WindowModel.Entry,
        observedFrame: CGRect?
    ) -> Bool {
        guard let controller else { return false }
        if controller.axManager.shouldSuppressFrameChangeRelayout(
            for: entry.windowId,
            observedFrame: observedFrame
        ) {
            debugCounters.geometryRelayoutsSuppressedForOwnFrameWrites += 1
            return true
        }
        return false
    }

    private func updateFocusedBorderForFrameChange(resolvedToken: WindowToken?) -> CGRect? {
        guard let controller else { return nil }
        guard let target = controller.currentKeyboardFocusTargetForRendering(),
              resolvedToken == target.token
        else { return nil }

        if let entry = controller.workspaceManager.entry(for: target.token) {
            let pendingFrame = controller.axManager.pendingFrameWrite(for: entry.windowId)

            if let pendingFrame {
                _ = controller.focusBorderController.updateFrameHint(
                    for: target.token,
                    frame: pendingFrame
                )
                return nil
            }

            if let frame = observedFrame(for: entry) {
                updateManagedReplacementFrame(frame, for: entry)
                _ = controller.focusBorderController.updateFrameHint(
                    for: target.token,
                    frame: frame,
                    source: .observed
                )
                return frame
            }

            return nil
        }

        if let frame = observedFrame(for: target.axRef) {
            _ = controller.focusBorderController.updateFrameHint(
                for: target.token,
                frame: frame,
                source: .observed
            )
            return frame
        }

        return nil
    }

    private func observedFrame(for entry: WindowModel.Entry) -> CGRect? {
        observedFrame(for: entry.axRef)
    }

    private func observedFrame(for axRef: AXWindowRef) -> CGRect? {
        frameProvider?(axRef)
            ?? fastFrameProvider?(axRef)
            ?? AXWindowService.framePreferFast(axRef)
            ?? (try? AXWindowService.frame(axRef))
    }

    private func handleCGSWindowDestroyed(windowId: UInt32) {
        AXWindowService.invalidateCachedTitle(windowId: windowId)
        cancelCreatedWindowRetry(windowId: windowId)
        discardCreatePlacementContext(windowId: windowId)
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
            if controller.isOwnedWindow(windowNumber: Int(windowId)) {
                cancelCreatedWindowRetry(windowId: windowId)
                discardCreatePlacementContext(windowId: windowId)
                continue
            }
            guard let windowInfo = resolveWindowInfo(windowId) else {
                _ = scheduleCreatedWindowInfoRetryIfNeeded(windowId: windowId)
                continue
            }
            let token = WindowToken(pid: pid_t(windowInfo.pid), windowId: Int(windowId))
            if controller.workspaceManager.entry(for: token) != nil {
                discardCreatePlacementContext(windowId: windowId)
                continue
            }
            guard let candidate = prepareCreateCandidate(
                windowId: windowId,
                windowInfo: windowInfo,
                createPlacementContext: createPlacementContextsByWindowId[windowId]
            ) else {
                _ = scheduleCreatedWindowRetryIfNeeded(
                    windowId: windowId,
                    pid: pid_t(windowInfo.pid)
                )
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
        discardCreatePlacementContext(windowId: candidate.windowId)
        recordNiriCreateFocusTrace(
            .init(
                kind: .candidateTracked(
                    token: candidate.token,
                    workspaceId: candidate.workspaceId
                )
            )
        )

        let appFullscreen = isFullscreenProvider?(candidate.axRef) ?? AXWindowService.isFullscreen(candidate.axRef)
        let nativeFullscreenRestore = restoreNativeFullscreenReplacement(
            token: candidate.token,
            windowId: candidate.windowId,
            axRef: candidate.axRef,
            workspaceId: candidate.workspaceId,
            appFullscreen: appFullscreen
        )
        if nativeFullscreenRestore.restored {
            if case let .restored(scheduledRelayout) = nativeFullscreenRestore,
               !scheduledRelayout
            {
                controller.layoutRefreshController.requestRelayout(reason: .axWindowCreated)
            }
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
        if trackedEntry.mode == .floating {
            controller.windowActionHandler.raiseFloatingWindow(trackedToken)
        }
        if candidate.requiresPostCreateLifecycleVerification {
            schedulePostCreateLifecycleVerification(for: trackedToken)
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

    private func schedulePostCreateLifecycleVerification(for token: WindowToken) {
        pendingPostCreateLifecycleVerificationTasks[token]?.cancel()
        let task = Task { @MainActor [weak self] in
            defer { self?.pendingPostCreateLifecycleVerificationTasks[token] = nil }
            try? await Task.sleep(for: Self.postCreateLifecycleVerificationDelay)
            guard !Task.isCancelled,
                  let self,
                  let controller = self.controller,
                  controller.workspaceManager.entry(for: token) != nil,
                  let windowId = UInt32(exactly: token.windowId),
                  self.resolveWindowInfo(windowId) == nil
            else {
                return
            }
            await self.warmAXContextIfNeeded(for: token.pid)
            guard !Task.isCancelled,
                  controller.workspaceManager.entry(for: token) != nil,
                  self.resolveWindowInfo(windowId) == nil
            else {
                return
            }
            AXWindowService.invalidateCachedTitle(windowId: windowId)
            self.cancelWindowStabilizationRetry(for: token)
            self.handleRemoved(token: token)
        }
        pendingPostCreateLifecycleVerificationTasks[token] = task
    }

    private func cancelPostCreateLifecycleVerification(for token: WindowToken) {
        pendingPostCreateLifecycleVerificationTasks[token]?.cancel()
        pendingPostCreateLifecycleVerificationTasks[token] = nil
    }

    private func resetPostCreateLifecycleVerificationState() {
        for (_, task) in pendingPostCreateLifecycleVerificationTasks {
            task.cancel()
        }
        pendingPostCreateLifecycleVerificationTasks.removeAll()
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

        cancelPostCreateLifecycleVerification(for: token)
        controller.axManager.removeWindowState(pid: token.pid, windowId: token.windowId)
        if handleNativeFullscreenDestroy(token) {
            return
        }

        clearManagedFocusState(matching: token, workspaceId: affectedWorkspaceId)
        controller.nativeFullscreenPlaceholderManager.remove(token)
        controller.clearResizePlaceholder(for: token)

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

        controller.cleanupScratchpadWindowResourcesIfNeeded(for: token)
        _ = controller.workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
        controller.clearManualWindowOverride(for: token)
        controller.focusBorderController.clear(matching: token)

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
        guard controller.focusPolicyEngine.evaluate(
            .managedAppActivation(source: source)
        ).allowsFocusChange else {
            return
        }
        recordNiriCreateFocusTrace(
            .init(
                kind: .activationSourceObserved(
                    pid: pid,
                    source: source
                )
            )
        )
        guard controller.hasStartedServices else { return }

        if source != .focusedWindowChanged {
            controller.focusPolicyEngine.beginLease(
                owner: .nativeAppSwitch,
                reason: source.rawValue,
                suppressesFocusFollowsMouse: true,
                duration: 0.4
            )
        }

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
            controller.focusBorderController.clear()
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
                if shouldHonorObservedFocusOverPendingRequest(
                    source: source,
                    origin: origin,
                    pendingRequest: request
                ) {
                    clearManagedFocusState(
                        matching: request.token,
                        workspaceId: request.workspaceId
                    )
                    break
                }
                continueManagedFocusRequest(
                    request,
                    source: source,
                    origin: origin,
                    reason: .pendingFocusMismatch
                )
                return
            case .unrelatedNoRequest:
                guard shouldHandleObservedManagedActivationWithoutPendingRequest(
                    source: source,
                    origin: origin,
                    isWorkspaceActive: isWorkspaceActive
                ) else { return }
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
                if shouldHonorObservedFocusOverPendingRequest(
                    source: source,
                    origin: origin,
                    pendingRequest: request
                ) {
                    clearManagedFocusState(
                        matching: request.token,
                        workspaceId: request.workspaceId
                    )
                    break
                }
                continueManagedFocusRequest(
                    request,
                    source: source,
                    origin: origin,
                    reason: .pendingFocusMismatch
                )
                return
            case .unrelatedNoRequest:
                guard shouldHandleObservedManagedActivationWithoutPendingRequest(
                    source: source,
                    origin: origin,
                    isWorkspaceActive: isWorkspaceActive
                ) else { return }
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
        case let .matchesActiveRequest(request),
             let .conflictsWithPendingRequest(request):
            if shouldHonorObservedFocusOverPendingRequest(
                source: source,
                origin: origin,
                pendingRequest: request
            ) {
                clearManagedFocusState(
                    matching: request.token,
                    workspaceId: request.workspaceId
                )
                break
            }
            continueManagedFocusRequest(
                request,
                source: source,
                origin: origin,
                reason: .pendingFocusUnmanagedToken
            )
            return
        case .unrelatedNoRequest:
            break
        }

        let target = controller.keyboardFocusTarget(for: token, axRef: axRef)
        let fallbackFullscreen = appFullscreenForFallbackLifecyclePreservation(
            observedAppFullscreen: appFullscreen
        )
        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: fallbackFullscreen)
        _ = controller.focusBorderController.focusChanged(to: target, forceOrdering: true)

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
        let shouldConfirmRequest = confirmRequest ?? true
        var confirmedRequestId: UInt64?

        if shouldConfirmRequest {
            _ = controller.workspaceManager.confirmManagedFocus(
                entry.token,
                in: wsId,
                onMonitor: monitorId,
                appFullscreen: appFullscreen,
                activateWorkspaceOnMonitor: shouldActivateWorkspace
            )

            if let activeRequest {
                confirmedRequestId = activeRequest.requestId
                if activeRequest.token == entry.token {
                    _ = controller.focusBridge.confirmManagedRequest(
                        token: entry.token,
                        source: source
                    )
                } else {
                    _ = controller.focusBridge.cancelManagedRequest(requestId: activeRequest.requestId)
                }
            }

            if let confirmedRequestId {
                cancelActivationRetry(requestId: confirmedRequestId)
            }
            recordNiriCreateFocusTrace(
                .init(
                    kind: .focusConfirmed(
                        token: entry.token,
                        workspaceId: wsId,
                        source: source
                    )
                )
            )
        } else {
            _ = controller.workspaceManager.setManagedFocus(
                entry.token,
                in: wsId,
                onMonitor: monitorId
            )
        }

        let target = controller.keyboardFocusTarget(for: entry.token, axRef: entry.axRef)
        var preferredMouseFrame: CGRect?
        if let engine = controller.niriEngine,
           let node = engine.findNode(for: entry.handle),
           let _ = controller.workspaceManager.monitor(for: wsId)
        {
            let preferredFrame = node.renderedFrame ?? node.frame
            preferredMouseFrame = preferredFrame
            var state = controller.workspaceManager.niriViewportState(for: wsId)
            let preserveActiveViewport = state.viewOffsetPixels.isGesture || state.viewOffsetPixels.isAnimating
            controller.niriLayoutHandler.activateNode(
                node, in: wsId, state: &state,
                options: preserveActiveViewport
                    ? .init(
                        ensureVisible: false,
                        preserveViewportAnchor: true,
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

            _ = controller.focusBorderController.focusChanged(
                to: target,
                preferredFrame: preferredFrame,
                forceOrdering: true
            )
        } else {
            _ = controller.focusBorderController.focusChanged(to: target, forceOrdering: true)
        }

        controller.niriLayoutHandler.updateTabbedColumnOverlays(forceOrdering: true)
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
            controller.moveMouseToWindow(entry.token, preferredFrame: preferredMouseFrame)
        }
    }

    func focusedWindowToken(for pid: pid_t) -> WindowToken? {
        guard let axRef = resolveFocusedAXWindowRef(pid: pid) else { return nil }
        return WindowToken(pid: pid, windowId: axRef.windowId)
    }

    func handleWindowMiniaturized(pid: pid_t, windowId: Int) {
        controller?.clearKeyboardFocusTarget(
            matching: WindowToken(pid: pid, windowId: windowId),
            pid: pid
        )
    }

    @discardableResult
    private func suspendManagedWindowForNativeFullscreen(_ entry: WindowModel.Entry) -> Bool {
        guard let controller else { return false }
        cancelNativeFullscreenLifecycleTasks(containing: entry.token)
        controller.clearResizePlaceholder(for: entry.token)
        let changed = controller.workspaceManager.markNativeFullscreenSuspended(entry.token)
        _ = controller.focusBorderController.focusChanged(
            to: controller.keyboardFocusTarget(for: entry.token, axRef: entry.axRef),
            forceOrdering: true
        )
        if changed {
            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .appActivationTransition,
                affectedWorkspaceIds: [entry.workspaceId]
            )
        }
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
        let restored = controller.workspaceManager.restoreNativeFullscreenRecord(for: entry.token) != nil || hadRecord
        if restored {
            controller.nativeFullscreenPlaceholderManager.remove(entry.token)
            controller.clearResizePlaceholder(for: entry.token)
        }
        return restored
    }

    @discardableResult
    func restoreNativeFullscreenReplacementIfNeeded(
        token: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef,
        workspaceId: WorkspaceDescriptor.ID?,
        appFullscreen: Bool
    ) -> Bool {
        restoreNativeFullscreenReplacement(
            token: token,
            windowId: windowId,
            axRef: axRef,
            workspaceId: workspaceId,
            appFullscreen: appFullscreen
        ).restored
    }

    private func restoreNativeFullscreenReplacement(
        token: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef,
        workspaceId: WorkspaceDescriptor.ID?,
        appFullscreen: Bool
    ) -> NativeFullscreenReplacementRestoreResult {
        guard let controller else { return .notRestored }
        let unavailableRecord = controller.workspaceManager.nativeFullscreenUnavailableCandidate(
            for: token.pid,
            activeWorkspaceId: workspaceId
        )
        guard let record = unavailableRecord else {
            return .notRestored
        }
        if record.currentToken == token {
            guard let entry = controller.workspaceManager.entry(for: token) else {
                return .notRestored
            }
            cancelNativeFullscreenLifecycleTasks(for: record.originalToken)
            let scheduledRelayout: Bool
            if appFullscreen {
                scheduledRelayout = suspendManagedWindowForNativeFullscreen(entry)
            } else {
                _ = controller.workspaceManager.restoreNativeFullscreenRecord(for: token)
                controller.nativeFullscreenPlaceholderManager.remove(token)
                controller.clearResizePlaceholder(for: token)
                scheduledRelayout = false
            }
            return .restored(scheduledRelayout: scheduledRelayout)
        }
        guard let entry = rekeyManagedWindowIdentity(from: record.currentToken, to: token, windowId: windowId, axRef: axRef)
        else {
            return .notRestored
        }

        cancelNativeFullscreenLifecycleTasks(for: record.originalToken)

        let scheduledRelayout: Bool
        if appFullscreen {
            scheduledRelayout = suspendManagedWindowForNativeFullscreen(entry)
        } else {
            _ = controller.workspaceManager.restoreNativeFullscreenRecord(for: token)
            controller.nativeFullscreenPlaceholderManager.remove(token)
            controller.clearResizePlaceholder(for: token)
            scheduledRelayout = false
        }

        return .restored(scheduledRelayout: scheduledRelayout)
    }

    @discardableResult
    func rekeyManagedWindowIdentity(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> WindowModel.Entry? {
        guard let controller else { return nil }
        let hadResizePlaceholder = oldToken != newToken
            && (controller.workspaceManager.resizePlaceholderState(for: oldToken) != nil
                || controller.resizePlaceholderManager.hasPlaceholder(for: oldToken))

        guard let entry = controller.workspaceManager.rekeyWindow(
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
        controller.nativeFullscreenPlaceholderManager.rekey(from: oldToken, to: newToken)
        controller.resizePlaceholderManager.rekey(from: oldToken, to: newToken)

        controller.focusBridge.rekeyPendingFocus(from: oldToken, to: newToken)
        controller.focusBridge.rekeyManagedRequest(from: oldToken, to: newToken)
        controller.focusBorderController.rekeyFocusedTarget(
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
        if hadResizePlaceholder {
            controller.clearResizePlaceholder(for: newToken)
            controller.layoutRefreshController.requestRelayout(
                reason: .axWindowCreated,
                affectedWorkspaceIds: [entry.workspaceId]
            )
        }
        controller.rekeyScratchpadWindowResources(from: oldToken, to: newToken, axRef: axRef)
        controller.layoutRefreshController.rekeyPendingRevealTransaction(
            from: oldToken,
            to: newToken,
            entry: entry
        )
        AXWindowService.invalidateCachedTitles(windowIds: [UInt32(oldToken.windowId), windowId])
        subscribeToWindows([windowId])
        controller.requestWorkspaceBarRefresh()
        controller.niriLayoutHandler.updateTabbedColumnOverlays(forceOrdering: true)
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
        guard let controller else {
            return false
        }

        let existingRecord = controller.workspaceManager.nativeFullscreenRecord(for: token)
        let unavailableRecord: WorkspaceManager.NativeFullscreenRecord?
        if existingRecord?.currentToken == token {
            unavailableRecord = controller.workspaceManager.markNativeFullscreenTemporarilyUnavailable(token)
        } else if existingRecord != nil {
            return false
        } else if shouldSpeculativelyPreserveNativeFullscreenDestroy(token) {
            unavailableRecord = controller.workspaceManager.markNativeFullscreenSpeculativelyUnavailable(token)
        } else {
            return false
        }

        guard let unavailableRecord else { return false }
        controller.focusBorderController.hide()
        controller.nativeFullscreenPlaceholderManager.remove(token)
        controller.clearResizePlaceholder(for: token)
        clearManagedFocusState(matching: token, workspaceId: unavailableRecord.workspaceId)
        scheduleNativeFullscreenFollowup(for: unavailableRecord.originalToken)
        return true
    }

    private func shouldSpeculativelyPreserveNativeFullscreenDestroy(_ token: WindowToken) -> Bool {
        guard let controller,
              let entry = controller.workspaceManager.entry(for: token),
              entry.mode == .tiling,
              controller.workspaceManager.focusedToken == token,
              controller.workspaceManager.scratchpadToken() != token
        else {
            return false
        }

        let layoutType = controller.workspaceManager.descriptor(for: entry.workspaceId)
            .map { controller.settings.layoutType(for: $0.name) } ?? .defaultLayout
        guard layoutType != .dwindle else { return false }

        if let isFullscreenProvider {
            return isFullscreenProvider(entry.axRef)
        }
        return AXWindowService.isFullscreenAttributeSet(entry.axRef)
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
            controller.focusBorderController.clear(pid: pid)
        }

        for entry in controller.workspaceManager.entries(forPid: pid) {
            controller.clearResizePlaceholder(for: entry.token)
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
        windowInfo: WindowServerInfo?,
        createPlacementContext: WindowCreatePlacementContext? = nil
    ) -> PreparedCreate? {
        guard let controller else { return nil }
        let ownedWindow = controller.isOwnedWindow(windowNumber: Int(windowId))
        guard let token = windowInfo.map({ WindowToken(pid: pid_t($0.pid), windowId: Int(windowId)) })
        else { return nil }
        if controller.workspaceManager.entry(for: token) != nil { return nil }
        if ownedWindow {
            discardCreatePlacementContext(windowId: windowId)
            return nil
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

        if trackedMode == nil {
            scheduleWindowStabilizationRetryIfNeeded(
                token: token,
                decision: evaluation.decision
            )
        }

        guard let trackedMode else { return nil }
        subscribeToWindows([windowId])

        let resolvedBundleId = bundleId ?? evaluation.facts.ax.bundleId
        let structuralReplacementWorkspaceId = structuralReplacementWorkspaceIdForCreate(
            token: token,
            bundleId: resolvedBundleId,
            mode: trackedMode,
            facts: evaluation.facts
        )
        let inheritTrackedParentWorkspace = controller.shouldInheritTrackedParentWorkspace(for: evaluation)
        let placementFrame = evaluation.facts.windowServer?.frame ?? windowInfo?.frame
        let workspaceId = controller.resolveWorkspaceForNewWindow(
            workspaceName: evaluation.decision.workspaceName,
            axRef: axRef,
            pid: token.pid,
            parentWindowId: evaluation.facts.windowServer?.parentId,
            inheritTrackedParentWorkspace: inheritTrackedParentWorkspace,
            preferSameAppSiblingWorkspace: controller.shouldPreferSameAppSiblingWorkspace(
                for: evaluation,
                inheritTrackedParentWorkspace: inheritTrackedParentWorkspace
            ),
            structuralReplacementWorkspaceId: structuralReplacementWorkspaceId,
            restrictWorkspaceRuleToPlacementMonitor: trackedMode != .floating,
            createPlacementContext: createPlacementContext,
            windowFrame: placementFrame,
            fallbackWorkspaceId: controller.activeWorkspace()?.id
        )
        recordCreatePlacementTrace(
            token: token,
            workspaceId: workspaceId,
            createPlacementContext: createPlacementContext,
            windowFrame: placementFrame,
            controller: controller
        )

        return PreparedCreate(
            windowId: windowId,
            token: token,
            axRef: axRef,
            ruleEffects: evaluation.decision.ruleEffects,
            replacementMetadata: makeManagedReplacementMetadata(
                bundleId: resolvedBundleId,
                workspaceId: workspaceId,
                mode: trackedMode,
                facts: evaluation.facts
            ),
            hasStructuralReplacementWorkspaceMatch: structuralReplacementWorkspaceId != nil,
            requiresPostCreateLifecycleVerification: requiresPostCreateLifecycleVerification(
                trackedMode: trackedMode,
                facts: evaluation.facts
            )
        )
    }

    private func requiresPostCreateLifecycleVerification(
        trackedMode: TrackedWindowMode,
        facts: WindowRuleFacts
    ) -> Bool {
        guard trackedMode == .floating else { return false }
        return !facts.ax.attributeFetchSucceeded
            || facts.ax.subrole == (kAXSystemDialogSubrole as String)
            || facts.windowServer?.hasTransientSurfaceEvidence == true
    }

    private func recordCreatePlacementTrace(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        createPlacementContext: WindowCreatePlacementContext?,
        windowFrame: CGRect?,
        controller: WMController
    ) {
        recordNiriCreateFocusTrace(
            .init(
                kind: .createPlacementResolved(
                    token: token,
                    workspaceId: workspaceId,
                    pendingWorkspaceId: createPlacementContext?.pendingFocusedWorkspaceId,
                    pendingMonitorId: createPlacementContext?.pendingFocusedMonitorId,
                    focusedWorkspaceId: createPlacementContext?.focusedWorkspaceId,
                    focusedMonitorId: createPlacementContext?.focusedMonitorId,
                    nativeSpaceMonitorId: createPlacementContext?.nativeSpaceMonitorId,
                    frameMonitorId: placementTraceMonitorId(for: windowFrame, controller: controller),
                    interactionMonitorId: createPlacementContext?.interactionMonitorId
                )
            )
        )
    }

    private func placementTraceMonitorId(
        for frame: CGRect?,
        controller: WMController
    ) -> Monitor.ID? {
        guard let frame, !frame.isNull, !frame.isEmpty else { return nil }
        return frame.center.monitorApproximation(in: controller.workspaceManager.monitors)?.id
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
        let resolvedToken = resolveWindowToken(windowId)
            ?? resolveTrackedToken(windowId)
            ?? pidHint.map { WindowToken(pid: $0, windowId: Int(windowId)) }
        if let resolvedToken {
            cancelWindowStabilizationRetry(for: resolvedToken)
            cancelPostCreateLifecycleVerification(for: resolvedToken)
            controller?.clearManualWindowOverride(for: resolvedToken)
        }

        guard let candidate = prepareDestroyCandidate(windowId: windowId, pidHint: pidHint) else {
            clearFocusedTargetForDestroyedWindow(
                windowId: windowId,
                resolvedToken: resolvedToken,
                pidHint: pidHint
            )
            if let resolvedToken {
                controller?.axManager.removeWindowState(
                    pid: resolvedToken.pid,
                    windowId: resolvedToken.windowId
                )
                scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(resolvedToken.pid)])
            } else if let pid = pidHint ?? resolveWindowInfo(windowId)?.pid {
                scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(pid_t(pid))])
            }
            return
        }

        let shouldDelayDestroy = shouldDelayManagedReplacementDestroy(candidate)
        if shouldDelayDestroy, handleNativeFullscreenDestroy(candidate.token) {
            return
        }

        if shouldDelayDestroy {
            if controller?.currentKeyboardFocusTargetForRendering()?.token == candidate.token {
                controller?.focusBorderController.hide()
            }
            enqueueManagedReplacementDestroy(candidate)
            return
        }

        processPreparedDestroy(candidate)
    }

    private func clearFocusedTargetForDestroyedWindow(
        windowId: UInt32,
        resolvedToken: WindowToken?,
        pidHint: pid_t?
    ) {
        guard let controller,
              let target = controller.currentKeyboardFocusTargetForRendering()
        else { return }

        let matchesResolvedToken = resolvedToken.map { $0 == target.token } ?? false
        let matchesPidHint = pidHint.map { $0 == target.pid && target.windowId == Int(windowId) } ?? false
        let matchesWindowId = target.windowId == Int(windowId)
        guard matchesResolvedToken || matchesPidHint || matchesWindowId else { return }

        controller.clearKeyboardFocusTarget(matching: target.token)
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

        return candidate.hasStructuralReplacementWorkspaceMatch
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
        recordManagedReplacementTrace(
            key: key,
            kind: .enqueued(
                policy: managedReplacementPolicyName(policy),
                createCount: burst.creates.count,
                destroyCount: burst.destroys.count,
                holdCount: 0,
                deadlineReset: resetExistingDeadline
            )
        )
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
        recordManagedReplacementTrace(
            key: key,
            kind: .enqueued(
                policy: managedReplacementPolicyName(policy),
                createCount: burst.creates.count,
                destroyCount: burst.destroys.count,
                holdCount: 0,
                deadlineReset: resetExistingDeadline
            )
        )
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
                          oldToken: destroy.candidate.token,
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
        let entry = rekeyManagedWindowIdentity(
            from: oldToken,
            to: create.token,
            windowId: create.windowId,
            axRef: create.axRef,
            managedReplacementMetadata: create.replacementMetadata
        )
        if entry != nil {
            discardCreatePlacementContext(windowId: create.windowId)
        }
        return entry != nil
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
            parentWindowId: normalizedParentWindowId(facts.windowServer?.parentId),
            frame: facts.windowServer?.frame,
            transientWindowServerEvidence: facts.windowServer?.hasTransientSurfaceEvidence ?? false
        )
    }

    private func normalizedParentWindowId(_ parentWindowId: UInt32?) -> UInt32? {
        guard let parentWindowId, parentWindowId != 0 else { return nil }
        return parentWindowId
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
        metadata.parentWindowId = normalizedParentWindowId(windowInfo.parentId) ?? metadata.parentWindowId
        if !windowInfo.frame.isNull, !windowInfo.frame.isEmpty {
            metadata.frame = windowInfo.frame
        }
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

    private func structuralReplacementMatch(
        token: WindowToken,
        bundleId: String?,
        mode: TrackedWindowMode,
        facts: WindowRuleFacts
    ) -> StructuralReplacementMatch? {
        guard let controller,
              let fallbackWorkspaceId = controller.activeWorkspace()?.id
              ?? controller.workspaceManager.primaryWorkspace()?.id
              ?? controller.workspaceManager.workspaces.first?.id
        else {
            return nil
        }

        let baseMetadata = makeManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: fallbackWorkspaceId,
            mode: mode,
            facts: facts
        )
        guard managedReplacementCorrelationPolicy(for: baseMetadata) != nil else { return nil }

        var match: StructuralReplacementMatch?
        func recordMatch(token: WindowToken, workspaceId: WorkspaceDescriptor.ID) -> Bool {
            if match != nil {
                return false
            }
            match = StructuralReplacementMatch(token: token, workspaceId: workspaceId)
            return true
        }

        func matches(_ oldMetadata: ManagedReplacementMetadata, oldToken: WindowToken) -> Bool {
            var newMetadata = baseMetadata
            newMetadata.workspaceId = oldMetadata.workspaceId
            return managedReplacementMetadataMatches(oldToken: oldToken, old: oldMetadata, new: newMetadata)
        }

        for burst in pendingManagedReplacementBursts.values {
            for destroy in burst.destroys where destroy.candidate.token.pid == token.pid {
                let metadata = destroy.candidate.replacementMetadata
                if matches(metadata, oldToken: destroy.candidate.token),
                   !recordMatch(token: destroy.candidate.token, workspaceId: metadata.workspaceId)
                {
                    return nil
                }
            }
        }

        for entry in controller.workspaceManager.entries(forPid: token.pid) where entry.token != token {
            let cachedMetadata = cachedManagedReplacementMetadata(
                for: entry,
                fallbackBundleId: bundleId
            )
            if matches(cachedMetadata, oldToken: entry.token),
               !recordMatch(token: entry.token, workspaceId: cachedMetadata.workspaceId)
            {
                return nil
            }
            if match?.token == entry.token {
                continue
            }
            let liveMetadata = overlayWindowServerInfo(
                UInt32(exactly: entry.windowId).flatMap(resolveWindowInfo),
                onto: cachedMetadata
            )
            if liveMetadata != cachedMetadata,
               matches(liveMetadata, oldToken: entry.token),
               !recordMatch(token: entry.token, workspaceId: liveMetadata.workspaceId)
            {
                return nil
            }
        }

        return match
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
        oldToken: WindowToken,
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

        return managedReplacementStructuralAnchorsMatch(oldToken: oldToken, old: old, new: new)
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
        oldToken: WindowToken,
        old: ManagedReplacementMetadata,
        new: ManagedReplacementMetadata
    ) -> Bool {
        let framesClose = framesAreCloseForManagedReplacement(old.frame, new.frame)
        let hasFrameEvidence = old.frame != nil && new.frame != nil

        switch (old.parentWindowId, new.parentWindowId) {
        case let (oldParentWindowId?, newParentWindowId?) where oldParentWindowId == newParentWindowId:
            return hasFrameEvidence ? framesClose : true
        case let (_, newParentWindowId?) where UInt32(exactly: oldToken.windowId) == newParentWindowId:
            return framesClose
        case (_?, _?):
            return false
        default:
            return framesClose
        }
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
        if let preferredFrame {
            _ = controller.focusBorderController.updateFrameHint(for: entry.token, frame: preferredFrame)
        } else {
            _ = controller.focusBorderController.refresh()
        }
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
            for entry in removedEntries {
                controller.nativeFullscreenPlaceholderManager.remove(entry.token)
                controller.clearResizePlaceholder(for: entry.token)
            }
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
        let elapsedMillis = max(
            0,
            Int(((managedReplacementCurrentUptime() - burst.firstEventUptime) * 1000).rounded())
        )
        recordManagedReplacementTrace(
            key: key,
            kind: .flushed(
                policy: managedReplacementPolicyName(burst.policy),
                createCount: burst.creates.count,
                destroyCount: burst.destroys.count,
                holdCount: 0,
                elapsedMillis: elapsedMillis
            )
        )

        if let pair = matchedManagedReplacementPair(in: burst) {
            if completeManagedReplacement(destroy: pair.destroy, create: pair.create) {
                recordManagedReplacementTrace(
                    key: key,
                    kind: .matched(
                        policy: managedReplacementPolicyName(burst.policy),
                        elapsedMillis: elapsedMillis
                    )
                )
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
            discardCreatePlacementContext(windowId: windowId)
            return false
        }
        guard !controller.isOwnedWindow(windowNumber: Int(windowId)) else {
            cancelCreatedWindowRetry(windowId: windowId)
            discardCreatePlacementContext(windowId: windowId)
            return false
        }
        guard resolveAXWindowRef(windowId: windowId, pid: pid) == nil else {
            return false
        }

        let attempt = createdWindowRetryCountById[windowId, default: 0] + 1
        guard attempt <= Self.createdWindowRetryLimit else {
            discardCreatePlacementContext(windowId: windowId)
            return false
        }

        enqueueCreatedWindowRetry(
            windowId: windowId,
            attempt: attempt,
            traceKind: .createRetryScheduled(
                windowId: windowId,
                pid: pid,
                attempt: attempt
            )
        )
        return true
    }

    private func scheduleCreatedWindowInfoRetryIfNeeded(windowId: UInt32) -> Bool {
        guard let controller else { return false }
        guard !controller.isOwnedWindow(windowNumber: Int(windowId)) else {
            cancelCreatedWindowRetry(windowId: windowId)
            discardCreatePlacementContext(windowId: windowId)
            return false
        }

        let attempt = createdWindowRetryCountById[windowId, default: 0] + 1
        guard attempt <= Self.createdWindowRetryLimit else {
            discardCreatePlacementContext(windowId: windowId)
            return false
        }

        enqueueCreatedWindowRetry(windowId: windowId, attempt: attempt, traceKind: nil)
        return true
    }

    private func enqueueCreatedWindowRetry(
        windowId: UInt32,
        attempt: Int,
        traceKind: NiriCreateFocusTraceEvent.Kind?
    ) {
        createdWindowRetryCountById[windowId] = attempt
        pendingCreatedWindowRetryTasks.removeValue(forKey: windowId)?.cancel()
        if let traceKind {
            recordNiriCreateFocusTrace(.init(kind: traceKind))
        }
        pendingCreatedWindowRetryTasks[windowId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.stabilizationRetryDelay)
            guard !Task.isCancelled, let self else { return }
            self.pendingCreatedWindowRetryTasks.removeValue(forKey: windowId)
            self.processCreatedWindow(windowId: windowId)
        }
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

    private func captureCreatePlacementContext(windowId: UInt32, spaceId: UInt64) {
        pruneExpiredCreatePlacementContexts()
        guard createPlacementContextsByWindowId[windowId] == nil,
              let controller
        else {
            return
        }

        let focusedWorkspaceId = resolveFocusedPlacementWorkspaceId(controller: controller)
        createPlacementContextsByWindowId[windowId] = WindowCreatePlacementContext(
            nativeSpaceMonitorId: resolveNativeSpacePlacementMonitorId(spaceId: spaceId, controller: controller),
            pendingFocusedWorkspaceId: controller.workspaceManager.pendingFocusedWorkspaceId,
            pendingFocusedMonitorId: resolvePendingFocusedPlacementMonitorId(controller: controller),
            focusedWorkspaceId: focusedWorkspaceId,
            focusedMonitorId: focusedWorkspaceId.flatMap {
                controller.workspaceManager.monitorId(for: $0)
            },
            interactionMonitorId: controller.workspaceManager.interactionMonitorId,
            createdAt: Date()
        )
    }

    private func resolvePendingFocusedPlacementMonitorId(
        controller: WMController
    ) -> Monitor.ID? {
        controller.workspaceManager.pendingFocusedMonitorId
            ?? controller.workspaceManager.pendingFocusedWorkspaceId.flatMap {
                controller.workspaceManager.monitorId(for: $0)
            }
    }

    private func resolveFocusedPlacementWorkspaceId(
        controller: WMController
    ) -> WorkspaceDescriptor.ID? {
        guard let focusedToken = controller.workspaceManager.focusedToken,
              let workspaceId = controller.workspaceManager.workspace(for: focusedToken)
        else {
            return nil
        }
        return workspaceId
    }

    private func resolveNativeSpacePlacementMonitorId(
        spaceId: UInt64,
        controller: WMController
    ) -> Monitor.ID? {
        let monitors = controller.workspaceManager.monitors
        let displayId: CGDirectDisplayID?
        if let spaceDisplayResolver {
            displayId = spaceDisplayResolver(spaceId, monitors)
        } else {
            displayId = SkyLight.shared.displayId(forSpaceId: spaceId, among: monitors)
        }
        guard let displayId,
              let monitor = monitors.first(where: { $0.displayId == displayId })
        else {
            return nil
        }

        return monitor.id
    }

    private func discardCreatePlacementContext(windowId: UInt32) {
        createPlacementContextsByWindowId.removeValue(forKey: windowId)
    }

    private func resetCreatePlacementContextState() {
        createPlacementContextsByWindowId.removeAll()
    }

    private func pruneExpiredCreatePlacementContexts(now: Date = Date()) {
        createPlacementContextsByWindowId = createPlacementContextsByWindowId.filter { _, context in
            now.timeIntervalSince(context.createdAt) < Self.createPlacementContextTTL
        }
    }

    private func handleMissingFocusedWindow(
        pid: pid_t,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        requestDisposition: ActivationRequestDisposition
    ) {
        guard let controller else { return }

        switch requestDisposition {
        case let .matchesActiveRequest(request),
             let .conflictsWithPendingRequest(request):
            if shouldHonorObservedFocusOverPendingRequest(
                source: source,
                origin: origin,
                pendingRequest: request
            ) {
                clearManagedFocusState(
                    matching: request.token,
                    workspaceId: request.workspaceId
                )
                break
            }
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
        controller.focusBorderController.clear()
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

    private func shouldHandleObservedManagedActivationWithoutPendingRequest(
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        isWorkspaceActive: Bool
    ) -> Bool {
        guard !isWorkspaceActive else { return true }

        switch source {
        case .focusedWindowChanged:
            return true
        case .workspaceDidActivateApplication,
             .cgsFrontAppChanged:
            return origin == .external
        }
    }

    private static let managedRequestGracePeriod: CFAbsoluteTime = 0.3

    private func shouldHonorObservedFocusOverPendingRequest(
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        pendingRequest: ManagedFocusRequest
    ) -> Bool {
        guard source.isAuthoritative, origin == .external else { return false }
        return pendingRequest.age > Self.managedRequestGracePeriod
    }

    func cleanupFocusStateForTerminatedApp(pid: pid_t) {
        guard let controller else { return }

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
    }

    private func clearManagedFocusState(
        matching token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID?
    ) {
        guard let controller else { return }

        controller.focusBridge.discardPendingFocus(token)
        let canceledRequest = controller.focusBridge.cancelManagedRequest(
            matching: token,
            workspaceId: workspaceId
        )
        _ = controller.workspaceManager.cancelManagedFocusRequest(
            matching: token,
            workspaceId: workspaceId
        )
        if let canceledRequest {
            cancelActivationRetry(requestId: canceledRequest.requestId)
        }
        controller.clearKeyboardFocusTarget(
            matching: token,
            restoreCurrentBorder: false
        )
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
                  requestId: request.requestId,
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
           controller.focusBorderController.refresh(
               preferredFrame: controller.preferredKeyboardFocusFrame(for: target.token),
               forceOrdering: true
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
            controller.focusBorderController.hide()
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
        if let windowInfoProvider {
            if let info = windowInfoProvider(windowId) {
                return info
            }
            if windowInfoProviderIsAuthoritativeForTests {
                return nil
            }
        }
        return SkyLight.shared.queryWindowInfo(windowId)
    }

    private func resolveWindowToken(_ windowId: UInt32) -> WindowToken? {
        guard let windowInfo = resolveWindowInfo(windowId) else { return nil }
        return .init(pid: windowInfo.pid, windowId: Int(windowId))
    }

    private func resolveTrackedToken(
        _ windowId: UInt32,
        resolvedWindowToken: WindowToken? = nil
    ) -> WindowToken? {
        if let token = resolvedWindowToken ?? resolveWindowToken(windowId) {
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
        return controller.appInfoCache.bundleId(for: pid) ?? NSRunningApplication(processIdentifier: pid)?
            .bundleIdentifier
    }
}
