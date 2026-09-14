// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

struct NiriColumnExpansionPlan {
    let availableWidth: CGFloat
    let leftmostColumnX: CGFloat?
    let activeColumnX: CGFloat?
    let countedNonActiveColumn: Bool

    init?(
        column: NiriContainer,
        columns: [NiriContainer],
        state: ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        guard let activeColumnIndex = columns.firstIndex(where: { $0 === column }) else { return nil }
        let viewX = state.columnX(
            at: state.activeColumnIndex.clamped(to: 0 ... max(0, columns.count - 1)),
            columns: columns,
            gap: gaps
        ) + state.viewOffset

        var widthTaken: CGFloat = 0
        var leftmostColX: CGFloat?
        var activeColX: CGFloat?
        var activeColumnWasFullyVisible = false
        var countedNonActiveColumn = false

        for idx in columns.indices {
            let colX = state.columnX(at: idx, columns: columns, gap: gaps)
            if colX < viewX + gaps {
                continue
            }

            if leftmostColX == nil {
                leftmostColX = colX
            }

            let width = columns[idx].cachedWidth
            if viewX + workingFrame.width < colX + width + gaps {
                break
            }

            if idx == activeColumnIndex {
                activeColumnWasFullyVisible = true
                activeColX = colX
            } else {
                countedNonActiveColumn = true
            }

            widthTaken += width + gaps
        }

        guard activeColumnWasFullyVisible else { return nil }
        let availableWidth = workingFrame.width - gaps - widthTaken
        guard availableWidth > 0 else { return nil }

        self.availableWidth = availableWidth
        leftmostColumnX = leftmostColX
        activeColumnX = activeColX
        self.countedNonActiveColumn = countedNonActiveColumn
    }
}
