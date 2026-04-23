// SPDX-License-Identifier: GPL-2.0-only
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
        case .left, .right: .horizontal
        case .down, .up: .vertical
        }
    }

    var isPositive: Bool {
        switch self {
        case .right, .up: true
        case .down, .left: false
        }
    }
}

enum DwindleNodeKind {
    case split(orientation: DwindleOrientation, ratio: CGFloat)
    case leaf(handle: WindowToken?, fullscreen: Bool)
}

struct DwindleInsertionSeed {
    let sourceFrame: CGRect
    let orientation: DwindleOrientation
    let appearsFirst: Bool

    func startingFrame(for targetFrame: CGRect, pixelEpsilon: CGFloat) -> CGRect {
        let pixel = max(pixelEpsilon, 0.0001)

        switch orientation {
        case .horizontal:
            let seedX = appearsFirst ? targetFrame.maxX - pixel : targetFrame.minX
            return CGRect(
                x: seedX,
                y: sourceFrame.minY,
                width: pixel,
                height: sourceFrame.height
            )
        case .vertical:
            let seedY = appearsFirst ? targetFrame.maxY - pixel : targetFrame.minY
            return CGRect(
                x: sourceFrame.minX,
                y: seedY,
                width: sourceFrame.width,
                height: pixel
            )
        }
    }
}

final class DwindleNode {
    let id: DwindleNodeId
    weak var parent: DwindleNode?
    var children: [DwindleNode] = []
    var kind: DwindleNodeKind
    var cachedFrame: CGRect?
    var insertionSeed: DwindleInsertionSeed?

    var moveXAnimation: MoveAnimation?
    var moveYAnimation: MoveAnimation?
    var sizeWAnimation: MoveAnimation?
    var sizeHAnimation: MoveAnimation?

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
        detach()
        self.parent = parent
        parent.children.insert(self, at: index)
    }

    func insertAfter(_ sibling: DwindleNode) {
        guard let parent = sibling.parent,
              let index = parent.children.firstIndex(where: { $0.id == sibling.id }) else { return }
        detach()
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
        collectAllLeaves().compactMap(\.windowToken)
    }

    func animateFrom(
        oldFrame: CGRect,
        newFrame: CGRect,
        clock: AnimationClock?,
        config: SpringConfig,
        displayRefreshRate: Double,
        pixelEpsilon: CGFloat,
        animated: Bool
    ) {
        guard animated else {
            clearAnimations()
            return
        }

        let now = clock?.now() ?? CACurrentMediaTime()

        let velX = moveXAnimation?.currentVelocity(at: now) ?? 0
        let velY = moveYAnimation?.currentVelocity(at: now) ?? 0
        let velW = sizeWAnimation?.currentVelocity(at: now) ?? 0
        let velH = sizeHAnimation?.currentVelocity(at: now) ?? 0

        let displacementX = oldFrame.origin.x - newFrame.origin.x
        let displacementY = oldFrame.origin.y - newFrame.origin.y
        let displacementW = oldFrame.width - newFrame.width
        let displacementH = oldFrame.height - newFrame.height

        if abs(displacementX) > pixelEpsilon {
            let anim = SpringAnimation(
                from: 1.0,
                to: 0.0,
                initialVelocity: velX,
                startTime: now,
                config: config,
                displayRefreshRate: displayRefreshRate
            )
            moveXAnimation = MoveAnimation(animation: anim, fromOffset: displacementX)
        } else {
            moveXAnimation = nil
        }

        if abs(displacementY) > pixelEpsilon {
            let anim = SpringAnimation(
                from: 1.0,
                to: 0.0,
                initialVelocity: velY,
                startTime: now,
                config: config,
                displayRefreshRate: displayRefreshRate
            )
            moveYAnimation = MoveAnimation(animation: anim, fromOffset: displacementY)
        } else {
            moveYAnimation = nil
        }

        if abs(displacementW) > pixelEpsilon {
            let anim = SpringAnimation(
                from: 1.0,
                to: 0.0,
                initialVelocity: velW,
                startTime: now,
                config: config,
                displayRefreshRate: displayRefreshRate
            )
            sizeWAnimation = MoveAnimation(animation: anim, fromOffset: displacementW)
        } else {
            sizeWAnimation = nil
        }

        if abs(displacementH) > pixelEpsilon {
            let anim = SpringAnimation(
                from: 1.0,
                to: 0.0,
                initialVelocity: velH,
                startTime: now,
                config: config,
                displayRefreshRate: displayRefreshRate
            )
            sizeHAnimation = MoveAnimation(animation: anim, fromOffset: displacementH)
        } else {
            sizeHAnimation = nil
        }
    }

    func renderOffset(at time: TimeInterval) -> CGPoint {
        CGPoint(
            x: moveXAnimation?.currentOffset(at: time) ?? 0,
            y: moveYAnimation?.currentOffset(at: time) ?? 0
        )
    }

    func renderSizeOffset(at time: TimeInterval) -> CGSize {
        CGSize(
            width: sizeWAnimation?.currentOffset(at: time) ?? 0,
            height: sizeHAnimation?.currentOffset(at: time) ?? 0
        )
    }

    func tickAnimations(at time: TimeInterval) {
        if let anim = moveXAnimation, anim.isComplete(at: time) {
            moveXAnimation = nil
        }
        if let anim = moveYAnimation, anim.isComplete(at: time) {
            moveYAnimation = nil
        }
        if let anim = sizeWAnimation, anim.isComplete(at: time) {
            sizeWAnimation = nil
        }
        if let anim = sizeHAnimation, anim.isComplete(at: time) {
            sizeHAnimation = nil
        }
    }

    func hasActiveAnimations(at time: TimeInterval) -> Bool {
        if let anim = moveXAnimation, !anim.isComplete(at: time) { return true }
        if let anim = moveYAnimation, !anim.isComplete(at: time) { return true }
        if let anim = sizeWAnimation, !anim.isComplete(at: time) { return true }
        if let anim = sizeHAnimation, !anim.isComplete(at: time) { return true }
        return false
    }

    func clearAnimations() {
        moveXAnimation = nil
        moveYAnimation = nil
        sizeWAnimation = nil
        sizeHAnimation = nil
    }
}
