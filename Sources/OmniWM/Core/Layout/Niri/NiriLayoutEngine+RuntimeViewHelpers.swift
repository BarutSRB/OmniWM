import Foundation

extension NiriLayoutEngine {
    func runtimeWindowView(
        for windowId: NodeId,
        in workspaceId: WorkspaceDescriptor.ID,
        view: NiriRuntimeWorkspaceView? = nil
    ) -> NiriRuntimeWorkspaceView.WindowView? {
        let resolvedView = view ?? runtimeWorkspaceView(for: workspaceId)
        return resolvedView?.window(for: windowId)
    }

    func runtimeColumnView(
        for columnId: NodeId,
        in workspaceId: WorkspaceDescriptor.ID,
        view: NiriRuntimeWorkspaceView? = nil
    ) -> NiriRuntimeWorkspaceView.ColumnView? {
        let resolvedView = view ?? runtimeWorkspaceView(for: workspaceId)
        return resolvedView?.column(for: columnId)
    }

    func runtimeWindowNode(
        for windowId: NodeId,
        in workspaceId: WorkspaceDescriptor.ID,
        view: NiriRuntimeWorkspaceView? = nil
    ) -> NiriWindow? {
        guard let windowView = runtimeWindowView(
            for: windowId,
            in: workspaceId,
            view: view
        ),
            let handle = windowView.handle
        else {
            return nil
        }
        return handleToNode[handle]
    }

    func runtimeColumnNode(
        for columnId: NodeId,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NiriContainer? {
        root(for: workspaceId)?.columns.first(where: { $0.id == columnId })
    }

    func runtimeSelectionAnchor(
        selectedNodeId: NodeId?,
        workspaceId: WorkspaceDescriptor.ID,
        view: NiriRuntimeWorkspaceView? = nil
    ) -> NiriRuntimeSelectionAnchor? {
        guard let selectedNodeId else { return nil }
        let resolvedView = view ?? runtimeWorkspaceView(for: workspaceId)
        if let window = resolvedView?.window(for: selectedNodeId) {
            return .window(windowId: window.windowId, columnId: window.columnId)
        }
        if resolvedView?.column(for: selectedNodeId) != nil {
            return .column(columnId: selectedNodeId)
        }
        return nil
    }

    func runtimeSelectionWindowId(
        selectedNodeId: NodeId?,
        workspaceId: WorkspaceDescriptor.ID,
        view: NiriRuntimeWorkspaceView? = nil
    ) -> NodeId? {
        switch runtimeSelectionAnchor(
            selectedNodeId: selectedNodeId,
            workspaceId: workspaceId,
            view: view
        ) {
        case let .window(windowId, _):
            return windowId
        default:
            return nil
        }
    }

    func runtimeSelectedColumnId(
        selectedNodeId: NodeId?,
        workspaceId: WorkspaceDescriptor.ID,
        view: NiriRuntimeWorkspaceView? = nil
    ) -> NodeId? {
        switch runtimeSelectionAnchor(
            selectedNodeId: selectedNodeId,
            workspaceId: workspaceId,
            view: view
        ) {
        case let .window(_, columnId):
            return columnId
        case let .column(columnId):
            return columnId
        default:
            return nil
        }
    }
}
