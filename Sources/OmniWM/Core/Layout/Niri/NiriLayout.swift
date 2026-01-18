import AppKit
import Foundation

extension CGFloat {
    func roundedToPhysicalPixel(scale: CGFloat) -> CGFloat {
        (self * scale).rounded() / scale
    }
}

extension CGPoint {
    func roundedToPhysicalPixels(scale: CGFloat) -> CGPoint {
        CGPoint(
            x: x.roundedToPhysicalPixel(scale: scale),
            y: y.roundedToPhysicalPixel(scale: scale)
        )
    }
}

extension CGSize {
    func roundedToPhysicalPixels(scale: CGFloat) -> CGSize {
        CGSize(
            width: width.roundedToPhysicalPixel(scale: scale),
            height: height.roundedToPhysicalPixel(scale: scale)
        )
    }
}

extension CGRect {
    func roundedToPhysicalPixels(scale: CGFloat) -> CGRect {
        CGRect(
            origin: origin.roundedToPhysicalPixels(scale: scale),
            size: size.roundedToPhysicalPixels(scale: scale)
        )
    }
}

struct LayoutResult {
    let frames: [WindowHandle: CGRect]
    let hiddenHandles: [WindowHandle: HideSide]
}

extension NiriLayoutEngine {
    func calculateLayout(
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        focusedColumnIndex _: Int? = nil,
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        orientation: Monitor.Orientation = .horizontal
    ) -> [WindowHandle: CGRect] {
        calculateLayoutWithVisibility(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: monitorFrame,
            screenFrame: screenFrame,
            gaps: gaps,
            scale: scale,
            workingArea: workingArea,
            orientation: orientation
        ).frames
    }

    func calculateLayoutWithVisibility(
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        orientation: Monitor.Orientation = .horizontal,
        animationTime: TimeInterval? = nil
    ) -> LayoutResult {
        var frames: [WindowHandle: CGRect] = [:]
        var hiddenHandles: [WindowHandle: HideSide] = [:]
        calculateLayoutInto(
            frames: &frames,
            hiddenHandles: &hiddenHandles,
            state: state,
            workspaceId: workspaceId,
            monitorFrame: monitorFrame,
            screenFrame: screenFrame,
            gaps: gaps,
            scale: scale,
            workingArea: workingArea,
            orientation: orientation,
            animationTime: animationTime
        )
        return LayoutResult(frames: frames, hiddenHandles: hiddenHandles)
    }

    func calculateLayoutInto(
        frames: inout [WindowHandle: CGRect],
        hiddenHandles: inout [WindowHandle: HideSide],
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        orientation: Monitor.Orientation = .horizontal,
        animationTime: TimeInterval? = nil
    ) {
        switch orientation {
        case .horizontal:
            calculateHorizontalLayoutInto(
                frames: &frames,
                hiddenHandles: &hiddenHandles,
                state: state,
                workspaceId: workspaceId,
                monitorFrame: monitorFrame,
                screenFrame: screenFrame,
                gaps: gaps,
                scale: scale,
                workingArea: workingArea,
                animationTime: animationTime
            )
        case .vertical:
            calculateVerticalLayoutInto(
                frames: &frames,
                hiddenHandles: &hiddenHandles,
                state: state,
                workspaceId: workspaceId,
                monitorFrame: monitorFrame,
                screenFrame: screenFrame,
                gaps: gaps,
                scale: scale,
                workingArea: workingArea,
                animationTime: animationTime
            )
        }
    }

    private func calculateHorizontalLayoutInto(
        frames: inout [WindowHandle: CGRect],
        hiddenHandles: inout [WindowHandle: HideSide],
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        animationTime: TimeInterval? = nil
    ) {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return }

        let workingFrame = workingArea?.workingFrame ?? monitorFrame
        let viewFrame = workingArea?.viewFrame ?? screenFrame ?? monitorFrame
        let effectiveScale = workingArea?.scale ?? scale

