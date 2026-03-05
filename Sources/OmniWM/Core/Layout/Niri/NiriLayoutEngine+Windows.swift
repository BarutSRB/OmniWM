import AppKit
import Foundation

extension NiriLayoutEngine {
    private struct LifecycleRuntimePreparation {
        let context: NiriLayoutZigKernel.LayoutContext
        let snapshot: NiriStateZigKernel.Snapshot
    }

    private func lifecycleContractFailure(
        op: NiriStateZigKernel.MutationOp,
        workspaceId: WorkspaceDescriptor.ID?,
        sourceHandle: WindowHandle? = nil,
        reason: String
    ) -> Never {
        let workspaceDescription = workspaceId.map { String(describing: $0) } ?? "nil"
        let sourceDescription: String
        if let sourceHandle {
            sourceDescription = "pid=\(sourceHandle.pid) id=\(sourceHandle.id)"
        } else {
            sourceDescription = "nil"
        }
        preconditionFailure(
            "Niri lifecycle \(op) contract failed: workspace=\(workspaceDescription), source=\(sourceDescription), reason=\(reason)"
        )
    }

    func updateWindowConstraints(for handle: WindowHandle, constraints: WindowSizeConstraints) {
        guard let node = handleToNode[handle] else { return }
        node.constraints = constraints
    }

    private func prepareLifecycleRuntime(
        workspaceId: WorkspaceDescriptor.ID,
        ensureWorkspaceRoot: Bool
    ) -> LifecycleRuntimePreparation? {
        if ensureWorkspaceRoot {
            _ = ensureRoot(for: workspaceId)
        } else if root(for: workspaceId) == nil {
            return nil
        }

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard let context = prepareSeededRuntimeContext(
            for: workspaceId,
            snapshot: snapshot
        ) else {
            return nil
        }

        return LifecycleRuntimePreparation(context: context, snapshot: snapshot)
    }

    func addWindow(
        handle: WindowHandle,
        to workspaceId: WorkspaceDescriptor.ID,
        afterSelection selectedNodeId: NodeId?,
        focusedHandle: WindowHandle? = nil
    ) -> NiriWindow {
        guard let prepared = prepareLifecycleRuntime(
            workspaceId: workspaceId,
            ensureWorkspaceRoot: true
        ) else {
            lifecycleContractFailure(
                op: .addWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "runtime preparation failed"
            )
        }

        let selectedTarget = NiriStateZigKernel.mutationNodeTarget(
            for: selectedNodeId,
            snapshot: prepared.snapshot
        )

        let focusedWindowIndex: Int
        if let focusedHandle,
           let focusedNode = handleToNode[focusedHandle],
           let resolvedFocusedIndex = prepared.snapshot.windowIndexByNodeId[focusedNode.id]
        {
            focusedWindowIndex = resolvedFocusedIndex
        } else {
            focusedWindowIndex = -1
        }

        let request = NiriStateZigKernel.MutationRequest(
            op: .addWindow,
            maxVisibleColumns: maxVisibleColumns,
            selectedNodeKind: selectedTarget.kind,
            selectedNodeIndex: selectedTarget.index,
            focusedWindowIndex: focusedWindowIndex
        )
        let applyRequest = NiriStateZigKernel.MutationApplyRequest(
            request: request,
            snapshot: prepared.snapshot,
            incomingWindowId: handle.id,
            createdColumnId: UUID(),
            placeholderColumnId: UUID()
        )
        let applyOutcome = NiriStateZigKernel.applyMutation(
            context: prepared.context,
            request: applyRequest
        )
        guard applyOutcome.rc == 0 else {
            lifecycleContractFailure(
                op: .addWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "ctx apply failed rc=\(applyOutcome.rc)"
            )
        }
        guard applyOutcome.applied else {
            lifecycleContractFailure(
                op: .addWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "ctx apply returned applied=false"
            )
        }

        guard let delta = applyOutcome.delta else {
            lifecycleContractFailure(
                op: .addWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "ctx delta missing after apply"
            )
        }

        let projection = NiriStateZigDeltaProjector.project(
            delta: delta,
            workspaceId: workspaceId,
            engine: self,
            additionalHandlesById: [handle.id: handle]
        )
        guard projection.applied else {
            let reason = projection.failureReason ?? "unknown projection failure"
            lifecycleContractFailure(
                op: .addWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "runtime projection failed: \(reason)"
            )
        }
        guard let targetWindow = handleToNode[handle] else {
            lifecycleContractFailure(
                op: .addWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "missing projected incoming window node"
            )
        }

        setRuntimeMirrorState(
            for: workspaceId,
            columnCount: delta.columns.count,
            windowCount: delta.windows.count
        )
        return targetWindow
    }

