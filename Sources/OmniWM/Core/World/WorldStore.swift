import CoreGraphics
import Foundation

@MainActor
final class WorldStore {
    private let model = WindowModel()
    private let trace = ReconcileTraceRecorder()
    private let nowProvider: () -> Date
    private(set) var seq: UInt64 = 0
    private var commitDepth = 0

    init(nowProvider: @escaping () -> Date = Date.init) {
        self.nowProvider = nowProvider
    }

    @discardableResult
    func commit(
        _ event: WMEvent,
        monitors: [Monitor],
        snapshot: () -> ReconcileSnapshot,
        resolvePlan: (ActionPlan, WindowToken?) -> ActionPlan
    ) -> ReconcileTxn {
        commitDepth += 1
        defer { commitDepth -= 1 }
        seq &+= 1
        let committedSeq = seq

        applyWindowMutation(event, phase: .beforePlan)
        let existingEntry = event.token.flatMap { model.entry(for: $0) }
        let normalizedEvent = EventNormalizer.normalize(
            event: event,
            existingEntry: existingEntry,
            monitors: monitors
        )
        let plan = StateReducer.reduce(
            event: normalizedEvent,
            existingEntry: existingEntry,
            currentSnapshot: snapshot(),
            monitors: monitors
        )
        let resolvedPlan = resolvePlan(plan, normalizedEvent.token)
        applyWindowMutation(event, phase: .afterPlan)

        let committedSnapshot = snapshot()
        let invariantViolations = InvariantChecks.validate(snapshot: committedSnapshot)
        var tracedPlan = resolvedPlan
        if !invariantViolations.isEmpty {
            tracedPlan.notes.append(contentsOf: invariantViolations.map(\.traceNote))
            assertionFailure(
                "Reconcile invariants violated after \(event.summary): "
                    + invariantViolations.map(\.code).joined(separator: ",")
            )
        }
        let txn = ReconcileTxn(
            seq: committedSeq,
            timestamp: nowProvider(),
            event: event,
            normalizedEvent: normalizedEvent,
            plan: tracedPlan,
            snapshot: committedSnapshot,
            invariantViolations: invariantViolations
        )
        trace.append(transaction: txn)
        return txn
    }

    func traceRecords() -> [ReconcileTraceRecord] {
        trace.snapshot()
    }

    private enum MutationPhase {
        case beforePlan
        case afterPlan
    }

    private func applyWindowMutation(_ event: WMEvent, phase: MutationPhase) {
        switch event {
        case let .windowAdmitted(token, workspaceId, _, mode, axRef, ruleEffects, metadata, _):
            guard phase == .beforePlan else { return }
            model.upsert(
                window: axRef,
                pid: token.pid,
                windowId: token.windowId,
                workspace: workspaceId,
                mode: mode,
                ruleEffects: ruleEffects,
                managedReplacementMetadata: metadata
            )

        case let .windowRekeyed(from, to, _, _, _, newAXRef, metadata, _):
            guard phase == .beforePlan else { return }
            model.rekeyWindow(
                from: from,
                to: to,
                newAXRef: newAXRef,
                managedReplacementMetadata: metadata
            )

        case let .windowRemoved(token, _, _):
            guard phase == .afterPlan else { return }
            model.removeWindow(key: token)

        case .activeSpaceChanged,
             .floatingGeometryUpdated,
             .focusLeaseChanged,
             .hiddenStateChanged,
             .managedFocusCancelled,
             .managedFocusConfirmed,
             .managedFocusRequested,
             .managedReplacementMetadataChanged,
             .nativeFullscreenTransition,
             .nonManagedFocusChanged,
             .systemSleep,
             .systemWake,
             .topologyChanged,
             .windowModeChanged,
             .workspaceAssigned:
            break
        }
    }

    private func assertInCommit(_ operation: StaticString) {
        assert(commitDepth > 0, "\(operation) must run inside WorldStore.commit")
    }
}

extension WorldStore {
    func handle(for token: WindowToken) -> WindowHandle? {
        model.handle(for: token)
    }

    func entry(for token: WindowToken) -> WindowModel.Entry? {
        model.entry(for: token)
    }

    func entry(for handle: WindowHandle) -> WindowModel.Entry? {
        model.entry(for: handle)
    }

    func entry(forPid pid: pid_t, windowId: Int) -> WindowModel.Entry? {
        model.entry(forPid: pid, windowId: windowId)
    }

    func entry(forWindowId windowId: Int) -> WindowModel.Entry? {
        model.entry(forWindowId: windowId)
    }

    func entry(forWindowId windowId: Int, inVisibleWorkspaces visibleIds: Set<WorkspaceDescriptor.ID>) -> WindowModel.Entry? {
        model.entry(forWindowId: windowId, inVisibleWorkspaces: visibleIds)
    }

    func entries(forPid pid: pid_t) -> [WindowModel.Entry] {
        model.entries(forPid: pid)
    }

    func windows(in workspace: WorkspaceDescriptor.ID) -> [WindowModel.Entry] {
        model.windows(in: workspace)
    }

