// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct DwindleInteractiveResize {
    let token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let edges: ResizeEdge
    let startMouseLocation: CGPoint
    let innerGap: CGFloat

    let horizontalSplitId: DwindleNodeId?
    let horizontalChildId: DwindleNodeId?
    let horizontalOriginRatio: CGFloat?
    let horizontalAxisLength: CGFloat?

    let verticalSplitId: DwindleNodeId?
    let verticalChildId: DwindleNodeId?
    let verticalOriginRatio: CGFloat?
    let verticalAxisLength: CGFloat?

    var didChange = false
}

/// Which edge a resize grabs when the requested one has no split to move.
enum DwindleResizeEdgePolicy {
    /// Move exactly the requested edges; an edge without a controlling split contributes nothing.
    case exact
    /// Per axis, fall back to the opposite edge when only that one has a split. For input with no physical
    /// grab point, such as a trackpad gesture, this keeps a tile against the screen edge resizable.
    case nearestMovable
}

extension DwindleLayoutEngine {
    private struct ControllingSplitMatch {
        let split: DwindleNode
        let child: DwindleNode
        let axisLength: CGFloat
        let edge: ResizeEdge
    }

    func interactiveResizeBegin(
        token: WindowToken,
        edges: ResizeEdge,
        startLocation: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        innerGap: CGFloat,
        edgePolicy: DwindleResizeEdgePolicy = .exact
    ) -> Bool {
        guard interactiveResize == nil else { return false }
        guard let leaf = findNode(for: token, in: workspaceId), leaf.isLeaf, !leaf.isFullscreen else { return false }

        let horizontal = resolveControllingSplit(
            from: leaf,
            edges: edges,
            axis: .horizontal,
            policy: edgePolicy,
            workspaceId: workspaceId
        )
        let vertical = resolveControllingSplit(
            from: leaf,
            edges: edges,
            axis: .vertical,
            policy: edgePolicy,
            workspaceId: workspaceId
        )
        guard horizontal != nil || vertical != nil else { return false }

        interactiveResize = DwindleInteractiveResize(
            token: token,
            workspaceId: workspaceId,
            edges: [horizontal?.edge ?? [], vertical?.edge ?? []],
            startMouseLocation: startLocation,
            innerGap: innerGap,
            horizontalSplitId: horizontal?.split.id,
            horizontalChildId: horizontal?.child.id,
            horizontalOriginRatio: horizontal?.split.splitRatio,
            horizontalAxisLength: horizontal?.axisLength,
            verticalSplitId: vertical?.split.id,
            verticalChildId: vertical?.child.id,
            verticalOriginRatio: vertical?.split.splitRatio,
            verticalAxisLength: vertical?.axisLength
        )
        return true
    }

    func interactiveResizeUpdate(currentLocation: CGPoint) -> Bool {
        guard let resize = interactiveResize else { return false }
        guard let leaf = findNode(for: resize.token, in: resize.workspaceId), leaf.isLeaf else {
            clearInteractiveResize()
            return false
        }

        var changed = false
        if applyAxis(
            resize: resize,
            leaf: leaf,
            axis: .horizontal,
            wantFirstChild: resize.edges.contains(.right),
            splitId: resize.horizontalSplitId,
            childId: resize.horizontalChildId,
            originRatio: resize.horizontalOriginRatio,
            axisLength: resize.horizontalAxisLength,
            delta: currentLocation.x - resize.startMouseLocation.x
        ) {
            changed = true
        }
        if applyAxis(
            resize: resize,
            leaf: leaf,
            axis: .vertical,
            wantFirstChild: resize.edges.contains(.top),
            splitId: resize.verticalSplitId,
            childId: resize.verticalChildId,
            originRatio: resize.verticalOriginRatio,
            axisLength: resize.verticalAxisLength,
            delta: currentLocation.y - resize.startMouseLocation.y
        ) {
            changed = true
        }

        if changed {
            interactiveResize?.didChange = true
        }
        return changed
    }

