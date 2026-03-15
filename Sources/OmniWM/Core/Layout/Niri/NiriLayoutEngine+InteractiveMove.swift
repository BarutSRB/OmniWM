import AppKit
import Foundation

extension NiriLayoutEngine {
    func interactiveMoveBegin(
        windowId: NodeId,
        windowHandle: WindowHandle,
        startLocation: CGPoint,
        isInsertMode: Bool = false,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard interactiveMove == nil else { return false }
        guard interactiveResize == nil else { return false }

        guard let windowNode = findNode(by: windowId) as? NiriWindow else { return false }
        guard let column = findColumn(containing: windowNode, in: workspaceId) else { return false }
        guard let colIdx = columnIndex(of: column, in: workspaceId) else { return false }

        if windowNode.isFullscreen {
            return false
        }

        interactiveMove = InteractiveMove(
            windowId: windowId,
            windowHandle: windowHandle,
            workspaceId: workspaceId,
            startMouseLocation: startLocation,
            originalColumnIndex: colIdx,
            originalFrame: windowNode.renderedFrame ?? windowNode.frame ?? .zero,
            isInsertMode: isInsertMode,
            currentHoverTarget: nil
        )

        let cols = columns(in: workspaceId)
        let settings = effectiveSettings(in: workspaceId)
        state.transitionToColumn(
            colIdx,
            columns: cols,
            gap: gaps,
            viewportWidth: workingFrame.width,
            animate: false,
            centerMode: settings.centerFocusedColumn,
            alwaysCenterSingleColumn: settings.alwaysCenterSingleColumn
        )

        return true
    }

