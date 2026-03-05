import Foundation

extension NiriLayoutEngine {
    func setRuntimeMirrorState(
        for workspaceId: WorkspaceDescriptor.ID,
        columnCount: Int,
        windowCount: Int
    ) {
        runtimeMirrorStates[workspaceId] = RuntimeMirrorState(
            isSeeded: true,
            columnCount: columnCount,
            windowCount: windowCount
        )
    }

    func prepareSeededRuntimeContext(
        for workspaceId: WorkspaceDescriptor.ID,
        snapshot: NiriStateZigKernel.Snapshot
    ) -> NiriLayoutZigKernel.LayoutContext? {
        guard let context = ensureLayoutContext(for: workspaceId) else {
            return nil
        }
        if let mirror = runtimeMirrorStates[workspaceId], mirror.isSeeded {
            return context
        }

        let seedRC = NiriStateZigKernel.seedRuntimeState(
            context: context,
            snapshot: snapshot
        )
        guard seedRC == 0 else {
            return nil
        }

        setRuntimeMirrorState(
            for: workspaceId,
            columnCount: snapshot.columns.count,
            windowCount: snapshot.windows.count
        )
        return context
    }

    @discardableResult
    func applyProjectedRuntimeExport(
        context: NiriLayoutZigKernel.LayoutContext,
        workspaceId: WorkspaceDescriptor.ID,
        delta: NiriStateZigKernel.DeltaExport? = nil,
        refreshMirrorStateFromExport: Bool = true
    ) -> NiriStateZigKernel.DeltaExport? {
        let resolvedDelta: NiriStateZigKernel.DeltaExport
        if let delta {
            resolvedDelta = delta
        } else {
            let exported = NiriStateZigKernel.exportDelta(context: context)
            guard exported.rc == 0 else {
                return nil
            }
            resolvedDelta = exported.export
        }

        let projection = NiriStateZigDeltaProjector.project(
            delta: resolvedDelta,
            workspaceId: workspaceId,
            engine: self
        )
        guard projection.applied else {
            return nil
        }

        if refreshMirrorStateFromExport {
            setRuntimeMirrorState(
                for: workspaceId,
                columnCount: resolvedDelta.columns.count,
                windowCount: resolvedDelta.windows.count
            )
        }

        return resolvedDelta
    }

    func navigationRefreshColumnIds(
        sourceColumnId: NodeId?,
        targetColumnId: NodeId?
    ) -> [NodeId] {
        var refreshColumnIds: [NodeId] = []
        if let sourceColumnId {
            refreshColumnIds.append(sourceColumnId)
        }
        if let targetColumnId, !refreshColumnIds.contains(targetColumnId) {
            refreshColumnIds.append(targetColumnId)
        }
        return refreshColumnIds
    }

}
