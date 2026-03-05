import AppKit
import Foundation

extension NiriLayoutEngine {
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
        guard let workspaceId = window.findRoot()?.workspaceId else { return }
        let previousMode = window.sizingMode

        if previousMode == mode {
            return
        }

        let savedOffsetToRestore = state.viewOffsetToRestore

        let runtimeStore = runtimeStore(for: workspaceId)
        let outcome: NiriRuntimeMutationOutcome
        switch runtimeStore.executeMutation(
            .setWindowSizingMode(
                sourceWindowId: window.id,
                mode: mode
            )
        ) {
        case let .success(resolved):
            outcome = resolved
        case .failure:
            return
        }
        guard outcome.rc == 0 else { return }
        guard outcome.applied else { return }

        if previousMode == .fullscreen, mode == .normal,
           let savedOffset = savedOffsetToRestore
        {
            state.animateViewOffsetRestore(savedOffset)
        } else if previousMode == .normal, mode == .fullscreen {
            state.saveViewOffsetForFullscreen()
        }
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

        let baselineWidth: ProportionalSize
        if column.isFullWidth, let savedWidth = column.savedWidth {
            baselineWidth = savedWidth
        } else {
            baselineWidth = column.width
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
            let currentValue = baselineWidth.value
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

        let runtimeStore = runtimeStore(for: workspaceId)
        let outcome: NiriRuntimeMutationOutcome
        switch runtimeStore.executeMutation(
            .setColumnWidth(
                sourceColumnId: column.id,
                width: newWidth,
                isFullWidth: false,
                savedWidth: nil
            )
        ) {
        case let .success(resolved):
            outcome = resolved
        case .failure:
            return
        }
        guard outcome.rc == 0 else { return }

        guard let resolvedColumn = runtimeColumnNode(
            for: column.id,
            in: workspaceId
        ) else {
            return
        }
        resolvedColumn.presetWidthIdx = nextIdx

        let workingAreaWidth = workingFrame.width
        let targetPixels: CGFloat
        switch resolvedColumn.width {
        case .proportion(let p):
            targetPixels = (workingAreaWidth - gaps) * p
        case .fixed(let f):
            targetPixels = f
        }

        resolvedColumn.animateWidthTo(
            newWidth: targetPixels,
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate
        )

        if let window = resolvedColumn.windowNodes.first {
            ensureSelectionVisible(
                node: window,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                alwaysCenterSingleColumn: alwaysCenterSingleColumn
            )
        }
    }

    func toggleFullWidth(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        let toggledIsFullWidth = !column.isFullWidth
        let resolvedWidth: ProportionalSize
        let savedWidth: ProportionalSize?
        if toggledIsFullWidth {
            resolvedWidth = column.width
            savedWidth = column.width
        } else {
            resolvedWidth = column.savedWidth ?? column.width
            savedWidth = nil
        }

        let runtimeStore = runtimeStore(for: workspaceId)
        let outcome: NiriRuntimeMutationOutcome
        switch runtimeStore.executeMutation(
            .setColumnWidth(
                sourceColumnId: column.id,
                width: resolvedWidth,
                isFullWidth: toggledIsFullWidth,
                savedWidth: savedWidth
            )
        ) {
        case let .success(resolved):
            outcome = resolved
        case .failure:
            return
        }
        guard outcome.rc == 0 else { return }

        guard let resolvedColumn = runtimeColumnNode(
            for: column.id,
            in: workspaceId
        ) else {
            return
        }
        if resolvedColumn.isFullWidth {
            resolvedColumn.presetWidthIdx = nil
        }

        let workingAreaWidth = workingFrame.width
        let targetPixels: CGFloat
        if resolvedColumn.isFullWidth {
            targetPixels = workingAreaWidth
        } else {
            switch resolvedColumn.width {
            case .proportion(let p):
                targetPixels = (workingAreaWidth - gaps) * p
            case .fixed(let f):
                targetPixels = f
            }
        }

        resolvedColumn.animateWidthTo(
            newWidth: targetPixels,
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate
        )

        if let window = resolvedColumn.windowNodes.first {
            ensureSelectionVisible(
                node: window,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                alwaysCenterSingleColumn: alwaysCenterSingleColumn
            )
        }
    }

    func setWindowHeight(_ window: NiriWindow, height: WeightedSize) {
        guard let workspaceId = window.findRoot()?.workspaceId else { return }

        let runtimeStore = runtimeStore(for: workspaceId)
        switch runtimeStore.executeMutation(
            .setWindowHeight(
                sourceWindowId: window.id,
                height: height
            )
        ) {
        case let .success(outcome):
            guard outcome.rc == 0 else { return }
        case .failure:
            return
        }
    }
}
