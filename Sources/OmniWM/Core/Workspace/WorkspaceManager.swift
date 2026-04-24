// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import COmniWMKernels
import Foundation
import OmniWMIPC

struct WorkspaceDescriptor: Identifiable, Hashable {
    typealias ID = UUID
    let id: ID
    var name: String
    var assignedMonitorPoint: CGPoint?

    init(name: String, assignedMonitorPoint: CGPoint? = nil) {
        id = UUID()
        self.name = name
        self.assignedMonitorPoint = assignedMonitorPoint
    }
}

struct WorkspaceMonitorProjection {
    var projectedMonitorId: Monitor.ID?
    var homeMonitorId: Monitor.ID?
    var effectiveMonitorId: Monitor.ID?
}

func workspaceSessionKernelOutputValidationFailureReason(
    status: Int32,
    rawOutput: omniwm_workspace_session_output,
    monitorCapacity: Int,
    workspaceProjectionCapacity: Int,
    disconnectedCacheCapacity: Int
) -> String? {
    guard status == OMNIWM_KERNELS_STATUS_OK else {
        return "omniwm_workspace_session_plan returned \(status)"
    }
    guard rawOutput.monitor_result_count <= monitorCapacity else {
        return "omniwm_workspace_session_plan reported \(rawOutput.monitor_result_count) monitor results for capacity \(monitorCapacity)"
    }
    guard rawOutput.workspace_projection_count <= workspaceProjectionCapacity else {
        return "omniwm_workspace_session_plan reported \(rawOutput.workspace_projection_count) workspace projections for capacity \(workspaceProjectionCapacity)"
    }
    guard rawOutput.disconnected_cache_result_count <= disconnectedCacheCapacity else {
        return "omniwm_workspace_session_plan reported \(rawOutput.disconnected_cache_result_count) disconnected cache results for capacity \(disconnectedCacheCapacity)"
    }
    return nil
}

private func reportWorkspaceSessionKernelBridgeFailure(_ message: String) {
    fputs("[WorkspaceSessionKernel] \(message)\n", stderr)
}

@MainActor
final class WorkspaceManager {
    static let managedRestoreSnapshotFrameTolerance: CGFloat = 0.5

    static let staleUnavailableNativeFullscreenTimeout: TimeInterval = 15
    static var forceTopologyReconcileFailureForTests = false

    enum NativeFullscreenTransition: Equatable {
        case enterRequested
        case suspended
        case exitRequested
        case restoring
    }

    enum NativeFullscreenAvailability: Equatable {
        case present
        case temporarilyUnavailable
    }

    struct NativeFullscreenRecord {
        struct RestoreSnapshot: Equatable {
            let frame: CGRect
            let topologyProfile: TopologyProfile
            let niriState: ManagedWindowRestoreSnapshot.NiriState?
            let replacementMetadata: ManagedReplacementMetadata?

            init(
                frame: CGRect,
                topologyProfile: TopologyProfile,
                niriState: ManagedWindowRestoreSnapshot.NiriState? = nil,
                replacementMetadata: ManagedReplacementMetadata? = nil
            ) {
                self.frame = frame
                self.topologyProfile = topologyProfile
                self.niriState = niriState
                self.replacementMetadata = replacementMetadata
            }
        }

        struct RestoreFailure: Equatable {
            let path: String
            let detail: String
        }

        let originalToken: WindowToken
        var currentToken: WindowToken
        let workspaceId: WorkspaceDescriptor.ID
        var restoreSnapshot: RestoreSnapshot?
        var restoreFailure: RestoreFailure?
        var exitRequestedByCommand: Bool
        var transition: NativeFullscreenTransition
        var availability: NativeFullscreenAvailability
        var unavailableSince: Date?
    }

    private let windowRegistry = WindowRegistry()
    private let workspaceStore: WorkspaceStore
    private let restoreState: RestoreState

    private(set) var monitors: [Monitor] {
        get { workspaceStore.monitors }
        set {
            workspaceStore.monitors = newValue
            cachedTopologyProfile = TopologyProfile(monitors: newValue)
            rebuildMonitorIndexes()
        }
    }

    private var _monitorsById: [Monitor.ID: Monitor] = [:]
    private var _monitorsByName: [String: [Monitor]] = [:]
    private var cachedTopologyProfile: TopologyProfile
    private let settings: SettingsStore

    private var workspacesById: [WorkspaceDescriptor.ID: WorkspaceDescriptor] {
        get { workspaceStore.workspacesById }
        set { workspaceStore.workspacesById = newValue }
    }
    private var workspaceIdByName: [String: WorkspaceDescriptor.ID] {
        get { workspaceStore.workspaceIdByName }
        set { workspaceStore.workspaceIdByName = newValue }
    }
    private var disconnectedVisibleWorkspaceCache: [MonitorRestoreKey: WorkspaceDescriptor.ID] {
        get { workspaceStore.disconnectedVisibleWorkspaceCache }
        set { workspaceStore.disconnectedVisibleWorkspaceCache = newValue }
    }

    private(set) var gaps: Double = 8
    private(set) var outerGaps: LayoutGaps.OuterGaps = .zero
    private var windows: WindowModel { windowRegistry.windows }
    private lazy var runtimeStore = RuntimeStore()
    private var restorePlanner: RestorePlanner { restoreState.restorePlanner }
    private var bootPersistedWindowRestoreCatalog: PersistedWindowRestoreCatalog {
        restoreState.bootPersistedWindowRestoreCatalog
    }
    private var nativeFullscreenRecordsByOriginalToken: [WindowToken: NativeFullscreenRecord] {
        get { restoreState.nativeFullscreenRecordsByOriginalToken }
        set { restoreState.nativeFullscreenRecordsByOriginalToken = newValue }
    }
    private var nativeFullscreenOriginalTokenByCurrentToken: [WindowToken: WindowToken] {
        get { restoreState.nativeFullscreenOriginalTokenByCurrentToken }
        set { restoreState.nativeFullscreenOriginalTokenByCurrentToken = newValue }
    }
    private var consumedBootPersistedWindowRestoreKeys: Set<PersistedWindowRestoreKey> {
        get { restoreState.consumedBootPersistedWindowRestoreKeys }
        set { restoreState.consumedBootPersistedWindowRestoreKeys = newValue }
    }
    private var persistedWindowRestoreCatalogDirty: Bool {
        get { restoreState.persistedWindowRestoreCatalogDirty }
        set { restoreState.persistedWindowRestoreCatalogDirty = newValue }
    }
    private var persistedWindowRestoreCatalogSaveScheduled: Bool {
        get { restoreState.persistedWindowRestoreCatalogSaveScheduled }
        set { restoreState.persistedWindowRestoreCatalogSaveScheduled = newValue }
    }

    private var _cachedSortedWorkspaces: [WorkspaceDescriptor]? {
        get { workspaceStore.cachedSortedWorkspaces }
        set { workspaceStore.cachedSortedWorkspaces = newValue }
    }
    private var _cachedWorkspaceIdsByMonitor: [Monitor.ID: [WorkspaceDescriptor.ID]]? {
        get { workspaceStore.cachedWorkspaceIdsByMonitor }
        set { workspaceStore.cachedWorkspaceIdsByMonitor = newValue }
    }
    private var _cachedVisibleWorkspaceIds: Set<WorkspaceDescriptor.ID>? {
        get { workspaceStore.cachedVisibleWorkspaceIds }
        set { workspaceStore.cachedVisibleWorkspaceIds = newValue }
    }
    private var _cachedVisibleWorkspaceMap: [Monitor.ID: WorkspaceDescriptor.ID]? {
        get { workspaceStore.cachedVisibleWorkspaceMap }
        set { workspaceStore.cachedVisibleWorkspaceMap = newValue }
    }
    private var _cachedMonitorIdByVisibleWorkspace: [WorkspaceDescriptor.ID: Monitor.ID]? {
        get { workspaceStore.cachedMonitorIdByVisibleWorkspace }
        set { workspaceStore.cachedMonitorIdByVisibleWorkspace = newValue }
    }
    private var _cachedWorkspaceMonitorProjection: [WorkspaceDescriptor.ID: WorkspaceMonitorProjection]? {
        get { workspaceStore.cachedWorkspaceMonitorProjection }
        set { workspaceStore.cachedWorkspaceMonitorProjection = newValue }
    }
    var animationClock: AnimationClock?
    private var sessionState = WorkspaceSessionState()

    var onGapsChanged: (() -> Void)?
    var onSessionStateChanged: (() -> Void)?
    var onWindowRemoved: ((WindowToken) -> Void)?
    var onWindowRekeyed: ((WindowToken, WindowToken) -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
        let discoveredMonitors = Monitor.current()
        let initialMonitors = discoveredMonitors.isEmpty ? [Monitor.fallback()] : discoveredMonitors
        workspaceStore = WorkspaceStore(
            monitors: initialMonitors
        )
        cachedTopologyProfile = TopologyProfile(monitors: initialMonitors)
        restoreState = RestoreState(settings: settings)
        settings.rebindMonitorReferences(to: monitors)
        rebuildMonitorIndexes()
        applySettings()
        reconcileInteractionMonitorState(notify: false)
    }

    func reconcileSnapshot() -> ReconcileSnapshot {
        let windowSnapshots = windows.allEntries()
            .sorted {
                if $0.workspaceId != $1.workspaceId {
                    return $0.workspaceId.uuidString < $1.workspaceId.uuidString
                }
                if $0.pid != $1.pid {
                    return $0.pid < $1.pid
                }
                return $0.windowId < $1.windowId
            }
            .map { entry in
                ReconcileWindowSnapshot(
                    token: entry.token,
                    workspaceId: entry.workspaceId,
                    mode: entry.mode,
                    lifecyclePhase: entry.lifecyclePhase,
                    observedState: entry.observedState,
                    desiredState: entry.desiredState,
                    restoreIntent: entry.restoreIntent,
                    replacementCorrelation: entry.replacementCorrelation
                )
            }

        return ReconcileSnapshot(
            topologyProfile: topologyProfile,
            focusSession: focusSessionSnapshot(),
            windows: windowSnapshots
        )
    }

    private func focusSessionSnapshot() -> FocusSessionSnapshot {
        FocusSessionSnapshot(
            focusedToken: sessionState.focus.focusedToken,
            pendingManagedFocus: PendingManagedFocusSnapshot(
                token: sessionState.focus.pendingManagedFocus.token,
                workspaceId: sessionState.focus.pendingManagedFocus.workspaceId,
                monitorId: sessionState.focus.pendingManagedFocus.monitorId
            ),
            focusLease: sessionState.focus.focusLease,
            isNonManagedFocusActive: sessionState.focus.isNonManagedFocusActive,
            isAppFullscreenActive: sessionState.focus.isAppFullscreenActive,
            interactionMonitorId: sessionState.interactionMonitorId,
            previousInteractionMonitorId: sessionState.previousInteractionMonitorId
        )
    }

    @discardableResult
    func recordReconcileEvent(
        _ event: WMEvent,
        transactionEpoch: TransactionEpoch = .invalid
    ) -> ReconcileTxn {
        let snapshot = reconcileSnapshot()
        let restoreEventPlan = restorePlanner.planEvent(
            .init(
                event: event,
                snapshot: snapshot,
                monitors: monitors
            )
        )
        let entry = event.token.flatMap { windows.entry(for: $0) }
        let persistedHydration = event.token.flatMap { plannedPersistedHydrationMutation(for: $0) }
        let restoreRefresh = plannedRestoreRefresh(
            from: restoreEventPlan,
            snapshot: snapshot
        )
        return runtimeStore.transact(
            event: event,
            existingEntry: entry,
            monitors: monitors,
            persistedHydration: persistedHydration,
            transactionEpoch: transactionEpoch,
            snapshot: { self.reconcileSnapshot() },
            applyPlan: { plan, token in
                var plan = plan
                if let restoreRefresh {
                    plan.restoreRefresh = restoreRefresh
                }
                if let persistedHydration {
                    plan.persistedHydration = persistedHydration
                    plan.notes.append("persisted_hydration")
                }
                if !restoreEventPlan.notes.isEmpty {
                    plan.notes.append(contentsOf: restoreEventPlan.notes)
                }
                return self.applyActionPlan(plan, to: token)
            }
        )
    }

    @discardableResult
    private func recordTopologyChange(to newMonitors: [Monitor]) -> ReconcileTxn {
        let normalizedMonitors = newMonitors.isEmpty ? [Monitor.fallback()] : newMonitors
        let originalWorkspaceConfigurations = settings.workspaceConfigurations
        let originalMonitorBarSettings = settings.monitorBarSettings
        let originalOrientationSettings = settings.monitorOrientationSettings
        let originalNiriSettings = settings.monitorNiriSettings
        let originalDwindleSettings = settings.monitorDwindleSettings
        let originalMouseWarpMonitorOrder = settings.mouseWarpMonitorOrder
        settings.rebindMonitorReferences(to: normalizedMonitors)
        let topologyPlan = WorkspaceSessionKernel.reconcileTopology(
            manager: self,
            newMonitors: normalizedMonitors
        )
        if topologyPlan == nil {
            if settings.workspaceConfigurations != originalWorkspaceConfigurations {
                settings.workspaceConfigurations = originalWorkspaceConfigurations
            }
            if settings.monitorBarSettings != originalMonitorBarSettings {
                settings.monitorBarSettings = originalMonitorBarSettings
            }
            if settings.monitorOrientationSettings != originalOrientationSettings {
                settings.monitorOrientationSettings = originalOrientationSettings
            }
            if settings.monitorNiriSettings != originalNiriSettings {
                settings.monitorNiriSettings = originalNiriSettings
            }
            if settings.monitorDwindleSettings != originalDwindleSettings {
                settings.monitorDwindleSettings = originalDwindleSettings
            }
            if settings.mouseWarpMonitorOrder != originalMouseWarpMonitorOrder {
                settings.mouseWarpMonitorOrder = originalMouseWarpMonitorOrder
            }
        }
        let event = WMEvent.topologyChanged(
            displays: Monitor.sortedByPosition(normalizedMonitors).map(DisplayFingerprint.init),
            source: .workspaceManager
        )

        return runtimeStore.transact(
            event: event,
            existingEntry: nil,
            monitors: normalizedMonitors,
            snapshot: { self.reconcileSnapshot() },
            applyPlan: { plan, _ in
                var plan = plan
                if let topologyPlan {
                    plan.topologyTransition = topologyPlan
                    if topologyPlan.refreshRestoreIntents {
                        plan.notes.append("restore_refresh=topology")
                    }
                }
                return self.applyActionPlan(plan, to: nil)
            }
        )
    }

    private func applyActionPlan(
        _ plan: ActionPlan,
        to token: WindowToken?
    ) -> ActionPlan {
        var resolvedPlan = plan

        if let restoreRefresh = plan.restoreRefresh {
            applyRestoreRefresh(restoreRefresh)
        }

        if let focusSession = plan.focusSession {
            applyReconciledFocusSession(focusSession)
        }

        if let topologyTransition = plan.topologyTransition {
            applyTopologyTransition(topologyTransition)
            notifySessionStateChanged()
        }

        guard let token else {
            if !resolvedPlan.isEmpty {
                schedulePersistedWindowRestoreCatalogSave()
            }
            return resolvedPlan
        }

        if let persistedHydration = plan.persistedHydration {
            _ = applyPersistedHydrationMutation(
                persistedHydration,
                floatingState: hydratedFloatingState(
                    for: persistedHydration,
                    restoreIntent: plan.restoreIntent
                ),
                to: token
            )
        }

        if let lifecyclePhase = plan.lifecyclePhase {
            windows.setLifecyclePhase(lifecyclePhase, for: token)
        }
        if let observedState = plan.observedState {
            windows.setObservedState(observedState, for: token)
        }
        if let desiredState = plan.desiredState {
            windows.setDesiredState(desiredState, for: token)
        }
        if let replacementCorrelation = plan.replacementCorrelation {
            windows.setReplacementCorrelation(replacementCorrelation, for: token)
        }
        if let restoreIntent = plan.restoreIntent {
            windows.setRestoreIntent(restoreIntent, for: token)
            resolvedPlan.restoreIntent = restoreIntent
        }
        if !resolvedPlan.isEmpty {
            schedulePersistedWindowRestoreCatalogSave()
        }

        return resolvedPlan
    }

    private func applyReconciledFocusSession(_ focusSession: FocusSessionSnapshot) {
        sessionState.focus.focusedToken = focusSession.focusedToken
        sessionState.focus.pendingManagedFocus = .init(
            token: focusSession.pendingManagedFocus.token,
            workspaceId: focusSession.pendingManagedFocus.workspaceId,
            monitorId: focusSession.pendingManagedFocus.monitorId
        )
        sessionState.focus.focusLease = focusSession.focusLease
        sessionState.focus.isNonManagedFocusActive = focusSession.isNonManagedFocusActive
        sessionState.focus.isAppFullscreenActive = focusSession.isAppFullscreenActive
        sessionState.interactionMonitorId = focusSession.interactionMonitorId
        sessionState.previousInteractionMonitorId = focusSession.previousInteractionMonitorId
    }

    @discardableResult
    private func applyFocusReconcileEvent(_ event: WMEvent) -> Bool {
        let previousFocusSession = focusSessionSnapshot()
        recordReconcileEvent(event)
        return focusSessionSnapshot() != previousFocusSession
    }

    private func plannedRestoreRefresh(
        from eventPlan: RestorePlanner.EventPlan,
        snapshot: ReconcileSnapshot
    ) -> RestoreRefreshPlan? {
        let hasInteractionChange = eventPlan.interactionMonitorId != snapshot.interactionMonitorId
            || eventPlan.previousInteractionMonitorId != snapshot.previousInteractionMonitorId
        guard eventPlan.refreshRestoreIntents || hasInteractionChange else {
            return nil
        }

        return RestoreRefreshPlan(
            refreshRestoreIntents: eventPlan.refreshRestoreIntents,
            interactionMonitorId: eventPlan.interactionMonitorId,
            previousInteractionMonitorId: eventPlan.previousInteractionMonitorId
        )
    }

    private func refreshRestoreIntentsForAllEntries() {
        for entry in windows.allEntries() {
            windows.setRestoreIntent(
                StateReducer.restoreIntent(for: entry, monitors: monitors),
                for: entry.token
            )
        }
    }

    private func applyRestoreRefresh(_ plan: RestoreRefreshPlan) {
        if plan.refreshRestoreIntents {
            refreshRestoreIntentsForAllEntries()
            schedulePersistedWindowRestoreCatalogSave()
        }

        sessionState.interactionMonitorId = plan.interactionMonitorId
        sessionState.previousInteractionMonitorId = plan.previousInteractionMonitorId
    }

