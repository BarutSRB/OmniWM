// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension NiriLayoutEngine {
    struct WindowTransferAnimationSample {
        let source: WindowTransferRenderSample
        let sampling: ColumnRenderSampling

        init(
            source: WindowTransferRenderSample,
            geometry: NiriProjectedGeometrySnapshot,
            time: TimeInterval,
            context: NiriInteractionContext
        ) {
            self.source = source
            sampling = ColumnRenderSampling(geometry: geometry, time: time, context: context)
        }
    }

    func animateConsumedWindow(
        _ window: NiriWindow,
        target: (column: NiriContainer, fallbackIndex: Int),
        sample: WindowTransferAnimationSample,
        state: ViewportState
    ) {
        let context = sample.sampling.context
        let columns = columns(in: context.workspaceId)
        let index = columnIndex(of: target.column, in: context.workspaceId) ?? target.fallbackIndex
        let destination = sampleTransferredWindow(
            window, in: (target.column, index), columns: columns, state: state, sampling: sample.sampling
        )
        animateTransferredWindow(
            window, from: sample.source.column, to: destination.column,
            secondary: sample.source.secondaryOffset - destination.secondaryOffset, context: context
        )
    }

    func animateExpelledWindow(
        _ window: NiriWindow,
        into column: NiriContainer,
        sample: WindowTransferAnimationSample,
        state: ViewportState
    ) {
        let context = sample.sampling.context
        let columns = columns(in: context.workspaceId)
        guard let index = columnIndex(of: column, in: context.workspaceId) else { return }
        let destination = sampleColumnPosition(
            in: (column, index), columns: columns, state: state, sampling: sample.sampling
        )
        animateTransferredWindow(
            window, from: sample.source.column, to: destination,
            secondary: sample.source.secondaryOffset, context: context
        )
    }

    func animateInsertedColumn(
        _ column: NiriContainer,
        snapshot: ColumnMutationSnapshot,
        context: NiriInteractionContext,
        state: ViewportState
    ) {
        if !snapshot.hasProjectionExclusions,
           let index = columnIndex(of: column, in: context.workspaceId)
        {
            animateColumnsForAddition(columnIndex: index, context: context, state: state)
        }
    }
}
