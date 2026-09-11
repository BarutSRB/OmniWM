// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

extension NiriLayoutEngine {
    private struct VisibleColumnsSpan {
        let firstPosition: CGFloat
        let activePosition: CGFloat
        let span: CGFloat
    }

    @discardableResult
    func centerColumn(context: NiriInteractionContext, state: inout ViewportState) -> Bool {
        assertSanctionedMutation()
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
        let scale = displayScale(in: context.workspaceId)
        let viewFrame = monitorForWorkspace(context.workspaceId)?.frame
        return withProjectedViewport(
            state: &state,
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        ) { columns, projectedState in
            let activeIndex = projectedState.activeColumnIndex.clamped(to: 0 ... columns.count - 1)
            projectedState.activeColumnIndex = activeIndex
            cancelInteractiveResize(for: columns[activeIndex], in: context.workspaceId)
            let targetOffset = projectedState.computeCenteredOffset(
                containerIndex: activeIndex,
                containers: columns,
                gap: context.gaps,
                viewportSpan: viewportSpan,
                sizeKeyPath: sizeKeyPath,
                workingArea: context.workingFrame,
                viewFrame: viewFrame,
                orientation: context.orientation,
                scale: scale
            )
            projectedState.animateToOffset(
                targetOffset,
                motion: context.motion,
                scale: scale
            )
            return true
        } ?? false
    }

    @discardableResult
    func centerVisibleColumns(context: NiriInteractionContext, state: inout ViewportState) -> Bool {
        assertSanctionedMutation()
        let settings = effectiveSettings(in: context.workspaceId)
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

        let scale = displayScale(in: context.workspaceId)
        let viewFrame = monitorForWorkspace(context.workspaceId)?.frame
        return withProjectedViewport(
            state: &state,
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        ) { columns, projectedState in
            guard settings.centerFocusedColumn != .always,
                  !settings.alwaysCenterSingleColumn || columns.count > 1
            else {
                return false
            }

            let activeIndex = projectedState.activeColumnIndex.clamped(to: 0 ... columns.count - 1)
            projectedState.activeColumnIndex = activeIndex
            let areas = projectedState.normalizedFittingAreas(
                viewportSpan: viewportSpan,
                workingArea: context.workingFrame,
                viewFrame: viewFrame,
                orientation: context.orientation,
                scale: scale
            )
            guard let visibleSpan = visibleColumnsSpan(
                columns: columns,
                state: projectedState,
                areas: areas,
                gap: context.gaps
            ) else { return false }
            cancelInteractiveResize(for: columns[activeIndex], in: context.workspaceId)
            let workingStart = areas.origin(of: areas.working)
            let workingSpan = areas.span(of: areas.working)
            let freeSpace = workingSpan - visibleSpan.span + context.gaps
            let newViewStart = visibleSpan.firstPosition - freeSpace / 2 - workingStart
            let targetOffset = newViewStart - visibleSpan.activePosition

            projectedState.animateToOffset(targetOffset, motion: context.motion, scale: scale)
            projectedState.ensureContainerVisible(
                containerIndex: activeIndex,
                containers: columns,
                gap: context.gaps,
                viewportSpan: areas.span(of: areas.working),
                motion: context.motion,
                sizeKeyPath: sizeKeyPath,
                centerMode: settings.centerFocusedColumn,
                alwaysCenterSingleColumn: settings.alwaysCenterSingleColumn,
                scale: scale,
                workingArea: context.workingFrame,
                viewFrame: viewFrame,
                orientation: context.orientation
            )
            return true
        } ?? false
    }

    private func visibleColumnsSpan(
        columns: [NiriContainer],
        state: ViewportState,
        areas: ViewportFittingAreas,
        gap: CGFloat
    ) -> VisibleColumnsSpan? {
        let sizeKeyPath = areas.orientation.settledSpanKeyPath
        let activePosition = state.containerPosition(
            at: state.activeColumnIndex,
            containers: columns,
            gap: gap,
            sizeKeyPath: sizeKeyPath
        )
        let viewStart = activePosition + state.viewOffset
        let workingStart = areas.origin(of: areas.working)
        let workingSpan = areas.span(of: areas.working)

        var spanTaken: CGFloat = 0
        var firstVisiblePosition: CGFloat?
        var activeContainerPosition: CGFloat?

        for (idx, column) in columns.enumerated() {
            let position = state.containerPosition(
                at: idx,
                containers: columns,
                gap: gap,
                sizeKeyPath: sizeKeyPath
            )
            if position < viewStart + workingStart + gap {
                continue
            }

            if firstVisiblePosition == nil {
                firstVisiblePosition = position
            }

            let span = column[keyPath: sizeKeyPath]
            if viewStart + workingStart + workingSpan < position + span + gap {
                break
            }

            if idx == state.activeColumnIndex {
                activeContainerPosition = position
            }

            spanTaken += span + gap
        }

        guard let firstVisiblePosition, let activeContainerPosition else { return nil }
        return VisibleColumnsSpan(
            firstPosition: firstVisiblePosition,
            activePosition: activeContainerPosition,
            span: spanTaken
        )
    }

    private func cancelInteractiveResize(
        for column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let resize = interactiveResize, resize.workspaceId == workspaceId else { return }
        guard let resizeWindow = findNode(by: resize.windowId, in: workspaceId) as? NiriWindow,
              let resizeColumn = findColumn(containing: resizeWindow, in: workspaceId),
              resizeColumn === column
        else {
            return
        }

        clearInteractiveResize()
    }
}
