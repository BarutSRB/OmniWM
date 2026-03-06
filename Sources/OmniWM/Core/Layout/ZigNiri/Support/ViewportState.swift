import CZigLayout
import AppKit
import Foundation

final class ViewGesture {
    var gestureState: OmniViewportGestureState
    var currentViewOffset: Double {
        get { gestureState.current_view_offset }
        set { gestureState.current_view_offset = newValue }
    }
    var animation: SpringAnimation?
    var stationaryViewOffset: Double {
        get { gestureState.stationary_view_offset }
        set { gestureState.stationary_view_offset = newValue }
    }
    var deltaFromTracker: Double {
        get { gestureState.delta_from_tracker }
        set { gestureState.delta_from_tracker = newValue }
    }

    init(currentViewOffset: Double, isTrackpad: Bool) {
        gestureState = ZigNiriViewportMath.gestureBegin(
            currentViewOffset: CGFloat(currentViewOffset),
            isTrackpad: isTrackpad
        )
    }

    func applyDelta(_ delta: Double) {
        gestureState.current_view_offset += delta
        gestureState.stationary_view_offset += delta
        gestureState.delta_from_tracker += delta
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
        return ZigNiriViewportMath.gestureVelocity(state: gestureState)
    }

    func velocity(at time: TimeInterval) -> Double {
        if let anim = animation {
            return anim.velocity(at: time)
        }
        return ZigNiriViewportMath.gestureVelocity(state: gestureState)
    }
}

enum ViewOffset {
    case `static`(CGFloat)
    case gesture(ViewGesture)
    case spring(SpringAnimation)

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

struct ViewportState {
    var activeColumnIndex: Int = 0

    var viewOffsetPixels: ViewOffset = .static(0.0)

    var selectionProgress: CGFloat = 0.0

    var selectedNodeId: NodeId?

    var viewOffsetToRestore: CGFloat?

    var activatePrevColumnOnRemoval: CGFloat?

    let springConfig: SpringConfig = .snappy

    var animationClock: AnimationClock?

    var displayRefreshRate: Double = 60.0
}
