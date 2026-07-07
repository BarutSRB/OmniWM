// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

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

struct ManagedReplacementFocusKey: Hashable, Equatable {
    let pid: pid_t
    let workspaceId: WorkspaceDescriptor.ID
}

enum ActivationCallOrigin: String {
    case external
    case probe
    case retry
}

enum ManagedBorderReapplyPhase: String, Equatable {
    case postLayout
    case animationSettled
    case retryExhaustedFallback
}

struct NiriCreateFocusTraceEvent: Equatable {
    enum Kind: Equatable {
        case createSeen(windowId: UInt32)
        case createRetryScheduled(windowId: UInt32, pid: pid_t, attempt: Int)
        case createPlacementResolved(
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID,
            rung: WorkspacePlacementRung,
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
            rung,
            pendingWorkspaceId,
            pendingMonitorId,
            focusedWorkspaceId,
            focusedMonitorId,
            nativeSpaceMonitorId,
            frameMonitorId,
            interactionMonitorId
        ):
            "create_placement_resolved token=\(token) workspace=\(workspaceId.uuidString) rung=\(rung.rawValue) pending_workspace=\(pendingWorkspaceId?.uuidString ?? "nil") pending_monitor=\(String(describing: pendingMonitorId)) focused_workspace=\(focusedWorkspaceId?.uuidString ?? "nil") focused_monitor=\(String(describing: focusedMonitorId)) native_monitor=\(String(describing: nativeSpaceMonitorId)) frame_monitor=\(String(describing: frameMonitorId)) interaction_monitor=\(String(describing: interactionMonitorId))"
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
final class AXEventHandler {
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
        let structuralReplacementMatch: StructuralReplacementMatch?
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

    private enum PendingFocusedManagedActivationRequest {
        case matchesActiveRequest(UInt64)
        case conflictsWithPendingRequest(UInt64)
        case unrelatedNoRequest

        init(_ disposition: ActivationRequestDisposition) {
            switch disposition {
            case let .matchesActiveRequest(request):
                self = .matchesActiveRequest(request.requestId)
            case let .conflictsWithPendingRequest(request):
                self = .conflictsWithPendingRequest(request.requestId)
            case .unrelatedNoRequest:
                self = .unrelatedNoRequest
            }
        }

        var requestId: UInt64? {
            switch self {
            case let .matchesActiveRequest(requestId),
                 let .conflictsWithPendingRequest(requestId):
                requestId
            case .unrelatedNoRequest:
                nil
            }
        }
    }

    private struct PendingFocusedManagedActivation {
        let source: ActivationEventSource
        let origin: ActivationCallOrigin
        let appFullscreen: Bool
        let request: PendingFocusedManagedActivationRequest
    }

    private struct WindowCloseFocusRecoveryContext {
        let workspaceId: WorkspaceDescriptor.ID
        let closedToken: WindowToken
        let expiresAt: Date
    }

    private struct RecentMouseFocusIntent {
        let token: WindowToken
        let expiresAt: Date
    }

    private struct PendingManagedCreate {
        let sequence: UInt64
        let candidate: PreparedCreate
        let focusedActivation: PendingFocusedManagedActivation?
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

    enum StructuralReplacementMatchSource {
        case pendingDestroy
        case liveInvisible
    }

    struct StructuralReplacementMatch {
        let token: WindowToken
        let workspaceId: WorkspaceDescriptor.ID
        let source: StructuralReplacementMatchSource
    }

    private static let managedReplacementGraceDelay: Duration = .milliseconds(150)
    private static let stabilizationRetryDelay: Duration = .milliseconds(100)
    private static let focusedAdmissionReadmitDelay: Duration = .milliseconds(150)
    private static let postCreateLifecycleVerificationDelay: Duration = .milliseconds(75)
    private static let createdWindowRetryLimit = 5
    private static let createPlacementContextTTL: TimeInterval = 15
    private static let activationRetryLimit = 5
    private static let windowCloseFocusRecoveryDuration: TimeInterval = 0.6
    private static let sameAppCloseProbeDelay: Duration = .milliseconds(80)
    private static let mouseFocusIntentDuration: TimeInterval = 0.35
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
    private var pendingWindowRuleReevaluationTask: Task<Void, Never>?
    private var pendingWindowRuleReevaluationTargets: Set<WindowRuleReevaluationTarget> = []
    private var pendingWindowRuleReevaluationGeneration: UInt64 = 0
    private var pendingWindowStabilizationTasks: [WindowToken: Task<Void, Never>] = [:]
    private var pendingFocusedAdmissionReadmitTask: Task<Void, Never>?
    private var focusedAdmissionReadmitExhaustedToken: WindowToken?
    private var pendingPostCreateLifecycleVerificationTasks: [WindowToken: Task<Void, Never>] = [:]
    private var pendingPostCreateLifecycleVerificationOwners: [WindowToken: UInt64] = [:]
    private var nextPostCreateLifecycleVerificationOwner: UInt64 = 1
    private var pendingCreatedWindowRetryTasks: [UInt32: Task<Void, Never>] = [:]
    private var createdWindowRetryCountById: [UInt32: Int] = [:]
    private var windowCloseFocusRecoveryContext: WindowCloseFocusRecoveryContext?
    private var recentMouseFocusIntent: RecentMouseFocusIntent?
    private var createFocusTrace =
        RingBuffer<NiriCreateFocusTraceEvent>(capacity: AXEventHandler.createFocusTraceLimit)
    private var managedReplacementTrace =
        RingBuffer<ManagedReplacementTraceEvent>(capacity: AXEventHandler.managedReplacementTraceLimit)
    private var nextManagedReplacementEventSequence: UInt64 = 0
    var visibleWindowInfoProvider: () -> [WindowServerInfo]
    var windowInfoProvider: (UInt32) -> WindowServerInfo?

    init(
        controller: WMController,
        visibleWindowInfoProvider: @escaping () -> [WindowServerInfo] = {
            SkyLight.shared.queryAllVisibleWindows()
        },
        windowInfoProvider: @escaping (UInt32) -> WindowServerInfo? = {
            SkyLight.shared.queryWindowInfo($0)
        }
    ) {
        self.controller = controller
        self.visibleWindowInfoProvider = visibleWindowInfoProvider
        self.windowInfoProvider = windowInfoProvider
    }

    func setup() {
        CGSEventObserver.shared.start()
    }

    func cleanup() {
        resetCreatePlacementContextState()
        resetManagedReplacementState()
        endWindowCloseFocusRecovery(reason: "cleanup")
        cancelSameAppCloseProbe(reason: "cleanup")
        resetWindowStabilizationState()
        resetPostCreateLifecycleVerificationState()
        resetCreatedWindowRetryState()
        pendingFocusedAdmissionReadmitTask?.cancel()
        pendingFocusedAdmissionReadmitTask = nil
        focusedAdmissionReadmitExhaustedToken = nil
        pendingWindowRuleReevaluationTask?.cancel()
        pendingWindowRuleReevaluationTask = nil
        pendingWindowRuleReevaluationTargets.removeAll()
        pendingWindowRuleReevaluationGeneration &+= 1
        CGSEventObserver.shared.stop()
    }

    func handleCGSEvent(_ event: CGSWindowEvent) {
        guard let controller else { return }

        switch event {
        case let .created(windowId, spaceId):
            handleCGSWindowCreated(windowId: windowId, spaceId: spaceId)
            controller.spaceTracker.noteWindowSpace(windowId: Int(windowId), spaceId: spaceId)

        case let .destroyed(windowId, _):
            handleCGSWindowDestroyed(windowId: windowId)
            controller.spaceTracker.noteWindowDestroyed(windowId: Int(windowId))

        case let .closed(windowId):
            handleCGSWindowDestroyed(windowId: windowId)
            controller.spaceTracker.noteWindowDestroyed(windowId: Int(windowId))

        case let .frameChanged(windowId):
            handleFrameChanged(windowId: windowId)

        case let .frontAppChanged(pid):
            handleAppActivation(pid: pid, source: .cgsFrontAppChanged)

        case let .orderChanged(windowId):
            handleWindowOrderChanged(windowId: windowId)

        case let .titleChanged(windowId):
            AXWindowService.invalidateCachedTitle(windowId: windowId)
            controller.requestWorkspaceBarRefresh()
            if let token = resolveWindowToken(windowId) ?? resolveTrackedToken(windowId) {
                updateManagedReplacementTitle(windowId: windowId, token: token)
                scheduleWindowRuleReevaluationIfNeeded(targets: [.window(token)])
            }
        }
    }

    private func handleWindowOrderChanged(windowId: UInt32) {
        guard let controller else { return }
        guard !controller.isOwnedWindow(windowNumber: Int(windowId)) else { return }
        controller.surfaceReconciler.noteRestackOccurred()
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
        pendingWindowRuleReevaluationGeneration &+= 1
        let generation = pendingWindowRuleReevaluationGeneration
        pendingWindowRuleReevaluationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.pendingWindowRuleReevaluationGeneration == generation,
                  let controller = self.controller
            else { return }
            guard controller.niriLayoutHandler.scrollAnimationByDisplay.isEmpty else {
                self.pendingWindowRuleReevaluationTask = nil
                self.scheduleWindowRuleReevaluationIfNeeded(targets: self.pendingWindowRuleReevaluationTargets)
                return
            }
            let targets = self.pendingWindowRuleReevaluationTargets
            self.pendingWindowRuleReevaluationTargets.removeAll()
            self.pendingWindowRuleReevaluationTask = nil
            let outcome = await controller.reevaluateWindowRules(for: targets)
            if outcome.stale {
                self.scheduleWindowRuleReevaluationIfNeeded(targets: targets)
            }
        }
    }

    private func isWindowDisplayable(token: WindowToken) -> Bool {
        guard let controller else { return false }
        guard let entry = controller.workspaceManager.entry(for: token) else {
            return false
        }
        return controller.isManagedWindowDisplayable(entry.token)
    }

