// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension NiriLayoutEngine {
    func correctViewportAfterColumnRemoval(
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        let cols = columns(in: context.workspaceId)
        guard !cols.isEmpty else { return false }

        let monitor = monitorForWorkspace(context.workspaceId)
        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        let sizeKeyPath = context.orientation.settledSpanKeyPath
        let viewportSpan: CGFloat = switch context.orientation {
        case .horizontal: context.workingFrame.width
        case .vertical: context.workingFrame.height
        }

        let activeIdx = state.activeColumnIndex.clamped(to: 0 ... (cols.count - 1))
        state.activeColumnIndex = activeIdx
        let activePosition = state.containerPosition(
            at: activeIdx,
            containers: cols,
            gap: context.gaps,
            sizeKeyPath: sizeKeyPath
        )
        let viewStart = activePosition + state.viewOffset
        let settings = effectiveSettings(in: context.workspaceId)
        let scale = displayScale(in: context.workspaceId)
        let viewport = RemovalViewport(
            columns: cols, activeIndex: activeIdx, activePosition: activePosition,
            viewStart: viewStart, span: viewportSpan, scale: scale, viewFrame: monitor?.frame
        )
        if settings.centerFocusedColumn == .always
            || (cols.count == 1 && settings.alwaysCenterSingleColumn)
        {
            return centerRemovalViewport(
                viewport, context: context, state: &state,
                centerMode: settings.centerFocusedColumn, centerSingle: settings.alwaysCenterSingleColumn
            )
        }
        return fitRemovalViewport(viewport, context: context, state: &state, centerMode: settings.centerFocusedColumn)
    }

    private struct RemovalViewport {
        let columns: [NiriContainer]
        let activeIndex: Int
        let activePosition: CGFloat
        let viewStart: CGFloat
        let span: CGFloat
        let scale: CGFloat
        let viewFrame: CGRect?
    }

    private func centerRemovalViewport(
        _ viewport: RemovalViewport, context: NiriInteractionContext, state: inout ViewportState,
        centerMode: CenterFocusedColumn, centerSingle: Bool
    ) -> Bool {
        let targetOffset = state.computeVisibleOffset(
            containerIndex: viewport.activeIndex,
            containers: viewport.columns,
            context: context,
            currentViewStart: viewport.viewStart,
            centerMode: centerMode,
            alwaysCenterSingleColumn: centerSingle,
            scale: viewport.scale,
            viewFrame: viewport.viewFrame
        )
        let targetStart = viewport.activePosition + targetOffset
        guard abs(targetStart - viewport.viewStart) > 0.5 else { return false }
        state.animateToOffset(targetOffset, motion: context.motion, scale: viewport.scale)
        return true
    }

    private func fitRemovalViewport(
        _ viewport: RemovalViewport, context: NiriInteractionContext, state: inout ViewportState,
        centerMode: CenterFocusedColumn
    ) -> Bool {
        let totalSpan = state.totalSpan(
            containers: viewport.columns,
            gap: context.gaps,
            sizeKeyPath: context.orientation.settledSpanKeyPath
        )
        let contentEdge = totalSpan - viewport.span + context.gaps
        let clampedStart = viewport.viewStart.clamped(to: min(-context.gaps, contentEdge) ... max(
            -context.gaps,
            contentEdge
        ))
        guard abs(clampedStart - viewport.viewStart) > 0.5 else { return false }

        if centerMode == .onOverflow, preservesCenteredOverflow(viewport, context: context, state: state) {
            return false
        }

        let fittedOffset = state.computeVisibleOffset(
            containerIndex: viewport.activeIndex,
            containers: viewport.columns,
            context: context,
            currentViewStart: clampedStart,
            centerMode: .never,
            scale: viewport.scale,
            viewFrame: viewport.viewFrame
        )
        let fittedStart = viewport.activePosition + fittedOffset
        guard abs(fittedStart - viewport.viewStart) > 0.5 else { return false }
        state.animateToOffset(
            fittedOffset,
            motion: context.motion,
            scale: viewport.scale
        )
        return true
    }

    private func preservesCenteredOverflow(
        _ viewport: RemovalViewport, context: NiriInteractionContext, state: ViewportState
    ) -> Bool {
        let centeredOffset = state.computeVisibleOffset(
            containerIndex: viewport.activeIndex,
            containers: viewport.columns,
            context: context,
            currentViewStart: viewport.viewStart,
            centerMode: .always,
            scale: viewport.scale,
            viewFrame: viewport.viewFrame
        )
        let centeredStart = viewport.activePosition + centeredOffset
        let activeSpan = viewport.columns[viewport.activeIndex][keyPath: context.orientation.settledSpanKeyPath]
        let previousPairOverflows = viewport.activeIndex > 0
            && viewport
            .columns[viewport.activeIndex - 1][keyPath: context.orientation.settledSpanKeyPath] + activeSpan +
            context.gaps * 3 > viewport.span
        let nextPairOverflows = viewport.activeIndex + 1 < viewport.columns.count
            && activeSpan + viewport
            .columns[viewport.activeIndex + 1][keyPath: context.orientation.settledSpanKeyPath] + context
            .gaps * 3 > viewport.span
        return (previousPairOverflows || nextPairOverflows) && abs(centeredStart - viewport.viewStart) <= 0.5
    }
}
