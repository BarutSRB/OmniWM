import AppKit
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

@MainActor
final class WorkspaceManager {
    static let staleUnavailableNativeFullscreenTimeout: TimeInterval = 15

    enum NativeFullscreenTransition: Equatable {
        case enterRequested
        case suspended
        case exitRequested
    }

    enum NativeFullscreenAvailability: Equatable {
        case present
        case temporarilyUnavailable
    }

    struct NativeFullscreenRecord {
        let originalToken: WindowToken
        var currentToken: WindowToken
        let workspaceId: WorkspaceDescriptor.ID
        var exitRequestedByCommand: Bool
        var transition: NativeFullscreenTransition
        var availability: NativeFullscreenAvailability
        var unavailableSince: Date?
    }

    private struct DisconnectedVisibleWorkspaceMigration {
        let removedMonitor: Monitor
        let workspaceId: WorkspaceDescriptor.ID
    }

    struct SessionState {
        struct MonitorSession {
            var visibleWorkspaceId: WorkspaceDescriptor.ID?
            var previousVisibleWorkspaceId: WorkspaceDescriptor.ID?
        }

        struct WorkspaceSession {
            var niriViewportState: ViewportState?
        }

        struct FocusSession {
            struct PendingManagedFocusRequest {
                var token: WindowToken?
                var workspaceId: WorkspaceDescriptor.ID?
                var monitorId: Monitor.ID?
            }

