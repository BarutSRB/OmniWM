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

extension NiriLayoutEngine {
    func calculateLayout(
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        focusedColumnIndex _: Int? = nil,
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil
    ) -> [WindowHandle: CGRect] {
        var result: [WindowHandle: CGRect] = [:]

        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return result }

        let workingFrame = workingArea?.workingFrame ?? monitorFrame
        let viewFrame = workingArea?.viewFrame ?? screenFrame ?? monitorFrame
        let effectiveScale = workingArea?.scale ?? scale

        let horizontalGap = gaps.horizontal

        for column in cols {
            if column.cachedWidth <= 0 {
                column.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: horizontalGap)
            }
        }

        func columnX(at index: Int) -> CGFloat {
            var x: CGFloat = 0
            for i in 0..<index {
                x += cols[i].cachedWidth + horizontalGap
            }
            return x
        }

        let totalColumnsWidth = cols.reduce(0) { $0 + $1.cachedWidth } + CGFloat(max(0, cols.count - 1)) * horizontalGap

        let viewOffset = state.viewOffsetPixels.current()
        let viewLeft = -viewOffset
        let viewRight = viewLeft + workingFrame.width

        let centeringOffset: CGFloat
        if totalColumnsWidth < workingFrame.width {
            if alwaysCenterSingleColumn || cols.count == 1 {
                centeringOffset = (workingFrame.width - totalColumnsWidth) / 2
            } else {
                centeringOffset = 0
            }
        } else {
            centeringOffset = 0
        }

        var usedIndices = Set<Int>()

        for (idx, column) in cols.enumerated() {
            let colX = columnX(at: idx)
            let colRight = colX + column.cachedWidth

            let isVisible = colRight > viewLeft && colX < viewRight

            if isVisible {
                usedIndices.insert(idx)

                let screenX = workingFrame.origin.x + colX + viewOffset + centeringOffset
                let width = column.cachedWidth.roundedToPhysicalPixel(scale: effectiveScale)

                let columnRect = CGRect(
                    x: screenX,
                    y: workingFrame.origin.y,
                    width: width,
                    height: workingFrame.height
                ).roundedToPhysicalPixels(scale: effectiveScale)

                layoutColumn(
                    column: column,
                    columnRect: columnRect,
                    screenRect: viewFrame,
                    verticalGap: gaps.vertical,
                    scale: effectiveScale,
                    result: &result
                )
            }
        }

        if cols.count > usedIndices.count {
            let avgWidth = totalColumnsWidth / CGFloat(max(1, cols.count))
            let hiddenWidth = max(1, avgWidth).roundedToPhysicalPixel(scale: effectiveScale)
            for (idx, column) in cols.enumerated() {
                if usedIndices.contains(idx) { continue }

                let hiddenRect = hiddenColumnRect(
                    screenRect: viewFrame,
                    width: hiddenWidth,
                    height: workingFrame.height
                ).roundedToPhysicalPixels(scale: effectiveScale)

                layoutColumn(
                    column: column,
                    columnRect: hiddenRect,
                    screenRect: viewFrame,
                    verticalGap: gaps.vertical,
                    scale: effectiveScale,
                    result: &result
                )
            }
        }

        return result
    }

    private func layoutColumn(
        column: NiriContainer,
        columnRect: CGRect,
        screenRect: CGRect,
        verticalGap: CGFloat,
        scale: CGFloat,
        result: inout [WindowHandle: CGRect]
    ) {
        column.frame = columnRect

        let tabOffset = column.isTabbed ? renderStyle.tabIndicatorHeight : 0
        let contentRect = CGRect(
            x: columnRect.origin.x,
            y: columnRect.origin.y,
            width: columnRect.width,
            height: max(0, columnRect.height - tabOffset)
        )

        let rows = column.windowNodes
        guard !rows.isEmpty else { return }

        let isTabbed = column.isTabbed

        let resolvedHeights = resolveWindowHeights(
            windows: rows,
            availableHeight: contentRect.height,
            verticalGap: verticalGap,
            isTabbed: isTabbed
        )

        var y = contentRect.origin.y

        for (i, row) in rows.enumerated() {
            let rowHeight = resolvedHeights[i]

            let frame: CGRect = switch row.sizingMode {
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

            row.frame = frame
            row.resolvedHeight = rowHeight

            let offset = row.renderOffset()
            let animatedFrame = frame.offsetBy(dx: offset.x, dy: offset.y)
            result[row.handle] = animatedFrame

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
}