    private func applyTopologyTransition(_ transition: TopologyTransitionPlan) {
        monitors = transition.newMonitors.isEmpty ? [Monitor.fallback()] : transition.newMonitors
        invalidateWorkspaceProjectionCaches()
        _ = replaceWorkspaceSessionMonitorStates(
            transition.monitorStates,
            notify: false,
            updateVisibleAnchors: true
        )
        cacheCurrentWorkspaceProjectionRecords(transition.workspaceProjections)
        _ = applyWorkspaceSessionInteractionState(
            interactionMonitorId: transition.interactionMonitorId,
            previousInteractionMonitorId: transition.previousInteractionMonitorId,
            notify: false
        )
        disconnectedVisibleWorkspaceCache = transition.disconnectedVisibleWorkspaceCache
        refreshWindowMonitorReferencesForAllEntries()
        if transition.refreshRestoreIntents {
            refreshRestoreIntentsForAllEntries()
        }
    }

    private func refreshWindowMonitorReferencesForAllEntries() {
        for entry in windows.allEntries() {
            let currentMonitorId = monitorId(for: entry.workspaceId)
            if entry.observedState.monitorId != currentMonitorId {
                var observedState = entry.observedState
                observedState.monitorId = currentMonitorId
                windows.setObservedState(observedState, for: entry.token)
            }
            if entry.desiredState.monitorId != currentMonitorId {
                var desiredState = entry.desiredState
                desiredState.monitorId = currentMonitorId
                windows.setDesiredState(desiredState, for: entry.token)
            }
        }
    }

    private func plannedPersistedHydrationMutation(for token: WindowToken) -> PersistedHydrationMutation? {
        guard let metadata = windows.managedReplacementMetadata(for: token),
              let hydrationPlan = restorePlanner.planPersistedHydration(
                  .init(
                      metadata: metadata,
                      catalog: bootPersistedWindowRestoreCatalog,
                      consumedKeys: consumedBootPersistedWindowRestoreKeys,
                      monitors: monitors,
                      workspaceIdForName: { [weak self] workspaceName in
                          self?.workspaceId(for: workspaceName, createIfMissing: false)
                      }
                  )
              )
        else {
            return nil
        }

        return PersistedHydrationMutation(
            workspaceId: hydrationPlan.workspaceId,
            monitorId: hydrationPlan.preferredMonitorId ?? effectiveMonitor(for: hydrationPlan.workspaceId)?.id,
            targetMode: hydrationPlan.targetMode,
            floatingFrame: hydrationPlan.floatingFrame,
            consumedKey: hydrationPlan.consumedKey
        )
    }

    private func hydratedFloatingState(
        for hydration: PersistedHydrationMutation,
        restoreIntent: RestoreIntent?
    ) -> WindowModel.FloatingState? {
        guard let floatingFrame = hydration.floatingFrame else {
            return nil
        }

        return .init(
            lastFrame: floatingFrame,
            normalizedOrigin: restoreIntent?.normalizedFloatingOrigin,
            referenceMonitorId: hydration.monitorId,
            restoreToFloating: restoreIntent?.restoreToFloating ?? true
        )
    }

    @discardableResult
    private func applyPersistedHydrationMutation(
        _ hydration: PersistedHydrationMutation,
        floatingState resolvedFloatingState: WindowModel.FloatingState? = nil,
        to token: WindowToken
    ) -> Bool {
        guard let entry = windows.entry(for: token) else {
            return false
        }

        if entry.workspaceId != hydration.workspaceId {
            windows.updateWorkspace(
                for: token,
                workspace: hydration.workspaceId
            )
        }

        let focusChanged = applyWindowModeMutationWithoutReconcile(
            hydration.targetMode,
            for: token,
            workspaceId: hydration.workspaceId
        )

        if let resolvedFloatingState {
            windows.setFloatingState(resolvedFloatingState, for: token)
        } else if let floatingFrame = hydration.floatingFrame {
            let referenceMonitor = hydration.monitorId.flatMap(monitor(byId:))
            let referenceVisibleFrame = referenceMonitor?.visibleFrame ?? floatingFrame
            let normalizedOrigin = normalizedFloatingOrigin(
                for: floatingFrame,
                in: referenceVisibleFrame
            )
            windows.setFloatingState(
                .init(
                    lastFrame: floatingFrame,
                    normalizedOrigin: normalizedOrigin,
                    referenceMonitorId: referenceMonitor?.id,
                    restoreToFloating: true
                ),
                for: token
            )
        }

        consumedBootPersistedWindowRestoreKeys.insert(hydration.consumedKey)
        if focusChanged {
            notifySessionStateChanged()
        }
        return true
    }

    @discardableResult
    private func applyWindowModeMutationWithoutReconcile(
        _ mode: TrackedWindowMode,
        for token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let entry = entry(for: token) else { return false }
        let oldMode = entry.mode
        guard oldMode != mode else { return false }

        windows.setMode(mode, for: token)
        return updateFocusSession(notify: false) { focus in
            self.reconcileRememberedFocusAfterModeChange(
                token,
                workspaceId: workspaceId,
                oldMode: oldMode,
                newMode: mode,
                focus: &focus
            )
        }
    }

    func flushPersistedWindowRestoreCatalogNow() {
        persistedWindowRestoreCatalogDirty = true
        flushPersistedWindowRestoreCatalogIfNeeded()
    }

    func persistedWindowRestoreCatalogForTests() -> PersistedWindowRestoreCatalog {
        buildPersistedWindowRestoreCatalog()
    }

    func bootPersistedWindowRestoreCatalogForTests() -> PersistedWindowRestoreCatalog {
        bootPersistedWindowRestoreCatalog
    }

    func consumedBootPersistedWindowRestoreKeysForTests() -> Set<PersistedWindowRestoreKey> {
        consumedBootPersistedWindowRestoreKeys
    }

