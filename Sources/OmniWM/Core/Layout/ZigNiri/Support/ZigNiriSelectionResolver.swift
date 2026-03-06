import Foundation

enum ZigNiriSelectionResolver {
    static func preferredWindowId(
        in column: ZigNiriColumnView,
        focusedWindowId: NodeId?
    ) -> NodeId? {
        if let focusedWindowId,
           column.windowIds.contains(focusedWindowId)
        {
            return focusedWindowId
        }

        if let activeIndex = column.activeWindowIndex,
           column.windowIds.indices.contains(activeIndex)
        {
            return column.windowIds[activeIndex]
        }

        return column.windowIds.first
    }

    static func actionableWindowId(
        for selectedNodeId: NodeId?,
        in view: ZigNiriWorkspaceView
    ) -> NodeId? {
        if let selectedNodeId,
           view.windowsById[selectedNodeId] != nil
        {
            return selectedNodeId
        }

        if let selectedNodeId,
           let column = view.columns.first(where: { $0.nodeId == selectedNodeId }),
           !column.windowIds.isEmpty
        {
            return preferredWindowId(
                in: column,
                focusedWindowId: view.selection?.focusedWindowId
            )
        }

        if let focusedWindowId = view.selection?.focusedWindowId,
           view.windowsById[focusedWindowId] != nil
        {
            return focusedWindowId
        }

        if let selectedWindowId = view.selection?.selectedNodeId,
           view.windowsById[selectedWindowId] != nil
        {
            return selectedWindowId
        }

        return view.columns.first?.windowIds.first
    }
}
