import AppKit

extension NiriLayoutEngine {
    @discardableResult
    func centerColumn(
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        let columns = columns(in: workspaceId)
        guard !columns.isEmpty else { return false }

        let activeIndex = state.activeColumnIndex.clamped(to: 0 ... (columns.count - 1))
        state.activeColumnIndex = activeIndex

        cancelInteractiveResize(for: columns[activeIndex], in: workspaceId)

        let scale = displayScale(in: workspaceId)
        let viewFrame = monitorForWorkspace(workspaceId)?.frame
        let targetOffset = state.computeCenteredOffset(
            columnIndex: activeIndex,
            columns: columns,
            gap: gaps,
            viewportWidth: workingFrame.width,
            workingArea: workingFrame,
            viewFrame: viewFrame,
            scale: scale
        )
        state.animateToOffset(
            targetOffset,
            motion: motion,
            scale: scale
        )
        return true
    }

    @discardableResult
    func centerVisibleColumns(
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        let columns = columns(in: workspaceId)
        guard !columns.isEmpty else { return false }

        let settings = effectiveSettings(in: workspaceId)
        if settings.centerFocusedColumn == .always
            || (settings.alwaysCenterSingleColumn && columns.count <= 1)
        {
            return false
        }

        let activeIndex = state.activeColumnIndex.clamped(to: 0 ... (columns.count - 1))
        state.activeColumnIndex = activeIndex

        let scale = displayScale(in: workspaceId)
        let viewFrame = monitorForWorkspace(workspaceId)?.frame
        let areas = state.normalizedFittingAreas(
            viewportSpan: workingFrame.width,
            workingArea: workingFrame,
            viewFrame: viewFrame,
            scale: scale
        )
        let viewStart = state.viewPosPixels(columns: columns, gap: gaps)
        let workingStart = areas.origin(of: areas.working)
        let viewportWidth = areas.span(of: areas.working)

        var widthTaken: CGFloat = 0
        var leftmostColumnX: CGFloat?
        var activeColumnX: CGFloat?

        for (idx, column) in columns.enumerated() {
            let columnX = state.columnX(at: idx, columns: columns, gap: gaps)
            if columnX < viewStart + workingStart + gaps {
                continue
            }

            if leftmostColumnX == nil {
                leftmostColumnX = columnX
            }

            let width = column.cachedWidth
            if viewStart + workingStart + viewportWidth < columnX + width + gaps {
                break
            }

            if idx == activeIndex {
                activeColumnX = columnX
            }

            widthTaken += width + gaps
        }

        guard let leftmostColumnX, let activeColumnX else { return false }

        cancelInteractiveResize(for: columns[activeIndex], in: workspaceId)

        let freeSpace = viewportWidth - widthTaken + gaps
        let newViewStart = leftmostColumnX - freeSpace / 2 - workingStart
        let targetOffset = newViewStart - activeColumnX

        state.animateToOffset(
            targetOffset,
            motion: motion,
            scale: scale
        )

        state.ensureContainerVisible(
            containerIndex: activeIndex,
            containers: columns,
            gap: gaps,
            viewportSpan: viewportWidth,
            motion: motion,
            sizeKeyPath: \.cachedWidth,
            centerMode: settings.centerFocusedColumn,
            alwaysCenterSingleColumn: settings.alwaysCenterSingleColumn,
            scale: scale,
            workingArea: workingFrame,
            viewFrame: viewFrame
        )

        return true
    }

    private func cancelInteractiveResize(
        for column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let resize = interactiveResize, resize.workspaceId == workspaceId else { return }
        guard let resizeWindow = findNode(by: resize.windowId) as? NiriWindow,
              let resizeColumn = findColumn(containing: resizeWindow, in: workspaceId),
              resizeColumn === column
        else {
            return
        }

        clearInteractiveResize()
    }
}
