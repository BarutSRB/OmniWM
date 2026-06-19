// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

typealias DwindleNodeId = UUID

enum DwindleOrientation: Equatable, Codable {
    case horizontal
    case vertical

    var perpendicular: DwindleOrientation {
        switch self {
        case .horizontal: .vertical
        case .vertical: .horizontal
        }
    }
}

extension Direction {
    var dwindleOrientation: DwindleOrientation {
        switch self {
        case .left,
             .right: .horizontal
        case .up,
             .down: .vertical
        }
    }

    var isPositive: Bool {
        switch self {
        case .right,
             .up: true
        case .left,
             .down: false
        }
    }
}

enum DwindleNodeKind {
    case split(orientation: DwindleOrientation, ratio: CGFloat)
    case leaf(handle: WindowToken?, fullscreen: Bool)
}

struct CubicRectAnimation {
    let animation: CubicAnimation
    let fromFrame: CGRect
    let toFrame: CGRect

    func currentFrame(at time: TimeInterval) -> CGRect {
        let progress = CGFloat(animation.value(at: time))
        return CGRect(
            x: fromFrame.origin.x + (toFrame.origin.x - fromFrame.origin.x) * progress,
            y: fromFrame.origin.y + (toFrame.origin.y - fromFrame.origin.y) * progress,
            width: fromFrame.width + (toFrame.width - fromFrame.width) * progress,
            height: fromFrame.height + (toFrame.height - fromFrame.height) * progress
        )
    }

    func isComplete(at time: TimeInterval) -> Bool {
        animation.isComplete(at: time)
    }
}

final class DwindleNode {
    let id: DwindleNodeId
    weak var parent: DwindleNode?
    var children: [DwindleNode] = []
    var kind: DwindleNodeKind
    var cachedFrame: CGRect?

    var cachedMinSize: CGSize?

    var frameAnimation: CubicRectAnimation?

    init(kind: DwindleNodeKind) {
        id = UUID()
        self.kind = kind
    }

    var isLeaf: Bool {
        if case .leaf = kind { return true }
        return false
    }

    var isSplit: Bool {
        if case .split = kind { return true }
        return false
    }

    var windowToken: WindowToken? {
        if case let .leaf(handle, _) = kind { return handle }
        return nil
    }

    var isFullscreen: Bool {
        if case let .leaf(_, fullscreen) = kind { return fullscreen }
        return false
    }

    var splitOrientation: DwindleOrientation? {
        if case let .split(orientation, _) = kind { return orientation }
        return nil
    }

    var splitRatio: CGFloat? {
        if case let .split(_, ratio) = kind { return ratio }
        return nil
    }

    func firstChild() -> DwindleNode? {
        children.first
    }

    func secondChild() -> DwindleNode? {
        children.count > 1 ? children[1] : nil
    }

    func detach() {
        parent?.children.removeAll { $0.id == self.id }
        parent = nil
    }

    func appendChild(_ child: DwindleNode) {
        child.detach()
        child.parent = self
        children.append(child)
    }

    func insertChild(_ child: DwindleNode, at index: Int) {
        child.detach()
        child.parent = self
        children.insert(child, at: min(index, children.count))
    }

    func replaceChildren(first: DwindleNode, second: DwindleNode) {
        for child in children {
            child.parent = nil
        }
        children.removeAll()
        first.parent = self
        second.parent = self
        children = [first, second]
    }

    func descendToFirstLeaf() -> DwindleNode {
        var node = self
        while let first = node.firstChild() {
            node = first
        }
        return node
    }

    func isFirstChild(of parent: DwindleNode) -> Bool {
        parent.firstChild()?.id == id
    }

    func sibling() -> DwindleNode? {
        guard let parent else { return nil }
        if isFirstChild(of: parent) {
            return parent.secondChild()
        } else {
            return parent.firstChild()
        }
    }

    func insertBefore(_ sibling: DwindleNode) {
        guard let parent = sibling.parent,
              let index = parent.children.firstIndex(where: { $0.id == sibling.id }) else { return }
        self.detach()
        self.parent = parent
        parent.children.insert(self, at: index)
    }

    func insertAfter(_ sibling: DwindleNode) {
        guard let parent = sibling.parent,
              let index = parent.children.firstIndex(where: { $0.id == sibling.id }) else { return }
        self.detach()
        self.parent = parent
        parent.children.insert(self, at: index + 1)
    }

    func collectAllLeaves() -> [DwindleNode] {
        var result: [DwindleNode] = []
        collectLeavesRecursive(into: &result)
        return result
    }

    private func collectLeavesRecursive(into result: inout [DwindleNode]) {
        if isLeaf {
            result.append(self)
        } else {
            for child in children {
                child.collectLeavesRecursive(into: &result)
            }
        }
    }

    func collectAllWindows() -> [WindowToken] {
        collectAllLeaves().compactMap { $0.windowToken }
    }

    func animateFrom(
        oldFrame: CGRect,
        newFrame: CGRect,
        startTime: TimeInterval,
        config: CubicConfig,
        animated: Bool
    ) {
        guard animated else {
            clearAnimations()
            return
        }

        guard Self.frameChanged(oldFrame, newFrame, tolerance: 0.5) else {
            clearAnimations()
            return
        }

        frameAnimation = CubicRectAnimation(
            animation: CubicAnimation(
                from: 0.0,
                to: 1.0,
                startTime: startTime,
                config: config
            ),
            fromFrame: oldFrame,
            toFrame: newFrame
        )
    }

    private static func frameChanged(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) > tolerance ||
            abs(lhs.origin.y - rhs.origin.y) > tolerance ||
            abs(lhs.width - rhs.width) > tolerance ||
            abs(lhs.height - rhs.height) > tolerance
    }

    func presentedFrame(at time: TimeInterval) -> CGRect? {
        frameAnimation?.currentFrame(at: time) ?? cachedFrame
    }

    func tickAnimations(at time: TimeInterval) {
        if let anim = frameAnimation, anim.isComplete(at: time) {
            frameAnimation = nil
        }
    }

    func hasActiveAnimations(at time: TimeInterval) -> Bool {
        if let anim = frameAnimation, !anim.isComplete(at: time) { return true }
        return false
    }

    func clearAnimations() {
        frameAnimation = nil
    }
}