        let horizontalGap = gaps.horizontal

        let time = animationTime ?? CACurrentMediaTime()

        for column in cols {
            if column.cachedWidth <= 0 {
                column.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: horizontalGap)
            }
        }

        let columnWidths = cols.map { $0.cachedWidth }
        let columnRenderOffsets = cols.map { $0.renderOffset(at: time) }
        let columnWindowNodes = cols.map { $0.windowNodes }

        var columnXPositions = [CGFloat]()
        columnXPositions.reserveCapacity(cols.count)
        var runningX: CGFloat = 0
        var totalColumnsWidth: CGFloat = 0
        for i in 0 ..< cols.count {
            columnXPositions.append(runningX)
            let width = columnWidths[i]
            runningX += width + horizontalGap
            totalColumnsWidth += width
            if i < cols.count - 1 {
                totalColumnsWidth += horizontalGap
            }
        }

        let viewOffset = state.viewOffsetPixels.value(at: time)
        let activeColIdx = state.activeColumnIndex.clamped(to: 0 ... max(0, cols.count - 1))
        let activeColX = cols.isEmpty ? 0 : columnXPositions[activeColIdx]
        let viewPos = activeColX + viewOffset
        let viewLeft = viewPos
        let viewRight = viewLeft + workingFrame.width

        var usedIndices = Set<Int>()
        var columnSides: [Int: HideSide] = [:]

        for idx in 0 ..< cols.count {
            let colX = columnXPositions[idx]
            let colWidth = columnWidths[idx]
            let colRight = colX + colWidth
            let columnRenderOffset = columnRenderOffsets[idx]

            let isVisible = colRight > viewLeft && colX < viewRight

            if isVisible {
                usedIndices.insert(idx)

                let screenX = workingFrame.origin.x + colX - viewPos + columnRenderOffset.x
                let width = colWidth.roundedToPhysicalPixel(scale: effectiveScale)

                let columnRect = CGRect(
                    x: screenX,
                    y: workingFrame.origin.y,
                    width: width,
                    height: workingFrame.height
                ).roundedToPhysicalPixels(scale: effectiveScale)

                layoutColumn(
                    column: cols[idx],
                    columnRect: columnRect,
                    screenRect: viewFrame,
                    verticalGap: gaps.vertical,
                    scale: effectiveScale,
                    columnRenderOffset: columnRenderOffset,
                    animationTime: time,
                    result: &frames
                )
            } else {
                let hideSide: HideSide = colRight <= viewLeft ? .left : .right
                columnSides[idx] = hideSide
                for window in columnWindowNodes[idx] {
                    hiddenHandles[window.handle] = hideSide
                }
            }
        }

        if cols.count > usedIndices.count {
            let avgWidth = totalColumnsWidth / CGFloat(max(1, cols.count))
            let hiddenWidth = max(1, avgWidth).roundedToPhysicalPixel(scale: effectiveScale)
            for (idx, column) in cols.enumerated() {
                if usedIndices.contains(idx) { continue }

                let side = columnSides[idx] ?? .right
                let hiddenRect = hiddenColumnRect(
                    side: side,
                    width: hiddenWidth,
                    height: workingFrame.height,
                    screenY: viewFrame.maxY - 2
                ).roundedToPhysicalPixels(scale: effectiveScale)

                layoutColumn(
                    column: column,
                    columnRect: hiddenRect,
                    screenRect: viewFrame,
                    verticalGap: gaps.vertical,
                    scale: effectiveScale,
                    columnRenderOffset: .zero,
                    animationTime: time,
                    result: &frames
                )
            }
        }
    }

    private func calculateVerticalLayoutInto(
        frames: inout [WindowHandle: CGRect],
        hiddenHandles: inout [WindowHandle: HideSide],
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        animationTime: TimeInterval? = nil
    ) {
        let rows = columns(in: workspaceId)
        guard !rows.isEmpty else { return }

        let workingFrame = workingArea?.workingFrame ?? monitorFrame
        let viewFrame = workingArea?.viewFrame ?? screenFrame ?? monitorFrame
        let effectiveScale = workingArea?.scale ?? scale

        let verticalGap = gaps.vertical

        let time = animationTime ?? CACurrentMediaTime()

        for row in rows {
            if row.cachedHeight <= 0 {
                row.resolveAndCacheHeight(workingAreaHeight: workingFrame.height, gaps: verticalGap)
            }
        }

        let rowHeights = rows.map { $0.cachedHeight }
        let rowRenderOffsets = rows.map { $0.renderOffset(at: time) }
        let rowWindowNodes = rows.map { $0.windowNodes }

        var rowYPositions = [CGFloat]()
        rowYPositions.reserveCapacity(rows.count)
        var runningY: CGFloat = 0
        var totalRowsHeight: CGFloat = 0
        for i in 0 ..< rows.count {
            rowYPositions.append(runningY)
            let height = rowHeights[i]
            runningY += height + verticalGap
            totalRowsHeight += height
            if i < rows.count - 1 {
                totalRowsHeight += verticalGap
            }
        }

        let viewOffset = state.viewOffsetPixels.value(at: time)
        let activeRowIdx = state.activeColumnIndex.clamped(to: 0 ... max(0, rows.count - 1))
        let activeRowY = rows.isEmpty ? 0 : rowYPositions[activeRowIdx]
        let viewPos = activeRowY + viewOffset
        let viewTop = viewPos
        let viewBottom = viewTop + workingFrame.height

        var usedIndices = Set<Int>()

        for idx in 0 ..< rows.count {
            let rowYPos = rowYPositions[idx]
            let rowHeight = rowHeights[idx]
            let rowBottom = rowYPos + rowHeight
            let rowRenderOffset = rowRenderOffsets[idx]

            let isVisible = rowBottom > viewTop && rowYPos < viewBottom

            if isVisible {
                usedIndices.insert(idx)

                let screenY = workingFrame.origin.y + rowYPos - viewPos + rowRenderOffset.y
                let height = rowHeight.roundedToPhysicalPixel(scale: effectiveScale)

                let rowRect = CGRect(
                    x: workingFrame.origin.x,
                    y: screenY,
                    width: workingFrame.width,
                    height: height
                ).roundedToPhysicalPixels(scale: effectiveScale)

                layoutRow(
                    row: rows[idx],
                    rowRect: rowRect,
                    screenRect: viewFrame,
                    horizontalGap: gaps.horizontal,
                    scale: effectiveScale,
                    rowRenderOffset: rowRenderOffset,
                    animationTime: time,
                    result: &frames
                )
            } else {
                let hideSide: HideSide = rowBottom <= viewTop ? .left : .right
                for window in rowWindowNodes[idx] {
                    hiddenHandles[window.handle] = hideSide
                }
            }
        }

        if rows.count > usedIndices.count {
            let avgHeight = totalRowsHeight / CGFloat(max(1, rows.count))
            let hiddenHeight = max(1, avgHeight).roundedToPhysicalPixel(scale: effectiveScale)
            for (idx, row) in rows.enumerated() {
                if usedIndices.contains(idx) { continue }

                let hiddenRect = hiddenRowRect(
                    screenRect: viewFrame,
                    width: workingFrame.width,
                    height: hiddenHeight
                ).roundedToPhysicalPixels(scale: effectiveScale)

                layoutRow(
                    row: row,
                    rowRect: hiddenRect,
                    screenRect: viewFrame,
                    horizontalGap: gaps.horizontal,
                    scale: effectiveScale,
                    rowRenderOffset: .zero,
                    animationTime: time,
                    result: &frames
                )
            }
        }
    }

    private func layoutRow(
        row: NiriContainer,
        rowRect: CGRect,
        screenRect: CGRect,
        horizontalGap: CGFloat,
        scale: CGFloat,
        rowRenderOffset: CGPoint = .zero,
        animationTime: TimeInterval? = nil,
        result: inout [WindowHandle: CGRect]
    ) {
        row.frame = rowRect

        let tabOffset = row.isTabbed ? renderStyle.tabIndicatorWidth : 0
        let contentRect = CGRect(
            x: rowRect.origin.x + tabOffset,
            y: rowRect.origin.y,
            width: max(0, rowRect.width - tabOffset),
            height: rowRect.height
        )

        let windows = row.windowNodes
        guard !windows.isEmpty else { return }

        let isTabbed = row.isTabbed
        let time = animationTime ?? CACurrentMediaTime()

        let resolvedWidths = resolveWindowWidths(
            windows: windows,
            availableWidth: contentRect.width,
            horizontalGap: horizontalGap,
            isTabbed: isTabbed
        )

        let sizingModes = windows.map { $0.sizingMode }
        let windowRenderOffsets = windows.map { $0.renderOffset(at: time) }
        let windowHandles = windows.map { $0.handle }

        var x = contentRect.origin.x

        for i in 0 ..< windows.count {
            let windowWidth = resolvedWidths[i]
            let sizingMode = sizingModes[i]

            let frame: CGRect = switch sizingMode {
            case .fullscreen:
                screenRect.roundedToPhysicalPixels(scale: scale)
            case .normal:
                CGRect(
                    x: isTabbed ? contentRect.origin.x : x,
                    y: contentRect.origin.y,
                    width: windowWidth,
                    height: contentRect.height
                ).roundedToPhysicalPixels(scale: scale)
            }

            windows[i].frame = frame
            windows[i].resolvedWidth = windowWidth

            let windowOffset = windowRenderOffsets[i]
            let totalOffset = CGPoint(
                x: rowRenderOffset.x + windowOffset.x,
                y: rowRenderOffset.y + windowOffset.y
            )
            let animatedFrame = frame.offsetBy(dx: totalOffset.x, dy: totalOffset.y)
                .roundedToPhysicalPixels(scale: scale)
            result[windowHandles[i]] = animatedFrame

            if !isTabbed {
                x += windowWidth
                if i < windows.count - 1 {
                    x += horizontalGap
                }
            }
        }
    }

    private func resolveWindowWidths(
        windows: [NiriWindow],
        availableWidth: CGFloat,
        horizontalGap: CGFloat,
        isTabbed: Bool = false
    ) -> [CGFloat] {
        guard !windows.isEmpty else { return [] }

        let inputs: [NiriRowWidthSolver.WindowInput] = windows.map { window in
            let weight = window.widthWeight

            let isFixedWidth: Bool
            let fixedWidth: CGFloat?
            switch window.windowWidth {
            case let .fixed(w):
                isFixedWidth = true
                fixedWidth = w
            case .auto:
                isFixedWidth = false
                fixedWidth = nil
            }

            return NiriRowWidthSolver.WindowInput(
                weight: max(0.1, weight),
                constraints: window.constraints,
                isFixedWidth: isFixedWidth,
                fixedWidth: fixedWidth
            )
        }

        let outputs = NiriRowWidthSolver.solve(
            windows: inputs,
            availableWidth: availableWidth,
            gapSize: horizontalGap,
            isTabbed: isTabbed
        )

        for (i, output) in outputs.enumerated() {
            windows[i].widthFixedByConstraint = output.wasConstrained
        }

        return outputs.map(\.width)
    }

    private func hiddenRowRect(
        screenRect: CGRect,
        width: CGFloat,
        height: CGFloat
    ) -> CGRect {
        let origin = CGPoint(
            x: screenRect.maxX - 2,
            y: screenRect.maxY - 2
        )
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    private func layoutColumn(
        column: NiriContainer,
        columnRect: CGRect,
        screenRect: CGRect,
        verticalGap: CGFloat,
        scale: CGFloat,
        columnRenderOffset: CGPoint = .zero,
        animationTime: TimeInterval? = nil,
        result: inout [WindowHandle: CGRect]
    ) {
        column.frame = columnRect

        let tabOffset = column.isTabbed ? renderStyle.tabIndicatorWidth : 0
        let contentRect = CGRect(
            x: columnRect.origin.x + tabOffset,
            y: columnRect.origin.y,
            width: max(0, columnRect.width - tabOffset),
            height: columnRect.height
        )

        let rows = column.windowNodes
        guard !rows.isEmpty else { return }

        let isTabbed = column.isTabbed
        let time = animationTime ?? CACurrentMediaTime()

        let resolvedHeights = resolveWindowHeights(
            windows: rows,
            availableHeight: contentRect.height,
            verticalGap: verticalGap,
            isTabbed: isTabbed
        )

        let sizingModes = rows.map { $0.sizingMode }
        let rowRenderOffsets = rows.map { $0.renderOffset(at: time) }
        let rowHandles = rows.map { $0.handle }

        var y = contentRect.origin.y

        for i in 0 ..< rows.count {
            let rowHeight = resolvedHeights[i]
            let sizingMode = sizingModes[i]

            let frame: CGRect = switch sizingMode {
            case .fullscreen:
                screenRect.roundedToPhysicalPixels(scale: scale)
            case .normal:
                CGRect(
                    x: contentRect.origin.x,
                    y: isTabbed ? contentRect.origin.y : y,
                    width: contentRect.width,
                    height: rowHeight
                ).roundedToPhysicalPixels(scale: scale)
            }

            rows[i].frame = frame
            rows[i].resolvedHeight = rowHeight

            let windowOffset = rowRenderOffsets[i]
            let totalOffset = CGPoint(
                x: columnRenderOffset.x + windowOffset.x,
                y: columnRenderOffset.y + windowOffset.y
            )
            let animatedFrame = frame.offsetBy(dx: totalOffset.x, dy: totalOffset.y)
                .roundedToPhysicalPixels(scale: scale)
            result[rowHandles[i]] = animatedFrame

            if !isTabbed {
                y += rowHeight
                if i < rows.count - 1 {
                    y += verticalGap
                }
            }
        }
    }

    private func resolveWindowHeights(
        windows: [NiriWindow],
        availableHeight: CGFloat,
        verticalGap: CGFloat,
        isTabbed: Bool = false
    ) -> [CGFloat] {
        guard !windows.isEmpty else { return [] }

        let inputs: [NiriColumnHeightSolver.WindowInput] = windows.map { window in
            let weight = window.size

            let isFixedHeight: Bool
            let fixedHeight: CGFloat?
            switch window.height {
            case let .fixed(h):
                isFixedHeight = true
                fixedHeight = h
            case .auto:
                isFixedHeight = false
                fixedHeight = nil
            }

            return NiriColumnHeightSolver.WindowInput(
                weight: max(0.1, weight),
                constraints: window.constraints,
                isFixedHeight: isFixedHeight,
                fixedHeight: fixedHeight
            )
        }

        let outputs = NiriColumnHeightSolver.solve(
            windows: inputs,
            availableHeight: availableHeight,
            gapSize: verticalGap,
            isTabbed: isTabbed
        )

        for (i, output) in outputs.enumerated() {
            windows[i].heightFixedByConstraint = output.wasConstrained
        }

        return outputs.map(\.height)
    }

    private func hiddenColumnRect(
        side: HideSide,
        width: CGFloat,
        height: CGFloat,
        screenY: CGFloat
    ) -> CGRect {
        let globalBounds = ScreenCoordinateSpace.globalFrame
        let x: CGFloat
        switch side {
        case .left:
            x = globalBounds.minX - width + 2
        case .right:
            x = globalBounds.maxX - 2
        }
        let origin = CGPoint(x: x, y: screenY)
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }
}
