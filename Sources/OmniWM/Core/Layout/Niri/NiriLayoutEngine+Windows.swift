import AppKit
import Foundation

extension NiriLayoutEngine {
    func hiddenWindowHandles(
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        workingFrame: CGRect? = nil,
        gaps: CGFloat = 0
    ) -> [WindowToken: HideSide] {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return [:] }

        guard let workingFrame else {
            return [:]
        }

        let viewOffset = state.viewOffsetPixels.current()
        let viewLeft = -viewOffset
        let viewRight = viewLeft + workingFrame.width

        var columnPositions = [CGFloat]()
        columnPositions.reserveCapacity(cols.count)
        var runningX: CGFloat = 0
        for column in cols {
            columnPositions.append(runningX)
            runningX += column.cachedWidth + gaps
        }

        var hiddenHandles = [WindowToken: HideSide]()
        for (colIdx, column) in cols.enumerated() {
            let colX = columnPositions[colIdx]
            let colRight = colX + column.cachedWidth

            if colRight <= viewLeft {
                for window in column.windowNodes {
                    hiddenHandles[window.token] = .left
                }
            } else if colX >= viewRight {
                for window in column.windowNodes {
                    hiddenHandles[window.token] = .right
                }
            } else {
                for window in column.windowNodes {
                    if let windowFrame = window.renderedFrame ?? window.frame {
                        let visibleWidth = min(windowFrame.maxX, workingFrame.maxX) - max(
                            windowFrame.minX,
                            workingFrame.minX
                        )
                        if visibleWidth < 1.0 {
                            let side: HideSide = windowFrame.midX < workingFrame.midX ? .left : .right
                            hiddenHandles[window.token] = side
                        }
                    }
                }
            }
        }
        return hiddenHandles
    }

    func updateWindowConstraints(for token: WindowToken, constraints: WindowSizeConstraints) {
        guard let node = tokenToNode[token] else { return }
        node.constraints = constraints.normalized()
    }

    func addWindow(
        token: WindowToken,
        to workspaceId: WorkspaceDescriptor.ID,
        afterSelection selectedNodeId: NodeId?,
        focusedToken: WindowToken? = nil
    ) -> NiriWindow {
        let root = ensureRoot(for: workspaceId)

        if let existingColumn = claimEmptyColumnIfWorkspaceEmpty(in: root) {
            initializeNewColumnWidth(existingColumn, in: workspaceId)
            let windowNode = NiriWindow(token: token)
            existingColumn.appendChild(windowNode)
            tokenToNode[token] = windowNode
            return windowNode
        }

        let referenceColumn: NiriContainer? = if let focusedToken,
                                                 let focusedNode = tokenToNode[focusedToken],
                                                 let col = column(of: focusedNode)
        {
            col
        } else if let selId = selectedNodeId,
                  let selNode = root.findNode(by: selId),
                  let col = column(of: selNode)
        {
            col
        } else {
            root.columns.last
        }

        let newColumn = NiriContainer()
        initializeNewColumnWidth(newColumn, in: workspaceId)
        if let refCol = referenceColumn {
            root.insertAfter(newColumn, reference: refCol)
        } else {
            root.appendChild(newColumn)
        }

        let windowNode = NiriWindow(token: token)
        newColumn.appendChild(windowNode)

        tokenToNode[token] = windowNode

        return windowNode
    }

    func removeWindow(token: WindowToken) {
        guard let node = tokenToNode[token] else { return }
        closingTokens.remove(token)

        guard let column = node.parent as? NiriContainer else { return }

        column.adjustActiveTileIdxForRemoval(of: node)

        node.remove()
        tokenToNode.removeValue(forKey: token)

        if column.displayMode == .tabbed, !column.children.isEmpty {
            column.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: column)
        }

        if column.children.isEmpty {
            let root = column.parent as? NiriRoot
            column.remove()

            if let root {
                let cols = root.columns
                if cols.isEmpty {
                    let emptyColumn = NiriContainer()
                    root.appendChild(emptyColumn)
                } else {
                    for col in cols {
                        col.cachedWidth = 0
                    }
                }
            }
        }
    }

    @discardableResult
    func rekeyWindow(from oldToken: WindowToken, to newToken: WindowToken) -> Bool {
        guard oldToken != newToken,
              tokenToNode[newToken] == nil,
              let node = tokenToNode.removeValue(forKey: oldToken)
        else {
            return false
        }

        node.token = newToken
        tokenToNode[newToken] = node

        if let frame = framePool.removeValue(forKey: oldToken) {
            framePool[newToken] = frame
        }
        if let hiddenSide = hiddenPool.removeValue(forKey: oldToken) {
            hiddenPool[newToken] = hiddenSide
        }
        if closingTokens.remove(oldToken) != nil {
            closingTokens.insert(newToken)
        }

        node.invalidateChildrenCache()
        return true
    }

    @discardableResult
    func syncWindows(
        _ tokens: [WindowToken],
        in workspaceId: WorkspaceDescriptor.ID,
        selectedNodeId: NodeId?,
        focusedToken: WindowToken? = nil
    ) -> Set<WindowToken> {
        let root = ensureRoot(for: workspaceId)
        let existingIdSet = root.windowIdSet

        let currentIdSet = Set(tokens)

        var removedHandles = Set<WindowToken>()

        for window in root.allWindows {
            if !currentIdSet.contains(window.token) {
                removedHandles.insert(window.token)
                removeWindow(token: window.token)
            }
        }

        for token in tokens {
            if !existingIdSet.contains(token) {
                _ = addWindow(
                    token: token,
                    to: workspaceId,
                    afterSelection: selectedNodeId,
                    focusedToken: focusedToken
                )
            }
        }

        return removedHandles
    }

    func validateSelection(
        _ selectedNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NodeId? {
        guard let selectedId = selectedNodeId else {
            return columns(in: workspaceId).first?.firstChild()?.id
        }

        guard let root = roots[workspaceId],
              let existingNode = root.findNode(by: selectedId)
        else {
            return columns(in: workspaceId).first?.firstChild()?.id
        }

        return existingNode.id
    }

    func fallbackSelectionOnRemoval(
        removing removingNodeId: NodeId,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NodeId? {
        guard let root = roots[workspaceId],
              let removingNode = root.findNode(by: removingNodeId)
        else {
            return nil
        }

        if let nextSibling = removingNode.nextSibling() {
            return nextSibling.id
        }

        if let prevSibling = removingNode.prevSibling() {
            return prevSibling.id
        }

        let cols = columns(in: workspaceId)
        if let currentCol = column(of: removingNode),
           let currentIdx = cols.firstIndex(where: { $0 === currentCol })
        {
            if currentIdx > 0, let window = cols[currentIdx - 1].firstChild() {
                return window.id
            }
            if currentIdx < cols.count - 1, let window = cols[currentIdx + 1].firstChild() {
                return window.id
            }
        }

        for col in cols {
            if col.id != column(of: removingNode)?.id {
                if let firstWindow = col.firstChild() {
                    return firstWindow.id
                }
            }
        }

        return nil
    }

    func updateFocusTimestamp(for nodeId: NodeId) {
        guard let node = findNode(by: nodeId) as? NiriWindow else { return }
        node.lastFocusedTime = Date()
    }

    func updateFocusTimestamp(for token: WindowToken) {
        guard let node = findNode(for: token) else { return }
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
