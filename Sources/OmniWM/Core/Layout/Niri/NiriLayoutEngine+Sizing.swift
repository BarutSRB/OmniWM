import AppKit
import Foundation

extension NiriLayoutEngine {
    private func ensureSelectionVisibleForPendingWidth(
        _ column: NiriContainer,
        targetWidth: CGFloat,
        previousWidth: CGFloat,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        guard let window = column.windowNodes.first else { return }

        // Expose the target width only for viewport-fit math, then restore the
        // animated width source so the spring still runs from the old span.
        column.cachedWidth = targetWidth
        defer { column.cachedWidth = previousWidth }

        ensureSelectionVisible(
            node: window,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func calculateVerticalPixelsPerWeightUnit(
        column: NiriContainer,
        monitorFrame: CGRect,
        gaps: LayoutGaps
    ) -> CGFloat {
        let windows = column.children
        guard !windows.isEmpty else { return 0 }

        let totalWeight = windows.reduce(CGFloat(0)) { $0 + $1.size }
        guard totalWeight > 0 else { return 0 }

        let totalGaps = CGFloat(max(0, windows.count - 1)) * gaps.vertical
        let usableHeight = monitorFrame.height - totalGaps

        return usableHeight / totalWeight
    }

    func setWindowSizingMode(
        _ window: NiriWindow,
        mode: SizingMode,
        state: inout ViewportState
    ) {
        let previousMode = window.sizingMode

        if previousMode == mode {
            return
        }

        if previousMode == .fullscreen, mode == .normal {
            if let savedHeight = window.savedHeight {
                window.height = savedHeight
                window.savedHeight = nil
            }

            if let savedOffset = state.viewOffsetToRestore {
                state.animateViewOffsetRestore(savedOffset)
            }
        }

        if previousMode == .normal, mode == .fullscreen {
            window.savedHeight = window.height
            state.saveViewOffsetForFullscreen()
            window.stopMoveAnimations()
        }

        window.sizingMode = mode
    }

    func toggleFullscreen(
        _ window: NiriWindow,
        state: inout ViewportState
    ) {
        let newMode: SizingMode = window.sizingMode == .fullscreen ? .normal : .fullscreen
        setWindowSizingMode(window, mode: newMode, state: &state)
    }

    func toggleColumnWidth(
        _ column: NiriContainer,
        forwards: Bool,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        guard !presetColumnWidths.isEmpty else { return }

        if column.isFullWidth {
            column.isFullWidth = false
            if let saved = column.savedWidth {
                column.width = saved
                column.savedWidth = nil
            }
        }

        let presetCount = presetColumnWidths.count

        let nextIdx: Int
        if let currentIdx = column.presetWidthIdx {
            if forwards {
                nextIdx = (currentIdx + 1) % presetCount
            } else {
                nextIdx = (currentIdx - 1 + presetCount) % presetCount
            }
        } else {
            let currentValue = column.width.value
            var nearestIdx = 0
            var nearestDist = CGFloat.infinity
            for (i, preset) in presetColumnWidths.enumerated() {
                let dist = abs(preset.kind.value - currentValue)
                if dist < nearestDist {
                    nearestDist = dist
                    nearestIdx = i
                }
            }

            if forwards {
                nextIdx = (nearestIdx + 1) % presetCount
            } else {
                nextIdx = nearestIdx
            }
        }

        let newWidth = presetColumnWidths[nextIdx].asProportionalSize
        column.width = newWidth
        column.presetWidthIdx = nextIdx

        let workingAreaWidth = workingFrame.width
        let targetPixels: CGFloat
        switch newWidth {
        case .proportion(let p):
            targetPixels = (workingAreaWidth - gaps) * p
        case .fixed(let f):
            targetPixels = f
        }

        if column.cachedWidth <= 0 {
            column.resolveAndCacheWidth(workingAreaWidth: workingAreaWidth, gaps: gaps)
        }
        let previousWidth = column.cachedWidth

        column.animateWidthTo(
            newWidth: targetPixels,
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate
        )

        ensureSelectionVisibleForPendingWidth(
            column,
            targetWidth: targetPixels,
            previousWidth: previousWidth,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func toggleFullWidth(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        let workingAreaWidth = workingFrame.width
        let targetPixels: CGFloat
        if column.isFullWidth {
            column.isFullWidth = false
            if let saved = column.savedWidth {
                column.width = saved
                column.savedWidth = nil
            }
            switch column.width {
            case .proportion(let p):
                targetPixels = (workingAreaWidth - gaps) * p
            case .fixed(let f):
                targetPixels = f
            }
        } else {
            column.savedWidth = column.width
            column.isFullWidth = true
            column.presetWidthIdx = nil
            targetPixels = workingAreaWidth
        }

        if column.cachedWidth <= 0 {
            column.resolveAndCacheWidth(workingAreaWidth: workingAreaWidth, gaps: gaps)
        }
        let previousWidth = column.cachedWidth

        column.animateWidthTo(
            newWidth: targetPixels,
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate
        )

        ensureSelectionVisibleForPendingWidth(
            column,
            targetWidth: targetPixels,
            previousWidth: previousWidth,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func setWindowHeight(_ window: NiriWindow, height: WeightedSize) {
        window.height = height
    }
}
