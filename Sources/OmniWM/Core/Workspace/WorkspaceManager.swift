// SPDX-License-Identifier: GPL-2.0-only
// swiftlint:disable file_length type_body_length
import AppKit
import COmniWMKernels
import Foundation
import OSLog
import OmniWMIPC

private let nativeFullscreenWriteLog = Logger(
    subsystem: "com.omniwm.core",
    category: "WorkspaceManager.NativeFullscreen"
)

private let monitorRebindPolicyLog = Logger(
    subsystem: "com.omniwm.core",
    category: "WorkspaceManager.MonitorRebindPolicy"
)

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

struct WorkspaceFocusResolutionPlan: Equatable {
    enum FocusClearAction: Equatable {
        case none
        case pending
        case pendingAndConfirmed
    }

    let resolvedFocusToken: WindowToken?
    let resolvedFocusLogicalId: LogicalWindowId?
    let focusClearAction: FocusClearAction
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

        let logicalId: LogicalWindowId
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
    private let logicalWindowRegistryStorage = LogicalWindowRegistry()

    var logicalWindowRegistry: any LogicalWindowRegistryReading {
        logicalWindowRegistryStorage
    }
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

    // Monitor lookup cache extracted into `MonitorIndexCache` (ExecPlan 01,
    // slice WGT-SS-02). Rebuilt whenever the canonical `monitors` array
    // changes; queried via the `monitor(byId:)`, `monitor(named:)`, and
    // `monitors(named:)` forwarders below.
    private var monitorIndex = MonitorIndexCache()
    private var cachedTopologyProfile: TopologyProfile

    var currentTopologyProfile: TopologyProfile { cachedTopologyProfile }

    func sessionStateSnapshot() -> WorkspaceSessionState { sessionState }
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

    // Gap policy (inner gap + outer-gap insets) was extracted into
    // `GapPolicy` (ExecPlan 01, slice WGT-SS-01). External callers continue
    // to read `manager.gaps` and `manager.outerGaps` via the forwarders
    // below; mutators (`setGaps`, `setOuterGaps`) delegate to gapPolicy and
    // fan out the existing `onGapsChanged` notification.
    static var defaultInnerGapPoints: Double { GapPolicy.defaultInnerGapPoints }
    private var gapPolicy = GapPolicy()
    var gaps: Double { gapPolicy.gaps }
    var outerGaps: LayoutGaps.OuterGaps { gapPolicy.outerGaps }
    private var windows: WindowModel { windowRegistry.windows }
    private lazy var runtimeStore = RuntimeStore()

    /// Live authoritative workspace graph. `WindowModel` still stores the
    /// OS-facing per-window records; every manager mutation that changes
    /// workspace structure or graph-visible window facets updates this graph
    /// in the same serialized `@MainActor` turn.
    private let workspaceGraph: WorkspaceGraph
    private(set) var lastRecordedTransaction: Transaction?
    private var restorePlanner: RestorePlanner { restoreState.restorePlanner }
    private var bootPersistedWindowRestoreCatalog: PersistedWindowRestoreCatalog {
        restoreState.bootPersistedWindowRestoreCatalog
    }
    // Read-only forwarders to the native-fullscreen ledger
    // (`RestoreState.nativeFullscreenLedger`). All writes go through
    // `upsertNativeFullscreenRecord` / `removeNativeFullscreenRecord`
    // helpers below, which route to `ledger.upsert(_:)` / `.remove(...)`
    // so the records-by-id ↔ id-by-token invariant is maintained at the
    // ledger boundary.
    private var nativeFullscreenRecordsByLogicalId: [LogicalWindowId: NativeFullscreenRecord] {
        restoreState.nativeFullscreenRecordsByLogicalId
    }
    private var nativeFullscreenLogicalIdByCurrentToken: [WindowToken: LogicalWindowId] {
        restoreState.nativeFullscreenLogicalIdByCurrentToken
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

    // Manager-side focus state extracted into `FocusStateLedger` (ExecPlan
    // 01, slice WGT-SS-04). Internal call sites continue to read
    // `storedFocusState` via the forwarder below; the two write paths
    // (reducer dispatch + explicit clear) go through the ledger.
    private var focusLedger = FocusStateLedger()
    private var storedFocusState: FocusState { focusLedger.state }

    weak var capabilityProfileResolverRef: WindowCapabilityProfileResolver?

    // Per-logical-id frame state storage extracted into `FrameStateLedger`
    // (ExecPlan 01, slice WGT-SS-03). The reducer event flow stays here;
    // the ledger owns the storage and exposes `state(for:)`, `reduce(_:_)`,
    // and `drop(logicalId:)`.
    private var frameLedger = FrameStateLedger()

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
        workspaceGraph = WorkspaceGraph(
            workspaces: [:],
            workspaceOrder: [],
            entriesByLogicalId: [:]
        )
        cachedTopologyProfile = TopologyProfile(monitors: initialMonitors)
        restoreState = RestoreState(settings: settings)
        rebuildMonitorIndexes()
        synchronizeConfiguredWorkspaces()
        reconcileInteractionMonitorState(notify: false)
        refreshWorkspaceGraphMetadata()
        refreshWorkspaceGraphFocusState()
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
            .map { entry -> ReconcileWindowSnapshot in
                let frameState = self.frameState(for: entry.token)
                var observedState = entry.observedState
                if let observedFrame = frameState?.observed?.rect {
                    observedState.frame = observedFrame
                } else if let confirmedFrame = frameState?.confirmed?.rect {
                    observedState.frame = confirmedFrame
                }
                var desiredState = entry.desiredState
                if let desiredFrame = frameState?.desired?.rect {
                    desiredState.floatingFrame = desiredFrame
                }
                return ReconcileWindowSnapshot(
                    token: entry.token,
                    workspaceId: entry.workspaceId,
                    mode: entry.mode,
                    lifecyclePhase: entry.lifecyclePhase,
                    observedState: observedState,
                    desiredState: desiredState,
                    restoreIntent: entry.restoreIntent,
                    replacementCorrelation: entry.replacementCorrelation
                )
            }

        return ReconcileSnapshot(
            topologyProfile: topologyProfile,
            focusSession: focusSessionSnapshot(),
            windows: windowSnapshots,
            workspaceGraph: workspaceGraph.stateSnapshot()
        )
    }

    private func focusSessionSnapshot() -> FocusSessionSnapshot {
        return FocusSessionSnapshot(
            focusedToken: storedFocusState.observedToken,
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
    func recordTransaction(
        _ transaction: Transaction
    ) -> Transaction {
        let completed = transaction.isCompleted
            ? transaction
            : transaction.completedWithValidatedSnapshot(transaction.snapshot)
        lastRecordedTransaction = completed
        return completed
    }

    @discardableResult
    func prepareTransaction(
        _ event: WMEvent,
        transactionEpoch: TransactionEpoch = .invalid,
        effects: [WMEffect] = []
    ) -> Transaction {
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
            effects: effects,
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
                return self.applyActionPlan(
                    plan,
                    to: token,
                    transactionEpoch: transactionEpoch
                )
            }
        )
    }

    @discardableResult
    func recordTransaction(
        for event: WMEvent,
        transactionEpoch: TransactionEpoch = .invalid,
        effects: [WMEffect] = []
    ) -> Transaction {
        recordTransaction(
            prepareTransaction(
                event,
                transactionEpoch: transactionEpoch,
                effects: effects
            )
        )
    }

    @discardableResult
    func recordRuntimeTransaction(
        kindForLog: String,
        source: WMEventSource,
        transactionEpoch: TransactionEpoch,
        notes: [String] = [],
        effects: [WMEffect] = []
    ) -> Transaction {
        var plan = ActionPlan()
        plan.notes = notes
        return recordTransaction(runtimeStore.record(
            event: .commandIntent(kindForLog: kindForLog, source: source),
            plan: plan,
            effects: effects,
            snapshot: reconcileSnapshot(),
            transactionEpoch: transactionEpoch
        ))
    }

    @discardableResult
    private func recordTopologyChange(
        to newMonitors: [Monitor],
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> Transaction {
        let normalizedMonitors = newMonitors.isEmpty ? [Monitor.fallback()] : newMonitors
        let originalWorkspaceConfigurations = settings.workspaceConfigurations
        let originalMonitorBarSettings = settings.monitorBarSettings
        let originalOrientationSettings = settings.monitorOrientationSettings
        let originalNiriSettings = settings.monitorNiriSettings
        let originalDwindleSettings = settings.monitorDwindleSettings
        let originalMouseWarpMonitorOrder = settings.mouseWarpMonitorOrder

        let previousOutputs = monitors.map { OutputId(from: $0) }
        let workspaceList = allWorkspaceDescriptors()
        let restoreSnapshots = collectWorkspaceRestoreSnapshots()
        let topologyTransition = MonitorTopologyState.projectTransition(
            previousOutputs: previousOutputs,
            newMonitors: normalizedMonitors,
            workspaces: workspaceList,
            snapshots: restoreSnapshots,
            settings: settings,
            epoch: .invalid
        )
        let rebindDecision = topologyTransition.rebindDecision
        monitorRebindPolicyLog.debug(
            // swiftlint:disable:next line_length
            "monitor_rebind_decision workspaces=\(workspaceList.count) topology_nodes=\(topologyTransition.topology.order.count) monitors_prev=\(previousOutputs.count) claimed=\(rebindDecision.claimedMonitorIds.count) unresolved=\(rebindDecision.unresolvedOutputs.count) assigned=\(rebindDecision.workspaceMonitorAssignments.count)"
        )

        let topologyPlan: TopologyTransitionPlan? = if Self.forceTopologyReconcileFailureForTests {
            nil
        } else {
            WorkspaceSessionKernel.reconcileTopology(
                manager: self,
                newMonitors: normalizedMonitors
            )
        }
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
            source: eventSource
        )

        return recordTransaction(runtimeStore.transact(
            event: event,
            existingEntry: nil,
            monitors: normalizedMonitors,
            transactionEpoch: transactionEpoch,
            snapshot: { self.reconcileSnapshot() },
            applyPlan: { plan, _ in
                var plan = plan
                if let topologyPlan {
                    plan.topologyTransition = topologyPlan
                    if topologyPlan.refreshRestoreIntents {
                        plan.notes.append("restore_refresh=topology")
                    }
                }
                return self.applyActionPlan(
                    plan,
                    to: nil,
                    transactionEpoch: transactionEpoch
                )
            }
        ))
    }

