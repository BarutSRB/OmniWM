// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation

extension ViewportState {
    func viewPosPixels(columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        let activeColX = columnPlanningX(at: activeColumnIndex, columns: columns, gap: gap)
        return activeColX + viewOffsetPixels.current()
    }

    func targetViewPosPixels(columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        let activeColX = columnPlanningX(at: activeColumnIndex, columns: columns, gap: gap)
        return activeColX + viewOffsetPixels.target()
    }

    func currentViewOffset() -> CGFloat {
        viewOffsetPixels.current()
    }

    func stationary() -> CGFloat {
        switch viewOffsetPixels {
        case .static(let offset):
            return offset
        case .spring(let anim):
            return CGFloat(anim.target)
        case .gesture(let g):
            return CGFloat(g.stationaryViewOffset)
        }
    }

    mutating func advanceAnimations(at time: CFTimeInterval) -> Bool {
        return tickAnimation(at: time)
    }

    mutating func tickAnimation(at time: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        switch viewOffsetPixels {
        case let .spring(anim):
            if anim.isComplete(at: time) {
                let finalOffset = CGFloat(anim.target)
                viewOffsetPixels = .static(finalOffset)
                return false
            }
            return true

        case let .gesture(gesture):
            if let anim = gesture.animation {
                if anim.isComplete(at: time) {
                    gesture.animation = nil
                    return false
                }
                return true
            }
            return false

        default:
            return false
        }
    }

    mutating func animateToOffset(
        _ offset: CGFloat,
        motion: MotionSnapshot,
        config: SpringConfig? = nil,
        scale: CGFloat = 2.0
    ) {
        guard motion.animationsEnabled else {
            viewOffsetPixels = .static(offset)
            return
        }

        let now = animationClock?.now() ?? CACurrentMediaTime()
        let pixel: CGFloat = 1.0 / scale

        let toDiff = offset - viewOffsetPixels.target()
        if abs(toDiff) < pixel {
            viewOffsetPixels.offset(delta: Double(toDiff))
            return
        }

        let currentOffset = viewOffsetPixels.current()
        let velocity = viewOffsetPixels.currentVelocity()

        let animation = SpringAnimation(
            from: Double(currentOffset),
            to: Double(offset),
            initialVelocity: velocity,
            startTime: now,
            config: config ?? springConfig,
            displayRefreshRate: displayRefreshRate
        )
        viewOffsetPixels = .spring(animation)
    }

    mutating func cancelAnimation() {
        viewOffsetPixels = .static(viewOffsetPixels.target())
    }

    mutating func reset() {
        activeColumnIndex = 0
        viewOffsetPixels = .static(0.0)
        selectionProgress = 0.0
        preserveViewportDuringTopologySync = false
        selectedNodeId = nil
    }

    mutating func offsetViewport(by delta: CGFloat) {
        let current = viewOffsetPixels.current()
        viewOffsetPixels = .static(current + delta)
    }

    mutating func saveViewOffsetForFullscreen() {
        viewOffsetToRestore = stationary()
    }

    mutating func restoreViewOffset(_ offset: CGFloat) {
        guard !viewOffsetPixels.isGesture else {
            viewOffsetToRestore = nil
            return
        }

        viewOffsetPixels = .static(offset)
        viewOffsetToRestore = nil
    }

    mutating func clearSavedViewOffset() {
        viewOffsetToRestore = nil
    }
}