            var focusedToken: WindowToken?
            var pendingManagedFocus = PendingManagedFocusRequest()
            var lastTiledFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowToken] = [:]
            var lastFloatingFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowToken] = [:]
            var focusLease: FocusPolicyLease?
            var isNonManagedFocusActive: Bool = false
            var isAppFullscreenActive: Bool = false
        }

        var interactionMonitorId: Monitor.ID?
        var previousInteractionMonitorId: Monitor.ID?
        var monitorSessions: [Monitor.ID: MonitorSession] = [:]
        var workspaceSessions: [WorkspaceDescriptor.ID: WorkspaceSession] = [:]
        var scratchpadToken: WindowToken?
        var focus = FocusSession()
    }

    private(set) var monitors: [Monitor] = Monitor.current() {
        didSet { rebuildMonitorIndexes() }
    }
    private var _monitorsById: [Monitor.ID: Monitor] = [:]
    private var _monitorsByName: [String: [Monitor]] = [:]
    private let settings: SettingsStore

    private var workspacesById: [WorkspaceDescriptor.ID: WorkspaceDescriptor] = [:]
    private var workspaceIdByName: [String: WorkspaceDescriptor.ID] = [:]
    private var disconnectedVisibleWorkspaceCache: [MonitorRestoreKey: WorkspaceDescriptor.ID] = [:]

    private(set) var gaps: Double = 8
    private(set) var outerGaps: LayoutGaps.OuterGaps = .zero
    private let windows = WindowModel()
    private let reconcileTrace = ReconcileTraceRecorder()
    private lazy var runtimeStore = RuntimeStore(traceRecorder: reconcileTrace)
    private let restorePlanner = RestorePlanner()
    private let bootPersistedWindowRestoreCatalog: PersistedWindowRestoreCatalog
    private var nativeFullscreenRecordsByOriginalToken: [WindowToken: NativeFullscreenRecord] = [:]
    private var nativeFullscreenOriginalTokenByCurrentToken: [WindowToken: WindowToken] = [:]
    private var consumedBootPersistedWindowRestoreKeys: Set<PersistedWindowRestoreKey> = []
    private var persistedWindowRestoreCatalogDirty = false
    private var persistedWindowRestoreCatalogSaveScheduled = false

    private var _cachedSortedWorkspaces: [WorkspaceDescriptor]?
    private var _cachedWorkspaceIdsByMonitor: [Monitor.ID: [WorkspaceDescriptor.ID]]?
    private var _cachedVisibleWorkspaceIds: Set<WorkspaceDescriptor.ID>?
    private var _cachedVisibleWorkspaceMap: [Monitor.ID: WorkspaceDescriptor.ID]?
    private var _cachedMonitorIdByVisibleWorkspace: [WorkspaceDescriptor.ID: Monitor.ID]?
    var animationClock: AnimationClock?
    private var sessionState = SessionState()

    var onGapsChanged: (() -> Void)?
    var onSessionStateChanged: (() -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
        bootPersistedWindowRestoreCatalog = settings.loadPersistedWindowRestoreCatalog()
        if monitors.isEmpty {
            monitors = [Monitor.fallback()]
        }
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
            topologyProfile: TopologyProfile(monitors: monitors),
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

    func reconcileTraceSnapshotForTests() -> [ReconcileTraceRecord] {
        reconcileTrace.snapshot()
    }

    func replayReconcileTraceForTests() -> [ActionPlan] {
        StateReducer.replay(reconcileTrace.snapshot())
    }

    func reconcileSnapshotDump() -> String {
        ReconcileDebugDump.snapshot(reconcileSnapshot())
    }

    func reconcileTraceDump(limit: Int? = nil) -> String {
        ReconcileDebugDump.trace(reconcileTrace.snapshot(), limit: limit)
    }

    @discardableResult
    func recordReconcileEvent(_ event: WMEvent) -> ReconcileTxn {
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
            snapshot: { self.reconcileSnapshot() },
            applyPlan: { plan, token in
                var plan = plan
                if let restoreRefresh {
                    plan.restoreRefresh = restoreRefresh
                }
                if let persistedHydration {
                    plan = self.mergePersistedHydration(
                        persistedHydration,
                        into: plan,
                        existingEntry: entry
                    )
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
        let snapshot = reconcileSnapshot()
        let topologyPlan = restorePlanner.planMonitorConfigurationChange(
            .init(
                snapshot: snapshot,
                previousMonitors: monitors,
                newMonitors: normalizedMonitors,
                visibleWorkspaceMap: activeVisibleWorkspaceMap(),
                disconnectedVisibleWorkspaceCache: disconnectedVisibleWorkspaceCache,
                interactionMonitorId: sessionState.interactionMonitorId,
                previousInteractionMonitorId: sessionState.previousInteractionMonitorId,
                workspaceExists: { [weak self] workspaceId in
                    self?.descriptor(for: workspaceId) != nil
                },
                homeMonitorId: { [weak self] workspaceId, monitors in
                    self?.homeMonitor(for: workspaceId, in: monitors)?.id
                },
                effectiveMonitorId: { [weak self] workspaceId, monitors in
                    self?.effectiveMonitor(for: workspaceId, in: monitors)?.id
                }
            )
        )
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
                plan.topologyTransition = TopologyTransitionPlan(
                    previousMonitors: topologyPlan.previousMonitors,
                    newMonitors: topologyPlan.newMonitors,
                    visibleAssignments: topologyPlan.visibleAssignments,
                    disconnectedVisibleWorkspaceCache: topologyPlan.disconnectedVisibleWorkspaceCache,
                    interactionMonitorId: topologyPlan.interactionMonitorId,
                    previousInteractionMonitorId: topologyPlan.previousInteractionMonitorId,
                    refreshRestoreIntents: topologyPlan.refreshRestoreIntents
                )
                plan.notes.append("restore_refresh=topology")
                if !topologyPlan.notes.isEmpty {
                    plan.notes.append(contentsOf: topologyPlan.notes)
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
            _ = applyPersistedHydrationMutation(persistedHydration, to: token)
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
        if let entry = windows.entry(for: token) {
            let restoreIntent = StateReducer.restoreIntent(for: entry, monitors: monitors)
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
        replaceMonitorsForTopologyTransition(with: transition.newMonitors)

        for monitor in Monitor.sortedByPosition(monitors) {
            guard let workspaceId = transition.visibleAssignments[monitor.id] else { continue }
            _ = setActiveWorkspaceInternal(
                workspaceId,
                on: monitor.id,
                anchorPoint: monitor.workspaceAnchorPoint,
                updateInteractionMonitor: false,
                notify: false
            )
        }

        reconcileConfiguredVisibleWorkspaces(notify: false)
        disconnectedVisibleWorkspaceCache = transition.disconnectedVisibleWorkspaceCache
        sessionState.interactionMonitorId = transition.interactionMonitorId
        sessionState.previousInteractionMonitorId = transition.previousInteractionMonitorId
        reconcileInteractionMonitorState(notify: false)
        refreshWindowMonitorReferencesForAllEntries()
        if transition.refreshRestoreIntents {
            refreshRestoreIntentsForAllEntries()
        }
    }

    private func replaceMonitorsForTopologyTransition(with newMonitors: [Monitor]) {
        monitors = newMonitors.isEmpty ? [Monitor.fallback()] : newMonitors

        let currentMonitorIds = Set(monitors.map(\.id))
        let expectedVisibleMonitorIds = expectedVisibleMonitorIds()
        sessionState.monitorSessions = sessionState.monitorSessions.filter {
            currentMonitorIds.contains($0.key) && expectedVisibleMonitorIds.contains($0.key)
        }
        invalidateWorkspaceProjectionCaches()
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

    private func mergePersistedHydration(
        _ hydration: PersistedHydrationMutation,
        into plan: ActionPlan,
        existingEntry: WindowModel.Entry?
    ) -> ActionPlan {
        var mergedPlan = plan
        let monitorId = hydration.monitorId

        var observedState = mergedPlan.observedState
            ?? existingEntry?.observedState
            ?? ObservedWindowState.initial(
                workspaceId: hydration.workspaceId,
                monitorId: monitorId
            )
        observedState.workspaceId = hydration.workspaceId
        observedState.monitorId = monitorId ?? observedState.monitorId
        mergedPlan.observedState = observedState

        var desiredState = mergedPlan.desiredState
            ?? existingEntry?.desiredState
            ?? DesiredWindowState.initial(
                workspaceId: hydration.workspaceId,
                monitorId: monitorId,
                disposition: hydration.targetMode
            )
        desiredState.workspaceId = hydration.workspaceId
        desiredState.monitorId = monitorId ?? desiredState.monitorId
        desiredState.disposition = hydration.targetMode
        if let floatingFrame = hydration.floatingFrame {
            desiredState.floatingFrame = floatingFrame
            desiredState.rescueEligible = true
        } else if hydration.targetMode == .floating {
            desiredState.rescueEligible = true
        }
        mergedPlan.desiredState = desiredState
        mergedPlan.lifecyclePhase = hydration.targetMode == .floating ? .floating : .tiled
        mergedPlan.persistedHydration = hydration
        mergedPlan.notes.append("persisted_hydration")
        return mergedPlan
    }

    @discardableResult
    private func applyPersistedHydrationMutation(
        _ hydration: PersistedHydrationMutation,
        to token: WindowToken
    ) -> Bool {
        guard let entry = windows.entry(for: token) else {
            return false
        }

        if entry.workspaceId != hydration.workspaceId {
            windows.updateWorkspace(for: token, workspace: hydration.workspaceId)
        }

        let focusChanged = applyWindowModeMutationWithoutReconcile(
            hydration.targetMode,
            for: token,
            workspaceId: hydration.workspaceId
        )

        if let floatingFrame = hydration.floatingFrame {
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
            self.persistedWindowRestoreCatalogSaveScheduled = false
            self.flushPersistedWindowRestoreCatalogIfNeeded()
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
            for (title, titledCandidates) in candidatesByTitle where title != nil && titledCandidates.count == 1 {
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
            topologyProfile: TopologyProfile(monitors: monitors),
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
            $0.transition == .enterRequested || $0.availability == .temporarilyUnavailable
        }
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
        let appFullscreen = sessionState.focus.isNonManagedFocusActive ? false : sessionState.focus.isAppFullscreenActive
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

    @discardableResult
    func requestNativeFullscreenEnter(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        var changed = rememberFocus(token, in: workspaceId)
        let originalToken = nativeFullscreenOriginalToken(for: token) ?? token
        let existing = nativeFullscreenRecordsByOriginalToken[originalToken]
        var record = existing ?? NativeFullscreenRecord(
            originalToken: originalToken,
            currentToken: token,
            workspaceId: workspaceId,
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
        if existing == nil || changed {
            upsertNativeFullscreenRecord(record)
        }

        return changed || existing == nil
    }

    @discardableResult
    func markNativeFullscreenSuspended(_ token: WindowToken) -> Bool {
        guard let entry = entry(for: token) else { return false }

        var changed = rememberFocus(token, in: entry.workspaceId)
        let originalToken = nativeFullscreenOriginalToken(for: token) ?? token
        let existing = nativeFullscreenRecordsByOriginalToken[originalToken]
        var record = existing ?? NativeFullscreenRecord(
            originalToken: originalToken,
            currentToken: token,
            workspaceId: entry.workspaceId,
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
        if existing == nil || changed {
            upsertNativeFullscreenRecord(record)
        }

        if layoutReason(for: token) != .nativeFullscreen {
            setLayoutReason(.nativeFullscreen, for: token)
            changed = true
        }
        changed = enterNonManagedFocus(appFullscreen: true) || changed
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

        var record = existing ?? NativeFullscreenRecord(
            originalToken: originalToken,
            currentToken: token,
            workspaceId: workspaceId,
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

    func nativeFullscreenUnavailableCandidate(
        for pid: pid_t,
        activeWorkspaceId: WorkspaceDescriptor.ID?
    ) -> NativeFullscreenRecord? {
        let candidates = nativeFullscreenRecordsByOriginalToken.values.filter { record in
            guard record.currentToken.pid == pid,
                  record.availability == .temporarilyUnavailable
            else {
                return false
            }
            return true
        }
        guard !candidates.isEmpty else { return nil }

        if let activeWorkspaceId {
            let workspaceMatches = candidates.filter { $0.workspaceId == activeWorkspaceId }
            if workspaceMatches.count == 1 {
                return workspaceMatches[0]
            }
        }

        let commandMatches = candidates.filter(\.exitRequestedByCommand)
        if commandMatches.count == 1 {
            return commandMatches[0]
        }

        guard candidates.count == 1 else { return nil }
        return candidates[0]
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
        _ = setManagedAppFullscreen(false)
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
            if let removed = removeWindow(pid: record.currentToken.pid, windowId: record.currentToken.windowId) {
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
        var changed = false

        if var viewportState = patch.viewportState {
            // Guard against a stale gesture snapshot overwriting an in-progress snap animation.
            // Layout plans are built asynchronously and may arrive after endGesture() has already
            // transitioned the viewport from .gesture to .spring. Preserve the spring animation.
            if viewportState.viewOffsetPixels.isGesture {
                let currentState = niriViewportState(for: patch.workspaceId)
                if case .spring = currentState.viewOffsetPixels {
                    viewportState.viewOffsetPixels = currentState.viewOffsetPixels
                    viewportState.activeColumnIndex = currentState.activeColumnIndex
                }
            }
            updateNiriViewportState(viewportState, for: patch.workspaceId)
            changed = true
        }

        if let rememberedFocusToken = patch.rememberedFocusToken {
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
        if let pendingToken = eligibleFocusCandidate(
            sessionState.focus.pendingManagedFocus.token,
            in: workspaceId,
            mode: .tiling
        ),
           sessionState.focus.pendingManagedFocus.workspaceId == workspaceId
        {
            return pendingToken
        }

        if let remembered = eligibleFocusCandidate(
            sessionState.focus.lastTiledFocusedByWorkspace[workspaceId],
            in: workspaceId,
            mode: .tiling
        ) {
            return remembered
        }

        if let confirmed = eligibleFocusCandidate(
            sessionState.focus.focusedToken,
            in: workspaceId,
            mode: .tiling
        ) {
            return confirmed
        }

        return tiledEntries(in: workspaceId).first {
            isFocusResolutionEligible($0, in: workspaceId, mode: .tiling)
        }?.token
    }

    func resolveWorkspaceFocusToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        if let remembered = eligibleFocusCandidate(
            sessionState.focus.lastTiledFocusedByWorkspace[workspaceId],
            in: workspaceId,
            mode: .tiling
        ) {
            return remembered
        }
        if let preferredTiled = preferredFocusToken(in: workspaceId) {
            return preferredTiled
        }
        if let rememberedFloating = eligibleFocusCandidate(
            sessionState.focus.lastFloatingFocusedByWorkspace[workspaceId],
            in: workspaceId,
            mode: .floating
        ) {
            return rememberedFloating
        }
        if let confirmed = eligibleFocusCandidate(
            sessionState.focus.focusedToken,
            in: workspaceId,
            mode: .floating
        ) {
            return confirmed
        }
        return floatingEntries(in: workspaceId).first {
            isFocusResolutionEligible($0, in: workspaceId, mode: .floating)
        }?.token
    }

    @discardableResult
    func resolveAndSetWorkspaceFocusToken(
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor _: Monitor.ID? = nil
    ) -> WindowToken? {
        if let token = resolveWorkspaceFocusToken(in: workspaceId) {
            _ = rememberFocus(token, in: workspaceId)
            return token
        }

        _ = updateFocusSession(notify: true) { focus in
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
        _ mutate: (inout SessionState.FocusSession) -> Bool
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
        focus: inout SessionState.FocusSession
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
        focus: inout SessionState.FocusSession
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
        focus: inout SessionState.FocusSession
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
        focus: inout SessionState.FocusSession
    ) -> Bool {
        let request = focus.pendingManagedFocus
        let matchesHandle = token.map { request.token == $0 } ?? true
        let matchesWorkspace = workspaceId.map { request.workspaceId == $0 } ?? true
        guard matchesHandle, matchesWorkspace else { return false }
        guard request.token != nil || request.workspaceId != nil || request.monitorId != nil else { return false }
        focus.pendingManagedFocus = .init()
        return true
    }

    private func eligibleFocusCandidate(
        _ token: WindowToken?,
        in workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode
    ) -> WindowToken? {
        guard let token,
              let entry = entry(for: token),
              isFocusResolutionEligible(entry, in: workspaceId, mode: mode)
        else {
            return nil
        }
        return token
    }

    private func isFocusResolutionEligible(
        _ entry: WindowModel.Entry,
        in workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode
    ) -> Bool {
        guard entry.workspaceId == workspaceId,
              entry.mode == mode
        else {
            return false
        }

        guard entry.hiddenProportionalPosition != nil else {
            return true
        }

        if case .workspaceInactive = entry.hiddenReason {
            return true
        }

        return false
    }

    private func setRememberedFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode,
        focus: inout SessionState.FocusSession
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
        focus: inout SessionState.FocusSession
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
        focus: inout SessionState.FocusSession
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
        focus: inout SessionState.FocusSession
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
        let availableWidth = max(1, visibleFrame.width - frame.width)
        let availableHeight = max(1, visibleFrame.height - frame.height)
        let normalizedX = (frame.origin.x - visibleFrame.minX) / availableWidth
        let normalizedY = (frame.origin.y - visibleFrame.minY) / availableHeight
        return CGPoint(
            x: min(max(0, normalizedX), 1),
            y: min(max(0, normalizedY), 1)
        )
    }

    private func floatingOrigin(
        from normalizedOrigin: CGPoint,
        windowSize: CGSize,
        in visibleFrame: CGRect
    ) -> CGPoint {
        let availableWidth = max(0, visibleFrame.width - windowSize.width)
        let availableHeight = max(0, visibleFrame.height - windowSize.height)
        return CGPoint(
            x: visibleFrame.minX + min(max(0, normalizedOrigin.x), 1) * availableWidth,
            y: visibleFrame.minY + min(max(0, normalizedOrigin.y), 1) * availableHeight
        )
    }

    private func clampedFloatingFrame(
        _ frame: CGRect,
        in visibleFrame: CGRect
    ) -> CGRect {
        let maxX = visibleFrame.maxX - frame.width
        let maxY = visibleFrame.maxY - frame.height
        let clampedX = min(max(frame.origin.x, visibleFrame.minX), maxX >= visibleFrame.minX ? maxX : visibleFrame.minX)
        let clampedY = min(max(frame.origin.y, visibleFrame.minY), maxY >= visibleFrame.minY ? maxY : visibleFrame.minY)
        return CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: frame.size)
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
        _cachedWorkspaceIdsByMonitor = nil
        _cachedVisibleWorkspaceIds = nil
        _cachedVisibleWorkspaceMap = nil
        _cachedMonitorIdByVisibleWorkspace = nil
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
        ensureVisibleWorkspaces()
        return currentActiveWorkspace(on: monitorId)
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

    func nextWorkspaceInOrder(
        on monitorId: Monitor.ID,
        from workspaceId: WorkspaceDescriptor.ID,
        wrapAround: Bool
    ) -> WorkspaceDescriptor? {
        adjacentWorkspaceInOrder(on: monitorId, from: workspaceId, offset: 1, wrapAround: wrapAround)
    }

    func previousWorkspaceInOrder(
        on monitorId: Monitor.ID,
        from workspaceId: WorkspaceDescriptor.ID,
        wrapAround: Bool
    ) -> WorkspaceDescriptor? {
        adjacentWorkspaceInOrder(on: monitorId, from: workspaceId, offset: -1, wrapAround: wrapAround)
    }

    func activeWorkspaceOrFirst(on monitorId: Monitor.ID) -> WorkspaceDescriptor? {
        if let active = activeWorkspace(on: monitorId) {
            return active
        }
        guard let defaultWorkspaceId = defaultVisibleWorkspaceId(on: monitorId) else { return nil }
        _ = setActiveWorkspaceInternal(defaultWorkspaceId, on: monitorId)
        return descriptor(for: defaultWorkspaceId)
    }

    func visibleWorkspaceIds() -> Set<WorkspaceDescriptor.ID> {
        if let cached = _cachedVisibleWorkspaceIds {
            return cached
        }
        return Set(visibleWorkspaceMap().values)
    }

    private func adjacentWorkspaceInOrder(
        on monitorId: Monitor.ID,
        from workspaceId: WorkspaceDescriptor.ID,
        offset: Int,
        wrapAround: Bool
    ) -> WorkspaceDescriptor? {
        let ordered = workspaces(on: monitorId)
        guard ordered.count > 1 else { return nil }
        guard let currentIdx = ordered.firstIndex(where: { $0.id == workspaceId }) else { return nil }

        let targetIdx = currentIdx + offset
        if wrapAround {
            let wrappedIdx = (targetIdx % ordered.count + ordered.count) % ordered.count
            return ordered[wrappedIdx]
        }
        guard ordered.indices.contains(targetIdx) else { return nil }
        return ordered[targetIdx]
    }

    func focusWorkspace(named name: String) -> (workspace: WorkspaceDescriptor, monitor: Monitor)? {
        ensureVisibleWorkspaces()
        guard let workspaceId = workspaceId(for: name, createIfMissing: false) else { return nil }
        guard let targetMonitor = monitorForWorkspace(workspaceId) else { return nil }
        guard setActiveWorkspace(workspaceId, on: targetMonitor.id) else { return nil }
        guard let workspace = descriptor(for: workspaceId) else { return nil }
        return (workspace, targetMonitor)
    }

    func applySettings() {
        synchronizeConfiguredWorkspaces()
        ensureVisibleWorkspaces()
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
        let visibleFrame = targetMonitor?.visibleFrame ?? floatingState.lastFrame

        if let targetMonitor,
           floatingState.referenceMonitorId == targetMonitor.id || floatingState.normalizedOrigin == nil
        {
            return clampedFloatingFrame(floatingState.lastFrame, in: visibleFrame)
        }

        let origin = floatingOrigin(
            from: floatingState.normalizedOrigin ?? .zero,
            windowSize: floatingState.lastFrame.size,
            in: visibleFrame
        )
        return clampedFloatingFrame(
            CGRect(origin: origin, size: floatingState.lastFrame.size),
            in: visibleFrame
        )
    }

    func removeMissing(keys activeKeys: Set<WindowModel.WindowKey>, requiredConsecutiveMisses: Int = 1) {
        let removedEntries = windows.removeMissing(keys: activeKeys, requiredConsecutiveMisses: requiredConsecutiveMisses)
        for entry in removedEntries {
            _ = removeNativeFullscreenRecord(containing: entry.token)
            handleWindowRemoved(entry.token, in: entry.workspaceId)
            _ = runtimeStore.record(
                event: .windowRemoved(
                    token: entry.token,
                    workspaceId: entry.workspaceId,
                    source: .workspaceManager
                ),
                plan: ActionPlan(lifecyclePhase: .destroyed),
                snapshot: reconcileSnapshot()
            )
        }
        if !removedEntries.isEmpty {
            schedulePersistedWindowRestoreCatalogSave()
        }
    }

    @discardableResult
    func removeWindow(pid: pid_t, windowId: Int) -> WindowModel.Entry? {
        guard let entry = windows.entry(forPid: pid, windowId: windowId) else { return nil }
        recordReconcileEvent(
            .windowRemoved(
                token: entry.token,
                workspaceId: entry.workspaceId,
                source: .workspaceManager
            )
        )
        _ = removeNativeFullscreenRecord(containing: entry.token)
        handleWindowRemoved(entry.token, in: entry.workspaceId)
        _ = windows.removeWindow(key: .init(pid: pid, windowId: windowId))
        schedulePersistedWindowRestoreCatalogSave()
        return entry
    }

    @discardableResult
    func removeWindowsForApp(pid: pid_t) -> Set<WorkspaceDescriptor.ID> {
        var affectedWorkspaces: Set<WorkspaceDescriptor.ID> = []
        let entriesToRemove = entries(forPid: pid)

        for entry in entriesToRemove {
            affectedWorkspaces.insert(entry.workspaceId)
            recordReconcileEvent(
                .windowRemoved(
                    token: entry.token,
                    workspaceId: entry.workspaceId,
                    source: .workspaceManager
                )
            )
            _ = removeNativeFullscreenRecord(containing: entry.token)
            handleWindowRemoved(entry.token, in: entry.workspaceId)
            _ = windows.removeWindow(key: .init(pid: pid, windowId: entry.windowId))
        }

        if !entriesToRemove.isEmpty {
            schedulePersistedWindowRestoreCatalogSave()
        }

        return affectedWorkspaces
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
        case .standard, .macosHiddenApp:
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
        var workspaceSession = sessionState.workspaceSessions[workspaceId] ?? SessionState.WorkspaceSession()
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

    func adjacentMonitor(from monitorId: Monitor.ID, direction: Direction, wrapAround: Bool = false) -> Monitor? {
        guard let current = monitor(byId: monitorId) else { return nil }
        let others = monitors.filter { $0.id != current.id }
        guard !others.isEmpty else { return nil }

        let directional = others.filter { candidate in
            let delta = monitorDelta(from: current, to: candidate)
            switch direction {
            case .left: return delta.dx < 0
            case .right: return delta.dx > 0
            case .up: return delta.dy > 0
            case .down: return delta.dy < 0
            }
        }

        if let bestDirectional = bestMonitor(in: directional, from: current, direction: direction) {
            return bestDirectional
        }

        guard wrapAround else { return nil }
        return wrappedMonitor(in: others, from: current, direction: direction)
    }

    func previousMonitor(from monitorId: Monitor.ID) -> Monitor? {
        guard monitors.count > 1 else { return nil }

        let sorted = Monitor.sortedByPosition(monitors)
        guard let currentIdx = sorted.firstIndex(where: { $0.id == monitorId }) else { return nil }

        let prevIdx = currentIdx > 0 ? currentIdx - 1 : sorted.count - 1
        return sorted[prevIdx]
    }

    func nextMonitor(from monitorId: Monitor.ID) -> Monitor? {
        guard monitors.count > 1 else { return nil }

        let sorted = Monitor.sortedByPosition(monitors)
        guard let currentIdx = sorted.firstIndex(where: { $0.id == monitorId }) else { return nil }

        let nextIdx = (currentIdx + 1) % sorted.count
        return sorted[nextIdx]
    }

    private func monitorDelta(from source: Monitor, to target: Monitor) -> (dx: CGFloat, dy: CGFloat) {
        let dx = target.frame.center.x - source.frame.center.x
        let dy = target.frame.center.y - source.frame.center.y
        return (dx, dy)
    }

    private func bestMonitor(in candidates: [Monitor], from current: Monitor, direction: Direction) -> Monitor? {
        candidates.min(by: {
            isBetterMonitorCandidate($0, than: $1, from: current, direction: direction, mode: .directional)
        })
    }

    private func wrappedMonitor(in candidates: [Monitor], from current: Monitor, direction: Direction) -> Monitor? {
        candidates.min(by: {
            isBetterMonitorCandidate($0, than: $1, from: current, direction: direction, mode: .wrapped)
        })
    }

    private enum MonitorSelectionMode {
        case directional
        case wrapped
    }

    private struct MonitorSelectionRank {
        let primary: CGFloat
        let secondary: CGFloat
        let distance: CGFloat?
    }

    private func isBetterMonitorCandidate(
        _ lhs: Monitor,
        than rhs: Monitor,
        from current: Monitor,
        direction: Direction,
        mode: MonitorSelectionMode
    ) -> Bool {
        let lhsRank = monitorSelectionRank(for: lhs, from: current, direction: direction, mode: mode)
        let rhsRank = monitorSelectionRank(for: rhs, from: current, direction: direction, mode: mode)

        if lhsRank.primary != rhsRank.primary {
            return lhsRank.primary < rhsRank.primary
        }
        if lhsRank.secondary != rhsRank.secondary {
            return lhsRank.secondary < rhsRank.secondary
        }
        if let lhsDistance = lhsRank.distance,
           let rhsDistance = rhsRank.distance,
           lhsDistance != rhsDistance
        {
            return lhsDistance < rhsDistance
        }
        return monitorSortKey(lhs) < monitorSortKey(rhs)
    }

    private func monitorSelectionRank(
        for candidate: Monitor,
        from current: Monitor,
        direction: Direction,
        mode: MonitorSelectionMode
    ) -> MonitorSelectionRank {
        let delta = monitorDelta(from: current, to: candidate)

        switch mode {
        case .directional:
            switch direction {
            case .left, .right:
                return MonitorSelectionRank(
                    primary: abs(delta.dx),
                    secondary: abs(delta.dy),
                    distance: candidate.frame.center.distanceSquared(to: current.frame.center)
                )
            case .up, .down:
                return MonitorSelectionRank(
                    primary: abs(delta.dy),
                    secondary: abs(delta.dx),
                    distance: candidate.frame.center.distanceSquared(to: current.frame.center)
                )
            }
        case .wrapped:
            switch direction {
            case .right:
                return MonitorSelectionRank(primary: candidate.frame.center.x, secondary: abs(delta.dy), distance: nil)
            case .left:
                return MonitorSelectionRank(primary: -candidate.frame.center.x, secondary: abs(delta.dy), distance: nil)
            case .up:
                return MonitorSelectionRank(primary: candidate.frame.center.y, secondary: abs(delta.dx), distance: nil)
            case .down:
                return MonitorSelectionRank(primary: -candidate.frame.center.y, secondary: abs(delta.dx), distance: nil)
            }
        }
    }

    private func monitorSortKey(_ monitor: Monitor) -> (CGFloat, CGFloat, UInt32) {
        (monitor.frame.minX, -monitor.frame.maxY, monitor.displayId)
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

    private func captureVisibleWorkspaceRestoreSnapshots() -> [WorkspaceRestoreSnapshot] {
        activeVisibleWorkspaceMap()
            .sorted { lhs, rhs in
                guard let lhsMonitor = monitor(byId: lhs.key), let rhsMonitor = monitor(byId: rhs.key) else {
                    return lhs.key.displayId < rhs.key.displayId
                }
                let lhsKey = (lhsMonitor.frame.minX, -lhsMonitor.frame.maxY, lhsMonitor.displayId)
                let rhsKey = (rhsMonitor.frame.minX, -rhsMonitor.frame.maxY, rhsMonitor.displayId)
                return lhsKey < rhsKey
            }
            .compactMap { monitorId, workspaceId in
            guard let monitor = monitor(byId: monitorId) else { return nil }
            return WorkspaceRestoreSnapshot(
                monitor: MonitorRestoreKey(monitor: monitor),
                workspaceId: workspaceId
            )
        }
    }

    private func captureDisconnectedVisibleWorkspaceMigrations(
        removedFrom previousMonitors: [Monitor],
        survivingMonitors: [Monitor]
    ) -> [DisconnectedVisibleWorkspaceMigration] {
        let survivingIds = Set(survivingMonitors.map(\.id))
        var migrations: [DisconnectedVisibleWorkspaceMigration] = []
        migrations.reserveCapacity(previousMonitors.count)

        for monitor in previousMonitors where !survivingIds.contains(monitor.id) {
            guard let workspaceId = visibleWorkspaceId(on: monitor.id),
                  descriptor(for: workspaceId) != nil
            else {
                continue
            }
            disconnectedVisibleWorkspaceCache[MonitorRestoreKey(monitor: monitor)] = workspaceId
            migrations.append(
                DisconnectedVisibleWorkspaceMigration(
                    removedMonitor: monitor,
                    workspaceId: workspaceId
                )
            )
        }

        migrations.sort { lhs, rhs in
            monitorSortKey(lhs.removedMonitor) < monitorSortKey(rhs.removedMonitor)
        }
        return migrations
    }

    private func restoreDisconnectedVisibleWorkspacesToHomeMonitors(monitorsWereAdded: Bool) {
        guard monitorsWereAdded, !disconnectedVisibleWorkspaceCache.isEmpty else { return }

        let sortedCacheEntries = disconnectedVisibleWorkspaceCache.sorted { lhs, rhs in
            restoreKeySortKey(lhs.key) < restoreKeySortKey(rhs.key)
        }

        var reconnectAssignments: [Monitor.ID: WorkspaceDescriptor.ID] = [:]
        for (_, workspaceId) in sortedCacheEntries {
            guard descriptor(for: workspaceId) != nil else { continue }
            guard let homeMonitor = homeMonitor(for: workspaceId) else { continue }
            guard reconnectAssignments[homeMonitor.id] == nil else { continue }
            reconnectAssignments[homeMonitor.id] = workspaceId
        }

        for monitor in Monitor.sortedByPosition(monitors) {
            guard let workspaceId = reconnectAssignments[monitor.id] else { continue }
            _ = setActiveWorkspaceInternal(
                workspaceId,
                on: monitor.id,
                anchorPoint: monitor.workspaceAnchorPoint,
                updateInteractionMonitor: false,
                notify: false
            )
        }
    }

    private func applyDisconnectedVisibleWorkspaceMigrations(
        _ migrations: [DisconnectedVisibleWorkspaceMigration]
    ) {
        guard !migrations.isEmpty else { return }

        var winnerByFallbackMonitorId: [Monitor.ID: DisconnectedVisibleWorkspaceMigration] = [:]
        for migration in migrations {
            guard descriptor(for: migration.workspaceId) != nil else { continue }
            guard let fallbackMonitor = effectiveMonitor(for: migration.workspaceId) else { continue }
            guard winnerByFallbackMonitorId[fallbackMonitor.id] == nil else { continue }
            winnerByFallbackMonitorId[fallbackMonitor.id] = migration
        }

        for monitor in Monitor.sortedByPosition(monitors) {
            guard let migration = winnerByFallbackMonitorId[monitor.id] else { continue }
            _ = setActiveWorkspaceInternal(
                migration.workspaceId,
                on: monitor.id,
                anchorPoint: monitor.workspaceAnchorPoint,
                updateInteractionMonitor: false,
                notify: false
            )
        }
    }

    private func pruneRestoredDisconnectedVisibleWorkspaces() {
        disconnectedVisibleWorkspaceCache = disconnectedVisibleWorkspaceCache.filter { _, workspaceId in
            guard descriptor(for: workspaceId) != nil else { return false }
            guard let homeMonitorId = homeMonitorId(for: workspaceId) else { return true }
            return visibleWorkspaceId(on: homeMonitorId) != workspaceId
        }
    }

    private func reconcileConfiguredVisibleWorkspaces(notify: Bool = true) {
        var changed = false

        for monitor in Monitor.sortedByPosition(monitors) {
            let assigned = workspaces(on: monitor.id)
            guard !assigned.isEmpty else {
                if visibleWorkspaceId(on: monitor.id) != nil || previousVisibleWorkspaceId(on: monitor.id) != nil {
                    updateMonitorSession(monitor.id) { session in
                        session.visibleWorkspaceId = nil
                        session.previousVisibleWorkspaceId = nil
                    }
                    changed = true
                }
                continue
            }

            if let currentVisibleId = visibleWorkspaceId(on: monitor.id),
               assigned.contains(where: { $0.id == currentVisibleId })
            {
                continue
            }

            guard let defaultWorkspaceId = assigned.first?.id else { continue }
            if setActiveWorkspaceInternal(
                defaultWorkspaceId,
                on: monitor.id,
                anchorPoint: monitor.workspaceAnchorPoint,
                notify: false
            ) {
                changed = true
            }
        }

        if notify, changed {
            notifySessionStateChanged()
        }
    }

    private func restoreVisibleWorkspacesAfterMonitorConfigurationChange(
        from snapshots: [WorkspaceRestoreSnapshot]
    ) {
        guard !snapshots.isEmpty else { return }

        let assignments = resolveWorkspaceRestoreAssignments(
            snapshots: snapshots,
            monitors: monitors,
            workspaceExists: { descriptor(for: $0) != nil }
        )
        guard !assignments.isEmpty else { return }

        let sortedMonitors = Monitor.sortedByPosition(monitors)
        var restoredWorkspaces: Set<WorkspaceDescriptor.ID> = []

        for monitor in sortedMonitors {
            guard let workspaceId = assignments[monitor.id] else { continue }
            guard workspaceMonitorId(for: workspaceId) == monitor.id else { continue }
            guard restoredWorkspaces.insert(workspaceId).inserted else { continue }
            _ = setActiveWorkspaceInternal(
                workspaceId,
                on: monitor.id,
                anchorPoint: monitor.workspaceAnchorPoint,
                updateInteractionMonitor: false,
                notify: false
            )
        }
    }

    private func ensureVisibleWorkspaces(previousMonitors: [Monitor]? = nil, notify: Bool = true) {
        let currentMonitorIds = Set(monitors.map(\.id))
        let expectedVisibleMonitorIds = expectedVisibleMonitorIds()
        let previousMonitorSessions = sessionState.monitorSessions
        sessionState.monitorSessions = previousMonitorSessions.filter {
            currentMonitorIds.contains($0.key) && expectedVisibleMonitorIds.contains($0.key)
        }
        invalidateWorkspaceProjectionCaches()

        let currentVisibleMonitorIds = Set(activeVisibleWorkspaceMap(from: sessionState.monitorSessions).keys)
        if currentVisibleMonitorIds != expectedVisibleMonitorIds {
            rearrangeWorkspacesOnMonitors(
                previousMonitors: previousMonitors,
                previousMonitorSessions: previousMonitorSessions,
                notify: notify
            )
        }
    }

    private func replaceMonitors(with newMonitors: [Monitor], notify: Bool = true) {
        let previousMonitors = monitors
        monitors = newMonitors.isEmpty ? [Monitor.fallback()] : newMonitors
        ensureVisibleWorkspaces(previousMonitors: previousMonitors, notify: notify)
    }

    private func rearrangeWorkspacesOnMonitors(
        previousMonitors: [Monitor]? = nil,
        previousMonitorSessions: [Monitor.ID: SessionState.MonitorSession]? = nil,
        notify: Bool = true
    ) {
        let sortedNewMonitors = Monitor.sortedByPosition(monitors)
        let oldForward = activeVisibleWorkspaceMap(from: previousMonitorSessions ?? sessionState.monitorSessions)
        var oldMonitorById: [Monitor.ID: Monitor] = [:]

        let oldCandidates = previousMonitors ?? monitors
        for monitor in oldCandidates {
            oldMonitorById[monitor.id] = monitor
        }
        let visibleSnapshots = oldForward.compactMap { monitorId, workspaceId -> WorkspaceRestoreSnapshot? in
            guard let monitor = oldMonitorById[monitorId] else { return nil }
            return WorkspaceRestoreSnapshot(
                monitor: MonitorRestoreKey(monitor: monitor),
                workspaceId: workspaceId
            )
        }
        let restoredAssignments = resolveWorkspaceRestoreAssignments(
            snapshots: visibleSnapshots,
            monitors: monitors,
            workspaceExists: { descriptor(for: $0) != nil }
        )

        sessionState.monitorSessions = sessionState.monitorSessions.mapValues { session in
            var pruned = session
            pruned.visibleWorkspaceId = nil
            return pruned
        }
        invalidateWorkspaceProjectionCaches()

        for newMonitor in sortedNewMonitors {
            if let existingWorkspaceId = restoredAssignments[newMonitor.id],
               workspaceMonitorId(for: existingWorkspaceId) == newMonitor.id,
               setActiveWorkspaceInternal(
                   existingWorkspaceId,
                   on: newMonitor.id,
                   anchorPoint: newMonitor.workspaceAnchorPoint,
                   notify: false
               )
            {
                continue
            }
            if let defaultWorkspaceId = defaultVisibleWorkspaceId(on: newMonitor.id) {
                _ = setActiveWorkspaceInternal(
                    defaultWorkspaceId,
                    on: newMonitor.id,
                    anchorPoint: newMonitor.workspaceAnchorPoint,
                    notify: false
                )
            }
        }

        if notify {
            notifySessionStateChanged()
        }
    }

    private func defaultVisibleWorkspaceId(on monitorId: Monitor.ID) -> WorkspaceDescriptor.ID? {
        let assigned = workspaces(on: monitorId)
        guard !assigned.isEmpty else { return nil }
        return assigned.first?.id
    }

    private func expectedVisibleMonitorIds() -> Set<Monitor.ID> {
        Set(monitors.compactMap { monitor in
            defaultVisibleWorkspaceId(on: monitor.id) == nil ? nil : monitor.id
        })
    }

    private func replaceVisibleWorkspaceIfNeeded(on monitorId: Monitor.ID) {
        guard let monitor = monitor(byId: monitorId) else { return }
        if let defaultWorkspaceId = defaultVisibleWorkspaceId(on: monitor.id) {
            _ = setActiveWorkspaceInternal(
                defaultWorkspaceId,
                on: monitor.id,
                anchorPoint: monitor.workspaceAnchorPoint
            )
        } else {
            updateMonitorSession(monitor.id) { session in
                session.visibleWorkspaceId = nil
                session.previousVisibleWorkspaceId = nil
            }
            notifySessionStateChanged()
        }
    }

    private func resolvedWorkspaceMonitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        guard let workspace = descriptor(for: workspaceId) else { return nil }
        if configuredWorkspaceNames().contains(workspace.name) {
            return effectiveMonitor(for: workspaceId)?.id
        }
        return monitorIdShowingWorkspace(workspaceId)
    }

    private func workspaceMonitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        resolvedWorkspaceMonitorId(for: workspaceId)
    }

    private func configuredMonitorDescriptions(for workspaceName: String) -> [MonitorDescription]? {
        let assignments = settings.workspaceToMonitorAssignments()
        guard let descriptions = assignments[workspaceName], !descriptions.isEmpty else { return nil }
        return descriptions
    }

    private func homeMonitor(for workspaceId: WorkspaceDescriptor.ID) -> Monitor? {
        homeMonitor(for: workspaceId, in: monitors)
    }

    private func homeMonitor(for workspaceId: WorkspaceDescriptor.ID, in monitors: [Monitor]) -> Monitor? {
        guard let workspace = descriptor(for: workspaceId) else { return nil }
        guard let descriptions = configuredMonitorDescriptions(for: workspace.name) else { return nil }
        let sorted = Monitor.sortedByPosition(monitors)
        return descriptions.compactMap { $0.resolveMonitor(sortedMonitors: sorted) }.first
    }

    private func homeMonitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        homeMonitor(for: workspaceId)?.id
    }

    private func effectiveMonitor(for workspaceId: WorkspaceDescriptor.ID) -> Monitor? {
        effectiveMonitor(for: workspaceId, in: monitors)
    }

    private func effectiveMonitor(for workspaceId: WorkspaceDescriptor.ID, in monitors: [Monitor]) -> Monitor? {
        if let home = homeMonitor(for: workspaceId, in: monitors) {
            return home
        }

        let sortedMonitors = Monitor.sortedByPosition(monitors)
        guard !sortedMonitors.isEmpty else { return nil }
        guard let workspace = descriptor(for: workspaceId) else { return nil }

        let anchorPoint = workspace.assignedMonitorPoint
            ?? monitorIdShowingWorkspace(workspaceId).flatMap { monitor(byId: $0)?.workspaceAnchorPoint }
        guard let anchorPoint else { return sortedMonitors.first }

        return sortedMonitors.min { lhs, rhs in
            let lhsDistance = lhs.workspaceAnchorPoint.distanceSquared(to: anchorPoint)
            let rhsDistance = rhs.workspaceAnchorPoint.distanceSquared(to: anchorPoint)
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }
            return monitorSortKey(lhs) < monitorSortKey(rhs)
        }
    }

    private func isValidAssignment(workspaceId: WorkspaceDescriptor.ID, monitorId: Monitor.ID) -> Bool {
        guard let workspace = descriptor(for: workspaceId) else { return false }
        guard configuredWorkspaceNames().contains(workspace.name) else { return false }
        return effectiveMonitor(for: workspaceId)?.id == monitorId
    }

    private func setActiveWorkspaceInternal(
        _ workspaceId: WorkspaceDescriptor.ID,
        on monitorId: Monitor.ID,
        anchorPoint: CGPoint? = nil,
        updateInteractionMonitor: Bool = false,
        notify: Bool = true
    ) -> Bool {
        guard isValidAssignment(workspaceId: workspaceId, monitorId: monitorId) else { return false }
        let effectiveAnchorPoint = anchorPoint ?? monitor(byId: monitorId)?.workspaceAnchorPoint
        var workspaceVisibilityChanged = false

        if let prevMonitorId = monitorIdShowingWorkspace(workspaceId),
           prevMonitorId != monitorId
        {
            updateMonitorSession(prevMonitorId) { session in
                session.previousVisibleWorkspaceId = workspaceId
                session.visibleWorkspaceId = nil
            }
            workspaceVisibilityChanged = true
        }

        let previousWorkspaceOnMonitor = visibleWorkspaceId(on: monitorId)
        if previousWorkspaceOnMonitor != workspaceId {
            updateMonitorSession(monitorId) { session in
                if let previousWorkspaceOnMonitor {
                    session.previousVisibleWorkspaceId = previousWorkspaceOnMonitor
                }
                session.visibleWorkspaceId = workspaceId
            }
            workspaceVisibilityChanged = true
        }

        updateWorkspace(workspaceId) { workspace in
            workspace.assignedMonitorPoint = effectiveAnchorPoint
        }

        if updateInteractionMonitor {
            let interactionChanged = self.updateInteractionMonitor(monitorId, preservePrevious: true, notify: false)
            if notify, workspaceVisibilityChanged || interactionChanged {
                notifySessionStateChanged()
            }
        } else if workspaceVisibilityChanged, notify {
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

    private func activeVisibleWorkspaceMap() -> [Monitor.ID: WorkspaceDescriptor.ID] {
        visibleWorkspaceMap()
    }

    private func activeVisibleWorkspaceMap(
        from monitorSessions: [Monitor.ID: SessionState.MonitorSession]
    ) -> [Monitor.ID: WorkspaceDescriptor.ID] {
        Dictionary(uniqueKeysWithValues: monitorSessions.compactMap { monitorId, session in
            guard let visibleWorkspaceId = session.visibleWorkspaceId else { return nil }
            return (monitorId, visibleWorkspaceId)
        })
    }

    private func updateMonitorSession(
        _ monitorId: Monitor.ID,
        _ mutate: (inout SessionState.MonitorSession) -> Void
    ) {
        var monitorSession = sessionState.monitorSessions[monitorId] ?? SessionState.MonitorSession()
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
        guard sessionState.interactionMonitorId != monitorId else { return false }
        if preservePrevious,
           let currentMonitorId = sessionState.interactionMonitorId,
           currentMonitorId != monitorId
        {
            sessionState.previousInteractionMonitorId = currentMonitorId
        }
        sessionState.interactionMonitorId = monitorId
        if notify {
            notifySessionStateChanged()
        }
        return true
    }

    private func restoreKeySortKey(_ restoreKey: MonitorRestoreKey) -> (CGFloat, CGFloat, UInt32) {
        (restoreKey.anchorPoint.x, -restoreKey.anchorPoint.y, restoreKey.displayId)
    }

    private func reconcileInteractionMonitorState(notify: Bool = true) {
        let validMonitorIds = Set(monitors.map(\.id))
        let focusedWorkspaceMonitorId = sessionState.focus.focusedToken
            .flatMap { entry(for: $0)?.workspaceId }
            .flatMap { monitorId(for: $0) }
        let newInteractionMonitorId = sessionState.interactionMonitorId.flatMap {
            validMonitorIds.contains($0) ? $0 : nil
        } ?? focusedWorkspaceMonitorId.flatMap {
            validMonitorIds.contains($0) ? $0 : nil
        } ?? monitors.first?.id
        let newPreviousInteractionMonitorId = sessionState.previousInteractionMonitorId.flatMap {
            validMonitorIds.contains($0) ? $0 : nil
        }

        let changed = sessionState.interactionMonitorId != newInteractionMonitorId
            || sessionState.previousInteractionMonitorId != newPreviousInteractionMonitorId

        sessionState.interactionMonitorId = newInteractionMonitorId
        sessionState.previousInteractionMonitorId = newPreviousInteractionMonitorId

        if changed, notify {
            notifySessionStateChanged()
        }
    }

    private func notifySessionStateChanged() {
        onSessionStateChanged?()
    }
}

private extension CGPoint {
    func distanceSquared(to point: CGPoint) -> CGFloat {
        let dx = x - point.x
        let dy = y - point.y
        return dx * dx + dy * dy
    }
}
