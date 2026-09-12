// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension DwindleLayoutEngine {
    private struct RootPromotion {
        let root: DwindleNode
        let leaf: DwindleNode
        let ancestor: DwindleNode
        let swapNode: DwindleNode
        let leafSibling: DwindleNode
        let leafIsFirst: Bool
        let ancestorIsFirst: Bool
    }

    private func rootPromotion(in workspaceId: WorkspaceDescriptor.ID) -> RootPromotion? {
        guard let selected = selectedNode(in: workspaceId) else { return nil }
        let leaf = selected.isLeaf ? selected : selected.descendToFirstLeaf()
        guard let root = existingState(for: workspaceId)?.root else { return nil }

        if leaf.id == root.id { return nil }

        guard let leafParent = leaf.parent else { return nil }

        if leafParent.id == root.id { return nil }

        var ancestor = leafParent
        while let parent = ancestor.parent, parent.id != root.id {
            ancestor = parent
        }

        guard ancestor.parent?.id == root.id else { return nil }

        guard root.children.count == 2,
              let first = root.firstChild(),
              let second = root.secondChild() else { return nil }

        let ancestorIsFirst = first.id == ancestor.id
        let swapNode = ancestorIsFirst ? second : first

        guard let leafSibling = leaf.sibling() else { return nil }
        let leafIsFirst = leaf.isFirstChild(of: leafParent)

        return RootPromotion(
            root: root,
            leaf: leaf,
            ancestor: ancestor,
            swapNode: swapNode,
            leafSibling: leafSibling,
            leafIsFirst: leafIsFirst,
            ancestorIsFirst: ancestorIsFirst
        )
    }

    @discardableResult
    func moveSelectionToRoot(stable: Bool, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        guard let promotion = rootPromotion(in: workspaceId) else { return false }
        let root = promotion.root
        let leaf = promotion.leaf
        let ancestor = promotion.ancestor
        let swapNode = promotion.swapNode
        let leafSibling = promotion.leafSibling
        let leafIsFirst = promotion.leafIsFirst
        let ancestorIsFirst = promotion.ancestorIsFirst
        leaf.detach()
        if ancestorIsFirst {
            leaf.insertAfter(ancestor)
        } else {
            leaf.insertBefore(ancestor)
        }

        swapNode.detach()
        if leafIsFirst {
            swapNode.insertBefore(leafSibling)
        } else {
            swapNode.insertAfter(leafSibling)
        }

        if stable, root.children.count == 2,
           let newFirst = root.firstChild()
        {
            newFirst.detach()
            root.appendChild(newFirst)
        }
        return true
    }
}
