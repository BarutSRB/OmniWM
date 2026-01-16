import AppKit
import Foundation

private let VIEW_GESTURE_WORKING_AREA_MOVEMENT: Double = 1200.0

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

    var animationsEnabled: Bool = true
    let springConfig: SpringConfig = .default

    var animationClock: AnimationClock?

    var displayRefreshRate: Double = 60.0

    func columnX(at index: Int, columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        var x: CGFloat = 0
        for i in 0 ..< index {
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

    func targetViewPosPixels(columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        let activeColX = columnX(at: activeColumnIndex, columns: columns, gap: gap)
        return activeColX + viewOffsetPixels.target()
    }

    func currentViewOffset() -> CGFloat {
        viewOffsetPixels.current()
    }

    mutating func advanceAnimations(at time: CFTimeInterval) -> Bool {
        return tickAnimation(at: time)
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

    mutating func animateToOffset(_ offset: CGFloat, config: SpringConfig? = nil, scale: CGFloat = 2.0) {
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

    mutating func saveViewOffsetForFullscreen() {
        viewOffsetToRestore = stationary()
    }

    mutating func restoreViewOffset(_ offset: CGFloat) {
        viewOffsetPixels = .static(offset)
        viewOffsetToRestore = nil
    }

    mutating func animateViewOffsetRestore(_ offset: CGFloat) {
        guard !viewOffsetPixels.isGesture else {
            viewOffsetToRestore = nil
            return
        }

        let now = animationClock?.now() ?? CACurrentMediaTime()
        let currentOffset = viewOffsetPixels.current()
        let velocity = viewOffsetPixels.currentVelocity()

        let animation = SpringAnimation(
            from: Double(currentOffset),
            to: Double(offset),
            initialVelocity: velocity,
            startTime: now,
            config: springConfig,
            displayRefreshRate: displayRefreshRate
        )
        viewOffsetPixels = .spring(animation)
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

        viewOffsetPixels.offset(delta: Double(offsetDelta))

        let targetOffset = computeCenteredOffset(
            columnIndex: clampedIndex,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth
        )

        if animate, animationsEnabled {
            animateToOffset(targetOffset)
        } else {
            viewOffsetPixels = .static(targetOffset)
        }

        activeColumnIndex = clampedIndex
        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
    }

    mutating func transitionToColumn(
        _ newIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        animate: Bool,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false,
        fromColumnIndex: Int? = nil,
        scale: CGFloat = 2.0
    ) {
        guard !columns.isEmpty else { return }
        let clampedIndex = newIndex.clamped(to: 0 ... (columns.count - 1))

        let oldActiveColX = columnX(at: activeColumnIndex, columns: columns, gap: gap)

        let prevActiveColumn = activeColumnIndex
        activeColumnIndex = clampedIndex

        let newActiveColX = columnX(at: clampedIndex, columns: columns, gap: gap)
        let offsetDelta = oldActiveColX - newActiveColX

        viewOffsetPixels.offset(delta: Double(offsetDelta))

        let targetOffset = computeVisibleOffset(
            columnIndex: clampedIndex,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth,
            currentOffset: viewOffsetPixels.target(),
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            fromColumnIndex: fromColumnIndex ?? prevActiveColumn
        )

        let pixel: CGFloat = 1.0 / scale
        let toDiff = targetOffset - viewOffsetPixels.target()
        if abs(toDiff) < pixel {
            viewOffsetPixels.offset(delta: Double(toDiff))
            activatePrevColumnOnRemoval = nil
            viewOffsetToRestore = nil
            return
        }

        if animate, animationsEnabled {
            animateToOffset(targetOffset)
        } else {
            viewOffsetPixels = .static(targetOffset)
        }

        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
    }

    func computeVisibleOffset(
        columnIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        currentOffset: CGFloat,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false,
        fromColumnIndex: Int? = nil
    ) -> CGFloat {
        guard !columns.isEmpty, columnIndex >= 0, columnIndex < columns.count else { return 0 }

        let effectiveCenterMode = (columns.count == 1 && alwaysCenterSingleColumn) ? .always : centerMode

        let colX = columnX(at: columnIndex, columns: columns, gap: gap)
        let colWidth = columns[columnIndex].cachedWidth
        let viewLeft = colX + currentOffset

        var targetOffset = currentOffset

        switch effectiveCenterMode {
        case .always:
            targetOffset = computeCenteredOffset(
                columnIndex: columnIndex,
                columns: columns,
                gap: gap,
                viewportWidth: viewportWidth
            )

        case .onOverflow:
            if colWidth > viewportWidth {
                targetOffset = computeCenteredOffset(
                    columnIndex: columnIndex,
                    columns: columns,
                    gap: gap,
                    viewportWidth: viewportWidth
                )
            } else if let fromIdx = fromColumnIndex, fromIdx != columnIndex {
                let sourceIdx = fromIdx > columnIndex
                    ? min(columnIndex + 1, columns.count - 1)
                    : max(columnIndex - 1, 0)

                guard sourceIdx >= 0, sourceIdx < columns.count else {
                    targetOffset = computeNewViewOffsetFit(
                        currentViewX: viewLeft,
                        viewWidth: viewportWidth,
                        newColumnX: colX,
                        newColumnWidth: colWidth,
                        gaps: gap
                    )
                    break
                }

                let sourceColX = columnX(at: sourceIdx, columns: columns, gap: gap)
                let sourceColWidth = columns[sourceIdx].cachedWidth

                let totalWidth: CGFloat = if sourceColX < colX {
                    colX - sourceColX + colWidth + gap * 2
                } else {
                    sourceColX - colX + sourceColWidth + gap * 2
                }

                if totalWidth <= viewportWidth {
                    targetOffset = computeNewViewOffsetFit(
                        currentViewX: viewLeft,
                        viewWidth: viewportWidth,
                        newColumnX: colX,
                        newColumnWidth: colWidth,
                        gaps: gap
                    )
                } else {
                    targetOffset = computeCenteredOffset(
                        columnIndex: columnIndex,
                        columns: columns,
                        gap: gap,
                        viewportWidth: viewportWidth
                    )
                }
            } else {
                targetOffset = computeNewViewOffsetFit(
                    currentViewX: viewLeft,
                    viewWidth: viewportWidth,
                    newColumnX: colX,
                    newColumnWidth: colWidth,
                    gaps: gap
                )
            }

        case .never:
            targetOffset = computeNewViewOffsetFit(
                currentViewX: viewLeft,
                viewWidth: viewportWidth,
                newColumnX: colX,
                newColumnWidth: colWidth,
                gaps: gap
            )
        }

        let totalW = totalWidth(columns: columns, gap: gap)
        let maxOffset: CGFloat = 0
        let minOffset = viewportWidth - totalW
        if minOffset < maxOffset {
            targetOffset = targetOffset.clamped(to: minOffset ... maxOffset)
        }

        return targetOffset
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
            return -colX - (viewportWidth - totalW) / 2
        }

        let colWidth = columns[columnIndex].cachedWidth
        let centeredOffset = -(viewportWidth - colWidth) / 2

        let maxOffset: CGFloat = 0
        let minOffset = viewportWidth - totalW

        return centeredOffset.clamped(to: minOffset ... maxOffset)
    }

    private func computeNewViewOffsetFit(
        currentViewX: CGFloat,
        viewWidth: CGFloat,
        newColumnX: CGFloat,
        newColumnWidth: CGFloat,
        gaps: CGFloat
    ) -> CGFloat {
        if viewWidth <= newColumnWidth {
            return 0
        }

        let padding = ((viewWidth - newColumnWidth) / 2).clamped(to: 0 ... gaps)
        let newX = newColumnX - padding
        let newRightX = newColumnX + newColumnWidth + padding

        if currentViewX <= newX && newRightX <= currentViewX + viewWidth {
            return -(newColumnX - currentViewX)
        }

        let distToLeft = abs(currentViewX - newX)
        let distToRight = abs((currentViewX + viewWidth) - newRightX)

        if distToLeft <= distToRight {
            return -padding
        } else {
            return -(viewWidth - padding - newColumnWidth)
        }
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
        viewOffsetPixels = .gesture(ViewGesture(currentViewOffset: Double(currentOffset), isTrackpad: isTrackpad))
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

        let normFactor = gesture.isTrackpad
            ? Double(viewportWidth) / VIEW_GESTURE_WORKING_AREA_MOVEMENT
            : 1.0
        let pos = gesture.tracker.position * normFactor
        let viewOffset = pos + gesture.deltaFromTracker

        guard !columns.isEmpty else {
            gesture.currentViewOffset = viewOffset
            return nil
        }

        let activeColX = Double(columnX(at: activeColumnIndex, columns: columns, gap: gap))
        let totalW = Double(totalWidth(columns: columns, gap: gap))
        var leftmost = 0.0
        var rightmost = max(0, totalW - Double(viewportWidth))
        leftmost -= activeColX
        rightmost -= activeColX

        let minOffset = min(leftmost, rightmost)
        let maxOffset = max(leftmost, rightmost)
        let clampedOffset = Swift.min(Swift.max(viewOffset, minOffset), maxOffset)

        gesture.deltaFromTracker += clampedOffset - viewOffset
        gesture.currentViewOffset = clampedOffset

        let avgColumnWidth = Double(totalWidth(columns: columns, gap: gap)) / Double(columns.count)
        selectionProgress += deltaPixels
        let steps = Int((selectionProgress / CGFloat(avgColumnWidth)).rounded(.towardZero))
        if steps != 0 {
            selectionProgress -= CGFloat(steps) * CGFloat(avgColumnWidth)
            return steps
        }
        return nil
    }

    mutating func endGesture(
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        centerMode: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false
    ) {
        guard case let .gesture(gesture) = viewOffsetPixels else {
            return
        }

        let velocity = gesture.currentVelocity()
        let currentOffset = gesture.current()

        let normFactor = gesture.isTrackpad
            ? Double(viewportWidth) / VIEW_GESTURE_WORKING_AREA_MOVEMENT
            : 1.0
        let projectedTrackerPos = gesture.tracker.projectedEndPosition() * normFactor
        let projectedOffset = projectedTrackerPos + gesture.deltaFromTracker

        let activeColX = columnX(at: activeColumnIndex, columns: columns, gap: gap)
        let currentViewPos = Double(activeColX) + currentOffset
        let projectedViewPos = Double(activeColX) + projectedOffset

        let result = findSnapPointsAndTarget(
            projectedViewPos: projectedViewPos,
            currentViewPos: currentViewPos,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        let newColX = columnX(at: result.columnIndex, columns: columns, gap: gap)
        let offsetDelta = activeColX - newColX

        activeColumnIndex = result.columnIndex

        let targetOffset = result.viewPos - Double(newColX)

        let totalW = totalWidth(columns: columns, gap: gap)
        let maxOffset: Double = 0
        let minOffset = Double(viewportWidth - totalW)
        let clampedTarget = min(max(targetOffset, minOffset), maxOffset)

        if animationsEnabled {
            let now = animationClock?.now() ?? CACurrentMediaTime()
            let animation = SpringAnimation(
                from: currentOffset + Double(offsetDelta),
                to: clampedTarget,
                initialVelocity: velocity,
                startTime: now,
                config: springConfig,
                displayRefreshRate: displayRefreshRate
            )
            viewOffsetPixels = .spring(animation)
        } else {
            viewOffsetPixels = .static(CGFloat(clampedTarget))
        }

        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
        selectionProgress = 0.0
    }

    struct SnapResult {
        let viewPos: Double
        let columnIndex: Int
    }

    private func findSnapPointsAndTarget(
        projectedViewPos: Double,
        currentViewPos: Double,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false
    ) -> SnapResult {
        guard !columns.isEmpty else { return SnapResult(viewPos: 0, columnIndex: 0) }

        let effectiveCenterMode = (columns.count == 1 && alwaysCenterSingleColumn) ? .always : centerMode

        let vw = Double(viewportWidth)
        let gaps = Double(gap)
        var snapPoints: [(viewPos: Double, columnIndex: Int)] = []

        if effectiveCenterMode == .always {
            for (idx, _) in columns.enumerated() {
                let colX = Double(columnX(at: idx, columns: columns, gap: gap))
                let offset = Double(computeCenteredOffset(
                    columnIndex: idx,
                    columns: columns,
                    gap: gap,
                    viewportWidth: viewportWidth
                ))
                let snapViewPos = colX + offset
                snapPoints.append((snapViewPos, idx))
            }
        } else {
            var colX: Double = 0
            for (idx, col) in columns.enumerated() {
                let colW = Double(col.cachedWidth)
                let padding = max(0, min((vw - colW) / 2.0, gaps))

                let leftSnap = colX - padding
                let rightSnap = colX + colW + padding - vw

                snapPoints.append((leftSnap, idx))
                if rightSnap != leftSnap {
                    snapPoints.append((rightSnap, idx))
                }
                colX += colW + gaps
            }
        }

        let totalW = Double(totalWidth(columns: columns, gap: gap))
        let maxViewPos: Double = 0
        let minViewPos = vw - totalW

        let clampedSnaps = snapPoints.map { snap -> (viewPos: Double, columnIndex: Int) in
            let clampedPos = min(max(snap.viewPos, minViewPos), maxViewPos)
            return (clampedPos, snap.columnIndex)
        }

        guard let closest = clampedSnaps.min(by: { abs($0.viewPos - projectedViewPos) < abs($1.viewPos - projectedViewPos) }) else {
            return SnapResult(viewPos: 0, columnIndex: 0)
        }

        var newColIdx = closest.columnIndex

        if effectiveCenterMode != .always {
            let scrollingRight = projectedViewPos >= currentViewPos
            if scrollingRight {
                for idx in (newColIdx + 1) ..< columns.count {
                    let colX = Double(columnX(at: idx, columns: columns, gap: gap))
                    let colW = Double(columns[idx].cachedWidth)
                    let padding = max(0, min((vw - colW) / 2.0, gaps))
                    if closest.viewPos + vw >= colX + colW + padding {
                        newColIdx = idx
                    } else {
                        break
                    }
                }
            } else {
                for idx in stride(from: newColIdx - 1, through: 0, by: -1) {
                    let colX = Double(columnX(at: idx, columns: columns, gap: gap))
                    let colW = Double(columns[idx].cachedWidth)
                    let padding = max(0, min((vw - colW) / 2.0, gaps))
                    if colX - padding >= closest.viewPos {
                        newColIdx = idx
                    } else {
                        break
                    }
                }
            }
        }

        return SnapResult(viewPos: closest.viewPos, columnIndex: newColIdx)
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

    mutating func offsetViewport(by delta: CGFloat) {
        let current = viewOffsetPixels.current()
        viewOffsetPixels = .static(current + delta)
    }

    mutating func ensureColumnVisible(
        columnIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        preferredEdge: NiriRevealEdge? = nil,
        animate: Bool = true,
        centerMode: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false,
        animationConfig: SpringConfig? = nil,
        fromColumnIndex: Int? = nil
    ) {
        guard !columns.isEmpty, columnIndex >= 0, columnIndex < columns.count else { return }

        let effectiveCenterMode = (columns.count == 1 && alwaysCenterSingleColumn) ? .always : centerMode

        let colX = columnX(at: columnIndex, columns: columns, gap: gap)
        let colWidth = columns[columnIndex].cachedWidth
        let checkOffset = viewOffsetPixels.target()
        let animStartOffset = viewOffsetPixels.current()
        let activeColX = columnX(at: activeColumnIndex, columns: columns, gap: gap)

        var targetOffset = checkOffset

        switch effectiveCenterMode {
        case .always:
            targetOffset = computeCenteredOffset(
                columnIndex: columnIndex,
                columns: columns,
                gap: gap,
                viewportWidth: viewportWidth
            )

        case .onOverflow:
            if colWidth > viewportWidth {
                targetOffset = computeCenteredOffset(
                    columnIndex: columnIndex,
                    columns: columns,
                    gap: gap,
                    viewportWidth: viewportWidth
                )
            } else if let fromIdx = fromColumnIndex, fromIdx != columnIndex {
                let sourceIdx = fromIdx > columnIndex
                    ? min(columnIndex + 1, columns.count - 1)
                    : max(columnIndex - 1, 0)

                guard sourceIdx >= 0, sourceIdx < columns.count else {
                    let offsetDelta = activeColX - colX
                    let adjustedViewLeft = colX + (checkOffset + offsetDelta)
                    targetOffset = computeNewViewOffsetFit(
                        currentViewX: adjustedViewLeft,
                        viewWidth: viewportWidth,
                        newColumnX: colX,
                        newColumnWidth: colWidth,
                        gaps: gap
                    )
                    break
                }

                let sourceColX = columnX(at: sourceIdx, columns: columns, gap: gap)
                let sourceColWidth = columns[sourceIdx].cachedWidth

                let totalWidth: CGFloat = if sourceColX < colX {
                    colX - sourceColX + colWidth + gap * 2
                } else {
                    sourceColX - colX + sourceColWidth + gap * 2
                }

                let offsetDelta = activeColX - colX
                let adjustedViewLeft = colX + (checkOffset + offsetDelta)

                if totalWidth <= viewportWidth {
                    targetOffset = computeNewViewOffsetFit(
                        currentViewX: adjustedViewLeft,
                        viewWidth: viewportWidth,
                        newColumnX: colX,
                        newColumnWidth: colWidth,
                        gaps: gap
                    )
                } else {
                    targetOffset = computeCenteredOffset(
                        columnIndex: columnIndex,
                        columns: columns,
                        gap: gap,
                        viewportWidth: viewportWidth
                    )
                }
            } else {
                let offsetDelta = activeColX - colX
                let adjustedViewLeft = colX + (checkOffset + offsetDelta)
                targetOffset = computeNewViewOffsetFit(
                    currentViewX: adjustedViewLeft,
                    viewWidth: viewportWidth,
                    newColumnX: colX,
                    newColumnWidth: colWidth,
                    gaps: gap
                )
            }

        case .never:
            let offsetDelta = activeColX - colX
            let adjustedViewLeft = colX + (checkOffset + offsetDelta)
            targetOffset = computeNewViewOffsetFit(
                currentViewX: adjustedViewLeft,
                viewWidth: viewportWidth,
                newColumnX: colX,
                newColumnWidth: colWidth,
                gaps: gap
            )
        }

        let totalW = totalWidth(columns: columns, gap: gap)
        let maxOffset: CGFloat = 0
        let minOffset = viewportWidth - totalW
        if minOffset < maxOffset {
            targetOffset = targetOffset.clamped(to: minOffset ... maxOffset)
        }

        let needsScroll = abs(targetOffset - animStartOffset) >= 0.001

        if !needsScroll {
            return
        }

        if animate, animationsEnabled {
            let now = animationClock?.now() ?? CACurrentMediaTime()
            let currentVelocity = viewOffsetPixels.currentVelocity()
            let config = animationConfig ?? springConfig
            let animation = SpringAnimation(
                from: Double(animStartOffset),
                to: Double(targetOffset),
                initialVelocity: currentVelocity,
                startTime: now,
                config: config,
                displayRefreshRate: displayRefreshRate
            )
            viewOffsetPixels = .spring(animation)
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

extension ViewportState {
    func rowY(at index: Int, rows: [NiriContainer], gap: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        for i in 0 ..< index {
            guard i < rows.count else { break }
            y += rows[i].cachedHeight + gap
        }
        return y
    }

    func totalHeight(rows: [NiriContainer], gap: CGFloat) -> CGFloat {
        guard !rows.isEmpty else { return 0 }
        let heightSum = rows.reduce(0) { $0 + $1.cachedHeight }
        let gapSum = CGFloat(max(0, rows.count - 1)) * gap
        return heightSum + gapSum
    }

    func computeCenteredOffsetVertical(
        rowIndex: Int,
        rows: [NiriContainer],
        gap: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        guard !rows.isEmpty, rowIndex < rows.count else { return 0 }

        let totalH = totalHeight(rows: rows, gap: gap)

        if totalH <= viewportHeight {
            let rowYPos = rowY(at: rowIndex, rows: rows, gap: gap)
            return -rowYPos - (viewportHeight - totalH) / 2
        }

        let rowHeight = rows[rowIndex].cachedHeight
        let centeredOffset = -(viewportHeight - rowHeight) / 2

        let maxOffset: CGFloat = 0
        let minOffset = viewportHeight - totalH

        return centeredOffset.clamped(to: minOffset ... maxOffset)
    }

    private func computeNewViewOffsetFitVertical(
        currentViewY: CGFloat,
        viewHeight: CGFloat,
        newRowY: CGFloat,
        newRowHeight: CGFloat,
        gaps: CGFloat
    ) -> CGFloat {
        if viewHeight <= newRowHeight {
            return 0
        }

        let padding = ((viewHeight - newRowHeight) / 2).clamped(to: 0 ... gaps)
        let newY = newRowY - padding
        let newBottomY = newRowY + newRowHeight + padding

        if currentViewY <= newY && newBottomY <= currentViewY + viewHeight {
            return -(newRowY - currentViewY)
        }

        let distToTop = abs(currentViewY - newY)
        let distToBottom = abs((currentViewY + viewHeight) - newBottomY)

        if distToTop <= distToBottom {
            return -padding
        } else {
            return -(viewHeight - padding - newRowHeight)
        }
    }

    mutating func ensureRowVisible(
        rowIndex: Int,
        rows: [NiriContainer],
        gap: CGFloat,
        viewportHeight: CGFloat,
        animate: Bool = true,
        centerMode: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false,
        animationConfig: SpringConfig? = nil,
        fromRowIndex: Int? = nil
    ) {
        guard !rows.isEmpty, rowIndex >= 0, rowIndex < rows.count else { return }

        let effectiveCenterMode = (rows.count == 1 && alwaysCenterSingleColumn) ? .always : centerMode

        let rowYPos = rowY(at: rowIndex, rows: rows, gap: gap)
        let rowHeight = rows[rowIndex].cachedHeight
        let currentOffset = viewOffsetPixels.current()
        let activeRowY = rowY(at: activeColumnIndex, rows: rows, gap: gap)

        var targetOffset = currentOffset

        switch effectiveCenterMode {
        case .always:
            targetOffset = computeCenteredOffsetVertical(
                rowIndex: rowIndex,
                rows: rows,
                gap: gap,
                viewportHeight: viewportHeight
            )

        case .onOverflow:
            if rowHeight > viewportHeight {
                targetOffset = computeCenteredOffsetVertical(
                    rowIndex: rowIndex,
                    rows: rows,
                    gap: gap,
                    viewportHeight: viewportHeight
                )
            } else if let fromIdx = fromRowIndex, fromIdx != rowIndex {
                let sourceIdx = fromIdx > rowIndex
                    ? min(rowIndex + 1, rows.count - 1)
                    : max(rowIndex - 1, 0)

                guard sourceIdx >= 0, sourceIdx < rows.count else {
                    let offsetDelta = activeRowY - rowYPos
                    let adjustedViewTop = rowYPos + (currentOffset + offsetDelta)
                    targetOffset = computeNewViewOffsetFitVertical(
                        currentViewY: adjustedViewTop,
                        viewHeight: viewportHeight,
                        newRowY: rowYPos,
                        newRowHeight: rowHeight,
                        gaps: gap
                    )
                    break
                }

                let sourceRowY = rowY(at: sourceIdx, rows: rows, gap: gap)
                let sourceRowHeight = rows[sourceIdx].cachedHeight

                let totalHeightNeeded: CGFloat = if sourceRowY < rowYPos {
                    rowYPos - sourceRowY + rowHeight + gap * 2
                } else {
                    sourceRowY - rowYPos + sourceRowHeight + gap * 2
                }

                let offsetDelta = activeRowY - rowYPos
                let adjustedViewTop = rowYPos + (currentOffset + offsetDelta)

                if totalHeightNeeded <= viewportHeight {
                    targetOffset = computeNewViewOffsetFitVertical(
                        currentViewY: adjustedViewTop,
                        viewHeight: viewportHeight,
                        newRowY: rowYPos,
                        newRowHeight: rowHeight,
                        gaps: gap
                    )
                } else {
                    targetOffset = computeCenteredOffsetVertical(
                        rowIndex: rowIndex,
                        rows: rows,
                        gap: gap,
                        viewportHeight: viewportHeight
                    )
                }
            } else {
                let offsetDelta = activeRowY - rowYPos
                let adjustedViewTop = rowYPos + (currentOffset + offsetDelta)
                targetOffset = computeNewViewOffsetFitVertical(
                    currentViewY: adjustedViewTop,
                    viewHeight: viewportHeight,
                    newRowY: rowYPos,
                    newRowHeight: rowHeight,
                    gaps: gap
                )
            }

        case .never:
            let offsetDelta = activeRowY - rowYPos
            let adjustedViewTop = rowYPos + (currentOffset + offsetDelta)
            targetOffset = computeNewViewOffsetFitVertical(
                currentViewY: adjustedViewTop,
                viewHeight: viewportHeight,
                newRowY: rowYPos,
                newRowHeight: rowHeight,
                gaps: gap
            )
        }

        let totalH = totalHeight(rows: rows, gap: gap)
        let maxOffset: CGFloat = 0
        let minOffset = viewportHeight - totalH
        if minOffset < maxOffset {
            targetOffset = targetOffset.clamped(to: minOffset ... maxOffset)
        }

        if abs(targetOffset - currentOffset) < 0.001 {
            return
        }

        if animate, animationsEnabled {
            let now = animationClock?.now() ?? CACurrentMediaTime()
            let currentVelocity = viewOffsetPixels.currentVelocity()
            let config = animationConfig ?? springConfig
            let animation = SpringAnimation(
                from: Double(currentOffset),
                to: Double(targetOffset),
                initialVelocity: currentVelocity,
                startTime: now,
                config: config,
                displayRefreshRate: displayRefreshRate
            )
            viewOffsetPixels = .spring(animation)
        } else {
            viewOffsetPixels = .static(targetOffset)
        }
    }
}