    private func schedulePersistedWindowRestoreCatalogSave() {
        persistedWindowRestoreCatalogDirty = true
        guard !persistedWindowRestoreCatalogSaveScheduled else { return }
        persistedWindowRestoreCatalogSaveScheduled = true

        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            persistedWindowRestoreCatalogSaveScheduled = false
            flushPersistedWindowRestoreCatalogIfNeeded()
        }
    }

    private func flushPersistedWindowRestoreCatalogIfNeeded() {
        guard persistedWindowRestoreCatalogDirty else { return }
        persistedWindowRestoreCatalogDirty = false
        settings.savePersistedWindowRestoreCatalog(buildPersistedWindowRestoreCatalog())
    }

    private func buildPersistedWindowRestoreCatalog() -> PersistedWindowRestoreCatalog {
        struct Candidate {
            let key: PersistedWindowRestoreKey
            let entry: PersistedWindowRestoreEntry
        }

        var candidatesByBaseKey: [PersistedWindowRestoreBaseKey: [Candidate]] = [:]

        for entry in windows.allEntries() {
            guard let metadata = entry.managedReplacementMetadata,
                  let key = PersistedWindowRestoreKey(metadata: metadata),
                  // Never persist a nil-title key: it becomes a
                  // catch-all that matches any later admission whose
                  // metadata still has nil title (AX facts not yet
                  // populated), silently consuming itself without doing
                  // any useful restore. Titled keys are re-created the
                  // next time a real title is available.
                  key.isIdentifying,
                  let persistedRestoreIntent = persistedRestoreIntent(for: entry)
            else {
                continue
            }

            let persistedEntry = PersistedWindowRestoreEntry(
                key: key,
                restoreIntent: persistedRestoreIntent
            )
            candidatesByBaseKey[key.baseKey, default: []].append(
                Candidate(key: key, entry: persistedEntry)
            )
        }

        var persistedEntries: [PersistedWindowRestoreEntry] = []
        persistedEntries.reserveCapacity(candidatesByBaseKey.count)

        for candidates in candidatesByBaseKey.values {
            if candidates.count == 1, let candidate = candidates.first {
                persistedEntries.append(candidate.entry)
                continue
            }

            let candidatesByTitle = Dictionary(grouping: candidates, by: { $0.key.title })
            for (_, titledCandidates) in candidatesByTitle where titledCandidates.count == 1 {
                if let candidate = titledCandidates.first {
                    persistedEntries.append(candidate.entry)
                }
            }
        }

        persistedEntries.sort { lhs, rhs in
            let lhsWorkspace = lhs.restoreIntent.workspaceName
            let rhsWorkspace = rhs.restoreIntent.workspaceName
            if lhsWorkspace != rhsWorkspace {
                return lhsWorkspace < rhsWorkspace
            }
            if lhs.key.baseKey.bundleId != rhs.key.baseKey.bundleId {
                return lhs.key.baseKey.bundleId < rhs.key.baseKey.bundleId
            }
            return (lhs.key.title ?? "") < (rhs.key.title ?? "")
        }

        return PersistedWindowRestoreCatalog(entries: persistedEntries)
    }

    private func persistedRestoreIntent(for entry: WindowModel.Entry) -> PersistedRestoreIntent? {
        guard let restoreIntent = entry.restoreIntent,
              let workspaceName = descriptor(for: entry.workspaceId)?.name
        else {
            return nil
        }

        let preferredMonitor = monitor(for: entry.workspaceId).map(DisplayFingerprint.init)
            ?? restoreIntent.preferredMonitor

        return PersistedRestoreIntent(
            workspaceName: workspaceName,
            topologyProfile: topologyProfile,
            preferredMonitor: preferredMonitor,
            floatingFrame: restoreIntent.floatingFrame,
            normalizedFloatingOrigin: restoreIntent.normalizedFloatingOrigin,
            restoreToFloating: restoreIntent.restoreToFloating,
            rescueEligible: restoreIntent.rescueEligible
        )
    }

    func monitor(byId id: Monitor.ID) -> Monitor? {
        _monitorsById[id]
    }

    func monitor(named name: String) -> Monitor? {
        guard let matches = _monitorsByName[name], matches.count == 1 else { return nil }
        return matches[0]
    }

    func monitors(named name: String) -> [Monitor] {
        _monitorsByName[name] ?? []
    }

    var interactionMonitorId: Monitor.ID? {
        sessionState.interactionMonitorId
    }

    var previousInteractionMonitorId: Monitor.ID? {
        sessionState.previousInteractionMonitorId
    }

    var focusedToken: WindowToken? {
        sessionState.focus.focusedToken
    }

    var focusedHandle: WindowHandle? {
        focusedToken.flatMap { windows.handle(for: $0) }
    }

    var pendingFocusedToken: WindowToken? {
        sessionState.focus.pendingManagedFocus.token
    }

    var pendingFocusedHandle: WindowHandle? {
        pendingFocusedToken.flatMap { windows.handle(for: $0) }
    }

    var pendingFocusedWorkspaceId: WorkspaceDescriptor.ID? {
        sessionState.focus.pendingManagedFocus.workspaceId
    }

    var pendingFocusedMonitorId: Monitor.ID? {
        sessionState.focus.pendingManagedFocus.monitorId
    }

    var isNonManagedFocusActive: Bool {
        sessionState.focus.isNonManagedFocusActive
    }

    var isAppFullscreenActive: Bool {
        sessionState.focus.isAppFullscreenActive
    }

    var hasNativeFullscreenLifecycleContext: Bool {
        sessionState.focus.isAppFullscreenActive || !nativeFullscreenRecordsByOriginalToken.isEmpty
    }

    /// Grace window kept after any native-FS lifecycle transition
    /// (suspend, begin, finalize) during which missing-window purges must be
    /// suppressed. macOS's AX enumeration is frequently incomplete for
    /// windows on non-active spaces for several hundred ms around any
    /// fullscreen-related space transition; a single missed enumeration must
    /// not be treated as "window destroyed". 400 ms comfortably covers
    /// roughly six rescan cycles at the current cadence.
    private static let nativeFullscreenLifecycleGrace: Duration = .milliseconds(400)

    private var lastNativeFullscreenLifecycleTransitionAt: ContinuousClock.Instant?

    var isWithinNativeFullscreenLifecycleGrace: Bool {
        guard let last = lastNativeFullscreenLifecycleTransitionAt else { return false }
        return ContinuousClock.now - last < Self.nativeFullscreenLifecycleGrace
    }

    fileprivate func markNativeFullscreenLifecycleTransition() {
        lastNativeFullscreenLifecycleTransitionAt = ContinuousClock.now
    }

    func scratchpadToken() -> WindowToken? {
        sessionState.scratchpadToken
    }

    @discardableResult
    func setScratchpadToken(_ token: WindowToken?) -> Bool {
        updateScratchpadToken(token, notify: true)
    }

    @discardableResult
    func clearScratchpadIfMatches(_ token: WindowToken) -> Bool {
        clearScratchpadToken(matching: token, notify: true)
    }

    func isScratchpadToken(_ token: WindowToken) -> Bool {
        sessionState.scratchpadToken == token
    }

    var hasPendingNativeFullscreenTransition: Bool {
        nativeFullscreenRecordsByOriginalToken.values.contains {
            $0.transition == .enterRequested
                || $0.transition == .restoring
                || $0.availability == .temporarilyUnavailable
        }
    }

    var topologyProfile: TopologyProfile {
        cachedTopologyProfile
    }

    @discardableResult
    func applyOrchestrationFocusState(
        _ focusSnapshot: FocusOrchestrationSnapshot
    ) -> Bool {
        var changed = false

        if let token = focusSnapshot.pendingFocusedToken,
           let workspaceId = focusSnapshot.pendingFocusedWorkspaceId
        {
            changed = updatePendingManagedFocusRequest(
                token,
                workspaceId: workspaceId,
                monitorId: monitorId(for: workspaceId),
                focus: &sessionState.focus
            ) || changed
        } else {
            changed = clearPendingManagedFocusRequest(focus: &sessionState.focus) || changed
        }

        if sessionState.focus.isNonManagedFocusActive != focusSnapshot.isNonManagedFocusActive {
            sessionState.focus.isNonManagedFocusActive = focusSnapshot.isNonManagedFocusActive
            changed = true
        }
        if sessionState.focus.isAppFullscreenActive != focusSnapshot.isAppFullscreenActive {
            sessionState.focus.isAppFullscreenActive = focusSnapshot.isAppFullscreenActive
            changed = true
        }

        if changed {
            notifySessionStateChanged()
        }
        return changed
    }

    @discardableResult
    func setInteractionMonitor(_ monitorId: Monitor.ID?, preservePrevious: Bool = true) -> Bool {
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id }
        return updateInteractionMonitor(normalizedMonitorId, preservePrevious: preservePrevious, notify: true)
    }

    @discardableResult
    func setManagedFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil
    ) -> Bool {
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id }
        var changed = rememberFocus(token, in: workspaceId)
        if let normalizedMonitorId {
            changed = updateInteractionMonitor(normalizedMonitorId, preservePrevious: true, notify: false) || changed
        }
        let appFullscreen = sessionState.focus.isNonManagedFocusActive ? false : sessionState.focus
            .isAppFullscreenActive
        changed = applyFocusReconcileEvent(
            .managedFocusConfirmed(
                token: token,
                workspaceId: workspaceId,
                monitorId: normalizedMonitorId,
                appFullscreen: appFullscreen,
                source: .workspaceManager
            )
        ) || changed
        if changed {
            notifySessionStateChanged()
        }
        return changed
    }

    @discardableResult
    func beginManagedFocusRequest(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil
    ) -> Bool {
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id }
        var changed = rememberFocus(token, in: workspaceId)
        changed = applyFocusReconcileEvent(
            .managedFocusRequested(
                token: token,
                workspaceId: workspaceId,
                monitorId: normalizedMonitorId,
                source: .workspaceManager
            )
        ) || changed
        if changed {
            notifySessionStateChanged()
        }
        return changed
    }

    @discardableResult
    func confirmManagedFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil,
        appFullscreen: Bool,
        activateWorkspaceOnMonitor: Bool
    ) -> Bool {
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id } ?? self.monitorId(for: workspaceId)
        var changed = false

        if activateWorkspaceOnMonitor,
           let normalizedMonitorId,
           let monitor = monitor(byId: normalizedMonitorId)
        {
            changed = setActiveWorkspaceInternal(
                workspaceId,
                on: normalizedMonitorId,
                anchorPoint: monitor.workspaceAnchorPoint,
                updateInteractionMonitor: false,
                notify: false
            ) || changed
        }

        if let normalizedMonitorId {
            changed = updateInteractionMonitor(normalizedMonitorId, preservePrevious: true, notify: false) || changed
        }

        changed = rememberFocus(token, in: workspaceId) || changed
        changed = applyFocusReconcileEvent(
            .managedFocusConfirmed(
                token: token,
                workspaceId: workspaceId,
                monitorId: normalizedMonitorId,
                appFullscreen: appFullscreen,
                source: .workspaceManager
            )
        ) || changed

        if changed {
            notifySessionStateChanged()
        }

        return changed
    }

    @discardableResult
    func cancelManagedFocusRequest(
        matching token: WindowToken? = nil,
        workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> Bool {
        let changed = applyFocusReconcileEvent(
            .managedFocusCancelled(
                token: token,
                workspaceId: workspaceId,
                source: .workspaceManager
            )
        )

        if changed {
            notifySessionStateChanged()
        }

        return changed
    }

    @discardableResult
    func setManagedAppFullscreen(_ active: Bool) -> Bool {
        let changed = applyFocusReconcileEvent(
            .nonManagedFocusChanged(
                active: false,
                appFullscreen: active,
                preserveFocusedToken: true,
                source: .workspaceManager
            )
        )
        if changed {
            notifySessionStateChanged()
        }
        return changed
    }

    func nativeFullscreenRecord(for token: WindowToken) -> NativeFullscreenRecord? {
        guard let originalToken = nativeFullscreenOriginalToken(for: token) else {
            return nil
        }
        return nativeFullscreenRecordsByOriginalToken[originalToken]
    }

    func managedRestoreSnapshot(for token: WindowToken) -> ManagedWindowRestoreSnapshot? {
        windows.managedRestoreSnapshot(for: token)
    }

    @discardableResult
    func setManagedRestoreSnapshot(
        _ snapshot: ManagedWindowRestoreSnapshot,
        for token: WindowToken
    ) -> Bool {
        guard windows.entry(for: token) != nil else { return false }
        guard shouldPersistManagedRestoreSnapshot(snapshot, for: token) else { return false }
        windows.setManagedRestoreSnapshot(snapshot, for: token)
        return true
    }

    @discardableResult
    func clearManagedRestoreSnapshot(for token: WindowToken) -> Bool {
        guard windows.managedRestoreSnapshot(for: token) != nil else { return false }
        windows.setManagedRestoreSnapshot(nil, for: token)
        return true
    }

    func shouldPersistManagedRestoreSnapshot(
        _ snapshot: ManagedWindowRestoreSnapshot,
        for token: WindowToken
    ) -> Bool {
        guard let previousSnapshot = windows.managedRestoreSnapshot(for: token) else {
            return true
        }
        return !previousSnapshot.isSemanticallyEquivalent(
            to: snapshot,
            frameTolerance: Self.managedRestoreSnapshotFrameTolerance
        )
    }

    private func nativeFullscreenRestoreSnapshot(
        from snapshot: ManagedWindowRestoreSnapshot?
    ) -> NativeFullscreenRecord.RestoreSnapshot? {
        guard let snapshot else { return nil }
        return NativeFullscreenRecord.RestoreSnapshot(
            frame: snapshot.frame,
            topologyProfile: snapshot.topologyProfile,
            niriState: snapshot.niriState,
            replacementMetadata: snapshot.replacementMetadata
        )
    }

    @discardableResult
    func seedNativeFullscreenRestoreSnapshot(
        _ restoreSnapshot: NativeFullscreenRecord.RestoreSnapshot,
        for token: WindowToken
    ) -> Bool {
        guard let originalToken = nativeFullscreenOriginalToken(for: token),
              var record = nativeFullscreenRecordsByOriginalToken[originalToken]
        else {
            return false
        }
        let changed = applyNativeFullscreenRestoreState(
            to: &record,
            restoreSnapshot: restoreSnapshot,
            restoreFailure: nil
        )
        if changed {
            upsertNativeFullscreenRecord(record)
        }
        return changed
    }

    @discardableResult
    func requestNativeFullscreenEnter(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        restoreSnapshot: NativeFullscreenRecord.RestoreSnapshot? = nil,
        restoreFailure: NativeFullscreenRecord.RestoreFailure? = nil
    ) -> Bool {
        var changed = rememberFocus(token, in: workspaceId)
        let resolvedRestoreSnapshot = restoreSnapshot
            ?? nativeFullscreenRestoreSnapshot(from: managedRestoreSnapshot(for: token))
        let originalToken = nativeFullscreenOriginalToken(for: token) ?? token
        let existing = nativeFullscreenRecordsByOriginalToken[originalToken]
        var record = existing ?? NativeFullscreenRecord(
            originalToken: originalToken,
            currentToken: token,
            workspaceId: workspaceId,
            restoreSnapshot: resolvedRestoreSnapshot,
            restoreFailure: restoreFailure,
            exitRequestedByCommand: false,
            transition: .enterRequested,
            availability: .present,
            unavailableSince: nil
        )

        if record.currentToken != token {
            record.currentToken = token
            changed = true
        }
        if record.exitRequestedByCommand {
            record.exitRequestedByCommand = false
            changed = true
        }
        if record.transition != .enterRequested {
            record.transition = .enterRequested
            changed = true
        }
        if record.availability != .present {
            record.availability = .present
            changed = true
        }
        if record.unavailableSince != nil {
            record.unavailableSince = nil
            changed = true
        }
        changed = applyNativeFullscreenRestoreState(
            to: &record,
            restoreSnapshot: resolvedRestoreSnapshot,
            restoreFailure: restoreFailure
        ) || changed
        if existing == nil || changed {
            upsertNativeFullscreenRecord(record)
        }

        return changed || existing == nil
    }

    @discardableResult
    func markNativeFullscreenSuspended(_ token: WindowToken) -> Bool {
        markNativeFullscreenSuspended(token, restoreSnapshot: nil)
    }

    @discardableResult
    func markNativeFullscreenSuspended(
        _ token: WindowToken,
        restoreSnapshot: NativeFullscreenRecord.RestoreSnapshot?,
        restoreFailure: NativeFullscreenRecord.RestoreFailure? = nil
    ) -> Bool {
        guard let entry = entry(for: token) else { return false }

        var changed = rememberFocus(token, in: entry.workspaceId)
        let resolvedRestoreSnapshot = restoreSnapshot
            ?? nativeFullscreenRestoreSnapshot(from: managedRestoreSnapshot(for: token))
        let originalToken = nativeFullscreenOriginalToken(for: token) ?? token
        let existing = nativeFullscreenRecordsByOriginalToken[originalToken]
        var record = existing ?? NativeFullscreenRecord(
            originalToken: originalToken,
            currentToken: token,
            workspaceId: entry.workspaceId,
            restoreSnapshot: resolvedRestoreSnapshot,
            restoreFailure: restoreFailure,
            exitRequestedByCommand: false,
            transition: .suspended,
            availability: .present,
            unavailableSince: nil
        )

        if record.currentToken != token {
            record.currentToken = token
            changed = true
        }
        if record.exitRequestedByCommand {
            record.exitRequestedByCommand = false
            changed = true
        }
        if record.transition != .suspended {
            record.transition = .suspended
            changed = true
        }
        if record.availability != .present {
            record.availability = .present
            changed = true
        }
        if record.unavailableSince != nil {
            record.unavailableSince = nil
            changed = true
        }
        changed = applyNativeFullscreenRestoreState(
            to: &record,
            restoreSnapshot: resolvedRestoreSnapshot,
            restoreFailure: restoreFailure
        ) || changed
        if existing == nil || changed {
            upsertNativeFullscreenRecord(record)
        }

        if layoutReason(for: token) != .nativeFullscreen {
            setLayoutReason(.nativeFullscreen, for: token)
            changed = true
        }
        changed = enterNonManagedFocus(appFullscreen: true) || changed
        markNativeFullscreenLifecycleTransition()
        return changed
    }

    @discardableResult
    func requestNativeFullscreenExit(
        _ token: WindowToken,
        initiatedByCommand: Bool
    ) -> Bool {
        let existing = nativeFullscreenRecord(for: token)
        if existing == nil, entry(for: token) == nil {
            return false
        }

        let originalToken = existing?.originalToken ?? token
        let workspaceId = existing?.workspaceId ?? workspace(for: token)
        guard let workspaceId else { return false }
        let resolvedRestoreSnapshot = existing?.restoreSnapshot
            ?? nativeFullscreenRestoreSnapshot(from: managedRestoreSnapshot(for: token))

        var record = existing ?? NativeFullscreenRecord(
            originalToken: originalToken,
            currentToken: token,
            workspaceId: workspaceId,
            restoreSnapshot: resolvedRestoreSnapshot,
            restoreFailure: existing?.restoreFailure,
            exitRequestedByCommand: initiatedByCommand,
            transition: .exitRequested,
            availability: .present,
            unavailableSince: nil
        )

        var changed = existing == nil
        if record.currentToken != token {
            record.currentToken = token
            changed = true
        }
        if record.exitRequestedByCommand != initiatedByCommand {
            record.exitRequestedByCommand = initiatedByCommand
            changed = true
        }
        if record.transition != .exitRequested {
            record.transition = .exitRequested
            changed = true
        }
        if record.availability != .present {
            record.availability = .present
            changed = true
        }
        if record.unavailableSince != nil {
            record.unavailableSince = nil
            changed = true
        }
        changed = applyNativeFullscreenRestoreState(
            to: &record,
            restoreSnapshot: resolvedRestoreSnapshot,
            restoreFailure: existing?.restoreFailure
        ) || changed
        if changed {
            upsertNativeFullscreenRecord(record)
        }

        return changed
    }

    @discardableResult
    func markNativeFullscreenTemporarilyUnavailable(
        _ token: WindowToken,
        now: Date = Date()
    ) -> NativeFullscreenRecord? {
        guard let originalToken = nativeFullscreenOriginalToken(for: token),
              var record = nativeFullscreenRecordsByOriginalToken[originalToken]
        else {
            return nil
        }

        if layoutReason(for: record.currentToken) != .nativeFullscreen {
            setLayoutReason(.nativeFullscreen, for: record.currentToken)
        }

        if record.currentToken != token {
            record.currentToken = token
        }
        record.availability = .temporarilyUnavailable
        if record.unavailableSince == nil {
            record.unavailableSince = now
        }
        upsertNativeFullscreenRecord(record)
        _ = setManagedAppFullscreen(false)
        return record
    }

    enum NativeFullscreenUnavailableMatch {
        case matched(NativeFullscreenRecord)
        case ambiguous
        case none
    }

    func nativeFullscreenUnavailableCandidate(
        for token: WindowToken,
        activeWorkspaceId _: WorkspaceDescriptor.ID?,
        replacementMetadata: ManagedReplacementMetadata?
    ) -> NativeFullscreenUnavailableMatch {
        let candidates = nativeFullscreenRecordsByOriginalToken.values.filter { record in
            guard record.currentToken.pid == token.pid,
                  record.availability == .temporarilyUnavailable
            else {
                return false
            }
            return true
        }
        guard !candidates.isEmpty else { return .none }

        let sameTokenMatches = candidates.filter { $0.currentToken == token }
        if sameTokenMatches.count == 1 {
            return .matched(sameTokenMatches[0])
        }
        if sameTokenMatches.count > 1 {
            return .ambiguous
        }

        if candidates.count == 1 {
            return .matched(candidates[0])
        }

        if let replacementMetadata {
            let metadataMatches = candidates.filter {
                nativeFullscreenRecord($0, matchesReplacementMetadata: replacementMetadata)
            }
            if metadataMatches.count == 1 {
                return .matched(metadataMatches[0])
            }
            if metadataMatches.count > 1 {
                return .ambiguous
            }
            if candidates.contains(where: {
                nativeFullscreenRecordHasComparableReplacementEvidence($0, replacementMetadata: replacementMetadata)
            }) {
                return .none
            }
        }

        return .ambiguous
    }

    @discardableResult
    func attachNativeFullscreenReplacement(
        _ originalToken: WindowToken,
        to newToken: WindowToken
    ) -> Bool {
        guard var record = nativeFullscreenRecordsByOriginalToken[originalToken] else {
            return false
        }
        guard record.currentToken != newToken else { return false }
        record.currentToken = newToken
        upsertNativeFullscreenRecord(record)
        return true
    }

    @discardableResult
    func restoreNativeFullscreenRecord(for token: WindowToken) -> ParentKind? {
        let record = nativeFullscreenRecord(for: token)
        let resolvedToken = record?.currentToken ?? token
        if let record {
            _ = removeNativeFullscreenRecord(originalToken: record.originalToken)
        }
        let restoredParentKind = restoreFromNativeState(for: resolvedToken)
        if nativeFullscreenRecordsByOriginalToken.isEmpty {
            _ = setManagedAppFullscreen(false)
        }
        return restoredParentKind
    }

    func nativeFullscreenCommandTarget(frontmostToken: WindowToken?) -> WindowToken? {
        if let frontmostToken,
           let record = nativeFullscreenRecord(for: frontmostToken),
           record.currentToken == frontmostToken,
           record.transition == .suspended || record.transition == .exitRequested
        {
            return record.currentToken
        }

        let candidates = nativeFullscreenRecordsByOriginalToken.values.filter {
            $0.transition == .suspended || $0.transition == .exitRequested
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0].currentToken
    }

    @discardableResult
    func expireStaleTemporarilyUnavailableNativeFullscreenRecords(
        now: Date = Date(),
        staleInterval: TimeInterval = staleUnavailableNativeFullscreenTimeout
    ) -> [WindowModel.Entry] {
        let expiredOriginalTokens = nativeFullscreenRecordsByOriginalToken.values.compactMap { record -> WindowToken? in
            guard record.availability == .temporarilyUnavailable,
                  let unavailableSince = record.unavailableSince,
                  now.timeIntervalSince(unavailableSince) >= staleInterval
            else {
                return nil
            }
            return record.originalToken
        }

        guard !expiredOriginalTokens.isEmpty else { return [] }

        var removedEntries: [WindowModel.Entry] = []
        removedEntries.reserveCapacity(expiredOriginalTokens.count)

        for originalToken in expiredOriginalTokens {
            guard let record = removeNativeFullscreenRecord(originalToken: originalToken) else {
                continue
            }
            if layoutReason(for: record.currentToken) == .nativeFullscreen {
                _ = restoreFromNativeState(for: record.currentToken)
            }
            if let removed = removeWindow(
                pid: record.currentToken.pid,
                windowId: record.currentToken.windowId
            ) {
                removedEntries.append(removed)
            }
        }

        return removedEntries
    }

    @discardableResult
    func rememberFocus(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        let mode = windowMode(for: token) ?? .tiling
        return setRememberedFocus(
            token,
            in: workspaceId,
            mode: mode,
            focus: &sessionState.focus
        )
    }

    @discardableResult
    func syncWorkspaceFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor _: Monitor.ID? = nil
    ) -> Bool {
        rememberFocus(token, in: workspaceId)
    }

    @discardableResult
    func commitWorkspaceSelection(
        nodeId: NodeId?,
        focusedToken: WindowToken?,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil
    ) -> Bool {
        var changed = false

        if let nodeId {
            let currentSelection = niriViewportState(for: workspaceId).selectedNodeId
            if currentSelection != nodeId {
                withNiriViewportState(for: workspaceId) { $0.selectedNodeId = nodeId }
                changed = true
            }
        }

        if let focusedToken {
            changed = syncWorkspaceFocus(
                focusedToken,
                in: workspaceId,
                onMonitor: monitorId
            ) || changed
        }

        return changed
    }

    @discardableResult
    func applySessionPatch(_ patch: WorkspaceSessionPatch) -> Bool {
        guard let plan = WorkspaceSessionKernel.applySessionPatch(
            manager: self,
            patch: patch
        ), plan.outcome == .apply else {
            return false
        }

        var changed = false

        if var viewportState = patch.viewportState,
           plan.patchViewportAction != .none
        {
            if plan.patchViewportAction == .preserveCurrent {
                let currentState = niriViewportState(for: patch.workspaceId)
                viewportState.viewOffsetPixels = currentState.viewOffsetPixels
                viewportState.activeColumnIndex = currentState.activeColumnIndex
            }
            updateNiriViewportState(viewportState, for: patch.workspaceId)
            changed = true
        }

        if plan.shouldRememberFocus,
           let rememberedFocusToken = patch.rememberedFocusToken
        {
            changed = rememberFocus(rememberedFocusToken, in: patch.workspaceId) || changed
        }

        return changed
    }

    @discardableResult
    func applySessionTransfer(_ transfer: WorkspaceSessionTransfer) -> Bool {
        var changed = false

        if let sourcePatch = transfer.sourcePatch {
            changed = applySessionPatch(sourcePatch) || changed
        }

        if let targetPatch = transfer.targetPatch {
            changed = applySessionPatch(targetPatch) || changed
        }

        return changed
    }

    func lastFocusedToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        sessionState.focus.lastTiledFocusedByWorkspace[workspaceId]
    }

    func lastFloatingFocusedToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        sessionState.focus.lastFloatingFocusedByWorkspace[workspaceId]
    }

    func preferredFocusToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        WorkspaceSessionKernel.resolvePreferredFocus(
            manager: self,
            workspaceId: workspaceId
        )?.resolvedFocusToken
    }

    func resolveWorkspaceFocusToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        WorkspaceSessionKernel.resolveWorkspaceFocus(
            manager: self,
            workspaceId: workspaceId
        )?.resolvedFocusToken
    }

    @discardableResult
    func resolveAndSetWorkspaceFocusToken(
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor _: Monitor.ID? = nil
    ) -> WindowToken? {
        guard let plan = WorkspaceSessionKernel.resolveWorkspaceFocus(
            manager: self,
            workspaceId: workspaceId
        ) else {
            return nil
        }

        if let token = plan.resolvedFocusToken {
            _ = rememberFocus(token, in: workspaceId)
            return token
        }

        _ = updateFocusSession(notify: true) { focus in
            switch plan.focusClearAction {
            case .none:
                return false
            case .pending:
                return self.clearPendingManagedFocusRequest(
                    matching: nil,
                    workspaceId: workspaceId,
                    focus: &focus
                )
            case .pendingAndConfirmed:
                var focusChanged = self.clearPendingManagedFocusRequest(
                    matching: nil,
                    workspaceId: workspaceId,
                    focus: &focus
                )
                if let confirmed = focus.focusedToken,
                   self.entry(for: confirmed)?.workspaceId == workspaceId
                {
                    focus.focusedToken = nil
                    focus.isAppFullscreenActive = false
                    focusChanged = true
                }
                return focusChanged
            }
        }

        return nil
    }

    @discardableResult
    func enterNonManagedFocus(
        appFullscreen: Bool,
        preserveFocusedToken: Bool = false
    ) -> Bool {
        let changed = applyFocusReconcileEvent(
            .nonManagedFocusChanged(
                active: true,
                appFullscreen: appFullscreen,
                preserveFocusedToken: preserveFocusedToken,
                source: .workspaceManager
            )
        )
        if changed {
            notifySessionStateChanged()
        }
        return changed
    }

    func handleWindowRemoved(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID?) {
        let focusChanged = updateFocusSession(notify: false) { focus in
            self.clearRememberedFocus(
                token,
                workspaceId: workspaceId,
                focus: &focus
            )
        }
        let scratchpadChanged = clearScratchpadToken(matching: token, notify: false)
        if focusChanged || scratchpadChanged {
            notifySessionStateChanged()
        }
    }

    @discardableResult
    private func updateFocusSession(
        notify: Bool,
        _ mutate: (inout WorkspaceSessionState.FocusSession) -> Bool
    ) -> Bool {
        let changed = mutate(&sessionState.focus)
        if changed, notify {
            notifySessionStateChanged()
        }
        return changed
    }

    private func applyConfirmedManagedFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        appFullscreen: Bool,
        focus: inout WorkspaceSessionState.FocusSession
    ) -> Bool {
        var changed = false
        let mode = windowMode(for: token) ?? .tiling

        if focus.focusedToken != token {
            focus.focusedToken = token
            changed = true
        }
        changed = setRememberedFocus(token, in: workspaceId, mode: mode, focus: &focus) || changed
        if focus.isNonManagedFocusActive {
            focus.isNonManagedFocusActive = false
            changed = true
        }
        if focus.isAppFullscreenActive != appFullscreen {
            focus.isAppFullscreenActive = appFullscreen
            changed = true
        }

        return changed
    }

    private func updatePendingManagedFocusRequest(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        focus: inout WorkspaceSessionState.FocusSession
    ) -> Bool {
        var changed = false

        if focus.pendingManagedFocus.token != token {
            focus.pendingManagedFocus.token = token
            changed = true
        }
        if focus.pendingManagedFocus.workspaceId != workspaceId {
            focus.pendingManagedFocus.workspaceId = workspaceId
            changed = true
        }
        if focus.pendingManagedFocus.monitorId != monitorId {
            focus.pendingManagedFocus.monitorId = monitorId
            changed = true
        }

        return changed
    }

    private func clearPendingManagedFocusRequest(
        focus: inout WorkspaceSessionState.FocusSession
    ) -> Bool {
        guard focus.pendingManagedFocus.token != nil
            || focus.pendingManagedFocus.workspaceId != nil
            || focus.pendingManagedFocus.monitorId != nil
        else {
            return false
        }
        focus.pendingManagedFocus = .init()
        return true
    }

    private func clearPendingManagedFocusRequest(
        matching token: WindowToken?,
        workspaceId: WorkspaceDescriptor.ID?,
        focus: inout WorkspaceSessionState.FocusSession
    ) -> Bool {
        let request = focus.pendingManagedFocus
        let matchesHandle = token.map { request.token == $0 } ?? true
        let matchesWorkspace = workspaceId.map { request.workspaceId == $0 } ?? true
        guard matchesHandle, matchesWorkspace else { return false }
        guard request.token != nil || request.workspaceId != nil || request.monitorId != nil else { return false }
        focus.pendingManagedFocus = .init()
        return true
    }

    private func setRememberedFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode,
        focus: inout WorkspaceSessionState.FocusSession
    ) -> Bool {
        switch mode {
        case .tiling:
            guard focus.lastTiledFocusedByWorkspace[workspaceId] != token else { return false }
            focus.lastTiledFocusedByWorkspace[workspaceId] = token
            return true
        case .floating:
            guard focus.lastFloatingFocusedByWorkspace[workspaceId] != token else { return false }
            focus.lastFloatingFocusedByWorkspace[workspaceId] = token
            return true
        }
    }

    private func clearRememberedFocus(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID?,
        focus: inout WorkspaceSessionState.FocusSession
    ) -> Bool {
        var changed = false

        if let workspaceId {
            if focus.lastTiledFocusedByWorkspace[workspaceId] == token {
                focus.lastTiledFocusedByWorkspace[workspaceId] = nil
                changed = true
            }
            if focus.lastFloatingFocusedByWorkspace[workspaceId] == token {
                focus.lastFloatingFocusedByWorkspace[workspaceId] = nil
                changed = true
            }
            return changed
        }

        for (id, rememberedToken) in focus.lastTiledFocusedByWorkspace where rememberedToken == token {
            focus.lastTiledFocusedByWorkspace[id] = nil
            changed = true
        }
        for (id, rememberedToken) in focus.lastFloatingFocusedByWorkspace where rememberedToken == token {
            focus.lastFloatingFocusedByWorkspace[id] = nil
            changed = true
        }

        return changed
    }

    private func replaceRememberedFocus(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        focus: inout WorkspaceSessionState.FocusSession
    ) -> Bool {
        var changed = false

        for (workspaceId, token) in focus.lastTiledFocusedByWorkspace where token == oldToken {
            focus.lastTiledFocusedByWorkspace[workspaceId] = newToken
            changed = true
        }
        for (workspaceId, token) in focus.lastFloatingFocusedByWorkspace where token == oldToken {
            focus.lastFloatingFocusedByWorkspace[workspaceId] = newToken
            changed = true
        }

        return changed
    }

    @discardableResult
    private func updateScratchpadToken(_ token: WindowToken?, notify: Bool) -> Bool {
        guard sessionState.scratchpadToken != token else { return false }
        sessionState.scratchpadToken = token
        if notify {
            notifySessionStateChanged()
        }
        return true
    }

    @discardableResult
    private func clearScratchpadToken(matching token: WindowToken, notify: Bool) -> Bool {
        guard sessionState.scratchpadToken == token else { return false }
        return updateScratchpadToken(nil, notify: notify)
    }

    private func reconcileRememberedFocusAfterModeChange(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        oldMode: TrackedWindowMode,
        newMode: TrackedWindowMode,
        focus: inout WorkspaceSessionState.FocusSession
    ) -> Bool {
        guard oldMode != newMode else { return false }

        var changed = false
        switch oldMode {
        case .tiling:
            if focus.lastTiledFocusedByWorkspace[workspaceId] == token {
                focus.lastTiledFocusedByWorkspace[workspaceId] = nil
                changed = true
            }
        case .floating:
            if focus.lastFloatingFocusedByWorkspace[workspaceId] == token {
                focus.lastFloatingFocusedByWorkspace[workspaceId] = nil
                changed = true
            }
        }

        if focus.focusedToken == token || focus.pendingManagedFocus.token == token {
            changed = setRememberedFocus(token, in: workspaceId, mode: newMode, focus: &focus) || changed
        }

        return changed
    }

    private func normalizedFloatingOrigin(
        for frame: CGRect,
        in visibleFrame: CGRect
    ) -> CGPoint {
        let availableWidth = max(0, visibleFrame.width - frame.width)
        let availableHeight = max(0, visibleFrame.height - frame.height)
        let normalizedX = availableWidth == 0 ? 0 : (frame.origin.x - visibleFrame.minX) / availableWidth
        let normalizedY = availableHeight == 0 ? 0 : (frame.origin.y - visibleFrame.minY) / availableHeight
        return CGPoint(
            x: min(max(0, normalizedX), 1),
            y: min(max(0, normalizedY), 1)
        )
    }

    private func rebuildMonitorIndexes() {
        _monitorsById = Dictionary(uniqueKeysWithValues: monitors.map { ($0.id, $0) })
        var byName: [String: [Monitor]] = [:]
        for monitor in monitors {
            byName[monitor.name, default: []].append(monitor)
        }
        for key in byName.keys {
            byName[key] = Monitor.sortedByPosition(byName[key] ?? [])
        }
        _monitorsByName = byName
        invalidateWorkspaceProjectionCaches()
    }

    private func invalidateWorkspaceProjectionCaches() {
        _cachedWorkspaceMonitorProjection = nil
        _cachedWorkspaceIdsByMonitor = nil
        _cachedVisibleWorkspaceIds = nil
        _cachedVisibleWorkspaceMap = nil
        _cachedMonitorIdByVisibleWorkspace = nil
    }

    private func workspaceMonitorProjectionMap(
        in monitors: [Monitor]
    ) -> [WorkspaceDescriptor.ID: WorkspaceMonitorProjection] {
        if monitors == self.monitors,
           let cached = _cachedWorkspaceMonitorProjection
        {
            return cached
        }

        guard let plan = WorkspaceSessionKernel.project(
            manager: self,
            monitors: monitors
        ) else {
            return monitors == self.monitors ? (_cachedWorkspaceMonitorProjection ?? [:]) : [:]
        }
        let projections = Dictionary(uniqueKeysWithValues: plan.workspaceProjections.map {
            (
                $0.workspaceId,
                WorkspaceMonitorProjection(
                    projectedMonitorId: $0.projectedMonitorId,
                    homeMonitorId: $0.homeMonitorId,
                    effectiveMonitorId: $0.effectiveMonitorId
                )
            )
        })

        if monitors == self.monitors {
            _cachedWorkspaceMonitorProjection = projections
        }

        return projections
    }

    private func cacheCurrentWorkspaceProjectionPlan(_ plan: WorkspaceSessionKernel.Plan) {
        guard !plan.workspaceProjections.isEmpty else { return }
        _cachedWorkspaceMonitorProjection = Dictionary(
            uniqueKeysWithValues: plan.workspaceProjections.map {
                (
                    $0.workspaceId,
                    WorkspaceMonitorProjection(
                        projectedMonitorId: $0.projectedMonitorId,
                        homeMonitorId: $0.homeMonitorId,
                        effectiveMonitorId: $0.effectiveMonitorId
                    )
                )
            }
        )
    }

    private func cacheCurrentWorkspaceProjectionRecords(
        _ records: [TopologyWorkspaceProjectionRecord]
    ) {
        guard !records.isEmpty else {
            _cachedWorkspaceMonitorProjection = nil
            return
        }
        _cachedWorkspaceMonitorProjection = Dictionary(
            uniqueKeysWithValues: records.map {
                (
                    $0.workspaceId,
                    WorkspaceMonitorProjection(
                        projectedMonitorId: $0.projectedMonitorId,
                        homeMonitorId: $0.homeMonitorId,
                        effectiveMonitorId: $0.effectiveMonitorId
                    )
                )
            }
        )
    }

    private func refreshCurrentWorkspaceProjectionCache() {
        _cachedWorkspaceMonitorProjection = nil
        _ = workspaceMonitorProjectionMap(in: monitors)
    }

    @discardableResult
    private func applyWorkspaceSessionInteractionState(
        from plan: WorkspaceSessionKernel.Plan,
        notify: Bool
    ) -> Bool {
        applyWorkspaceSessionInteractionState(
            interactionMonitorId: plan.interactionMonitorId,
            previousInteractionMonitorId: plan.previousInteractionMonitorId,
            notify: notify
        )
    }

    @discardableResult
    private func applyWorkspaceSessionInteractionState(
        interactionMonitorId: Monitor.ID?,
        previousInteractionMonitorId: Monitor.ID?,
        notify: Bool
    ) -> Bool {
        let changed = sessionState.interactionMonitorId != interactionMonitorId
            || sessionState.previousInteractionMonitorId != previousInteractionMonitorId
        sessionState.interactionMonitorId = interactionMonitorId
        sessionState.previousInteractionMonitorId = previousInteractionMonitorId
        if changed, notify {
            notifySessionStateChanged()
        }
        return changed
    }

    @discardableResult
    private func applyWorkspaceSessionMonitorStates(
        _ states: [WorkspaceSessionKernel.MonitorState],
        notify: Bool,
        updateVisibleAnchors: Bool
    ) -> Bool {
        var changed = false
        var nextMonitorSessions = sessionState.monitorSessions

        for state in states {
            let existing = nextMonitorSessions[state.monitorId]
            let hasExisting = existing != nil
            let visibleChanged = existing?.visibleWorkspaceId != state.visibleWorkspaceId
            let previousChanged = existing?.previousVisibleWorkspaceId != state.previousVisibleWorkspaceId

            if state.visibleWorkspaceId == nil, state.previousVisibleWorkspaceId == nil {
                if hasExisting {
                    nextMonitorSessions.removeValue(forKey: state.monitorId)
                    changed = true
                }
                continue
            }

            if visibleChanged || previousChanged || !hasExisting {
                nextMonitorSessions[state.monitorId] = WorkspaceSessionState.MonitorSession(
                    visibleWorkspaceId: state.visibleWorkspaceId,
                    previousVisibleWorkspaceId: state.previousVisibleWorkspaceId
                )
                changed = true
            }
        }

        if changed {
            sessionState.monitorSessions = nextMonitorSessions
            invalidateWorkspaceProjectionCaches()
        }

        if updateVisibleAnchors {
            for state in states {
                guard let workspaceId = state.visibleWorkspaceId,
                      let monitor = monitor(byId: state.monitorId)
                else {
                    continue
                }
                if descriptor(for: workspaceId)?.assignedMonitorPoint != monitor.workspaceAnchorPoint {
                    updateWorkspace(workspaceId) { workspace in
                        workspace.assignedMonitorPoint = monitor.workspaceAnchorPoint
                    }
                    changed = true
                }
            }
        }

        if changed, notify {
            notifySessionStateChanged()
        }

        return changed
    }

    @discardableResult
    private func replaceWorkspaceSessionMonitorStates(
        _ states: [TopologyMonitorSessionState],
        notify: Bool,
        updateVisibleAnchors: Bool
    ) -> Bool {
        let nextMonitorSessions: [Monitor.ID: WorkspaceSessionState.MonitorSession] = Dictionary(
            uniqueKeysWithValues: states.compactMap { state in
                guard state.visibleWorkspaceId != nil || state.previousVisibleWorkspaceId != nil else {
                    return nil
                }
                return (
                    state.monitorId,
                    WorkspaceSessionState.MonitorSession(
                        visibleWorkspaceId: state.visibleWorkspaceId,
                        previousVisibleWorkspaceId: state.previousVisibleWorkspaceId
                    )
                )
            }
        )

        var changed = sessionState.monitorSessions != nextMonitorSessions
        if changed {
            sessionState.monitorSessions = nextMonitorSessions
            invalidateWorkspaceProjectionCaches()
        }

        if updateVisibleAnchors {
            for state in states {
                guard let workspaceId = state.visibleWorkspaceId,
                      let monitor = monitor(byId: state.monitorId)
                else {
                    continue
                }
                if descriptor(for: workspaceId)?.assignedMonitorPoint != monitor.workspaceAnchorPoint {
                    updateWorkspace(workspaceId) { workspace in
                        workspace.assignedMonitorPoint = monitor.workspaceAnchorPoint
                    }
                    changed = true
                }
            }
        }

        if changed, notify {
            notifySessionStateChanged()
        }

        return changed
    }

    @discardableResult
    private func applyVisibleWorkspaceReconciliation(
        notify: Bool
    ) -> Bool {
        guard let plan = WorkspaceSessionKernel.reconcileVisible(manager: self) else {
            return false
        }
        let monitorChanged = applyWorkspaceSessionMonitorStates(
            plan.monitorStates,
            notify: false,
            updateVisibleAnchors: true
        )
        let interactionChanged = applyWorkspaceSessionInteractionState(
            from: plan,
            notify: false
        )
        let changed = monitorChanged || interactionChanged
        if !plan.workspaceProjections.isEmpty {
            if changed {
                refreshCurrentWorkspaceProjectionCache()
            } else {
                cacheCurrentWorkspaceProjectionPlan(plan)
            }
        }
        if changed, notify {
            notifySessionStateChanged()
        }
        return changed
    }

    private func workspaceIdsByMonitor() -> [Monitor.ID: [WorkspaceDescriptor.ID]] {
        if let cached = _cachedWorkspaceIdsByMonitor {
            return cached
        }

        var workspaceIdsByMonitor: [Monitor.ID: [WorkspaceDescriptor.ID]] = [:]
        for workspace in sortedWorkspaces() {
            guard let monitorId = resolvedWorkspaceMonitorId(for: workspace.id) else { continue }
            workspaceIdsByMonitor[monitorId, default: []].append(workspace.id)
        }

        _cachedWorkspaceIdsByMonitor = workspaceIdsByMonitor
        return workspaceIdsByMonitor
    }

    private func visibleWorkspaceMap() -> [Monitor.ID: WorkspaceDescriptor.ID] {
        if let cached = _cachedVisibleWorkspaceMap {
            return cached
        }

        let visibleWorkspaceMap = activeVisibleWorkspaceMap(from: sessionState.monitorSessions)
        _cachedVisibleWorkspaceMap = visibleWorkspaceMap
        _cachedMonitorIdByVisibleWorkspace = Dictionary(
            uniqueKeysWithValues: visibleWorkspaceMap.map { ($0.value, $0.key) }
        )
        _cachedVisibleWorkspaceIds = Set(visibleWorkspaceMap.values)
        return visibleWorkspaceMap
    }

    var workspaces: [WorkspaceDescriptor] {
        sortedWorkspaces()
    }

    func descriptor(for id: WorkspaceDescriptor.ID) -> WorkspaceDescriptor? {
        workspacesById[id]
    }

    func workspaceId(for name: String, createIfMissing: Bool) -> WorkspaceDescriptor.ID? {
        if let existing = workspaceIdByName[name] {
            return existing
        }
        guard createIfMissing else { return nil }
        guard configuredWorkspaceNames().contains(name) else { return nil }
        return createWorkspace(named: name)
    }

    func workspaceId(named name: String) -> WorkspaceDescriptor.ID? {
        workspaceIdByName[name]
    }

    func workspaces(on monitorId: Monitor.ID) -> [WorkspaceDescriptor] {
        workspaceIdsByMonitor()[monitorId]?.compactMap(descriptor(for:)) ?? []
    }

    func primaryWorkspace() -> WorkspaceDescriptor? {
        let monitor = monitors.first(where: { $0.isMain }) ?? monitors.first
        guard let monitor else { return nil }
        return activeWorkspaceOrFirst(on: monitor.id)
    }

    func activeWorkspace(on monitorId: Monitor.ID) -> WorkspaceDescriptor? {
        currentActiveWorkspace(on: monitorId)
    }

    func currentActiveWorkspace(on monitorId: Monitor.ID) -> WorkspaceDescriptor? {
        guard let mon = monitor(byId: monitorId) else { return nil }
        guard let workspaceId = visibleWorkspaceId(on: mon.id) else { return nil }
        return descriptor(for: workspaceId)
    }

    func previousWorkspace(on monitorId: Monitor.ID) -> WorkspaceDescriptor? {
        guard let monitor = monitor(byId: monitorId) else { return nil }
        guard let prevId = previousVisibleWorkspaceId(on: monitor.id) else { return nil }
        guard prevId != visibleWorkspaceId(on: monitor.id) else { return nil }
        return descriptor(for: prevId)
    }

    func activeWorkspaceOrFirst(on monitorId: Monitor.ID) -> WorkspaceDescriptor? {
        if let active = activeWorkspace(on: monitorId) {
            return active
        }
        guard let plan = WorkspaceSessionKernel.project(
            manager: self,
            monitors: monitors
        ) else {
            return nil
        }
        cacheCurrentWorkspaceProjectionPlan(plan)
        guard let resolvedWorkspaceId = plan.monitorStates.first(where: { $0.monitorId == monitorId })?
            .resolvedActiveWorkspaceId
        else {
            return nil
        }
        guard setActiveWorkspaceInternal(resolvedWorkspaceId, on: monitorId) else { return nil }
        return descriptor(for: resolvedWorkspaceId)
    }

    func visibleWorkspaceIds() -> Set<WorkspaceDescriptor.ID> {
        if let cached = _cachedVisibleWorkspaceIds {
            return cached
        }
        return Set(visibleWorkspaceMap().values)
    }

    func focusWorkspace(named name: String) -> (workspace: WorkspaceDescriptor, monitor: Monitor)? {
        guard let workspaceId = workspaceId(for: name, createIfMissing: false) else { return nil }
        guard let targetMonitor = monitorForWorkspace(workspaceId) else { return nil }
        guard setActiveWorkspace(workspaceId, on: targetMonitor.id) else { return nil }
        guard let workspace = descriptor(for: workspaceId) else { return nil }
        return (workspace, targetMonitor)
    }

    func applySettings() {
        synchronizeConfiguredWorkspaces()
        reconcileConfiguredVisibleWorkspaces()
    }

    func applyMonitorConfigurationChange(_ newMonitors: [Monitor]) {
        _ = recordTopologyChange(to: newMonitors)
    }

    func setGaps(to size: Double) {
        let clamped = max(0, min(64, size))
        guard clamped != gaps else { return }
        gaps = clamped
        onGapsChanged?()
    }

    func setOuterGaps(left: Double, right: Double, top: Double, bottom: Double) {
        let newGaps = LayoutGaps.OuterGaps(
            left: max(0, CGFloat(left)),
            right: max(0, CGFloat(right)),
            top: max(0, CGFloat(top)),
            bottom: max(0, CGFloat(bottom))
        )
        if outerGaps.left == newGaps.left,
           outerGaps.right == newGaps.right,
           outerGaps.top == newGaps.top,
           outerGaps.bottom == newGaps.bottom
        {
            return
        }
        outerGaps = newGaps
        onGapsChanged?()
    }

    func monitorForWorkspace(_ workspaceId: WorkspaceDescriptor.ID) -> Monitor? {
        guard let monitorId = workspaceMonitorId(for: workspaceId) else { return nil }
        return monitor(byId: monitorId)
    }

    func monitor(for workspaceId: WorkspaceDescriptor.ID) -> Monitor? {
        monitorForWorkspace(workspaceId)
    }

    func monitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        monitorForWorkspace(workspaceId)?.id
    }

    @discardableResult
    func addWindow(
        _ ax: AXWindowRef,
        pid: pid_t,
        windowId: Int,
        to workspace: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode = .tiling,
        ruleEffects: ManagedWindowRuleEffects = .none,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> WindowToken {
        let token = windows.upsert(
            window: ax,
            pid: pid,
            windowId: windowId,
            workspace: workspace,
            mode: mode,
            ruleEffects: ruleEffects,
            managedReplacementMetadata: managedReplacementMetadata
        )
        recordReconcileEvent(
            .windowAdmitted(
                token: token,
                workspaceId: workspace,
                monitorId: monitorId(for: workspace),
                mode: mode,
                source: .workspaceManager
            )
        )
        return token
    }

    @discardableResult
    func rekeyWindow(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        newAXRef: AXWindowRef,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> WindowModel.Entry? {
        guard let entry = windows.rekeyWindow(
            from: oldToken,
            to: newToken,
            newAXRef: newAXRef,
            managedReplacementMetadata: managedReplacementMetadata
        ) else {
            return nil
        }

        if let originalToken = nativeFullscreenOriginalToken(for: oldToken),
           var record = nativeFullscreenRecordsByOriginalToken[originalToken]
        {
            record.currentToken = newToken
            upsertNativeFullscreenRecord(record)
        }

        recordReconcileEvent(
            .windowRekeyed(
                from: oldToken,
                to: newToken,
                workspaceId: entry.workspaceId,
                monitorId: monitorId(for: entry.workspaceId),
                reason: managedReplacementMetadata == nil ? .manualRekey : .managedReplacement,
                source: .workspaceManager
            )
        )

        let focusChanged = updateFocusSession(notify: false) { focus in
            self.replaceRememberedFocus(from: oldToken, to: newToken, focus: &focus)
        }

        let scratchpadChanged: Bool
        if sessionState.scratchpadToken == oldToken {
            sessionState.scratchpadToken = newToken
            scratchpadChanged = true
        } else {
            scratchpadChanged = false
        }

        if focusChanged || scratchpadChanged {
            notifySessionStateChanged()
        }

        if oldToken != newToken {
            onWindowRekeyed?(oldToken, newToken)
        }

        return entry
    }

    func entries(in workspace: WorkspaceDescriptor.ID) -> [WindowModel.Entry] {
        windows.windows(in: workspace)
    }

    func tiledEntries(in workspace: WorkspaceDescriptor.ID) -> [WindowModel.Entry] {
        windows.windows(in: workspace, mode: .tiling)
    }

    func barVisibleEntries(
        in workspace: WorkspaceDescriptor.ID,
        showFloatingWindows: Bool = false
    ) -> [WindowModel.Entry] {
        var entries = tiledEntries(in: workspace)
        if showFloatingWindows {
            entries.append(contentsOf: barVisibleFloatingEntries(in: workspace))
        }
        return entries
    }

    func hasTiledOccupancy(in workspace: WorkspaceDescriptor.ID) -> Bool {
        !tiledEntries(in: workspace).isEmpty
    }

    func hasBarVisibleOccupancy(
        in workspace: WorkspaceDescriptor.ID,
        showFloatingWindows: Bool = false
    ) -> Bool {
        !barVisibleEntries(in: workspace, showFloatingWindows: showFloatingWindows).isEmpty
    }

    func floatingEntries(in workspace: WorkspaceDescriptor.ID) -> [WindowModel.Entry] {
        windows.windows(in: workspace, mode: .floating)
    }

    private func barVisibleFloatingEntries(in workspace: WorkspaceDescriptor.ID) -> [WindowModel.Entry] {
        floatingEntries(in: workspace).filter { hiddenState(for: $0.token)?.isScratchpad != true }
    }

    func handle(for token: WindowToken) -> WindowHandle? {
        windows.handle(for: token)
    }

    func entry(for token: WindowToken) -> WindowModel.Entry? {
        windows.entry(for: token)
    }

    func entry(for handle: WindowHandle) -> WindowModel.Entry? {
        windows.entry(for: handle)
    }

    func entry(forPid pid: pid_t, windowId: Int) -> WindowModel.Entry? {
        windows.entry(forPid: pid, windowId: windowId)
    }

    func entries(forPid pid: pid_t) -> [WindowModel.Entry] {
        windows.entries(forPid: pid)
    }

    func entry(forWindowId windowId: Int) -> WindowModel.Entry? {
        windows.entry(forWindowId: windowId)
    }

    func entry(forWindowId windowId: Int, inVisibleWorkspaces: Bool) -> WindowModel.Entry? {
        guard inVisibleWorkspaces else {
            return windows.entry(forWindowId: windowId)
        }
        return windows.entry(forWindowId: windowId, inVisibleWorkspaces: visibleWorkspaceIds())
    }

    func allEntries() -> [WindowModel.Entry] {
        windows.allEntries()
    }

    func allTiledEntries() -> [WindowModel.Entry] {
        windows.allEntries(mode: .tiling)
    }

    func allFloatingEntries() -> [WindowModel.Entry] {
        windows.allEntries(mode: .floating)
    }

    func windowMode(for token: WindowToken) -> TrackedWindowMode? {
        windows.mode(for: token)
    }

    func lifecyclePhase(for token: WindowToken) -> WindowLifecyclePhase? {
        windows.lifecyclePhase(for: token)
    }

    func observedState(for token: WindowToken) -> ObservedWindowState? {
        windows.observedState(for: token)
    }

    func desiredState(for token: WindowToken) -> DesiredWindowState? {
        windows.desiredState(for: token)
    }

    func restoreIntent(for token: WindowToken) -> RestoreIntent? {
        windows.restoreIntent(for: token)
    }

    func replacementCorrelation(for token: WindowToken) -> ReplacementCorrelation? {
        windows.replacementCorrelation(for: token)
    }

    func managedReplacementMetadata(for token: WindowToken) -> ManagedReplacementMetadata? {
        windows.managedReplacementMetadata(for: token)
    }

    @discardableResult
    func setManagedReplacementMetadata(
        _ metadata: ManagedReplacementMetadata?,
        for token: WindowToken
    ) -> Bool {
        guard let entry = windows.entry(for: token) else {
            return false
        }
        let previousMetadata = windows.managedReplacementMetadata(for: token)
        windows.setManagedReplacementMetadata(metadata, for: token)
        guard previousMetadata != metadata else {
            return false
        }
        recordReconcileEvent(
            .managedReplacementMetadataChanged(
                token: token,
                workspaceId: entry.workspaceId,
                monitorId: monitorId(for: entry.workspaceId),
                source: .workspaceManager
            )
        )
        return true
    }

    @discardableResult
    func updateManagedReplacementFrame(
        _ frame: CGRect,
        for token: WindowToken
    ) -> Bool {
        guard var metadata = windows.managedReplacementMetadata(for: token) else {
            return false
        }
        guard metadata.frame != frame else {
            return false
        }
        metadata.frame = frame
        return setManagedReplacementMetadata(metadata, for: token)
    }

    @discardableResult
    func updateManagedReplacementTitle(
        _ title: String,
        for token: WindowToken
    ) -> Bool {
        guard var metadata = windows.managedReplacementMetadata(for: token) else {
            return false
        }
        guard metadata.title != title else {
            return false
        }
        metadata.title = title
        return setManagedReplacementMetadata(metadata, for: token)
    }

    @discardableResult
    func setWindowMode(_ mode: TrackedWindowMode, for token: WindowToken) -> Bool {
        guard let entry = entry(for: token) else { return false }
        let oldMode = entry.mode
        guard oldMode != mode else { return false }

        windows.setMode(mode, for: token)
        let workspaceId = entry.workspaceId
        let focusChanged = updateFocusSession(notify: false) { focus in
            self.reconcileRememberedFocusAfterModeChange(
                token,
                workspaceId: workspaceId,
                oldMode: oldMode,
                newMode: mode,
                focus: &focus
            )
        }
        if focusChanged {
            notifySessionStateChanged()
        }
        recordReconcileEvent(
            .windowModeChanged(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId(for: workspaceId),
                mode: mode,
                source: .workspaceManager
            )
        )
        return true
    }

    func floatingState(for token: WindowToken) -> WindowModel.FloatingState? {
        windows.floatingState(for: token)
    }

    func setFloatingState(_ state: WindowModel.FloatingState?, for token: WindowToken) {
        windows.setFloatingState(state, for: token)
        schedulePersistedWindowRestoreCatalogSave()
    }

    func manualLayoutOverride(for token: WindowToken) -> ManualWindowOverride? {
        windows.manualLayoutOverride(for: token)
    }

    func setManualLayoutOverride(_ override: ManualWindowOverride?, for token: WindowToken) {
        windows.setManualLayoutOverride(override, for: token)
    }

    func updateFloatingGeometry(
        frame: CGRect,
        for token: WindowToken,
        referenceMonitor: Monitor? = nil,
        restoreToFloating: Bool = true
    ) {
        guard let entry = entry(for: token) else { return }

        let resolvedReferenceMonitor = referenceMonitor
            ?? frame.center.monitorApproximation(in: monitors)
            ?? monitor(for: entry.workspaceId)
        let referenceVisibleFrame = resolvedReferenceMonitor?.visibleFrame ?? frame
        let normalizedOrigin = normalizedFloatingOrigin(
            for: frame,
            in: referenceVisibleFrame
        )

        windows.setFloatingState(
            .init(
                lastFrame: frame,
                normalizedOrigin: normalizedOrigin,
                referenceMonitorId: resolvedReferenceMonitor?.id,
                restoreToFloating: restoreToFloating
            ),
            for: token
        )
        recordReconcileEvent(
            .floatingGeometryUpdated(
                token: token,
                workspaceId: entry.workspaceId,
                referenceMonitorId: resolvedReferenceMonitor?.id,
                frame: frame,
                restoreToFloating: restoreToFloating,
                source: .workspaceManager
            )
        )
    }

    func resolvedFloatingFrame(
        for token: WindowToken,
        preferredMonitor: Monitor? = nil
    ) -> CGRect? {
        guard let entry = entry(for: token),
              let floatingState = floatingState(for: token)
        else {
            return nil
        }

        let targetMonitor = preferredMonitor
            ?? monitor(for: entry.workspaceId)
            ?? floatingState.referenceMonitorId.flatMap { monitor(byId: $0) }
        return restorePlanner.resolvedFloatingFrame(
            .init(
                floatingFrame: floatingState.lastFrame,
                normalizedOrigin: floatingState.normalizedOrigin,
                referenceMonitorId: floatingState.referenceMonitorId,
                targetMonitor: targetMonitor
            )
        )
    }

    func removeMissing(keys activeKeys: Set<WindowModel.WindowKey>, requiredConsecutiveMisses: Int = 1) {
        let confirmedMissingKeys = windows.confirmedMissingKeys(
            keys: activeKeys,
            requiredConsecutiveMisses: requiredConsecutiveMisses
        )
        var removedAny = false
        for key in confirmedMissingKeys {
            guard let entry = windows.entry(for: key) else { continue }
            _ = removeTrackedWindow(entry)
            removedAny = true
        }
        if removedAny {
            schedulePersistedWindowRestoreCatalogSave()
        }
    }

    @discardableResult
    func removeWindow(
        pid: pid_t,
        windowId: Int
    ) -> WindowModel.Entry? {
        guard let entry = windows.entry(forPid: pid, windowId: windowId) else { return nil }
        let removedEntry = removeTrackedWindow(entry)
        schedulePersistedWindowRestoreCatalogSave()
        return removedEntry
    }

    @discardableResult
    func removeWindowsForApp(pid: pid_t) -> Set<WorkspaceDescriptor.ID> {
        var affectedWorkspaces: Set<WorkspaceDescriptor.ID> = []
        let entriesToRemove = entries(forPid: pid)

        for entry in entriesToRemove {
            affectedWorkspaces.insert(entry.workspaceId)
            _ = removeTrackedWindow(entry)
        }

        if !entriesToRemove.isEmpty {
            schedulePersistedWindowRestoreCatalogSave()
        }

        return affectedWorkspaces
    }

    @discardableResult
    private func removeTrackedWindow(_ entry: WindowModel.Entry) -> WindowModel.Entry {
        recordReconcileEvent(
            .windowRemoved(
                token: entry.token,
                workspaceId: entry.workspaceId,
                source: .workspaceManager
            )
        )
        _ = removeNativeFullscreenRecord(containing: entry.token)
        handleWindowRemoved(entry.token, in: entry.workspaceId)
        _ = windows.removeWindow(key: entry.token)
        onWindowRemoved?(entry.token)
        return entry
    }

    func setWorkspace(for token: WindowToken, to workspace: WorkspaceDescriptor.ID) {
        let previousWorkspace = windows.workspace(for: token)
        windows.updateWorkspace(for: token, workspace: workspace)
        recordReconcileEvent(
            .workspaceAssigned(
                token: token,
                from: previousWorkspace,
                to: workspace,
                monitorId: monitorId(for: workspace),
                source: .workspaceManager
            )
        )
    }

    func workspace(for token: WindowToken) -> WorkspaceDescriptor.ID? {
        windows.workspace(for: token)
    }

    func isHiddenInCorner(_ token: WindowToken) -> Bool {
        windows.isHiddenInCorner(token)
    }

    func setHiddenState(_ state: WindowModel.HiddenState?, for token: WindowToken) {
        windows.setHiddenState(state, for: token)
        if let workspaceId = workspace(for: token) {
            recordReconcileEvent(
                .hiddenStateChanged(
                    token: token,
                    workspaceId: workspaceId,
                    monitorId: monitorId(for: workspaceId),
                    hiddenState: state,
                    source: .workspaceManager
                )
            )
        }
    }

    func hiddenState(for token: WindowToken) -> WindowModel.HiddenState? {
        windows.hiddenState(for: token)
    }

    func layoutReason(for token: WindowToken) -> LayoutReason {
        windows.layoutReason(for: token)
    }

    func isNativeFullscreenSuspended(_ token: WindowToken) -> Bool {
        windows.isNativeFullscreenSuspended(token)
    }

    func setLayoutReason(_ reason: LayoutReason, for token: WindowToken) {
        windows.setLayoutReason(reason, for: token)
        guard let workspaceId = workspace(for: token) else { return }
        switch reason {
        case .nativeFullscreen:
            recordReconcileEvent(
                .nativeFullscreenTransition(
                    token: token,
                    workspaceId: workspaceId,
                    monitorId: monitorId(for: workspaceId),
                    isActive: true,
                    source: .workspaceManager
                )
            )
        case .macosHiddenApp, .standard:
            recordReconcileEvent(
                .nativeFullscreenTransition(
                    token: token,
                    workspaceId: workspaceId,
                    monitorId: monitorId(for: workspaceId),
                    isActive: false,
                    source: .workspaceManager
                )
            )
        }
    }

    func restoreFromNativeState(for token: WindowToken) -> ParentKind? {
        let restored = windows.restoreFromNativeState(for: token)
        if restored != nil, let workspaceId = workspace(for: token) {
            recordReconcileEvent(
                .nativeFullscreenTransition(
                    token: token,
                    workspaceId: workspaceId,
                    monitorId: monitorId(for: workspaceId),
                    isActive: false,
                    source: .workspaceManager
                )
            )
        }
        return restored
    }

    func isNativeFullscreenTemporarilyUnavailable(_ token: WindowToken) -> Bool {
        nativeFullscreenRecord(for: token)?.availability == .temporarilyUnavailable
    }

    private func nativeFullscreenOriginalToken(for token: WindowToken) -> WindowToken? {
        if nativeFullscreenRecordsByOriginalToken[token] != nil {
            return token
        }
        return nativeFullscreenOriginalTokenByCurrentToken[token]
    }

    private func nativeFullscreenRecord(
        _ record: NativeFullscreenRecord,
        matchesReplacementMetadata replacementMetadata: ManagedReplacementMetadata
    ) -> Bool {
        guard let capturedMetadata = nativeFullscreenCapturedReplacementMetadata(for: record) else {
            return false
        }

        guard managedReplacementBundleIdsMatch(capturedMetadata.bundleId, replacementMetadata.bundleId) else {
            return false
        }

        if let capturedRole = capturedMetadata.role,
           let replacementRole = replacementMetadata.role,
           capturedRole != replacementRole
        {
            return false
        }

        if let capturedSubrole = capturedMetadata.subrole,
           let replacementSubrole = replacementMetadata.subrole,
           capturedSubrole != replacementSubrole
        {
            return false
        }

        if let capturedLevel = capturedMetadata.windowLevel,
           let replacementLevel = replacementMetadata.windowLevel,
           capturedLevel != replacementLevel
        {
            return false
        }

        var hasExactEvidence = false
        if let capturedParent = capturedMetadata.parentWindowId,
           let replacementParent = replacementMetadata.parentWindowId
        {
            guard capturedParent == replacementParent else { return false }
            hasExactEvidence = true
        }

        if let capturedTitle = trimmedNonEmpty(capturedMetadata.title),
           let replacementTitle = trimmedNonEmpty(replacementMetadata.title)
        {
            guard capturedTitle == replacementTitle else { return false }
            hasExactEvidence = true
        }

        if let capturedFrame = capturedMetadata.frame,
           let replacementFrame = replacementMetadata.frame,
           framesAreCloseForNativeFullscreenReplacement(capturedFrame, replacementFrame)
        {
            hasExactEvidence = true
        }

        return hasExactEvidence
    }

    private func nativeFullscreenCapturedReplacementMetadata(
        for record: NativeFullscreenRecord
    ) -> ManagedReplacementMetadata? {
        managedReplacementMetadata(for: record.currentToken)
            ?? managedReplacementMetadata(for: record.originalToken)
            ?? record.restoreSnapshot?.replacementMetadata
            ?? managedRestoreSnapshot(for: record.originalToken)?.replacementMetadata
            ?? managedRestoreSnapshot(for: record.currentToken)?.replacementMetadata
    }

    private func nativeFullscreenRecordHasComparableReplacementEvidence(
        _ record: NativeFullscreenRecord,
        replacementMetadata: ManagedReplacementMetadata
    ) -> Bool {
        guard let capturedMetadata = nativeFullscreenCapturedReplacementMetadata(for: record) else {
            return false
        }
        if capturedMetadata.parentWindowId != nil,
           replacementMetadata.parentWindowId != nil
        {
            return true
        }
        if trimmedNonEmpty(capturedMetadata.title) != nil,
           trimmedNonEmpty(replacementMetadata.title) != nil
        {
            return true
        }
        if capturedMetadata.frame != nil,
           replacementMetadata.frame != nil
        {
            return true
        }
        return false
    }

    private func managedReplacementBundleIdsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs?.lowercased(), rhs?.lowercased()) {
        case let (lhs?, rhs?):
            lhs == rhs
        default:
            true
        }
    }

    private func framesAreCloseForNativeFullscreenReplacement(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.midX - rhs.midX) <= 96
            && abs(lhs.midY - rhs.midY) <= 96
            && abs(lhs.width - rhs.width) <= 64
            && abs(lhs.height - rhs.height) <= 64
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func upsertNativeFullscreenRecord(_ record: NativeFullscreenRecord) {
        if let previous = nativeFullscreenRecordsByOriginalToken[record.originalToken] {
            nativeFullscreenOriginalTokenByCurrentToken.removeValue(forKey: previous.currentToken)
        }
        nativeFullscreenRecordsByOriginalToken[record.originalToken] = record
        nativeFullscreenOriginalTokenByCurrentToken[record.currentToken] = record.originalToken
    }

    @discardableResult
    private func removeNativeFullscreenRecord(originalToken: WindowToken) -> NativeFullscreenRecord? {
        guard let record = nativeFullscreenRecordsByOriginalToken.removeValue(forKey: originalToken) else {
            return nil
        }
        nativeFullscreenOriginalTokenByCurrentToken.removeValue(forKey: record.currentToken)
        return record
    }

    @discardableResult
    private func removeNativeFullscreenRecord(containing token: WindowToken) -> NativeFullscreenRecord? {
        guard let originalToken = nativeFullscreenOriginalToken(for: token) else {
            return nil
        }
        return removeNativeFullscreenRecord(originalToken: originalToken)
    }

    func cachedConstraints(for token: WindowToken, maxAge: TimeInterval = 5.0) -> WindowSizeConstraints? {
        windows.cachedConstraints(for: token, maxAge: maxAge)
    }

    func setCachedConstraints(_ constraints: WindowSizeConstraints, for token: WindowToken) {
        windows.setCachedConstraints(constraints, for: token)
    }

    @discardableResult
    func moveWorkspaceToMonitor(_ workspaceId: WorkspaceDescriptor.ID, to targetMonitorId: Monitor.ID) -> Bool {
        guard let targetMonitor = monitor(byId: targetMonitorId) else { return false }
        guard let sourceMonitor = monitorForWorkspace(workspaceId) else { return false }

        if sourceMonitor.id == targetMonitor.id { return false }

        guard isValidAssignment(workspaceId: workspaceId, monitorId: targetMonitor.id) else { return false }

        guard setActiveWorkspaceInternal(
            workspaceId,
            on: targetMonitor.id,
            anchorPoint: targetMonitor.workspaceAnchorPoint,
            updateInteractionMonitor: true
        ) else {
            return false
        }

        replaceVisibleWorkspaceIfNeeded(on: sourceMonitor.id)

        return true
    }

    @discardableResult
    func swapWorkspaces(
        _ workspace1Id: WorkspaceDescriptor.ID,
        on monitor1Id: Monitor.ID,
        with workspace2Id: WorkspaceDescriptor.ID,
        on monitor2Id: Monitor.ID
    ) -> Bool {
        guard let monitor1 = monitor(byId: monitor1Id),
              let monitor2 = monitor(byId: monitor2Id),
              monitor1Id != monitor2Id else { return false }

        guard isValidAssignment(workspaceId: workspace1Id, monitorId: monitor2.id),
              isValidAssignment(workspaceId: workspace2Id, monitorId: monitor1.id) else { return false }

        let previousWorkspace1 = visibleWorkspaceId(on: monitor1.id)
        let previousWorkspace2 = visibleWorkspaceId(on: monitor2.id)

        updateMonitorSession(monitor1.id) { session in
            session.previousVisibleWorkspaceId = previousWorkspace1
            session.visibleWorkspaceId = workspace2Id
        }
        updateWorkspace(workspace2Id) { workspace in
            workspace.assignedMonitorPoint = monitor1.workspaceAnchorPoint
        }

        updateMonitorSession(monitor2.id) { session in
            session.previousVisibleWorkspaceId = previousWorkspace2
            session.visibleWorkspaceId = workspace1Id
        }
        updateWorkspace(workspace1Id) { workspace in
            workspace.assignedMonitorPoint = monitor2.workspaceAnchorPoint
        }

        notifySessionStateChanged()
        return true
    }

    func setActiveWorkspace(
        _ workspaceId: WorkspaceDescriptor.ID,
        on monitorId: Monitor.ID,
        updateInteractionMonitor: Bool = true
    ) -> Bool {
        guard let monitor = monitor(byId: monitorId) else { return false }
        return setActiveWorkspaceInternal(
            workspaceId,
            on: monitor.id,
            anchorPoint: monitor.workspaceAnchorPoint,
            updateInteractionMonitor: updateInteractionMonitor
        )
    }

    func assignWorkspaceToMonitor(_ workspaceId: WorkspaceDescriptor.ID, monitorId: Monitor.ID) {
        guard let monitor = monitor(byId: monitorId) else { return }
        guard isValidAssignment(workspaceId: workspaceId, monitorId: monitor.id) else { return }
        updateWorkspace(workspaceId) { $0.assignedMonitorPoint = monitor.workspaceAnchorPoint }
    }

    func niriViewportState(for workspaceId: WorkspaceDescriptor.ID) -> ViewportState {
        if let state = sessionState.workspaceSessions[workspaceId]?.niriViewportState {
            return state
        }
        var newState = ViewportState()
        newState.animationClock = animationClock
        return newState
    }

    func updateNiriViewportState(_ state: ViewportState, for workspaceId: WorkspaceDescriptor.ID) {
        var workspaceSession = sessionState.workspaceSessions[workspaceId] ?? WorkspaceSessionState.WorkspaceSession()
        workspaceSession.niriViewportState = state
        sessionState.workspaceSessions[workspaceId] = workspaceSession
    }

    func withNiriViewportState(
        for workspaceId: WorkspaceDescriptor.ID,
        _ mutate: (inout ViewportState) -> Void
    ) {
        var state = niriViewportState(for: workspaceId)
        mutate(&state)
        updateNiriViewportState(state, for: workspaceId)
    }

    func setSelection(_ nodeId: NodeId?, for workspaceId: WorkspaceDescriptor.ID) {
        withNiriViewportState(for: workspaceId) { $0.selectedNodeId = nodeId }
    }

    func updateAnimationClock(_ clock: AnimationClock?) {
        animationClock = clock
        for workspaceId in sessionState.workspaceSessions.keys {
            sessionState.workspaceSessions[workspaceId]?.niriViewportState?.animationClock = clock
        }
    }

    func garbageCollectUnusedWorkspaces(focusedWorkspaceId: WorkspaceDescriptor.ID?) {
        let configured = Set(configuredWorkspaceNames())
        var toRemove: [WorkspaceDescriptor.ID] = []
        for (id, workspace) in workspacesById {
            if configured.contains(workspace.name) {
                continue
            }
            if focusedWorkspaceId == id {
                continue
            }
            if !windows.windows(in: id).isEmpty {
                continue
            }
            toRemove.append(id)
        }

        for id in toRemove {
            workspacesById.removeValue(forKey: id)
            sessionState.workspaceSessions.removeValue(forKey: id)
            sessionState.focus.lastTiledFocusedByWorkspace.removeValue(forKey: id)
            sessionState.focus.lastFloatingFocusedByWorkspace.removeValue(forKey: id)
        }
        if !toRemove.isEmpty {
            _cachedSortedWorkspaces = nil
            workspaceIdByName = workspaceIdByName.filter { !toRemove.contains($0.value) }
            invalidateWorkspaceProjectionCaches()
            for monitorId in sessionState.monitorSessions.keys {
                updateMonitorSession(monitorId) { session in
                    if let visibleWorkspaceId = session.visibleWorkspaceId,
                       toRemove.contains(visibleWorkspaceId)
                    {
                        session.visibleWorkspaceId = nil
                    }
                    if let previousVisibleWorkspaceId = session.previousVisibleWorkspaceId,
                       toRemove.contains(previousVisibleWorkspaceId)
                    {
                        session.previousVisibleWorkspaceId = nil
                    }
                }
            }
        }
    }

    private func sortedWorkspaces() -> [WorkspaceDescriptor] {
        if let cached = _cachedSortedWorkspaces {
            return cached
        }
        let sorted = workspacesById.values.sorted { WorkspaceIDPolicy.sortsBefore($0.name, $1.name) }
        _cachedSortedWorkspaces = sorted
        return sorted
    }

    private func configuredWorkspaceNames() -> [String] {
        settings.configuredWorkspaceNames()
    }

    private func synchronizeConfiguredWorkspaces() {
        let configuredNames = configuredWorkspaceNames()
        let configuredSet = Set(configuredNames)

        for name in configuredNames {
            _ = workspaceId(for: name, createIfMissing: true)
        }

        let toRemove = workspacesById.compactMap { workspaceId, workspace -> WorkspaceDescriptor.ID? in
            guard !configuredSet.contains(workspace.name) else { return nil }
            guard windows.windows(in: workspaceId).isEmpty else { return nil }
            return workspaceId
        }
        removeWorkspaces(toRemove)
    }

    private func removeWorkspaces(_ ids: [WorkspaceDescriptor.ID]) {
        guard !ids.isEmpty else { return }

        let toRemove = Set(ids)
        for id in ids {
            workspacesById.removeValue(forKey: id)
            sessionState.workspaceSessions.removeValue(forKey: id)
            sessionState.focus.lastTiledFocusedByWorkspace.removeValue(forKey: id)
            sessionState.focus.lastFloatingFocusedByWorkspace.removeValue(forKey: id)
        }

        _cachedSortedWorkspaces = nil
        workspaceIdByName = workspaceIdByName.filter { !toRemove.contains($0.value) }
        invalidateWorkspaceProjectionCaches()

        for monitorId in sessionState.monitorSessions.keys {
            updateMonitorSession(monitorId) { session in
                if let visibleWorkspaceId = session.visibleWorkspaceId,
                   toRemove.contains(visibleWorkspaceId)
                {
                    session.visibleWorkspaceId = nil
                }
                if let previousVisibleWorkspaceId = session.previousVisibleWorkspaceId,
                   toRemove.contains(previousVisibleWorkspaceId)
                {
                    session.previousVisibleWorkspaceId = nil
                }
            }
        }
    }

    private func reconcileConfiguredVisibleWorkspaces(notify: Bool = true) {
        _ = applyVisibleWorkspaceReconciliation(notify: notify)
    }

    private func replaceVisibleWorkspaceIfNeeded(on monitorId: Monitor.ID) {
        guard monitor(byId: monitorId) != nil else { return }
        _ = applyVisibleWorkspaceReconciliation(notify: true)
    }

    private func resolvedWorkspaceMonitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        workspaceMonitorProjectionMap(in: monitors)[workspaceId]?.projectedMonitorId
    }

    private func workspaceMonitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        resolvedWorkspaceMonitorId(for: workspaceId)
    }

    private func homeMonitor(for workspaceId: WorkspaceDescriptor.ID, in monitors: [Monitor]) -> Monitor? {
        guard let monitorId = workspaceMonitorProjectionMap(in: monitors)[workspaceId]?.homeMonitorId else {
            return nil
        }
        return monitors.first(where: { $0.id == monitorId })
    }

    private func effectiveMonitor(for workspaceId: WorkspaceDescriptor.ID) -> Monitor? {
        effectiveMonitor(for: workspaceId, in: monitors)
    }

    private func effectiveMonitor(for workspaceId: WorkspaceDescriptor.ID, in monitors: [Monitor]) -> Monitor? {
        guard let monitorId = workspaceMonitorProjectionMap(in: monitors)[workspaceId]?.effectiveMonitorId else {
            return nil
        }
        return monitors.first(where: { $0.id == monitorId })
    }

    private func isValidAssignment(workspaceId: WorkspaceDescriptor.ID, monitorId: Monitor.ID) -> Bool {
        workspaceMonitorProjectionMap(in: monitors)[workspaceId]?.effectiveMonitorId == monitorId
    }

    private func setActiveWorkspaceInternal(
        _ workspaceId: WorkspaceDescriptor.ID,
        on monitorId: Monitor.ID,
        anchorPoint: CGPoint? = nil,
        updateInteractionMonitor: Bool = false,
        notify: Bool = true
    ) -> Bool {
        _ = anchorPoint
        guard let plan = WorkspaceSessionKernel.activateWorkspace(
            manager: self,
            workspaceId: workspaceId,
            monitorId: monitorId,
            updateInteractionMonitor: updateInteractionMonitor
        ), plan.outcome != .invalidTarget else {
            return false
        }

        let monitorChanged = applyWorkspaceSessionMonitorStates(
            plan.monitorStates,
            notify: false,
            updateVisibleAnchors: true
        )
        let interactionChanged = applyWorkspaceSessionInteractionState(
            from: plan,
            notify: false
        )
        let changed = monitorChanged || interactionChanged
        if !plan.workspaceProjections.isEmpty {
            if changed {
                refreshCurrentWorkspaceProjectionCache()
            } else {
                cacheCurrentWorkspaceProjectionPlan(plan)
            }
        }
        if changed, notify {
            notifySessionStateChanged()
        }
        return true
    }

    private func updateWorkspace(_ workspaceId: WorkspaceDescriptor.ID, update: (inout WorkspaceDescriptor) -> Void) {
        guard var workspace = workspacesById[workspaceId] else { return }
        let previousWorkspace = workspace
        let oldName = workspace.name
        update(&workspace)
        workspacesById[workspaceId] = workspace
        if workspace.name != oldName {
            workspaceIdByName.removeValue(forKey: oldName)
            workspaceIdByName[workspace.name] = workspaceId
        }
        if previousWorkspace != workspace {
            _cachedSortedWorkspaces = nil
        }
        invalidateWorkspaceProjectionCaches()
        if previousWorkspace != workspace {
            schedulePersistedWindowRestoreCatalogSave()
        }
    }

    private func createWorkspace(named name: String) -> WorkspaceDescriptor.ID? {
        guard let rawID = WorkspaceIDPolicy.normalizeRawID(name) else { return nil }
        guard configuredWorkspaceNames().contains(rawID) else { return nil }
        let workspace = WorkspaceDescriptor(name: rawID)
        workspacesById[workspace.id] = workspace
        workspaceIdByName[workspace.name] = workspace.id
        _cachedSortedWorkspaces = nil
        invalidateWorkspaceProjectionCaches()
        return workspace.id
    }

    private func visibleWorkspaceId(on monitorId: Monitor.ID) -> WorkspaceDescriptor.ID? {
        visibleWorkspaceMap()[monitorId]
    }

    private func previousVisibleWorkspaceId(on monitorId: Monitor.ID) -> WorkspaceDescriptor.ID? {
        sessionState.monitorSessions[monitorId]?.previousVisibleWorkspaceId
    }

    private func monitorIdShowingWorkspace(_ workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        if let cached = _cachedMonitorIdByVisibleWorkspace {
            return cached[workspaceId]
        }
        _ = visibleWorkspaceMap()
        return _cachedMonitorIdByVisibleWorkspace?[workspaceId]
    }

    private func activeVisibleWorkspaceMap(
        from monitorSessions: [Monitor.ID: WorkspaceSessionState.MonitorSession]
    ) -> [Monitor.ID: WorkspaceDescriptor.ID] {
        Dictionary(uniqueKeysWithValues: monitorSessions.compactMap { monitorId, session in
            guard let visibleWorkspaceId = session.visibleWorkspaceId else { return nil }
            return (monitorId, visibleWorkspaceId)
        })
    }

    private func updateMonitorSession(
        _ monitorId: Monitor.ID,
        _ mutate: (inout WorkspaceSessionState.MonitorSession) -> Void
    ) {
        var monitorSession = sessionState.monitorSessions[monitorId] ?? WorkspaceSessionState.MonitorSession()
        mutate(&monitorSession)
        if monitorSession.visibleWorkspaceId == nil, monitorSession.previousVisibleWorkspaceId == nil {
            sessionState.monitorSessions.removeValue(forKey: monitorId)
        } else {
            sessionState.monitorSessions[monitorId] = monitorSession
        }
        invalidateWorkspaceProjectionCaches()
    }

    @discardableResult
    private func updateInteractionMonitor(
        _ monitorId: Monitor.ID?,
        preservePrevious: Bool,
        notify: Bool
    ) -> Bool {
        guard let plan = WorkspaceSessionKernel.setInteractionMonitor(
            manager: self,
            monitorId: monitorId,
            preservePrevious: preservePrevious
        ) else {
            return false
        }
        return applyWorkspaceSessionInteractionState(from: plan, notify: notify)
    }

    private func reconcileInteractionMonitorState(notify: Bool = true) {
        guard let plan = WorkspaceSessionKernel.project(
            manager: self,
            monitors: monitors
        ) else {
            return
        }
        cacheCurrentWorkspaceProjectionPlan(plan)
        _ = applyWorkspaceSessionInteractionState(from: plan, notify: notify)
    }

    private func notifySessionStateChanged() {
        onSessionStateChanged?()
    }
}

