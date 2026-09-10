// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

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

    private struct RemovalBatch {
        let tokens: Set<WindowToken>
        let nodeIds: Set<NodeId>
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

    func updateWindowConstraints(
        for token: WindowToken,
        constraints: WindowSizeConstraints,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot
    ) {
        assertSanctionedMutation()
        guard let node = states[workspaceId]?.nodesByToken[token] else { return }
        let normalized = constraints.normalized()
        guard node.constraints != normalized else { return }
        node.constraints = normalized
        guard let column = node.parent as? NiriContainer else { return }
        if column.cachedHeight > 0 {
            column.cachedHeight = column.clampedToHeightBounds(column.cachedHeight)
        }
        let contentInset = tabContentInset(for: column)
        if let target = column.targetWidth {
            let clampedTarget = column.clampedToWidthBounds(
                target,
                contentInset: contentInset
            )
            if clampedTarget != target {
                column.animateWidthTo(
                    newWidth: clampedTarget,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate(in: workspaceId),
                    animated: motion.animationsEnabled
                )
            }
        } else if column.cachedWidth > 0 {
            column.cachedWidth = column.clampedToWidthBounds(
                column.cachedWidth,
                contentInset: contentInset
            )
        }
    }

    func addWindow(
        token: WindowToken,
        to workspaceId: WorkspaceDescriptor.ID,
        afterSelection selectedNodeId: NodeId?,
        focusedToken: WindowToken? = nil,
        containerSizingState: NiriContainerSizingState? = nil
    ) -> NiriWindow {
        let state = ensureState(for: workspaceId)
        if let existing = state.nodesByToken[token] {
            return existing
        }
        let root = state.root

        if let existingColumn = claimEmptyColumnIfWorkspaceEmpty(in: root) {
            initializeNewContainerSizing(existingColumn, in: workspaceId, initialState: containerSizingState)
            let windowNode = NiriWindow(token: token)
            existingColumn.appendChild(windowNode)
            state.index(windowNode)
            return windowNode
        }

        let referenceColumn: NiriContainer? = if let focusedToken,
                                                 let focusedNode = state.nodesByToken[focusedToken],
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
        initializeNewContainerSizing(newColumn, in: workspaceId, initialState: containerSizingState)
        if let refCol = referenceColumn {
            root.insertAfter(newColumn, reference: refCol)
        } else {
            root.appendChild(newColumn)
        }

        let windowNode = NiriWindow(token: token)
        newColumn.appendChild(windowNode)

        state.index(windowNode)

        return windowNode
    }

    func workspaceIds(containing token: WindowToken) -> [WorkspaceDescriptor.ID] {
        states.compactMap { $0.value.nodesByToken[token] != nil ? $0.key : nil }
    }

    func workspaceIds() -> [WorkspaceDescriptor.ID] {
        Array(states.keys)
    }

    func findNode(for token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> NiriWindow? {
        states[workspaceId]?.nodesByToken[token]
    }

    func removeWindow(token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        guard let state = states[workspaceId],
              let node = state.nodesByToken[token],
              let column = node.parent as? NiriContainer else { return }

        cancelInteractions(for: Set([node.id]), in: workspaceId)
        column.adjustActiveTileIdxForRemoval(of: node)
        node.remove()
        state.unindex(node)
        if excludedTokensByWorkspace[workspaceId]?.remove(token) != nil,
           excludedTokensByWorkspace[workspaceId]?.isEmpty == true
        {
            excludedTokensByWorkspace.removeValue(forKey: workspaceId)
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
        context: NiriInteractionContext,
        state: inout ViewportState,
        selectedNodeId: NodeId?,
        removedNodeIds externallyRemovedNodeIds: [NodeId]
    ) -> NiriRemovalResult {
        assertSanctionedMutation()
        guard !tokens.isEmpty,
              let workspaceState = states[context.workspaceId]
        else {
            return NiriRemovalResult(
                removedTokens: [],
                removedNodeIds: [],
                removedColumnIndicesBefore: [],
                activeIndexBefore: columns(in: context.workspaceId).isEmpty ? nil : state.activeColumnIndex,
                activeIndexAfter: columns(in: context.workspaceId).isEmpty ? nil : state.activeColumnIndex,
                finalSelectionId: nil,
                viewportNeedsRecalc: false,
                fromIndexForVisibility: nil,
                visibilityWasCorrected: false
            )
        }

        let root = workspaceState.root
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

        let batch = RemovalBatch(
            tokens: removalTokens,
            nodeIds: Set(externallyRemovedNodeIds).union(
                removalTokens.compactMap { workspaceState.nodesByToken[$0]?.id }
            )
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
                  let columnIndex = columnIndex(of: column, in: context.workspaceId),
                  let tileIndex = column.windowNodes.firstIndex(where: { $0 === window })
            else {
                remainingTokens.remove(window.token)
                continue
            }

            let step = removeTileByIdx(
                columnIndex: columnIndex,
                tileIndex: tileIndex,
                context: context,
                state: &state,
                batch: batch
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
           !batch.nodeIds.contains(currentSelection),
           root.findNode(by: currentSelection) != nil
        {
            finalSelection = currentSelection
        } else {
            finalSelection = latestFallback
                ?? fallbackSelectionFromActiveColumn(
                    in: context.workspaceId,
                    activeIndex: state.activeColumnIndex,
                    excluding: batch.nodeIds
                )
                ?? validateSelection(nil, in: context.workspaceId)
        }

        state.selectedNodeId = finalSelection

        if let finalSelection,
           !visibilityWasCorrected,
           let fromIndexForVisibility,
           let selectedNode = root.findNode(by: finalSelection),
           viewportNeedsRecalc
        {
            ensureSelectionVisible(
                node: selectedNode,
                context: context,
                state: &state,
                fromContainerIndex: fromIndexForVisibility
            )
            visibilityWasCorrected = true
        }

        if !removedColumnIndicesBefore.isEmpty,
           correctViewportAfterColumnRemoval(
               context: context,
               state: &state
           )
        {
            viewportNeedsRecalc = true
        }

        return NiriRemovalResult(
            removedTokens: removedTokens,
            removedNodeIds: removedNodeIds.union(batch.nodeIds),
            removedColumnIndicesBefore: removedColumnIndicesBefore,
            activeIndexBefore: activeIndexBefore,
            activeIndexAfter: columns(in: context.workspaceId).isEmpty ? nil : state.activeColumnIndex,
            finalSelectionId: finalSelection,
            viewportNeedsRecalc: viewportNeedsRecalc,
            fromIndexForVisibility: visibilityWasCorrected ? nil : fromIndexForVisibility,
            visibilityWasCorrected: visibilityWasCorrected
        )
    }

    private func removeTileByIdx(
        columnIndex: Int,
        tileIndex: Int,
        context: NiriInteractionContext,
        state: inout ViewportState,
        batch: RemovalBatch
    ) -> TileRemovalStep {
        let cols = columns(in: context.workspaceId)
        guard columnIndex >= 0, columnIndex < cols.count else { return TileRemovalStep() }

        let column = cols[columnIndex]
        let windows = column.windowNodes
        guard tileIndex >= 0, tileIndex < windows.count else { return TileRemovalStep() }

        if windows.count == 1 {
            return removeColumnByIdx(
                columnIndex,
                context: context,
                state: &state,
                batch: batch
            )
        }

        let node = windows[tileIndex]
        let removedToken = node.token
        let removedNodeId = node.id

        cancelInteractions(for: Set([removedNodeId]), in: context.workspaceId)

        column.adjustActiveTileIdxForRemoval(of: node)
        states[context.workspaceId]?.unindex(node)
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
            excluding: batch.nodeIds
        )

        return TileRemovalStep(
            removedTokens: [removedToken],
            removedNodeIds: [removedNodeId],
            fallbackSelectionId: fallback
        )
    }

    private func removeColumnByIdx(
        _ removedIdx: Int,
        context: NiriInteractionContext,
        state: inout ViewportState,
        batch: RemovalBatch
    ) -> TileRemovalStep {
        let cols = columns(in: context.workspaceId)
        guard removedIdx >= 0, removedIdx < cols.count else { return TileRemovalStep() }

        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )

        let column = cols[removedIdx]
        let removedWindows = column.windowNodes
        let removedTokens = Set(removedWindows.map(\.token)).intersection(batch.tokens)
        let removedNodeIds = Set(removedWindows.map(\.id))
        let activeIdx = state.activeColumnIndex.clamped(to: 0 ... max(0, cols.count - 1))
        let postRemovalCount = cols.count - 1
        let primarySpan = switch context.orientation {
        case .horizontal: column.cachedWidth
        case .vertical: column.cachedHeight
        }
        let offset = primarySpan + context.gaps

        animateColumnsAroundRemoval(
            columns: cols,
            removedIdx: removedIdx,
            activeIdx: activeIdx,
            offset: offset,
            in: context.workspaceId,
            motion: context.motion,
            orientation: context.orientation
        )

        cancelInteractions(for: Set(removedWindows.map(\.id)), in: context.workspaceId)

        let pendingPreviousOffset = state.activatePrevColumnOnRemoval
        if removedIdx + 1 == activeIdx {
            state.activatePrevColumnOnRemoval = nil
        }
        if removedIdx == activeIdx {
            state.viewOffsetToRestore = nil
        }

        for window in removedWindows {
            states[context.workspaceId]?.unindex(window)
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
                in: context.workspaceId,
                activeIndex: state.activeColumnIndex,
                excluding: batch.nodeIds
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
                in: context.workspaceId,
                activeIndex: state.activeColumnIndex,
                excluding: batch.nodeIds
            )
            if let fallbackSelectionId,
               let selectedNode = findNode(by: fallbackSelectionId, in: context.workspaceId)
            {
                state.selectedNodeId = fallbackSelectionId
                ensureSelectionVisible(
                    node: selectedNode,
                    context: context,
                    state: &state,
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
                in: context.workspaceId,
                activeIndex: state.activeColumnIndex,
                excluding: batch.nodeIds
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

    func correctViewportAfterColumnRemoval(
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        let cols = columns(in: context.workspaceId)
        guard !cols.isEmpty else { return false }

        let monitor = monitorForWorkspace(context.workspaceId)
        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        let sizeKeyPath = context.orientation.settledSpanKeyPath
        let viewportSpan: CGFloat = switch context.orientation {
        case .horizontal: context.workingFrame.width
        case .vertical: context.workingFrame.height
        }

        let activeIdx = state.activeColumnIndex.clamped(to: 0 ... (cols.count - 1))
        state.activeColumnIndex = activeIdx
        let activePosition = state.containerPosition(
            at: activeIdx,
            containers: cols,
            gap: context.gaps,
            sizeKeyPath: sizeKeyPath
        )
        let viewStart = activePosition + state.viewOffset
        let settings = effectiveSettings(in: context.workspaceId)
        let scale = displayScale(in: context.workspaceId)
        if settings.centerFocusedColumn == .always
            || (cols.count == 1 && settings.alwaysCenterSingleColumn)
        {
            let targetOffset = state.computeVisibleOffset(
                containerIndex: activeIdx,
                containers: cols,
                gap: context.gaps,
                viewportSpan: viewportSpan,
                sizeKeyPath: sizeKeyPath,
                currentViewStart: viewStart,
                centerMode: settings.centerFocusedColumn,
                alwaysCenterSingleColumn: settings.alwaysCenterSingleColumn,
                scale: scale,
                workingArea: context.workingFrame,
                viewFrame: monitor?.frame,
                orientation: context.orientation
            )
            let targetStart = activePosition + targetOffset
            guard abs(targetStart - viewStart) > 0.5 else { return false }
            state.animateToOffset(targetOffset, motion: context.motion, scale: scale)
            return true
        }

        let totalSpan = state.totalSpan(
            containers: cols,
            gap: context.gaps,
            sizeKeyPath: sizeKeyPath
        )
        let contentEdge = totalSpan - viewportSpan + context.gaps
        let clampedStart = viewStart.clamped(to: min(-context.gaps, contentEdge) ... max(-context.gaps, contentEdge))
        guard abs(clampedStart - viewStart) > 0.5 else { return false }

        if settings.centerFocusedColumn == .onOverflow {
            let centeredOffset = state.computeVisibleOffset(
                containerIndex: activeIdx,
                containers: cols,
                gap: context.gaps,
                viewportSpan: viewportSpan,
                sizeKeyPath: sizeKeyPath,
                currentViewStart: viewStart,
                centerMode: .always,
                scale: scale,
                workingArea: context.workingFrame,
                viewFrame: monitor?.frame,
                orientation: context.orientation
            )
            let centeredStart = activePosition + centeredOffset
            let activeSpan = cols[activeIdx][keyPath: sizeKeyPath]
            let previousPairOverflows = activeIdx > 0
                && cols[activeIdx - 1][keyPath: sizeKeyPath] + activeSpan + context.gaps * 3 > viewportSpan
            let nextPairOverflows = activeIdx + 1 < cols.count
                && activeSpan + cols[activeIdx + 1][keyPath: sizeKeyPath] + context.gaps * 3 > viewportSpan
            if previousPairOverflows || nextPairOverflows,
               abs(centeredStart - viewStart) <= 0.5
            {
                return false
            }
        }

        let fittedOffset = state.computeVisibleOffset(
            containerIndex: activeIdx,
            containers: cols,
            gap: context.gaps,
            viewportSpan: viewportSpan,
            sizeKeyPath: sizeKeyPath,
            currentViewStart: clampedStart,
            centerMode: .never,
            scale: scale,
            workingArea: context.workingFrame,
            viewFrame: monitor?.frame,
            orientation: context.orientation
        )
        let fittedStart = activePosition + fittedOffset
        guard abs(fittedStart - viewStart) > 0.5 else { return false }
        state.animateToOffset(
            fittedOffset,
            motion: context.motion,
            scale: scale
        )
        return true
    }

    @discardableResult
    func rekeyWindow(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard oldToken != newToken,
              let state = states[workspaceId],
              state.nodesByToken[newToken] == nil,
              let node = state.nodesByToken.removeValue(forKey: oldToken)
        else {
            return false
        }

        node.token = newToken
        state.index(node)

        if var move = interactiveMove,
           move.workspaceId == workspaceId,
           move.windowId == node.id
        {
            move.windowToken = newToken
            interactiveMove = move
        }

        node.invalidateChildrenCache()
        return true
    }

    @discardableResult
    func syncWindows(
        _ tokens: [WindowToken],
        in workspaceId: WorkspaceDescriptor.ID,
        selectedNodeId: NodeId?,
        focusedToken: WindowToken? = nil,
        containerSizingStates: [WindowToken: NiriContainerSizingState]? = nil
    ) -> Set<WindowToken> {
        assertSanctionedMutation()
        let state = ensureState(for: workspaceId)

        let currentIdSet = Set(tokens)

        var removedHandles = Set<WindowToken>()

        for window in state.root.allWindows where !currentIdSet.contains(window.token) {
            removedHandles.insert(window.token)
            removeWindow(token: window.token, in: workspaceId)
        }

        for token in tokens where state.nodesByToken[token] == nil {
            _ = addWindow(
                token: token,
                to: workspaceId,
                afterSelection: selectedNodeId,
                focusedToken: focusedToken,
                containerSizingState: containerSizingStates?[token]
            )
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

        guard let root = root(for: workspaceId),
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
        guard let root = root(for: workspaceId),
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

        for col in cols where col.id != column(of: removingNode)?.id {
            if let firstWindow = col.firstChild() {
                return firstWindow.id
            }
        }

        return nil
    }

    func updateFocusTimestamp(for nodeId: NodeId, in workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        guard let node = findNode(by: nodeId, in: workspaceId) as? NiriWindow else { return }
        node.lastFocusedTime = Date()
    }

    func updateFocusTimestamp(for token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) {
        guard let node = states[workspaceId]?.nodesByToken[token] else { return }
        node.lastFocusedTime = Date()
    }

    func findMostRecentlyFocusedWindow(
        excluding excludingNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> NiriWindow? {
        let allWindows: [NiriWindow] = if let wsId = workspaceId, let root = root(for: wsId) {
            root.allWindows
        } else {
            Array(states.values.flatMap(\.root.allWindows))
        }

        let candidates = allWindows.filter { window in
            guard window.id != excludingNodeId, window.lastFocusedTime != nil else { return false }
            if let workspaceId {
                return !isExcludedFromProjection(window.token, in: workspaceId)
            }
            return !excludedTokensByWorkspace.values.contains { $0.contains(window.token) }
        }

        return candidates.max { ($0.lastFocusedTime ?? .distantPast) < ($1.lastFocusedTime ?? .distantPast) }
    }
}
