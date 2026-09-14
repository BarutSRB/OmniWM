// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension NiriLayoutEngine {
    struct ResizeUpdateContext {
        let resize: InteractiveResize
        let delta: CGPoint
        let monitorFrame: CGRect
        let gaps: LayoutGaps
    }

    func resizeHorizontalColumn(
        _ column: NiriContainer, context: ResizeUpdateContext,
        viewportState: ((inout ViewportState) -> Void) -> Void
    ) -> Bool {
        let resize = context.resize
        let delta = context.delta
        let monitorFrame = context.monitorFrame
        let gaps = context.gaps
        var changed = false
        if resize.edges.hasHorizontal, let originalWidth = resize.originalContainerSpan {
            column.widthAnimation = nil
            column.targetWidth = nil

            var dx = delta.x

            if resize.edges.contains(.left) {
                dx = -dx
            }

            let widthBounds = projectedWidthBounds(for: column, workspaceId: resize.workspaceId)
            let minWidth = widthBounds.min
            let viewportMaxWidth = monitorFrame.width - gaps.horizontal
            let maxWidth = max(
                minWidth,
                min(viewportMaxWidth, widthBounds.max ?? viewportMaxWidth)
            )

            let newWidth = originalWidth + dx
            column.cachedWidth = newWidth.clamped(to: minWidth ... maxWidth)
            column.width = .fixed(column.cachedWidth)
            column.presetWidthIdx = nil
            column.isFullWidth = false
            column.savedWidth = nil
            column.hasManualSingleWindowWidthOverride = true
            changed = true

            if resize.edges.contains(.left), let origOffset = resize.originalViewOffset {
                let widthDelta = column.cachedWidth - originalWidth
                viewportState { state in
                    state.jumpOffset(to: origOffset + widthDelta)
                }
            }
        }
        return changed
    }

    func resizeHorizontalWindow(
        _ windowNode: NiriWindow, column: NiriContainer, context: ResizeUpdateContext
    ) -> Bool {
        let resize = context.resize
        let delta = context.delta
        let monitorFrame = context.monitorFrame
        let gaps = context.gaps
        var changed = false
        if resize.edges.hasVertical,
           case let .weight(originalHeight)? = resize.originalWindowBaseline
        {
            var dy = delta.y

            if resize.edges.contains(.bottom) {
                dy = -dy
            }

            let pixelsPerWeight = calculateVerticalPixelsPerWeightUnit(
                column: column,
                workspaceId: resize.workspaceId,
                monitorFrame: monitorFrame,
                gaps: gaps
            )

            if pixelsPerWeight > 0 {
                let weightDelta = dy / pixelsPerWeight
                let newWeight = originalHeight + weightDelta
                windowNode.size = newWeight.clamped(
                    to: resizeConfiguration.minWindowWeight ... resizeConfiguration.maxWindowWeight
                )
                changed = true
            }
        }
        return changed
    }

    func resizeVerticalWindow(
        _ windowNode: NiriWindow, column: NiriContainer, context: ResizeUpdateContext
    ) -> Bool {
        let resize = context.resize
        let delta = context.delta
        let monitorFrame = context.monitorFrame
        let gaps = context.gaps
        var changed = false
        if resize.edges.hasHorizontal, let windowBaseline = resize.originalWindowBaseline {
            var dx = delta.x

            if resize.edges.contains(.left) {
                dx = -dx
            }

            switch windowBaseline {
            case let .fixedPixels(originalWidth):
                let constraints = windowNode.constraints.normalized()
                let minWidth = constraints.minSize.width
                let viewportMaxWidth = monitorFrame.width - gaps.horizontal
                let constrainedMaxWidth = constraints.hasMaxWidth
                    ? constraints.maxSize.width
                    : viewportMaxWidth
                let maxWidth = max(minWidth, min(viewportMaxWidth, constrainedMaxWidth))
                let newWidth = (originalWidth + dx).clamped(to: minWidth ... maxWidth)
                windowNode.windowWidth = .fixed(newWidth)
                changed = true
            case let .weight(originalWidthWeight):
                let pixelsPerWeight = calculateHorizontalPixelsPerWeightUnit(
                    column: column,
                    workspaceId: resize.workspaceId,
                    monitorFrame: monitorFrame,
                    gaps: gaps
                )

                if pixelsPerWeight > 0 {
                    let weightDelta = dx / pixelsPerWeight
                    let newWeight = (originalWidthWeight + weightDelta).clamped(
                        to: resizeConfiguration.minWindowWeight ... resizeConfiguration.maxWindowWeight
                    )
                    let constrainedWidth = windowNode.constraints.clampWidth(
                        newWeight * pixelsPerWeight
                    )
                    windowNode.windowWidth = .auto(weight: constrainedWidth / pixelsPerWeight)
                    changed = true
                }
            }
        }
        return changed
    }

    func resizeVerticalColumn(
        _ column: NiriContainer, context: ResizeUpdateContext,
        viewportState: ((inout ViewportState) -> Void) -> Void
    ) -> Bool {
        let resize = context.resize
        let delta = context.delta
        let monitorFrame = context.monitorFrame
        let gaps = context.gaps
        var changed = false
        if resize.edges.hasVertical, let originalHeight = resize.originalContainerSpan {
            var dy = delta.y

            if resize.edges.contains(.bottom) {
                dy = -dy
            }

            let heightBounds = projectedHeightBounds(for: column, workspaceId: resize.workspaceId)
            let minHeight = heightBounds.min
            let viewportMaxHeight = monitorFrame.height - gaps.vertical
            let maxHeight = max(
                minHeight,
                min(viewportMaxHeight, heightBounds.max ?? viewportMaxHeight)
            )

            let newHeight = originalHeight + dy
            column.cachedHeight = newHeight.clamped(to: minHeight ... maxHeight)
            column.height = .fixed(column.cachedHeight)
            column.isFullHeight = false
            column.savedHeight = nil
            column.hasManualSingleWindowHeightOverride = true
            changed = true

            if resize.edges.contains(.bottom), let origOffset = resize.originalViewOffset {
                let heightDelta = column.cachedHeight - originalHeight
                viewportState { state in
                    state.jumpOffset(to: origOffset + heightDelta)
                }
            }
        }
        return changed
    }
}