extension WorkspaceManager {
    func nativeFullscreenRestoreContext(for token: WindowToken) -> NativeFullscreenRestoreContext? {
        guard let record = nativeFullscreenRecord(for: token),
              record.currentToken == token,
              record.transition == .restoring
        else {
            return nil
        }

        return NativeFullscreenRestoreContext(
            originalToken: record.originalToken,
            currentToken: record.currentToken,
            workspaceId: record.workspaceId,
            restoreFrame: record.restoreSnapshot?.frame,
            capturedTopologyProfile: record.restoreSnapshot?.topologyProfile,
            niriState: record.restoreSnapshot?.niriState,
            replacementMetadata: record.restoreSnapshot?.replacementMetadata
        )
    }

    @discardableResult
    func beginNativeFullscreenRestore(for token: WindowToken) -> NativeFullscreenRecord? {
        guard var record = nativeFullscreenRecord(for: token) else { return nil }

        let resolvedToken = record.currentToken == token ? record.currentToken : token
        var changed = false
        if record.currentToken != resolvedToken {
            record.currentToken = resolvedToken
            changed = true
        }
        guard record.restoreSnapshot != nil else {
            changed = ensureNativeFullscreenRestoreInvariant(on: &record) || changed
            if changed {
                upsertNativeFullscreenRecord(record)
            }
            return nil
        }
        if record.transition != .restoring {
            record.transition = .restoring
            changed = true
        }
        if record.availability != .present {
            record.availability = .present
            changed = true
        }
        if record.unavailableSince != nil {
            record.unavailableSince = nil
            changed = true
        }
        changed = ensureNativeFullscreenRestoreInvariant(on: &record) || changed
        if changed {
            upsertNativeFullscreenRecord(record)
        }

        markNativeFullscreenLifecycleTransition()
        _ = restoreFromNativeState(for: resolvedToken)
        return nativeFullscreenRecordsByOriginalToken[record.originalToken]
    }

