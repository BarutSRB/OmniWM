// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension NiriLayoutEngine {
    struct ColumnMutationSnapshot {
        let geometry: NiriProjectedGeometrySnapshot
        let hasProjectionExclusions: Bool
    }

    struct WindowTransferRenderSample {
        let column: ColumnRenderPosition
        let secondaryOffset: CGFloat
    }

    struct ColumnRenderSampling {
        let geometry: NiriProjectedGeometrySnapshot
        let time: TimeInterval
        let context: NiriInteractionContext
    }

    func prepareColumnMutation(context: NiriInteractionContext) -> ColumnMutationSnapshot {
        resolvePrimaryContainerSpans(
            in: context.workspaceId, workingFrame: context.workingFrame,
            gaps: context.gaps, orientation: context.orientation
        )
        let hasProjectionExclusions = !projectionExclusions(in: context.workspaceId).isEmpty
        let geometry = projectedGeometrySnapshot(
            in: context.workspaceId, workingFrame: context.workingFrame,
            gaps: context.gaps, orientation: context.orientation
        )
        return ColumnMutationSnapshot(geometry: geometry, hasProjectionExclusions: hasProjectionExclusions)
    }

    func completeColumnMutation(
        from snapshot: ColumnMutationSnapshot,
        context: NiriInteractionContext
    ) -> NiriProjectedGeometrySnapshot {
        let geometry = projectedGeometrySnapshot(
            in: context.workspaceId, workingFrame: context.workingFrame,
            gaps: context.gaps, orientation: context.orientation
        )
        if snapshot.hasProjectionExclusions {
            animateProjectedColumns(
                from: snapshot.geometry, to: geometry, in: context.workspaceId,
                motion: context.motion, orientation: context.orientation
            )
        }
        return geometry
    }

    func sampleTransferredWindow(
        _ window: NiriWindow,
        in columnAtIndex: (column: NiriContainer, index: Int),
        columns: [NiriContainer],
        state: ViewportState,
        sampling: ColumnRenderSampling
    ) -> WindowTransferRenderSample {
        WindowTransferRenderSample(
            column: sampleColumnPosition(in: columnAtIndex, columns: columns, state: state, sampling: sampling),
            secondaryOffset: sampling.geometry.secondaryOffset(of: window, in: columnAtIndex.column) ?? sampling.context
                .gaps
        )
    }

    func sampleColumnPosition(
        in columnAtIndex: (column: NiriContainer, index: Int),
        columns: [NiriContainer],
        state: ViewportState,
        sampling: ColumnRenderSampling
    ) -> ColumnRenderPosition {
        let column = columnAtIndex.column
        let context = sampling.context
        let position = sampling.geometry.column(containing: column)?.primaryPosition
            ?? state.containerPosition(
                at: columnAtIndex.index, containers: columns, gap: context.gaps,
                sizeKeyPath: primarySizeKeyPath(for: context.orientation)
            )
        return ColumnRenderPosition(primaryPosition: position, renderOffset: column.renderOffset(at: sampling.time))
    }

    func cleanUpConsumedColumn(
        _ column: NiriContainer,
        transfer: ColumnTransferResult,
        snapshot: ColumnMutationSnapshot,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        if transfer.sourceBecameEmpty {
            if !snapshot.hasProjectionExclusions {
                _ = animateColumnsForRemoval(
                    columnIndex: transfer.sourceColumnIndexBeforeCleanup,
                    context: context, state: &state
                )
            }
            cleanupEmptyColumn(column, in: context.workspaceId, state: &state)
        }
    }
}
