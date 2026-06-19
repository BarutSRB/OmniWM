// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct InvalidationDomain: OptionSet {
    let rawValue: UInt8

    static let workspace = InvalidationDomain(rawValue: 1 << 0)
    static let layout = InvalidationDomain(rawValue: 1 << 1)
    static let focus = InvalidationDomain(rawValue: 1 << 2)
    static let fullscreen = InvalidationDomain(rawValue: 1 << 3)

    static let layoutCommit: InvalidationDomain = [.workspace, .layout, .fullscreen]
    static let focusCommit: InvalidationDomain = .focus
}

struct InvalidationMarks: Equatable {
    var workspace: UInt64 = 0
    var layout: UInt64 = 0
    var focus: UInt64 = 0
    var fullscreen: UInt64 = 0

    mutating func record(_ seq: UInt64, domains: InvalidationDomain) {
        if domains.contains(.workspace) { workspace = seq }
        if domains.contains(.layout) { layout = seq }
        if domains.contains(.focus) { focus = seq }
        if domains.contains(.fullscreen) { fullscreen = seq }
    }

    func isCurrent(_ plannedSeq: UInt64, domains: InvalidationDomain) -> Bool {
        if domains.contains(.workspace), workspace > plannedSeq { return false }
        if domains.contains(.layout), layout > plannedSeq { return false }
        if domains.contains(.focus), focus > plannedSeq { return false }
        if domains.contains(.fullscreen), fullscreen > plannedSeq { return false }
        return true
    }

    func merged(with other: InvalidationMarks) -> InvalidationMarks {
        InvalidationMarks(
            workspace: max(workspace, other.workspace),
            layout: max(layout, other.layout),
            focus: max(focus, other.focus),
            fullscreen: max(fullscreen, other.fullscreen)
        )
    }
}

@MainActor
final class WorldStore {
    private let model = WindowModel()
    private let trace = ReconcileTraceRecorder()
    private let nowProvider: () -> Date
    private(set) var seq: UInt64 = 0
    private(set) var invariantViolationCounts: [String: Int] = [:]
    private(set) var focus = FocusSessionSnapshot()
    private(set) var viewports: [WorkspaceDescriptor.ID: ViewportState] = [:]
    private(set) var scratchpadToken: WindowToken?
    private(set) var monitorSessions: [Monitor.ID: MonitorSession] = [:]
    private(set) var spaceTopology = SpaceTopology()
    private(set) var niriEngine: NiriLayoutEngine?
    private(set) var dwindleEngine: DwindleLayoutEngine?
    private(set) var epochMarks = InvalidationMarks()
    private var broadcastMarks = InvalidationMarks()
    private var workspaceMarks: [WorkspaceDescriptor.ID: InvalidationMarks] = [:]
    private var commitDepth = 0

    var isEngineMutationSanctioned: Bool {
        commitDepth > 0
    }

    private func pushEngineSanction() {
        let sanctioned = isEngineMutationSanctioned
        niriEngine?.isMutationSanctioned = sanctioned
        dwindleEngine?.isMutationSanctioned = sanctioned
    }

    init(nowProvider: @escaping () -> Date = Date.init) {
        self.nowProvider = nowProvider
    }

