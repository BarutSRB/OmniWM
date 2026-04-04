import Foundation
import CoreGraphics
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
        case .up, .down: .vertical
        }
    }

    var isPositive: Bool {
        switch self {
        case .right, .up: true
        case .left, .down: false
        }
    }
}

enum DwindleNodeKind {
    case split(orientation: DwindleOrientation, ratio: CGFloat)
    case leaf(handle: WindowToken?, fullscreen: Bool)
}

final class DwindleNode {
    let id: DwindleNodeId
    weak var parent: DwindleNode?
    var children: [DwindleNode] = []
    var kind: DwindleNodeKind
    var cachedFrame: CGRect?

    var cachedMinSize: CGSize?

    var moveXAnimation: CubicMoveAnimation?
    var moveYAnimation: CubicMoveAnimation?
    var sizeWAnimation: CubicMoveAnimation?
    var sizeHAnimation: CubicMoveAnimation?

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

    func firstChild() -> DwindleNode? { children.first }
    func secondChild() -> DwindleNode? { children.count > 1 ? children[1] : nil }

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
        clock: AnimationClock?,
        config: CubicConfig,
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

        if abs(displacementX) > 0.5 {
            let normalizedVel = abs(displacementX) > 0.001 ? Double(velX / displacementX) : 0
            let anim = CubicAnimation(
                from: 1.0,
                to: 0.0,
                startTime: now,
                initialVelocity: normalizedVel,
                config: config
            )
            moveXAnimation = CubicMoveAnimation(animation: anim, fromOffset: displacementX)
        } else {
            moveXAnimation = nil
        }

        if abs(displacementY) > 0.5 {
            let normalizedVel = abs(displacementY) > 0.001 ? Double(velY / displacementY) : 0
            let anim = CubicAnimation(
                from: 1.0,
                to: 0.0,
                startTime: now,
                initialVelocity: normalizedVel,
                config: config
            )
            moveYAnimation = CubicMoveAnimation(animation: anim, fromOffset: displacementY)
        } else {
            moveYAnimation = nil
        }

        if abs(displacementW) > 0.5 {
            let normalizedVel = abs(displacementW) > 0.001 ? Double(velW / displacementW) : 0
            let anim = CubicAnimation(
                from: 1.0,
                to: 0.0,
                startTime: now,
                initialVelocity: normalizedVel,
                config: config
            )
            sizeWAnimation = CubicMoveAnimation(animation: anim, fromOffset: displacementW)
        } else {
            sizeWAnimation = nil
        }

        if abs(displacementH) > 0.5 {
            let normalizedVel = abs(displacementH) > 0.001 ? Double(velH / displacementH) : 0
            let anim = CubicAnimation(
                from: 1.0,
                to: 0.0,
                startTime: now,
                initialVelocity: normalizedVel,
                config: config
            )
            sizeHAnimation = CubicMoveAnimation(animation: anim, fromOffset: displacementH)
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
