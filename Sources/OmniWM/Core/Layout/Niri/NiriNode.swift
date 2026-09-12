// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

struct NodeId: Hashable, Equatable {
    let uuid: UUID

    init() {
        uuid = UUID()
    }
}

class NiriNode {
    let id: NodeId
    weak var parent: NiriNode?
    private(set) var children: [NiriNode] = [] {
        didSet { invalidateChildrenCache() }
    }

    var size: CGFloat = 1.0

    var frame: CGRect?
    var renderedFrame: CGRect?

    init() {
        id = NodeId()
    }

    func invalidateChildrenCache() {
        parent?.invalidateChildrenCache()
    }

    func invalidateAxisSolveInputs() {
        parent?.invalidateAxisSolveInputs()
    }

    func findRoot() -> NiriRoot? {
        var current: NiriNode? = self
        while let node = current {
            if let root = node as? NiriRoot {
                return root
            }
            current = node.parent
        }
        return nil
    }

    func firstChild() -> NiriNode? {
        children.first
    }

    func nextSibling() -> NiriNode? {
        guard let parent else { return nil }
        guard let index = parent.children.firstIndex(where: { $0 === self }) else { return nil }
        let nextIndex = index + 1
        guard nextIndex < parent.children.count else { return nil }
        return parent.children[nextIndex]
    }

    func prevSibling() -> NiriNode? {
        guard let parent else { return nil }
        guard let index = parent.children.firstIndex(where: { $0 === self }) else { return nil }
        guard index > 0 else { return nil }
        return parent.children[index - 1]
    }

    func appendChild(_ child: NiriNode) {
        child.detach()
        child.parent = self
        children.append(child)
        findRoot()?.registerNode(child)
    }

    func insertBefore(_ child: NiriNode, reference: NiriNode) {
        guard let index = children.firstIndex(where: { $0 === reference }) else {
            return
        }
        child.detach()
        child.parent = self
        children.insert(child, at: index)
        findRoot()?.registerNode(child)
    }

    func insertAfter(_ child: NiriNode, reference: NiriNode) {
        guard let index = children.firstIndex(where: { $0 === reference }) else {
            return
        }
        child.detach()
        child.parent = self
        children.insert(child, at: index + 1)
        findRoot()?.registerNode(child)
    }

    func detach() {
        guard let parent else { return }
        let root = findRoot()
        parent.children.removeAll { $0 === self }
        self.parent = nil
        root?.unregisterNode(self)
    }

    func remove() {
        detach()
        children.removeAll()
    }

    func swapWith(_ sibling: NiriNode) {
        guard let parent,
              parent === sibling.parent,
              let myIndex = parent.children.firstIndex(where: { $0 === self }),
              let sibIndex = parent.children.firstIndex(where: { $0 === sibling })
        else {
            return
        }
        parent.children.swapAt(myIndex, sibIndex)
    }

    func insertChild(_ child: NiriNode, at index: Int) {
        child.detach()
        child.parent = self
        let clampedIndex = max(0, min(index, children.count))
        children.insert(child, at: clampedIndex)
        findRoot()?.registerNode(child)
    }
}
