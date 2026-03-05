import AppKit
import Foundation

extension NiriLayoutEngine {
    private struct LifecycleRuntimePreparation {
        let runtimeStore: NiriRuntimeWorkspaceStore
    }

    private func canonicalSelectedNodeId(
        _ selectedNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NodeId? {
        guard let selectedNodeId else { return nil }
        guard runtimeSelectionAnchor(
            selectedNodeId: selectedNodeId,
            workspaceId: workspaceId
        ) != nil else {
            return nil
        }
        return selectedNodeId
    }

    private func lifecycleContractFailure(
        op: NiriStateZigKernel.MutationOp,
        workspaceId: WorkspaceDescriptor.ID?,
        sourceHandle: WindowHandle? = nil,
        reason: String
    ) {
        let workspaceDescription = workspaceId.map { String(describing: $0) } ?? "nil"
        let sourceDescription: String
        if let sourceHandle {
            sourceDescription = "pid=\(sourceHandle.pid) id=\(sourceHandle.id)"
        } else {
            sourceDescription = "nil"
        }
        NSLog(
            "Niri lifecycle %@ contract failed: workspace=%@ source=%@ reason=%@",
            String(describing: op),
            workspaceDescription,
            sourceDescription,
            reason
        )
    }

    private func fallbackAddWindow(
        handle: WindowHandle,
        workspaceId: WorkspaceDescriptor.ID
    ) -> NiriWindow {
        if let existing = handleToNode[handle] {
            return existing
        }

        let root = ensureRoot(for: workspaceId)
        let targetColumn: NiriContainer
        if let claimed = claimEmptyColumnIfWorkspaceEmpty(in: root) {
            targetColumn = claimed
        } else if let first = root.columns.first {
            targetColumn = first
        } else {
            let created = NiriContainer()
            root.appendChild(created)
            targetColumn = created
        }

        let window = NiriWindow(handle: handle)
        targetColumn.appendChild(window)
        targetColumn.setActiveTileIdx(max(0, targetColumn.windowNodes.count - 1))
        updateTabbedColumnVisibility(column: targetColumn)
        handleToNode[handle] = window
        clearRuntimeMirrorState(for: workspaceId)
        return window
    }

    private func fallbackRemoveWindow(
        handle: WindowHandle,
        workspaceId: WorkspaceDescriptor.ID?
    ) {
        closingHandles.remove(handle)
        if let window = handleToNode.removeValue(forKey: handle) {
            window.remove()
        }
        if let workspaceId {
            clearRuntimeMirrorState(for: workspaceId)
        }
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

        return LifecycleRuntimePreparation(
            runtimeStore: runtimeStore(
                for: workspaceId,
                ensureWorkspaceRoot: ensureWorkspaceRoot
            )
        )
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
            return fallbackAddWindow(handle: handle, workspaceId: workspaceId)
        }

        let focusedWindowId: NodeId?
        if let focusedHandle,
           let focusedNode = handleToNode[focusedHandle],
           runtimeWindowView(for: focusedNode.id, in: workspaceId) != nil
        {
            focusedWindowId = focusedNode.id
        } else {
            focusedWindowId = nil
        }
        let sanitizedSelectedNodeId = canonicalSelectedNodeId(
            selectedNodeId,
            in: workspaceId
        )

        let applyOutcome: NiriRuntimeLifecycleOutcome
        switch prepared.runtimeStore.executeLifecycle(
            .addWindow(
                incomingHandle: handle,
                selectedNodeId: sanitizedSelectedNodeId,
                focusedWindowId: focusedWindowId,
                createdColumnId: UUID(),
                placeholderColumnId: UUID()
            )
        ) {
        case let .success(outcome):
            applyOutcome = outcome
        case let .failure(error):
            lifecycleContractFailure(
                op: .addWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "runtime boundary command failed: \(error.description)"
            )
            return fallbackAddWindow(handle: handle, workspaceId: workspaceId)
        }

        guard applyOutcome.rc == 0 else {
            lifecycleContractFailure(
                op: .addWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "runtime command failed rc=\(applyOutcome.rc)"
            )
            return fallbackAddWindow(handle: handle, workspaceId: workspaceId)
        }
        guard applyOutcome.applied else {
            lifecycleContractFailure(
                op: .addWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "runtime command returned applied=false"
            )
            return fallbackAddWindow(handle: handle, workspaceId: workspaceId)
        }

        guard applyOutcome.delta != nil else {
            lifecycleContractFailure(
                op: .addWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "runtime delta missing after apply"
            )
            return fallbackAddWindow(handle: handle, workspaceId: workspaceId)
        }
        guard let targetWindow = handleToNode[handle] else {
            lifecycleContractFailure(
                op: .addWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "missing projected incoming window node"
            )
            return fallbackAddWindow(handle: handle, workspaceId: workspaceId)
        }

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
            fallbackRemoveWindow(handle: handle, workspaceId: nil)
            return
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
            fallbackRemoveWindow(handle: handle, workspaceId: workspaceId)
            return
        }
        guard runtimeWindowView(for: node.id, in: workspaceId) != nil else {
            lifecycleContractFailure(
                op: .removeWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "source window missing from runtime snapshot"
            )
            fallbackRemoveWindow(handle: handle, workspaceId: workspaceId)
            return
        }

