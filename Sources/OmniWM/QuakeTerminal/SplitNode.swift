// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import GhosttyKit

enum SplitDirection {
    case horizontal
    case vertical
}

indirect enum SplitNode {
    enum AddressStep {
        case left
        case right
    }

    typealias SplitAddress = [AddressStep]

    case leaf(GhosttySurfaceView)
    case split(SplitDirection, Double, SplitNode, SplitNode)

    var ratio: Double {
        switch self {
        case .leaf: return 0.5
        case let .split(_, r, _, _): return r
        }
    }

    func surfaceView() -> GhosttySurfaceView? {
        switch self {
        case let .leaf(view): return view
        case .split: return nil
        }
    }

    func allSurfaceViews() -> [GhosttySurfaceView] {
        switch self {
        case let .leaf(view):
            return [view]
        case let .split(_, _, left, right):
            return left.allSurfaceViews() + right.allSurfaceViews()
        }
    }

    func leafCount() -> Int {
        switch self {
        case .leaf: return 1
        case let .split(_, _, left, right): return left.leafCount() + right.leafCount()
        }
    }

    func inserting(at targetView: GhosttySurfaceView, direction: SplitDirection, newView: GhosttySurfaceView) -> SplitNode {
        switch self {
        case let .leaf(view):
            if view === targetView {
                return .split(direction, 0.5, .leaf(view), .leaf(newView))
            }
            return self

        case let .split(dir, ratio, left, right):
            let newLeft = left.inserting(at: targetView, direction: direction, newView: newView)
            if !areIdentical(newLeft, left) {
                return .split(dir, ratio, newLeft, right)
            }
            let newRight = right.inserting(at: targetView, direction: direction, newView: newView)
            return .split(dir, ratio, left, newRight)
        }
    }

    func removing(_ targetView: GhosttySurfaceView) -> SplitNode? {
        switch self {
        case let .leaf(view):
            return view === targetView ? nil : self

        case let .split(dir, ratio, left, right):
            let newLeft = left.removing(targetView)
            let newRight = right.removing(targetView)

            if newLeft == nil && newRight == nil { return nil }
            if newLeft == nil { return newRight }
            if newRight == nil { return newLeft }
            return .split(dir, ratio, newLeft!, newRight!)
        }
    }

    func contains(_ view: GhosttySurfaceView) -> Bool {
        switch self {
        case let .leaf(v): return v === view
        case let .split(_, _, left, right): return left.contains(view) || right.contains(view)
        }
    }

    struct LeafBounds {
        let view: GhosttySurfaceView
        let rect: NSRect
    }

    func calculateBounds(in rect: NSRect) -> [LeafBounds] {
        switch self {
        case let .leaf(view):
            return [LeafBounds(view: view, rect: rect)]

        case let .split(direction, ratio, left, right):
            let clampedRatio = min(max(ratio, 0.1), 0.9)

            switch direction {
            case .horizontal:
                let leftWidth = rect.width * clampedRatio
                let leftRect = NSRect(x: rect.minX, y: rect.minY, width: leftWidth, height: rect.height)
                let rightRect = NSRect(x: rect.minX + leftWidth, y: rect.minY, width: rect.width - leftWidth, height: rect.height)
                return left.calculateBounds(in: leftRect) + right.calculateBounds(in: rightRect)

            case .vertical:
                let topHeight = rect.height * clampedRatio
                let topRect = NSRect(x: rect.minX, y: rect.minY + rect.height - topHeight, width: rect.width, height: topHeight)
                let bottomRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - topHeight)
                return left.calculateBounds(in: topRect) + right.calculateBounds(in: bottomRect)
            }
        }
    }

    struct DividerInfo {
        let address: SplitAddress
        let direction: SplitDirection
        let visibleRect: NSRect
        let hitRect: NSRect
    }

    func calculateDividers(
        in rect: NSRect,
        visibleThickness: CGFloat,
        hitThickness: CGFloat,
        address: SplitAddress = []
    ) -> [DividerInfo] {
        switch self {
        case .leaf:
            return []

        case let .split(direction, ratio, left, right):
            let clampedRatio = min(max(ratio, 0.1), 0.9)
            var result: [DividerInfo] = []

            switch direction {
            case .horizontal:
                let leftWidth = rect.width * clampedRatio
                let dividerX = rect.minX + leftWidth
                let visibleRect = NSRect(
                    x: dividerX - visibleThickness / 2,
                    y: rect.minY,
                    width: visibleThickness,
                    height: rect.height
                )
                let hitRect = NSRect(
                    x: dividerX - hitThickness / 2,
                    y: rect.minY,
                    width: hitThickness,
                    height: rect.height
                )
                result.append(DividerInfo(
                    address: address,
                    direction: direction,
                    visibleRect: visibleRect,
                    hitRect: hitRect
                ))
                let leftRect = NSRect(x: rect.minX, y: rect.minY, width: leftWidth, height: rect.height)
                let rightRect = NSRect(x: rect.minX + leftWidth, y: rect.minY, width: rect.width - leftWidth, height: rect.height)
                result += left.calculateDividers(
                    in: leftRect,
                    visibleThickness: visibleThickness,
                    hitThickness: hitThickness,
                    address: address + [.left]
                )
                result += right.calculateDividers(
                    in: rightRect,
                    visibleThickness: visibleThickness,
                    hitThickness: hitThickness,
                    address: address + [.right]
                )

            case .vertical:
                let topHeight = rect.height * clampedRatio
                let dividerY = rect.minY + rect.height - topHeight
                let visibleRect = NSRect(
                    x: rect.minX,
                    y: dividerY - visibleThickness / 2,
                    width: rect.width,
                    height: visibleThickness
                )
                let hitRect = NSRect(
                    x: rect.minX,
                    y: dividerY - hitThickness / 2,
                    width: rect.width,
                    height: hitThickness
                )
                result.append(DividerInfo(
                    address: address,
                    direction: direction,
                    visibleRect: visibleRect,
                    hitRect: hitRect
                ))
                let topRect = NSRect(x: rect.minX, y: rect.minY + rect.height - topHeight, width: rect.width, height: topHeight)
                let bottomRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - topHeight)
                result += left.calculateDividers(
                    in: topRect,
                    visibleThickness: visibleThickness,
                    hitThickness: hitThickness,
                    address: address + [.left]
                )
                result += right.calculateDividers(
                    in: bottomRect,
                    visibleThickness: visibleThickness,
                    hitThickness: hitThickness,
                    address: address + [.right]
                )
            }

            return result
        }
    }

    func findNeighbor(of view: GhosttySurfaceView, direction: NavigationDirection, in rect: NSRect) -> GhosttySurfaceView? {
        let bounds = calculateBounds(in: rect)
        guard let current = bounds.first(where: { $0.view === view }) else { return nil }

        let candidates = bounds.filter { $0.view !== view }
        let center = NSPoint(x: current.rect.midX, y: current.rect.midY)

        var best: LeafBounds?
        var bestDistance: CGFloat = .greatestFiniteMagnitude

        for candidate in candidates {
            let cCenter = NSPoint(x: candidate.rect.midX, y: candidate.rect.midY)
            let matches: Bool
            switch direction {
            case .left:  matches = cCenter.x < center.x
            case .right: matches = cCenter.x > center.x
            case .up:    matches = cCenter.y > center.y
            case .down:  matches = cCenter.y < center.y
            }
            guard matches else { continue }

            let dist = hypot(cCenter.x - center.x, cCenter.y - center.y)
            if dist < bestDistance {
                bestDistance = dist
                best = candidate
            }
        }

        return best?.view
    }

    func equalized() -> SplitNode {
        switch self {
        case .leaf:
            return self
        case let .split(dir, _, left, right):
            return .split(dir, 0.5, left.equalized(), right.equalized())
        }
    }

    func ratio(at address: SplitAddress) -> Double? {
        switch self {
        case .leaf:
            return nil

        case let .split(_, ratio, left, right):
            guard let step = address.first else {
                return ratio
            }

            switch step {
            case .left:
                return left.ratio(at: Array(address.dropFirst()))
            case .right:
                return right.ratio(at: Array(address.dropFirst()))
            }
        }
    }

    func updatingRatio(at address: SplitAddress, newRatio: Double) -> SplitNode {
        switch self {
        case .leaf:
            return self

        case let .split(dir, _, left, right) where address.isEmpty:
            return .split(dir, newRatio, left, right)

        case let .split(dir, ratio, left, right):
            guard let step = address.first else {
                return self
            }

            switch step {
            case .left:
                return .split(
                    dir,
                    ratio,
                    left.updatingRatio(at: Array(address.dropFirst()), newRatio: newRatio),
                    right
                )
            case .right:
                return .split(
                    dir,
                    ratio,
                    left,
                    right.updatingRatio(at: Array(address.dropFirst()), newRatio: newRatio)
                )
            }
        }
    }

}

enum NavigationDirection {
    case left, right, up, down
}

private func areIdentical(_ a: SplitNode, _ b: SplitNode) -> Bool {
    switch (a, b) {
    case let (.leaf(v1), .leaf(v2)):
        return v1 === v2
    case let (.split(d1, r1, l1, rr1), .split(d2, r2, l2, rr2)):
        return d1 == d2 && r1 == r2 && areIdentical(l1, l2) && areIdentical(rr1, rr2)
    default:
        return false
    }
}
