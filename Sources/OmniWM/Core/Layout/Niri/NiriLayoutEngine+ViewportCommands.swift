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

        let targetOffset = state.computeCenteredOffset(
            columnIndex: activeIndex,
            columns: columns,
            gap: gaps,
            viewportWidth: workingFrame.width
        )
        state.animateToOffset(
            targetOffset,
            motion: motion,
            scale: displayScale(in: workspaceId)
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

        let viewStart = state.targetViewPosPixels(columns: columns, gap: gaps)
        let viewportWidth = workingFrame.width

        var widthTaken: CGFloat = 0
        var leftmostColumnX: CGFloat?
        var activeColumnX: CGFloat?

        for (idx, column) in columns.enumerated() {
            let columnX = state.columnX(at: idx, columns: columns, gap: gaps)
            if columnX < viewStart + gaps {
                continue
            }

            if leftmostColumnX == nil {
                leftmostColumnX = columnX
            }

            let width = column.cachedWidth
            if viewStart + viewportWidth < columnX + width + gaps {
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
        let newViewStart = leftmostColumnX - freeSpace / 2
        let targetOffset = newViewStart - activeColumnX
        let scale = displayScale(in: workspaceId)

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
            scale: scale
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