        let applyOutcome: NiriRuntimeLifecycleOutcome
        switch prepared.runtimeStore.executeLifecycle(
            .removeWindow(
                sourceWindowId: node.id,
                placeholderColumnId: UUID()
            )
        ) {
        case let .success(outcome):
            applyOutcome = outcome
        case let .failure(error):
            lifecycleContractFailure(
                op: .removeWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "runtime boundary command failed: \(error.description)"
            )
            fallbackRemoveWindow(handle: handle, workspaceId: workspaceId)
            return
        }

        guard applyOutcome.rc == 0 else {
            lifecycleContractFailure(
                op: .removeWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "runtime command failed rc=\(applyOutcome.rc)"
            )
            fallbackRemoveWindow(handle: handle, workspaceId: workspaceId)
            return
        }
        guard applyOutcome.applied else {
            lifecycleContractFailure(
                op: .removeWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "runtime command returned applied=false"
            )
            fallbackRemoveWindow(handle: handle, workspaceId: workspaceId)
            return
        }

        guard applyOutcome.delta != nil else {
            lifecycleContractFailure(
                op: .removeWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "runtime delta missing after apply"
            )
            fallbackRemoveWindow(handle: handle, workspaceId: workspaceId)
            return
        }
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
        let sanitizedSelectedNodeId = canonicalSelectedNodeId(
            selectedNodeId,
            in: workspaceId
        )

        let outcome: NiriRuntimeLifecycleOutcome
        switch prepared.runtimeStore.executeLifecycle(
            .validateSelection(
                selectedNodeId: sanitizedSelectedNodeId,
                focusedWindowId: nil
            )
        ) {
        case let .success(resolved):
            outcome = resolved
        case .failure:
            return columns(in: workspaceId).first?.firstChild()?.id
        }

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
        guard runtimeWindowView(for: removingNodeId, in: workspaceId) != nil else {
            return nil
        }

        let outcome: NiriRuntimeLifecycleOutcome
        switch prepared.runtimeStore.executeLifecycle(
            .fallbackSelectionOnRemoval(sourceWindowId: removingNodeId)
        ) {
        case let .success(resolved):
            outcome = resolved
        case .failure:
            return nil
        }

        guard outcome.rc == 0 else { return nil }
        return outcome.targetNode?.nodeId
    }

    func updateFocusTimestamp(for nodeId: NodeId) {
        for workspaceId in roots.keys {
            if let node = runtimeWindowNode(for: nodeId, in: workspaceId) {
                node.lastFocusedTime = Date()
                return
            }
        }
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