    private func handleCGSWindowCreated(windowId: UInt32, spaceId: UInt64) {
        if let controller, controller.workspaceManager.entry(forWindowId: Int(windowId)) != nil {
            cancelCreatedWindowRetry(windowId: windowId)
            discardCreatePlacementContext(windowId: windowId)
            removeDeferredCreatedWindow(windowId)
            return
        }
        captureCreatePlacementContext(windowId: windowId, spaceId: spaceId)
        recordNiriCreateFocusTrace(.init(kind: .createSeen(windowId: windowId)))
        if shouldDeferCreateForInactiveNativeSpace(spaceId) {
            deferCreatedWindow(windowId)
            return
        }
        processCreatedWindow(windowId: windowId)
    }

    private func shouldDeferCreateForInactiveNativeSpace(_ spaceId: UInt64) -> Bool {
        guard spaceId != 0, let controller else { return false }
        let topology = controller.workspaceManager.spaceTopology
        return topology.isKnownSpace(spaceId) && !topology.isCurrentSpace(spaceId)
    }

    private func liveCreateSpace(for windowId: UInt32) -> UInt64 {
        guard let controller else { return 0 }
        return controller.workspaceManager.spaceTopology
            .selectWindowSpace(from: SkyLight.shared.spacesForWindow(windowId)) ?? 0
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
        if let windowInfo, isOwnProcessPid(pid_t(windowInfo.pid)) {
            cancelCreatedWindowRetry(windowId: windowId)
            discardCreatePlacementContext(windowId: windowId)
            removeDeferredCreatedWindow(windowId)
            return
        }
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
        if completeLiveStructuralReplacementCreate(candidate) {
            return
        }
        if shouldDelayManagedReplacementCreate(candidate) {
            enqueueManagedReplacementCreate(candidate)
            return
        }

        trackPreparedCreate(candidate)
    }

    func probeFocusedWindowAfterFronting(
        expectedToken: WindowToken,
        workspaceId _: WorkspaceDescriptor.ID
    ) {
        let requestId = controller?.intentLedger.activeManagedRequest(for: expectedToken)?.requestId
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let requestId,
               self.controller?.intentLedger.activeManagedRequest(requestId: requestId) == nil
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

    func pendingCreatePlacementContext(for windowId: Int) -> WindowCreatePlacementContext? {
        guard let windowId = UInt32(exactly: windowId) else { return nil }
        pruneExpiredCreatePlacementContexts()
        return createPlacementContextsByWindowId[windowId]
    }

    func discardCreatePlacementContext(for windowId: Int) {
        guard let windowId = UInt32(exactly: windowId) else { return }
        discardCreatePlacementContext(windowId: windowId)
    }

    @discardableResult
    func rekeyStructuralManagedReplacement(
        match: StructuralReplacementMatch,
        token: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef,
        bundleId: String?,
        mode: TrackedWindowMode,
        facts: WindowRuleFacts
    ) -> Bool {
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

        rekeyManagedReplacementFocusTransaction(
            from: match.token,
            to: token,
            workspaceId: match.workspaceId
        )
        discardCreatePlacementContext(windowId: windowId)
        return true
    }

    func recordNiriCreateFocusTrace(_ event: NiriCreateFocusTraceEvent) {
        createFocusTrace.append(event)

        if Self.createFocusTraceLoggingEnabled {
            Log.ax.debug("[NiriCreateFocus] \(event.description)")
        }
    }

    func createFocusTraceDump() -> String {
        let events = createFocusTrace.snapshot()
        guard !events.isEmpty else { return "none" }
        return events
            .map { "\($0.timestamp.ISO8601Format()) \($0.description)" }
            .joined(separator: "\n")
    }

    func managedReplacementTraceDump() -> String {
        let events = managedReplacementTrace.snapshot()
        guard !events.isEmpty else { return "none" }
        return events
            .map {
                "uptime=\(String(format: "%.3f", $0.timestamp)) pid=\($0.pid)"
                    + " workspace=\($0.workspaceId.uuidString) \(String(describing: $0.kind))"
            }
            .joined(separator: "\n")
    }

    private func managedReplacementCurrentUptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
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
        managedReplacementTrace.append(event)

        if Self.managedReplacementTraceLoggingEnabled {
            Log.ax.debug(
                "[ManagedReplacement] pid=\(key.pid) workspace=\(key.workspaceId.uuidString) kind=\(String(describing: kind))"
            )
        }
    }

    private func managedReplacementFocusKey(_ key: ManagedReplacementKey) -> ManagedReplacementFocusKey {
        ManagedReplacementFocusKey(pid: key.pid, workspaceId: key.workspaceId)
    }

    private func managedReplacementFocusKey(
        pid: pid_t,
        workspaceId: WorkspaceDescriptor.ID
    ) -> ManagedReplacementFocusKey {
        ManagedReplacementFocusKey(pid: pid, workspaceId: workspaceId)
    }

    private func selectedNiriWindowToken(
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        guard let controller else { return nil }
        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        guard let selectedNodeId = state.selectedNodeId else { return nil }
        return controller.workspaceManager.layoutTopology(for: workspaceId).token(for: selectedNodeId)
    }

    private func niriManagedFocusAnchor(
        for key: ManagedReplacementFocusKey
    ) -> WindowToken? {
        guard let controller else { return nil }
        let topology = controller.workspaceManager.layoutTopology(for: key.workspaceId)

        func eligible(_ token: WindowToken?) -> Bool {
            guard let token,
                  token.pid == key.pid,
                  let entry = controller.workspaceManager.entry(for: token),
                  entry.workspaceId == key.workspaceId,
                  entry.mode == .tiling,
                  topology.containsNiriWindow(token)
            else {
                return false
            }
            return true
        }

        if let selected = selectedNiriWindowToken(in: key.workspaceId),
           eligible(selected)
        {
            return selected
        }

        if let focusedToken = controller.workspaceManager.focusedToken,
           eligible(focusedToken)
        {
            return focusedToken
        }

        return nil
    }

    private func armManagedReplacementFocusTransaction(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller else { return }
        if let open = controller.intentLedger.openReplacementFocusIntent(pid: token.pid, workspaceId: workspaceId) {
            controller.intentLedger.updateReplacementFocus(id: open.id) { payload in
                payload.isBurstOpen = true
                payload.protectedTokens.insert(token)
            }
            return
        }

        let key = managedReplacementFocusKey(pid: token.pid, workspaceId: workspaceId)
        guard let anchor = niriManagedFocusAnchor(for: key) else { return }
        _ = controller.intentLedger.registerReplacementFocus(
            ReplacementFocusPayload(
                pid: token.pid,
                workspaceId: workspaceId,
                anchorToken: anchor,
                protectedTokens: [anchor, token],
                isBurstOpen: true
            )
        )
        cancelSameAppCloseProbe(matchingFocusedToken: anchor, reason: "managed_replacement_focus_transaction")
    }

    private func markManagedReplacementFocusBurstClosed(for key: ManagedReplacementKey) {
        guard let controller,
              let open = controller.intentLedger.openReplacementFocusIntent(pid: key.pid, workspaceId: key.workspaceId)
        else {
            return
        }
        controller.intentLedger.updateReplacementFocus(id: open.id) { payload in
            payload.isBurstOpen = false
        }
    }

    private func rekeyManagedReplacementFocusTransaction(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller,
              let open = controller.intentLedger.openReplacementFocusIntent(pid: oldToken.pid, workspaceId: workspaceId)
        else {
            return
        }
        controller.intentLedger.updateReplacementFocus(id: open.id) { payload in
            payload.rekey(from: oldToken, to: newToken)
            payload.protectedTokens.insert(newToken)
            payload.pid = newToken.pid
        }
    }

    private func clearManagedReplacementFocusTransaction(
        for key: ManagedReplacementFocusKey,
        reason _: String
    ) {
        guard let controller,
              let open = controller.intentLedger.openReplacementFocusIntent(pid: key.pid, workspaceId: key.workspaceId)
        else {
            return
        }
        _ = controller.intentLedger.cancel(id: open.id)
    }

    private func clearManagedReplacementFocusTransaction(
        containing token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        reason: String
    ) {
        guard let transaction = managedReplacementFocusTransaction(for: token, workspaceId: workspaceId),
              transaction.protects(token)
        else {
            return
        }
        clearManagedReplacementFocusTransaction(
            for: managedReplacementFocusKey(pid: token.pid, workspaceId: workspaceId),
            reason: reason
        )
    }

    private func clearManagedReplacementFocusTransactions(
        pid: pid_t,
        reason _: String
    ) {
        guard let controller else { return }
        for intent in controller.intentLedger.openReplacementFocusIntents(pid: pid) {
            _ = controller.intentLedger.cancel(id: intent.id)
        }
    }

