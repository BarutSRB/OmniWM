import Foundation

enum NiriStateZigDeltaProjector {
    struct ProjectionResult {
        let applied: Bool
        let failureReason: String?
    }

    static func project(
        delta: NiriStateZigKernel.DeltaExport,
        workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine,
        additionalHandlesById: [UUID: WindowHandle] = [:]
    ) -> ProjectionResult {
        struct ResolvedColumn {
            let column: NiriContainer
            let runtime: NiriStateZigKernel.RuntimeColumnState
            let windowRecords: [NiriStateZigKernel.DeltaWindowRecord]
            let windows: [NiriWindow]
        }

        let root = engine.ensureRoot(for: workspaceId)
        let initialColumns = root.columns
        let initialWindows = root.allWindows
        let initialWindowHandleIds = Set(initialWindows.map { $0.handle.id })

        var existingColumnsById: [NodeId: NiriContainer] = [:]
        existingColumnsById.reserveCapacity(initialColumns.count)
        for column in initialColumns {
            existingColumnsById[column.id] = column
        }

        var existingWindowsById: [NodeId: NiriWindow] = [:]
        existingWindowsById.reserveCapacity(initialWindows.count)
        for window in initialWindows {
            existingWindowsById[window.id] = window
        }

        var existingWindowsByHandleId: [UUID: NiriWindow] = [:]
        existingWindowsByHandleId.reserveCapacity(initialWindows.count)
        for window in initialWindows where existingWindowsByHandleId[window.handle.id] == nil {
            existingWindowsByHandleId[window.handle.id] = window
        }

        var handleById: [UUID: WindowHandle] = [:]
        handleById.reserveCapacity(
            engine.handleToNode.count + initialWindows.count + additionalHandlesById.count
        )
        for (handleId, handle) in additionalHandlesById {
            handleById[handleId] = handle
        }
        for handle in engine.handleToNode.keys where handleById[handle.id] == nil {
            handleById[handle.id] = handle
        }
        for window in initialWindows where handleById[window.handle.id] == nil {
            handleById[window.handle.id] = window.handle
        }

        let orderedColumns = delta.columns.sorted { $0.orderIndex < $1.orderIndex }
        var seenColumnOrders = Set<Int>()
        seenColumnOrders.reserveCapacity(orderedColumns.count)
        for column in orderedColumns {
            if !seenColumnOrders.insert(column.orderIndex).inserted {
                return fail("duplicate delta column order index \(column.orderIndex)")
            }
        }
        let orderedWindows = delta.windows.sorted {
            if $0.columnOrderIndex == $1.columnOrderIndex {
                return $0.rowIndex < $1.rowIndex
            }
            return $0.columnOrderIndex < $1.columnOrderIndex
        }
        var claimedWindowSlots = Array(repeating: false, count: orderedWindows.count)

        var usedColumns = Set<ObjectIdentifier>()
        var usedWindows = Set<ObjectIdentifier>()
        var resolvedColumns: [ResolvedColumn] = []
        resolvedColumns.reserveCapacity(orderedColumns.count)

        for orderedColumn in orderedColumns {
            let runtimeColumn = orderedColumn.column
            let resolvedColumn = existingColumnsById[runtimeColumn.columnId]
                ?? (engine.findNode(by: runtimeColumn.columnId) as? NiriContainer)
                ?? NiriContainer(id: runtimeColumn.columnId)

            let columnObjectId = ObjectIdentifier(resolvedColumn)
            guard !usedColumns.contains(columnObjectId) else {
                return fail("duplicate resolved column for id \(runtimeColumn.columnId.uuid)")
            }
            usedColumns.insert(columnObjectId)

            let start = runtimeColumn.windowStart
            let end = start + runtimeColumn.windowCount
            guard start >= 0, end >= start, end <= orderedWindows.count else {
                return fail("invalid delta column window range start=\(start) count=\(runtimeColumn.windowCount)")
            }

            var windowRecords: [NiriStateZigKernel.DeltaWindowRecord] = []
            windowRecords.reserveCapacity(runtimeColumn.windowCount)
            var resolvedWindows: [NiriWindow] = []
            resolvedWindows.reserveCapacity(runtimeColumn.windowCount)

            for idx in start ..< end {
                if claimedWindowSlots[idx] {
                    return fail("overlapping delta window range at index \(idx)")
                }
                claimedWindowSlots[idx] = true

                let windowRecord = orderedWindows[idx]
                if windowRecord.columnOrderIndex != orderedColumn.orderIndex {
                    return fail("delta window \(windowRecord.window.windowId.uuid) has mismatched column order index")
                }
                if windowRecord.window.columnId != runtimeColumn.columnId {
                    return fail("delta window \(windowRecord.window.windowId.uuid) has mismatched column id")
                }
                let expectedRowIndex = idx - start
                if windowRecord.rowIndex != expectedRowIndex {
                    return fail("delta window \(windowRecord.window.windowId.uuid) has non-contiguous row index")
                }

                windowRecords.append(windowRecord)

                let runtimeWindow = windowRecord.window
                let resolvedWindow: NiriWindow
                if let nodeById = existingWindowsById[runtimeWindow.windowId] {
                    resolvedWindow = nodeById
                } else if let globalNodeById = engine.findNode(by: runtimeWindow.windowId) as? NiriWindow {
                    resolvedWindow = globalNodeById
                } else if let nodeByHandle = existingWindowsByHandleId[runtimeWindow.windowId.uuid] {
                    resolvedWindow = nodeByHandle
                } else if let handle = handleById[runtimeWindow.windowId.uuid] {
                    resolvedWindow = NiriWindow(handle: handle, id: runtimeWindow.windowId)
                } else {
                    return fail("missing window handle for delta window id \(runtimeWindow.windowId.uuid)")
                }

                let windowObjectId = ObjectIdentifier(resolvedWindow)
                guard !usedWindows.contains(windowObjectId) else {
                    return fail("duplicate resolved window object for delta window id \(runtimeWindow.windowId.uuid)")
                }
                usedWindows.insert(windowObjectId)
                resolvedWindows.append(resolvedWindow)
            }

            resolvedColumns.append(
                ResolvedColumn(
                    column: resolvedColumn,
                    runtime: runtimeColumn,
                    windowRecords: windowRecords,
                    windows: resolvedWindows
                )
            )
        }

        if claimedWindowSlots.contains(false) {
            return fail("delta windows are not fully covered by column ranges")
        }

        for (targetColumnIndex, resolvedColumn) in resolvedColumns.enumerated() {
            let column = resolvedColumn.column
            root.insertChild(column, at: targetColumnIndex)

            guard let runtimeWidth = NiriStateZigKernel.decodeWidth(
                kind: resolvedColumn.runtime.widthKind,
                value: resolvedColumn.runtime.sizeValue
            ) else {
                return fail("invalid delta width kind for column id \(resolvedColumn.runtime.columnId.uuid)")
            }
            column.width = runtimeWidth
            column.isFullWidth = resolvedColumn.runtime.isFullWidth
            if resolvedColumn.runtime.hasSavedWidth {
                guard let runtimeSavedWidth = NiriStateZigKernel.decodeWidth(
                    kind: resolvedColumn.runtime.savedWidthKind,
                    value: resolvedColumn.runtime.savedWidthValue
                ) else {
                    return fail("invalid delta saved width kind for column id \(resolvedColumn.runtime.columnId.uuid)")
                }
                column.savedWidth = runtimeSavedWidth
            } else {
                column.savedWidth = nil
            }
            column.displayMode = resolvedColumn.runtime.isTabbed ? .tabbed : .normal

            for (targetWindowIndex, window) in resolvedColumn.windows.enumerated() {
                column.insertChild(window, at: targetWindowIndex)
                let runtimeWindow = resolvedColumn.windowRecords[targetWindowIndex].window
                guard let runtimeHeight = NiriStateZigKernel.decodeHeight(
                    kind: runtimeWindow.heightKind,
                    value: runtimeWindow.heightValue
                ) else {
                    return fail("invalid delta height kind for window id \(runtimeWindow.windowId.uuid)")
                }
                window.height = runtimeHeight
            }

            if resolvedColumn.windows.isEmpty {
                column.setActiveTileIdx(0)
            } else {
                column.setActiveTileIdx(resolvedColumn.runtime.activeTileIdx)
            }

            if !resolvedColumn.runtime.isTabbed {
                for window in resolvedColumn.windows {
                    window.isHiddenInTabbedMode = false
                }
            }
        }

        let activeColumnObjects = Set(resolvedColumns.map { ObjectIdentifier($0.column) })
        for staleColumn in initialColumns where !activeColumnObjects.contains(ObjectIdentifier(staleColumn)) {
            staleColumn.remove()
        }

        let activeWindowObjects = Set(resolvedColumns.flatMap { $0.windows }.map(ObjectIdentifier.init))
        for staleWindow in initialWindows where !activeWindowObjects.contains(ObjectIdentifier(staleWindow)) {
            engine.closingHandles.remove(staleWindow.handle)
            staleWindow.remove()
        }

        let activeHandleIds = Set(root.allWindows.map { $0.handle.id })
        for (handle, node) in engine.handleToNode {
            if activeHandleIds.contains(handle.id) {
                continue
            }
            if node.findRoot()?.workspaceId == workspaceId ||
                (node.findRoot() == nil && initialWindowHandleIds.contains(handle.id))
            {
                engine.handleToNode.removeValue(forKey: handle)
            }
        }
        for window in root.allWindows {
            engine.handleToNode[window.handle] = window
        }

        if delta.resetAllColumnCachedWidths {
            for column in root.columns {
                column.cachedWidth = 0
            }
        }

        for columnId in delta.refreshTabbedVisibilityColumnIds {
            if let column = root.findNode(by: columnId) as? NiriContainer {
                engine.updateTabbedColumnVisibility(column: column)
            }
        }

        return ProjectionResult(applied: true, failureReason: nil)
    }

    private static func fail(_ reason: String) -> ProjectionResult {
        ProjectionResult(applied: false, failureReason: reason)
    }
}