    @discardableResult
    func interactiveResizeEnd() -> Bool {
        let didChange = interactiveResize?.didChange ?? false
        interactiveResize = nil
        return didChange
    }

    func clearInteractiveResize() {
        interactiveResize = nil
    }

    func cancelAnimations(in workspaceId: WorkspaceDescriptor.ID) {
        guard let root = root(for: workspaceId) else { return }
        clearAnimationsRecursive(root)
    }

    private func clearAnimationsRecursive(_ node: DwindleNode) {
        node.clearAnimations()
        for child in node.children {
            clearAnimationsRecursive(child)
        }
    }

    private func applyAxis(
        resize: DwindleInteractiveResize,
        leaf: DwindleNode,
        axis: DwindleOrientation,
        wantFirstChild: Bool,
        splitId: DwindleNodeId?,
        childId: DwindleNodeId?,
        originRatio: CGFloat?,
        axisLength: CGFloat?,
        delta: CGFloat
    ) -> Bool {
        guard let splitId, let childId, let originRatio, let axisLength,
              let match = controllingSplit(
                  from: leaf,
                  orientation: axis,
                  wantFirstChild: wantFirstChild,
                  workspaceId: resize.workspaceId
              ),
              match.split.id == splitId,
              match.child.id == childId
        else {
            return false
        }

        let newRatio = clampedRatioRespectingMinimums(
            originRatio + 2 * delta / axisLength,
            for: match.split,
            innerGap: resize.innerGap,
            excludedTokens: excludedTokens(in: resize.workspaceId)
        )
        guard newRatio != match.split.splitRatio else { return false }
        match.split.kind = .split(orientation: axis, ratio: newRatio)
        return true
    }

    private func resolveControllingSplit(
        from leaf: DwindleNode,
        edges: ResizeEdge,
        axis: DwindleOrientation,
        policy: DwindleResizeEdgePolicy,
        workspaceId: WorkspaceDescriptor.ID
    ) -> ControllingSplitMatch? {
        // The first child of a split sits on the left or top, so grabbing a tile's right or top edge moves
        // the split where this tile is the first child.
        let (firstChildEdge, secondChildEdge): (ResizeEdge, ResizeEdge) = switch axis {
        case .horizontal: (.right, .left)
        case .vertical: (.top, .bottom)
        }
        let requested = edges.intersection([firstChildEdge, secondChildEdge])
        guard let preferred = [firstChildEdge, secondChildEdge].first(where: { requested.contains($0) }) else {
            return nil
        }
        let candidates: [ResizeEdge] = switch policy {
        case .exact: [preferred]
        case .nearestMovable: [preferred, preferred == firstChildEdge ? secondChildEdge : firstChildEdge]
        }
        for edge in candidates {
            guard let match = controllingSplit(
                from: leaf,
                orientation: axis,
                wantFirstChild: edge == firstChildEdge,
                workspaceId: workspaceId
            ),
                let frame = match.split.cachedFrame
            else { continue }
            let axisLength = axis == .horizontal ? frame.width : frame.height
            guard axisLength.isFinite, axisLength > 0 else { continue }
            return ControllingSplitMatch(split: match.split, child: match.child, axisLength: axisLength, edge: edge)
        }
        return nil
    }

    private func controllingSplit(
        from leaf: DwindleNode,
        orientation: DwindleOrientation,
        wantFirstChild: Bool,
        workspaceId: WorkspaceDescriptor.ID
    ) -> (split: DwindleNode, child: DwindleNode)? {
        var child = leaf
        var current = leaf.parent
        while let parent = current {
            if case let .split(splitOrientation, _) = parent.kind,
               splitOrientation == orientation,
               splitHasTwoVisibleBranches(
                   parent,
                   excluding: excludedTokens(in: workspaceId)
               ),
               child.isFirstChild(of: parent) == wantFirstChild
            {
                return (parent, child)
            }
            child = parent
            current = parent.parent
        }
        return nil
    }
}