    func removeWindow(handle: WindowHandle) {
        guard let node = handleToNode[handle] else { return }
        guard let workspaceId = node.findRoot()?.workspaceId else {
            lifecycleContractFailure(
                op: .removeWindow,
                workspaceId: nil,
                sourceHandle: handle,
                reason: "source node has no root workspace"
            )
        }

        guard let prepared = prepareLifecycleRuntime(
            workspaceId: workspaceId,
            ensureWorkspaceRoot: false
        ) else {
            lifecycleContractFailure(
                op: .removeWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "runtime preparation failed"
            )
        }
        guard let sourceWindowIndex = prepared.snapshot.windowIndexByNodeId[node.id] else {
            lifecycleContractFailure(
                op: .removeWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "source window missing from runtime snapshot"
            )
        }

        let request = NiriStateZigKernel.MutationRequest(
            op: .removeWindow,
            sourceWindowIndex: sourceWindowIndex
        )
        let applyRequest = NiriStateZigKernel.MutationApplyRequest(
            request: request,
            snapshot: prepared.snapshot,
            placeholderColumnId: UUID()
        )
        let applyOutcome = NiriStateZigKernel.applyMutation(
            context: prepared.context,
            request: applyRequest
        )
        guard applyOutcome.rc == 0 else {
            lifecycleContractFailure(
                op: .removeWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "ctx apply failed rc=\(applyOutcome.rc)"
            )
        }
        guard applyOutcome.applied else {
            lifecycleContractFailure(
                op: .removeWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "ctx apply returned applied=false"
            )
        }

        guard let delta = applyOutcome.delta else {
            lifecycleContractFailure(
                op: .removeWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "ctx delta missing after apply"
            )
        }

        let projection = NiriStateZigDeltaProjector.project(
            delta: delta,
            workspaceId: workspaceId,
            engine: self
        )
        guard projection.applied else {
            let reason = projection.failureReason ?? "unknown projection failure"
            lifecycleContractFailure(
                op: .removeWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "runtime projection failed: \(reason)"
            )
        }

        setRuntimeMirrorState(
            for: workspaceId,
            columnCount: delta.columns.count,
            windowCount: delta.windows.count
        )
    }

    @discardableResult
    func syncWindows(
        _ handles: [WindowHandle],
        in workspaceId: WorkspaceDescriptor.ID,
        selectedNodeId: NodeId?,
        focusedHandle: WindowHandle? = nil
    ) -> Set<WindowHandle> {
        let root = ensureRoot(for: workspaceId)
        let existingIdSet = root.windowIdSet

        var currentIdSet = Set<UUID>(minimumCapacity: handles.count)
        for handle in handles {
            currentIdSet.insert(handle.id)
        }

        var removedHandles = Set<WindowHandle>()

        for window in root.allWindows {
            if !currentIdSet.contains(window.windowId) {
                removedHandles.insert(window.handle)
                removeWindow(handle: window.handle)
            }
        }

        for handle in handles {
            if !existingIdSet.contains(handle.id) {
                _ = addWindow(
                    handle: handle,
                    to: workspaceId,
                    afterSelection: selectedNodeId,
                    focusedHandle: focusedHandle
                )
            }
        }

        return removedHandles
    }

    func validateSelection(
        _ selectedNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NodeId? {
        guard root(for: workspaceId) != nil else { return nil }
        guard let prepared = prepareLifecycleRuntime(
            workspaceId: workspaceId,
            ensureWorkspaceRoot: false
        ) else {
            return columns(in: workspaceId).first?.firstChild()?.id
        }

        let selectedTarget = NiriStateZigKernel.mutationNodeTarget(
            for: selectedNodeId,
            snapshot: prepared.snapshot
        )
        let request = NiriStateZigKernel.MutationRequest(
            op: .validateSelection,
            selectedNodeKind: selectedTarget.kind,
            selectedNodeIndex: selectedTarget.index
        )
        let outcome = NiriStateZigKernel.applyMutation(
            context: prepared.context,
            request: .init(
                request: request,
                snapshot: prepared.snapshot
            )
        )
        guard outcome.rc == 0 else {
            return columns(in: workspaceId).first?.firstChild()?.id
        }
        return outcome.targetNode?.nodeId
    }

    func fallbackSelectionOnRemoval(
        removing removingNodeId: NodeId,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NodeId? {
        guard root(for: workspaceId) != nil else { return nil }
        guard let prepared = prepareLifecycleRuntime(
            workspaceId: workspaceId,
            ensureWorkspaceRoot: false
        ) else {
            return nil
        }
        guard let sourceWindowIndex = prepared.snapshot.windowIndexByNodeId[removingNodeId] else {
            return nil
        }

        let request = NiriStateZigKernel.MutationRequest(
            op: .fallbackSelectionOnRemoval,
            sourceWindowIndex: sourceWindowIndex
        )
        let outcome = NiriStateZigKernel.applyMutation(
            context: prepared.context,
            request: .init(
                request: request,
                snapshot: prepared.snapshot
            )
        )
        guard outcome.rc == 0 else { return nil }
        return outcome.targetNode?.nodeId
    }

    func updateFocusTimestamp(for nodeId: NodeId) {
        guard let node = findNode(by: nodeId) as? NiriWindow else { return }
        node.lastFocusedTime = Date()
    }

    func updateFocusTimestamp(for handle: WindowHandle) {
        guard let node = findNode(for: handle) else { return }
        node.lastFocusedTime = Date()
    }

    func findMostRecentlyFocusedWindow(
        excluding excludingNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> NiriWindow? {
        let allWindows: [NiriWindow] = if let wsId = workspaceId, let root = root(for: wsId) {
            root.allWindows
        } else {
            Array(roots.values.flatMap(\.allWindows))
        }

        let candidates = allWindows.filter { window in
            window.id != excludingNodeId && window.lastFocusedTime != nil
        }

        return candidates.max { ($0.lastFocusedTime ?? .distantPast) < ($1.lastFocusedTime ?? .distantPast) }
    }

}