    @discardableResult
    func commit(
        _ event: WMEvent,
        monitors: [Monitor],
        snapshot: () -> ReconcileSnapshot,
        preMutate: () -> Void = {},
        resolvePlan: (ActionPlan, WindowToken?) -> ActionPlan
    ) -> ReconcileTxn {
        commitDepth += 1
        pushEngineSanction()
        defer {
            commitDepth -= 1
            pushEngineSanction()
        }
        seq &+= 1
        let committedSeq = seq

        preMutate()
        applyWindowMutation(event, phase: .beforePlan, monitors: monitors)
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
        applyWindowMutation(event, phase: .afterPlan, monitors: monitors)

        let committedSnapshot = snapshot()
        let invariantViolations = commitDepth == 1
            ? InvariantChecks.validate(snapshot: committedSnapshot)
            : []
        var tracedPlan = resolvedPlan
        if !invariantViolations.isEmpty {
            tracedPlan.notes.append(contentsOf: invariantViolations.map(\.traceNote))
            for violation in invariantViolations {
                invariantViolationCounts[violation.code, default: 0] += 1
            }
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

    func invariantViolationCountsDump() -> String {
        guard !invariantViolationCounts.isEmpty else { return "clean" }
        return invariantViolationCounts.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }

    func noteInvalidation(workspaceId: WorkspaceDescriptor.ID?, domains: InvalidationDomain) {
        seq &+= 1
        epochMarks.record(seq, domains: domains)
        if let workspaceId {
            workspaceMarks[workspaceId, default: InvalidationMarks()].record(seq, domains: domains)
        } else {
            broadcastMarks.record(seq, domains: domains)
        }
    }

    func invalidationMarks(for workspaceId: WorkspaceDescriptor.ID) -> InvalidationMarks {
        broadcastMarks.merged(with: workspaceMarks[workspaceId] ?? InvalidationMarks())
    }

    func isSeqCurrent(
        _ plannedSeq: UInt64,
        for workspaceId: WorkspaceDescriptor.ID,
        domains: InvalidationDomain
    ) -> Bool {
        invalidationMarks(for: workspaceId).isCurrent(plannedSeq, domains: domains)
    }

    func isSeqEpochCurrent(_ plannedSeq: UInt64, domains: InvalidationDomain) -> Bool {
        epochMarks.isCurrent(plannedSeq, domains: domains)
    }

    func removeInvalidationMarks<S: Sequence>(for workspaceIds: S) where S.Element == WorkspaceDescriptor.ID {
        for workspaceId in workspaceIds {
            workspaceMarks.removeValue(forKey: workspaceId)
        }
    }

    private enum MutationPhase {
        case beforePlan
        case afterPlan
    }

    private func applyWindowMutation(_ event: WMEvent, phase: MutationPhase, monitors: [Monitor]) {
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
            reconcileNiriMembership(for: token, keeping: mode == .tiling ? workspaceId : nil)

        case let .windowRekeyed(from, to, workspaceId, _, _, newAXRef, metadata, _):
            guard phase == .beforePlan else { return }
            model.rekeyWindow(
                from: from,
                to: to,
                newAXRef: newAXRef,
                managedReplacementMetadata: metadata
            )
            _ = niriEngine?.rekeyWindow(from: from, to: to)
            _ = dwindleEngine?.rekeyWindow(from: from, to: to, in: workspaceId)

        case let .windowRemoved(token, _, _):
            guard phase == .afterPlan else { return }
            model.removeWindow(key: token)
            reconcileNiriMembership(for: token, keeping: nil)

        case let .workspaceAssigned(token, _, to, _, _):
            guard phase == .beforePlan else { return }
            updateWorkspace(for: token, workspace: to)

        case let .windowModeChanged(token, _, _, mode, _):
            guard phase == .beforePlan else { return }
            setMode(mode, for: token)

        case let .floatingGeometryUpdated(token, _, referenceMonitorId, frame, normalizedOrigin, restoreToFloating, _):
            guard phase == .beforePlan else { return }
            model.setFloatingState(
                .init(
                    lastFrame: frame,
                    normalizedOrigin: normalizedOrigin,
                    referenceMonitorId: referenceMonitorId,
                    restoreToFloating: restoreToFloating
                ),
                for: token
            )

        case let .floatingStateChanged(token, _, state, _):
            guard phase == .beforePlan else { return }
            model.setFloatingState(state, for: token)

        case let .manualLayoutOverrideChanged(token, _, layoutOverride, _):
            guard phase == .beforePlan else { return }
            model.setManualLayoutOverride(layoutOverride, for: token)

        case let .niriPlacementsResolved(placements, _):
            guard phase == .beforePlan else { return }
            for (token, placement) in placements {
                guard let entry = model.entry(for: token), entry.mode == .tiling else { continue }
                var restoreIntent = StateReducer.restoreIntent(for: entry, monitors: monitors)
                guard restoreIntent.niriPlacement != placement else { continue }
                restoreIntent.niriPlacement = placement
                model.setRestoreIntent(restoreIntent, for: token)
            }

        case let .hiddenStateChanged(token, _, _, hiddenState, _):
            guard phase == .beforePlan else { return }
            model.setHiddenState(hiddenState, for: token)

        case let .nativeFullscreenTransition(token, _, _, change, _):
            guard phase == .beforePlan else { return }
            switch change {
            case let .suspended(reason):
                model.setLayoutReason(reason, for: token)
            case .restored:
                model.restoreFromNativeState(for: token)
            }

        case let .managedReplacementMetadataChanged(token, _, _, metadata, _):
            guard phase == .beforePlan else { return }
            model.setManagedReplacementMetadata(metadata, for: token)

        case let .scratchpadChanged(token, _):
            guard phase == .beforePlan else { return }
            scratchpadToken = token

        case let .visibleWorkspacesChanged(sessions, _):
            guard phase == .beforePlan else { return }
            monitorSessions = sessions

        case let .spaceTopologyChanged(topology, _):
            guard phase == .beforePlan else { return }
            spaceTopology = topology

        case .activeSpaceChanged,
             .focusForgotten,
             .focusLeaseChanged,
             .focusRemembered,
             .interactionMonitorChanged,
             .layoutOperationPerformed,
             .managedFocusCancelled,
             .managedFocusConfirmed,
             .managedFocusRequested,
             .nativeFullscreenPlaceholderSelected,
             .nonManagedFocusChanged,
             .nonManagedFocusTargetChanged,
             .selectionChanged,
             .suppressedFocusChanged,
             .systemModalFocusChanged,
             .systemSleep,
             .systemWake,
             .topologyChanged,
             .userCommand,
             .viewportChanged,
             .viewportCommitted,
             .viewportForgotten,
             .workspaceFocusCleared:
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

    func entry(for token: WindowToken) -> WindowState? {
        model.entry(for: token)
    }

    func entry(for handle: WindowHandle) -> WindowState? {
        model.entry(for: handle)
    }

    func entry(forPid pid: pid_t, windowId: Int) -> WindowState? {
        model.entry(forPid: pid, windowId: windowId)
    }

    func entry(forWindowId windowId: Int) -> WindowState? {
        model.entry(forWindowId: windowId)
    }

    func entry(forWindowId windowId: Int, inVisibleWorkspaces visibleIds: Set<WorkspaceDescriptor.ID>) -> WindowState? {
        model.entry(forWindowId: windowId, inVisibleWorkspaces: visibleIds)
    }

    func entries(forPid pid: pid_t) -> [WindowState] {
        model.entries(forPid: pid)
    }

    func windows(in workspace: WorkspaceDescriptor.ID) -> [WindowState] {
        model.windows(in: workspace)
    }

    func windows(in workspace: WorkspaceDescriptor.ID, mode: TrackedWindowMode) -> [WindowState] {
        model.windows(in: workspace, mode: mode)
    }

    func allEntries() -> [WindowState] {
        model.allEntries()
    }

    func allEntries(mode: TrackedWindowMode) -> [WindowState] {
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

    func floatingState(for token: WindowToken) -> FloatingState? {
        model.floatingState(for: token)
    }

    func manualLayoutOverride(for token: WindowToken) -> ManualWindowOverride? {
        model.manualLayoutOverride(for: token)
    }

    func hiddenState(for token: WindowToken) -> HiddenState? {
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

    func observedMinSize(for token: WindowToken) -> CGSize? {
        model.observedMinSize(for: token)
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
        assertInCommit("setRestoreIntent")
        model.setRestoreIntent(intent, for: token)
    }

    func updateWorkspace(for token: WindowToken, workspace: WorkspaceDescriptor.ID) {
        assertInCommit("updateWorkspace")
        model.updateWorkspace(for: token, workspace: workspace)
        reconcileNiriMembership(for: token, keeping: model.mode(for: token) == .tiling ? workspace : nil)
    }

    func setMode(_ mode: TrackedWindowMode, for token: WindowToken) {
        assertInCommit("setMode")
        model.setMode(mode, for: token)
        reconcileNiriMembership(for: token, keeping: mode == .tiling ? model.workspace(for: token) : nil)
    }

    func setFloatingState(_ state: FloatingState?, for token: WindowToken) {
        assertInCommit("setFloatingState")
        model.setFloatingState(state, for: token)
    }

    func applyFocusSession(_ focusSession: FocusSessionSnapshot) {
        assertInCommit("applyFocusSession")
        focus = focusSession
    }

    @discardableResult
    func updateFocus<T>(_ mutate: (inout FocusSessionSnapshot) -> T) -> T {
        assertInCommit("updateFocus")
        return mutate(&focus)
    }

    private func reconcileNiriMembership(
        for token: WindowToken,
        keeping authoritativeWorkspaceId: WorkspaceDescriptor.ID?
    ) {
        guard let engine = niriEngine else { return }
        for staleWorkspaceId in engine.workspaceIds(containing: token)
            where staleWorkspaceId != authoritativeWorkspaceId
        {
            repairViewportSelection(in: staleWorkspaceId, removing: token, engine: engine)
            engine.removeWindow(token: token, in: staleWorkspaceId)
        }
    }

    private func repairViewportSelection(
        in workspaceId: WorkspaceDescriptor.ID,
        removing token: WindowToken,
        engine: NiriLayoutEngine
    ) {
        guard let node = engine.findNode(for: token, in: workspaceId),
              var state = viewports[workspaceId],
              state.selectedNodeId == node.id
        else { return }
        state.selectedNodeId = engine.fallbackSelectionOnRemoval(removing: node.id, in: workspaceId)
        applyViewportPlan(.set(workspaceId: workspaceId, state: state))
    }

    func layoutTopology(for workspaceId: WorkspaceDescriptor.ID) -> LayoutTopology {
        LayoutTopology(
            columns: niriEngine?.topologyColumns(in: workspaceId) ?? [],
            dwindleFullscreenTokens: dwindleEngine?.fullscreenTokens(in: workspaceId) ?? []
        )
    }

    func installNiriEngine(_ engine: NiriLayoutEngine?) {
        engine?.isMutationSanctioned = isEngineMutationSanctioned
        niriEngine = engine
    }

    func installDwindleEngine(_ engine: DwindleLayoutEngine?) {
        engine?.isMutationSanctioned = isEngineMutationSanctioned
        dwindleEngine = engine
    }

    func applyViewportPlan(_ viewportPlan: ViewportPlan) {
        assertInCommit("applyViewportPlan")
        switch viewportPlan {
        case let .set(workspaceId, state):
            viewports[workspaceId] = state
        case let .remove(workspaceIds):
            for workspaceId in workspaceIds {
                viewports.removeValue(forKey: workspaceId)
            }
        }
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
        model.confirmedMissingKeys(
            keys: activeKeys,
            requiredConsecutiveMisses: requiredConsecutiveMisses,
            spaceTopology: spaceTopology
        )
    }
}