    func interactiveMoveUpdate(
        currentLocation: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> MoveHoverTarget? {
        guard var move = interactiveMove else { return nil }

        let dragDistance = hypot(
            currentLocation.x - move.startMouseLocation.x,
            currentLocation.y - move.startMouseLocation.y
        )
        guard dragDistance >= moveConfiguration.dragThreshold else {
            return nil
        }

        let hoverTarget = hitTestMoveTarget(
            point: currentLocation,
            excludingWindowId: move.windowId,
            isInsertMode: move.isInsertMode,
            in: workspaceId
        )

        move.currentHoverTarget = hoverTarget
        interactiveMove = move

        return hoverTarget
    }

    func interactiveMoveEnd(
        at _: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard let move = interactiveMove else { return false }
        defer { interactiveMove = nil }

        guard let target = move.currentHoverTarget else {
            return false
        }

        switch target {
        case let .window(targetNodeId, _, position):
            switch position {
            case .swap:
                return swapWindowsByMove(
                    sourceWindowId: move.windowId,
                    targetWindowId: targetNodeId,
                    in: workspaceId,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps
                )
            case .before, .after:
                return insertWindowByMove(
                    sourceWindowId: move.windowId,
                    targetWindowId: targetNodeId,
                    position: position,
                    in: workspaceId,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps
                )
            }

        case .columnGap, .workspaceEdge:
            return false
        }
    }

    func interactiveMoveCancel() {
        interactiveMove = nil
    }

    func hitTestMoveTarget(
        point: CGPoint,
        excludingWindowId: NodeId,
        isInsertMode: Bool = false,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> MoveHoverTarget? {
        guard let root = roots[workspaceId] else { return nil }

        for column in root.columns {
            for child in column.children {
                guard let window = child as? NiriWindow,
                      window.id != excludingWindowId,
                      let frame = window.renderedFrame ?? window.frame else { continue }

                if frame.contains(point) {
                    let position: InsertPosition = if isInsertMode {
                        point.y < frame.midY ? .before : .after
                    } else {
                        .swap
                    }
                    return .window(
                        nodeId: window.id,
                        handle: window.handle,
                        insertPosition: position
                    )
                }
            }
        }

        return nil
    }

    func swapWindowsByMove(
        sourceWindowId: NodeId,
        targetWindowId: NodeId,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        fromColumnIndex: Int? = nil
    ) -> Bool {
        guard let sourceWindow = findNode(by: sourceWindowId) as? NiriWindow,
              let targetWindow = findNode(by: targetWindowId) as? NiriWindow
        else {
            return false
        }

        guard let sourceColumn = findColumn(containing: sourceWindow, in: workspaceId),
              let targetColumn = findColumn(containing: targetWindow, in: workspaceId)
        else {
            return false
        }

        if sourceColumn.id == targetColumn.id {
            sourceWindow.swapWith(targetWindow)

            if sourceColumn.isTabbed {
                sourceColumn.clampActiveTileIdx()
            }
        } else {
            guard let sourceIdx = sourceColumn.children.firstIndex(where: { $0.id == sourceWindowId }),
                  let targetIdx = targetColumn.children.firstIndex(where: { $0.id == targetWindowId })
            else {
                return false
            }

            let sourceSize = sourceWindow.size
            let sourceHeight = sourceWindow.height
            let targetSize = targetWindow.size
            let targetHeight = targetWindow.height

            sourceWindow.detach()
            targetWindow.detach()

            sourceColumn.insertChild(targetWindow, at: sourceIdx)
            targetColumn.insertChild(sourceWindow, at: targetIdx)

            sourceWindow.size = targetSize
            sourceWindow.height = targetHeight
            targetWindow.size = sourceSize
            targetWindow.height = sourceHeight

            if sourceColumn.isTabbed {
                sourceColumn.clampActiveTileIdx()
            }
            if targetColumn.isTabbed {
                targetColumn.clampActiveTileIdx()
            }
        }

        ensureSelectionVisible(
            node: sourceWindow,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )

        return true
    }

    func insertWindowByMove(
        sourceWindowId: NodeId,
        targetWindowId: NodeId,
        position: InsertPosition,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard let sourceWindow = findNode(by: sourceWindowId) as? NiriWindow,
              let targetWindow = findNode(by: targetWindowId) as? NiriWindow
        else {
            return false
        }

        guard let sourceColumn = findColumn(containing: sourceWindow, in: workspaceId),
              let targetColumn = findColumn(containing: targetWindow, in: workspaceId)
        else {
            return false
        }

        guard let targetIdx = targetColumn.children.firstIndex(where: { $0.id == targetWindowId }) else {
            return false
        }

        let sameColumn = sourceColumn.id == targetColumn.id
        let sourceColumnWillBeEmpty = sourceColumn.children.count == 1 && !sameColumn

        sourceWindow.detach()

        let insertIdx: Int
        if sameColumn {
            let currentTargetIdx = targetColumn.children.firstIndex(where: { $0.id == targetWindowId }) ?? targetIdx
            insertIdx = position == .before ? currentTargetIdx : currentTargetIdx + 1
        } else {
            insertIdx = position == .before ? targetIdx : targetIdx + 1
        }

        targetColumn.insertChild(sourceWindow, at: insertIdx)

        sourceWindow.size = 1.0
        sourceWindow.height = .default

        if sourceColumnWillBeEmpty {
            sourceColumn.remove()
        }

        if sourceColumn.isTabbed {
            sourceColumn.clampActiveTileIdx()
        }
        if targetColumn.isTabbed {
            targetColumn.clampActiveTileIdx()
        }

        ensureSelectionVisible(
            node: sourceWindow,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )

        return true
    }

    func insertionDropzoneFrame(
        targetWindowId: NodeId,
        position: InsertPosition,
        in workspaceId: WorkspaceDescriptor.ID,
        gaps: CGFloat
    ) -> CGRect? {
        guard let targetWindow = findNode(by: targetWindowId) as? NiriWindow,
              let targetFrame = targetWindow.renderedFrame ?? targetWindow.frame,
              let column = findColumn(containing: targetWindow, in: workspaceId)
        else {
            return nil
        }

        let windows = column.windowNodes
        let n = windows.count
        let postInsertionCount = n + 1
        let firstFrame = windows.first?.renderedFrame ?? windows.first?.frame
        let lastFrame = windows.last?.renderedFrame ?? windows.last?.frame
        guard let bottom = firstFrame?.minY, let top = lastFrame?.maxY else { return nil }

        let columnHeight = top - bottom
        let totalGaps = CGFloat(postInsertionCount - 1) * gaps
        let newHeight = max(0, (columnHeight - totalGaps) / CGFloat(postInsertionCount))
        let x = targetFrame.minX
        let width = targetFrame.width

        let y: CGFloat = switch position {
        case .before:
            max(top, targetFrame.minY - gaps - newHeight)
        case .after:
            targetFrame.maxY + gaps
        case .swap:
            targetFrame.minY
        }

        return CGRect(x: x, y: y, width: width, height: newHeight)
    }
}