    @discardableResult
    func finalizeNativeFullscreenRestore(for token: WindowToken) -> ParentKind? {
        guard let record = nativeFullscreenRecord(for: token),
              record.transition == .restoring
        else { return nil }

        let removed = removeNativeFullscreenRecord(originalToken: record.originalToken)
        if nativeFullscreenRecordsByOriginalToken.isEmpty {
            _ = setManagedAppFullscreen(false)
        }
        markNativeFullscreenLifecycleTransition()
        return removed.flatMap { _ in
            restoreFromNativeState(for: record.currentToken)
        }
    }

    @discardableResult
    private func applyNativeFullscreenRestoreState(
        to record: inout NativeFullscreenRecord,
        restoreSnapshot: NativeFullscreenRecord.RestoreSnapshot?,
        restoreFailure: NativeFullscreenRecord.RestoreFailure?
    ) -> Bool {
        var changed = false

        if record.restoreSnapshot == nil, let restoreSnapshot {
            record.restoreSnapshot = restoreSnapshot
            changed = true
        }

        if record.restoreSnapshot != nil {
            if record.restoreFailure != nil {
                record.restoreFailure = nil
                changed = true
            }
            return changed
        }

        if let restoreFailure,
           record.restoreFailure != restoreFailure
        {
            record.restoreFailure = restoreFailure
            changed = true
        }

        return changed
    }

