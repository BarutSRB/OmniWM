import AppKit
import Foundation

final class ViewGesture {
    let tracker: SwipeTracker
    let isTrackpad: Bool

    var currentViewOffset: Double
    var animation: SpringAnimation?
    var stationaryViewOffset: Double
    var deltaFromTracker: Double

    init(currentViewOffset: Double, isTrackpad: Bool) {
        self.tracker = SwipeTracker()
        self.currentViewOffset = currentViewOffset
        self.stationaryViewOffset = currentViewOffset
        self.deltaFromTracker = currentViewOffset
        self.isTrackpad = isTrackpad
    }

    func applyDelta(_ delta: Double) {
        currentViewOffset += delta
        stationaryViewOffset += delta
        deltaFromTracker += delta
    }

    func current() -> Double {
        if let anim = animation {
            return currentViewOffset + (anim.value(at: CACurrentMediaTime()) - anim.from)
        }
        return currentViewOffset
    }

    func value(at time: TimeInterval) -> Double {
        if let anim = animation {
            return currentViewOffset + (anim.value(at: time) - anim.from)
        }
        return currentViewOffset
    }

    func currentVelocity() -> Double {
        if let anim = animation {
            return anim.velocity(at: CACurrentMediaTime())
        }
        return tracker.velocity()
    }

    func velocity(at time: TimeInterval) -> Double {
        if let anim = animation {
            return anim.velocity(at: time)
        }
        return tracker.velocity()
    }
}

enum ViewOffset: Equatable {
    case `static`(CGFloat)
    case gesture(ViewGesture)
    case spring(SpringAnimation)

    static func == (lhs: ViewOffset, rhs: ViewOffset) -> Bool {
        switch (lhs, rhs) {
        case let (.static(lhsOffset), .static(rhsOffset)):
            lhsOffset == rhsOffset
        case let (.gesture(lhsGesture), .gesture(rhsGesture)):
            lhsGesture === rhsGesture
        case let (.spring(lhsAnimation), .spring(rhsAnimation)):
            lhsAnimation === rhsAnimation
        default:
            false
        }
    }

    func current() -> CGFloat {
        switch self {
        case let .static(offset):
            offset
        case let .gesture(g):
            CGFloat(g.current())
        case let .spring(anim):
            CGFloat(anim.value(at: CACurrentMediaTime()))
        }
    }

    func value(at time: TimeInterval) -> CGFloat {
        switch self {
        case let .static(offset):
            offset
        case let .gesture(g):
            CGFloat(g.value(at: time))
        case let .spring(anim):
            CGFloat(anim.value(at: time))
        }
    }

    func target() -> CGFloat {
        switch self {
        case let .static(offset):
            offset
        case let .gesture(g):
            CGFloat(g.currentViewOffset)
        case let .spring(anim):
            CGFloat(anim.target)
        }
    }

    var isAnimating: Bool {
        switch self {
        case .spring:
            return true
        case let .gesture(g):
            return g.animation != nil
        case .static:
            return false
        }
    }

    var isGesture: Bool {
        if case .gesture = self { return true }
        return false
    }

    var gestureRef: ViewGesture? {
        if case let .gesture(g) = self { return g }
        return nil
    }

    mutating func offset(delta: Double) {
        switch self {
        case .static(let offset):
            self = .static(CGFloat(Double(offset) + delta))
        case .spring(let anim):
            anim.offsetBy(delta)
        case .gesture(let g):
            g.applyDelta(delta)
        }
    }

    func currentVelocity(at time: TimeInterval = CACurrentMediaTime()) -> Double {
        switch self {
        case .static:
            0
        case let .gesture(g):
            g.currentVelocity()
        case let .spring(anim):
            anim.velocity(at: time)
        }
    }

    func velocity(at time: TimeInterval) -> Double {
        switch self {
        case .static:
            0
        case let .gesture(g):
            g.velocity(at: time)
        case let .spring(anim):
            anim.velocity(at: time)
        }
    }
}

struct ViewportState: Equatable {
    var activeColumnIndex: Int = 0

    var viewOffsetPixels: ViewOffset = .static(0.0)

    var selectionProgress: CGFloat = 0.0

    var selectedNodeId: NodeId?

    var viewOffsetToRestore: CGFloat?

    var activatePrevColumnOnRemoval: CGFloat?

    let springConfig: SpringConfig = .niriHorizontalViewMovement

    var displayRefreshRate: Double = 60.0
}

extension ViewportState {
    mutating func resolveCommitConflicts(against current: ViewportState, hasStaleSelection: Bool) {
        if hasStaleSelection {
            selectedNodeId = current.selectedNodeId
            activeColumnIndex = current.activeColumnIndex
            selectionProgress = current.selectionProgress
        }
        if viewOffsetPixels.isGesture, case .spring = current.viewOffsetPixels {
            viewOffsetPixels = current.viewOffsetPixels
            activeColumnIndex = current.activeColumnIndex
        }
    }
}
