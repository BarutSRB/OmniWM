// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension DwindleLayoutEngine {
    func findGeometricNeighbor(
        from handle: WindowToken,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        guard let state = existingState(for: workspaceId),
              let currentNode = state.leafByToken[handle],
              let currentTile = currentNode.tile,
              visibleMember(in: currentTile, excluding: state.excludedTokens)?.token == handle,
              let rootFrame = state.root.cachedFrame,
              let currentFrame = structuralFrame(
                  for: currentNode,
                  at: .init(node: state.root, rect: rootFrame, boundaryEdges: .all),
                  projection: .init(tilingArea: rootFrame, excludedTokens: state.excludedTokens)
              )
        else {
            return nil
        }

        var bestCandidate: (handle: WindowToken, overlap: CGFloat)?

        collectNavigationCandidates(
            at: .init(node: state.root, rect: rootFrame, boundaryEdges: .all),
            search: .init(
                current: currentNode,
                currentFrame: currentFrame,
                direction: direction,
                innerGap: settings.innerGap,
                projection: .init(tilingArea: rootFrame, excludedTokens: state.excludedTokens)
            ),
            bestCandidate: &bestCandidate
        )

        return bestCandidate?.handle
    }

    private func projectedBranches(
        at position: DwindleTraversalPosition,
        excluding excludedTokens: Set<WindowToken>
    ) -> DwindleProjectedBranches {
        let node = position.node
        guard case let .split(orientation, ratio) = node.kind,
              let first = node.firstChild(), let second = node.secondChild()
        else { return .none }
        let firstVisible = subtreeHasVisibleMember(first, excluding: excludedTokens)
        let secondVisible = subtreeHasVisibleMember(second, excluding: excludedTokens)
        if firstVisible != secondVisible {
            return .single(.init(
                node: firstVisible ? first : second,
                rect: position.rect,
                boundaryEdges: position.boundaryEdges
            ))
        }
        guard firstVisible, secondVisible else { return .none }
        let childEdges = splitChildBoundaryEdges(position.boundaryEdges, orientation: orientation)
        let firstMin = computeProjectedMinSizeForSubtree(
            first,
            boundaryEdges: childEdges.first,
            excludedTokens: excludedTokens
        )
        let secondMin = computeProjectedMinSizeForSubtree(
            second,
            boundaryEdges: childEdges.second,
            excludedTokens: excludedTokens
        )
        let (firstRect, secondRect) = splitRect(
            position.rect,
            orientation: orientation,
            ratio: ratio,
            minimums: (first: firstMin, second: secondMin)
        )
        return .split(
            .init(node: first, rect: firstRect, boundaryEdges: childEdges.first),
            .init(node: second, rect: secondRect, boundaryEdges: childEdges.second)
        )
    }

    private func structuralFrame(
        for target: DwindleNode,
        at position: DwindleTraversalPosition,
        projection: DwindleTreeProjection
    ) -> CGRect? {
        let node = position.node
        if node.id == target.id {
            guard node.isLeaf,
                  visibleMember(in: node.tile, excluding: projection.excludedTokens) != nil else { return nil }
            return DwindleGapCalculator.applyGaps(
                nodeRect: position.rect,
                tilingArea: projection.tilingArea,
                settings: settings
            )
        }
        switch projectedBranches(at: position, excluding: projection.excludedTokens) {
        case .none: return nil
        case let .single(child):
            return structuralFrame(for: target, at: child, projection: projection)
        case let .split(first, second):
            return structuralFrame(for: target, at: first, projection: projection)
                ?? structuralFrame(for: target, at: second, projection: projection)
        }
    }

    private func collectNavigationCandidates(
        at position: DwindleTraversalPosition,
        search: DwindleNavigationSearch,
        bestCandidate: inout (handle: WindowToken, overlap: CGFloat)?
    ) {
        let node = position.node
        guard node.id != search.current.id else { return }
        guard subtreeHasVisibleMember(node, excluding: search.projection.excludedTokens) else { return }
        if let tile = node.tile, let member = visibleMember(in: tile, excluding: search.projection.excludedTokens) {
            let candidateFrame = DwindleGapCalculator.applyGaps(
                nodeRect: position.rect,
                tilingArea: search.projection.tilingArea,
                settings: settings
            )
            if let overlap = calculateDirectionalOverlap(
                from: search.currentFrame,
                to: candidateFrame,
                direction: search.direction,
                innerGap: search.innerGap
            ),
                bestCandidate.map({ overlap > $0.overlap }) ?? true
            {
                bestCandidate = (member.token, overlap)
            }
            return
        }
        switch projectedBranches(at: position, excluding: search.projection.excludedTokens) {
        case .none: return
        case let .single(child):
            collectNavigationCandidates(at: child, search: search, bestCandidate: &bestCandidate)
        case let .split(first, second):
            collectNavigationCandidates(at: first, search: search, bestCandidate: &bestCandidate)
            collectNavigationCandidates(at: second, search: search, bestCandidate: &bestCandidate)
        }
    }

    private func calculateDirectionalOverlap(
        from source: CGRect,
        to target: CGRect,
        direction: Direction,
        innerGap: CGFloat
    ) -> CGFloat? {
        let edgeThreshold = innerGap + 5.0
        let minOverlapRatio: CGFloat = 0.1

        switch direction {
        case .up:
            let edgesTouch = abs(source.maxY - target.minY) < edgeThreshold
            guard edgesTouch else { return nil }

            let overlapStart = max(source.minX, target.minX)
            let overlapEnd = min(source.maxX, target.maxX)
            let overlap = max(0, overlapEnd - overlapStart)

            let minRequired = min(source.width, target.width) * minOverlapRatio
            return overlap >= minRequired ? overlap : nil

        case .down:
            let edgesTouch = abs(source.minY - target.maxY) < edgeThreshold
            guard edgesTouch else { return nil }

            let overlapStart = max(source.minX, target.minX)
            let overlapEnd = min(source.maxX, target.maxX)
            let overlap = max(0, overlapEnd - overlapStart)

            let minRequired = min(source.width, target.width) * minOverlapRatio
            return overlap >= minRequired ? overlap : nil

        case .left:
            let edgesTouch = abs(source.minX - target.maxX) < edgeThreshold
            guard edgesTouch else { return nil }

            let overlapStart = max(source.minY, target.minY)
            let overlapEnd = min(source.maxY, target.maxY)
            let overlap = max(0, overlapEnd - overlapStart)

            let minRequired = min(source.height, target.height) * minOverlapRatio
            return overlap >= minRequired ? overlap : nil

        case .right:
            let edgesTouch = abs(source.maxX - target.minX) < edgeThreshold
            guard edgesTouch else { return nil }

            let overlapStart = max(source.minY, target.minY)
            let overlapEnd = min(source.maxY, target.maxY)
            let overlap = max(0, overlapEnd - overlapStart)

            let minRequired = min(source.height, target.height) * minOverlapRatio
            return overlap >= minRequired ? overlap : nil
        }
    }
}
