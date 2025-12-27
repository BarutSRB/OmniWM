import AppKit
import Foundation

final class ViewGesture {
    let tracker: SwipeTracker
    let startOffset: Double
    let isTrackpad: Bool

    init(startOffset: Double, isTrackpad: Bool) {
        self.tracker = SwipeTracker()
        self.startOffset = startOffset
        self.isTrackpad = isTrackpad
    }

    var currentOffset: Double {
        startOffset + tracker.position
    }
}

enum ViewOffset {
    case `static`(CGFloat)
    case gesture(ViewGesture)
    case animating(ViewAnimation)
    case decelerating(DecelerationAnimation)

    func current() -> CGFloat {
        switch self {
        case let .static(offset):
            offset
        case let .gesture(g):
            CGFloat(g.currentOffset)
        case let .animating(anim):
            CGFloat(anim.value(at: CACurrentMediaTime()))
        case let .decelerating(anim):
            CGFloat(anim.value(at: CACurrentMediaTime()))
        }
    }

    var isAnimating: Bool {
        switch self {
        case .animating, .decelerating:
            true
        default:
            false
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
}

struct ViewportState {
    var firstVisibleColumn: Int = 0

    var viewportOffset: ViewOffset = .static(0.0)

    var selectionProgress: CGFloat = 0.0

    var selectedNodeId: NodeId?

    var viewOffsetToRestore: CGFloat?

    var viewportStart: CGFloat {
        CGFloat(firstVisibleColumn) + viewportOffset.current()
    }

    mutating func saveViewOffsetForFullscreen() {
        viewOffsetToRestore = viewportOffset.current()
    }

    mutating func restoreViewOffset(_ offset: CGFloat) {
        viewportOffset = .static(offset)
        viewOffsetToRestore = nil
    }

    mutating func clearSavedViewOffset() {
        viewOffsetToRestore = nil
    }

    mutating func setViewportStart(
        _ start: CGFloat,
        totalColumns: Int,
        visibleCap: Int,
        infiniteLoop: Bool
    ) {
        let normalized = normalizeViewport(
            start: start,
            total: totalColumns,
            visibleCap: visibleCap,
            infiniteLoop: infiniteLoop
        )
        firstVisibleColumn = normalized.base
        viewportOffset = .static(normalized.offset)
    }

    func normalizeViewport(
        start: CGFloat,
        total: Int,
        visibleCap: Int,
        infiniteLoop: Bool
    ) -> (base: Int, offset: CGFloat) {
        guard total > 0, visibleCap > 0 else {
            return (0, 0.0)
        }

        if infiniteLoop {
            let modulo = CGFloat(total)
            let wrapped = ((start.truncatingRemainder(dividingBy: modulo)) + modulo)
                .truncatingRemainder(dividingBy: modulo)
            let base = wrapped.rounded(.down).clamped(to: 0 ... CGFloat(total - 1))
            let offset = wrapped - base
            return (Int(base), offset)
        } else {
            let maxStart = CGFloat(max(0, total - visibleCap))
            let clamped = start.clamped(to: 0 ... maxStart)
            let base = clamped.rounded(.down)
            let offset = clamped - base
            return (Int(base), offset)
        }
    }

    mutating func snapToColumn(
        _ columnIndex: Int,
        totalColumns: Int,
        visibleCap: Int,
        infiniteLoop: Bool
    ) {
        let newStart: CGFloat
        if infiniteLoop {
            newStart = CGFloat(columnIndex)
        } else {
            let maxStart = max(0, totalColumns - visibleCap)
            newStart = CGFloat(min(columnIndex, maxStart))
        }
        setViewportStart(newStart, totalColumns: totalColumns, visibleCap: visibleCap, infiniteLoop: infiniteLoop)
        selectionProgress = 0.0
    }

    mutating func scrollBy(
        _ delta: CGFloat,
        totalColumns: Int,
        visibleCap: Int,
        infiniteLoop: Bool,
        changeSelection: Bool
    ) -> Int? {
        guard abs(delta) > CGFloat.ulpOfOne else { return nil }
        guard totalColumns > 0, visibleCap > 0 else { return nil }

        let currentStart = viewportStart
        var newStart = currentStart + delta

        if !infiniteLoop {
            let maxStart = CGFloat(max(0, totalColumns - visibleCap))
            let clamped = newStart.clamped(to: 0 ... maxStart)
            let actualDelta = clamped - currentStart
            newStart = clamped

            setViewportStart(newStart, totalColumns: totalColumns, visibleCap: visibleCap, infiniteLoop: infiniteLoop)

            if changeSelection {
                selectionProgress += actualDelta
                let steps = Int(selectionProgress.rounded(.towardZero))
                if steps != 0 {
                    selectionProgress -= CGFloat(steps)
                    return steps
                }
            }
        } else {
            setViewportStart(newStart, totalColumns: totalColumns, visibleCap: visibleCap, infiniteLoop: infiniteLoop)

            if changeSelection {
                selectionProgress += delta
                let steps = Int(selectionProgress.rounded(.towardZero))
                if steps != 0 {
                    selectionProgress -= CGFloat(steps)
                    return steps
                }
            }
        }

        return nil
    }

    mutating func dndScrollBegin() {
        selectionProgress = 0.0
    }

    mutating func dndScrollUpdate(
        delta: CGFloat,
        totalColumns: Int,
        visibleCap: Int,
        infiniteLoop: Bool
    ) -> Int? {
        scrollBy(
            delta,
            totalColumns: totalColumns,
            visibleCap: visibleCap,
            infiniteLoop: infiniteLoop,
            changeSelection: true
        )
    }

    mutating func dndScrollEnd(
        totalColumns: Int,
        visibleCap: Int,
        infiniteLoop: Bool
    ) {
        let target = Int(viewportStart.rounded())
        snapToColumn(
            target,
            totalColumns: totalColumns,
            visibleCap: visibleCap,
            infiniteLoop: infiniteLoop
        )
    }

    mutating func beginGesture(isTrackpad: Bool) {
        let currentOffset = viewportOffset.current()
        viewportOffset = .gesture(ViewGesture(startOffset: Double(currentOffset), isTrackpad: isTrackpad))
        selectionProgress = 0.0
    }

    mutating func updateGesture(
        delta: CGFloat,
        timestamp: TimeInterval,
        totalColumns: Int,
        visibleCap: Int,
        infiniteLoop: Bool,
        workingAreaWidth: CGFloat
    ) -> Int? {
        guard case let .gesture(gesture) = viewportOffset else {
            return nil
        }

        let normFactor = Double(workingAreaWidth) / 1200.0
        let normalizedDelta = Double(delta) / 1200.0 * normFactor

        gesture.tracker.push(delta: normalizedDelta, timestamp: timestamp)

        let newOffset = CGFloat(gesture.currentOffset)
        let newStart = CGFloat(firstVisibleColumn) + newOffset

        if !infiniteLoop {
            let maxStart = CGFloat(max(0, totalColumns - visibleCap))
            let clamped = newStart.clamped(to: 0 ... maxStart)
            let normalized = normalizeViewport(
                start: clamped,
                total: totalColumns,
                visibleCap: visibleCap,
                infiniteLoop: infiniteLoop
            )
            firstVisibleColumn = normalized.base
            viewportOffset = .gesture(ViewGesture(startOffset: Double(normalized.offset), isTrackpad: gesture.isTrackpad))
            if let newGesture = viewportOffset.gestureRef {
                newGesture.tracker.push(delta: 0, timestamp: timestamp)
            }
        }

        selectionProgress += delta / CGFloat(workingAreaWidth) * CGFloat(normFactor)
        let steps = Int(selectionProgress.rounded(.towardZero))
        if steps != 0 {
            selectionProgress -= CGFloat(steps)
            return steps
        }
        return nil
    }

    mutating func endGesture(
        totalColumns: Int,
        visibleCap: Int,
        infiniteLoop: Bool
    ) {
        guard case let .gesture(gesture) = viewportOffset else {
            return
        }

        let velocity = gesture.tracker.velocity()
        let currentOffset = gesture.currentOffset

        let projectedEnd = gesture.tracker.projectedEndPosition() + Double(firstVisibleColumn)

        let targetColumn = Int(projectedEnd.rounded())
        let clampedTarget: Int
        if infiniteLoop {
            clampedTarget = ((targetColumn % totalColumns) + totalColumns) % totalColumns
        } else {
            let maxStart = max(0, totalColumns - visibleCap)
            clampedTarget = min(max(0, targetColumn), maxStart)
        }

        let targetOffset = Double(clampedTarget) - Double(firstVisibleColumn)

        let now = CACurrentMediaTime()

        if abs(velocity) > 0.5 {
            let animation = ViewAnimation(
                from: currentOffset,
                to: targetOffset,
                duration: 0.35,
                curve: .easeOutCubic,
                startTime: now,
                initialVelocity: velocity
            )
            viewportOffset = .animating(animation)
        } else {
            let animation = ViewAnimation(
                from: currentOffset,
                to: targetOffset,
                duration: 0.25,
                curve: .easeOutCubic,
                startTime: now,
                initialVelocity: 0
            )
            viewportOffset = .animating(animation)
        }

        selectionProgress = 0.0
    }

    mutating func tickAnimation(
        totalColumns: Int,
        visibleCap: Int,
        infiniteLoop: Bool
    ) -> Bool {
        let now = CACurrentMediaTime()

        switch viewportOffset {
        case let .animating(anim):
            if anim.isComplete(at: now) {
                let finalOffset = CGFloat(anim.targetValue)
                let finalStart = CGFloat(firstVisibleColumn) + finalOffset
                let normalized = normalizeViewport(
                    start: finalStart,
                    total: totalColumns,
                    visibleCap: visibleCap,
                    infiniteLoop: infiniteLoop
                )
                firstVisibleColumn = normalized.base
                viewportOffset = .static(normalized.offset)
                return false
            }
            let currentOffset = anim.value(at: now)
            let currentStart = CGFloat(firstVisibleColumn) + CGFloat(currentOffset)
            let normalized = normalizeViewport(
                start: currentStart,
                total: totalColumns,
                visibleCap: visibleCap,
                infiniteLoop: infiniteLoop
            )
            firstVisibleColumn = normalized.base
            return true

        case let .decelerating(anim):
            if anim.isComplete(at: now) {
                let finalOffset = CGFloat(anim.targetValue)
                let finalStart = CGFloat(firstVisibleColumn) + finalOffset
                let normalized = normalizeViewport(
                    start: finalStart,
                    total: totalColumns,
                    visibleCap: visibleCap,
                    infiniteLoop: infiniteLoop
                )
                firstVisibleColumn = normalized.base
                viewportOffset = .static(normalized.offset)
                return false
            }
            return true

        default:
            return false
        }
    }

    mutating func cancelAnimation() {
        let current = viewportOffset.current()
        viewportOffset = .static(current)
    }

    mutating func reset() {
        firstVisibleColumn = 0
        viewportOffset = .static(0.0)
        selectionProgress = 0.0
        selectedNodeId = nil
    }
}

enum NiriRevealEdge {
    case left
    case right
}