    func windows(in workspace: WorkspaceDescriptor.ID, mode: TrackedWindowMode) -> [WindowModel.Entry] {
        model.windows(in: workspace, mode: mode)
    }

    func allEntries() -> [WindowModel.Entry] {
        model.allEntries()
    }

    func allEntries(mode: TrackedWindowMode) -> [WindowModel.Entry] {
        model.allEntries(mode: mode)
    }

    func workspace(for token: WindowToken) -> WorkspaceDescriptor.ID? {
        model.workspace(for: token)
    }

    func mode(for token: WindowToken) -> TrackedWindowMode? {
        model.mode(for: token)
    }

    func lifecyclePhase(for token: WindowToken) -> WindowLifecyclePhase? {
        model.lifecyclePhase(for: token)
    }

    func observedState(for token: WindowToken) -> ObservedWindowState? {
        model.observedState(for: token)
    }

    func desiredState(for token: WindowToken) -> DesiredWindowState? {
        model.desiredState(for: token)
    }

    func restoreIntent(for token: WindowToken) -> RestoreIntent? {
        model.restoreIntent(for: token)
    }

    func replacementCorrelation(for token: WindowToken) -> ReplacementCorrelation? {
        model.replacementCorrelation(for: token)
    }

    func managedReplacementMetadata(for token: WindowToken) -> ManagedReplacementMetadata? {
        model.managedReplacementMetadata(for: token)
    }

    func floatingState(for token: WindowToken) -> WindowModel.FloatingState? {
        model.floatingState(for: token)
    }

    func manualLayoutOverride(for token: WindowToken) -> ManualWindowOverride? {
        model.manualLayoutOverride(for: token)
    }

    func hiddenState(for token: WindowToken) -> WindowModel.HiddenState? {
        model.hiddenState(for: token)
    }

    func isHiddenInCorner(_ token: WindowToken) -> Bool {
        model.isHiddenInCorner(token)
    }

    func layoutReason(for token: WindowToken) -> LayoutReason {
        model.layoutReason(for: token)
    }

    func isNativeFullscreenSuspended(_ token: WindowToken) -> Bool {
        model.isNativeFullscreenSuspended(token)
    }

    func cachedConstraints(for token: WindowToken, maxAge: TimeInterval = 5.0) -> WindowSizeConstraints? {
        model.cachedConstraints(for: token, maxAge: maxAge)
    }
}

extension WorldStore {
    func setLifecyclePhase(_ phase: WindowLifecyclePhase, for token: WindowToken) {
        assertInCommit("setLifecyclePhase")
        model.setLifecyclePhase(phase, for: token)
    }

    func setObservedState(_ state: ObservedWindowState, for token: WindowToken) {
        assertInCommit("setObservedState")
        model.setObservedState(state, for: token)
    }

    func setDesiredState(_ state: DesiredWindowState, for token: WindowToken) {
        assertInCommit("setDesiredState")
        model.setDesiredState(state, for: token)
    }

    func setReplacementCorrelation(_ correlation: ReplacementCorrelation?, for token: WindowToken) {
        assertInCommit("setReplacementCorrelation")
        model.setReplacementCorrelation(correlation, for: token)
    }

    func setRestoreIntent(_ intent: RestoreIntent?, for token: WindowToken) {
        model.setRestoreIntent(intent, for: token)
    }

    func updateWorkspace(for token: WindowToken, workspace: WorkspaceDescriptor.ID) {
        model.updateWorkspace(for: token, workspace: workspace)
    }

    func setMode(_ mode: TrackedWindowMode, for token: WindowToken) {
        model.setMode(mode, for: token)
    }

    func setFloatingState(_ state: WindowModel.FloatingState?, for token: WindowToken) {
        model.setFloatingState(state, for: token)
    }

    func setManualLayoutOverride(_ override: ManualWindowOverride?, for token: WindowToken) {
        model.setManualLayoutOverride(override, for: token)
    }

    func setManagedReplacementMetadata(_ metadata: ManagedReplacementMetadata?, for token: WindowToken) {
        model.setManagedReplacementMetadata(metadata, for: token)
    }

    func setHiddenState(_ state: WindowModel.HiddenState?, for token: WindowToken) {
        model.setHiddenState(state, for: token)
    }

    func setLayoutReason(_ reason: LayoutReason, for token: WindowToken) {
        model.setLayoutReason(reason, for: token)
    }

    func restoreFromNativeState(for token: WindowToken) -> ParentKind? {
        model.restoreFromNativeState(for: token)
    }

    func setCachedConstraints(_ constraints: WindowSizeConstraints, for token: WindowToken) {
        model.setCachedConstraints(constraints, for: token)
    }

    @discardableResult
    func setObservedMinSize(_ size: CGSize, for token: WindowToken) -> Bool {
        model.setObservedMinSize(size, for: token)
    }

    func confirmedMissingKeys(
        keys activeKeys: Set<WindowToken>,
        requiredConsecutiveMisses: Int = 1
    ) -> [WindowToken] {
        model.confirmedMissingKeys(keys: activeKeys, requiredConsecutiveMisses: requiredConsecutiveMisses)
    }
}