    private func collectWorkspaceRestoreSnapshots() -> [WorkspaceRestoreSnapshot] {
        var seen: Set<WorkspaceDescriptor.ID> = []
        var result: [WorkspaceRestoreSnapshot] = []
        for descriptor in allWorkspaceDescriptors() {
            guard let monitorId = monitorId(for: descriptor.id),
                  let monitor = monitors.first(where: { $0.id == monitorId })
            else { continue }
            guard seen.insert(descriptor.id).inserted else { continue }
            result.append(
                WorkspaceRestoreSnapshot(
                    monitor: MonitorRestoreKey(monitor: monitor),
                    workspaceId: descriptor.id
                )
            )
        }
        for (key, workspaceId) in disconnectedVisibleWorkspaceCache {
            guard seen.insert(workspaceId).inserted else { continue }
            result.append(
                WorkspaceRestoreSnapshot(monitor: key, workspaceId: workspaceId)
            )
        }
        return result
    }

    private func applyActionPlan(
        _ plan: ActionPlan,
        to token: WindowToken?,
        transactionEpoch: TransactionEpoch
    ) -> ActionPlan {
        var resolvedPlan = plan

        if let restoreRefresh = plan.restoreRefresh {
            applyRestoreRefresh(restoreRefresh)
        }

        if let focusSession = plan.focusSession {
            applyReconciledFocusSession(
                focusSession,
                transactionEpoch: transactionEpoch
            )
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
            applyLifecyclePhase(lifecyclePhase, for: token)
        }
        if let observedState = plan.observedState {
            if let frame = observedState.frame {
                _ = recordObservedFrame(
                    .init(rect: frame, space: .appKit, isVisibleFrame: true),
                    for: token
                )
            }
            windows.setObservedState(observedState, for: token)
        }
        if let desiredState = plan.desiredState {
            if let floating = desiredState.floatingFrame {
                _ = recordDesiredFrame(
                    .init(rect: floating, space: .appKit, isVisibleFrame: true),
                    for: token
                )
            }
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

    private func applyReconciledFocusSession(
        _ focusSession: FocusSessionSnapshot,
        transactionEpoch: TransactionEpoch
    ) {
        defer { _ = refreshWorkspaceGraphFocusState() }
        let previousLease = sessionState.focus.focusLease
        let previousFocusedToken = sessionState.focus.focusedToken
        let previousPendingToken = sessionState.focus.pendingManagedFocus.token
        let previousNonManagedActive = sessionState.focus.isNonManagedFocusActive
        let previousAppFullscreenActive = sessionState.focus.isAppFullscreenActive
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

        let newFocusedToken = focusSession.focusedToken
        let newPendingFocus = focusSession.pendingManagedFocus
        if let token = newPendingFocus.token,
           let workspaceId = newPendingFocus.workspaceId,
           let logicalId = logicalWindowRegistry.lookup(token: token).liveLogicalId
        {
            applyFocusReducerEvent(
                .activationRequested(
                    desired: .logical(logicalId, workspaceId: workspaceId),
                    requestId: 0,
                    originatingTransactionEpoch: transactionEpoch
                )
            )
        }
        if newFocusedToken != previousFocusedToken {
            if let token = newFocusedToken {
                if newPendingFocus.token != nil {
                    applyFocusReducerEvent(
                        .observationSettled(observedToken: token, txn: transactionEpoch)
                    )
                } else {
                    applyFocusReducerEvent(
                        .activationConfirmed(observedToken: token, observedAt: transactionEpoch)
                    )
                }
            } else {
                applyFocusReducerEvent(.activationCancelled(txn: transactionEpoch))
                clearStoredFocusObservedToken()
            }
        }
        if newFocusedToken == previousFocusedToken,
           previousPendingToken != nil,
           focusSession.pendingManagedFocus.token == nil
        {
            applyFocusReducerEvent(.activationCancelled(txn: transactionEpoch))
        }

        if focusSession.isAppFullscreenActive, !previousAppFullscreenActive,
           focusSession.pendingManagedFocus.token == nil
        {
            applyFocusReducerEvent(.preempted(source: .nativeFullscreen))
        }
        if !focusSession.isAppFullscreenActive, previousAppFullscreenActive {
            applyFocusReducerEvent(.preemptionEnded)
        }
        _ = previousNonManagedActive

        let newLease = focusSession.focusLease
        if previousLease?.owner != newLease?.owner {
            switch newLease?.owner {
            case .nativeMenu:
                applyFocusReducerEvent(.preempted(source: .nativeMenu))
            case .nativeAppSwitch:
                applyFocusReducerEvent(.preempted(source: .appSwitcher))
            case .ruleCreatedFloatingWindow:
                break
            case .none:
                applyFocusReducerEvent(.preemptionEnded)
            }
        }
    }

    private func clearStoredFocusObservedToken() {
        focusLedger.clearObservedAndActivation()
        _ = refreshWorkspaceGraphFocusState()
    }

    @discardableResult
    private func applyFocusReconcileEvent(
        _ event: WMEvent,
        transactionEpoch: TransactionEpoch = .invalid
    ) -> Bool {
        let previousFocusSession = focusSessionSnapshot()
        recordTransaction(for: event, transactionEpoch: transactionEpoch)
        let graphChanged = refreshWorkspaceGraphFocusState()
        return focusSessionSnapshot() != previousFocusSession || graphChanged
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
            if let logicalId = logicalWindowRegistry.resolveForWrite(token: entry.token) {
                _ = logicalWindowRegistryStorage.updateWorkspaceAssignment(
                    logicalId: logicalId,
                    workspaceId: entry.workspaceId,
                    monitorId: currentMonitorId
                )
            }
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
            _ = syncWorkspaceGraphEntry(for: token)
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
        _ = syncWorkspaceGraphEntry(for: token)

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
        _ = syncWorkspaceGraphEntry(for: token)
        let focusChanged = updateFocusSession(notify: false) { focus in
            self.reconcileRememberedFocusAfterModeChange(
                token,
                workspaceId: workspaceId,
                oldMode: oldMode,
                newMode: mode,
                focus: &focus
            )
        }
        _ = refreshWorkspaceGraphFocusState()
        return focusChanged
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
        monitorIndex.monitor(byId: id)
    }

    func monitor(named name: String) -> Monitor? {
        monitorIndex.monitor(named: name)
    }

    func monitors(named name: String) -> [Monitor] {
        monitorIndex.monitors(named: name)
    }

    var interactionMonitorId: Monitor.ID? {
        sessionState.interactionMonitorId
    }

    var previousInteractionMonitorId: Monitor.ID? {
        sessionState.previousInteractionMonitorId
    }

    var focusedToken: WindowToken? {
        storedFocusState.observedToken
    }

    var focusedLogicalId: LogicalWindowId? {
        workspaceGraph.workspaceOrder
            .lazy
            .compactMap { self.workspaceGraph.node(for: $0)?.focusedLogicalId }
            .first
    }

    var focusedHandle: WindowHandle? {
        focusedToken.flatMap { windows.handle(for: $0) }
    }

    var pendingFocusedToken: WindowToken? {
        sessionState.focus.pendingManagedFocus.token
    }

    var pendingFocusedLogicalId: LogicalWindowId? {
        workspaceGraph.workspaceOrder
            .lazy
            .compactMap { self.workspaceGraph.node(for: $0)?.pendingFocusedLogicalId }
            .first
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

    var focusStateProjection: FocusState {
        focusStateProjection(activeRequestId: nil, originatingTransactionEpoch: nil)
    }

    func focusStateProjection(
        activeRequestId: UInt64?,
        originatingTransactionEpoch: TransactionEpoch?
    ) -> FocusState {
        var state = FocusState.initial

        let pendingToken = sessionState.focus.pendingManagedFocus.token
        let pendingWorkspaceId = sessionState.focus.pendingManagedFocus.workspaceId
        let confirmedLogical = focusedLogicalId
        let pendingLogical = pendingFocusedLogicalId

        if let pendingLogical, let pendingWorkspaceId {
            state.desired = .logical(pendingLogical, workspaceId: pendingWorkspaceId)
        } else if let confirmedLogical,
                  let token = sessionState.focus.focusedToken,
                  let workspaceId = workspaceIdForToken(token)
        {
            state.desired = .logical(confirmedLogical, workspaceId: workspaceId)
        } else {
            state.desired = .none
        }

        state.observedToken = sessionState.focus.focusedToken

        if pendingToken != nil {
            let id = activeRequestId ?? 0
            let epoch = originatingTransactionEpoch ?? .invalid
            state.activation = .pending(requestId: id, originatingTransactionEpoch: epoch)
        } else if confirmedLogical != nil {
            state.activation = .confirmed(observedAt: .invalid)
        } else {
            state.activation = .idle
        }

        if let lease = sessionState.focus.focusLease {
            switch lease.owner {
            case .nativeMenu:
                state.preemption = .nativeMenu
            case .nativeAppSwitch:
                state.preemption = .appSwitcher
            case .ruleCreatedFloatingWindow:
                state.preemption = .none
            }
        } else if sessionState.focus.isAppFullscreenActive, pendingToken == nil {
            state.preemption = .nativeFullscreen
        } else {
            state.preemption = .none
        }

        return state
    }

    private func workspaceIdForToken(_ token: WindowToken) -> WorkspaceDescriptor.ID? {
        let logicalId: LogicalWindowId
        switch logicalWindowRegistry.lookup(token: token) {
        case let .current(id), let .staleAlias(id):
            logicalId = id
        case .retired, .unknown:
            return nil
        }
        return logicalWindowRegistry.record(for: logicalId)?.lastKnownWorkspaceId
    }

    var hasNativeFullscreenLifecycleContext: Bool {
        sessionState.focus.isAppFullscreenActive || !nativeFullscreenRecordsByLogicalId.isEmpty
    }

    @discardableResult
    func applyFocusReducerEvent(_ event: FocusReducer.Event) -> Bool {
        let changed = focusLedger.reduce(event).didChange
        if changed {
            _ = refreshWorkspaceGraphFocusState()
        }
        return changed
    }

    func applyFocusReducerEventReturningAction(
        _ event: FocusReducer.Event
    ) -> (changed: Bool, action: FocusReducer.RecommendedAction?) {
        let reduction = focusLedger.reduce(event)
        if reduction.didChange {
            _ = refreshWorkspaceGraphFocusState()
        }
        return (reduction.didChange, reduction.recommendedAction)
    }

    var storedFocusStateSnapshot: FocusState {
        storedFocusState
    }

    func frameState(for logicalId: LogicalWindowId) -> FrameState? {
        frameLedger.state(for: logicalId)
    }

    func frameState(for token: WindowToken) -> FrameState? {
        guard let logicalId = logicalWindowRegistry.lookup(token: token).liveLogicalId else {
            return nil
        }
        return frameLedger.state(for: logicalId)
    }

    @discardableResult
    private func applyFrameReducerEvent(
        _ event: FrameReducer.Event,
        for token: WindowToken
    ) -> FrameReducer.Reduction? {
        guard let logicalId = logicalWindowRegistry.lookup(token: token).liveLogicalId else {
            return nil
        }
        return applyFrameReducerEvent(event, forLogicalId: logicalId)
    }

    @discardableResult
    private func applyFrameReducerEvent(
        _ event: FrameReducer.Event,
        forLogicalId logicalId: LogicalWindowId
    ) -> FrameReducer.Reduction {
        frameLedger.reduce(event, forLogicalId: logicalId)
    }

    @discardableResult
    func recordDesiredFrame(_ frame: FrameState.Frame, for token: WindowToken) -> Bool {
        applyFrameReducerEvent(.desiredFrameRequested(frame), for: token) != nil
    }

    @discardableResult
    func recordObservedFrame(_ frame: FrameState.Frame, for token: WindowToken) -> Bool {
        applyFrameReducerEvent(.observedFrameReceived(frame), for: token) != nil
    }

    @discardableResult
    func recordPendingFrameWrite(
        _ frame: FrameState.Frame,
        requestId: AXFrameRequestId,
        since: TransactionEpoch,
        for token: WindowToken
    ) -> Bool {
        applyFrameReducerEvent(
            .pendingFrameWriteEmitted(frame, requestId: requestId, since: since),
            for: token
        ) != nil
    }

    @discardableResult
    func recordFailedFrameWrite(
        reason: AXFrameWriteFailureReason,
        attemptedAt: TransactionEpoch,
        for token: WindowToken
    ) -> Bool {
        applyFrameReducerEvent(
            .writeFailed(reason: reason, attemptedAt: attemptedAt),
            for: token
        ) != nil
    }

    @discardableResult
    func captureRestorableFrame(for logicalId: LogicalWindowId) -> Bool {
        let reduction = applyFrameReducerEvent(.captureRestorable, forLogicalId: logicalId)
        return reduction.nextState.confirmed != nil
    }

    func dropFrameState(for logicalId: LogicalWindowId) {
        frameLedger.drop(logicalId: logicalId)
    }

    func lifecycleRecordWithFrame(
        for logicalId: LogicalWindowId
    ) -> WindowLifecycleRecordWithFrame? {
        guard let record = logicalWindowRegistry.record(for: logicalId) else {
            return nil
        }
        return record.frameProjection { [self] id in frameLedger.state(for: id) }
    }

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
        nativeFullscreenRecordsByLogicalId.values.contains {
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
        _ focusSnapshot: FocusOrchestrationSnapshot,
        transactionEpoch: TransactionEpoch = .invalid
    ) -> Bool {
        var changed = false
        let previousPendingToken = sessionState.focus.pendingManagedFocus.token
        let previousAppFullscreen = sessionState.focus.isAppFullscreenActive

        if let token = focusSnapshot.pendingFocusedToken,
           let workspaceId = focusSnapshot.pendingFocusedWorkspaceId
        {
            changed = updatePendingManagedFocusRequest(
                token,
                workspaceId: workspaceId,
                monitorId: monitorId(for: workspaceId),
                focus: &sessionState.focus
            ) || changed
            if let logicalId = logicalWindowRegistry.lookup(token: token).liveLogicalId {
                applyFocusReducerEvent(
                    .activationRequested(
                        desired: .logical(logicalId, workspaceId: workspaceId),
                        requestId: 0,
                        originatingTransactionEpoch: transactionEpoch
                    )
                )
            }
        } else {
            changed = clearPendingManagedFocusRequest(focus: &sessionState.focus) || changed
            if previousPendingToken != nil {
                applyFocusReducerEvent(.activationCancelled(txn: transactionEpoch))
            }
        }

        if sessionState.focus.isNonManagedFocusActive != focusSnapshot.isNonManagedFocusActive {
            sessionState.focus.isNonManagedFocusActive = focusSnapshot.isNonManagedFocusActive
            changed = true
        }
        if sessionState.focus.isAppFullscreenActive != focusSnapshot.isAppFullscreenActive {
            sessionState.focus.isAppFullscreenActive = focusSnapshot.isAppFullscreenActive
            changed = true
            if focusSnapshot.isAppFullscreenActive, !previousAppFullscreen {
                applyFocusReducerEvent(.preempted(source: .nativeFullscreen))
            } else if !focusSnapshot.isAppFullscreenActive, previousAppFullscreen {
                applyFocusReducerEvent(.preemptionEnded)
            }
        }

        if changed {
            _ = refreshWorkspaceGraphFocusState()
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
        onMonitor monitorId: Monitor.ID? = nil,
        originatingTransactionEpoch: TransactionEpoch = .invalid,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
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
                source: eventSource,
                originatingTransactionEpoch: originatingTransactionEpoch
            ),
            transactionEpoch: transactionEpoch
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
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> Bool {
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id }
        var changed = rememberFocus(token, in: workspaceId)
        changed = applyFocusReconcileEvent(
            .managedFocusRequested(
                token: token,
                workspaceId: workspaceId,
                monitorId: normalizedMonitorId,
                source: eventSource
            ),
            transactionEpoch: transactionEpoch
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
        activateWorkspaceOnMonitor: Bool,
        originatingTransactionEpoch: TransactionEpoch = .invalid,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
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
                source: eventSource,
                originatingTransactionEpoch: originatingTransactionEpoch
            ),
            transactionEpoch: transactionEpoch
        ) || changed

        if changed {
            notifySessionStateChanged()
        }

        return changed
    }

    @discardableResult
    func cancelManagedFocusRequest(
        matching token: WindowToken? = nil,
        workspaceId: WorkspaceDescriptor.ID? = nil,
        originatingTransactionEpoch: TransactionEpoch = .invalid,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> Bool {
        let changed = applyFocusReconcileEvent(
            .managedFocusCancelled(
                token: token,
                workspaceId: workspaceId,
                source: eventSource,
                originatingTransactionEpoch: originatingTransactionEpoch
            ),
            transactionEpoch: transactionEpoch
        )

        if changed {
            notifySessionStateChanged()
        }

        return changed
    }

    @discardableResult
    func setManagedAppFullscreen(
        _ active: Bool,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> Bool {
        let changed = applyFocusReconcileEvent(
            .nonManagedFocusChanged(
                active: false,
                appFullscreen: active,
                preserveFocusedToken: true,
                source: eventSource
            ),
            transactionEpoch: transactionEpoch
        )
        if changed {
            notifySessionStateChanged()
        }
        return changed
    }

    func nativeFullscreenRecord(for token: WindowToken) -> NativeFullscreenRecord? {
        guard let logicalId = nativeFullscreenLogicalIdForRead(for: token) else {
            return nil
        }
        return nativeFullscreenRecordsByLogicalId[logicalId]
    }

    private var managedRestoreSnapshotByLogicalId: [LogicalWindowId: ManagedWindowRestoreSnapshot] = [:]

    func managedRestoreSnapshot(for token: WindowToken) -> ManagedWindowRestoreSnapshot? {
        guard let logicalId = logicalWindowRegistry.resolveForRead(token: token) else {
            return nil
        }
        return managedRestoreSnapshotByLogicalId[logicalId]
    }

    func managedRestoreSnapshot(forLogicalId logicalId: LogicalWindowId) -> ManagedWindowRestoreSnapshot? {
        managedRestoreSnapshotByLogicalId[logicalId]
    }

    @discardableResult
    func setManagedRestoreSnapshot(
        _ snapshot: ManagedWindowRestoreSnapshot,
        for token: WindowToken
    ) -> Bool {
        guard windows.entry(for: token) != nil else { return false }
        guard let logicalId = logicalWindowRegistry.resolveForWrite(token: token) else {
            return false
        }
        guard shouldPersistManagedRestoreSnapshot(snapshot, forLogicalId: logicalId) else {
            return false
        }
        managedRestoreSnapshotByLogicalId[logicalId] = snapshot
        return true
    }

    @discardableResult
    func clearManagedRestoreSnapshot(for token: WindowToken) -> Bool {
        guard let logicalId = logicalWindowRegistry.resolveForRead(token: token),
              managedRestoreSnapshotByLogicalId[logicalId] != nil
        else {
            return false
        }
        managedRestoreSnapshotByLogicalId.removeValue(forKey: logicalId)
        return true
    }

    func shouldPersistManagedRestoreSnapshot(
        _ snapshot: ManagedWindowRestoreSnapshot,
        for token: WindowToken
    ) -> Bool {
        guard let logicalId = logicalWindowRegistry.resolveForRead(token: token) else {
            return true
        }
        return shouldPersistManagedRestoreSnapshot(snapshot, forLogicalId: logicalId)
    }

    private func shouldPersistManagedRestoreSnapshot(
        _ snapshot: ManagedWindowRestoreSnapshot,
        forLogicalId logicalId: LogicalWindowId
    ) -> Bool {
        guard let previousSnapshot = managedRestoreSnapshotByLogicalId[logicalId] else {
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
        for token: WindowToken,
        transactionEpoch _: TransactionEpoch = .invalid,
        eventSource _: WMEventSource = .workspaceManager
    ) -> Bool {
        guard let logicalId = resolveNativeFullscreenWriteTarget(
            for: token,
            api: "seedNativeFullscreenRestoreSnapshot"
        ),
              var record = nativeFullscreenRecordsByLogicalId[logicalId]
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
        restoreFailure: NativeFullscreenRecord.RestoreFailure? = nil,
        transactionEpoch _: TransactionEpoch = .invalid,
        eventSource _: WMEventSource = .workspaceManager
    ) -> Bool {
        guard let logicalId = resolveNativeFullscreenWriteTarget(
            for: token,
            api: "requestNativeFullscreenEnter"
        ) else {
            return false
        }
        var changed = rememberFocus(token, in: workspaceId)
        _ = captureRestorableFrame(for: logicalId)
        let resolvedRestoreSnapshot = restoreSnapshot
            ?? nativeFullscreenRestoreSnapshot(from: managedRestoreSnapshot(for: token))
        let existing = nativeFullscreenRecordsByLogicalId[logicalId]
        var record = existing ?? NativeFullscreenRecord(
            logicalId: logicalId,
            originalToken: token,
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
    func markNativeFullscreenSuspended(
        _ token: WindowToken,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> Bool {
        markNativeFullscreenSuspended(
            token,
            restoreSnapshot: nil,
            transactionEpoch: transactionEpoch,
            eventSource: eventSource
        )
    }

    @discardableResult
    func markNativeFullscreenSuspended(
        _ token: WindowToken,
        restoreSnapshot: NativeFullscreenRecord.RestoreSnapshot?,
        restoreFailure: NativeFullscreenRecord.RestoreFailure? = nil,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> Bool {
        guard let entry = entry(for: token) else { return false }
        guard let logicalId = resolveNativeFullscreenWriteTarget(
            for: token,
            api: "markNativeFullscreenSuspended"
        ) else {
            return false
        }

        var changed = rememberFocus(token, in: entry.workspaceId)
        let resolvedRestoreSnapshot = restoreSnapshot
            ?? nativeFullscreenRestoreSnapshot(from: managedRestoreSnapshot(for: token))
        let existing = nativeFullscreenRecordsByLogicalId[logicalId]
        var record = existing ?? NativeFullscreenRecord(
            logicalId: logicalId,
            originalToken: token,
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
            setLayoutReason(
                .nativeFullscreen,
                for: token,
                transactionEpoch: transactionEpoch,
                eventSource: eventSource
            )
            changed = true
        }
        changed = enterNonManagedFocus(
            appFullscreen: true,
            transactionEpoch: transactionEpoch,
            eventSource: eventSource
        ) || changed
        markNativeFullscreenLifecycleTransition()
        return changed
    }

    @discardableResult
    func requestNativeFullscreenExit(
        _ token: WindowToken,
        initiatedByCommand: Bool,
        transactionEpoch _: TransactionEpoch = .invalid,
        eventSource _: WMEventSource = .workspaceManager
    ) -> Bool {
        let existing = nativeFullscreenRecord(for: token)
        if existing == nil, entry(for: token) == nil {
            return false
        }
        guard let logicalId = resolveNativeFullscreenWriteTarget(
            for: token,
            api: "requestNativeFullscreenExit"
        ) else {
            return false
        }

        let workspaceId = existing?.workspaceId ?? workspace(for: token)
        guard let workspaceId else { return false }
        let resolvedRestoreSnapshot = existing?.restoreSnapshot
            ?? nativeFullscreenRestoreSnapshot(from: managedRestoreSnapshot(for: token))

        var record = existing ?? NativeFullscreenRecord(
            logicalId: logicalId,
            originalToken: token,
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
        now: Date = Date(),
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> NativeFullscreenRecord? {
        guard let logicalId = resolveNativeFullscreenWriteTarget(
            for: token,
            api: "markNativeFullscreenTemporarilyUnavailable"
        ),
              var record = nativeFullscreenRecordsByLogicalId[logicalId]
        else {
            return nil
        }

        if layoutReason(for: record.currentToken) != .nativeFullscreen {
            setLayoutReason(
                .nativeFullscreen,
                for: record.currentToken,
                transactionEpoch: transactionEpoch,
                eventSource: eventSource
            )
        }

        if record.currentToken != token {
            record.currentToken = token
        }
        record.availability = .temporarilyUnavailable
        if record.unavailableSince == nil {
            record.unavailableSince = now
        }
        upsertNativeFullscreenRecord(record)
        _ = setManagedAppFullscreen(
            false,
            transactionEpoch: transactionEpoch,
            eventSource: eventSource
        )
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
        let candidates = nativeFullscreenRecordsByLogicalId.values.filter { record in
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
        guard let logicalId = nativeFullscreenLogicalIdForRead(for: originalToken),
              var record = nativeFullscreenRecordsByLogicalId[logicalId]
        else {
            return false
        }
        guard record.currentToken != newToken else { return false }
        record.currentToken = newToken
        upsertNativeFullscreenRecord(record)
        return true
    }

    @discardableResult
    func restoreNativeFullscreenRecord(
        for token: WindowToken,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> ParentKind? {
        guard let logicalId = resolveNativeFullscreenWriteTarget(
            for: token,
            api: "restoreNativeFullscreenRecord"
        ) else {
            return nil
        }
        let record = nativeFullscreenRecordsByLogicalId[logicalId]
        let resolvedToken = record?.currentToken ?? token
        if record != nil {
            _ = removeNativeFullscreenRecord(logicalId: logicalId)
        }
        let restoredParentKind = restoreFromNativeState(
            for: resolvedToken,
            transactionEpoch: transactionEpoch,
            eventSource: eventSource
        )
        if nativeFullscreenRecordsByLogicalId.isEmpty {
            _ = setManagedAppFullscreen(
                false,
                transactionEpoch: transactionEpoch,
                eventSource: eventSource
            )
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

        let candidates = nativeFullscreenRecordsByLogicalId.values.filter {
            $0.transition == .suspended || $0.transition == .exitRequested
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0].currentToken
    }

    @discardableResult
    func expireStaleTemporarilyUnavailableNativeFullscreenRecords(
        now: Date = Date(),
        staleInterval: TimeInterval = staleUnavailableNativeFullscreenTimeout,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> [WindowModel.Entry] {
        let expiredLogicalIds = nativeFullscreenRecordsByLogicalId.values.compactMap { record -> LogicalWindowId? in
            guard record.availability == .temporarilyUnavailable,
                  let unavailableSince = record.unavailableSince,
                  now.timeIntervalSince(unavailableSince) >= staleInterval
            else {
                return nil
            }
            return record.logicalId
        }

        guard !expiredLogicalIds.isEmpty else { return [] }

        var removedEntries: [WindowModel.Entry] = []
        removedEntries.reserveCapacity(expiredLogicalIds.count)

        for logicalId in expiredLogicalIds {
            guard let record = removeNativeFullscreenRecord(logicalId: logicalId) else {
                continue
            }
            if layoutReason(for: record.currentToken) == .nativeFullscreen {
                _ = restoreFromNativeState(
                    for: record.currentToken,
                    transactionEpoch: transactionEpoch,
                    eventSource: eventSource
                )
            }
            if let removed = removeWindow(
                pid: record.currentToken.pid,
                windowId: record.currentToken.windowId,
                transactionEpoch: transactionEpoch,
                eventSource: eventSource
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
            mode: mode
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
            let focusToken = nativeFullscreenSessionPatchFocusToken(
                requestedToken: rememberedFocusToken,
                workspaceId: patch.workspaceId
            )
            changed = rememberFocus(focusToken, in: patch.workspaceId) || changed
        }

        return changed
    }

    private func nativeFullscreenSessionPatchFocusToken(
        requestedToken: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken {
        let nativeFullscreenRecords = nativeFullscreenRecordsByLogicalId.values.filter { record in
            record.workspaceId == workspaceId
                && record.originalToken != record.currentToken
                && record.availability == .present
                && entry(for: record.currentToken)?.workspaceId == workspaceId
        }
        guard nativeFullscreenRecords.count == 1,
              let nativeFullscreenToken = nativeFullscreenRecords.first?.currentToken,
              nativeFullscreenToken != requestedToken
        else {
            return requestedToken
        }
        // Layout session patches can be built before a native-fullscreen
        // replacement rekey completes. The fullscreen record owns focus
        // while the app is preempting managed focus, so stale selected-node
        // patches must not rewrite the workspace's remembered focus.
        return nativeFullscreenToken
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

    func lastFocusedLogicalId(in workspaceId: WorkspaceDescriptor.ID) -> LogicalWindowId? {
        let candidate = workspaceGraph.node(for: workspaceId)?.lastTiledFocusedLogicalId
        guard let candidate,
              let record = logicalWindowRegistry.record(for: candidate),
              record.primaryPhase != .retired
        else {
            return nil
        }
        return candidate
    }

    func lastFloatingFocusedLogicalId(in workspaceId: WorkspaceDescriptor.ID) -> LogicalWindowId? {
        let candidate = workspaceGraph.node(for: workspaceId)?.lastFloatingFocusedLogicalId
        guard let candidate,
              let record = logicalWindowRegistry.record(for: candidate),
              record.primaryPhase != .retired
        else {
            return nil
        }
        return candidate
    }

    func lastFocusedToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        guard let logicalId = lastFocusedLogicalId(in: workspaceId) else { return nil }
        return rememberedFocusCurrentToken(for: logicalId)
    }

    func lastFloatingFocusedToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        guard let logicalId = lastFloatingFocusedLogicalId(in: workspaceId) else { return nil }
        return rememberedFocusCurrentToken(for: logicalId)
    }

    private func rememberedFocusCurrentToken(
        for logicalId: LogicalWindowId
    ) -> WindowToken? {
        guard let record = logicalWindowRegistry.record(for: logicalId),
              record.primaryPhase != .retired
        else {
            return nil
        }
        return record.currentToken
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

    func resolveWorkspaceFocusPlan(
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WorkspaceFocusResolutionPlan? {
        guard let plan = WorkspaceSessionKernel.resolveWorkspaceFocus(
            manager: self,
            workspaceId: workspaceId
        ) else {
            return nil
        }
        let mappedClearAction: WorkspaceFocusResolutionPlan.FocusClearAction
        switch plan.focusClearAction {
        case .none:
            mappedClearAction = .none
        case .pending:
            mappedClearAction = .pending
        case .pendingAndConfirmed:
            mappedClearAction = .pendingAndConfirmed
        }
        return WorkspaceFocusResolutionPlan(
            resolvedFocusToken: plan.resolvedFocusToken,
            resolvedFocusLogicalId: plan.resolvedFocusLogicalId,
            focusClearAction: mappedClearAction
        )
    }

    @discardableResult
    func applyResolvedWorkspaceFocusClearMirror(
        in workspaceId: WorkspaceDescriptor.ID,
        scope: WorkspaceFocusResolutionPlan.FocusClearAction,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .focusPolicy
    ) -> Bool {
        var changed = false

        switch scope {
        case .none:
            return false
        case .pending:
            changed = cancelManagedFocusRequest(
                matching: nil,
                workspaceId: workspaceId,
                originatingTransactionEpoch: transactionEpoch,
                transactionEpoch: transactionEpoch,
                eventSource: eventSource
            )
        case .pendingAndConfirmed:
            changed = cancelManagedFocusRequest(
                matching: nil,
                workspaceId: workspaceId,
                originatingTransactionEpoch: transactionEpoch,
                transactionEpoch: transactionEpoch,
                eventSource: eventSource
            )
            let confirmedChanged = updateFocusSession(notify: false) { focus in
                guard let confirmed = focus.focusedToken,
                      self.entry(for: confirmed)?.workspaceId == workspaceId
                else {
                    return false
                }
                focus.focusedToken = nil
                focus.isAppFullscreenActive = false
                return true
            }
            if confirmedChanged {
                applyFocusReducerEvent(.activationCancelled(txn: transactionEpoch))
                clearStoredFocusObservedTokenMirror()
                _ = refreshWorkspaceGraphFocusState()
            }
            changed = changed || confirmedChanged
        }

        if changed {
            notifySessionStateChanged()
        }
        return changed
    }

    private func clearStoredFocusObservedTokenMirror() {
        clearStoredFocusObservedToken()
    }

    @discardableResult
    func enterNonManagedFocus(
        appFullscreen: Bool,
        preserveFocusedToken: Bool = false,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> Bool {
        let changed = applyFocusReconcileEvent(
            .nonManagedFocusChanged(
                active: true,
                appFullscreen: appFullscreen,
                preserveFocusedToken: preserveFocusedToken,
                source: eventSource
            ),
            transactionEpoch: transactionEpoch
        )
        if changed {
            notifySessionStateChanged()
        }
        return changed
    }

    func handleWindowRemoved(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID?) {
        let focusChanged = updateFocusSession(notify: false) { _ in
            self.clearRememberedFocus(
                token,
                workspaceId: workspaceId
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
        changed = setRememberedFocus(token, in: workspaceId, mode: mode) || changed
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
        mode: TrackedWindowMode
    ) -> Bool {
        guard let logicalId = logicalWindowRegistry.resolveForWrite(token: token) else {
            return false
        }
        return workspaceGraph.setLastFocused(logicalId, in: workspaceId, mode: mode)
    }

    private func clearRememberedFocus(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID?
    ) -> Bool {
        let logicalId = logicalWindowRegistry.resolveForRead(token: token)
            ?? remainingRetiredLogicalId(for: token)
        guard let logicalId else { return false }

        var changed = false

        if let workspaceId {
            changed = workspaceGraph.clearFocusReferences(to: logicalId, in: workspaceId)
            return changed
        }

        changed = workspaceGraph.clearFocusReferences(to: logicalId)

        return changed
    }

    private func remainingRetiredLogicalId(for token: WindowToken) -> LogicalWindowId? {
        if case let .retired(logicalId) = logicalWindowRegistry.lookup(token: token) {
            return logicalId
        }
        return nil
    }

    private func replaceRememberedFocus(
        from _: WindowToken,
        to _: WindowToken,
        focus _: inout WorkspaceSessionState.FocusSession
    ) -> Bool {
        false
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
        guard let logicalId = logicalWindowRegistry.resolveForWrite(token: token) else {
            return false
        }

        var changed = workspaceGraph.clearFocusReferences(to: logicalId, in: workspaceId)

        if focus.focusedToken == token || focus.pendingManagedFocus.token == token {
            changed = setRememberedFocus(token, in: workspaceId, mode: newMode) || changed
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
        monitorIndex.rebuild(from: monitors)
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
            updateWorkspaceGraphMonitorIds(from: projections)
        }

        return projections
    }

    private func cacheCurrentWorkspaceProjectionPlan(_ plan: WorkspaceSessionKernel.Plan) {
        guard !plan.workspaceProjections.isEmpty else { return }
        let projection = Dictionary(
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
        _cachedWorkspaceMonitorProjection = projection
        updateWorkspaceGraphMonitorIds(from: projection)
    }

    private func cacheCurrentWorkspaceProjectionRecords(
        _ records: [TopologyWorkspaceProjectionRecord]
    ) {
        guard !records.isEmpty else {
            _cachedWorkspaceMonitorProjection = nil
            updateWorkspaceGraphMonitorIds(from: [:])
            return
        }
        let projection = Dictionary(
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
        _cachedWorkspaceMonitorProjection = projection
        updateWorkspaceGraphMonitorIds(from: projection)
    }

    private func refreshCurrentWorkspaceProjectionCache() {
        _cachedWorkspaceMonitorProjection = nil
        _ = workspaceMonitorProjectionMap(in: monitors)
        refreshWorkspaceGraphMetadata()
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

    func allWorkspaceDescriptors() -> [WorkspaceDescriptor] {
        sortedWorkspaces()
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
        guard let resolvedWorkspaceId = inferredActiveWorkspaceId(on: monitorId) else {
            return nil
        }
        return descriptor(for: resolvedWorkspaceId)
    }

    private func inferredActiveWorkspaceId(on monitorId: Monitor.ID) -> WorkspaceDescriptor.ID? {
        guard let plan = WorkspaceSessionKernel.project(
            manager: self,
            monitors: monitors
        ) else {
            return nil
        }
        cacheCurrentWorkspaceProjectionPlan(plan)
        return plan.monitorStates.first(where: { $0.monitorId == monitorId })?
            .resolvedActiveWorkspaceId
    }

    @discardableResult
    func activateInferredWorkspaceIfNeeded(
        on monitorId: Monitor.ID,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> Bool {
        _ = transactionEpoch
        _ = eventSource
        if activeWorkspace(on: monitorId) != nil { return false }
        guard let resolvedWorkspaceId = inferredActiveWorkspaceId(on: monitorId) else {
            return false
        }
        return setActiveWorkspaceInternal(resolvedWorkspaceId, on: monitorId)
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
        refreshWorkspaceGraphMetadata()
    }

    func applyMonitorConfigurationChange(
        _ newMonitors: [Monitor],
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) {
        let normalizedMonitors = newMonitors.isEmpty ? [Monitor.fallback()] : newMonitors
        guard TopologyProfile(monitors: normalizedMonitors) != currentTopologyProfile else {
            return
        }
        _ = recordTopologyChange(
            to: normalizedMonitors,
            transactionEpoch: transactionEpoch,
            eventSource: eventSource
        )
    }

    func setGaps(to size: Double) {
        guard gapPolicy.setGaps(to: size) else { return }
        onGapsChanged?()
    }

    func setOuterGaps(left: Double, right: Double, top: Double, bottom: Double) {
        guard gapPolicy.setOuterGaps(left: left, right: right, top: top, bottom: bottom) else {
            return
        }
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
        managedReplacementMetadata: ManagedReplacementMetadata? = nil,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
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
        let allocatedFresh: Bool
        if logicalWindowRegistry.resolveForWrite(token: token) == nil {
            _ = logicalWindowRegistryStorage.allocate(
                boundTo: token,
                workspaceId: workspace,
                monitorId: monitorId(for: workspace)
            )
            allocatedFresh = true
        } else {
            allocatedFresh = false
        }
        if allocatedFresh, let initialPhase = windows.lifecyclePhase(for: token) {
            applyLifecyclePhase(initialPhase, for: token)
        }
        _ = syncWorkspaceGraphEntry(for: token)
        recordTransaction(
            for: .windowAdmitted(
                token: token,
                workspaceId: workspace,
                monitorId: monitorId(for: workspace),
                mode: mode,
                source: eventSource
            ),
            transactionEpoch: transactionEpoch
        )
        return token
    }

    @discardableResult
    func rekeyWindow(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        newAXRef: AXWindowRef,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> WindowModel.Entry? {
        guard let entry = windows.rekeyWindow(
            from: oldToken,
            to: newToken,
            newAXRef: newAXRef,
            managedReplacementMetadata: managedReplacementMetadata
        ) else {
            return nil
        }

        let rebindReason: LogicalWindowReplacementReason = managedReplacementMetadata == nil
            ? .manualRekey
            : .managedReplacement
        let rebindLogicalId: LogicalWindowId
        if let existing = logicalWindowRegistry.resolveForWrite(token: oldToken) {
            _ = logicalWindowRegistryStorage.rebindToken(
                logicalId: existing,
                from: oldToken,
                to: newToken,
                reason: rebindReason
            )
            rebindLogicalId = existing
        } else {
            rebindLogicalId = logicalWindowRegistryStorage.allocate(
                boundTo: newToken,
                workspaceId: entry.workspaceId,
                monitorId: monitorId(for: entry.workspaceId)
            )
        }

        if var record = nativeFullscreenRecordsByLogicalId[rebindLogicalId] {
            record.currentToken = newToken
            upsertNativeFullscreenRecord(record)
        }

        if let metadata = managedReplacementMetadata,
           let snapshot = managedRestoreSnapshotByLogicalId[rebindLogicalId]
        {
            managedRestoreSnapshotByLogicalId[rebindLogicalId] = snapshot
                .withReplacementMetadata(metadata)
        }
        _ = syncWorkspaceGraphEntry(for: rebindLogicalId)

        recordTransaction(
            for: .windowRekeyed(
                from: oldToken,
                to: newToken,
                workspaceId: entry.workspaceId,
                monitorId: monitorId(for: entry.workspaceId),
                reason: managedReplacementMetadata == nil ? .manualRekey : .managedReplacement,
                source: eventSource
            ),
            transactionEpoch: transactionEpoch
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
        let graphEntries = graphEntries(in: workspace, mode: nil)
        return windowEntries(for: graphEntries)
    }

    func workspaceGraphSnapshot() -> WorkspaceGraph {
        workspaceGraph.snapshot()
    }

    private func graphEntries(
        in workspace: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode? = nil,
        includeSuppressed: Bool = true
    ) -> [WorkspaceGraph.WindowEntry] {
        guard let node = workspaceGraph.node(for: workspace) else { return [] }
        var logicalIds: [LogicalWindowId] = []
        switch mode {
        case .tiling:
            logicalIds.append(contentsOf: node.tiledOrder)
        case .floating:
            logicalIds.append(contentsOf: node.floating)
        case .none:
            logicalIds.append(contentsOf: node.tiledOrder)
            logicalIds.append(contentsOf: node.floating)
        }
        if includeSuppressed {
            logicalIds.append(contentsOf: node.suppressed)
        }
        return logicalIds.compactMap { logicalId in
            guard let entry = workspaceGraph.entry(for: logicalId) else { return nil }
            if let mode, entry.mode != mode { return nil }
            return entry
        }
    }

    private func windowEntries(
        for graphEntries: [WorkspaceGraph.WindowEntry]
    ) -> [WindowModel.Entry] {
        graphEntries.compactMap { windows.entry(for: $0.token) }
    }

    func tiledGraphEntries(in workspace: WorkspaceDescriptor.ID) -> [WorkspaceGraph.WindowEntry] {
        graphEntries(in: workspace, mode: .tiling)
    }

    func floatingGraphEntries(in workspace: WorkspaceDescriptor.ID) -> [WorkspaceGraph.WindowEntry] {
        graphEntries(in: workspace, mode: .floating)
    }

    private func tiledEntries(in workspace: WorkspaceDescriptor.ID) -> [WindowModel.Entry] {
        windowEntries(for: tiledGraphEntries(in: workspace))
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

    private func floatingEntries(in workspace: WorkspaceDescriptor.ID) -> [WindowModel.Entry] {
        windowEntries(for: floatingGraphEntries(in: workspace))
    }

    private func barVisibleFloatingEntries(in workspace: WorkspaceDescriptor.ID) -> [WindowModel.Entry] {
        floatingEntries(in: workspace).filter { hiddenState(for: $0.token)?.isScratchpad != true }
    }

    private func refreshWorkspaceGraphMetadata() {
        let projection = workspaceMonitorProjectionMap(in: monitors)
        _ = workspaceGraph.replaceWorkspaces(
            sortedWorkspaces(),
            layoutTypeFor: { [settings] descriptor in
                settings.layoutType(for: descriptor.name)
            },
            monitorIdFor: { workspaceId in
                projection[workspaceId]?.projectedMonitorId
            }
        )
    }

    private func updateWorkspaceGraphMonitorIds(
        from projection: [WorkspaceDescriptor.ID: WorkspaceMonitorProjection]
    ) {
        _ = workspaceGraph.updateMonitorIds(
            projection.mapValues(\.projectedMonitorId)
        )
    }

    private func workspaceGraphEntry(
        for entry: WindowModel.Entry
    ) -> WorkspaceGraph.WindowEntry? {
        let logicalId: LogicalWindowId
        switch logicalWindowRegistry.lookup(token: entry.token) {
        case let .current(id), let .staleAlias(id):
            logicalId = id
        case .retired, .unknown:
            return nil
        }
        guard let record = logicalWindowRegistry.record(for: logicalId),
              record.primaryPhase != .retired,
              let effectToken = logicalWindowRegistry.currentToken(for: logicalId)
        else {
            return nil
        }

        let hiddenState = hiddenState(for: effectToken)
        let replacementMetadata = managedReplacementMetadata(for: effectToken)
        return WorkspaceGraph.WindowEntry(
            logicalId: logicalId,
            token: effectToken,
            workspaceId: entry.workspaceId,
            mode: entry.mode,
            lifecyclePhase: entry.lifecyclePhase,
            visibility: record.visibility,
            quarantine: record.quarantine,
            floatingState: floatingState(for: effectToken),
            replacementMetadata: replacementMetadata,
            overlayParentWindowId: replacementMetadata?.parentWindowId,
            hiddenState: hiddenState,
            isHidden: hiddenState != nil,
            isMinimized: record.visibility == .minimized,
            isNativeFullscreen: nativeFullscreenRecord(for: effectToken) != nil,
            constraintRuleEffects: LayoutConstraintRuleEffects(ruleEffects: entry.ruleEffects)
        )
    }

    @discardableResult
    private func syncWorkspaceGraphEntry(for token: WindowToken) -> Bool {
        guard let entry = windows.entry(for: token),
              let graphEntry = workspaceGraphEntry(for: entry)
        else {
            return false
        }
        let changed = workspaceGraph.placeEntry(graphEntry)
        refreshWorkspaceGraphFocusState()
        return changed
    }

    @discardableResult
    private func syncWorkspaceGraphEntry(for logicalId: LogicalWindowId) -> Bool {
        guard let token = logicalWindowRegistry.currentToken(for: logicalId) else {
            return false
        }
        return syncWorkspaceGraphEntry(for: token)
    }

    @discardableResult
    private func removeWorkspaceGraphEntry(for token: WindowToken) -> Bool {
        let logicalId = logicalWindowRegistry.resolveForRead(token: token)
            ?? remainingRetiredLogicalId(for: token)
        guard let logicalId else { return false }
        let changed = workspaceGraph.removeEntry(logicalId)
        refreshWorkspaceGraphFocusState()
        return changed
    }

    @discardableResult
    private func refreshWorkspaceGraphFocusState() -> Bool {
        let focusedToken = storedFocusState.observedToken
        let pendingToken = sessionState.focus.pendingManagedFocus.token

        let focusedLogicalId = focusedToken.flatMap { token -> LogicalWindowId? in
            guard let logicalId = logicalWindowRegistry.lookup(token: token).liveLogicalId,
                  workspaceGraph.entry(for: logicalId)?.isLayoutEligible == true
            else { return nil }
            return logicalId
        }
        let focusedWorkspaceId = focusedToken.flatMap { token -> WorkspaceDescriptor.ID? in
            guard let logicalId = logicalWindowRegistry.lookup(token: token).liveLogicalId,
                  workspaceGraph.entry(for: logicalId)?.isLayoutEligible == true
            else { return nil }
            return workspaceGraph.workspaceId(containing: logicalId)
        }

        let pendingLogicalId = pendingToken.flatMap { token -> LogicalWindowId? in
            guard let logicalId = logicalWindowRegistry.lookup(token: token).liveLogicalId,
                  workspaceGraph.entry(for: logicalId)?.isLayoutEligible == true
            else { return nil }
            return logicalId
        }
        let pendingWorkspaceId: WorkspaceDescriptor.ID? = {
            guard let pendingLogicalId,
                  sessionState.focus.pendingManagedFocus.workspaceId
                      == workspaceGraph.workspaceId(containing: pendingLogicalId)
            else { return nil }
            return sessionState.focus.pendingManagedFocus.workspaceId
        }()

        return workspaceGraph.replaceActiveFocus(
            focused: focusedLogicalId,
            focusedWorkspaceId: focusedWorkspaceId,
            pending: pendingLogicalId,
            pendingWorkspaceId: pendingWorkspaceId
        )
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
        workspaceGraph.workspaceOrder.flatMap { tiledEntries(in: $0) }
    }

    func allFloatingEntries() -> [WindowModel.Entry] {
        workspaceGraph.workspaceOrder.flatMap { floatingEntries(in: $0) }
    }

    func windowMode(for token: WindowToken) -> TrackedWindowMode? {
        workspaceGraph.entry(for: token, registry: logicalWindowRegistry)?.mode
            ?? windows.mode(for: token)
    }

    func lifecyclePhase(for token: WindowToken) -> WindowLifecyclePhase? {
        windows.lifecyclePhase(for: token)
    }

    func applyLifecyclePhase(_ phase: WindowLifecyclePhase, for token: WindowToken) {
        windows.setLifecyclePhase(phase, for: token)
        guard let logicalId = logicalWindowRegistry.resolveForRead(token: token) else {
            return
        }
        let projection = phase.facetProjection
        if phase != .destroyed {
            _ = logicalWindowRegistryStorage.updatePrimaryPhase(
                logicalId: logicalId,
                projection.primary
            )
        }
        _ = logicalWindowRegistryStorage.updateVisibility(
            logicalId: logicalId,
            projection.visibility
        )
        _ = logicalWindowRegistryStorage.updateFullscreenSession(
            logicalId: logicalId,
            projection.fullscreen
        )
        _ = syncWorkspaceGraphEntry(for: logicalId)
    }

    func projectedLifecyclePhase(for token: WindowToken) -> WindowLifecyclePhase? {
        let logicalId: LogicalWindowId
        switch logicalWindowRegistry.lookup(token: token) {
        case let .current(id), let .staleAlias(id), let .retired(id):
            logicalId = id
        case .unknown:
            return nil
        }
        guard let record = logicalWindowRegistry.record(for: logicalId) else { return nil }
        switch record.primaryPhase {
        case .candidate:
            return .discovered
        case .admitted:
            return .admitted
        case .retiring, .retired:
            return .destroyed
        case .managed:
            break
        }
        if record.fullscreenSession == .nativeFullscreen {
            return .nativeFullscreen
        }
        if case .replacing = record.replacement {
            return .replacing
        }
        if record.visibility == .hidden {
            return .hidden
        }
        if let entry = entry(for: token) {
            switch entry.mode {
            case .tiling:
                return .tiled
            case .floating:
                return .floating
            }
        }
        return nil
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
        for token: WindowToken,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> Bool {
        guard let entry = windows.entry(for: token) else {
            return false
        }
        let previousMetadata = windows.managedReplacementMetadata(for: token)
        windows.setManagedReplacementMetadata(metadata, for: token)
        guard previousMetadata != metadata else {
            return false
        }
        _ = syncWorkspaceGraphEntry(for: token)
        recordTransaction(
            for: .managedReplacementMetadataChanged(
                token: token,
                workspaceId: entry.workspaceId,
                monitorId: monitorId(for: entry.workspaceId),
                source: eventSource
            ),
            transactionEpoch: transactionEpoch
        )
        return true
    }

    @discardableResult
    func updateManagedReplacementFrame(
        _ frame: CGRect,
        for token: WindowToken,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> Bool {
        guard var metadata = windows.managedReplacementMetadata(for: token) else {
            return false
        }
        guard metadata.frame != frame else {
            return false
        }
        metadata.frame = frame
        return setManagedReplacementMetadata(
            metadata,
            for: token,
            transactionEpoch: transactionEpoch,
            eventSource: eventSource
        )
    }

    @discardableResult
    func updateManagedReplacementTitle(
        _ title: String,
        for token: WindowToken,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> Bool {
        guard var metadata = windows.managedReplacementMetadata(for: token) else {
            return false
        }
        guard metadata.title != title else {
            return false
        }
        metadata.title = title
        return setManagedReplacementMetadata(
            metadata,
            for: token,
            transactionEpoch: transactionEpoch,
            eventSource: eventSource
        )
    }

    @discardableResult
    func setWindowMode(
        _ mode: TrackedWindowMode,
        for token: WindowToken,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> Bool {
        guard let entry = entry(for: token) else { return false }
        let oldMode = entry.mode
        guard oldMode != mode else { return false }

        windows.setMode(mode, for: token)
        _ = syncWorkspaceGraphEntry(for: token)
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
        _ = refreshWorkspaceGraphFocusState()
        if focusChanged {
            notifySessionStateChanged()
        }
        recordTransaction(
            for: .windowModeChanged(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId(for: workspaceId),
                mode: mode,
                source: eventSource
            ),
            transactionEpoch: transactionEpoch
        )
        return true
    }

    func floatingState(for token: WindowToken) -> WindowModel.FloatingState? {
        windows.floatingState(for: token)
    }

    func setFloatingState(_ state: WindowModel.FloatingState?, for token: WindowToken) {
        windows.setFloatingState(state, for: token)
        _ = syncWorkspaceGraphEntry(for: token)
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
        restoreToFloating: Bool = true,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
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
        _ = syncWorkspaceGraphEntry(for: token)
        recordTransaction(
            for: .floatingGeometryUpdated(
                token: token,
                workspaceId: entry.workspaceId,
                referenceMonitorId: resolvedReferenceMonitor?.id,
                frame: frame,
                restoreToFloating: restoreToFloating,
                source: eventSource
            ),
            transactionEpoch: transactionEpoch
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
        let delta = windows.confirmedMissingKeysWithDelta(
            keys: activeKeys,
            requiredConsecutiveMisses: requiredConsecutiveMisses
        )

        applyMissingRescanQuarantineDelta(
            delayed: delta.delayed,
            cleared: delta.cleared
        )

        var removedAny = false
        for key in delta.confirmed {
            guard let entry = windows.entry(for: key) else { continue }
            _ = removeTrackedWindow(entry)
            removedAny = true
        }
        if removedAny {
            schedulePersistedWindowRestoreCatalogSave()
        }
    }

    func applyMissingRescanQuarantineDelta(
        delayed: [WindowToken],
        cleared: [WindowToken]
    ) {
        for token in delayed {
            if let logicalId = logicalWindowRegistry.resolveForWrite(token: token) {
                _ = logicalWindowRegistryStorage.updateQuarantine(
                    logicalId: logicalId,
                    .quarantined(reason: .delayedAdmission)
                )
                _ = syncWorkspaceGraphEntry(for: logicalId)
            }
        }
        for token in cleared {
            if let logicalId = logicalWindowRegistry.resolveForWrite(token: token) {
                _ = logicalWindowRegistryStorage.updateQuarantine(
                    logicalId: logicalId,
                    .clear
                )
                _ = syncWorkspaceGraphEntry(for: logicalId)
            }
        }
    }

    @discardableResult
    func quarantineStaleCGSDestroyIfApplicable(probeToken: WindowToken) -> LogicalWindowId? {
        let lookup = logicalWindowRegistry.lookup(token: probeToken)
        guard case let .staleAlias(logicalId) = lookup else { return nil }
        _ = logicalWindowRegistryStorage.updateQuarantine(
            logicalId: logicalId,
            .quarantined(reason: .staleCGSDestroy)
        )
        _ = syncWorkspaceGraphEntry(for: logicalId)
        return logicalId
    }

    @discardableResult
    func quarantineWindowsForTerminatedApp(pid: pid_t) -> [LogicalWindowId] {
        var quarantined: [LogicalWindowId] = []
        for entry in entries(forPid: pid) {
            if let logicalId = logicalWindowRegistry.resolveForRead(token: entry.token) {
                _ = logicalWindowRegistryStorage.updateQuarantine(
                    logicalId: logicalId,
                    .quarantined(reason: .appDisappeared)
                )
                _ = syncWorkspaceGraphEntry(for: logicalId)
                quarantined.append(logicalId)
            }
        }
        return quarantined
    }

    @discardableResult
    func applyAXOutcomeQuarantine(
        for token: WindowToken,
        axFailure: AXFrameWriteFailureReason?
    ) -> LogicalWindowRegistry.WriteOutcome? {
        guard let logicalId = logicalWindowRegistry.resolveForWrite(token: token) else {
            return nil
        }
        switch axFailure {
        case .none,
             .invalidTargetFrame,
             .valueCreationFailed,
             .verificationMismatch,
             .readbackFailed,
             .cacheMiss,
             .cancelled,
             .suppressed:
            let outcome = logicalWindowRegistryStorage.updateQuarantine(logicalId: logicalId, .clear)
            _ = syncWorkspaceGraphEntry(for: logicalId)
            return outcome
        case .staleElement,
             .contextUnavailable,
             .sizeWriteFailed(_),
             .positionWriteFailed(_):
            let outcome = logicalWindowRegistryStorage.updateQuarantine(
                logicalId: logicalId,
                .quarantined(reason: .axReadFailure)
            )
            _ = syncWorkspaceGraphEntry(for: logicalId)
            return outcome
        }
    }

    @discardableResult
    func removeWindow(
        pid: pid_t,
        windowId: Int,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> WindowModel.Entry? {
        guard let entry = windows.entry(forPid: pid, windowId: windowId) else { return nil }
        let removedEntry = removeTrackedWindow(
            entry,
            transactionEpoch: transactionEpoch,
            eventSource: eventSource
        )
        schedulePersistedWindowRestoreCatalogSave()
        return removedEntry
    }

    @discardableResult
    func removeWindowsForApp(
        pid: pid_t,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> Set<WorkspaceDescriptor.ID> {
        var affectedWorkspaces: Set<WorkspaceDescriptor.ID> = []
        let entriesToRemove = entries(forPid: pid)

        for entry in entriesToRemove {
            affectedWorkspaces.insert(entry.workspaceId)
            _ = removeTrackedWindow(
                entry,
                transactionEpoch: transactionEpoch,
                eventSource: eventSource
            )
        }

        if !entriesToRemove.isEmpty {
            schedulePersistedWindowRestoreCatalogSave()
        }

        return affectedWorkspaces
    }

    @discardableResult
    private func removeTrackedWindow(
        _ entry: WindowModel.Entry,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> WindowModel.Entry {
        recordTransaction(
            for: .windowRemoved(
                token: entry.token,
                workspaceId: entry.workspaceId,
                source: eventSource
            ),
            transactionEpoch: transactionEpoch
        )
        _ = removeNativeFullscreenRecord(containing: entry.token)
        handleWindowRemoved(entry.token, in: entry.workspaceId)
        _ = removeWorkspaceGraphEntry(for: entry.token)
        _ = windows.removeWindow(key: entry.token)
        if let logicalId = logicalWindowRegistry.resolveForWrite(token: entry.token) {
            managedRestoreSnapshotByLogicalId.removeValue(forKey: logicalId)
            dropFrameState(for: logicalId)
            _ = logicalWindowRegistryStorage.retire(logicalId: logicalId)
        }
        onWindowRemoved?(entry.token)
        return entry
    }

    func setWorkspace(
        for token: WindowToken,
        to workspace: WorkspaceDescriptor.ID,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) {
        let previousWorkspace = windows.workspace(for: token)
        let targetMonitorId = monitorId(for: workspace)
        windows.updateWorkspace(for: token, workspace: workspace)
        if let logicalId = logicalWindowRegistry.resolveForWrite(token: token) {
            _ = logicalWindowRegistryStorage.updateWorkspaceAssignment(
                logicalId: logicalId,
                workspaceId: workspace,
                monitorId: targetMonitorId
            )
        }
        _ = syncWorkspaceGraphEntry(for: token)
        recordTransaction(
            for: .workspaceAssigned(
                token: token,
                from: previousWorkspace,
                to: workspace,
                monitorId: targetMonitorId,
                source: eventSource
            ),
            transactionEpoch: transactionEpoch
        )
    }

    @discardableResult
    func swapTiledWindowOrder(
        _ lhs: WindowToken,
        _ rhs: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let lhsLogicalId = logicalWindowRegistry.lookup(token: lhs).liveLogicalId,
              let rhsLogicalId = logicalWindowRegistry.lookup(token: rhs).liveLogicalId,
              let lhsEntry = workspaceGraph.entry(for: lhsLogicalId),
              let rhsEntry = workspaceGraph.entry(for: rhsLogicalId),
              lhsEntry.workspaceId == workspaceId,
              rhsEntry.workspaceId == workspaceId,
              lhsEntry.mode == .tiling,
              rhsEntry.mode == .tiling
        else {
            return false
        }
        return workspaceGraph.swapTiledOrder(lhsLogicalId, rhsLogicalId, in: workspaceId)
    }

    func workspace(for token: WindowToken) -> WorkspaceDescriptor.ID? {
        workspaceGraph.entry(for: token, registry: logicalWindowRegistry)?.workspaceId
            ?? windows.workspace(for: token)
    }

    func isHiddenInCorner(_ token: WindowToken) -> Bool {
        windows.isHiddenInCorner(token)
    }

    func setHiddenState(
        _ state: WindowModel.HiddenState?,
        for token: WindowToken,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) {
        windows.setHiddenState(state, for: token)
        _ = syncWorkspaceGraphEntry(for: token)
        if let workspaceId = workspace(for: token) {
            recordTransaction(
                for: .hiddenStateChanged(
                    token: token,
                    workspaceId: workspaceId,
                    monitorId: monitorId(for: workspaceId),
                    hiddenState: state,
                    source: eventSource
                ),
                transactionEpoch: transactionEpoch
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

    func setLayoutReason(
        _ reason: LayoutReason,
        for token: WindowToken,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) {
        windows.setLayoutReason(reason, for: token)
        guard let workspaceId = workspace(for: token) else { return }
        switch reason {
        case .nativeFullscreen:
            recordTransaction(
                for: .nativeFullscreenTransition(
                    token: token,
                    workspaceId: workspaceId,
                    monitorId: monitorId(for: workspaceId),
                    isActive: true,
                source: eventSource
            ),
            transactionEpoch: transactionEpoch
        )
        case .macosHiddenApp, .standard:
            recordTransaction(
                for: .nativeFullscreenTransition(
                    token: token,
                    workspaceId: workspaceId,
                    monitorId: monitorId(for: workspaceId),
                    isActive: false,
                    source: eventSource
                ),
                transactionEpoch: transactionEpoch
            )
        }
    }

    func restoreFromNativeState(
        for token: WindowToken,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> ParentKind? {
        let restored = windows.restoreFromNativeState(for: token)
        if restored != nil, let workspaceId = workspace(for: token) {
            recordTransaction(
                for: .nativeFullscreenTransition(
                    token: token,
                    workspaceId: workspaceId,
                    monitorId: monitorId(for: workspaceId),
                    isActive: false,
                    source: eventSource
                ),
                transactionEpoch: transactionEpoch
            )
        }
        return restored
    }

    func isNativeFullscreenTemporarilyUnavailable(_ token: WindowToken) -> Bool {
        nativeFullscreenRecord(for: token)?.availability == .temporarilyUnavailable
    }

    private func nativeFullscreenLogicalIdForRead(for token: WindowToken) -> LogicalWindowId? {
        if let logicalId = nativeFullscreenLogicalIdByCurrentToken[token] {
            return logicalId
        }
        return logicalWindowRegistry.resolveForRead(token: token)
    }

    private func nativeFullscreenLogicalIdForWrite(for token: WindowToken) -> LogicalWindowId? {
        logicalWindowRegistry.resolveForWrite(token: token)
    }

    private func resolveNativeFullscreenWriteTarget(
        for token: WindowToken,
        api: String
    ) -> LogicalWindowId? {
        let binding = logicalWindowRegistry.lookup(token: token)
        switch binding {
        case let .current(logicalId):
            return logicalId
        case let .staleAlias(logicalId):
            logNativeFullscreenWriteRejection(
                api: api,
                reason: "stale_alias",
                logicalId: logicalId,
                token: token
            )
            return nil
        case let .retired(logicalId):
            logNativeFullscreenWriteRejection(
                api: api,
                reason: "retired",
                logicalId: logicalId,
                token: token
            )
            return nil
        case .unknown:
            logNativeFullscreenWriteRejection(
                api: api,
                reason: "unknown",
                logicalId: nil,
                token: token
            )
            return nil
        }
    }

    private func logNativeFullscreenWriteRejection(
        api: String,
        reason: String,
        logicalId: LogicalWindowId?,
        token: WindowToken
    ) {
        let summary: String
        if let logicalId,
           let record = logicalWindowRegistry.record(for: logicalId)
        {
            summary = record.debugSummary
        } else if let logicalId {
            summary = "\(logicalId) missing-record"
        } else {
            summary = "pid=\(token.pid) wid=\(token.windowId)"
        }
        nativeFullscreenWriteLog.notice(
            "reject api=\(api, privacy: .public) reason=\(reason, privacy: .public) \(summary, privacy: .public)"
        )
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
        restoreState.nativeFullscreenLedger.upsert(record)
        _ = syncWorkspaceGraphEntry(for: record.logicalId)
    }

    @discardableResult
    private func removeNativeFullscreenRecord(logicalId: LogicalWindowId) -> NativeFullscreenRecord? {
        let record = restoreState.nativeFullscreenLedger.remove(logicalId: logicalId)
        _ = syncWorkspaceGraphEntry(for: logicalId)
        return record
    }

    @discardableResult
    private func removeNativeFullscreenRecord(containing token: WindowToken) -> NativeFullscreenRecord? {
        guard let logicalId = nativeFullscreenLogicalIdForRead(for: token) else {
            return nil
        }
        return removeNativeFullscreenRecord(logicalId: logicalId)
    }

    // Window size-constraint cache lifetime, in seconds. AX size-constraint
    // queries are slow; 5s covers typical interactive windows of layout work
    // without serving values across major app/window state changes.
    static let defaultWindowConstraintCacheLifetimeSeconds: TimeInterval = 5.0

    func cachedConstraints(
        for token: WindowToken,
        maxAge: TimeInterval = WorkspaceManager.defaultWindowConstraintCacheLifetimeSeconds
    ) -> WindowSizeConstraints? {
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
            if !entries(in: id).isEmpty {
                continue
            }
            toRemove.append(id)
        }

        removeWorkspaces(toRemove)
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
            guard entries(in: workspaceId).isEmpty else { return nil }
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
        }

        _cachedSortedWorkspaces = nil
        workspaceIdByName = workspaceIdByName.filter { !toRemove.contains($0.value) }
        invalidateWorkspaceProjectionCaches()
        refreshWorkspaceGraphMetadata()

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
        refreshWorkspaceGraphMetadata()
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
        refreshWorkspaceGraphMetadata()
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

        // Prefer the live FrameReducer's restorable rect; fall back to the
        // captured RestoreSnapshot frame so a record whose `restorable` has
        // not yet been populated (cold start, registry rekey, or epoch ratchet
        // rejected a stale frame) still gets a usable restore target.
        var restoreFrame = frameLedger.state(for: record.logicalId)?.restorable?.rect
            ?? record.restoreSnapshot?.frame

        if let bundleId = record.restoreSnapshot?.replacementMetadata?.bundleId,
           let resolver = capabilityProfileResolverRef
        {
            let facts = WindowRuleFacts(
                appName: nil,
                ax: AXWindowFacts(
                    role: nil,
                    subrole: nil,
                    title: nil,
                    hasCloseButton: false,
                    hasFullscreenButton: false,
                    fullscreenButtonEnabled: nil,
                    hasZoomButton: false,
                    hasMinimizeButton: false,
                    appPolicy: nil,
                    bundleId: bundleId,
                    attributeFetchSucceeded: false
                ),
                sizeConstraints: nil,
                windowServer: nil
            )
            if resolver.resolve(for: facts, level: nil).profile.shouldSkipNativeFullscreenFrameRestore {
                restoreFrame = nil
            }
        } else if let bundleId = record.restoreSnapshot?.replacementMetadata?.bundleId,
                  let bundleProfile = WindowCapabilityProfileResolver.builtInProfile(forBundleId: bundleId),
                  bundleProfile.shouldSkipNativeFullscreenFrameRestore
        {
            restoreFrame = nil
        }

        return NativeFullscreenRestoreContext(
            originalToken: record.originalToken,
            currentToken: record.currentToken,
            workspaceId: record.workspaceId,
            restoreFrame: restoreFrame,
            capturedTopologyProfile: record.restoreSnapshot?.topologyProfile,
            niriState: record.restoreSnapshot?.niriState,
            replacementMetadata: record.restoreSnapshot?.replacementMetadata
        )
    }

    @discardableResult
    func beginNativeFullscreenRestore(forLogicalId logicalId: LogicalWindowId) -> NativeFullscreenRecord? {
        guard let record = nativeFullscreenRecordsByLogicalId[logicalId] else { return nil }
        return beginNativeFullscreenRestore(for: record.currentToken)
    }

    @discardableResult
    func beginNativeFullscreenRestore(
        for token: WindowToken,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> NativeFullscreenRecord? {
        guard let logicalId = resolveNativeFullscreenWriteTarget(
            for: token,
            api: "beginNativeFullscreenRestore"
        ),
              var record = nativeFullscreenRecordsByLogicalId[logicalId]
        else {
            return nil
        }

        let resolvedToken = record.currentToken == token ? record.currentToken : token
        var changed = false
        if record.currentToken != resolvedToken {
            record.currentToken = resolvedToken
            changed = true
        }
        guard record.restoreSnapshot != nil else {
            if record.transition == .restoring {
                changed = ensureNativeFullscreenRestoreInvariant(on: &record) || changed
            }
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
        _ = restoreFromNativeState(
            for: resolvedToken,
            transactionEpoch: transactionEpoch,
            eventSource: eventSource
        )
        return nativeFullscreenRecordsByLogicalId[logicalId]
    }

    @discardableResult
    func finalizeNativeFullscreenRestore(forLogicalId logicalId: LogicalWindowId) -> ParentKind? {
        guard let record = nativeFullscreenRecordsByLogicalId[logicalId] else { return nil }
        return finalizeNativeFullscreenRestore(for: record.currentToken)
    }

    @discardableResult
    func finalizeNativeFullscreenRestore(
        for token: WindowToken,
        transactionEpoch: TransactionEpoch = .invalid,
        eventSource: WMEventSource = .workspaceManager
    ) -> ParentKind? {
        guard let logicalId = resolveNativeFullscreenWriteTarget(
            for: token,
            api: "finalizeNativeFullscreenRestore"
        ),
              let record = nativeFullscreenRecordsByLogicalId[logicalId],
              record.transition == .restoring
        else { return nil }

        let removed = removeNativeFullscreenRecord(logicalId: logicalId)
        if nativeFullscreenRecordsByLogicalId.isEmpty {
            _ = setManagedAppFullscreen(
                false,
                transactionEpoch: transactionEpoch,
                eventSource: eventSource
            )
        }
        markNativeFullscreenLifecycleTransition()
        return removed.flatMap { _ in
            restoreFromNativeState(
                for: record.currentToken,
                transactionEpoch: transactionEpoch,
                eventSource: eventSource
            )
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
            var resolvedFocusLogicalId: LogicalWindowId?
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

        // swiftlint:disable:next function_body_length
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
                let assignment = assignmentSnapshot(
                    manager: manager,
                    workspace: workspace,
                    monitors: monitors
                )
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

            let registry = manager.logicalWindowRegistry
            var rawWindowCandidates = ContiguousArray<omniwm_workspace_session_window_candidate>()
            for workspace in sortedWorkspaces {
                appendWindowCandidates(
                    manager.tiledGraphEntries(in: workspace.id),
                    workspaceId: workspace.id,
                    rawMode: UInt32(OMNIWM_WORKSPACE_SESSION_WINDOW_MODE_TILING),
                    into: &rawWindowCandidates
                )
                appendWindowCandidates(
                    manager.floatingGraphEntries(in: workspace.id),
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
            let pendingTiledLogicalId = resolveLogicalId(
                token: focusSnapshot.pendingTiledToken, registry: registry
            )
            let confirmedTiledLogicalId = resolveLogicalId(
                token: focusSnapshot.confirmedTiledToken, registry: registry
            )
            let confirmedFloatingLogicalId = resolveLogicalId(
                token: focusSnapshot.confirmedFloatingToken, registry: registry
            )
            let rememberedLogicalId = resolveLogicalId(
                token: patch?.rememberedFocusToken, registry: registry
            )

            var rawInput = omniwm_workspace_session_input(
                operation: operation,
                workspace_id: workspaceId.map(encode(uuid:)) ?? zeroUUID(),
                monitor_id: monitorId?.displayId ?? 0,
                focused_workspace_id: focusSnapshot.focusedWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
                pending_tiled_workspace_id: focusSnapshot.pendingTiledWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
                confirmed_tiled_workspace_id: focusSnapshot.confirmedTiledWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
                confirmed_floating_workspace_id: focusSnapshot.confirmedFloatingWorkspaceId
                    .map(encode(uuid:)) ?? zeroUUID(),
                pending_tiled_focus_logical_id: pendingTiledLogicalId.map(encode(logicalId:)) ?? zeroLogicalId(),
                confirmed_tiled_focus_logical_id: confirmedTiledLogicalId.map(encode(logicalId:)) ?? zeroLogicalId(),
                confirmed_floating_focus_logical_id: confirmedFloatingLogicalId.map(encode(logicalId:)) ?? zeroLogicalId(),
                remembered_focus_logical_id: rememberedLogicalId.map(encode(logicalId:)) ?? zeroLogicalId(),
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
                has_pending_tiled_focus_logical_id: pendingTiledLogicalId == nil ? 0 : 1,
                has_confirmed_tiled_focus_logical_id: confirmedTiledLogicalId == nil ? 0 : 1,
                has_confirmed_floating_focus_logical_id: confirmedFloatingLogicalId == nil ? 0 : 1,
                has_remembered_focus_logical_id: rememberedLogicalId == nil ? 0 : 1,
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
                resolved_focus_logical_id: zeroLogicalId(),
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
                has_resolved_focus_logical_id: 0,
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
                    resolvedFocusLogicalId: rawOutput.has_resolved_focus_logical_id == 0
                        ? nil
                        : LogicalWindowId(value: rawOutput.resolved_focus_logical_id.value),
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
            workspace: WorkspaceDescriptor,
            monitors: [Monitor]
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
                let liveOutput = output.rebound(in: Monitor.sortedByPosition(monitors)) ?? output
                return AssignmentSnapshot(
                    rawAssignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SPECIFIC_DISPLAY),
                    specificDisplayId: liveOutput.runtimeDisplayId,
                    specificDisplayName: liveOutput.name
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
            _ entries: [WorkspaceGraph.WindowEntry],
            workspaceId: WorkspaceDescriptor.ID,
            rawMode: UInt32,
            into candidates: inout ContiguousArray<omniwm_workspace_session_window_candidate>
        ) {
            candidates.reserveCapacity(candidates.count + entries.count)
            for (index, entry) in entries.enumerated() {
                let hiddenReasonIsWorkspaceInactive: UInt8 = if case .workspaceInactive = entry.hiddenState?.reason {
                    1
                } else {
                    0
                }

                candidates.append(
                    omniwm_workspace_session_window_candidate(
                        workspace_id: encode(uuid: workspaceId),
                        token: encode(token: entry.token),
                        logical_id: encode(logicalId: entry.logicalId),
                        mode: rawMode,
                        order_index: UInt32(clamping: index),
                        has_hidden_proportional_position: entry.hiddenState?.proportionalPosition == nil ? 0 : 1,
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

        private static func encode(logicalId: LogicalWindowId) -> omniwm_logical_window_id {
            omniwm_logical_window_id(value: logicalId.value)
        }

        private static func zeroLogicalId() -> omniwm_logical_window_id {
            omniwm_logical_window_id(value: 0)
        }

        private static func resolveLogicalId(
            token: WindowToken?,
            registry: any LogicalWindowRegistryReading
        ) -> LogicalWindowId? {
            guard let token else { return nil }
            switch registry.lookup(token: token) {
            case let .current(id), let .staleAlias(id):
                return id
            case .retired, .unknown:
                return nil
            }
        }

        private static func encode(point: CGPoint) -> omniwm_point {
            omniwm_point(x: point.x, y: point.y)
        }
    }
}
