import AppKit
import Foundation

extension NiriLayoutEngine {
    struct NiriRemovalResult {
        let removedTokens: Set<WindowToken>
        let removedNodeIds: Set<NodeId>
        let removedColumnIndicesBefore: [Int]
        let activeIndexBefore: Int?
        let activeIndexAfter: Int?
        let finalSelectionId: NodeId?
        let viewportNeedsRecalc: Bool
        let fromIndexForVisibility: Int?
        let visibilityWasCorrected: Bool
    }

    private struct TileRemovalStep {
        var removedTokens: Set<WindowToken> = []
        var removedNodeIds: Set<NodeId> = []
        var removedColumnIndexBefore: Int?
        var fallbackSelectionId: NodeId?
        var viewportNeedsRecalc = false
        var fromIndexForVisibility: Int?
        var visibilityWasCorrected = false
    }

    func updateWindowConstraints(for token: WindowToken, constraints: WindowSizeConstraints) {
        assertSanctionedMutation()
        guard let node = tokenToNode[token] else { return }
        let normalized = constraints.normalized()
        guard node.constraints != normalized else { return }
        node.constraints = normalized
        if let column = node.parent as? NiriContainer, column.cachedWidth > 0 {
            let bounds = column.widthBounds()
            column.cachedWidth = max(column.cachedWidth, bounds.min)
            if let maxWidth = bounds.max {
                column.cachedWidth = min(column.cachedWidth, maxWidth)
            }
        }
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
        assertSanctionedMutation()
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
                for col in root.columns {
                    col.cachedWidth = 0
                }
            }
        }
    }

    func workspaceIds(containing token: WindowToken) -> [WorkspaceDescriptor.ID] {
        roots.compactMap { $0.value.windowIdSet.contains(token) ? $0.key : nil }
    }

    func findNode(for token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> NiriWindow? {
        root(for: workspaceId)?.allWindows.first { $0.token == token }
    }

    func removeWindow(token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        guard let node = findNode(for: token, in: workspaceId),
              let column = node.parent as? NiriContainer else { return }

        column.adjustActiveTileIdxForRemoval(of: node)
        node.remove()

        let remaining = roots.values.lazy.compactMap { root in
            root.allWindows.first { $0.token == token }
        }.first
        if let remaining {
            if tokenToNode[token] === node { tokenToNode[token] = remaining }
        } else {
            closingTokens.remove(token)
            tokenToNode.removeValue(forKey: token)
        }

        if column.displayMode == .tabbed, !column.children.isEmpty {
            column.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: column)
        }

        if column.children.isEmpty {
            let root = column.parent as? NiriRoot
            column.remove()

            if let root {
                for col in root.columns {
                    col.cachedWidth = 0
                }
            }
        }
    }

    @discardableResult
    func removeWindows(
        _ tokens: Set<WindowToken>,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        motion: MotionSnapshot,
        workingFrame: CGRect,
        gaps: CGFloat,
        selectedNodeId: NodeId?,
        removedNodeIds externallyRemovedNodeIds: [NodeId]
    ) -> NiriRemovalResult {
        assertSanctionedMutation()
        guard !tokens.isEmpty,
              let root = root(for: workspaceId)
        else {
            return NiriRemovalResult(
                removedTokens: [],
                removedNodeIds: [],
                removedColumnIndicesBefore: [],
                activeIndexBefore: columns(in: workspaceId).isEmpty ? nil : state.activeColumnIndex,
                activeIndexAfter: columns(in: workspaceId).isEmpty ? nil : state.activeColumnIndex,
                finalSelectionId: nil,
                viewportNeedsRecalc: false,
                fromIndexForVisibility: nil,
                visibilityWasCorrected: false
            )
        }

        let activeIndexBefore = root.columns.isEmpty ? nil : state.activeColumnIndex
        let removalTokens = tokens.intersection(root.windowIdSet)
        guard !removalTokens.isEmpty else {
            return NiriRemovalResult(
                removedTokens: [],
                removedNodeIds: [],
                removedColumnIndicesBefore: [],
                activeIndexBefore: activeIndexBefore,
                activeIndexAfter: root.columns.isEmpty ? nil : state.activeColumnIndex,
                finalSelectionId: nil,
                viewportNeedsRecalc: false,
                fromIndexForVisibility: nil,
                visibilityWasCorrected: false
            )
        }

        let batchRemovedNodeIds = Set(externallyRemovedNodeIds).union(
            removalTokens.compactMap { tokenToNode[$0]?.id }
        )
        var remainingTokens = removalTokens
        var removedTokens: Set<WindowToken> = []
        var removedNodeIds: Set<NodeId> = []
        var removedColumnIndicesBefore: [Int] = []
        var latestFallback: NodeId?
        var viewportNeedsRecalc = false
        var fromIndexForVisibility: Int?
        var visibilityWasCorrected = false

        while let window = root.allWindows.first(where: { remainingTokens.contains($0.token) }) {
            guard let column = column(of: window),
                  let columnIndex = columnIndex(of: column, in: workspaceId),
                  let tileIndex = column.windowNodes.firstIndex(where: { $0 === window })
            else {
                remainingTokens.remove(window.token)
                continue
            }

            let step = removeTileByIdx(
                columnIndex: columnIndex,
                tileIndex: tileIndex,
                in: workspaceId,
                state: &state,
                motion: motion,
                workingFrame: workingFrame,
                gaps: gaps,
                allRemovalTokens: removalTokens,
                allRemovalNodeIds: batchRemovedNodeIds
            )

            removedTokens.formUnion(step.removedTokens)
            removedNodeIds.formUnion(step.removedNodeIds)
            remainingTokens.subtract(step.removedTokens)
            if let removedColumnIndex = step.removedColumnIndexBefore {
                removedColumnIndicesBefore.append(removedColumnIndex)
            }
            if let fallback = step.fallbackSelectionId {
                latestFallback = fallback
            }
            viewportNeedsRecalc = viewportNeedsRecalc || step.viewportNeedsRecalc
            if fromIndexForVisibility == nil {
                fromIndexForVisibility = step.fromIndexForVisibility
            }
            visibilityWasCorrected = visibilityWasCorrected || step.visibilityWasCorrected
        }

        let currentSelection = state.selectedNodeId ?? selectedNodeId
        let finalSelection: NodeId?
        if let currentSelection,
           !batchRemovedNodeIds.contains(currentSelection),
           findNode(by: currentSelection) != nil
        {
            finalSelection = currentSelection
        } else {
            finalSelection = latestFallback
                ?? fallbackSelectionFromActiveColumn(
                    in: workspaceId,
                    activeIndex: state.activeColumnIndex,
                    excluding: batchRemovedNodeIds
                )
                ?? validateSelection(nil, in: workspaceId)
        }

        state.selectedNodeId = finalSelection

        if let finalSelection,
           !visibilityWasCorrected,
           let fromIndexForVisibility,
           let selectedNode = findNode(by: finalSelection),
           viewportNeedsRecalc
        {
            ensureSelectionVisible(
                node: selectedNode,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                fromContainerIndex: fromIndexForVisibility
            )
            visibilityWasCorrected = true
        }

        return NiriRemovalResult(
            removedTokens: removedTokens,
            removedNodeIds: removedNodeIds.union(batchRemovedNodeIds),
            removedColumnIndicesBefore: removedColumnIndicesBefore,
            activeIndexBefore: activeIndexBefore,
            activeIndexAfter: columns(in: workspaceId).isEmpty ? nil : state.activeColumnIndex,
            finalSelectionId: finalSelection,
            viewportNeedsRecalc: viewportNeedsRecalc,
            fromIndexForVisibility: visibilityWasCorrected ? nil : fromIndexForVisibility,
            visibilityWasCorrected: visibilityWasCorrected
        )
    }

    private func removeTileByIdx(
        columnIndex: Int,
        tileIndex: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        motion: MotionSnapshot,
        workingFrame: CGRect,
        gaps: CGFloat,
        allRemovalTokens: Set<WindowToken>,
        allRemovalNodeIds: Set<NodeId>
    ) -> TileRemovalStep {
        let cols = columns(in: workspaceId)
        guard columnIndex >= 0, columnIndex < cols.count else { return TileRemovalStep() }

        let column = cols[columnIndex]
        let windows = column.windowNodes
        guard tileIndex >= 0, tileIndex < windows.count else { return TileRemovalStep() }

        if windows.count == 1 {
            return removeColumnByIdx(
                columnIndex,
                in: workspaceId,
                state: &state,
                motion: motion,
                workingFrame: workingFrame,
                gaps: gaps,
                allRemovalTokens: allRemovalTokens,
                allRemovalNodeIds: allRemovalNodeIds
            )
        }

        let node = windows[tileIndex]
        let removedToken = node.token
        let removedNodeId = node.id

        if interactiveResize?.windowId == removedNodeId {
            clearInteractiveResize()
        }

        column.adjustActiveTileIdxForRemoval(of: node)
        removeWindowPools(for: node)
        node.remove()

        if column.displayMode == .tabbed {
            column.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: column)
        }

        if column.windowNodes.count == 1,
           let remaining = column.windowNodes.first,
           remaining.height.isAuto
        {
            remaining.height = .auto(weight: 1.0)
        }

        let fallback = fallbackSelectionInColumn(
            column,
            excluding: allRemovalNodeIds
        )

        return TileRemovalStep(
            removedTokens: [removedToken],
            removedNodeIds: [removedNodeId],
            fallbackSelectionId: fallback
        )
    }

    private func removeColumnByIdx(
        _ removedIdx: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        motion: MotionSnapshot,
        workingFrame: CGRect,
        gaps: CGFloat,
        allRemovalTokens: Set<WindowToken>,
        allRemovalNodeIds: Set<NodeId>
    ) -> TileRemovalStep {
        let cols = columns(in: workspaceId)
        guard removedIdx >= 0, removedIdx < cols.count else { return TileRemovalStep() }

        for col in cols where col.cachedWidth <= 0 {
            col.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gaps)
        }

        let column = cols[removedIdx]
        let removedWindows = column.windowNodes
        let removedTokens = Set(removedWindows.map(\.token)).intersection(allRemovalTokens)
        let removedNodeIds = Set(removedWindows.map(\.id))
        let activeIdx = state.activeColumnIndex.clamped(to: 0 ... max(0, cols.count - 1))
        let postRemovalCount = cols.count - 1
        let offset = columnX(at: removedIdx + 1, columns: cols, gaps: gaps)
            - columnX(at: removedIdx, columns: cols, gaps: gaps)

        animateColumnsAroundRemoval(
            columns: cols,
            removedIdx: removedIdx,
            activeIdx: activeIdx,
            offset: offset,
            in: workspaceId,
            motion: motion
        )

        if let resize = interactiveResize,
           removedWindows.contains(where: { $0.id == resize.windowId })
        {
            clearInteractiveResize()
        }

        let pendingPreviousOffset = state.activatePrevColumnOnRemoval
        if removedIdx + 1 == activeIdx {
            state.activatePrevColumnOnRemoval = nil
        }
        if removedIdx == activeIdx {
            state.viewOffsetToRestore = nil
        }

        for window in removedWindows {
            removeWindowPools(for: window)
            window.detach()
        }
        column.remove()

        var fallbackSelectionId: NodeId?
        var viewportNeedsRecalc = false
        var fromIndexForVisibility: Int?
        var visibilityWasCorrected = false

        if postRemovalCount <= 0 {
            state.activeColumnIndex = 0
            state.activatePrevColumnOnRemoval = nil
            state.selectedNodeId = nil
        } else if removedIdx < activeIdx {
            state.activeColumnIndex = activeIdx - 1
            state.rebaseOffset(by: offset)
            state.activatePrevColumnOnRemoval = nil
            viewportNeedsRecalc = true
            fallbackSelectionId = fallbackSelectionFromActiveColumn(
                in: workspaceId,
                activeIndex: state.activeColumnIndex,
                excluding: allRemovalNodeIds
            )
        } else if removedIdx == activeIdx,
                  let previousOffset = pendingPreviousOffset,
                  removedIdx > 0
        {
            state.activeColumnIndex = activeIdx - 1
            state.activatePrevColumnOnRemoval = nil
            state.jumpOffset(to: previousOffset)
            viewportNeedsRecalc = true
            fallbackSelectionId = fallbackSelectionFromActiveColumn(
                in: workspaceId,
                activeIndex: state.activeColumnIndex,
                excluding: allRemovalNodeIds
            )
            if let fallbackSelectionId,
               let selectedNode = findNode(by: fallbackSelectionId)
            {
                state.selectedNodeId = fallbackSelectionId
                ensureSelectionVisible(
                    node: selectedNode,
                    in: workspaceId,
                    motion: motion,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    fromContainerIndex: state.activeColumnIndex
                )
                visibilityWasCorrected = true
            }
        } else if removedIdx == activeIdx {
            state.activeColumnIndex = min(activeIdx, postRemovalCount - 1)
            state.activatePrevColumnOnRemoval = nil
            viewportNeedsRecalc = true
            fromIndexForVisibility = removedIdx
            fallbackSelectionId = fallbackSelectionFromActiveColumn(
                in: workspaceId,
                activeIndex: state.activeColumnIndex,
                excluding: allRemovalNodeIds
            )
        } else {
            state.activatePrevColumnOnRemoval = nil
        }

        return TileRemovalStep(
            removedTokens: removedTokens,
            removedNodeIds: removedNodeIds,
            removedColumnIndexBefore: removedIdx,
            fallbackSelectionId: fallbackSelectionId,
            viewportNeedsRecalc: viewportNeedsRecalc,
            fromIndexForVisibility: fromIndexForVisibility,
            visibilityWasCorrected: visibilityWasCorrected
        )
    }

    private func fallbackSelectionInColumn(
        _ column: NiriContainer,
        excluding removedNodeIds: Set<NodeId>
    ) -> NodeId? {
        if let activeWindow = column.activeWindow,
           !removedNodeIds.contains(activeWindow.id)
        {
            return activeWindow.id
        }

        return column.windowNodes.first(where: { !removedNodeIds.contains($0.id) })?.id
    }

    private func fallbackSelectionFromActiveColumn(
        in workspaceId: WorkspaceDescriptor.ID,
        activeIndex: Int,
        excluding removedNodeIds: Set<NodeId>
    ) -> NodeId? {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return nil }
        let idx = activeIndex.clamped(to: 0 ... (cols.count - 1))
        return fallbackSelectionInColumn(cols[idx], excluding: removedNodeIds)
    }

    private func removeWindowPools(for window: NiriWindow) {
        closingTokens.remove(window.token)
        tokenToNode.removeValue(forKey: window.token)
        framePool.removeValue(forKey: window.token)
        hiddenPool.removeValue(forKey: window.token)
    }

    @discardableResult
    func rekeyWindow(from oldToken: WindowToken, to newToken: WindowToken) -> Bool {
        assertSanctionedMutation()
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
        assertSanctionedMutation()
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
        assertSanctionedMutation()
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
