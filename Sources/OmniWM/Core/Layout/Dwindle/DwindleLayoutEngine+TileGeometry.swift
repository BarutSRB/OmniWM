// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension DwindleLayoutEngine {
    func contentFrame(
        for tile: DwindleTile,
        member: DwindleTileMember,
        tileFrame: CGRect,
        excludedTokens: Set<WindowToken>
    ) -> CGRect {
        guard tile.members.count(where: { !excludedTokens.contains($0.token) }) > 1,
              !member.isFullscreen
        else {
            return tileFrame
        }
        let railWidth = min(tabRailWidth, tileFrame.width)
        return CGRect(
            x: tileFrame.minX + railWidth,
            y: tileFrame.minY,
            width: max(0, tileFrame.width - railWidth),
            height: tileFrame.height
        )
    }

    func visibleMember(
        in tile: DwindleTile,
        excluding excludedTokens: Set<WindowToken>
    ) -> DwindleTileMember? {
        if !excludedTokens.contains(tile.activeToken) {
            return tile.activeMember
        }
        return tile.members.first { !excludedTokens.contains($0.token) }
    }

    func visibleMember(
        in tile: DwindleTile?,
        excluding excludedTokens: Set<WindowToken>
    ) -> DwindleTileMember? {
        guard let tile else { return nil }
        return visibleMember(in: tile, excluding: excludedTokens)
    }

    func subtreeHasVisibleMember(
        _ node: DwindleNode,
        excluding excludedTokens: Set<WindowToken>
    ) -> Bool {
        if let tile = node.tile {
            return visibleMember(in: tile, excluding: excludedTokens) != nil
        }
        for child in node.children where subtreeHasVisibleMember(child, excluding: excludedTokens) {
            return true
        }
        return false
    }

    func splitHasTwoVisibleBranches(
        _ split: DwindleNode,
        excluding excludedTokens: Set<WindowToken>
    ) -> Bool {
        guard let first = split.firstChild(), let second = split.secondChild() else {
            return false
        }
        return subtreeHasVisibleMember(first, excluding: excludedTokens)
            && subtreeHasVisibleMember(second, excluding: excludedTokens)
    }

    func firstVisibleSplitAncestor(
        from node: DwindleNode,
        excluding excludedTokens: Set<WindowToken>
    ) -> (split: DwindleNode, child: DwindleNode)? {
        var child = node
        var current = node.parent
        while let split = current {
            if splitHasTwoVisibleBranches(split, excluding: excludedTokens) {
                return (split, child)
            }
            child = split
            current = split.parent
        }
        return nil
    }

    func firstVisibleLeaf(
        in node: DwindleNode,
        excluding excludedTokens: Set<WindowToken>
    ) -> DwindleNode? {
        if let tile = node.tile {
            return visibleMember(in: tile, excluding: excludedTokens) == nil ? nil : node
        }
        for child in node.children {
            if let leaf = firstVisibleLeaf(in: child, excluding: excludedTokens) {
                return leaf
            }
        }
        return nil
    }
}
