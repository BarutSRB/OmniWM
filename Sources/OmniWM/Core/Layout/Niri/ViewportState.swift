import AppKit
import Foundation

final class ViewGesture {
    let tracker: SwipeTracker
    let startOffsetPixels: Double
    let isTrackpad: Bool

    init(startOffsetPixels: Double, isTrackpad: Bool) {
        self.tracker = SwipeTracker()
        self.startOffsetPixels = startOffsetPixels
        self.isTrackpad = isTrackpad
    }

    var currentOffsetPixels: Double {
        startOffsetPixels + tracker.position
    }
}

enum ViewOffset {
    case `static`(CGFloat)
    case gesture(ViewGesture)
    case animating(ViewAnimation)
    case decelerating(DecelerationAnimation)
    case spring(SpringAnimation)

    func current() -> CGFloat {
        switch self {
        case let .static(offset):
            offset
        case let .gesture(g):
            CGFloat(g.currentOffsetPixels)
        case let .animating(anim):
            CGFloat(anim.value(at: CACurrentMediaTime()))
        case let .decelerating(anim):
            CGFloat(anim.value(at: CACurrentMediaTime()))
        case let .spring(anim):
            CGFloat(anim.value(at: CACurrentMediaTime()))
        }
    }

    var isAnimating: Bool {
        switch self {
        case .animating, .decelerating, .spring:
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
    var activeColumnIndex: Int = 0

    var viewOffsetPixels: ViewOffset = .static(0.0)

    var selectionProgress: CGFloat = 0.0

    var selectedNodeId: NodeId?

    var viewOffsetToRestore: CGFloat?

    var animationsEnabled: Bool = true
    var focusChangeSpringConfig: SpringConfig = .snappy
    var gestureSpringConfig: SpringConfig = .snappy
    var columnRevealSpringConfig: SpringConfig = .snappy

    var focusChangeAnimationType: AnimationType = .spring
    var focusChangeEasingCurve: EasingCurve = .easeOutCubic
    var focusChangeEasingDuration: Double = 0.3

    var gestureAnimationType: AnimationType = .spring
    var gestureEasingCurve: EasingCurve = .easeOutCubic
    var gestureEasingDuration: Double = 0.3

    var columnRevealAnimationType: AnimationType = .spring
    var columnRevealEasingCurve: EasingCurve = .easeOutCubic
    var columnRevealEasingDuration: Double = 0.3

    func columnX(at index: Int, columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        var x: CGFloat = 0
        for i in 0..<index {
            guard i < columns.count else { break }
            x += columns[i].cachedWidth + gap
        }
        return x
    }

    func totalWidth(columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        guard !columns.isEmpty else { return 0 }
        let widthSum = columns.reduce(0) { $0 + $1.cachedWidth }
        let gapSum = CGFloat(max(0, columns.count - 1)) * gap
        return widthSum + gapSum
    }

    func viewPosPixels(columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        let activeColX = columnX(at: activeColumnIndex, columns: columns, gap: gap)
        return activeColX + viewOffsetPixels.current()
    }

    mutating func saveViewOffsetForFullscreen() {
        viewOffsetToRestore = viewOffsetPixels.current()
    }

    mutating func restoreViewOffset(_ offset: CGFloat) {
        viewOffsetPixels = .static(offset)
        viewOffsetToRestore = nil
    }

    mutating func clearSavedViewOffset() {
        viewOffsetToRestore = nil
    }

    mutating func setActiveColumn(
        _ index: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        animate: Bool = false
    ) {
        guard !columns.isEmpty else { return }
        let clampedIndex = index.clamped(to: 0 ... (columns.count - 1))

        let oldActiveColX = columnX(at: activeColumnIndex, columns: columns, gap: gap)
        let newActiveColX = columnX(at: clampedIndex, columns: columns, gap: gap)

        let offsetDelta = oldActiveColX - newActiveColX
        let currentOffset = viewOffsetPixels.current()
        let newOffset = currentOffset + offsetDelta

        activeColumnIndex = clampedIndex

        let targetOffset = computeCenteredOffset(
            columnIndex: clampedIndex,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth
        )

        if animate && animationsEnabled {
            let now = CACurrentMediaTime()
            switch focusChangeAnimationType {
            case .spring:
                let animation = SpringAnimation(
                    from: newOffset,
                    to: targetOffset,
                    initialVelocity: 0,
                    startTime: now,
                    config: focusChangeSpringConfig
                )
                viewOffsetPixels = .spring(animation)
            case .easing:
                let animation = ViewAnimation(
                    from: newOffset,
                    to: targetOffset,
                    duration: focusChangeEasingDuration,
                    curve: focusChangeEasingCurve,
                    startTime: now
                )
                viewOffsetPixels = .animating(animation)
            }
        } else {
            viewOffsetPixels = .static(targetOffset)
        }
    }

    func computeCenteredOffset(
        columnIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat
    ) -> CGFloat {
        guard !columns.isEmpty, columnIndex < columns.count else { return 0 }

        let totalW = totalWidth(columns: columns, gap: gap)

        if totalW <= viewportWidth {
            let colX = columnX(at: columnIndex, columns: columns, gap: gap)
            return -colX + (viewportWidth - totalW) / 2
        }

        let colWidth = columns[columnIndex].cachedWidth
        let colX = columnX(at: columnIndex, columns: columns, gap: gap)
        let centeredOffset = (viewportWidth - colWidth) / 2 - colX

        let maxOffset: CGFloat = 0
        let minOffset = viewportWidth - totalW

        return centeredOffset.clamped(to: minOffset ... maxOffset)
    }

    mutating func scrollByPixels(
        _ deltaPixels: CGFloat,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        changeSelection: Bool
    ) -> Int? {
        guard abs(deltaPixels) > CGFloat.ulpOfOne else { return nil }
        guard !columns.isEmpty else { return nil }

        let totalW = totalWidth(columns: columns, gap: gap)
        guard totalW > 0 else { return nil }

        let currentOffset = viewOffsetPixels.current()
        var newOffset = currentOffset + deltaPixels

        let maxOffset: CGFloat = 0
        let minOffset = viewportWidth - totalW

        if minOffset < maxOffset {
            newOffset = newOffset.clamped(to: minOffset ... maxOffset)
        } else {
            newOffset = 0
        }

        viewOffsetPixels = .static(newOffset)

        if changeSelection {
            selectionProgress += deltaPixels
            let avgColumnWidth = totalW / CGFloat(columns.count)
            let steps = Int((selectionProgress / avgColumnWidth).rounded(.towardZero))
            if steps != 0 {
                selectionProgress -= CGFloat(steps) * avgColumnWidth
                return steps
            }
        }

        return nil
    }

    mutating func beginGesture(isTrackpad: Bool) {
        let currentOffset = viewOffsetPixels.current()
        viewOffsetPixels = .gesture(ViewGesture(startOffsetPixels: Double(currentOffset), isTrackpad: isTrackpad))
        selectionProgress = 0.0
    }

    mutating func updateGesture(
        deltaPixels: CGFloat,
        timestamp: TimeInterval,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat
    ) -> Int? {
        guard case let .gesture(gesture) = viewOffsetPixels else {
            return nil
        }

        gesture.tracker.push(delta: Double(deltaPixels), timestamp: timestamp)

        let totalW = totalWidth(columns: columns, gap: gap)
        let maxOffset: CGFloat = 0
        let minOffset = viewportWidth - totalW

        let currentOffset = CGFloat(gesture.currentOffsetPixels)
        if minOffset < maxOffset {
            let clampedOffset = currentOffset.clamped(to: minOffset ... maxOffset)
            if abs(clampedOffset - currentOffset) > 0.5 {
                viewOffsetPixels = .gesture(ViewGesture(startOffsetPixels: Double(clampedOffset), isTrackpad: gesture.isTrackpad))
                if let newGesture = viewOffsetPixels.gestureRef {
                    newGesture.tracker.push(delta: 0, timestamp: timestamp)
                }
            }
        }

        guard !columns.isEmpty else { return nil }
        let avgColumnWidth = totalW / CGFloat(columns.count)
        selectionProgress += deltaPixels
        let steps = Int((selectionProgress / avgColumnWidth).rounded(.towardZero))
        if steps != 0 {
            selectionProgress -= CGFloat(steps) * avgColumnWidth
            return steps
        }
        return nil
    }

    mutating func endGesture(
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat
    ) {
        guard case let .gesture(gesture) = viewOffsetPixels else {
            return
        }

        let velocity = gesture.tracker.velocity()
        let currentOffset = gesture.currentOffsetPixels

        let projectedEndOffset = gesture.tracker.projectedEndPosition()

        let totalW = totalWidth(columns: columns, gap: gap)
        let maxOffset: CGFloat = 0
        let minOffset = Double(viewportWidth - totalW)

        var targetOffset: Double
        if minOffset < maxOffset {
            targetOffset = min(max(projectedEndOffset, minOffset), Double(maxOffset))
        } else {
            targetOffset = 0
        }

        if animationsEnabled {
            let now = CACurrentMediaTime()
            switch gestureAnimationType {
            case .spring:
                let animation = SpringAnimation(
                    from: currentOffset,
                    to: targetOffset,
                    initialVelocity: velocity,
                    startTime: now,
                    config: gestureSpringConfig
                )
                viewOffsetPixels = .spring(animation)
            case .easing:
                let animation = ViewAnimation(
                    from: currentOffset,
                    to: targetOffset,
                    duration: gestureEasingDuration,
                    curve: gestureEasingCurve,
                    startTime: now,
                    initialVelocity: velocity
                )
                viewOffsetPixels = .animating(animation)
            }
        } else {
            viewOffsetPixels = .static(CGFloat(targetOffset))
        }

        selectionProgress = 0.0
    }

    mutating func tickAnimation(at time: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        switch viewOffsetPixels {
        case let .animating(anim):
            if anim.isComplete(at: time) {
                let finalOffset = CGFloat(anim.targetValue)
                viewOffsetPixels = .static(finalOffset)
                return false
            }
            return true

        case let .decelerating(anim):
            if anim.isComplete(at: time) {
                let finalOffset = CGFloat(anim.targetValue)
                viewOffsetPixels = .static(finalOffset)
                return false
            }
            return true

        case let .spring(anim):
            if anim.isComplete(at: time) {
                let finalOffset = CGFloat(anim.target)
                viewOffsetPixels = .static(finalOffset)
                return false
            }
            return true

        default:
            return false
        }
    }

    mutating func cancelAnimation() {
        let current = viewOffsetPixels.current()
        viewOffsetPixels = .static(current)
    }

    mutating func reset() {
        activeColumnIndex = 0
        viewOffsetPixels = .static(0.0)
        selectionProgress = 0.0
        selectedNodeId = nil
    }

    mutating func ensureColumnVisible(
        columnIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        preferredEdge: NiriRevealEdge? = nil,
        animate: Bool = true
    ) {
        guard !columns.isEmpty, columnIndex >= 0, columnIndex < columns.count else { return }

        let colX = columnX(at: columnIndex, columns: columns, gap: gap)
        let colWidth = columns[columnIndex].cachedWidth
        let currentOffset = viewOffsetPixels.current()

        let viewLeft = -currentOffset
        let viewRight = viewLeft + viewportWidth

        let colLeft = colX
        let colRight = colX + colWidth

        var targetOffset = currentOffset

        if colLeft < viewLeft {
            targetOffset = -colX
        } else if colRight > viewRight {
            targetOffset = viewportWidth - colRight
        }

        let totalW = totalWidth(columns: columns, gap: gap)
        let maxOffset: CGFloat = 0
        let minOffset = viewportWidth - totalW
        if minOffset < maxOffset {
            targetOffset = targetOffset.clamped(to: minOffset ... maxOffset)
        }

        if abs(targetOffset - currentOffset) < 1 {
            return
        }

        if animate && animationsEnabled {
            let now = CACurrentMediaTime()
            switch columnRevealAnimationType {
            case .spring:
                let animation = SpringAnimation(
                    from: Double(currentOffset),
                    to: Double(targetOffset),
                    initialVelocity: 0,
                    startTime: now,
                    config: columnRevealSpringConfig
                )
                viewOffsetPixels = .spring(animation)
            case .easing:
                let animation = ViewAnimation(
                    from: Double(currentOffset),
                    to: Double(targetOffset),
                    duration: columnRevealEasingDuration,
                    curve: columnRevealEasingCurve,
                    startTime: now
                )
                viewOffsetPixels = .animating(animation)
            }
        } else {
            viewOffsetPixels = .static(targetOffset)
        }
    }
}

enum NiriRevealEdge {
    case left
    case right
}

extension ViewportState {
    mutating func snapToColumn(
        _ columnIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat
    ) {
        guard !columns.isEmpty else { return }
        let clampedIndex = columnIndex.clamped(to: 0 ... (columns.count - 1))
        activeColumnIndex = clampedIndex

        let targetOffset = computeCenteredOffset(
            columnIndex: clampedIndex,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth
        )
        viewOffsetPixels = .static(targetOffset)
        selectionProgress = 0
    }
}
