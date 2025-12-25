import AppKit
import Foundation

enum ViewOffset {
    case `static`(CGFloat)

    func current() -> CGFloat {
        switch self {
        case let .static(offset):
            offset
        }
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