    private func managedReplacementFocusTransaction(
        for token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> ReplacementFocusPayload? {
        guard let controller,
              let open = controller.intentLedger.openReplacementFocusIntent(pid: token.pid, workspaceId: workspaceId),
              case let .replacementFocus(payload) = open.kind
        else {
            return nil
        }
        return payload
    }

    private func isProtectedManagedReplacementFocus(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        managedReplacementFocusTransaction(for: token, workspaceId: workspaceId)?.protects(token) == true
    }

    private func completeManagedReplacementFocusTransactionIfNeeded(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller,
              let open = controller.intentLedger.openReplacementFocusIntent(pid: token.pid, workspaceId: workspaceId),
              case let .replacementFocus(payload) = open.kind,
              payload.protects(token),
              !payload.isBurstOpen
        else {
            return
        }
        _ = controller.intentLedger.confirm(id: open.id)
    }

    private func handleFrameChanged(windowId: UInt32) {
        guard let controller else { return }
        guard !controller.isOwnedWindow(windowNumber: Int(windowId)) else { return }
        if let trackedEntry = controller.workspaceManager.entry(forWindowId: Int(windowId)),
           trackedEntry.mode == .tiling,
           controller.niriLayoutHandler.hasScrollAnimation(for: trackedEntry.workspaceId)
        {
            return
        }
        let windowServerToken = resolveWindowToken(windowId)
        let resolvedToken = resolveTrackedToken(
            windowId,
            resolvedWindowToken: windowServerToken
        )
        let focusedObservedFrame = observedFrameForFocusedFrameChange(
            windowId: windowId,
            windowServerToken: windowServerToken,
            resolvedToken: resolvedToken
        )
        guard let token = resolvedToken else { return }
        guard let entry = controller.workspaceManager.entry(for: token) else { return }

        guard isWindowDisplayable(token: token) else { return }

        if entry.mode == .floating {
            if let frame = focusedObservedFrame ?? observedFrame(for: entry) {
                if shouldSuppressFrameChangedRelayout(for: entry, observedFrame: frame) {
                    return
                }
                controller.workspaceManager.updateFloatingGeometry(frame: frame, for: token)
            }
            return
        }

        if controller.isInteractiveGestureActive {
            return
        }

        if controller.niriLayoutHandler.hasScrollAnimation(for: entry.workspaceId) {
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

        controller.layoutRefreshController.requestRelayout(
            reason: .axWindowChanged,
            affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    private func shouldSuppressFrameChangedRelayout(
        for entry: WindowState,
        observedFrame: CGRect?
    ) -> Bool {
        guard let controller else { return false }
        if controller.axManager.shouldSuppressFrameChangeRelayout(
            for: entry.windowId,
            observedFrame: observedFrame
        ) {
            return true
        }
        return false
    }

    private func observedFrameForFocusedFrameChange(
        windowId: UInt32,
        windowServerToken: WindowToken?,
        resolvedToken: WindowToken?
    ) -> CGRect? {
        guard let controller else { return nil }
        guard let target = controller.workspaceManager.renderableFocusToken,
              let entry = controller.workspaceManager.entry(for: target)
        else { return nil }

        if let windowServerToken {
            guard windowServerToken == target else { return nil }
        } else {
            guard resolvedToken == target,
                  entry.mode == .floating
            else { return nil }
            if needsFocusedAXConfirmationForUnresolvedFrameChange(entry),
               focusedWindowToken(for: target.pid) != target
            {
                return nil
            }
        }

        guard controller.axManager.pendingFrameWrite(for: entry.windowId) == nil else { return nil }
        guard let frame = observedFrame(for: entry) else { return nil }
        return frame
    }

    private func needsFocusedAXConfirmationForUnresolvedFrameChange(_ entry: WindowState) -> Bool {
        guard let controller else { return true }
        return entry.layoutReason == .nativeFullscreen
            || controller.workspaceManager.nativeFullscreenRecord(for: entry.token) != nil
    }

    private func observedFrame(for entry: WindowState) -> CGRect? {
        observedFrame(for: entry.axRef)
    }

    private func observedFrame(for axRef: AXWindowRef) -> CGRect? {
        AXWindowService.framePreferFast(axRef)
            ?? (try? AXWindowService.frame(axRef))
    }

    private func handleCGSWindowDestroyed(windowId: UInt32) {
        if resolveWindowInfo(windowId) != nil {
            return
        }
        if let controller,
           let entry = controller.workspaceManager.entry(forWindowId: Int(windowId)),
           controller.workspaceManager.hiddenState(for: entry.token) != nil
        {
            return
        }
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
            if isOwnProcessPid(pid_t(windowInfo.pid)) {
                cancelCreatedWindowRetry(windowId: windowId)
                discardCreatePlacementContext(windowId: windowId)
                continue
            }
            let token = WindowToken(pid: pid_t(windowInfo.pid), windowId: Int(windowId))
            if controller.workspaceManager.entry(for: token) != nil {
                discardCreatePlacementContext(windowId: windowId)
                continue
            }
            if shouldDeferCreateForInactiveNativeSpace(liveCreateSpace(for: windowId)) {
                deferCreatedWindow(windowId)
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
            if completeLiveStructuralReplacementCreate(candidate) {
                continue
            }
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
            let observedFrame = AXWindowService.framePreferFast(candidate.axRef)
                ?? (try? AXWindowService.frame(candidate.axRef))
            let preferredMonitor = controller.workspaceManager.monitor(for: trackedEntry.workspaceId)

            if let observedFrame {
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

        let liveTrackedEntry = controller.workspaceManager.entry(for: trackedToken) ?? trackedEntry
        if let floatingTargetFrame,
           shouldApplyFloatingCreateFrameImmediately(for: liveTrackedEntry.workspaceId)
        {
            scheduleFloatingCreateFrameApplication(
                floatingTargetFrame,
                token: trackedToken,
                pid: liveTrackedEntry.pid,
                windowId: liveTrackedEntry.windowId,
                workspaceId: liveTrackedEntry.workspaceId
            )
        } else {
            scheduleAXContextWarmup(for: liveTrackedEntry.pid)
        }
        if liveTrackedEntry.mode == .floating {
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
        let owner = nextPostCreateLifecycleVerificationOwner
        nextPostCreateLifecycleVerificationOwner &+= 1
        pendingPostCreateLifecycleVerificationOwners[token] = owner
        let task = Task { @MainActor [weak self] in
            defer { self?.finishPostCreateLifecycleVerification(for: token, owner: owner) }
            do {
                try await Task.sleep(for: Self.postCreateLifecycleVerificationDelay)
            } catch {
                return
            }
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
        pendingPostCreateLifecycleVerificationOwners[token] = nil
    }

    private func resetPostCreateLifecycleVerificationState() {
        for (_, task) in pendingPostCreateLifecycleVerificationTasks {
            task.cancel()
        }
        pendingPostCreateLifecycleVerificationTasks.removeAll()
        pendingPostCreateLifecycleVerificationOwners.removeAll()
        nextPostCreateLifecycleVerificationOwner = 1
    }

    private func finishPostCreateLifecycleVerification(for token: WindowToken, owner: UInt64) {
        guard pendingPostCreateLifecycleVerificationOwners[token] == owner else { return }
        pendingPostCreateLifecycleVerificationOwners[token] = nil
        pendingPostCreateLifecycleVerificationTasks[token] = nil
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
        let plannedSeq = controller.workspaceManager.worldSeq

        if canApplySynchronously {
            applyFloatingCreateFrame(
                targetFrame,
                token: token,
                pid: pid,
                windowId: windowId,
                workspaceId: workspaceId,
                plannedSeq: plannedSeq
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
                        workspaceId: workspaceId,
                        plannedSeq: plannedSeq
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
                workspaceId: workspaceId,
                plannedSeq: plannedSeq
            )
            if self.controller?.axManager.recentFrameWriteFailure(for: windowId) == .contextUnavailable {
                await self.warmAXContextIfNeeded(for: pid)
                self.applyFloatingCreateFrame(
                    targetFrame,
                    token: token,
                    pid: pid,
                    windowId: windowId,
                    workspaceId: workspaceId,
                    plannedSeq: plannedSeq
                )
            }
        }
    }

    private func applyFloatingCreateFrame(
        _ targetFrame: CGRect,
        token: WindowToken,
        pid: pid_t,
        windowId: Int,
        workspaceId: WorkspaceDescriptor.ID,
        plannedSeq: UInt64
    ) {
        guard let controller,
              controller.workspaceManager.entry(for: token)?.workspaceId == workspaceId,
              controller.workspaceManager.isSeqCurrent(
                  plannedSeq,
                  for: workspaceId,
                  domains: .layoutCommit
              ),
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
        let focusedTokenBefore = controller.workspaceManager.focusedToken

        cancelPostCreateLifecycleVerification(for: token)
        controller.axManager.removeWindowState(pid: token.pid, windowId: token.windowId)
        if handleNativeFullscreenDestroy(token) {
            return
        }

        let shouldRecoverFocus = token == focusedTokenBefore
        let closeRecoveryArmed: Bool
        if shouldRecoverFocus, let workspaceId = affectedWorkspaceId {
            closeRecoveryArmed = beginWindowCloseFocusRecovery(in: workspaceId, closedToken: token)
        } else {
            _ = activeWindowCloseFocusRecoveryWorkspaceId()
            closeRecoveryArmed = false
        }
        cancelSameAppCloseProbe(matchingFocusedToken: token, reason: "focused_token_removed")

        clearManagedFocusState(matching: token, workspaceId: affectedWorkspaceId)

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
        controller.workspaceManager.clearNonManagedFocusTarget(matching: token)

        if let wsId = affectedWorkspaceId {
            controller.layoutRefreshController.requestWindowRemoval(
                workspaceId: wsId,
                layoutType: layoutType,
                removedNodeId: removedNodeId,
                niriOldFrames: oldFrames,
                shouldRecoverFocus: shouldRecoverFocus,
                allowsPreferredRecoveryToken: closeRecoveryArmed
            )
        }
        scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(token.pid)])
    }

    private func beginWindowCloseFocusRecovery(
        in workspaceId: WorkspaceDescriptor.ID,
        closedToken: WindowToken
    ) -> Bool {
        guard let controller else { return false }
        guard isWorkspaceActive(workspaceId) else {
            endWindowCloseFocusRecovery(reason: "inactive_workspace")
            return false
        }

        windowCloseFocusRecoveryContext = WindowCloseFocusRecoveryContext(
            workspaceId: workspaceId,
            closedToken: closedToken,
            expiresAt: Date().addingTimeInterval(Self.windowCloseFocusRecoveryDuration)
        )
        controller.focusPolicyEngine.beginLease(
            owner: .windowCloseFocusRecovery,
            reason: "window_close_focus_recovery",
            suppressesFocusFollowsMouse: true,
            duration: Self.windowCloseFocusRecoveryDuration,
            notify: false
        )
        return true
    }

    private func activeWindowCloseFocusRecoveryWorkspaceId() -> WorkspaceDescriptor.ID? {
        guard let context = windowCloseFocusRecoveryContext else { return nil }
        guard context.expiresAt > Date(), isWorkspaceActive(context.workspaceId) else {
            endWindowCloseFocusRecovery(reason: "expired_or_inactive")
            return nil
        }
        return context.workspaceId
    }

    private func endWindowCloseFocusRecovery(
        matching workspaceId: WorkspaceDescriptor.ID? = nil,
        reason: String = "end"
    ) {
        if let workspaceId, windowCloseFocusRecoveryContext?.workspaceId != workspaceId {
            return
        }
        guard windowCloseFocusRecoveryContext != nil else { return }
        windowCloseFocusRecoveryContext = nil
        controller?.focusPolicyEngine.endLease(owner: .windowCloseFocusRecovery, notify: false)
    }

    private func shouldSuppressObservedActivationDuringWindowCloseRecovery(
        observedToken: WindowToken,
        requestDisposition: ActivationRequestDisposition
    ) -> Bool {
        guard activeWindowCloseFocusRecoveryWorkspaceId() != nil,
              let context = windowCloseFocusRecoveryContext,
              context.closedToken.pid == observedToken.pid
        else {
            return false
        }

        if case .matchesActiveRequest = requestDisposition {
            return false
        }
        return true
    }

    private func shouldDeferSameAppActivationForCloseProbe(
        entry observedEntry: WindowState,
        requestDisposition: ActivationRequestDisposition,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) -> Bool {
        guard source == .focusedWindowChanged, origin == .external else { return false }
        guard case .unrelatedNoRequest = requestDisposition else { return false }
        guard let controller else { return false }
        guard !hasRecentMouseFocusIntent(for: observedEntry.token) else { return false }
        guard observedEntry.mode == .tiling,
              controller.niriEngine?.findNode(for: observedEntry.token) != nil
        else {
            return false
        }

        guard let focusedToken = controller.workspaceManager.focusedToken,
              focusedToken != observedEntry.token,
              focusedToken.pid == observedEntry.pid,
              let focusedEntry = controller.workspaceManager.entry(for: focusedToken),
              focusedEntry.mode == .tiling,
              controller.niriEngine?.findNode(for: focusedToken) != nil,
              let focusedWorkspace = controller.workspaceManager.descriptor(for: focusedEntry.workspaceId)
        else {
            return false
        }
        switch controller.settings.layoutType(for: focusedWorkspace.name) {
        case .niri,
             .defaultLayout:
            break
        case .dwindle:
            return false
        }

        deferSameAppCloseProbe(
            focusedToken: focusedToken,
            observedToken: observedEntry.token,
            source: source
        )
        return true
    }

    private func shouldSuppressObservedManagedActivation(
        entry observedEntry: WindowState,
        requestDisposition: ActivationRequestDisposition,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) -> Bool {
        if hasRecentMouseFocusIntent(for: observedEntry.token) {
            clearManagedReplacementFocusTransaction(
                for: managedReplacementFocusKey(
                    pid: observedEntry.pid,
                    workspaceId: observedEntry.workspaceId
                ),
                reason: "mouse_focus_intent"
            )
            return false
        }

        if shouldSuppressObservedActivationDuringManagedReplacementFocusTransaction(
            entry: observedEntry,
            requestDisposition: requestDisposition,
            source: source,
            origin: origin
        ) {
            return true
        }

        if shouldDeferSameAppActivationForCloseProbe(
            entry: observedEntry,
            requestDisposition: requestDisposition,
            source: source,
            origin: origin
        ) {
            return true
        }

        if shouldSuppressObservedActivationDuringWindowCloseRecovery(
            observedToken: observedEntry.token,
            requestDisposition: requestDisposition
        ) {
            return true
        }
        return false
    }

    private func shouldSuppressObservedActivationDuringManagedReplacementFocusTransaction(
        entry observedEntry: WindowState,
        requestDisposition: ActivationRequestDisposition,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) -> Bool {
        let key = managedReplacementFocusKey(pid: observedEntry.pid, workspaceId: observedEntry.workspaceId)
        guard let transaction = managedReplacementFocusTransaction(
            for: observedEntry.token,
            workspaceId: observedEntry.workspaceId
        ) else { return false }

        guard case .unrelatedNoRequest = requestDisposition else {
            if !transaction.protects(observedEntry.token) {
                clearManagedReplacementFocusTransaction(for: key, reason: "managed_focus_request")
            }
            return false
        }

        guard source == .focusedWindowChanged else {
            clearManagedReplacementFocusTransaction(for: key, reason: "app_activation")
            return false
        }

        guard transaction.suppressesUnrelatedActivation(
            token: observedEntry.token,
            workspaceId: observedEntry.workspaceId
        ) else {
            return false
        }

        cancelSameAppCloseProbe(
            matchingFocusedToken: transaction.anchorToken,
            reason: "managed_replacement_focus_transaction"
        )
        return true
    }

    private func shouldSuppressNonManagedFallbackDuringWindowCloseRecovery(
        observedToken: WindowToken,
        requestDisposition: ActivationRequestDisposition,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) -> Bool {
        guard activeWindowCloseFocusRecoveryWorkspaceId() != nil,
              windowCloseFocusRecoveryContext?.closedToken.pid == observedToken.pid
        else {
            return false
        }

        if case .matchesActiveRequest = requestDisposition {
            return false
        }
        return true
    }

    private func deferSameAppCloseProbe(
        focusedToken: WindowToken,
        observedToken: WindowToken,
        source: ActivationEventSource
    ) {
        guard let controller else { return }
        if let open = controller.intentLedger.openSameAppCloseProbe(),
           open.payload.focusedToken == focusedToken,
           open.payload.observedToken == observedToken
        {
            return
        }

        cancelSameAppCloseProbe()
        let intent = controller.intentLedger.registerSameAppCloseProbe(
            SameAppCloseProbePayload(
                focusedToken: focusedToken,
                observedToken: observedToken,
                source: source
            )
        )
        controller.deadlineWheel.schedule(intentId: intent.id, after: Self.sameAppCloseProbeDelay)
    }

    private func handleSameAppCloseProbeDeadline(_ payload: SameAppCloseProbePayload) {
        guard let controller else { return }
        guard controller.workspaceManager.focusedToken == payload.focusedToken,
              controller.workspaceManager.entry(for: payload.focusedToken) != nil,
              controller.intentLedger.activeManagedRequest == nil
        else {
            return
        }
        handleAppActivation(
            pid: payload.observedToken.pid,
            source: payload.source,
            origin: .probe
        )
    }

    private func cancelSameAppCloseProbe(
        matchingFocusedToken token: WindowToken? = nil,
        reason _: String = "cancel"
    ) {
        guard let controller,
              let open = controller.intentLedger.openSameAppCloseProbe()
        else {
            return
        }
        if let token, open.payload.focusedToken != token {
            return
        }
        _ = controller.intentLedger.cancel(id: open.intent.id)
        controller.deadlineWheel.cancel(intentId: open.intent.id)
    }

    func noteMouseFocusIntent(token: WindowToken) {
        recentMouseFocusIntent = RecentMouseFocusIntent(
            token: token,
            expiresAt: Date().addingTimeInterval(Self.mouseFocusIntentDuration)
        )
        if let controller,
           let entry = controller.workspaceManager.entry(for: token)
        {
            clearManagedReplacementFocusTransaction(
                for: managedReplacementFocusKey(pid: token.pid, workspaceId: entry.workspaceId),
                reason: "mouse_focus_intent"
            )
        }
        if let open = controller?.intentLedger.openSameAppCloseProbe(),
           open.payload.observedToken == token
        {
            cancelSameAppCloseProbe(reason: "mouse_focus_intent")
        }
    }

    func hasRecentMouseFocusIntent(for token: WindowToken) -> Bool {
        guard let intent = recentMouseFocusIntent else { return false }
        guard intent.expiresAt > Date() else {
            recentMouseFocusIntent = nil
            return false
        }
        return intent.token == token
    }

    private func isWorkspaceActive(_ workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller,
              let monitorId = controller.workspaceManager.monitorId(for: workspaceId)
        else {
            return false
        }
        return controller.workspaceManager.activeWorkspace(on: monitorId)?.id == workspaceId
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

        if focusedAdmissionReadmitExhaustedToken == nil {
            pendingFocusedAdmissionReadmitTask?.cancel()
            pendingFocusedAdmissionReadmitTask = nil
        }

        if source != .focusedWindowChanged {
            controller.focusPolicyEngine.beginLease(
                owner: .nativeAppSwitch,
                reason: source.rawValue,
                suppressesFocusFollowsMouse: true,
                duration: 0.4
            )
        }

        if pid == getpid(), (controller.hasFrontmostOwnedWindow || controller.hasVisibleOwnedWindow) {
            if let activeRequest = controller.intentLedger.activeManagedRequest, activeRequest.token.pid == pid {
                _ = controller.intentLedger.cancelManagedRequest(requestId: activeRequest.requestId)
                _ = controller.workspaceManager.cancelManagedFocusRequest(
                    matching: activeRequest.token,
                    workspaceId: activeRequest.workspaceId,
                    requestId: activeRequest.requestId
                )
            }
            _ = controller.workspaceManager.enterNonManagedFocus(
                preserveFocusedToken: true
            )
            return
        }

        controller.factResolver.resolveActivationFacts(pid: pid, source: source, origin: origin)
    }

    func handleIntentExpired(_ intentId: IntentID) {
        guard let controller else { return }
        guard let intent = controller.intentLedger.openIntent(id: intentId) else { return }

        switch intent.kind {
        case .activateApp,
             .replacementFocus:
            _ = controller.intentLedger.markExpired(id: intentId)

        case let .focusPolicyLease(owner):
            _ = controller.intentLedger.markExpired(id: intentId)
            controller.focusPolicyEngine.handleLeaseDeadlineExpired(owner: owner, intentId: intentId)

        case let .sameAppCloseProbe(payload):
            _ = controller.intentLedger.markExpired(id: intentId)
            handleSameAppCloseProbeDeadline(payload)

        case .focusWindow:
            guard let liveRequest = controller.intentLedger.activeManagedRequest(requestId: intentId) else {
                _ = controller.intentLedger.markExpired(id: intentId)
                return
            }
            controller.retryManagedFocusFronting(liveRequest)
            handleAppActivation(
                pid: liveRequest.token.pid,
                source: liveRequest.lastActivationSource ?? .focusedWindowChanged,
                origin: .retry
            )
        }
    }

    func handleActivationFactsResolved(_ facts: ActivationFacts) {
        guard let controller, controller.hasStartedServices else { return }
        if let issuedAtSeq = controller.intentLedger.newestFocusIntentIssuedAtSeq(),
           issuedAtSeq > facts.requestedAtSeq
        {
            return
        }

        let pid = facts.pid
        let source = facts.source
        let origin = facts.origin
        let activeRequest = controller.intentLedger.activeManagedRequest
        let axRef = facts.focusedWindow?.axRef
        let observedToken = axRef.map { WindowToken(pid: pid, windowId: $0.windowId) }
        let requestDisposition = activationRequestDisposition(
            for: pid,
            token: observedToken,
            activeRequest: activeRequest
        )

        guard let axRef, let focusedWindow = facts.focusedWindow else {
            controller.workspaceManager.setSystemModalFocus(nil)
            handleMissingFocusedWindow(
                pid: pid,
                source: source,
                origin: origin,
                requestDisposition: requestDisposition
            )
            return
        }
        let token = WindowToken(pid: pid, windowId: axRef.windowId)
        controller.workspaceManager.setSystemModalFocus(focusedWindow.isSystemModalSurface ? token : nil)

        let appFullscreen = focusedWindow.isFullscreen

        if let entry = controller.workspaceManager.entry(for: token) {
            if appFullscreen {
                suspendManagedWindowForNativeFullscreen(entry)
                return
            }
            _ = restoreManagedWindowFromNativeFullscreen(entry)
            let entry = controller.workspaceManager.entry(for: token) ?? entry
            let wsId = entry.workspaceId

            let targetMonitor = controller.workspaceManager.monitor(for: wsId)
            let isWorkspaceActive = targetMonitor.map { monitor in
                controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == wsId
            } ?? false

            if shouldSuppressObservedManagedActivation(
                entry: entry,
                requestDisposition: requestDisposition,
                source: source,
                origin: origin
            ) {
                if case let .conflictsWithPendingRequest(request) = requestDisposition {
                    continueManagedFocusRequest(
                        request,
                        source: source,
                        origin: origin,
                        reason: .pendingFocusMismatch
                    )
                }
                return
            }

            switch requestDisposition {
            case .matchesActiveRequest:
                break
            case let .conflictsWithPendingRequest(request):
                if shouldHonorObservedFocusOverPendingRequest(
                    observedToken: token,
                    source: source,
                    origin: origin
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

            endWindowCloseFocusRecovery(matching: wsId, reason: "accepted_managed_activation")
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

        let admissionAttempt = admitFocusedWindowBeforeNonManagedFallback(
            token: token,
            axRef: axRef,
            source: source,
            origin: origin,
            requestDisposition: requestDisposition,
            appFullscreen: appFullscreen
        )
        if admissionAttempt == .handled {
            return
        }

        if shouldSuppressNonManagedFallbackDuringWindowCloseRecovery(
            observedToken: token,
            requestDisposition: requestDisposition,
            source: source,
            origin: origin
        ) {
            if case let .conflictsWithPendingRequest(request) = requestDisposition {
                continueManagedFocusRequest(
                    request,
                    source: source,
                    origin: origin,
                    reason: .pendingFocusUnmanagedToken
                )
            }
            return
        }

        switch requestDisposition {
        case let .matchesActiveRequest(request),
             let .conflictsWithPendingRequest(request):
            if shouldHonorObservedFocusOverPendingRequest(
                observedToken: token,
                source: source,
                origin: origin
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

        if admissionAttempt == .admissionPending,
           scheduleFocusedAdmissionReadmit(token: token, source: source, origin: origin)
        {
            return
        }

        _ = controller.workspaceManager.enterNonManagedFocus(
            target: token
        )
        controller.surfaceReconciler.noteRestackOccurred()

        recordNiriCreateFocusTrace(
            .init(
                kind: .nonManagedFallbackEntered(
                    pid: pid,
                    source: source
                )
            )
        )
    }

    private enum FocusedAdmissionAttempt: Equatable {
        case handled
        case admissionPending
        case rejected
    }

    private func admitFocusedWindowBeforeNonManagedFallback(
        token: WindowToken,
        axRef: AXWindowRef,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        requestDisposition: ActivationRequestDisposition,
        appFullscreen: Bool
    ) -> FocusedAdmissionAttempt {
        guard let controller,
              let windowId = UInt32(exactly: token.windowId)
        else {
            return .rejected
        }

        let windowInfo = resolveWindowInfo(windowId)
        guard let candidate = prepareCreateCandidate(
            windowId: windowId,
            windowInfo: windowInfo,
            fallbackToken: token,
            fallbackAXRef: axRef,
            createPlacementContext: createPlacementContextsByWindowId[windowId]
                ?? liveCreatePlacementContext(controller: controller)
        ) else {
            var admissionPending = pendingWindowStabilizationTasks[token] != nil
            if let windowInfo {
                if scheduleCreatedWindowRetryIfNeeded(
                    windowId: windowId,
                    pid: pid_t(windowInfo.pid)
                ) {
                    admissionPending = true
                }
                scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(pid_t(windowInfo.pid))])
            } else if scheduleCreatedWindowInfoRetryIfNeeded(windowId: windowId) {
                admissionPending = true
            }
            return admissionPending ? .admissionPending : .rejected
        }
        guard candidate.token == token else { return .rejected }

        cancelCreatedWindowRetry(windowId: windowId)
        if completeLiveStructuralReplacementCreate(candidate) {
            guard let entry = controller.workspaceManager.entry(for: candidate.token) else {
                return .handled
            }
            let targetMonitor = controller.workspaceManager.monitor(for: entry.workspaceId)
            let isWorkspaceActive = targetMonitor.map { monitor in
                controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == entry.workspaceId
            } ?? false
            return completeFocusedManagedAdmission(
                entry: entry,
                isWorkspaceActive: isWorkspaceActive,
                activation: .init(
                    source: source,
                    origin: origin,
                    appFullscreen: appFullscreen,
                    request: .init(requestDisposition)
                ),
                requestDisposition: requestDisposition
            ) ? .handled : .rejected
        }
        if shouldDelayManagedReplacementCreate(candidate) {
            enqueueManagedReplacementCreate(
                candidate,
                focusedActivation: .init(
                    source: source,
                    origin: origin,
                    appFullscreen: appFullscreen,
                    request: .init(requestDisposition)
                )
            )
            return .handled
        }

        trackPreparedCreate(candidate)
        guard let entry = controller.workspaceManager.entry(for: candidate.token) else {
            return .handled
        }

        let targetMonitor = controller.workspaceManager.monitor(for: entry.workspaceId)
        let isWorkspaceActive = targetMonitor.map { monitor in
            controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == entry.workspaceId
        } ?? false

        return completeFocusedManagedAdmission(
            entry: entry,
            isWorkspaceActive: isWorkspaceActive,
            activation: .init(
                source: source,
                origin: origin,
                appFullscreen: appFullscreen,
                request: .init(requestDisposition)
            ),
            requestDisposition: requestDisposition
        ) ? .handled : .rejected
    }

    private func scheduleFocusedAdmissionReadmit(
        token: WindowToken,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) -> Bool {
        guard let controller,
              focusedAdmissionReadmitExhaustedToken != token,
              controller.workspaceManager.focusedToken != nil,
              !controller.workspaceManager.isNonManagedFocusActive
        else {
            return false
        }

        pendingFocusedAdmissionReadmitTask?.cancel()
        pendingFocusedAdmissionReadmitTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.focusedAdmissionReadmitDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.pendingFocusedAdmissionReadmitTask = nil
            self.focusedAdmissionReadmitExhaustedToken = token
            self.handleAppActivation(pid: token.pid, source: source, origin: origin)
            self.focusedAdmissionReadmitExhaustedToken = nil
        }
        return true
    }

    @discardableResult
    private func completeFocusedManagedAdmission(
        entry: WindowState,
        isWorkspaceActive: Bool,
        activation: PendingFocusedManagedActivation,
        requestDisposition: ActivationRequestDisposition,
        bindCurrentPidRequest: Bool = true
    ) -> Bool {
        if shouldSuppressObservedManagedActivation(
            entry: entry,
            requestDisposition: requestDisposition,
            source: activation.source,
            origin: activation.origin
        ) {
            if case let .conflictsWithPendingRequest(request) = requestDisposition {
                continueManagedFocusRequest(
                    request,
                    source: activation.source,
                    origin: activation.origin,
                    reason: .pendingFocusUnmanagedToken
                )
            }
            return true
        }

        switch requestDisposition {
        case .matchesActiveRequest:
            break
        case let .conflictsWithPendingRequest(request):
            if shouldHonorObservedFocusOverPendingRequest(
                observedToken: entry.token,
                source: activation.source,
                origin: activation.origin
            ) {
                clearManagedFocusState(
                    matching: request.token,
                    workspaceId: request.workspaceId
                )
                handleManagedAppActivation(
                    entry: entry,
                    isWorkspaceActive: isWorkspaceActive,
                    appFullscreen: activation.appFullscreen,
                    source: activation.source,
                    confirmRequest: true,
                    origin: activation.origin,
                    activeRequestId: nil,
                    bindCurrentPidRequest: false
                )
                return true
            }
            continueManagedFocusRequest(
                request,
                source: activation.source,
                origin: activation.origin,
                reason: .pendingFocusUnmanagedToken
            )
            return true
        case .unrelatedNoRequest:
            guard shouldHandleObservedManagedActivationWithoutPendingRequest(
                source: activation.source,
                origin: activation.origin,
                isWorkspaceActive: isWorkspaceActive
            ) else { return true }
        }

        handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: isWorkspaceActive,
            appFullscreen: activation.appFullscreen,
            source: activation.source,
            confirmRequest: true,
            origin: activation.origin,
            activeRequestId: activation.request.requestId,
            bindCurrentPidRequest: bindCurrentPidRequest
        )
        return true
    }

    func handleManagedAppActivation(
        entry: WindowState,
        isWorkspaceActive: Bool,
        appFullscreen: Bool,
        source: ActivationEventSource = .focusedWindowChanged,
        confirmRequest: Bool? = nil,
        origin: ActivationCallOrigin = .external,
        activeRequestId: UInt64? = nil,
        bindCurrentPidRequest: Bool = true
    ) {
        guard let controller else { return }
        if appFullscreen {
            suspendManagedWindowForNativeFullscreen(entry)
            return
        }

        _ = restoreManagedWindowFromNativeFullscreen(entry)
        let entry = controller.workspaceManager.entry(for: entry.token) ?? entry
        let wsId = entry.workspaceId
        let monitorId = controller.workspaceManager.monitorId(for: wsId)
        let shouldActivateWorkspace = !isWorkspaceActive && !controller.isTransferringWindow
        var activeRequest: ManagedFocusRequest?
        if let activeRequestId {
            activeRequest = controller.intentLedger.activeManagedRequest(requestId: activeRequestId)
        } else if bindCurrentPidRequest {
            activeRequest = controller.intentLedger.activeManagedRequest(for: entry.pid)
        } else {
            activeRequest = nil
        }
        let shouldConfirmRequest = confirmRequest ?? true

        if shouldConfirmRequest {
            if let request = activeRequest,
               !controller.workspaceManager.pendingManagedFocusMatches(
                   token: entry.token,
                   workspaceId: wsId,
                   requestId: request.requestId
               )
            {
                _ = controller.intentLedger.cancelManagedRequest(requestId: request.requestId)
                _ = controller.workspaceManager.cancelManagedFocusRequest(
                    matching: request.token,
                    workspaceId: request.workspaceId,
                    requestId: request.requestId
                )
                return
            }

            let confirmationRequestId = activeRequest?.requestId
            guard controller.workspaceManager.canConfirmManagedFocus(
                entry.token,
                in: wsId,
                requestId: confirmationRequestId
            ) else {
                return
            }

            _ = controller.workspaceManager.confirmManagedFocus(
                entry.token,
                in: wsId,
                onMonitor: monitorId,
                activateWorkspaceOnMonitor: shouldActivateWorkspace,
                requestId: confirmationRequestId
            )

            if let activeRequest {
                if activeRequest.token == entry.token {
                    _ = controller.intentLedger.confirmManagedRequest(
                        token: entry.token,
                        source: source
                    )
                } else {
                    _ = controller.intentLedger.cancelManagedRequest(requestId: activeRequest.requestId)
                    _ = controller.workspaceManager.cancelManagedFocusRequest(
                        matching: activeRequest.token,
                        workspaceId: activeRequest.workspaceId,
                        requestId: activeRequest.requestId
                    )
                }
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

        if let dwindleEngine = controller.dwindleEngine,
           let node = dwindleEngine.findNode(for: entry.token)
        {
            controller.workspaceManager.withEngineMutationScope {
                dwindleEngine.setSelectedNode(node, in: wsId)
            }
        }

        var preferredMouseFrame: CGRect?
        if let engine = controller.niriEngine,
           let node = engine.findNode(for: entry.token),
           let _ = controller.workspaceManager.monitor(for: wsId)
        {
            let preferredFrame = node.renderedFrame ?? node.frame
            preferredMouseFrame = preferredFrame
            var state = controller.workspaceManager.niriViewportState(for: wsId)
            let preserveActiveViewport = controller.workspaceManager.animationDriver.hasMotion(in: wsId)
            let preserveReplacementViewport = isProtectedManagedReplacementFocus(
                token: entry.token,
                workspaceId: wsId
            )
            controller.niriLayoutHandler.activateNode(
                node, in: wsId, state: &state,
                options: preserveReplacementViewport
                    ? .init(
                        ensureVisible: false,
                        preserveViewportAnchor: true,
                        layoutRefresh: isWorkspaceActive,
                        axFocus: false,
                        startAnimation: false
                    )
                    : preserveActiveViewport
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
                    rememberedFocusToken: nil,
                    plannedSeq: controller.workspaceManager.worldSeq
                )
            )
            if preserveReplacementViewport {
                completeManagedReplacementFocusTransactionIfNeeded(
                    token: entry.token,
                    workspaceId: wsId
                )
            }
        }

        controller.surfaceReconciler.noteRestackOccurred()
        if shouldActivateWorkspace, shouldConfirmRequest {
            controller.syncMonitorsToNiriEngine()
            controller.layoutRefreshController.commitWorkspaceTransition(
                reason: .appActivationTransition
            )
        }
        if shouldConfirmRequest,
           controller.moveMouseToFocusedWindowEnabled,
           !hasRecentMouseFocusIntent(for: entry.token),
           controller.intentLedger.allowsMouseToFocusedWarp(for: entry.token),
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
        controller?.workspaceManager.clearNonManagedFocusTarget(
            matching: WindowToken(pid: pid, windowId: windowId)
        )
    }

    @discardableResult
    private func suspendManagedWindowForNativeFullscreen(_ entry: WindowState) -> Bool {
        guard let controller else { return false }
        let changed = controller.workspaceManager.markNativeFullscreenSuspended(entry.token)
        if changed {
            requestNativeFullscreenRelayout(for: entry.token, fallback: entry.workspaceId)
        }
        return changed
    }

    private func requestNativeFullscreenRelayout(
        for token: WindowToken,
        fallback workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller else { return }
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .appActivationTransition,
            affectedWorkspaceIds: [
                controller.workspaceManager.workspace(for: token) ?? workspaceId
            ]
        )
    }

    private func handleNativeFullscreenDestroy(_ token: WindowToken) -> Bool {
        guard let controller,
              let entry = controller.workspaceManager.entry(for: token)
        else {
            return false
        }

        if let record = controller.workspaceManager.nativeFullscreenRecord(for: token) {
            guard record.currentToken == token else { return false }
        } else if !shouldPreserveNativeFullscreenDestroy(entry) {
            return false
        }

        _ = controller.workspaceManager.markNativeFullscreenSuspended(entry.token)
        clearManagedFocusState(matching: token, workspaceId: entry.workspaceId)
        requestNativeFullscreenRelayout(for: token, fallback: entry.workspaceId)
        return true
    }

    private func shouldPreserveNativeFullscreenDestroy(_ entry: WindowState) -> Bool {
        guard let controller else { return false }
        guard entry.mode == .tiling else { return false }
        guard controller.workspaceManager.focusedToken == entry.token else { return false }
        guard controller.workspaceManager.scratchpadToken() != entry.token else { return false }
        guard let descriptor = controller.workspaceManager.descriptor(for: entry.workspaceId) else { return false }
        guard controller.settings.layoutType(for: descriptor.name) != .dwindle else { return false }
        if entry.observedState.isNativeFullscreen {
            return true
        }
        if controller.workspaceManager.isWindowOnObservedNativeFullscreenSpace(entry.windowId) {
            return true
        }
        return AXWindowService.isFullscreenAttributeSet(entry.axRef)
    }

    @discardableResult
    private func restoreManagedWindowFromNativeFullscreen(_ entry: WindowState) -> Bool {
        guard let controller else { return false }
        let hadRecord = controller.workspaceManager.nativeFullscreenRecord(for: entry.token) != nil
        guard hadRecord || controller.workspaceManager.layoutReason(for: entry.token) == .nativeFullscreen else {
            return false
        }
        let restored = controller.workspaceManager.restoreNativeFullscreenRecord(for: entry.token) || hadRecord
        if restored {
            controller.layoutRefreshController.markNativeFullscreenRestoredForFrameApply(entry.token)
        }
        return restored
    }

    @discardableResult
    func rekeyManagedWindowIdentity(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> WindowState? {
        guard let controller else { return nil }

        guard let entry = controller.workspaceManager.rekeyWindow(
            from: oldToken,
            to: newToken,
            newAXRef: axRef,
            managedReplacementMetadata: managedReplacementMetadata
        )
        else {
            return nil
        }

        controller.intentLedger.rekeyManagedRequest(from: oldToken, to: newToken)
        controller.axManager.rekeyWindowState(
            pid: newToken.pid,
            oldWindowId: oldToken.windowId,
            newWindow: axRef
        )
        controller.rekeyScratchpadWindowResources(from: oldToken, to: newToken, axRef: axRef)
        controller.layoutRefreshController.rekeyPendingRevealTransaction(
            from: oldToken,
            to: newToken,
            entry: entry
        )
        AXWindowService.invalidateCachedTitles(windowIds: [UInt32(oldToken.windowId), windowId])
        subscribeToWindows([windowId])
        controller.requestWorkspaceBarRefresh()
        controller.surfaceReconciler.noteRestackOccurred()

        Task { @MainActor [weak self] in
            guard let self, let controller = self.controller else { return }
            if let app = NSRunningApplication(processIdentifier: newToken.pid) {
                _ = await controller.axManager.windowsForApp(app)
            }
        }

        return entry
    }

    func handleAppHidden(pid: pid_t) {
        guard let controller else { return }
        controller.hiddenAppPIDs.insert(pid)

        if let activeRequest = controller.intentLedger.activeManagedRequest,
           activeRequest.token.pid == pid
        {
            _ = controller.intentLedger.cancelManagedRequest(requestId: activeRequest.requestId)
            _ = controller.workspaceManager.cancelManagedFocusRequest(
                matching: activeRequest.token,
                workspaceId: activeRequest.workspaceId,
                requestId: activeRequest.requestId
            )
            controller.intentLedger.discardPendingFocus(activeRequest.token)
        }
        if controller.workspaceManager.renderableFocusToken?.pid == pid {
            _ = controller.workspaceManager.enterNonManagedFocus(
                preserveFocusedToken: true
            )
        }

        for entry in controller.workspaceManager.entries(forPid: pid) {
            controller.workspaceManager.setLayoutReason(.macosHiddenApp, for: entry.token)
        }
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appHidden)
    }

    func handleAppDeactivated(pid: pid_t) {
        guard let controller else { return }
        let workspaceManager = controller.workspaceManager
        workspaceManager.clearNonManagedFocusTarget(pid: pid)

        guard !workspaceManager.isNonManagedFocusActive,
              let focusedToken = workspaceManager.focusedToken,
              focusedToken.pid == pid,
              let entry = workspaceManager.entry(for: focusedToken),
              entry.mode == .floating
        else { return }

        workspaceManager.suppressFocusBorder(for: focusedToken)
    }

    func handleAppUnhidden(pid: pid_t) {
        guard let controller else { return }
        controller.hiddenAppPIDs.remove(pid)

        for entry in controller.workspaceManager.entries(forPid: pid) {
            if controller.workspaceManager.layoutReason(for: entry.token) == .macosHiddenApp {
                controller.workspaceManager.restoreFromNativeState(for: entry.token)
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
        if let controller {
            for intent in controller.intentLedger.openReplacementFocusIntents() {
                _ = controller.intentLedger.cancel(id: intent.id)
            }
        }
        nextManagedReplacementEventSequence = 0
    }

    func resetWindowStabilizationState() {
        for (_, task) in pendingWindowStabilizationTasks {
            task.cancel()
        }
        pendingWindowStabilizationTasks.removeAll()
    }

    private func prepareCreateCandidate(
        windowId: UInt32,
        windowInfo: WindowServerInfo?,
        fallbackToken: WindowToken? = nil,
        fallbackAXRef: AXWindowRef? = nil,
        createPlacementContext: WindowCreatePlacementContext? = nil
    ) -> PreparedCreate? {
        guard let controller else { return nil }
        let ownedWindow = controller.isOwnedWindow(windowNumber: Int(windowId))
        let windowInfoToken = windowInfo.map { WindowToken(pid: pid_t($0.pid), windowId: Int(windowId)) }
        let token = fallbackToken ?? windowInfoToken
        guard let token,
              token.windowId == Int(windowId)
        else {
            return nil
        }
        if controller.workspaceManager.entry(for: token) != nil {
            return nil
        }
        if ownedWindow {
            discardCreatePlacementContext(windowId: windowId)
            return nil
        }

        guard let axRef = fallbackAXRef?.windowId == Int(windowId)
            ? fallbackAXRef
            : resolveAXWindowRef(windowId: windowId, pid: token.pid)
        else {
            return nil
        }

        let app = NSRunningApplication(processIdentifier: token.pid)
        let bundleId = resolveBundleId(token.pid) ?? app?.bundleIdentifier
        let appFullscreen = AXWindowService.isFullscreen(axRef)
        let matchingWindowInfo = windowInfo.flatMap { pid_t($0.pid) == token.pid ? $0 : nil }
        let evaluation = controller.evaluateWindowDisposition(
            axRef: axRef,
            pid: token.pid,
            appFullscreen: appFullscreen,
            windowInfo: matchingWindowInfo
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
        let replacementMatch = structuralReplacementMatch(
            token: token,
            bundleId: resolvedBundleId,
            mode: trackedMode,
            facts: evaluation.facts
        )
        let inheritTrackedParentWorkspace = controller.shouldInheritTrackedParentWorkspace(for: evaluation)
        let placementFrame = evaluation.facts.windowServer?.frame ?? matchingWindowInfo?.frame
        let preferSameAppSiblingWorkspace = controller.shouldPreferSameAppSiblingWorkspace(
            for: evaluation,
            inheritTrackedParentWorkspace: inheritTrackedParentWorkspace
        )
        let placement = controller.resolveWorkspaceForNewWindow(
            workspaceName: evaluation.decision.workspaceName,
            axRef: axRef,
            pid: token.pid,
            parentWindowId: evaluation.facts.windowServer?.parentId,
            inheritTrackedParentWorkspace: inheritTrackedParentWorkspace,
            preferSameAppSiblingWorkspace: preferSameAppSiblingWorkspace,
            structuralReplacementWorkspaceId: replacementMatch?.workspaceId,
            restrictWorkspaceRuleToPlacementMonitor: trackedMode != .floating,
            createPlacementContext: createPlacementContext,
            windowFrame: placementFrame,
            fallbackWorkspaceId: controller.activeWorkspace()?.id
        )
        let workspaceId = placement.workspaceId
        recordCreatePlacementTrace(
            token: token,
            placement: placement,
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
            structuralReplacementMatch: replacementMatch,
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
        placement: WorkspacePlacementResolution,
        createPlacementContext: WindowCreatePlacementContext?,
        windowFrame: CGRect?,
        controller: WMController
    ) {
        recordNiriCreateFocusTrace(
            .init(
                kind: .createPlacementResolved(
                    token: token,
                    workspaceId: placement.workspaceId,
                    rung: placement.rung,
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
            cancelSameAppCloseProbe(matchingFocusedToken: resolvedToken, reason: "destroy_resolved")
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
              let target = controller.workspaceManager.nonManagedFocusToken
        else { return }

        let matchesResolvedToken = resolvedToken.map { $0 == target } ?? false
        let matchesPidHint = pidHint.map { $0 == target.pid && target.windowId == Int(windowId) } ?? false
        let matchesWindowId = target.windowId == Int(windowId)
        guard matchesResolvedToken || matchesPidHint || matchesWindowId else { return }

        controller.workspaceManager.clearNonManagedFocusTarget(matching: target)
    }

    private func processPreparedDestroy(_ candidate: PreparedDestroy) {
        handleRemoved(token: candidate.token)
        clearManagedReplacementFocusTransaction(
            containing: candidate.token,
            workspaceId: candidate.workspaceId,
            reason: "destroy_processed"
        )
    }

    private func shouldDelayManagedReplacementCreate(_ candidate: PreparedCreate) -> Bool {
        guard let _ = managedReplacementCorrelationPolicy(for: candidate.replacementMetadata) else {
            return false
        }

        let key = ManagedReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        if pendingManagedReplacementBursts[key] != nil {
            return true
        }

        return candidate.structuralReplacementMatch?.source == .pendingDestroy
    }

    private func completeLiveStructuralReplacementCreate(_ candidate: PreparedCreate) -> Bool {
        guard let match = candidate.structuralReplacementMatch,
              match.source == .liveInvisible
        else {
            return false
        }

        return rekeyManagedReplacement(from: match.token, to: candidate)
    }

    private func shouldDelayManagedReplacementDestroy(_ candidate: PreparedDestroy) -> Bool {
        managedReplacementCorrelationPolicy(for: candidate.replacementMetadata) != nil
    }

    private func enqueueManagedReplacementCreate(
        _ candidate: PreparedCreate,
        focusedActivation: PendingFocusedManagedActivation? = nil
    ) {
        guard let policy = managedReplacementCorrelationPolicy(for: candidate.replacementMetadata) else { return }
        let key = ManagedReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        armManagedReplacementFocusTransaction(
            token: candidate.token,
            workspaceId: candidate.workspaceId
        )
        let isNewBurst = pendingManagedReplacementBursts[key] == nil
        var burst = pendingManagedReplacementBursts[key] ?? PendingManagedReplacementBurst(
            policy: policy,
            firstEventUptime: managedReplacementCurrentUptime()
        )
        let pendingCreate = PendingManagedCreate(
            sequence: nextManagedReplacementSequence(),
            candidate: candidate,
            focusedActivation: focusedActivation
        )
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
        if flushManagedReplacementBurstIfUnambiguouslyMatched(for: key) {
            return
        }
        scheduleManagedReplacementFlush(
            for: key,
            policy: policy,
            resetExistingDeadline: resetExistingDeadline
        )
    }

    private func enqueueManagedReplacementDestroy(_ candidate: PreparedDestroy) {
        guard let policy = managedReplacementCorrelationPolicy(for: candidate.replacementMetadata) else { return }
        let key = ManagedReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        armManagedReplacementFocusTransaction(
            token: candidate.token,
            workspaceId: candidate.workspaceId
        )
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
        if flushManagedReplacementBurstIfUnambiguouslyMatched(for: key) {
            return
        }
        scheduleManagedReplacementFlush(
            for: key,
            policy: policy,
            resetExistingDeadline: resetExistingDeadline
        )
    }

    private func flushManagedReplacementBurstIfUnambiguouslyMatched(for key: ManagedReplacementKey) -> Bool {
        guard let burst = pendingManagedReplacementBursts[key],
              burst.destroys.count == 1,
              burst.creates.count == 1,
              matchedManagedReplacementPair(in: burst) != nil
        else {
            return false
        }
        flushManagedReplacementBurst(for: key)
        return true
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
                          new: create.candidate.replacementMetadata,
                          newFacts: nil
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
        guard rekeyManagedReplacement(from: destroy.candidate.token, to: create.candidate) else {
            return false
        }
        completeDelayedFocusedManagedAdmission(create)
        return true
    }

    private func completeDelayedFocusedManagedAdmission(_ create: PendingManagedCreate) {
        guard let activation = create.focusedActivation,
              let controller,
              let entry = controller.workspaceManager.entry(for: create.candidate.token)
        else {
            return
        }

        let targetMonitor = controller.workspaceManager.monitor(for: entry.workspaceId)
        let isWorkspaceActive = targetMonitor.map { monitor in
            controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == entry.workspaceId
        } ?? false
        let requestDisposition: ActivationRequestDisposition
        let shouldBindCurrentPidRequest: Bool
        switch activation.request {
        case let .matchesActiveRequest(requestId):
            if let request = controller.intentLedger.activeManagedRequest(requestId: requestId) {
                requestDisposition = .matchesActiveRequest(request)
                shouldBindCurrentPidRequest = true
            } else {
                requestDisposition = .unrelatedNoRequest
                shouldBindCurrentPidRequest = false
            }
        case let .conflictsWithPendingRequest(requestId):
            if let request = controller.intentLedger.activeManagedRequest(requestId: requestId) {
                requestDisposition = .conflictsWithPendingRequest(request)
                shouldBindCurrentPidRequest = true
            } else {
                requestDisposition = .unrelatedNoRequest
                shouldBindCurrentPidRequest = false
            }
        case .unrelatedNoRequest:
            requestDisposition = .unrelatedNoRequest
            shouldBindCurrentPidRequest = false
        }
        completeFocusedManagedAdmission(
            entry: entry,
            isWorkspaceActive: isWorkspaceActive,
            activation: activation,
            requestDisposition: requestDisposition,
            bindCurrentPidRequest: shouldBindCurrentPidRequest
        )
    }

    private func replayManagedReplacementEvents(_ events: [PendingManagedReplacementEvent]) {
        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            switch event {
            case let .create(create):
                trackPreparedCreate(create.candidate)
                completeDelayedFocusedManagedAdmission(create)
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
            rekeyManagedReplacementFocusTransaction(
                from: oldToken,
                to: create.token,
                workspaceId: create.workspaceId
            )
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
            transientWindowServerEvidence: facts.windowServer?.hasTransientSurfaceEvidence ?? false,
            degradedWindowServerChildEvidence: facts.degradedWindowServerChildEvidence
        )
    }

    private func normalizedParentWindowId(_ parentWindowId: UInt32?) -> UInt32? {
        guard let parentWindowId, parentWindowId != 0 else { return nil }
        return parentWindowId
    }

    private func cachedManagedReplacementMetadata(
        for entry: WindowState,
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
        if entry.mode == .floating,
           let floatingFrame = controller?.workspaceManager.floatingState(for: entry.token)?.lastFrame
        {
            metadata.frame = floatingFrame
        } else if let appliedFrame = controller?.axManager.lastAppliedFrame(for: entry.windowId) {
            metadata.frame = appliedFrame
        }
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

    func structuralReplacementMatch(
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
        var visibleWindowIds: Set<Int>?

        func oldLiveTokenIsInvisible(_ token: WindowToken) -> Bool {
            if visibleWindowIds == nil {
                visibleWindowIds = Set(visibleWindowInfoProvider().map { Int($0.id) })
            }
            guard let visibleWindowIds, !visibleWindowIds.isEmpty else { return false }
            return !visibleWindowIds.contains(token.windowId)
        }

        func recordMatch(
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID,
            source: StructuralReplacementMatchSource
        ) -> Bool {
            if match != nil {
                return false
            }
            match = StructuralReplacementMatch(token: token, workspaceId: workspaceId, source: source)
            return true
        }

        func matches(_ oldMetadata: ManagedReplacementMetadata, oldToken: WindowToken) -> Bool {
            var newMetadata = baseMetadata
            newMetadata.workspaceId = oldMetadata.workspaceId
            return managedReplacementMetadataMatches(
                oldToken: oldToken,
                old: oldMetadata,
                new: newMetadata,
                newFacts: facts
            )
        }

        for burst in pendingManagedReplacementBursts.values {
            for destroy in burst.destroys where destroy.candidate.token.pid == token.pid {
                let metadata = destroy.candidate.replacementMetadata
                if matches(metadata, oldToken: destroy.candidate.token),
                   !recordMatch(
                       token: destroy.candidate.token,
                       workspaceId: metadata.workspaceId,
                       source: .pendingDestroy
                   )
                {
                    return nil
                }
            }
        }

        for entry in controller.workspaceManager.entries(forPid: token.pid) where entry.token != token {
            guard oldLiveTokenIsInvisible(entry.token) else { continue }

            let cachedMetadata = cachedManagedReplacementMetadata(
                for: entry,
                fallbackBundleId: bundleId
            )
            if matches(cachedMetadata, oldToken: entry.token),
               !recordMatch(
                   token: entry.token,
                   workspaceId: cachedMetadata.workspaceId,
                   source: .liveInvisible
               )
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
               !recordMatch(
                   token: entry.token,
                   workspaceId: liveMetadata.workspaceId,
                   source: .liveInvisible
               )
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
        new: ManagedReplacementMetadata,
        newFacts: WindowRuleFacts?
    ) -> Bool {
        if managedReplacementIsDirectFloatingChild(oldToken: oldToken, new: new, newFacts: newFacts) {
            return false
        }

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

    private func managedReplacementIsDirectFloatingChild(
        oldToken: WindowToken,
        new: ManagedReplacementMetadata,
        newFacts: WindowRuleFacts?
    ) -> Bool {
        guard new.mode == .floating,
              let oldWindowId = UInt32(exactly: oldToken.windowId),
              new.parentWindowId == oldWindowId
        else {
            return false
        }

        if managedReplacementHasAXChildEvidence(new) {
            return true
        }

        if new.degradedWindowServerChildEvidence {
            return true
        }

        return newFacts?.degradedWindowServerChildEvidence == true
    }

    private func managedReplacementHasAXChildEvidence(_ metadata: ManagedReplacementMetadata) -> Bool {
        if metadata.role == kAXSheetRole as String {
            return true
        }

        guard let subrole = metadata.subrole else {
            return false
        }

        return subrole == kAXDialogSubrole as String
            || subrole == kAXSystemDialogSubrole as String
            || subrole != kAXStandardWindowSubrole as String
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
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.flushManagedReplacementBurst(for: key)
        }
    }

    private func flushManagedReplacementBurst(for key: ManagedReplacementKey) {
        pendingManagedReplacementTasks.removeValue(forKey: key)?.cancel()
        guard let burst = pendingManagedReplacementBursts.removeValue(forKey: key) else { return }
        markManagedReplacementFocusBurstClosed(for: key)
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
            do {
                try await Task.sleep(for: Self.stabilizationRetryDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self, let controller = self.controller else { return }
            self.pendingWindowStabilizationTasks.removeValue(forKey: token)
            let targets: Set<WindowRuleReevaluationTarget> = [.window(token)]
            let outcome = await controller.reevaluateWindowRules(for: targets)
            if outcome.stale {
                self.scheduleWindowRuleReevaluationIfNeeded(targets: targets)
            }
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
        guard !controller.isOwnedWindow(windowNumber: Int(windowId)), !isOwnProcessPid(pid) else {
            cancelCreatedWindowRetry(windowId: windowId)
            discardCreatePlacementContext(windowId: windowId)
            return false
        }
        guard resolveAXWindowRef(windowId: windowId, pid: pid) == nil else {
            return false
        }

        let attempt = createdWindowRetryCountById[windowId, default: 0] + 1
        guard attempt <= Self.createdWindowRetryLimit else {
            createdWindowRetryCountById.removeValue(forKey: windowId)
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
            createdWindowRetryCountById.removeValue(forKey: windowId)
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
            do {
                try await Task.sleep(for: Self.stabilizationRetryDelay)
            } catch {
                return
            }
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

        createPlacementContextsByWindowId[windowId] = liveCreatePlacementContext(
            controller: controller,
            nativeSpaceMonitorId: resolveNativeSpacePlacementMonitorId(spaceId: spaceId, controller: controller)
        )
    }

    func liveCreatePlacementContext(
        controller: WMController,
        nativeSpaceMonitorId: Monitor.ID? = nil
    ) -> WindowCreatePlacementContext {
        let focusedWorkspaceId = resolveFocusedPlacementWorkspaceId(controller: controller)
        return WindowCreatePlacementContext(
            nativeSpaceMonitorId: nativeSpaceMonitorId,
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
        let displayId = SkyLight.shared.displayId(forSpaceId: spaceId, among: monitors)
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
                observedToken: nil,
                source: source,
                origin: origin
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

        _ = controller.workspaceManager.enterNonManagedFocus()
        recordNiriCreateFocusTrace(
            .init(
                kind: .nonManagedFallbackEntered(
                    pid: pid,
                    source: source
                )
            )
        )
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

    private func shouldHonorObservedFocusOverPendingRequest(
        observedToken: WindowToken?,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) -> Bool {
        guard source.isAuthoritative, origin == .external else { return false }
        guard let controller, let observedToken else { return true }
        switch controller.intentLedger.classifyFocusObservation(token: observedToken) {
        case .echoOf,
             .lateEcho:
            return false
        case .external:
            return true
        }
    }

    func cleanupFocusStateForTerminatedApp(pid: pid_t) {
        guard let controller else { return }

        clearManagedReplacementFocusTransactions(pid: pid, reason: "app_terminated")
        let entries = controller.workspaceManager.entries(forPid: pid)
        for entry in entries {
            clearManagedFocusState(
                matching: entry.token,
                workspaceId: controller.workspaceManager.workspace(for: entry.token) ?? entry.workspaceId
            )
        }

        if let activeRequest = controller.intentLedger.activeManagedRequest,
           activeRequest.token.pid == pid
        {
            clearManagedFocusState(
                matching: activeRequest.token,
                workspaceId: activeRequest.workspaceId
            )
        }

        controller.workspaceManager.clearNonManagedFocusTarget(pid: pid)
    }

    private func clearManagedFocusState(
        matching token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID?
    ) {
        guard let controller else { return }

        controller.intentLedger.discardPendingFocus(token)
        let canceledRequest = controller.intentLedger.cancelManagedRequest(
            matching: token,
            workspaceId: workspaceId
        )
        if let canceledRequest {
            _ = controller.workspaceManager.cancelManagedFocusRequest(
                matching: token,
                workspaceId: workspaceId,
                requestId: canceledRequest.requestId
            )
        } else {
            _ = controller.workspaceManager.cancelCurrentManagedFocusRequest(
                matching: token,
                workspaceId: workspaceId
            )
        }
        controller.workspaceManager.clearNonManagedFocusTarget(matching: token)
    }

    private func continueManagedFocusRequest(
        _ request: ManagedFocusRequest,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        reason: ActivationRetryReason
    ) {
        guard let controller else { return }
        if let updatedRequest = controller.intentLedger.recordRetry(
            requestId: request.requestId,
            source: source,
            retryLimit: Self.activationRetryLimit
        ) {
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

    private func handleActivationRetryExhausted(
        request: ManagedFocusRequest,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) {
        guard let controller else { return }

        _ = controller.intentLedger.cancelManagedRequest(requestId: request.requestId)
        _ = controller.workspaceManager.cancelManagedFocusRequest(
            matching: request.token,
            workspaceId: request.workspaceId,
            requestId: request.requestId
        )

        if let token = controller.workspaceManager.renderableFocusToken {
            controller.surfaceReconciler.noteRestackOccurred()
            recordNiriCreateFocusTrace(
                .init(
                    kind: .borderReapplied(
                        token: token,
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
        }
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
        windowInfoProvider(windowId)
    }

    private func isOwnProcessPid(_ pid: pid_t) -> Bool {
        pid == getpid()
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
        AXWindowService.axWindowRef(for: windowId, pid: pid)
    }

    private func subscribeToWindows(_ windowIds: [UInt32]) {
        CGSEventObserver.shared.subscribeToWindows(windowIds)
    }

    private func resolveFocusedWindowValue(pid: pid_t) -> CFTypeRef? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard result == .success else { return nil }
        return focusedWindow
    }

    private func resolveFocusedAXWindowRef(pid: pid_t) -> AXWindowRef? {
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
        return controller.appInfoCache.bundleId(for: pid) ?? NSRunningApplication(processIdentifier: pid)?
            .bundleIdentifier
    }
}
