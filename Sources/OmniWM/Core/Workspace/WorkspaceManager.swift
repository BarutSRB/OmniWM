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

private struct PersistedWindowRestoreCatalogBuildSnapshot: Sendable {
    let entries: [PersistedWindowRestoreCatalogBuildEntry]
}

private struct PersistedWindowRestoreCatalogBuildEntry: Sendable {
    let token: WindowToken
    let metadata: ManagedReplacementMetadata
    let workspaceName: String
    let topologyProfile: TopologyProfile
    let preferredMonitor: DisplayFingerprint?
    let floatingFrame: CGRect?
    let normalizedFloatingOrigin: CGPoint?
    let restoreToFloating: Bool
    let rescueEligible: Bool
    let niriPlacement: PersistedNiriPlacement?
}

private enum PersistedWindowRestoreCatalogBuilder {
    private struct Candidate {
        let key: PersistedWindowRestoreKey
        let entry: PersistedWindowRestoreEntry
    }

    static func build(from snapshot: PersistedWindowRestoreCatalogBuildSnapshot) -> PersistedWindowRestoreCatalog {
        var candidatesByBaseKey: [PersistedWindowRestoreBaseKey: [Candidate]] = [:]

        for snapshotEntry in snapshot.entries {
            guard let key = PersistedWindowRestoreKey(metadata: snapshotEntry.metadata) else { continue }
            let persistedEntry = PersistedWindowRestoreEntry(
                key: key,
                identity: PersistedWindowRestoreIdentity(
                    token: snapshotEntry.token,
                    metadata: snapshotEntry.metadata
                ),
                restoreIntent: PersistedRestoreIntent(
                    workspaceName: snapshotEntry.workspaceName,
                    topologyProfile: snapshotEntry.topologyProfile,
                    preferredMonitor: snapshotEntry.preferredMonitor,
                    floatingFrame: snapshotEntry.floatingFrame,
                    normalizedFloatingOrigin: snapshotEntry.normalizedFloatingOrigin,
                    restoreToFloating: snapshotEntry.restoreToFloating,
                    rescueEligible: snapshotEntry.rescueEligible,
                    niriPlacement: snapshotEntry.niriPlacement
                )
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

            let identityCandidates = candidates.filter { $0.entry.identity != nil }
            persistedEntries.append(contentsOf: identityCandidates.map(\.entry))

            let semanticCandidates = candidates.filter { $0.entry.identity == nil }
            let candidatesByTitle = Dictionary(grouping: semanticCandidates, by: { $0.key.title })
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
            if (lhs.key.title ?? "") != (rhs.key.title ?? "") {
                return (lhs.key.title ?? "") < (rhs.key.title ?? "")
            }
            if lhs.identity?.pid != rhs.identity?.pid {
                return (lhs.identity?.pid ?? Int32.min) < (rhs.identity?.pid ?? Int32.min)
            }
            return (lhs.identity?.windowId ?? Int.min) < (rhs.identity?.windowId ?? Int.min)
        }

        return PersistedWindowRestoreCatalog(entries: persistedEntries)
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

    struct NativeFullscreenRecord: Equatable {
        let originalToken: WindowToken
        var currentToken: WindowToken
        var workspaceId: WorkspaceDescriptor.ID
        var transitionId: UInt64
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
                var requestId: UInt64?
            }

            var focusedToken: WindowToken?
            var pendingManagedFocus = PendingManagedFocusRequest()
            var lastTiledFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowToken] = [:]
            var lastFloatingFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowToken] = [:]
            var focusLease: FocusPolicyLease?
            var isNonManagedFocusActive: Bool = false
            var isAppFullscreenActive: Bool = false
            var nonManagedFocusToken: WindowToken?
            var suppressedFocusToken: WindowToken?
        }

        var interactionMonitorId: Monitor.ID?
        var previousInteractionMonitorId: Monitor.ID?
        var monitorSessions: [Monitor.ID: MonitorSession] = [:]
        var workspaceSessions: [WorkspaceDescriptor.ID: WorkspaceSession] = [:]
        var scratchpadToken: WindowToken?
        var focus = FocusSession()
    }

    private struct MonitorResolutionContext {
        let monitors: [Monitor]
        let sortedMonitors: [Monitor]
        let topologyProfile: TopologyProfile
        let configuredWorkspaceNames: Set<String>
        let monitorDescriptionByWorkspaceName: [String: MonitorDescription]
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
    private let world = WorldStore()
    private let restorePlanner = RestorePlanner()
    private let bootPersistedWindowRestoreCatalog: PersistedWindowRestoreCatalog
    private var nativeFullscreenRecordsByOriginalToken: [WindowToken: NativeFullscreenRecord] = [:]
    private var nativeFullscreenOriginalTokenByCurrentToken: [WindowToken: WindowToken] = [:]
    private var nextNativeFullscreenTransitionId: UInt64 = 1
    private var consumedBootPersistedWindowRestoreEntries: Set<PersistedWindowRestoreConsumptionKey> = []
    private var persistedWindowRestoreCatalogDirty = false
    private var persistedWindowRestoreCatalogSaveScheduled = false
    private var persistedWindowRestoreCatalogBuildInFlight = false
    private var persistedWindowRestoreCatalogRevision: UInt64 = 0
    private var runtimeRevisionSerial: UInt64 = 0
    private var globalWorkspaceRevision: UInt64 = 0
    private var globalLayoutRevision: UInt64 = 0
    private var globalFocusRevision: UInt64 = 0
    private var globalFullscreenRevision: UInt64 = 0
    private var workspaceRevisions: [WorkspaceDescriptor.ID: UInt64] = [:]
    private var layoutRevisions: [WorkspaceDescriptor.ID: UInt64] = [:]
    private var focusRevisions: [WorkspaceDescriptor.ID: UInt64] = [:]
    private var fullscreenRevisions: [WorkspaceDescriptor.ID: UInt64] = [:]
    var persistedRestoreBundleIdProvider: ((pid_t) -> String?)?

    private var _cachedSortedMonitors: [Monitor]?
    private var _cachedTopologyProfile: TopologyProfile?
    private var _cachedConfiguredWorkspaceNames: [String]?
    private var _cachedConfiguredWorkspaceNameSet: Set<String>?
    private var _cachedMonitorDescriptionByWorkspaceName: [String: MonitorDescription]?
    private var _cachedSortedWorkspaces: [WorkspaceDescriptor]?
    private var _cachedWorkspaceIdsByMonitor: [Monitor.ID: [WorkspaceDescriptor.ID]]?
    private var _cachedVisibleWorkspaceIds: Set<WorkspaceDescriptor.ID>?
    private var _cachedVisibleWorkspaceMap: [Monitor.ID: WorkspaceDescriptor.ID]?
    private var _cachedMonitorIdByVisibleWorkspace: [WorkspaceDescriptor.ID: Monitor.ID]?
    var animationClock: AnimationClock?
    private var sessionState = SessionState()

    var onGapsChanged: (() -> Void)?
    var onSessionStateChanged: (() -> Void)?
    var onRuntimeRevisionChanged: ((WorkspaceDescriptor.ID?, RuntimeRevisionDomain) -> Void)?

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
        let windowSnapshots = world.allEntries()
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
            topologyProfile: currentTopologyProfile(),
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
                monitorId: sessionState.focus.pendingManagedFocus.monitorId,
                requestId: sessionState.focus.pendingManagedFocus.requestId
            ),
            focusLease: sessionState.focus.focusLease,
            isNonManagedFocusActive: sessionState.focus.isNonManagedFocusActive,
            isAppFullscreenActive: sessionState.focus.isAppFullscreenActive,
            interactionMonitorId: sessionState.interactionMonitorId,
            previousInteractionMonitorId: sessionState.previousInteractionMonitorId
        )
    }

    func reconcileSnapshotDump() -> String {
        ReconcileDebugDump.snapshot(reconcileSnapshot())
    }

    func reconcileTraceDump(limit: Int? = nil) -> String {
        ReconcileDebugDump.trace(world.traceRecords(), limit: limit)
    }

    func runtimeRevision(for workspaceId: WorkspaceDescriptor.ID) -> RuntimeRevision {
        RuntimeRevision(
            runtime: runtimeRevisionSerial,
            workspace: workspaceRevisions[workspaceId, default: 0],
            layout: layoutRevisions[workspaceId, default: 0],
            focus: focusRevisions[workspaceId, default: 0],
            fullscreen: fullscreenRevisions[workspaceId, default: 0]
        )
    }

    func runtimeEpoch(for domains: RuntimeRevisionDomain) -> RuntimeRevision {
        RuntimeRevision(
            runtime: runtimeRevisionSerial,
            workspace: globalWorkspaceRevision,
            layout: globalLayoutRevision,
            focus: globalFocusRevision,
            fullscreen: globalFullscreenRevision
        )
    }

    func isRuntimeEpochCurrent(_ epoch: RuntimeRevision, domains: RuntimeRevisionDomain) -> Bool {
        epoch.matches(runtimeEpoch(for: domains), domains: domains)
    }

    func isRuntimeRevisionCurrent(
        _ revision: RuntimeRevision,
        for workspaceId: WorkspaceDescriptor.ID,
        domains: RuntimeRevisionDomain
    ) -> Bool {
        guard workspacesById[workspaceId] != nil else { return false }
        return revision.matches(runtimeRevision(for: workspaceId), domains: domains)
    }

    @discardableResult
    func recordReconcileEvent(_ event: WMEvent) -> ReconcileTxn {
        let txn = world.commit(
            event,
            monitors: monitors,
            snapshot: { self.reconcileSnapshot() },
            resolvePlan: { plan, token in
                var plan = plan
                let snapshot = self.reconcileSnapshot()
                let restoreEventPlan = self.restorePlanner.planEvent(
                    .init(
                        event: event,
                        snapshot: snapshot,
                        monitors: self.monitors
                    )
                )
                if let restoreRefresh = self.plannedRestoreRefresh(
                    from: restoreEventPlan,
                    snapshot: snapshot
                ) {
                    plan.restoreRefresh = restoreRefresh
                }
                if let token, let persistedHydration = self.plannedPersistedHydrationMutation(for: token) {
                    plan = self.mergePersistedHydration(
                        persistedHydration,
                        into: plan,
                        existingEntry: self.world.entry(for: token)
                    )
                }
                if !restoreEventPlan.notes.isEmpty {
                    plan.notes.append(contentsOf: restoreEventPlan.notes)
                }
                return self.applyActionPlan(plan, to: token)
            }
        )
        if txn.plan.mutatesRuntimeState || eventRequiresRuntimeInvalidation(event) {
            bumpRuntimeRevision(for: event)
        }
        return txn
    }

    @discardableResult
    private func recordTopologyChange(to newMonitors: [Monitor]) -> ReconcileTxn {
        let normalizedMonitors = newMonitors.isEmpty ? [Monitor.fallback()] : newMonitors
        let snapshot = reconcileSnapshot()
        let topologyResolutionContext = monitorResolutionContext(for: normalizedMonitors)
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
                    guard let self else { return nil }
                    let context = monitors == topologyResolutionContext.monitors
                        ? topologyResolutionContext
                        : self.monitorResolutionContext(for: monitors)
                    return self.homeMonitor(for: workspaceId, context: context)?.id
                },
                effectiveMonitorId: { [weak self] workspaceId, monitors in
                    guard let self else { return nil }
                    let context = monitors == topologyResolutionContext.monitors
                        ? topologyResolutionContext
                        : self.monitorResolutionContext(for: monitors)
                    return self.effectiveMonitor(for: workspaceId, context: context)?.id
                }
            )
        )
        let event = WMEvent.topologyChanged(
            displays: topologyResolutionContext.topologyProfile.displays,
            source: .workspaceManager
        )

        let txn = world.commit(
            event,
            monitors: normalizedMonitors,
            snapshot: { self.reconcileSnapshot() },
            resolvePlan: { plan, _ in
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
        if txn.plan.mutatesRuntimeState || eventRequiresRuntimeInvalidation(event) {
            bumpRuntimeRevision(for: event)
        }
        return txn
    }

    private func eventRequiresRuntimeInvalidation(_ event: WMEvent) -> Bool {
        switch event {
        case .activeSpaceChanged,
             .floatingStateChanged,
             .manualLayoutOverrideChanged,
             .systemSleep,
             .systemWake,
             .topologyChanged:
            return true
        case .floatingGeometryUpdated,
             .focusLeaseChanged,
             .hiddenStateChanged,
             .managedFocusCancelled,
             .managedFocusConfirmed,
             .managedFocusRequested,
             .managedReplacementMetadataChanged,
             .nativeFullscreenTransition,
             .niriPlacementsResolved,
             .nonManagedFocusChanged,
             .windowAdmitted,
             .windowModeChanged,
             .windowRekeyed,
             .windowRemoved,
             .workspaceAssigned:
            return false
        }
    }

    private func applyActionPlan(
        _ plan: ActionPlan,
        to token: WindowToken?
    ) -> ActionPlan {
        var resolvedPlan = plan
        resolvedPlan.restoreIntent = nil

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
            world.setLifecyclePhase(lifecyclePhase, for: token)
        }
        if let observedState = plan.observedState {
            world.setObservedState(observedState, for: token)
        }
        if let desiredState = plan.desiredState {
            world.setDesiredState(desiredState, for: token)
        }
        if let replacementCorrelation = plan.replacementCorrelation {
            world.setReplacementCorrelation(replacementCorrelation, for: token)
        }
        if let entry = world.entry(for: token) {
            let restoreIntent = StateReducer.restoreIntent(for: entry, monitors: monitors)
            if entry.restoreIntent != restoreIntent {
                world.setRestoreIntent(restoreIntent, for: token)
                resolvedPlan.restoreIntent = restoreIntent
            }
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
            monitorId: focusSession.pendingManagedFocus.monitorId,
            requestId: focusSession.pendingManagedFocus.requestId
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
        var changed = focusSessionSnapshot() != previousFocusSession
        if case let .managedFocusConfirmed(token, _, _, _, _, _) = event {
            changed = updateFocusSession(notify: false) { focus in
                var focusChanged = false
                if focus.suppressedFocusToken == token {
                    focus.suppressedFocusToken = nil
                    focusChanged = true
                }
                if focus.nonManagedFocusToken != nil {
                    focus.nonManagedFocusToken = nil
                    focusChanged = true
                }
                return focusChanged
            } || changed
        }
        return changed
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
        for entry in world.allEntries() {
            world.setRestoreIntent(
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

        let previousWorkspaceId = sessionState.interactionMonitorId
            .flatMap { currentActiveWorkspace(on: $0)?.id }
        let nextWorkspaceId = plan.interactionMonitorId
            .flatMap { currentActiveWorkspace(on: $0)?.id }
        let interactionChanged = sessionState.interactionMonitorId != plan.interactionMonitorId
            || sessionState.previousInteractionMonitorId != plan.previousInteractionMonitorId
        sessionState.interactionMonitorId = plan.interactionMonitorId
        sessionState.previousInteractionMonitorId = plan.previousInteractionMonitorId
        if interactionChanged {
            bumpFocusRevision(
                previousWorkspaceId: previousWorkspaceId,
                currentWorkspaceId: nextWorkspaceId
            )
        }
    }

    private func applyTopologyTransition(_ transition: TopologyTransitionPlan) {
        replaceMonitorsForTopologyTransition(with: transition.newMonitors)
        let context = monitorResolutionContext()

        for monitor in context.sortedMonitors {
            guard let workspaceId = transition.visibleAssignments[monitor.id] else { continue }
            _ = setActiveWorkspaceInternal(
                workspaceId,
                on: monitor.id,
                anchorPoint: monitor.workspaceAnchorPoint,
                updateInteractionMonitor: false,
                notify: false,
                context: context
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
        let context = monitorResolutionContext()
        for entry in world.allEntries() {
            let currentMonitorId = monitorId(for: entry.workspaceId, context: context)
            if entry.observedState.monitorId != currentMonitorId {
                var observedState = entry.observedState
                observedState.monitorId = currentMonitorId
                world.setObservedState(observedState, for: entry.token)
            }
            if entry.desiredState.monitorId != currentMonitorId {
                var desiredState = entry.desiredState
                desiredState.monitorId = currentMonitorId
                world.setDesiredState(desiredState, for: entry.token)
            }
        }
    }

    private func plannedPersistedHydrationMutation(for token: WindowToken) -> PersistedHydrationMutation? {
        guard let entry = world.entry(for: token),
              let metadata = persistedRestoreMetadata(for: entry),
              let hydrationPlan = restorePlanner.planPersistedHydration(
                  .init(
                      token: token,
                      metadata: metadata,
                      catalog: bootPersistedWindowRestoreCatalog,
                      consumedEntries: consumedBootPersistedWindowRestoreEntries,
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
            niriPlacement: hydrationPlan.niriPlacement,
            consumedKey: hydrationPlan.consumedKey,
            consumedEntry: hydrationPlan.consumedEntry
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
        guard let entry = world.entry(for: token) else {
            return false
        }

        if entry.workspaceId != hydration.workspaceId {
            world.updateWorkspace(for: token, workspace: hydration.workspaceId)
        }

        let focusChanged = applyWindowModeMutationWithoutReconcile(
            hydration.targetMode,
            for: token,
            workspaceId: hydration.workspaceId
        )

        if let entry = world.entry(for: token) {
            var restoreIntent = StateReducer.restoreIntent(for: entry, monitors: monitors)
            restoreIntent.niriPlacement = hydration.niriPlacement
            world.setRestoreIntent(restoreIntent, for: token)
        }

        if let floatingFrame = hydration.floatingFrame {
            let referenceMonitor = hydration.monitorId.flatMap(monitor(byId:))
            let referenceVisibleFrame = referenceMonitor?.visibleFrame ?? floatingFrame
            let normalizedOrigin = normalizedFloatingOrigin(
                for: floatingFrame,
                in: referenceVisibleFrame
            )
            world.setFloatingState(
                .init(
                    lastFrame: floatingFrame,
                    normalizedOrigin: normalizedOrigin,
                    referenceMonitorId: referenceMonitor?.id,
                    restoreToFloating: true
                ),
                for: token
            )
        }

        consumedBootPersistedWindowRestoreEntries.insert(hydration.consumedEntry)
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

        world.setMode(mode, for: token)
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
        markPersistedWindowRestoreCatalogDirty()
        flushPersistedWindowRestoreCatalogSynchronously()
    }

    private func schedulePersistedWindowRestoreCatalogSave() {
        markPersistedWindowRestoreCatalogDirty()
        enqueuePersistedWindowRestoreCatalogSave()
    }

    private func markPersistedWindowRestoreCatalogDirty() {
        persistedWindowRestoreCatalogDirty = true
        persistedWindowRestoreCatalogRevision &+= 1
    }

    private func enqueuePersistedWindowRestoreCatalogSave() {
        guard !persistedWindowRestoreCatalogSaveScheduled,
              !persistedWindowRestoreCatalogBuildInFlight
        else { return }
        persistedWindowRestoreCatalogSaveScheduled = true

        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 75_000_000)
            } catch {
                return
            }
            guard let self else { return }
            self.persistedWindowRestoreCatalogSaveScheduled = false
            self.startPersistedWindowRestoreCatalogBuildIfNeeded()
        }
    }

    private func startPersistedWindowRestoreCatalogBuildIfNeeded() {
        guard persistedWindowRestoreCatalogDirty else { return }
        persistedWindowRestoreCatalogDirty = false
        persistedWindowRestoreCatalogBuildInFlight = true
        let revision = persistedWindowRestoreCatalogRevision
        let snapshot = persistedWindowRestoreCatalogBuildSnapshot()

        Task { [weak self] in
            let catalog = await Task.detached(priority: .utility) {
                PersistedWindowRestoreCatalogBuilder.build(from: snapshot)
            }.value
            self?.completePersistedWindowRestoreCatalogBuild(catalog, revision: revision)
        }
    }

    private func completePersistedWindowRestoreCatalogBuild(
        _ catalog: PersistedWindowRestoreCatalog,
        revision: UInt64
    ) {
        persistedWindowRestoreCatalogBuildInFlight = false
        if revision == persistedWindowRestoreCatalogRevision, !persistedWindowRestoreCatalogDirty {
            settings.savePersistedWindowRestoreCatalog(catalog)
            return
        }
        if persistedWindowRestoreCatalogDirty {
            enqueuePersistedWindowRestoreCatalogSave()
        }
    }

    private func flushPersistedWindowRestoreCatalogSynchronously() {
        guard persistedWindowRestoreCatalogDirty else { return }
        persistedWindowRestoreCatalogDirty = false
        settings.savePersistedWindowRestoreCatalog(buildPersistedWindowRestoreCatalog())
    }

    private func buildPersistedWindowRestoreCatalog() -> PersistedWindowRestoreCatalog {
        PersistedWindowRestoreCatalogBuilder.build(from: persistedWindowRestoreCatalogBuildSnapshot())
    }

    private func persistedRestoreMetadata(for entry: WindowModel.Entry) -> ManagedReplacementMetadata? {
        let bundleId = entry.managedReplacementMetadata?.bundleId
            ?? persistedRestoreBundleIdProvider?(entry.pid)
        guard bundleId != nil || entry.managedReplacementMetadata != nil else {
            return nil
        }

        let fallback = ManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: entry.workspaceId,
            mode: entry.mode,
            role: nil,
            subrole: nil,
            title: nil,
            windowLevel: nil,
            parentWindowId: nil,
            frame: entry.observedState.frame ?? entry.desiredState.floatingFrame ?? entry.floatingState?.lastFrame,
            transientWindowServerEvidence: entry.managedReplacementMetadata?.transientWindowServerEvidence ?? false,
            degradedWindowServerChildEvidence: entry.managedReplacementMetadata?
                .degradedWindowServerChildEvidence ?? false
        )

        guard let metadata = entry.managedReplacementMetadata else {
            return fallback
        }

        var merged = fallback.mergingNonNilValues(from: metadata)
        merged.workspaceId = entry.workspaceId
        merged.mode = entry.mode
        return merged
    }

    private func persistedWindowRestoreCatalogBuildSnapshot() -> PersistedWindowRestoreCatalogBuildSnapshot {
        let context = monitorResolutionContext()
        let topologyProfile = context.topologyProfile
        var snapshotEntries: [PersistedWindowRestoreCatalogBuildEntry] = []

        for entry in world.allEntries() {
            guard let metadata = persistedRestoreMetadata(for: entry),
                  let restoreIntent = entry.restoreIntent,
                  let workspaceName = descriptor(for: entry.workspaceId)?.name
            else {
                continue
            }

            let preferredMonitor = monitor(for: entry.workspaceId, context: context).map(DisplayFingerprint.init)
                ?? restoreIntent.preferredMonitor

            snapshotEntries.append(
                PersistedWindowRestoreCatalogBuildEntry(
                    token: entry.token,
                    metadata: metadata,
                    workspaceName: workspaceName,
                    topologyProfile: topologyProfile,
                    preferredMonitor: preferredMonitor,
                    floatingFrame: restoreIntent.floatingFrame,
                    normalizedFloatingOrigin: restoreIntent.normalizedFloatingOrigin,
                    restoreToFloating: restoreIntent.restoreToFloating,
                    rescueEligible: restoreIntent.rescueEligible,
                    niriPlacement: restoreIntent.niriPlacement
                )
            )
        }

        return PersistedWindowRestoreCatalogBuildSnapshot(entries: snapshotEntries)
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
        focusedToken.flatMap { world.handle(for: $0) }
    }

    var pendingFocusedToken: WindowToken? {
        sessionState.focus.pendingManagedFocus.token
    }

    var pendingFocusedHandle: WindowHandle? {
        pendingFocusedToken.flatMap { world.handle(for: $0) }
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
        guard canConfirmManagedFocus(token, in: workspaceId, requestId: nil) else {
            return false
        }
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
                requestId: nil,
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
        onMonitor monitorId: Monitor.ID? = nil,
        requestId: UInt64
    ) -> Bool {
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id }
        var changed = rememberFocus(token, in: workspaceId)
        changed = applyFocusReconcileEvent(
            .managedFocusRequested(
                token: token,
                workspaceId: workspaceId,
                monitorId: normalizedMonitorId,
                requestId: requestId,
                source: .workspaceManager
            )
        ) || changed
        if changed {
            notifySessionStateChanged()
        }
        return changed
    }

    @discardableResult
    func selectNativeFullscreenPlaceholder(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil
    ) -> Bool {
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id } ?? self.monitorId(for: workspaceId)
        var changed = rememberFocus(token, in: workspaceId)
        if let normalizedMonitorId {
            changed = updateInteractionMonitor(normalizedMonitorId, preservePrevious: true, notify: false) || changed
        }
        changed = updateFocusSession(notify: false) { focus in
            var focusChanged = false
            if focus.focusedToken != token {
                focus.focusedToken = token
                focusChanged = true
            }
            if !focus.isNonManagedFocusActive {
                focus.isNonManagedFocusActive = true
                focusChanged = true
            }
            if !focus.isAppFullscreenActive {
                focus.isAppFullscreenActive = true
                focusChanged = true
            }
            focusChanged = clearPendingManagedFocusRequest(focus: &focus) || focusChanged
            return focusChanged
        } || changed
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
        activateWorkspaceOnMonitor: Bool,
        requestId: UInt64? = nil
    ) -> Bool {
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id } ?? self.monitorId(for: workspaceId)
        guard canConfirmManagedFocus(token, in: workspaceId, requestId: requestId) else {
            return false
        }
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
                requestId: requestId,
                source: .workspaceManager
            )
        ) || changed

        if changed {
            notifySessionStateChanged()
        }

        return changed
    }

    func canConfirmManagedFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        requestId: UInt64?
    ) -> Bool {
        if let requestId {
            return pendingManagedFocusMatches(
                token: token,
                workspaceId: workspaceId,
                requestId: requestId
            )
        }
        let request = sessionState.focus.pendingManagedFocus
        guard request.token != nil
            || request.workspaceId != nil
            || request.monitorId != nil
            || request.requestId != nil
        else {
            return true
        }
        return request.requestId == nil
            && request.token == token
            && request.workspaceId == workspaceId
    }

    @discardableResult
    func cancelManagedFocusRequest(
        matching token: WindowToken? = nil,
        workspaceId: WorkspaceDescriptor.ID? = nil,
        requestId: UInt64?
    ) -> Bool {
        let changed = applyFocusReconcileEvent(
            .managedFocusCancelled(
                token: token,
                workspaceId: workspaceId,
                requestId: requestId,
                source: .workspaceManager
            )
        )

        if changed {
            notifySessionStateChanged()
        }

        return changed
    }

    @discardableResult
    func cancelCurrentManagedFocusRequest(
        matching token: WindowToken? = nil,
        workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> Bool {
        let request = sessionState.focus.pendingManagedFocus
        let matchesToken = token.map { request.token == $0 } ?? true
        let matchesWorkspace = workspaceId.map { request.workspaceId == $0 } ?? true
        guard matchesToken,
              matchesWorkspace,
              request.token != nil
              || request.workspaceId != nil
              || request.monitorId != nil
              || request.requestId != nil
        else {
            return false
        }
        return cancelManagedFocusRequest(
            matching: token,
            workspaceId: workspaceId,
            requestId: request.requestId
        )
    }

    @discardableResult
    func setManagedAppFullscreen(_ active: Bool) -> Bool {
        let changed = applyFocusReconcileEvent(
            .nonManagedFocusChanged(
                active: false,
                appFullscreen: active,
                preserveFocusedToken: true,
                preservePendingManagedFocus: false,
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
            transitionId: 0,
            exitRequestedByCommand: false,
            transition: .enterRequested,
            availability: .present,
            unavailableSince: nil
        )

        if record.currentToken != token {
            record.currentToken = token
            changed = true
        }
        if record.workspaceId != workspaceId {
            record.workspaceId = workspaceId
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
            transitionId: 0,
            exitRequestedByCommand: false,
            transition: .suspended,
            availability: .present,
            unavailableSince: nil
        )

        if record.currentToken != token {
            record.currentToken = token
            changed = true
        }
        if record.workspaceId != entry.workspaceId {
            record.workspaceId = entry.workspaceId
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
            transitionId: 0,
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
        if record.workspaceId != workspaceId {
            record.workspaceId = workspaceId
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
        if let workspaceId = workspace(for: token), record.workspaceId != workspaceId {
            record.workspaceId = workspaceId
        }
        record.availability = .temporarilyUnavailable
        if record.unavailableSince == nil {
            record.unavailableSince = now
        }
        record = upsertNativeFullscreenRecord(record)
        _ = setManagedAppFullscreen(false)
        return record
    }

    @discardableResult
    func markNativeFullscreenSpeculativelyUnavailable(
        _ token: WindowToken,
        now: Date = Date()
    ) -> NativeFullscreenRecord? {
        guard let entry = entry(for: token) else { return nil }

        _ = rememberFocus(token, in: entry.workspaceId)
        setLayoutReason(.nativeFullscreen, for: token)
        let record = NativeFullscreenRecord(
            originalToken: token,
            currentToken: token,
            workspaceId: entry.workspaceId,
            transitionId: 0,
            exitRequestedByCommand: false,
            transition: .enterRequested,
            availability: .temporarilyUnavailable,
            unavailableSince: now
        )
        let storedRecord = upsertNativeFullscreenRecord(record)
        _ = setManagedAppFullscreen(false)
        return storedRecord
    }

    func nativeFullscreenUnavailableCandidate(
        for pid: pid_t,
        activeWorkspaceId: WorkspaceDescriptor.ID?,
        now: Date = Date()
    ) -> NativeFullscreenRecord? {
        let candidates = nativeFullscreenRecordsByOriginalToken.values.filter { record in
            guard record.currentToken.pid == pid,
                  record.availability == .temporarilyUnavailable,
                  isNativeFullscreenUnavailableCandidateFresh(record, now: now)
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

    private func isNativeFullscreenUnavailableCandidateFresh(
        _ record: NativeFullscreenRecord,
        now: Date
    ) -> Bool {
        guard let unavailableSince = record.unavailableSince else { return false }
        return now.timeIntervalSince(unavailableSince) < Self.staleUnavailableNativeFullscreenTimeout
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
        if let workspaceId = workspace(for: newToken) {
            record.workspaceId = workspaceId
        }
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
    func expireStaleTemporarilyUnavailableNativeFullscreenRecord(
        originalToken: WindowToken,
        transitionId: UInt64,
        now: Date = Date(),
        staleInterval: TimeInterval = staleUnavailableNativeFullscreenTimeout
    ) -> WindowModel.Entry? {
        guard let record = nativeFullscreenRecordsByOriginalToken[originalToken],
              record.transitionId == transitionId,
              record.availability == .temporarilyUnavailable,
              let unavailableSince = record.unavailableSince,
              now.timeIntervalSince(unavailableSince) >= staleInterval
        else {
            return nil
        }

        guard let removedRecord = removeNativeFullscreenRecord(originalToken: originalToken) else {
            return nil
        }
        if layoutReason(for: removedRecord.currentToken) == .nativeFullscreen {
            _ = restoreFromNativeState(for: removedRecord.currentToken)
        }
        return removeWindow(pid: removedRecord.currentToken.pid, windowId: removedRecord.currentToken.windowId)
    }

    @discardableResult
    func rememberFocus(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        let mode = windowMode(for: token) ?? .tiling
        let changed = setRememberedFocus(
            token,
            in: workspaceId,
            mode: mode,
            focus: &sessionState.focus
        )
        if changed {
            bumpRuntimeRevision(for: workspaceId, domains: .focus)
        }
        return changed
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
                withNiriViewportState(for: workspaceId) {
                    $0.selectedNodeId = nodeId
                }
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
        guard isRuntimeRevisionCurrent(
            patch.runtimeRevision,
            for: patch.workspaceId,
            domains: .layoutCommit
        ) else {
            return false
        }

        var changed = false

        if var viewportState = patch.viewportState {
            let currentState = niriViewportState(for: patch.workspaceId)
            let patchHasStaleSelection = patch.baseSelectionRevision
                .map { $0 < currentState.selectionRevision } ?? false
            if patchHasStaleSelection {
                viewportState.selectedNodeId = currentState.selectedNodeId
                viewportState.activeColumnIndex = currentState.activeColumnIndex
                viewportState.selectionProgress = currentState.selectionProgress
                viewportState.selectionRevision = currentState.selectionRevision
            }
            if viewportState.viewOffsetPixels.isGesture {
                if case .spring = currentState.viewOffsetPixels {
                    viewportState.viewOffsetPixels = currentState.viewOffsetPixels
                    viewportState.activeColumnIndex = currentState.activeColumnIndex
                }
            }
            updateNiriViewportState(viewportState, for: patch.workspaceId)
            changed = true
        }

        if let rememberedFocusToken = patch.rememberedFocusToken {
            if isRuntimeRevisionCurrent(
                patch.runtimeRevision,
                for: patch.workspaceId,
                domains: .focusCommit
            ) {
                changed = rememberFocus(rememberedFocusToken, in: patch.workspaceId) || changed
            }
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
                requestId: focus.pendingManagedFocus.requestId,
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
        preserveFocusedToken: Bool = false,
        preservePendingManagedFocus: Bool = false,
        target: WindowToken? = nil
    ) -> Bool {
        var changed = applyFocusReconcileEvent(
            .nonManagedFocusChanged(
                active: true,
                appFullscreen: appFullscreen,
                preserveFocusedToken: preserveFocusedToken,
                preservePendingManagedFocus: preservePendingManagedFocus,
                source: .workspaceManager
            )
        )
        changed = updateFocusSession(notify: false) { focus in
            guard focus.nonManagedFocusToken != target else { return false }
            focus.nonManagedFocusToken = target
            return true
        } || changed
        if changed {
            notifySessionStateChanged()
        }
        return changed
    }

    var nonManagedFocusToken: WindowToken? {
        sessionState.focus.nonManagedFocusToken
    }

    var suppressedFocusToken: WindowToken? {
        sessionState.focus.suppressedFocusToken
    }

    var renderableFocusToken: WindowToken? {
        if sessionState.focus.isNonManagedFocusActive {
            return sessionState.focus.nonManagedFocusToken
        }
        return sessionState.focus.focusedToken
    }

    func clearNonManagedFocusTarget(matching token: WindowToken? = nil, pid: pid_t? = nil) {
        _ = updateFocusSession(notify: true) { focus in
            guard let current = focus.nonManagedFocusToken else { return false }
            if let token, current != token { return false }
            if let pid, current.pid != pid { return false }
            focus.nonManagedFocusToken = nil
            return true
        }
    }

    func suppressFocusBorder(for token: WindowToken) {
        _ = updateFocusSession(notify: true) { focus in
            guard focus.suppressedFocusToken != token else { return false }
            focus.suppressedFocusToken = token
            return true
        }
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
        let previousRevisionWorkspaceId = focusRevisionWorkspaceId(for: sessionState.focus)
        let changed = mutate(&sessionState.focus)
        if changed {
            bumpFocusRevision(
                previousWorkspaceId: previousRevisionWorkspaceId,
                currentWorkspaceId: focusRevisionWorkspaceId(for: sessionState.focus)
            )
        }
        if changed, notify {
            notifySessionStateChanged()
        }
        return changed
    }

    private func focusRevisionWorkspaceId(for focus: SessionState.FocusSession) -> WorkspaceDescriptor.ID? {
        focus.pendingManagedFocus.workspaceId
            ?? focus.focusedToken.flatMap { world.entry(for: $0)?.workspaceId }
    }

    private func bumpFocusRevision(
        previousWorkspaceId: WorkspaceDescriptor.ID?,
        currentWorkspaceId: WorkspaceDescriptor.ID?
    ) {
        if let currentWorkspaceId {
            bumpRuntimeRevision(for: currentWorkspaceId, domains: .focus)
        }
        if let previousWorkspaceId, previousWorkspaceId != currentWorkspaceId {
            bumpRuntimeRevision(for: previousWorkspaceId, domains: .focus)
        }
        if previousWorkspaceId == nil, currentWorkspaceId == nil {
            bumpAllRuntimeRevisions(domains: .focus)
        }
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
        requestId: UInt64?,
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
        if focus.pendingManagedFocus.requestId != requestId {
            focus.pendingManagedFocus.requestId = requestId
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
            || focus.pendingManagedFocus.requestId != nil
        else {
            return false
        }
        focus.pendingManagedFocus = .init()
        return true
    }

    private func clearPendingManagedFocusRequest(
        matching token: WindowToken?,
        workspaceId: WorkspaceDescriptor.ID?,
        requestId: UInt64? = nil,
        focus: inout SessionState.FocusSession
    ) -> Bool {
        let request = focus.pendingManagedFocus
        let matchesHandle = token.map { request.token == $0 } ?? true
        let matchesWorkspace = workspaceId.map { request.workspaceId == $0 } ?? true
        let matchesRequest = requestId.map { request.requestId == $0 } ?? (request.requestId == nil)
        guard matchesHandle, matchesWorkspace, matchesRequest else { return false }
        guard request.token != nil
            || request.workspaceId != nil
            || request.monitorId != nil
            || request.requestId != nil
        else {
            return false
        }
        focus.pendingManagedFocus = .init()
        return true
    }

    func pendingManagedFocusMatches(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        requestId: UInt64
    ) -> Bool {
        let request = sessionState.focus.pendingManagedFocus
        return request.token == token
            && request.workspaceId == workspaceId
            && request.requestId == requestId
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
        let previousToken = sessionState.scratchpadToken
        guard previousToken != token else { return false }
        let previousWorkspaceId = previousToken.flatMap { world.entry(for: $0)?.workspaceId }
        let nextWorkspaceId = token.flatMap { world.entry(for: $0)?.workspaceId }
        if token != nil, nextWorkspaceId == nil {
            return false
        }
        sessionState.scratchpadToken = token
        let affectedWorkspaceIds = Set([previousWorkspaceId, nextWorkspaceId].compactMap { $0 })
        for workspaceId in affectedWorkspaceIds {
            bumpRuntimeRevision(for: workspaceId, domains: [.workspace, .layout, .focus])
        }
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
        _cachedSortedMonitors = nil
        _cachedTopologyProfile = nil
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

    private func invalidateSettingsProjectionCaches() {
        _cachedConfiguredWorkspaceNames = nil
        _cachedConfiguredWorkspaceNameSet = nil
        _cachedMonitorDescriptionByWorkspaceName = nil
    }

    private func invalidateWorkspaceProjectionCaches() {
        _cachedWorkspaceIdsByMonitor = nil
        _cachedVisibleWorkspaceIds = nil
        _cachedVisibleWorkspaceMap = nil
        _cachedMonitorIdByVisibleWorkspace = nil
    }

    private func sortedMonitors() -> [Monitor] {
        if let cached = _cachedSortedMonitors {
            return cached
        }
        let sorted = Monitor.sortedByPosition(monitors)
        _cachedSortedMonitors = sorted
        return sorted
    }

    private func currentTopologyProfile() -> TopologyProfile {
        if let cached = _cachedTopologyProfile {
            return cached
        }
        let profile = TopologyProfile(sortedMonitors: sortedMonitors())
        _cachedTopologyProfile = profile
        return profile
    }

    private func configuredWorkspaceNames() -> [String] {
        if let cached = _cachedConfiguredWorkspaceNames {
            return cached
        }
        let names = settings.configuredWorkspaceNames()
        _cachedConfiguredWorkspaceNames = names
        return names
    }

    private func configuredWorkspaceNameSet() -> Set<String> {
        if let cached = _cachedConfiguredWorkspaceNameSet {
            return cached
        }
        let names = Set(configuredWorkspaceNames())
        _cachedConfiguredWorkspaceNameSet = names
        return names
    }

    private func monitorDescriptionByWorkspaceName() -> [String: MonitorDescription] {
        if let cached = _cachedMonitorDescriptionByWorkspaceName {
            return cached
        }
        var descriptions: [String: MonitorDescription] = [:]
        for configuration in settings.workspaceConfigurations {
            descriptions[configuration.name] = configuration.monitorAssignment.toMonitorDescription()
        }
        _cachedMonitorDescriptionByWorkspaceName = descriptions
        return descriptions
    }

    private func monitorResolutionContext() -> MonitorResolutionContext {
        MonitorResolutionContext(
            monitors: monitors,
            sortedMonitors: sortedMonitors(),
            topologyProfile: currentTopologyProfile(),
            configuredWorkspaceNames: configuredWorkspaceNameSet(),
            monitorDescriptionByWorkspaceName: monitorDescriptionByWorkspaceName()
        )
    }

    private func monitorResolutionContext(for monitors: [Monitor]) -> MonitorResolutionContext {
        if monitors == self.monitors {
            return monitorResolutionContext()
        }
        let sortedMonitors = Monitor.sortedByPosition(monitors)
        return MonitorResolutionContext(
            monitors: monitors,
            sortedMonitors: sortedMonitors,
            topologyProfile: TopologyProfile(sortedMonitors: sortedMonitors),
            configuredWorkspaceNames: configuredWorkspaceNameSet(),
            monitorDescriptionByWorkspaceName: monitorDescriptionByWorkspaceName()
        )
    }

    private func workspaceIdsByMonitor() -> [Monitor.ID: [WorkspaceDescriptor.ID]] {
        if let cached = _cachedWorkspaceIdsByMonitor {
            return cached
        }

        let context = monitorResolutionContext()
        var workspaceIdsByMonitor: [Monitor.ID: [WorkspaceDescriptor.ID]] = [:]
        for workspace in sortedWorkspaces() {
            guard let monitorId = resolvedWorkspaceMonitorId(for: workspace.id, context: context) else { continue }
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
        guard configuredWorkspaceNameSet().contains(name) else { return nil }
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
        invalidateSettingsProjectionCaches()
        invalidateWorkspaceProjectionCaches()
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
        bumpAllRuntimeRevisions(domains: [.workspace, .layout])
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
        bumpAllRuntimeRevisions(domains: [.workspace, .layout])
        onGapsChanged?()
    }

    func invalidateLayoutRevision(for workspaceIds: Set<WorkspaceDescriptor.ID>) {
        for workspaceId in workspaceIds {
            bumpRuntimeRevision(for: workspaceId, domains: .layout)
        }
    }

    func monitorForWorkspace(_ workspaceId: WorkspaceDescriptor.ID) -> Monitor? {
        guard let monitorId = workspaceMonitorId(for: workspaceId) else { return nil }
        return monitor(byId: monitorId)
    }

    func monitor(for workspaceId: WorkspaceDescriptor.ID) -> Monitor? {
        monitorForWorkspace(workspaceId)
    }

    private func monitor(
        for workspaceId: WorkspaceDescriptor.ID,
        context: MonitorResolutionContext
    ) -> Monitor? {
        guard let monitorId = workspaceMonitorId(for: workspaceId, context: context) else { return nil }
        return monitor(byId: monitorId)
    }

    func monitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        monitorForWorkspace(workspaceId)?.id
    }

    private func monitorId(
        for workspaceId: WorkspaceDescriptor.ID,
        context: MonitorResolutionContext
    ) -> Monitor.ID? {
        monitor(for: workspaceId, context: context)?.id
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
        let token = WindowToken(pid: pid, windowId: windowId)
        if let originalToken = nativeFullscreenOriginalToken(for: token),
           var record = nativeFullscreenRecordsByOriginalToken[originalToken],
           record.currentToken == token,
           record.workspaceId != workspace
        {
            record.workspaceId = workspace
            upsertNativeFullscreenRecord(record)
        }
        recordReconcileEvent(
            .windowAdmitted(
                token: token,
                workspaceId: workspace,
                monitorId: monitorId(for: workspace),
                mode: mode,
                axRef: ax,
                ruleEffects: ruleEffects,
                managedReplacementMetadata: managedReplacementMetadata,
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
        guard let existingEntry = world.entry(for: oldToken),
              oldToken == newToken || world.entry(for: newToken) == nil
        else {
            return nil
        }

        if let originalToken = nativeFullscreenOriginalToken(for: oldToken),
           var record = nativeFullscreenRecordsByOriginalToken[originalToken]
        {
            record.currentToken = newToken
            record.workspaceId = existingEntry.workspaceId
            upsertNativeFullscreenRecord(record)
        }

        recordReconcileEvent(
            .windowRekeyed(
                from: oldToken,
                to: newToken,
                workspaceId: existingEntry.workspaceId,
                monitorId: monitorId(for: existingEntry.workspaceId),
                reason: managedReplacementMetadata == nil ? .manualRekey : .managedReplacement,
                newAXRef: newAXRef,
                managedReplacementMetadata: managedReplacementMetadata,
                source: .workspaceManager
            )
        )

        let focusChanged = updateFocusSession(notify: false) { focus in
            var changed = self.replaceRememberedFocus(from: oldToken, to: newToken, focus: &focus)
            if focus.nonManagedFocusToken == oldToken {
                focus.nonManagedFocusToken = newToken
                changed = true
            }
            if focus.suppressedFocusToken == oldToken {
                focus.suppressedFocusToken = newToken
                changed = true
            }
            return changed
        }

        let scratchpadChanged = sessionState.scratchpadToken == oldToken
        if scratchpadChanged {
            _ = updateScratchpadToken(newToken, notify: false)
        }

        if focusChanged || scratchpadChanged {
            notifySessionStateChanged()
        }

        return world.entry(for: newToken)
    }

    func entries(in workspace: WorkspaceDescriptor.ID) -> [WindowModel.Entry] {
        world.windows(in: workspace)
    }

    func tiledEntries(in workspace: WorkspaceDescriptor.ID) -> [WindowModel.Entry] {
        world.windows(in: workspace, mode: .tiling)
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
        world.windows(in: workspace, mode: .floating)
    }

    private func barVisibleFloatingEntries(in workspace: WorkspaceDescriptor.ID) -> [WindowModel.Entry] {
        floatingEntries(in: workspace).filter {
            !isScratchpadToken($0.token) && hiddenState(for: $0.token)?.isScratchpad != true
        }
    }

    func handle(for token: WindowToken) -> WindowHandle? {
        world.handle(for: token)
    }

    func entry(for token: WindowToken) -> WindowModel.Entry? {
        world.entry(for: token)
    }

    func entry(for handle: WindowHandle) -> WindowModel.Entry? {
        world.entry(for: handle)
    }

    func entry(forPid pid: pid_t, windowId: Int) -> WindowModel.Entry? {
        world.entry(forPid: pid, windowId: windowId)
    }

    func entries(forPid pid: pid_t) -> [WindowModel.Entry] {
        world.entries(forPid: pid)
    }

    func entry(forWindowId windowId: Int) -> WindowModel.Entry? {
        world.entry(forWindowId: windowId)
    }

    func entry(forWindowId windowId: Int, inVisibleWorkspaces: Bool) -> WindowModel.Entry? {
        guard inVisibleWorkspaces else {
            return world.entry(forWindowId: windowId)
        }
        return world.entry(forWindowId: windowId, inVisibleWorkspaces: visibleWorkspaceIds())
    }

    func allEntries() -> [WindowModel.Entry] {
        world.allEntries()
    }

    func allTiledEntries() -> [WindowModel.Entry] {
        world.allEntries(mode: .tiling)
    }

    func allFloatingEntries() -> [WindowModel.Entry] {
        world.allEntries(mode: .floating)
    }

    func windowMode(for token: WindowToken) -> TrackedWindowMode? {
        world.mode(for: token)
    }

    func lifecyclePhase(for token: WindowToken) -> WindowLifecyclePhase? {
        world.lifecyclePhase(for: token)
    }

    func observedState(for token: WindowToken) -> ObservedWindowState? {
        world.observedState(for: token)
    }

    func desiredState(for token: WindowToken) -> DesiredWindowState? {
        world.desiredState(for: token)
    }

    func restoreIntent(for token: WindowToken) -> RestoreIntent? {
        world.restoreIntent(for: token)
    }

    func setNiriRestorePlacements(_ placements: [WindowToken: PersistedNiriPlacement]) {
        let changedPlacements = placements.filter { token, placement in
            guard let entry = world.entry(for: token), entry.mode == .tiling else { return false }
            return StateReducer.restoreIntent(for: entry, monitors: monitors).niriPlacement != placement
        }
        guard !changedPlacements.isEmpty else { return }
        recordReconcileEvent(
            .niriPlacementsResolved(
                placements: changedPlacements,
                source: .workspaceManager
            )
        )
    }

    func replacementCorrelation(for token: WindowToken) -> ReplacementCorrelation? {
        world.replacementCorrelation(for: token)
    }

    func managedReplacementMetadata(for token: WindowToken) -> ManagedReplacementMetadata? {
        world.managedReplacementMetadata(for: token)
    }

    @discardableResult
    func setManagedReplacementMetadata(
        _ metadata: ManagedReplacementMetadata?,
        for token: WindowToken
    ) -> Bool {
        guard let entry = world.entry(for: token) else {
            return false
        }
        guard world.managedReplacementMetadata(for: token) != metadata else {
            return false
        }
        recordReconcileEvent(
            .managedReplacementMetadataChanged(
                token: token,
                workspaceId: entry.workspaceId,
                monitorId: monitorId(for: entry.workspaceId),
                metadata: metadata,
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
        guard var metadata = world.managedReplacementMetadata(for: token) else {
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
        guard var metadata = world.managedReplacementMetadata(for: token) else {
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

        let workspaceId = entry.workspaceId
        recordReconcileEvent(
            .windowModeChanged(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId(for: workspaceId),
                mode: mode,
                source: .workspaceManager
            )
        )
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
        return true
    }

    func floatingState(for token: WindowToken) -> WindowModel.FloatingState? {
        world.floatingState(for: token)
    }

    func setFloatingState(_ state: WindowModel.FloatingState?, for token: WindowToken) {
        guard let entry = world.entry(for: token) else { return }
        guard world.floatingState(for: token) != state else { return }
        recordReconcileEvent(
            .floatingStateChanged(
                token: token,
                workspaceId: entry.workspaceId,
                state: state,
                source: .workspaceManager
            )
        )
    }

    func manualLayoutOverride(for token: WindowToken) -> ManualWindowOverride? {
        world.manualLayoutOverride(for: token)
    }

    func setManualLayoutOverride(_ override: ManualWindowOverride?, for token: WindowToken) {
        guard let entry = world.entry(for: token) else { return }
        guard world.manualLayoutOverride(for: token) != override else { return }
        recordReconcileEvent(
            .manualLayoutOverrideChanged(
                token: token,
                workspaceId: entry.workspaceId,
                layoutOverride: override,
                source: .workspaceManager
            )
        )
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

        let state = WindowModel.FloatingState(
            lastFrame: frame,
            normalizedOrigin: normalizedOrigin,
            referenceMonitorId: resolvedReferenceMonitor?.id,
            restoreToFloating: restoreToFloating
        )
        guard world.floatingState(for: token) != state else { return }

        recordReconcileEvent(
            .floatingGeometryUpdated(
                token: token,
                workspaceId: entry.workspaceId,
                referenceMonitorId: resolvedReferenceMonitor?.id,
                frame: frame,
                normalizedOrigin: normalizedOrigin,
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

    @discardableResult
    func removeMissing(
        keys activeKeys: Set<WindowModel.WindowKey>,
        requiredConsecutiveMisses: Int = 1
    ) -> [WindowModel.Entry] {
        let confirmedMissingKeys = world.confirmedMissingKeys(
            keys: activeKeys,
            requiredConsecutiveMisses: requiredConsecutiveMisses
        )
        var removedEntries: [WindowModel.Entry] = []
        removedEntries.reserveCapacity(confirmedMissingKeys.count)
        for key in confirmedMissingKeys {
            guard let entry = world.entry(for: key) else { continue }
            removedEntries.append(removeTrackedWindow(entry))
        }
        if !removedEntries.isEmpty {
            schedulePersistedWindowRestoreCatalogSave()
        }
        return removedEntries
    }

    @discardableResult
    func removeWindow(pid: pid_t, windowId: Int) -> WindowModel.Entry? {
        guard let entry = world.entry(forPid: pid, windowId: windowId) else { return nil }
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
        return entry
    }

    func setWorkspace(for token: WindowToken, to workspace: WorkspaceDescriptor.ID) {
        let previousWorkspace = world.workspace(for: token)
        guard previousWorkspace != workspace else { return }
        if let originalToken = nativeFullscreenOriginalToken(for: token),
           var record = nativeFullscreenRecordsByOriginalToken[originalToken],
           record.currentToken == token,
           record.workspaceId != workspace
        {
            record.workspaceId = workspace
            upsertNativeFullscreenRecord(record)
        }
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
        world.workspace(for: token)
    }

    func isHiddenInCorner(_ token: WindowToken) -> Bool {
        world.isHiddenInCorner(token)
    }

    func setHiddenState(_ state: WindowModel.HiddenState?, for token: WindowToken) {
        guard world.hiddenState(for: token) != state else { return }
        guard let workspaceId = workspace(for: token) else { return }
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

    func hiddenState(for token: WindowToken) -> WindowModel.HiddenState? {
        world.hiddenState(for: token)
    }

    func layoutReason(for token: WindowToken) -> LayoutReason {
        world.layoutReason(for: token)
    }

    func isNativeFullscreenSuspended(_ token: WindowToken) -> Bool {
        world.isNativeFullscreenSuspended(token)
    }

    func setLayoutReason(_ reason: LayoutReason, for token: WindowToken) {
        guard world.layoutReason(for: token) != reason else { return }
        guard let workspaceId = workspace(for: token) else { return }
        recordReconcileEvent(
            .nativeFullscreenTransition(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId(for: workspaceId),
                change: .suspended(reason),
                source: .workspaceManager
            )
        )
    }

    func restoreFromNativeState(for token: WindowToken) -> ParentKind? {
        guard let entry = world.entry(for: token),
              entry.layoutReason != .standard,
              let workspaceId = workspace(for: token)
        else {
            return nil
        }
        let restoredParentKind = entry.prevParentKind
        recordReconcileEvent(
            .nativeFullscreenTransition(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId(for: workspaceId),
                change: .restored,
                source: .workspaceManager
            )
        )
        return restoredParentKind
    }

    func isNativeFullscreenTemporarilyUnavailable(_ token: WindowToken) -> Bool {
        nativeFullscreenRecord(for: token)?.availability == .temporarilyUnavailable
    }

    func showsNativeFullscreenPlaceholder(for token: WindowToken) -> Bool {
        guard layoutReason(for: token) == .nativeFullscreen else { return false }
        guard let record = nativeFullscreenRecord(for: token) else { return false }
        guard record.currentToken == token else { return false }
        switch record.availability {
        case .present:
            return record.transition != .enterRequested
        case .temporarilyUnavailable:
            return true
        }
    }

    private func nativeFullscreenOriginalToken(for token: WindowToken) -> WindowToken? {
        if nativeFullscreenRecordsByOriginalToken[token] != nil {
            return token
        }
        return nativeFullscreenOriginalTokenByCurrentToken[token]
    }

    @discardableResult
    private func upsertNativeFullscreenRecord(_ incomingRecord: NativeFullscreenRecord) -> NativeFullscreenRecord {
        var record = incomingRecord
        if let previous = nativeFullscreenRecordsByOriginalToken[record.originalToken] {
            nativeFullscreenOriginalTokenByCurrentToken.removeValue(forKey: previous.currentToken)
            if shouldMintNativeFullscreenTransitionId(previous: previous, next: record) {
                record.transitionId = mintNativeFullscreenTransitionId()
            } else {
                record.transitionId = previous.transitionId
            }
            if previous != record {
                bumpRuntimeRevision(for: previous.workspaceId, domains: [.workspace, .layout, .focus, .fullscreen])
                if previous.workspaceId != record.workspaceId {
                    bumpRuntimeRevision(for: record.workspaceId, domains: [.workspace, .layout, .focus, .fullscreen])
                }
            }
        } else {
            record.transitionId = record.transitionId == 0
                ? mintNativeFullscreenTransitionId()
                : record.transitionId
            bumpRuntimeRevision(for: record.workspaceId, domains: [.workspace, .layout, .focus, .fullscreen])
        }
        nativeFullscreenRecordsByOriginalToken[record.originalToken] = record
        nativeFullscreenOriginalTokenByCurrentToken[record.currentToken] = record.originalToken
        return record
    }

    private func shouldMintNativeFullscreenTransitionId(
        previous: NativeFullscreenRecord,
        next: NativeFullscreenRecord
    ) -> Bool {
        if previous.availability == .temporarilyUnavailable,
           next.availability == .temporarilyUnavailable
        {
            return previous.exitRequestedByCommand != next.exitRequestedByCommand
                || previous.transition != next.transition
        }
        return previous.currentToken != next.currentToken
            || previous.workspaceId != next.workspaceId
            || previous.exitRequestedByCommand != next.exitRequestedByCommand
            || previous.transition != next.transition
            || previous.availability != next.availability
    }

    private func mintNativeFullscreenTransitionId() -> UInt64 {
        let id = nextNativeFullscreenTransitionId
        nextNativeFullscreenTransitionId &+= 1
        return id
    }

    @discardableResult
    private func removeNativeFullscreenRecord(originalToken: WindowToken) -> NativeFullscreenRecord? {
        guard let record = nativeFullscreenRecordsByOriginalToken.removeValue(forKey: originalToken) else {
            return nil
        }
        nativeFullscreenOriginalTokenByCurrentToken.removeValue(forKey: record.currentToken)
        bumpRuntimeRevision(for: record.workspaceId, domains: [.workspace, .layout, .focus, .fullscreen])
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
        world.cachedConstraints(for: token, maxAge: maxAge)
    }

    func setCachedConstraints(_ constraints: WindowSizeConstraints, for token: WindowToken) {
        guard world.entry(for: token) != nil else { return }
        let normalized = constraints.normalized()
        world.setCachedConstraints(normalized, for: token)
    }

    @discardableResult
    func setObservedMinSize(_ size: CGSize, for token: WindowToken) -> Bool {
        world.setObservedMinSize(size, for: token)
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

        bumpRuntimeRevision(for: workspace1Id, domains: [.workspace, .layout, .focus])
        bumpRuntimeRevision(for: workspace2Id, domains: [.workspace, .layout, .focus])
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

    func updateNiriViewportState(
        _ state: ViewportState,
        for workspaceId: WorkspaceDescriptor.ID
    ) {
        var workspaceSession = sessionState.workspaceSessions[workspaceId] ?? SessionState.WorkspaceSession()
        let currentState = workspaceSession.niriViewportState
        var nextState = state
        if let currentState {
            if nextState.selectedNodeId != currentState.selectedNodeId {
                nextState.selectionRevision = max(nextState.selectionRevision, currentState.selectionRevision &+ 1)
            } else {
                nextState.selectionRevision = max(nextState.selectionRevision, currentState.selectionRevision)
            }
        } else if nextState.selectedNodeId != nil {
            nextState.selectionRevision = max(nextState.selectionRevision, 1)
        }
        workspaceSession.niriViewportState = nextState
        sessionState.workspaceSessions[workspaceId] = workspaceSession
        if shouldBumpNiriViewportRevision(previous: currentState, next: nextState) {
            bumpRuntimeRevision(for: workspaceId, domains: [.workspace, .layout])
        }
    }

    private func shouldBumpNiriViewportRevision(
        previous: ViewportState?,
        next: ViewportState
    ) -> Bool {
        guard let previous else {
            return next.selectedNodeId != nil || !next.viewOffsetPixels.isAnimating
        }
        if previous.selectedNodeId != next.selectedNodeId {
            return true
        }
        if previous.activeColumnIndex != next.activeColumnIndex {
            return true
        }
        if previous.viewOffsetPixels.target() != next.viewOffsetPixels.target() {
            return true
        }
        if previous.viewOffsetToRestore != next.viewOffsetToRestore {
            return true
        }
        if previous.activatePrevColumnOnRemoval != next.activatePrevColumnOnRemoval {
            return true
        }
        return false
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
        let configured = configuredWorkspaceNameSet()
        var toRemove: [WorkspaceDescriptor.ID] = []
        for (id, workspace) in workspacesById {
            if configured.contains(workspace.name) {
                continue
            }
            if focusedWorkspaceId == id {
                continue
            }
            if !world.windows(in: id).isEmpty {
                continue
            }
            toRemove.append(id)
        }

        removeWorkspaces(toRemove)
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

        let sorted = sortedMonitors()
        guard let currentIdx = sorted.firstIndex(where: { $0.id == monitorId }) else { return nil }

        let prevIdx = currentIdx > 0 ? currentIdx - 1 : sorted.count - 1
        return sorted[prevIdx]
    }

    func nextMonitor(from monitorId: Monitor.ID) -> Monitor? {
        guard monitors.count > 1 else { return nil }

        let sorted = sortedMonitors()
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
            case .left,
                 .right:
                return MonitorSelectionRank(
                    primary: abs(delta.dx),
                    secondary: abs(delta.dy),
                    distance: candidate.frame.center.distanceSquared(to: current.frame.center)
                )
            case .up,
                 .down:
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

    private func synchronizeConfiguredWorkspaces() {
        let configuredNames = configuredWorkspaceNames()
        let configuredSet = Set(configuredNames)

        for name in configuredNames {
            _ = workspaceId(for: name, createIfMissing: true)
        }

        let toRemove = workspacesById.compactMap { workspaceId, workspace -> WorkspaceDescriptor.ID? in
            guard !configuredSet.contains(workspace.name) else { return nil }
            guard world.windows(in: workspaceId).isEmpty else { return nil }
            return workspaceId
        }
        removeWorkspaces(toRemove)
    }

    private func removeWorkspaces(_ ids: [WorkspaceDescriptor.ID]) {
        guard !ids.isEmpty else { return }

        let toRemove = Set(ids)
        for id in toRemove {
            bumpRuntimeRevision(for: id, domains: [.workspace, .layout, .focus])
        }
        for id in ids {
            workspacesById.removeValue(forKey: id)
            sessionState.workspaceSessions.removeValue(forKey: id)
            sessionState.focus.lastTiledFocusedByWorkspace.removeValue(forKey: id)
            sessionState.focus.lastFloatingFocusedByWorkspace.removeValue(forKey: id)
            workspaceRevisions.removeValue(forKey: id)
            layoutRevisions.removeValue(forKey: id)
            focusRevisions.removeValue(forKey: id)
            fullscreenRevisions.removeValue(forKey: id)
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
        let context = monitorResolutionContext()

        let sortedCacheEntries = disconnectedVisibleWorkspaceCache.sorted { lhs, rhs in
            restoreKeySortKey(lhs.key) < restoreKeySortKey(rhs.key)
        }

        var reconnectAssignments: [Monitor.ID: WorkspaceDescriptor.ID] = [:]
        for (_, workspaceId) in sortedCacheEntries {
            guard descriptor(for: workspaceId) != nil else { continue }
            guard let homeMonitor = homeMonitor(for: workspaceId, context: context) else { continue }
            guard reconnectAssignments[homeMonitor.id] == nil else { continue }
            reconnectAssignments[homeMonitor.id] = workspaceId
        }

        for monitor in context.sortedMonitors {
            guard let workspaceId = reconnectAssignments[monitor.id] else { continue }
            _ = setActiveWorkspaceInternal(
                workspaceId,
                on: monitor.id,
                anchorPoint: monitor.workspaceAnchorPoint,
                updateInteractionMonitor: false,
                notify: false,
                context: context
            )
        }
    }

    private func applyDisconnectedVisibleWorkspaceMigrations(
        _ migrations: [DisconnectedVisibleWorkspaceMigration]
    ) {
        guard !migrations.isEmpty else { return }
        let context = monitorResolutionContext()

        var winnerByFallbackMonitorId: [Monitor.ID: DisconnectedVisibleWorkspaceMigration] = [:]
        for migration in migrations {
            guard descriptor(for: migration.workspaceId) != nil else { continue }
            guard let fallbackMonitor = effectiveMonitor(for: migration.workspaceId, context: context) else { continue }
            guard winnerByFallbackMonitorId[fallbackMonitor.id] == nil else { continue }
            winnerByFallbackMonitorId[fallbackMonitor.id] = migration
        }

        for monitor in context.sortedMonitors {
            guard let migration = winnerByFallbackMonitorId[monitor.id] else { continue }
            _ = setActiveWorkspaceInternal(
                migration.workspaceId,
                on: monitor.id,
                anchorPoint: monitor.workspaceAnchorPoint,
                updateInteractionMonitor: false,
                notify: false,
                context: context
            )
        }
    }

    private func pruneRestoredDisconnectedVisibleWorkspaces() {
        let context = monitorResolutionContext()
        disconnectedVisibleWorkspaceCache = disconnectedVisibleWorkspaceCache.filter { _, workspaceId in
            guard descriptor(for: workspaceId) != nil else { return false }
            guard let homeMonitorId = homeMonitorId(for: workspaceId, context: context) else { return true }
            return visibleWorkspaceId(on: homeMonitorId) != workspaceId
        }
    }

    private func reconcileConfiguredVisibleWorkspaces(notify: Bool = true) {
        var changed = false
        let context = monitorResolutionContext()

        for monitor in context.sortedMonitors {
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
                notify: false,
                context: context
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

        let context = monitorResolutionContext()
        var restoredWorkspaces: Set<WorkspaceDescriptor.ID> = []

        for monitor in context.sortedMonitors {
            guard let workspaceId = assignments[monitor.id] else { continue }
            guard workspaceMonitorId(for: workspaceId, context: context) == monitor.id else { continue }
            guard restoredWorkspaces.insert(workspaceId).inserted else { continue }
            _ = setActiveWorkspaceInternal(
                workspaceId,
                on: monitor.id,
                anchorPoint: monitor.workspaceAnchorPoint,
                updateInteractionMonitor: false,
                notify: false,
                context: context
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
        let context = monitorResolutionContext()
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

        for newMonitor in context.sortedMonitors {
            if let existingWorkspaceId = restoredAssignments[newMonitor.id],
               workspaceMonitorId(for: existingWorkspaceId, context: context) == newMonitor.id,
               setActiveWorkspaceInternal(
                   existingWorkspaceId,
                   on: newMonitor.id,
                   anchorPoint: newMonitor.workspaceAnchorPoint,
                   notify: false,
                   context: context
               )
            {
                continue
            }
            if let defaultWorkspaceId = defaultVisibleWorkspaceId(on: newMonitor.id) {
                _ = setActiveWorkspaceInternal(
                    defaultWorkspaceId,
                    on: newMonitor.id,
                    anchorPoint: newMonitor.workspaceAnchorPoint,
                    notify: false,
                    context: context
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
        resolvedWorkspaceMonitorId(for: workspaceId, context: monitorResolutionContext())
    }

    private func resolvedWorkspaceMonitorId(
        for workspaceId: WorkspaceDescriptor.ID,
        context: MonitorResolutionContext
    ) -> Monitor.ID? {
        guard let workspace = descriptor(for: workspaceId) else { return nil }
        if context.configuredWorkspaceNames.contains(workspace.name) {
            return effectiveMonitor(for: workspaceId, context: context)?.id
        }
        return monitorIdShowingWorkspace(workspaceId)
    }

    private func workspaceMonitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        resolvedWorkspaceMonitorId(for: workspaceId)
    }

    private func workspaceMonitorId(
        for workspaceId: WorkspaceDescriptor.ID,
        context: MonitorResolutionContext
    ) -> Monitor.ID? {
        resolvedWorkspaceMonitorId(for: workspaceId, context: context)
    }

    private func configuredMonitorDescription(
        for workspaceName: String,
        context: MonitorResolutionContext
    ) -> MonitorDescription? {
        context.monitorDescriptionByWorkspaceName[workspaceName]
    }

    private func homeMonitor(for workspaceId: WorkspaceDescriptor.ID) -> Monitor? {
        homeMonitor(for: workspaceId, context: monitorResolutionContext())
    }

    private func homeMonitor(
        for workspaceId: WorkspaceDescriptor.ID,
        context: MonitorResolutionContext
    ) -> Monitor? {
        guard let workspace = descriptor(for: workspaceId) else { return nil }
        guard let description = configuredMonitorDescription(for: workspace.name, context: context) else { return nil }
        return description.resolveMonitor(sortedMonitors: context.sortedMonitors)
    }

    private func homeMonitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        homeMonitorId(for: workspaceId, context: monitorResolutionContext())
    }

    private func homeMonitorId(
        for workspaceId: WorkspaceDescriptor.ID,
        context: MonitorResolutionContext
    ) -> Monitor.ID? {
        homeMonitor(for: workspaceId, context: context)?.id
    }

    private func effectiveMonitor(for workspaceId: WorkspaceDescriptor.ID) -> Monitor? {
        effectiveMonitor(for: workspaceId, context: monitorResolutionContext())
    }

    private func effectiveMonitor(
        for workspaceId: WorkspaceDescriptor.ID,
        context: MonitorResolutionContext
    ) -> Monitor? {
        if let home = homeMonitor(for: workspaceId, context: context) {
            return home
        }

        guard !context.sortedMonitors.isEmpty else { return nil }
        guard let workspace = descriptor(for: workspaceId) else { return nil }

        let anchorPoint = workspace.assignedMonitorPoint
            ?? monitorIdShowingWorkspace(workspaceId).flatMap { monitor(byId: $0)?.workspaceAnchorPoint }
        guard let anchorPoint else { return context.sortedMonitors.first }

        return context.sortedMonitors.min { lhs, rhs in
            let lhsDistance = lhs.workspaceAnchorPoint.distanceSquared(to: anchorPoint)
            let rhsDistance = rhs.workspaceAnchorPoint.distanceSquared(to: anchorPoint)
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }
            return monitorSortKey(lhs) < monitorSortKey(rhs)
        }
    }

    private func isValidAssignment(workspaceId: WorkspaceDescriptor.ID, monitorId: Monitor.ID) -> Bool {
        isValidAssignment(workspaceId: workspaceId, monitorId: monitorId, context: monitorResolutionContext())
    }

    private func isValidAssignment(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID,
        context: MonitorResolutionContext
    ) -> Bool {
        guard let workspace = descriptor(for: workspaceId) else { return false }
        guard context.configuredWorkspaceNames.contains(workspace.name) else { return false }
        return effectiveMonitor(for: workspaceId, context: context)?.id == monitorId
    }

    private func setActiveWorkspaceInternal(
        _ workspaceId: WorkspaceDescriptor.ID,
        on monitorId: Monitor.ID,
        anchorPoint: CGPoint? = nil,
        updateInteractionMonitor: Bool = false,
        notify: Bool = true,
        context: MonitorResolutionContext? = nil
    ) -> Bool {
        let resolutionContext = context ?? monitorResolutionContext()
        guard isValidAssignment(workspaceId: workspaceId, monitorId: monitorId, context: resolutionContext) else {
            return false
        }
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
            if workspaceVisibilityChanged || interactionChanged {
                bumpRuntimeRevision(for: workspaceId, domains: [.workspace, .layout, .focus])
                if let previousWorkspaceOnMonitor {
                    bumpRuntimeRevision(for: previousWorkspaceOnMonitor, domains: [.workspace, .layout, .focus])
                }
            }
            if notify, workspaceVisibilityChanged || interactionChanged {
                notifySessionStateChanged()
            }
        } else if workspaceVisibilityChanged {
            bumpRuntimeRevision(for: workspaceId, domains: [.workspace, .layout, .focus])
            if let previousWorkspaceOnMonitor {
                bumpRuntimeRevision(for: previousWorkspaceOnMonitor, domains: [.workspace, .layout, .focus])
            }
            if notify {
                notifySessionStateChanged()
            }
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
            bumpRuntimeRevision(for: workspaceId, domains: [.workspace, .layout])
            schedulePersistedWindowRestoreCatalogSave()
        }
    }

    private func createWorkspace(named name: String) -> WorkspaceDescriptor.ID? {
        guard let rawID = WorkspaceIDPolicy.normalizeRawID(name) else { return nil }
        guard configuredWorkspaceNameSet().contains(rawID) else { return nil }
        let workspace = WorkspaceDescriptor(name: rawID)
        workspacesById[workspace.id] = workspace
        workspaceIdByName[workspace.name] = workspace.id
        _cachedSortedWorkspaces = nil
        invalidateWorkspaceProjectionCaches()
        bumpRuntimeRevision(for: workspace.id, domains: [.workspace, .layout, .focus])
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
        let previousWorkspaceId = sessionState.interactionMonitorId
            .flatMap { currentActiveWorkspace(on: $0)?.id }
        let nextWorkspaceId = monitorId
            .flatMap { currentActiveWorkspace(on: $0)?.id }
        if preservePrevious,
           let currentMonitorId = sessionState.interactionMonitorId,
           currentMonitorId != monitorId
        {
            sessionState.previousInteractionMonitorId = currentMonitorId
        }
        sessionState.interactionMonitorId = monitorId
        bumpFocusRevision(
            previousWorkspaceId: previousWorkspaceId,
            currentWorkspaceId: nextWorkspaceId
        )
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

    private func bumpRuntimeRevision(for event: WMEvent) {
        switch event {
        case let .windowAdmitted(_, workspaceId, _, _, _, _, _, _),
             let .windowModeChanged(_, workspaceId, _, _, _),
             let .hiddenStateChanged(_, workspaceId, _, _, _),
             let .managedReplacementMetadataChanged(_, workspaceId, _, _, _):
            bumpRuntimeRevision(for: workspaceId, domains: [.workspace, .layout, .focus])

        case let .floatingGeometryUpdated(_, workspaceId, _, _, _, _, _):
            bumpRuntimeRevision(for: workspaceId, domains: [.workspace, .layout])

        case let .floatingStateChanged(_, workspaceId, _, _),
             let .manualLayoutOverrideChanged(_, workspaceId, _, _):
            bumpRuntimeRevision(for: workspaceId, domains: .layout)

        case .niriPlacementsResolved:
            break

        case let .windowRekeyed(_, _, workspaceId, _, _, _, _, _):
            bumpRuntimeRevision(for: workspaceId, domains: [.workspace, .layout, .focus])

        case let .workspaceAssigned(_, fromWorkspaceId, toWorkspaceId, _, _):
            bumpRuntimeRevision(for: toWorkspaceId, domains: [.workspace, .layout, .focus])
            if let fromWorkspaceId {
                bumpRuntimeRevision(for: fromWorkspaceId, domains: [.workspace, .layout, .focus])
            }

        case let .windowRemoved(token, workspaceId, _):
            bumpRuntimeRevision(
                for: workspaceId ?? world.entry(for: token)?.workspaceId,
                domains: [.workspace, .layout, .focus, .fullscreen]
            )

        case let .nativeFullscreenTransition(_, workspaceId, _, _, _):
            bumpRuntimeRevision(for: workspaceId, domains: [.workspace, .layout, .focus, .fullscreen])

        case let .managedFocusRequested(_, workspaceId, _, _, _),
             let .managedFocusConfirmed(_, workspaceId, _, _, _, _):
            bumpRuntimeRevision(for: workspaceId, domains: .focus)

        case let .managedFocusCancelled(token, workspaceId, _, _):
            bumpRuntimeRevision(
                for: workspaceId ?? token.flatMap { world.entry(for: $0)?.workspaceId },
                domains: .focus
            )

        case .focusLeaseChanged,
             .nonManagedFocusChanged:
            bumpAllRuntimeRevisions(domains: .focus)

        case .topologyChanged,
             .activeSpaceChanged,
             .systemSleep,
             .systemWake:
            bumpAllRuntimeRevisions(domains: [.workspace, .layout, .focus, .fullscreen])
        }
    }

    private func bumpRuntimeRevision(
        for workspaceId: WorkspaceDescriptor.ID?,
        domains: RuntimeRevisionDomain
    ) {
        runtimeRevisionSerial &+= 1
        guard let workspaceId else {
            for workspaceId in allRuntimeRevisionWorkspaceIds() {
                bumpRuntimeRevisionDomains(for: workspaceId, domains: domains)
            }
            onRuntimeRevisionChanged?(nil, domains)
            return
        }
        bumpRuntimeRevisionDomains(for: workspaceId, domains: domains)
        onRuntimeRevisionChanged?(workspaceId, domains)
    }

    private func bumpRuntimeRevisionDomains(
        for workspaceId: WorkspaceDescriptor.ID,
        domains: RuntimeRevisionDomain
    ) {
        if domains.contains(.workspace) {
            globalWorkspaceRevision &+= 1
            workspaceRevisions[workspaceId, default: 0] &+= 1
        }
        if domains.contains(.layout) {
            globalLayoutRevision &+= 1
            layoutRevisions[workspaceId, default: 0] &+= 1
        }
        if domains.contains(.focus) {
            globalFocusRevision &+= 1
            focusRevisions[workspaceId, default: 0] &+= 1
        }
        if domains.contains(.fullscreen) {
            globalFullscreenRevision &+= 1
            fullscreenRevisions[workspaceId, default: 0] &+= 1
        }
    }

    private func bumpAllRuntimeRevisions(domains: RuntimeRevisionDomain) {
        runtimeRevisionSerial &+= 1
        for workspaceId in allRuntimeRevisionWorkspaceIds() {
            bumpRuntimeRevisionDomains(for: workspaceId, domains: domains)
        }
        onRuntimeRevisionChanged?(nil, domains)
    }

    private func allRuntimeRevisionWorkspaceIds() -> Set<WorkspaceDescriptor.ID> {
        Set(workspacesById.keys)
            .union(world.allEntries().map(\.workspaceId))
            .union(workspaceRevisions.keys)
            .union(layoutRevisions.keys)
            .union(focusRevisions.keys)
            .union(fullscreenRevisions.keys)
    }
}

private extension CGPoint {
    func distanceSquared(to point: CGPoint) -> CGFloat {
        let dx = x - point.x
        let dy = y - point.y
        return dx * dx + dy * dy
    }
}