    @discardableResult
    private func ensureNativeFullscreenRestoreInvariant(
        on record: inout NativeFullscreenRecord
    ) -> Bool {
        guard record.restoreSnapshot == nil else {
            if record.restoreFailure != nil {
                record.restoreFailure = nil
                return true
            }
            return false
        }

        let failure = record.restoreFailure ?? NativeFullscreenRecord.RestoreFailure(
            path: "restoring_invariant",
            detail: "entered restoring without a frozen pre-fullscreen restore snapshot"
        )
        let message =
            "[NativeFullscreenRestore] path=\(failure.path) token=\(record.currentToken) original=\(record.originalToken) detail=\(failure.detail)"
        if record.restoreFailure == nil {
            assertionFailure(message)
            record.restoreFailure = failure
            return true
        }

        return false
    }
}

private extension WorkspaceManager {
    @MainActor
    enum WorkspaceSessionKernel {
        enum Outcome {
            case noop
            case apply
            case invalidTarget
            case invalidPatch

            init?(kernelRawValue: UInt32) {
                switch kernelRawValue {
                case UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_NOOP):
                    self = .noop
                case UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_APPLY):
                    self = .apply
                case UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_INVALID_TARGET):
                    self = .invalidTarget
                case UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_INVALID_PATCH):
                    self = .invalidPatch
                default:
                    return nil
                }
            }
        }

        enum PatchViewportAction {
            case none
            case apply
            case preserveCurrent

            init?(kernelRawValue: UInt32) {
                switch kernelRawValue {
                case UInt32(OMNIWM_WORKSPACE_SESSION_PATCH_VIEWPORT_NONE):
                    self = .none
                case UInt32(OMNIWM_WORKSPACE_SESSION_PATCH_VIEWPORT_APPLY):
                    self = .apply
                case UInt32(OMNIWM_WORKSPACE_SESSION_PATCH_VIEWPORT_PRESERVE_CURRENT):
                    self = .preserveCurrent
                default:
                    return nil
                }
            }
        }

        enum FocusClearAction {
            case none
            case pending
            case pendingAndConfirmed

            init?(kernelRawValue: UInt32) {
                switch kernelRawValue {
                case UInt32(OMNIWM_WORKSPACE_SESSION_FOCUS_CLEAR_NONE):
                    self = .none
                case UInt32(OMNIWM_WORKSPACE_SESSION_FOCUS_CLEAR_PENDING):
                    self = .pending
                case UInt32(OMNIWM_WORKSPACE_SESSION_FOCUS_CLEAR_PENDING_AND_CONFIRMED):
                    self = .pendingAndConfirmed
                default:
                    return nil
                }
            }
        }

        struct MonitorState {
            var monitorId: Monitor.ID
            var visibleWorkspaceId: WorkspaceDescriptor.ID?
            var previousVisibleWorkspaceId: WorkspaceDescriptor.ID?
            var resolvedActiveWorkspaceId: WorkspaceDescriptor.ID?
        }

        struct WorkspaceProjectionRecord {
            var workspaceId: WorkspaceDescriptor.ID
            var projectedMonitorId: Monitor.ID?
            var homeMonitorId: Monitor.ID?
            var effectiveMonitorId: Monitor.ID?
        }

        struct Plan {
            var outcome: Outcome
            var patchViewportAction: PatchViewportAction
            var focusClearAction: FocusClearAction
            var interactionMonitorId: Monitor.ID?
            var previousInteractionMonitorId: Monitor.ID?
            var resolvedFocusToken: WindowToken?
            var monitorStates: [MonitorState]
            var workspaceProjections: [WorkspaceProjectionRecord]
            var shouldRememberFocus: Bool
        }

        private struct FocusSnapshot {
            var focusedWorkspaceId: WorkspaceDescriptor.ID?
            var pendingTiledToken: WindowToken?
            var pendingTiledWorkspaceId: WorkspaceDescriptor.ID?
            var confirmedTiledToken: WindowToken?
            var confirmedTiledWorkspaceId: WorkspaceDescriptor.ID?
            var confirmedFloatingToken: WindowToken?
            var confirmedFloatingWorkspaceId: WorkspaceDescriptor.ID?
        }

        private struct AssignmentSnapshot {
            var rawAssignmentKind: UInt32
            var specificDisplayId: UInt32?
            var specificDisplayName: String?
        }

        private struct PreviousMonitorSnapshot {
            var monitor: Monitor
            var visibleWorkspaceId: WorkspaceDescriptor.ID?
            var previousVisibleWorkspaceId: WorkspaceDescriptor.ID?
        }

        private struct DisconnectedCacheEntrySnapshot {
            var restoreKey: MonitorRestoreKey
            var workspaceId: WorkspaceDescriptor.ID
        }

        private struct DisconnectedCacheResultRecord {
            var sourceKind: UInt32
            var sourceIndex: Int
            var workspaceId: WorkspaceDescriptor.ID
        }

        private struct InvocationResult {
            var plan: Plan
            var disconnectedCacheResults: [DisconnectedCacheResultRecord]
            var refreshRestoreIntents: Bool
        }

        private struct KernelStringTable {
            private(set) var bytes = ContiguousArray<UInt8>()

            mutating func append(_ string: String?) -> (ref: omniwm_restore_string_ref, hasValue: UInt8) {
                guard let string else {
                    return (omniwm_restore_string_ref(offset: 0, length: 0), 0)
                }

                let utf8 = Array(string.utf8)
                let offset = bytes.count
                bytes.append(contentsOf: utf8)
                return (
                    omniwm_restore_string_ref(offset: offset, length: utf8.count),
                    1
                )
            }
        }

        static func project(
            manager: WorkspaceManager,
            monitors: [Monitor]
        ) -> Plan? {
            invoke(
                manager: manager,
                monitors: monitors,
                operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_PROJECT)
            )?.plan
        }

        static func reconcileVisible(
            manager: WorkspaceManager
        ) -> Plan? {
            invoke(
                manager: manager,
                monitors: manager.monitors,
                operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_RECONCILE_VISIBLE)
            )?.plan
        }

        static func activateWorkspace(
            manager: WorkspaceManager,
            workspaceId: WorkspaceDescriptor.ID,
            monitorId: Monitor.ID,
            updateInteractionMonitor: Bool
        ) -> Plan? {
            invoke(
                manager: manager,
                monitors: manager.monitors,
                operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_ACTIVATE_WORKSPACE),
                workspaceId: workspaceId,
                monitorId: monitorId,
                updateInteractionMonitor: updateInteractionMonitor,
                preservePreviousInteractionMonitor: true
            )?.plan
        }

        static func setInteractionMonitor(
            manager: WorkspaceManager,
            monitorId: Monitor.ID?,
            preservePrevious: Bool
        ) -> Plan? {
            invoke(
                manager: manager,
                monitors: manager.monitors,
                operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_SET_INTERACTION_MONITOR),
                monitorId: monitorId,
                preservePreviousInteractionMonitor: preservePrevious
            )?.plan
        }

        static func resolvePreferredFocus(
            manager: WorkspaceManager,
            workspaceId: WorkspaceDescriptor.ID
        ) -> Plan? {
            invoke(
                manager: manager,
                monitors: [],
                operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_RESOLVE_PREFERRED_FOCUS),
                workspaceId: workspaceId
            )?.plan
        }

        static func resolveWorkspaceFocus(
            manager: WorkspaceManager,
            workspaceId: WorkspaceDescriptor.ID
        ) -> Plan? {
            invoke(
                manager: manager,
                monitors: [],
                operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_RESOLVE_WORKSPACE_FOCUS),
                workspaceId: workspaceId
            )?.plan
        }

        static func applySessionPatch(
            manager: WorkspaceManager,
            patch: WorkspaceSessionPatch
        ) -> Plan? {
            invoke(
                manager: manager,
                monitors: [],
                operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_APPLY_SESSION_PATCH),
                workspaceId: patch.workspaceId,
                patch: patch
            )?.plan
        }

        static func reconcileTopology(
            manager: WorkspaceManager,
            newMonitors: [Monitor]
        ) -> TopologyTransitionPlan? {
            if WorkspaceManager.forceTopologyReconcileFailureForTests {
                return nil
            }
            let previousMonitors = previousMonitorSnapshots(manager: manager)
            let disconnectedCacheEntries = disconnectedCacheEntries(manager: manager)
            guard let result = invoke(
                manager: manager,
                monitors: newMonitors,
                previousMonitors: previousMonitors,
                operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_RECONCILE_TOPOLOGY),
                disconnectedCacheEntries: disconnectedCacheEntries
            ) else {
                return nil
            }

            var disconnectedCache: [MonitorRestoreKey: WorkspaceDescriptor.ID] = [:]
            disconnectedCache.reserveCapacity(result.disconnectedCacheResults.count)
            for entry in result.disconnectedCacheResults {
                let restoreKey: MonitorRestoreKey
                switch entry.sourceKind {
                case UInt32(OMNIWM_RESTORE_CACHE_SOURCE_EXISTING):
                    guard disconnectedCacheEntries.indices.contains(entry.sourceIndex) else { continue }
                    restoreKey = disconnectedCacheEntries[entry.sourceIndex].restoreKey
                case UInt32(OMNIWM_RESTORE_CACHE_SOURCE_REMOVED_MONITOR):
                    guard previousMonitors.indices.contains(entry.sourceIndex) else { continue }
                    restoreKey = MonitorRestoreKey(monitor: previousMonitors[entry.sourceIndex].monitor)
                default:
                    continue
                }
                disconnectedCache[restoreKey] = entry.workspaceId
            }

            return TopologyTransitionPlan(
                previousMonitors: previousMonitors.map(\.monitor),
                newMonitors: newMonitors,
                monitorStates: result.plan.monitorStates.map {
                    TopologyMonitorSessionState(
                        monitorId: $0.monitorId,
                        visibleWorkspaceId: $0.visibleWorkspaceId,
                        previousVisibleWorkspaceId: $0.previousVisibleWorkspaceId
                    )
                },
                workspaceProjections: result.plan.workspaceProjections.map {
                    TopologyWorkspaceProjectionRecord(
                        workspaceId: $0.workspaceId,
                        projectedMonitorId: $0.projectedMonitorId,
                        homeMonitorId: $0.homeMonitorId,
                        effectiveMonitorId: $0.effectiveMonitorId
                    )
                },
                disconnectedVisibleWorkspaceCache: disconnectedCache,
                interactionMonitorId: result.plan.interactionMonitorId,
                previousInteractionMonitorId: result.plan.previousInteractionMonitorId,
                refreshRestoreIntents: result.refreshRestoreIntents
            )
        }

        private static func invoke(
            manager: WorkspaceManager,
            monitors: [Monitor],
            previousMonitors: [PreviousMonitorSnapshot] = [],
            operation: UInt32,
            workspaceId: WorkspaceDescriptor.ID? = nil,
            monitorId: Monitor.ID? = nil,
            updateInteractionMonitor: Bool = false,
            preservePreviousInteractionMonitor: Bool = false,
            disconnectedCacheEntries: [DisconnectedCacheEntrySnapshot] = [],
            patch: WorkspaceSessionPatch? = nil
        ) -> InvocationResult? {
            let focusSnapshot = focusSnapshot(manager: manager)
            let sortedWorkspaces = manager.sortedWorkspaces()

            var stringTable = KernelStringTable()
            var rawMonitors = ContiguousArray<omniwm_workspace_session_monitor>()
            rawMonitors.reserveCapacity(monitors.count)
            for monitor in monitors {
                let session = manager.sessionState.monitorSessions[monitor.id]
                let encodedName = stringTable.append(monitor.name)
                rawMonitors.append(
                    omniwm_workspace_session_monitor(
                        monitor_id: monitor.id.displayId,
                        frame_min_x: monitor.frame.minX,
                        frame_max_y: monitor.frame.maxY,
                        frame_width: monitor.frame.width,
                        frame_height: monitor.frame.height,
                        anchor_x: monitor.workspaceAnchorPoint.x,
                        anchor_y: monitor.workspaceAnchorPoint.y,
                        visible_workspace_id: session?.visibleWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
                        previous_visible_workspace_id: session?.previousVisibleWorkspaceId
                            .map(encode(uuid:)) ?? zeroUUID(),
                        name: encodedName.ref,
                        is_main: monitor.isMain ? 1 : 0,
                        has_visible_workspace_id: session?.visibleWorkspaceId == nil ? 0 : 1,
                        has_previous_visible_workspace_id: session?.previousVisibleWorkspaceId == nil ? 0 : 1,
                        has_name: encodedName.hasValue
                    )
                )
            }

            var rawPreviousMonitors = ContiguousArray<omniwm_workspace_session_previous_monitor>()
            rawPreviousMonitors.reserveCapacity(previousMonitors.count)
            for previousMonitor in previousMonitors {
                let encodedName = stringTable.append(previousMonitor.monitor.name)
                rawPreviousMonitors.append(
                    omniwm_workspace_session_previous_monitor(
                        monitor_id: previousMonitor.monitor.id.displayId,
                        frame_min_x: previousMonitor.monitor.frame.minX,
                        frame_max_y: previousMonitor.monitor.frame.maxY,
                        frame_width: previousMonitor.monitor.frame.width,
                        frame_height: previousMonitor.monitor.frame.height,
                        anchor_x: previousMonitor.monitor.workspaceAnchorPoint.x,
                        anchor_y: previousMonitor.monitor.workspaceAnchorPoint.y,
                        visible_workspace_id: previousMonitor.visibleWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
                        previous_visible_workspace_id: previousMonitor.previousVisibleWorkspaceId
                            .map(encode(uuid:)) ?? zeroUUID(),
                        name: encodedName.ref,
                        has_visible_workspace_id: previousMonitor.visibleWorkspaceId == nil ? 0 : 1,
                        has_previous_visible_workspace_id: previousMonitor.previousVisibleWorkspaceId == nil ? 0 : 1,
                        has_name: encodedName.hasValue
                    )
                )
            }

            var rawWorkspaces = ContiguousArray<omniwm_workspace_session_workspace>()
            rawWorkspaces.reserveCapacity(sortedWorkspaces.count)
            for workspace in sortedWorkspaces {
                let assignment = assignmentSnapshot(manager: manager, workspace: workspace)
                let assignmentName = stringTable.append(assignment.specificDisplayName)
                let assignedAnchorPoint = workspace.assignedMonitorPoint
                    ?? manager.monitorIdShowingWorkspace(workspace.id)
                    .flatMap { manager.monitor(byId: $0)?.workspaceAnchorPoint }
                rawWorkspaces.append(
                    omniwm_workspace_session_workspace(
                        workspace_id: encode(uuid: workspace.id),
                        assigned_anchor_point: encode(point: assignedAnchorPoint ?? .zero),
                        assignment_kind: assignment.rawAssignmentKind,
                        specific_display_id: assignment.specificDisplayId ?? 0,
                        specific_display_name: assignmentName.ref,
                        remembered_tiled_focus_token: manager.lastFocusedToken(in: workspace.id)
                            .map(encode(token:)) ?? zeroToken(),
                        remembered_floating_focus_token: manager.lastFloatingFocusedToken(in: workspace.id)
                            .map(encode(token:)) ?? zeroToken(),
                        has_assigned_anchor_point: assignedAnchorPoint == nil ? 0 : 1,
                        has_specific_display_id: assignment.specificDisplayId == nil ? 0 : 1,
                        has_specific_display_name: assignmentName.hasValue,
                        has_remembered_tiled_focus_token: manager.lastFocusedToken(in: workspace.id) == nil ? 0 : 1,
                        has_remembered_floating_focus_token: manager
                            .lastFloatingFocusedToken(in: workspace.id) == nil ? 0 : 1
                    )
                )
            }

            var rawWindowCandidates = ContiguousArray<omniwm_workspace_session_window_candidate>()
            for workspace in sortedWorkspaces {
                appendWindowCandidates(
                    manager.tiledEntries(in: workspace.id),
                    workspaceId: workspace.id,
                    rawMode: UInt32(OMNIWM_WORKSPACE_SESSION_WINDOW_MODE_TILING),
                    into: &rawWindowCandidates
                )
                appendWindowCandidates(
                    manager.floatingEntries(in: workspace.id),
                    workspaceId: workspace.id,
                    rawMode: UInt32(OMNIWM_WORKSPACE_SESSION_WINDOW_MODE_FLOATING),
                    into: &rawWindowCandidates
                )
            }

            var rawDisconnectedCacheEntries = ContiguousArray<omniwm_workspace_session_disconnected_cache_entry>()
            rawDisconnectedCacheEntries.reserveCapacity(disconnectedCacheEntries.count)
            for entry in disconnectedCacheEntries {
                let encodedName = stringTable.append(entry.restoreKey.name)
                rawDisconnectedCacheEntries.append(
                    omniwm_workspace_session_disconnected_cache_entry(
                        workspace_id: encode(uuid: entry.workspaceId),
                        display_id: entry.restoreKey.displayId,
                        anchor_x: entry.restoreKey.anchorPoint.x,
                        anchor_y: entry.restoreKey.anchorPoint.y,
                        frame_width: entry.restoreKey.frameSize.width,
                        frame_height: entry.restoreKey.frameSize.height,
                        name: encodedName.ref,
                        has_name: encodedName.hasValue
                    )
                )
            }

            let currentViewport = rawViewportSnapshot(
                workspaceId.flatMap { manager.sessionState.workspaceSessions[$0]?.niriViewportState }
            )
            let patchViewport = rawViewportSnapshot(patch?.viewportState)
            var rawInput = omniwm_workspace_session_input(
                operation: operation,
                workspace_id: workspaceId.map(encode(uuid:)) ?? zeroUUID(),
                monitor_id: monitorId?.displayId ?? 0,
                focused_workspace_id: focusSnapshot.focusedWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
                pending_tiled_workspace_id: focusSnapshot.pendingTiledWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
                confirmed_tiled_workspace_id: focusSnapshot.confirmedTiledWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
                confirmed_floating_workspace_id: focusSnapshot.confirmedFloatingWorkspaceId
                    .map(encode(uuid:)) ?? zeroUUID(),
                pending_tiled_focus_token: focusSnapshot.pendingTiledToken.map(encode(token:)) ?? zeroToken(),
                confirmed_tiled_focus_token: focusSnapshot.confirmedTiledToken.map(encode(token:)) ?? zeroToken(),
                confirmed_floating_focus_token: focusSnapshot.confirmedFloatingToken.map(encode(token:)) ?? zeroToken(),
                remembered_focus_token: patch?.rememberedFocusToken.map(encode(token:)) ?? zeroToken(),
                interaction_monitor_id: manager.sessionState.interactionMonitorId?.displayId ?? 0,
                previous_interaction_monitor_id: manager.sessionState.previousInteractionMonitorId?.displayId ?? 0,
                current_viewport_kind: currentViewport.kind,
                current_viewport_active_column_index: currentViewport.activeColumnIndex,
                patch_viewport_kind: patchViewport.kind,
                patch_viewport_active_column_index: patchViewport.activeColumnIndex,
                has_workspace_id: workspaceId == nil ? 0 : 1,
                has_monitor_id: monitorId == nil ? 0 : 1,
                has_focused_workspace_id: focusSnapshot.focusedWorkspaceId == nil ? 0 : 1,
                has_pending_tiled_workspace_id: focusSnapshot.pendingTiledWorkspaceId == nil ? 0 : 1,
                has_confirmed_tiled_workspace_id: focusSnapshot.confirmedTiledWorkspaceId == nil ? 0 : 1,
                has_confirmed_floating_workspace_id: focusSnapshot.confirmedFloatingWorkspaceId == nil ? 0 : 1,
                has_pending_tiled_focus_token: focusSnapshot.pendingTiledToken == nil ? 0 : 1,
                has_confirmed_tiled_focus_token: focusSnapshot.confirmedTiledToken == nil ? 0 : 1,
                has_confirmed_floating_focus_token: focusSnapshot.confirmedFloatingToken == nil ? 0 : 1,
                has_remembered_focus_token: patch?.rememberedFocusToken == nil ? 0 : 1,
                has_interaction_monitor_id: manager.sessionState.interactionMonitorId == nil ? 0 : 1,
                has_previous_interaction_monitor_id: manager.sessionState.previousInteractionMonitorId == nil ? 0 : 1,
                has_current_viewport_state: currentViewport.hasState ? 1 : 0,
                has_patch_viewport_state: patchViewport.hasState ? 1 : 0,
                should_update_interaction_monitor: updateInteractionMonitor ? 1 : 0,
                preserve_previous_interaction_monitor: preservePreviousInteractionMonitor ? 1 : 0
            )

            var rawMonitorResults = ContiguousArray(
                repeating: omniwm_workspace_session_monitor_result(
                    monitor_id: 0,
                    visible_workspace_id: zeroUUID(),
                    previous_visible_workspace_id: zeroUUID(),
                    resolved_active_workspace_id: zeroUUID(),
                    has_visible_workspace_id: 0,
                    has_previous_visible_workspace_id: 0,
                    has_resolved_active_workspace_id: 0
                ),
                count: monitors.count
            )
            var rawWorkspaceProjections = ContiguousArray(
                repeating: omniwm_workspace_session_workspace_projection(
                    workspace_id: zeroUUID(),
                    projected_monitor_id: 0,
                    home_monitor_id: 0,
                    effective_monitor_id: 0,
                    has_projected_monitor_id: 0,
                    has_home_monitor_id: 0,
                    has_effective_monitor_id: 0
                ),
                count: manager.workspaces.count
            )
            var rawDisconnectedCacheResults = ContiguousArray(
                repeating: omniwm_workspace_session_disconnected_cache_result(
                    source_kind: 0,
                    source_index: 0,
                    workspace_id: zeroUUID()
                ),
                count: disconnectedCacheEntries.count + previousMonitors.count
            )
            var rawOutput = omniwm_workspace_session_output(
                outcome: 0,
                patch_viewport_action: 0,
                focus_clear_action: 0,
                interaction_monitor_id: 0,
                previous_interaction_monitor_id: 0,
                resolved_focus_token: zeroToken(),
                monitor_results: nil,
                monitor_result_capacity: rawMonitorResults.count,
                monitor_result_count: 0,
                workspace_projections: nil,
                workspace_projection_capacity: rawWorkspaceProjections.count,
                workspace_projection_count: 0,
                disconnected_cache_results: nil,
                disconnected_cache_result_capacity: rawDisconnectedCacheResults.count,
                disconnected_cache_result_count: 0,
                has_interaction_monitor_id: 0,
                has_previous_interaction_monitor_id: 0,
                has_resolved_focus_token: 0,
                should_remember_focus: 0,
                refresh_restore_intents: 0
            )

            let status = rawMonitors.withUnsafeBufferPointer { monitorBuffer in
                rawPreviousMonitors.withUnsafeBufferPointer { previousMonitorBuffer in
                    rawWorkspaces.withUnsafeBufferPointer { workspaceBuffer in
                        rawWindowCandidates.withUnsafeBufferPointer { candidateBuffer in
                            rawDisconnectedCacheEntries.withUnsafeBufferPointer { disconnectedCacheBuffer in
                                stringTable.bytes.withUnsafeBufferPointer { stringBuffer in
                                    rawMonitorResults.withUnsafeMutableBufferPointer { monitorResultBuffer in
                                        rawWorkspaceProjections
                                            .withUnsafeMutableBufferPointer { workspaceProjectionBuffer in
                                                rawDisconnectedCacheResults
                                                    .withUnsafeMutableBufferPointer { disconnectedCacheResultBuffer in
                                                        rawOutput.monitor_results = monitorResultBuffer.baseAddress
                                                        rawOutput.workspace_projections = workspaceProjectionBuffer
                                                            .baseAddress
                                                        rawOutput
                                                            .disconnected_cache_results =
                                                            disconnectedCacheResultBuffer
                                                                .baseAddress
                                                        return withUnsafeMutablePointer(to: &rawInput) { inputPointer in
                                                            withUnsafeMutablePointer(to: &rawOutput) { outputPointer in
                                                                omniwm_workspace_session_plan(
                                                                    inputPointer,
                                                                    monitorBuffer.baseAddress,
                                                                    monitorBuffer.count,
                                                                    previousMonitorBuffer.baseAddress,
                                                                    previousMonitorBuffer.count,
                                                                    workspaceBuffer.baseAddress,
                                                                    workspaceBuffer.count,
                                                                    candidateBuffer.baseAddress,
                                                                    candidateBuffer.count,
                                                                    disconnectedCacheBuffer.baseAddress,
                                                                    disconnectedCacheBuffer.count,
                                                                    stringBuffer.baseAddress,
                                                                    stringBuffer.count,
                                                                    outputPointer
                                                                )
                                                            }
                                                        }
                                                    }
                                            }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if let failureReason = workspaceSessionKernelOutputValidationFailureReason(
                status: status,
                rawOutput: rawOutput,
                monitorCapacity: rawMonitorResults.count,
                workspaceProjectionCapacity: rawWorkspaceProjections.count,
                disconnectedCacheCapacity: rawDisconnectedCacheResults.count
            ) {
                reportWorkspaceSessionKernelBridgeFailure(failureReason)
                return nil
            }

            return decodeInvocationResult(
                rawOutput: rawOutput,
                rawMonitorResults: rawMonitorResults,
                rawWorkspaceProjections: rawWorkspaceProjections,
                rawDisconnectedCacheResults: rawDisconnectedCacheResults
            )
        }

        private static func decodeInvocationResult(
            rawOutput: omniwm_workspace_session_output,
            rawMonitorResults: ContiguousArray<omniwm_workspace_session_monitor_result>,
            rawWorkspaceProjections: ContiguousArray<omniwm_workspace_session_workspace_projection>,
            rawDisconnectedCacheResults: ContiguousArray<omniwm_workspace_session_disconnected_cache_result>
        ) -> InvocationResult {
            InvocationResult(
                plan: Plan(
                    outcome: KernelContract.require(
                        Outcome(kernelRawValue: rawOutput.outcome),
                        "Unknown workspace session outcome \(rawOutput.outcome)"
                    ),
                    patchViewportAction: KernelContract.require(
                        PatchViewportAction(kernelRawValue: rawOutput.patch_viewport_action),
                        "Unknown workspace session patch viewport action \(rawOutput.patch_viewport_action)"
                    ),
                    focusClearAction: KernelContract.require(
                        FocusClearAction(kernelRawValue: rawOutput.focus_clear_action),
                        "Unknown workspace session focus clear action \(rawOutput.focus_clear_action)"
                    ),
                    interactionMonitorId: rawOutput.has_interaction_monitor_id == 0
                        ? nil
                        : Monitor.ID(displayId: rawOutput.interaction_monitor_id),
                    previousInteractionMonitorId: rawOutput.has_previous_interaction_monitor_id == 0
                        ? nil
                        : Monitor.ID(displayId: rawOutput.previous_interaction_monitor_id),
                    resolvedFocusToken: rawOutput.has_resolved_focus_token == 0
                        ? nil
                        : decode(token: rawOutput.resolved_focus_token),
                    monitorStates: Array(rawMonitorResults.prefix(rawOutput.monitor_result_count)).map {
                        MonitorState(
                            monitorId: Monitor.ID(displayId: $0.monitor_id),
                            visibleWorkspaceId: $0
                                .has_visible_workspace_id == 0 ? nil : decode(uuid: $0.visible_workspace_id),
                            previousVisibleWorkspaceId: $0.has_previous_visible_workspace_id == 0
                                ? nil
                                : decode(uuid: $0.previous_visible_workspace_id),
                            resolvedActiveWorkspaceId: $0.has_resolved_active_workspace_id == 0
                                ? nil
                                : decode(uuid: $0.resolved_active_workspace_id)
                        )
                    },
                    workspaceProjections: Array(rawWorkspaceProjections.prefix(rawOutput.workspace_projection_count))
                        .map {
                            WorkspaceProjectionRecord(
                                workspaceId: decode(uuid: $0.workspace_id),
                                projectedMonitorId: $0.has_projected_monitor_id == 0 ? nil : Monitor
                                    .ID(displayId: $0.projected_monitor_id),
                                homeMonitorId: $0.has_home_monitor_id == 0 ? nil : Monitor
                                    .ID(displayId: $0.home_monitor_id),
                                effectiveMonitorId: $0.has_effective_monitor_id == 0 ? nil : Monitor
                                    .ID(displayId: $0.effective_monitor_id)
                            )
                        },
                    shouldRememberFocus: rawOutput.should_remember_focus != 0
                ),
                disconnectedCacheResults: Array(rawDisconnectedCacheResults
                    .prefix(rawOutput.disconnected_cache_result_count)).map {
                    DisconnectedCacheResultRecord(
                        sourceKind: $0.source_kind,
                        sourceIndex: Int($0.source_index),
                        workspaceId: decode(uuid: $0.workspace_id)
                    )
                },
                refreshRestoreIntents: rawOutput.refresh_restore_intents != 0
            )
        }

        private static func previousMonitorSnapshots(
            manager: WorkspaceManager
        ) -> [PreviousMonitorSnapshot] {
            manager.monitors.map { monitor in
                let session = manager.sessionState.monitorSessions[monitor.id]
                return PreviousMonitorSnapshot(
                    monitor: monitor,
                    visibleWorkspaceId: session?.visibleWorkspaceId,
                    previousVisibleWorkspaceId: session?.previousVisibleWorkspaceId
                )
            }
        }

        private static func disconnectedCacheEntries(
            manager: WorkspaceManager
        ) -> [DisconnectedCacheEntrySnapshot] {
            manager.disconnectedVisibleWorkspaceCache.map {
                DisconnectedCacheEntrySnapshot(
                    restoreKey: $0.key,
                    workspaceId: $0.value
                )
            }
            .sorted { lhs, rhs in
                if lhs.restoreKey.displayId != rhs.restoreKey.displayId {
                    return lhs.restoreKey.displayId < rhs.restoreKey.displayId
                }
                if lhs.restoreKey.name != rhs.restoreKey.name {
                    return lhs.restoreKey.name < rhs.restoreKey.name
                }
                if lhs.restoreKey.anchorPoint.x != rhs.restoreKey.anchorPoint.x {
                    return lhs.restoreKey.anchorPoint.x < rhs.restoreKey.anchorPoint.x
                }
                if lhs.restoreKey.anchorPoint.y != rhs.restoreKey.anchorPoint.y {
                    return lhs.restoreKey.anchorPoint.y < rhs.restoreKey.anchorPoint.y
                }
                if lhs.restoreKey.frameSize.width != rhs.restoreKey.frameSize.width {
                    return lhs.restoreKey.frameSize.width < rhs.restoreKey.frameSize.width
                }
                if lhs.restoreKey.frameSize.height != rhs.restoreKey.frameSize.height {
                    return lhs.restoreKey.frameSize.height < rhs.restoreKey.frameSize.height
                }
                return lhs.workspaceId.uuidString < rhs.workspaceId.uuidString
            }
        }

        private static func focusSnapshot(
            manager: WorkspaceManager
        ) -> FocusSnapshot {
            let pendingTiled: (WindowToken, WorkspaceDescriptor.ID)? = if let token = manager.pendingFocusedToken,
                                                                          let workspaceId = manager
                                                                          .pendingFocusedWorkspaceId
            {
                (token, workspaceId)
            } else {
                nil
            }

            let confirmedManagedFocus: (
                WindowToken,
                WorkspaceDescriptor.ID,
                TrackedWindowMode
            )? = if let token = manager.focusedToken,
                    let entry = manager.entry(for: token)
            {
                (token, entry.workspaceId, entry.mode)
            } else {
                nil
            }

            let confirmedTiledToken: WindowToken?
            let confirmedTiledWorkspaceId: WorkspaceDescriptor.ID?
            let confirmedFloatingToken: WindowToken?
            let confirmedFloatingWorkspaceId: WorkspaceDescriptor.ID?
            if let confirmedManagedFocus {
                switch confirmedManagedFocus.2 {
                case .tiling:
                    confirmedTiledToken = confirmedManagedFocus.0
                    confirmedTiledWorkspaceId = confirmedManagedFocus.1
                    confirmedFloatingToken = nil
                    confirmedFloatingWorkspaceId = nil
                case .floating:
                    confirmedTiledToken = nil
                    confirmedTiledWorkspaceId = nil
                    confirmedFloatingToken = confirmedManagedFocus.0
                    confirmedFloatingWorkspaceId = confirmedManagedFocus.1
                }
            } else {
                confirmedTiledToken = nil
                confirmedTiledWorkspaceId = nil
                confirmedFloatingToken = nil
                confirmedFloatingWorkspaceId = nil
            }

            return FocusSnapshot(
                focusedWorkspaceId: manager.focusedToken.flatMap { manager.entry(for: $0)?.workspaceId },
                pendingTiledToken: pendingTiled?.0,
                pendingTiledWorkspaceId: pendingTiled?.1,
                confirmedTiledToken: confirmedTiledToken,
                confirmedTiledWorkspaceId: confirmedTiledWorkspaceId,
                confirmedFloatingToken: confirmedFloatingToken,
                confirmedFloatingWorkspaceId: confirmedFloatingWorkspaceId
            )
        }

        private static func assignmentSnapshot(
            manager: WorkspaceManager,
            workspace: WorkspaceDescriptor
        ) -> AssignmentSnapshot {
            guard let config = manager.settings.workspaceConfigurations.first(where: { $0.name == workspace.name })
            else {
                return AssignmentSnapshot(rawAssignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_UNCONFIGURED))
            }

            switch config.monitorAssignment {
            case .main:
                return AssignmentSnapshot(rawAssignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_MAIN))
            case .secondary:
                return AssignmentSnapshot(rawAssignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SECONDARY))
            case let .specificDisplay(output):
                return AssignmentSnapshot(
                    rawAssignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SPECIFIC_DISPLAY),
                    specificDisplayId: output.displayId,
                    specificDisplayName: output.name
                )
            }
        }

        private static func rawViewportSnapshot(
            _ state: ViewportState?
        ) -> (kind: UInt32, activeColumnIndex: Int32, hasState: Bool) {
            guard let state else {
                return (UInt32(OMNIWM_WORKSPACE_SESSION_VIEWPORT_NONE), 0, false)
            }

            let kind = switch state.viewOffsetPixels {
            case .static:
                UInt32(OMNIWM_WORKSPACE_SESSION_VIEWPORT_STATIC)
            case .gesture:
                UInt32(OMNIWM_WORKSPACE_SESSION_VIEWPORT_GESTURE)
            case .spring:
                UInt32(OMNIWM_WORKSPACE_SESSION_VIEWPORT_SPRING)
            }

            return (kind, Int32(clamping: state.activeColumnIndex), true)
        }

        private static func appendWindowCandidates(
            _ entries: [WindowModel.Entry],
            workspaceId: WorkspaceDescriptor.ID,
            rawMode: UInt32,
            into candidates: inout ContiguousArray<omniwm_workspace_session_window_candidate>
        ) {
            candidates.reserveCapacity(candidates.count + entries.count)
            for (index, entry) in entries.enumerated() {
                let hiddenReasonIsWorkspaceInactive: UInt8 = if case .workspaceInactive = entry.hiddenReason {
                    1
                } else {
                    0
                }

                candidates.append(
                    omniwm_workspace_session_window_candidate(
                        workspace_id: encode(uuid: workspaceId),
                        token: encode(token: entry.token),
                        mode: rawMode,
                        order_index: UInt32(clamping: index),
                        has_hidden_proportional_position: entry.hiddenProportionalPosition == nil ? 0 : 1,
                        hidden_reason_is_workspace_inactive: hiddenReasonIsWorkspaceInactive
                    )
                )
            }
        }

        private static func encode(uuid: UUID) -> omniwm_uuid {
            let t = uuid.uuid
            let high =
                UInt64(t.0) << 56 | UInt64(t.1) << 48 | UInt64(t.2) << 40 | UInt64(t.3) << 32 |
                UInt64(t.4) << 24 | UInt64(t.5) << 16 | UInt64(t.6) << 8 | UInt64(t.7)
            let low =
                UInt64(t.8) << 56 | UInt64(t.9) << 48 | UInt64(t.10) << 40 | UInt64(t.11) << 32 |
                UInt64(t.12) << 24 | UInt64(t.13) << 16 | UInt64(t.14) << 8 | UInt64(t.15)
            return omniwm_uuid(high: high, low: low)
        }

        private static func decode(uuid: omniwm_uuid) -> UUID {
            let h = uuid.high
            let l = uuid.low
            return UUID(uuid: (
                UInt8(truncatingIfNeeded: h >> 56),
                UInt8(truncatingIfNeeded: h >> 48),
                UInt8(truncatingIfNeeded: h >> 40),
                UInt8(truncatingIfNeeded: h >> 32),
                UInt8(truncatingIfNeeded: h >> 24),
                UInt8(truncatingIfNeeded: h >> 16),
                UInt8(truncatingIfNeeded: h >> 8),
                UInt8(truncatingIfNeeded: h),
                UInt8(truncatingIfNeeded: l >> 56),
                UInt8(truncatingIfNeeded: l >> 48),
                UInt8(truncatingIfNeeded: l >> 40),
                UInt8(truncatingIfNeeded: l >> 32),
                UInt8(truncatingIfNeeded: l >> 24),
                UInt8(truncatingIfNeeded: l >> 16),
                UInt8(truncatingIfNeeded: l >> 8),
                UInt8(truncatingIfNeeded: l)
            ))
        }

        private static func zeroUUID() -> omniwm_uuid {
            omniwm_uuid(high: 0, low: 0)
        }

        private static func encode(token: WindowToken) -> omniwm_window_token {
            omniwm_window_token(pid: token.pid, window_id: Int64(token.windowId))
        }

        private static func decode(token: omniwm_window_token) -> WindowToken {
            WindowToken(pid: token.pid, windowId: Int(token.window_id))
        }

        private static func zeroToken() -> omniwm_window_token {
            omniwm_window_token(pid: 0, window_id: 0)
        }

        private static func encode(point: CGPoint) -> omniwm_point {
            omniwm_point(x: point.x, y: point.y)
        }
    }
}
