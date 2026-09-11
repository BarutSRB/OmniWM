// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension DwindleLayoutEngine {
    func prepareProjectedLayoutFacts(
        for node: DwindleNode,
        boundaryEdges: ResizeEdge,
        excludedTokens: Set<WindowToken>,
        innerGap: CGFloat
    ) {
        prepareProjectedVisibilityFacts(for: node, excludedTokens: excludedTokens)
        prepareProjectedMinSizeFacts(
            for: node,
            boundaryEdges: boundaryEdges,
            excludedTokens: excludedTokens,
            innerGap: innerGap
        )
    }

    @discardableResult
    private func prepareProjectedVisibilityFacts(
        for node: DwindleNode,
        excludedTokens: Set<WindowToken>
    ) -> Int {
        if let tile = node.tile {
            let count = visibleMember(in: tile, excluding: excludedTokens) == nil ? 0 : 1
            node.projectedVisibleLeafCount = count
            return count
        }
        var count = 0
        for child in node.children {
            count += prepareProjectedVisibilityFacts(for: child, excludedTokens: excludedTokens)
        }
        node.projectedVisibleLeafCount = count
        return count
    }

    @discardableResult
    private func prepareProjectedMinSizeFacts(
        for node: DwindleNode,
        boundaryEdges: ResizeEdge,
        excludedTokens: Set<WindowToken>,
        innerGap: CGFloat
    ) -> CGSize {
        guard node.projectedVisibleLeafCount > 0 else {
            node.projectedMinSize = CGSize(width: 1, height: 1)
            return node.projectedMinSize
        }
        switch node.kind {
        case let .leaf(tile):
            guard let tile else { return node.projectedMinSize }
            node.projectedMinSize = projectedMinimumSize(
                for: tile,
                boundaryEdges: boundaryEdges,
                excludedTokens: excludedTokens,
                innerGap: innerGap
            )
            return node.projectedMinSize

        case let .split(orientation, _):
            node.projectedMinSize = prepareProjectedSplitMinSizeFacts(
                for: node,
                orientation: orientation,
                boundaryEdges: boundaryEdges,
                excludedTokens: excludedTokens,
                innerGap: innerGap
            )
            return node.projectedMinSize
        }
    }

    private func prepareProjectedSplitMinSizeFacts(
        for node: DwindleNode,
        orientation: DwindleOrientation,
        boundaryEdges: ResizeEdge,
        excludedTokens: Set<WindowToken>,
        innerGap: CGFloat
    ) -> CGSize {
        guard let first = node.firstChild(), let second = node.secondChild() else {
            return CGSize(width: 1, height: 1)
        }
        if first.projectedVisibleLeafCount == 0 {
            return prepareProjectedMinSizeFacts(
                for: second,
                boundaryEdges: boundaryEdges,
                excludedTokens: excludedTokens,
                innerGap: innerGap
            )
        }
        if second.projectedVisibleLeafCount == 0 {
            return prepareProjectedMinSizeFacts(
                for: first,
                boundaryEdges: boundaryEdges,
                excludedTokens: excludedTokens,
                innerGap: innerGap
            )
        }

        let childEdges = splitChildBoundaryEdges(boundaryEdges, orientation: orientation)
        let firstMin = prepareProjectedMinSizeFacts(
            for: first,
            boundaryEdges: childEdges.first,
            excludedTokens: excludedTokens,
            innerGap: innerGap
        )
        let secondMin = prepareProjectedMinSizeFacts(
            for: second,
            boundaryEdges: childEdges.second,
            excludedTokens: excludedTokens,
            innerGap: innerGap
        )
        switch orientation {
        case .horizontal:
            return CGSize(
                width: firstMin.width + secondMin.width,
                height: max(firstMin.height, secondMin.height)
            )
        case .vertical:
            return CGSize(
                width: max(firstMin.width, secondMin.width),
                height: firstMin.height + secondMin.height
            )
        }
    }
}
