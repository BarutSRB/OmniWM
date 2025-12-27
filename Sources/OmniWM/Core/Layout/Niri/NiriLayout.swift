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

        let total = cols.count
        let visibleCap = min(maxVisibleColumns, total)
        let startPos = state.viewportStart
        let spanEnd = startPos + CGFloat(visibleCap)

        var visibleIndices: [Int] = []

        var idx = Int(startPos.rounded(.down))
        while CGFloat(idx) < spanEnd + CGFloat.ulpOfOne, visibleIndices.count < total + 1 {
            guard let wrappedIdx = wrapIndex(idx, total: total) else { break }

            let colStart = CGFloat(idx)
            let colEnd = colStart + 1.0
            let overlap = min(colEnd, spanEnd) - max(colStart, startPos)

            if overlap > CGFloat.ulpOfOne {
                visibleIndices.append(wrappedIdx)
            }

            idx += 1
        }

        guard !visibleIndices.isEmpty else { return result }

        let horizontalGap = gaps.horizontal

        let aspectRatioMaxWidth: CGFloat? = {
            guard total == 1,
                  let ratio = singleWindowAspectRatio.ratio
            else {
                return nil
            }

            return workingFrame.height * ratio
        }()

        let columnsForWidthCalc = Array(visibleIndices.prefix(visibleCap))
        let columnInputs: [NiriColumnWidthSolver.ColumnInput] = columnsForWidthCalc.map { idx in
            let column = cols[idx]

            let minWidthConstraint = column.windowNodes.map(\.constraints.minSize.width).max()
            var maxWidthConstraint = column.windowNodes
                .compactMap { $0.constraints.hasMaxWidth ? $0.constraints.maxSize.width : nil }
                .min()

            if let aspectMax = aspectRatioMaxWidth {
                if let existing = maxWidthConstraint {
                    maxWidthConstraint = min(existing, aspectMax)
                } else {
                    maxWidthConstraint = aspectMax
                }
            }

            let effectiveWidth: ColumnWidth = switch column.width {
            case let .proportion(p):
                .proportion(max(0.1, p))
            case let .fixed(f):
                .fixed(max(1, f))
            }

            return NiriColumnWidthSolver.ColumnInput(
                width: effectiveWidth,
                isFullWidth: column.isFullWidth,
                minWidth: minWidthConstraint,
                maxWidth: maxWidthConstraint
            )
        }

        let widthOutputs = NiriColumnWidthSolver.solve(
            columns: columnInputs,
            availableWidth: workingFrame.width,
            gapSize: horizontalGap
        )
        guard !widthOutputs.isEmpty else { return result }

        let centeringOffset = computeCenteringOffset(
            visibleIndices: columnsForWidthCalc,
            widths: widthOutputs.map(\.width),
            horizontalGap: horizontalGap,
            workingFrame: workingFrame,
            totalColumns: total
        )

        let fractionalOffset = startPos - floor(startPos)
        let firstColWidth = widthOutputs.first?.width ?? 0
        let viewportShift = fractionalOffset * (firstColWidth + horizontalGap)

        var x = workingFrame.origin.x + centeringOffset - viewportShift
        var usedIndices = Set<Int>()

        for (i, colIdx) in visibleIndices.enumerated() {
            let widthIndex = i % widthOutputs.count
            let width = widthOutputs[widthIndex].width.roundedToPhysicalPixel(scale: effectiveScale)
            guard width > CGFloat.ulpOfOne else { continue }

            usedIndices.insert(colIdx)

            let columnRect = CGRect(
                x: x,
                y: workingFrame.origin.y,
                width: width,
                height: workingFrame.height
            ).roundedToPhysicalPixels(scale: effectiveScale)

            let column = cols[colIdx]
            layoutColumn(
                column: column,
                columnRect: columnRect,
                screenRect: viewFrame,
                verticalGap: gaps.vertical,
                scale: effectiveScale,
                result: &result
            )

            x += width + horizontalGap
        }

        if total > usedIndices.count {
            let avgWidth = widthOutputs.map(\.width).reduce(0, +) / CGFloat(max(1, widthOutputs.count))
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

    private func computeCenteringOffset(
        visibleIndices: [Int],
        widths: [CGFloat],
        horizontalGap: CGFloat,
        workingFrame: CGRect,
        totalColumns: Int
    ) -> CGFloat {
        let shouldApplyCentering: Bool = switch centerFocusedColumn {
        case .always:
            totalColumns < maxVisibleColumns
        case .never:
            alwaysCenterSingleColumn && totalColumns == 1
        case .onOverflow:
            alwaysCenterSingleColumn && totalColumns == 1
        }

        guard shouldApplyCentering else { return 0 }

        let gapCount = max(0, visibleIndices.count - 1)
        let totalColumnsWidth = widths.reduce(0, +) + CGFloat(gapCount) * horizontalGap

        let remainingSpace = workingFrame.width - totalColumnsWidth
        return max(0, remainingSpace / 2.0)
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
            case .maximized:
                columnRect
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
            result[row.handle] = frame

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

    private func wrapIndex(_ idx: Int, total: Int) -> Int? {
        guard total > 0 else { return nil }
        if infiniteLoop {
            let modulo = total
            return ((idx % modulo) + modulo) % modulo
        } else {
            return (idx >= 0 && idx < total) ? idx : nil
        }
    }
}
