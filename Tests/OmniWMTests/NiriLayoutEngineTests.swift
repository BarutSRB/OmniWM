import ApplicationServices
import Foundation
import Testing

@testable import OmniWM

func makeTestHandle(pid: pid_t = 1) -> WindowHandle {
    WindowHandle(
        id: WindowToken(pid: pid, windowId: Int.random(in: 1 ... 1_000_000)),
        pid: pid,
        axElement: AXUIElementCreateSystemWide()
    )
}

func makeTestMonitor(
    displayId: CGDirectDisplayID,
    name: String,
    x: CGFloat
) -> Monitor {
    let frame = CGRect(x: x, y: 0, width: 1920, height: 1080)
    return Monitor(
        id: Monitor.ID(displayId: displayId),
        displayId: displayId,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: name
    )
}

private func hasNiriScrollDirective(
    _ directives: [AnimationDirective],
    workspaceId: WorkspaceDescriptor.ID
) -> Bool {
    directives.contains { directive in
        if case let .startNiriScroll(candidate) = directive {
            return candidate == workspaceId
        }
        return false
    }
}

private func hasActivationDirective(
    _ directives: [AnimationDirective],
    token: WindowToken
) -> Bool {
    directives.contains { directive in
        if case let .activateWindow(candidate) = directive {
            return candidate == token
        }
        return false
    }
}

private func hasHiddenVisibilityChange(_ changes: [LayoutVisibilityChange]) -> Bool {
    changes.contains { change in
        if case .hide = change {
            return true
        }
        return false
    }
}

private func hiddenVisibilitySides(_ changes: [LayoutVisibilityChange]) -> [HideSide] {
    changes.compactMap { change in
        if case let .hide(_, side: side) = change {
            return side
        }
        return nil
    }
}

private func hasHideVisibilityChange(
    _ changes: [LayoutVisibilityChange],
    token: WindowToken,
    side: HideSide? = nil
) -> Bool {
    changes.contains { change in
        guard case let .hide(candidate, changeSide) = change,
              candidate == token
        else {
            return false
        }
        return side == nil || side == changeSide
    }
}

private func hasShowVisibilityChange(
    _ changes: [LayoutVisibilityChange],
    token: WindowToken
) -> Bool {
    changes.contains { change in
        if case let .show(candidate) = change {
            return candidate == token
        }
        return false
    }
}

private func hasAnyVisibilityChange(
    _ changes: [LayoutVisibilityChange],
    token: WindowToken
) -> Bool {
    hasHideVisibilityChange(changes, token: token) || hasShowVisibilityChange(changes, token: token)
}

@Suite struct NiriLayoutEngineTests {
    private func makeVisibleColumnFixture(
        visibleCount: Int,
        extraColumns: Int = 2,
        width: CGFloat = 1600,
        height: CGFloat = 900
    ) -> (
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        windows: [NiriWindow],
        monitor: Monitor,
        gap: CGFloat,
        gaps: LayoutGaps,
        area: WorkingAreaContext
    ) {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1, maxVisibleColumns: visibleCount)
        engine.centerFocusedColumn = .never

        let workspaceId = UUID()
        var windows: [NiriWindow] = []
        var previousSelection: NodeId?

        for index in 0 ..< (visibleCount + extraColumns) {
            let handle = makeTestHandle(pid: pid_t(200 + index))
            let window = engine.addWindow(
                handle: handle,
                to: workspaceId,
                afterSelection: previousSelection
            )
            windows.append(window)
            previousSelection = window.id
        }

        let monitor = makeLayoutPlanTestMonitor(width: width, height: height)
        let gap: CGFloat = 8
        let gaps = LayoutGaps(horizontal: gap, vertical: gap)
        let area = WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )
        let fixedWidth = (monitor.visibleFrame.width - gap * CGFloat(visibleCount - 1)) / CGFloat(visibleCount)

        for column in engine.columns(in: workspaceId) {
            column.width = .fixed(fixedWidth)
            column.cachedWidth = fixedWidth
        }

        return (engine, workspaceId, windows, monitor, gap, gaps, area)
    }

    private func makeViewportStateForVisibleColumn(
        targetWindow: NiriWindow,
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        gap: CGFloat
    ) -> ViewportState {
        var state = ViewportState()
        state.animationClock = engine.animationClock
        state.selectedNodeId = targetWindow.id
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)
        engine.ensureSelectionVisible(
            node: targetWindow,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )
        return state
    }

    private func settledLayoutState(
        from state: ViewportState,
        column: NiriContainer?,
        settleTime: TimeInterval
    ) -> ViewportState {
        var settledState = state
        _ = settledState.advanceAnimations(at: settleTime)
        _ = column?.tickWidthAnimation(at: settleTime)
        return settledState
    }

    private func assignFixedWidths(
        _ columns: [NiriContainer],
        width: CGFloat = 400
    ) {
        for column in columns {
            column.width = .fixed(width)
            column.cachedWidth = width
        }
    }

    private func assignWidths(
        _ columns: [NiriContainer],
        widths: [CGFloat]
    ) {
        for (column, width) in zip(columns, widths) {
            column.width = .fixed(width)
            column.cachedWidth = width
        }
    }

    private func resolvedSettings(
        for engine: NiriLayoutEngine,
        maxVisibleColumns: Int? = nil,
        maxWindowsPerColumn: Int? = nil,
        centerFocusedColumn: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowAspectRatio: SingleWindowAspectRatio? = nil,
        infiniteLoop: Bool? = nil
    ) -> ResolvedNiriSettings {
        let global = engine.globalResolvedSettings()
        return ResolvedNiriSettings(
            maxVisibleColumns: maxVisibleColumns ?? global.maxVisibleColumns,
            maxWindowsPerColumn: maxWindowsPerColumn ?? global.maxWindowsPerColumn,
            centerFocusedColumn: centerFocusedColumn ?? global.centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn ?? global.alwaysCenterSingleColumn,
            singleWindowAspectRatio: singleWindowAspectRatio ?? global.singleWindowAspectRatio,
            infiniteLoop: infiniteLoop ?? global.infiniteLoop
        )
    }

    private func attachWorkspace(
        _ workspaceId: WorkspaceDescriptor.ID,
        to monitor: Monitor,
        engine: NiriLayoutEngine,
        resolvedSettings: ResolvedNiriSettings? = nil
    ) {
        engine.moveWorkspace(workspaceId, to: monitor.id, monitor: monitor)
        if let resolvedSettings {
            engine.updateMonitorSettings(resolvedSettings, for: monitor.id)
        }
    }

    @Test func selectionFallbackAfterRemoval_sameSibling() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)
        let _ = engine.addWindow(handle: h3, to: wsId, afterSelection: w2.id)

        let cols = engine.columns(in: wsId)
        #expect(cols.count >= 2)

        let fallback = engine.fallbackSelectionOnRemoval(removing: w2.id, in: wsId)
        #expect(fallback != nil)
        #expect(fallback != w2.id)

        let fallbackNode = engine.findNode(by: fallback!)
        #expect(fallbackNode != nil)
    }

    @Test func firstWindowUsesBalancedWidthWhenDefaultWidthIsAutoWhenSingleWindowRatioIsDisabled() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.presetColumnWidths = [.proportion(0.85), .proportion(1.0), .proportion(0.5)]
        engine.singleWindowAspectRatio = .none
        let wsId = UUID()

        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)

        guard let column = engine.column(of: window) else {
            Issue.record("Expected claimed column for first window")
            return
        }

        #expect(column.width == .proportion(1.0 / 3.0))
        #expect(column.presetWidthIdx == nil)
    }

    @Test func firstWindowUsesResolvedMonitorMaxVisibleColumnsWhenDefaultWidthIsAuto() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 1)
        engine.presetColumnWidths = [.proportion(0.85), .proportion(1.0), .proportion(0.5)]
        engine.singleWindowAspectRatio = .none
        let wsId = UUID()
        let monitor = makeTestMonitor(displayId: 501, name: "Override", x: 0)
        attachWorkspace(
            wsId,
            to: monitor,
            engine: engine,
            resolvedSettings: resolvedSettings(for: engine, maxVisibleColumns: 3)
        )

        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)

        guard let column = engine.column(of: window) else {
            Issue.record("Expected claimed column for monitor-override width test")
            return
        }

        #expect(column.width == .proportion(1.0 / 3.0))
        #expect(column.presetWidthIdx == nil)
    }

    @Test func singleWindowAspectRatioCentersLoneWindowFrame() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.singleWindowAspectRatio = .ratio4x3
        engine.alwaysCenterSingleColumn = false
        let wsId = UUID()
        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        let monitor = makeLayoutPlanTestMonitor()

        let layout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: 8, vertical: 8),
            state: ViewportState()
        )

        guard let frame = layout.frames[window.token] else {
            Issue.record("Expected a rendered frame for the single Niri window")
            return
        }

        #expect(frame == CGRect(x: 240, y: 0, width: 1440, height: 1080))
    }

    @Test func addingSecondWindowReturnsToNormalColumnSizingAfterSingleWindowOverride() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.singleWindowAspectRatio = .ratio4x3
        engine.alwaysCenterSingleColumn = false
        let wsId = UUID()
        let gap: CGFloat = 8
        let firstWindow = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        let monitor = makeLayoutPlanTestMonitor()

        let singleWindowLayout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: gap, vertical: gap),
            state: ViewportState()
        )

        let secondWindow = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: firstWindow.id)
        let twoWindowLayout = engine.calculateCombinedLayoutWithVisibility(
            in: wsId,
            monitor: monitor,
            gaps: LayoutGaps(horizontal: gap, vertical: gap),
            state: ViewportState()
        )

        guard let singleFrame = singleWindowLayout.frames[firstWindow.token],
              let firstFrame = twoWindowLayout.frames[firstWindow.token],
              let secondFrame = twoWindowLayout.frames[secondWindow.token]
        else {
            Issue.record("Expected rendered frames before and after adding a second Niri window")
            return
        }

        let expectedColumnWidth = ((monitor.visibleFrame.width - gap) / 3).roundedToPhysicalPixel(scale: 2.0)

        #expect(engine.columns(in: wsId).count == 2)
        #expect(firstFrame.width < singleFrame.width)
        #expect(abs(firstFrame.width - expectedColumnWidth) < 0.6)
        #expect(abs(secondFrame.width - expectedColumnWidth) < 0.6)
        #expect(firstFrame.height == monitor.visibleFrame.height)
        #expect(secondFrame.height == monitor.visibleFrame.height)
    }

    @Test func additionalWindowUsesExplicitDefaultWidthWhenCreatingNewColumn() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.presetColumnWidths = [.proportion(0.85), .proportion(1.0), .proportion(0.5)]
        engine.defaultColumnWidth = 0.6
        let wsId = UUID()

        let firstWindow = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        let secondWindow = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: firstWindow.id)

        guard let column = engine.column(of: secondWindow) else {
            Issue.record("Expected new column for second window")
            return
        }

        #expect(engine.columns(in: wsId).count == 2)
        #expect(column.width == .proportion(0.6))
        #expect(column.presetWidthIdx == nil)
    }

    @Test func selectionFallbackAfterColumnRemoval() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)
        let w3 = engine.addWindow(handle: h3, to: wsId, afterSelection: w2.id)

        let cols = engine.columns(in: wsId)
        #expect(cols.count == 3)

        let middleColIdx = 1
        var state = ViewportState()
        state.activeColumnIndex = 0

        let result = engine.animateColumnsForRemoval(
            columnIndex: middleColIdx,
            in: wsId,
            state: &state,
            gaps: 8
        )

        #expect(result.fallbackSelectionId != nil)
        let fallbackNode = engine.findNode(by: result.fallbackSelectionId!)
        #expect(fallbackNode != nil)
        #expect(result.fallbackSelectionId != w2.id)
        let isW1OrW3 = result.fallbackSelectionId == w1.id || result.fallbackSelectionId == w3.id
        #expect(isW1OrW3)
    }

    @Test func viewportOffsetAdjustsForInsertionBeforeActive() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let _ = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)

        let cols = engine.columns(in: wsId)
        #expect(cols.count == 2)

        let workingWidth: CGFloat = 1000
        let gap: CGFloat = 8
        for col in cols {
            col.resolveAndCacheWidth(workingAreaWidth: workingWidth, gaps: gap)
        }

        var state = ViewportState()
        state.activeColumnIndex = 1
        state.viewOffsetPixels = .static(0)

        let h3 = makeTestHandle()
        engine.syncWindows(
            [h3, h1, h2],
            in: wsId,
            selectedNodeId: w1.id,
            focusedHandle: nil
        )

        let colsAfter = engine.columns(in: wsId)
        #expect(colsAfter.count == 3)

        let newNode = engine.findNode(for: h3)
        #expect(newNode != nil)

        if let newCol = engine.column(of: newNode!),
           let newColIdx = engine.columnIndex(of: newCol, in: wsId)
        {
            if newColIdx <= state.activeColumnIndex {
                newCol.resolveAndCacheWidth(workingAreaWidth: workingWidth, gaps: gap)
                let shiftAmount = newCol.cachedWidth + gap
                state.viewOffsetPixels.offset(delta: Double(-shiftAmount))
                state.activeColumnIndex += 1
            }
        }

        #expect(state.viewOffsetPixels.current() < 0)
        #expect(state.activeColumnIndex == 2)
    }

    @Test func constraintApplicationRespectsBounds() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()

        let h1 = makeTestHandle()
        let _ = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)

        let constraints = WindowSizeConstraints(
            minSize: CGSize(width: 400, height: 300),
            maxSize: CGSize(width: 800, height: 600),
            isFixed: false
        )
        engine.updateWindowConstraints(for: h1, constraints: constraints)

        let window = engine.findNode(for: h1)!
        #expect(window.constraints == constraints)
        #expect(window.constraints.minSize.width == 400)
        #expect(window.constraints.maxSize.width == 800)
    }

    @Test func syncWindowsIdempotency() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()

        engine.syncWindows([h1, h2, h3], in: wsId, selectedNodeId: nil)

        let colCount1 = engine.columns(in: wsId).count
        let windowIds1 = engine.root(for: wsId)!.windowIdSet

        engine.syncWindows([h1, h2, h3], in: wsId, selectedNodeId: nil)

        let colCount2 = engine.columns(in: wsId).count
        let windowIds2 = engine.root(for: wsId)!.windowIdSet

        #expect(colCount1 == colCount2)
        #expect(windowIds1 == windowIds2)
    }

    @Test func syncWindowsKeepsStableNodeForReobservedToken() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()

        let original = makeTestHandle(pid: 21)
        let refreshed = WindowHandle(
            id: original.id,
            pid: original.pid,
            axElement: AXUIElementCreateSystemWide()
        )

        engine.syncWindows([original], in: wsId, selectedNodeId: nil)
        let originalNodeId = engine.findNode(for: original.id)?.id

        engine.syncWindows([refreshed], in: wsId, selectedNodeId: nil)

        #expect(engine.root(for: wsId)?.allWindows.count == 1)
        #expect(engine.root(for: wsId)?.windowIdSet == Set([original.id]))
        #expect(engine.findNode(for: refreshed.id)?.id == originalNodeId)
    }

    @Test func rekeyWindowKeepsNodeAndSelectionStableAcrossSync() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()

        let handle1 = makeTestHandle(pid: 61)
        let handle2 = makeTestHandle(pid: 62)
        let handle3 = makeTestHandle(pid: 63)

        let firstWindow = engine.addWindow(handle: handle1, to: wsId, afterSelection: nil)
        let rekeyedWindow = engine.addWindow(handle: handle2, to: wsId, afterSelection: firstWindow.id)
        let _ = engine.addWindow(handle: handle3, to: wsId, afterSelection: rekeyedWindow.id)

        let replacementToken = WindowToken(pid: handle2.pid, windowId: handle2.windowId + 1000)
        let originalNodeId = rekeyedWindow.id

        #expect(engine.rekeyWindow(from: handle2.id, to: replacementToken))

        let removed = engine.syncWindows(
            [handle1.id, replacementToken, handle3.id],
            in: wsId,
            selectedNodeId: originalNodeId,
            focusedToken: handle3.id
        )

        #expect(removed.isEmpty)
        #expect(engine.findNode(for: handle2.id) == nil)
        #expect(engine.findNode(for: replacementToken)?.id == originalNodeId)
        #expect(engine.validateSelection(originalNodeId, in: wsId) == originalNodeId)
        #expect(engine.root(for: wsId)?.windowIdSet == Set([handle1.id, replacementToken, handle3.id]))
    }

    @Test func ensureSelectionVisibleMovesViewport() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)
        let w3 = engine.addWindow(handle: h3, to: wsId, afterSelection: w2.id)

        let workingFrame = CGRect(x: 0, y: 0, width: 500, height: 900)
        let gap: CGFloat = 8
        for col in engine.columns(in: wsId) {
            col.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gap)
        }

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        engine.ensureSelectionVisible(
            node: w3,
            in: wsId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        )

        #expect(state.activeColumnIndex == 2)
    }

    @Test func moveWindowHorizontalRightExpelsFocusedWindowIntoNewColumn() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let firstHandle = makeTestHandle(pid: 71)
        let focusedHandle = makeTestHandle(pid: 72)
        let rightHandle = makeTestHandle(pid: 73)
        let firstWindow = NiriWindow(token: firstHandle.id)
        let focusedWindow = NiriWindow(token: focusedHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(firstWindow)
        leftColumn.appendChild(focusedWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[firstHandle.id] = firstWindow
        engine.tokenToNode[focusedHandle.id] = focusedWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 0

        let moved = engine.moveWindow(
            focusedWindow,
            direction: .right,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(moved)
        #expect(columns.count == 3)
        #expect(columns[0].windowNodes.map(\.token) == [firstHandle.id])
        #expect(columns[1].windowNodes.map(\.token) == [focusedHandle.id])
        #expect(columns[2].windowNodes.map(\.token) == [rightHandle.id])
    }

    @Test func moveWindowHorizontalRightConsumesSingleWindowColumnIntoNeighbor() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let leftHandle = makeTestHandle(pid: 81)
        let rightHandle = makeTestHandle(pid: 82)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 0

        let moved = engine.moveWindow(
            leftWindow,
            direction: .right,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(moved)
        #expect(columns.count == 1)
        #expect(columns[0] === rightColumn)
        #expect(columns[0].windowNodes.map(\.token) == [leftHandle.id, rightHandle.id])
        #expect(columns[0].hasMoveAnimationRunning)

        let windowOffset = leftWindow.moveXAnimation?.fromOffset
        #expect(windowOffset != nil)
        #expect(windowOffset! < -300)

        let columnOffset = rightColumn.moveAnimation?.fromOffset
        #expect(columnOffset != nil)
        #expect(columnOffset! > 300)
    }

    @Test func moveWindowHorizontalRightConsumesSingleWindowColumnIntoNeighborWhenMonitorOverrideAllowsIt() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()
        let monitor = makeTestMonitor(displayId: 601, name: "Override", x: 0)
        attachWorkspace(
            wsId,
            to: monitor,
            engine: engine,
            resolvedSettings: resolvedSettings(for: engine, maxWindowsPerColumn: 2)
        )

        guard let root = engine.root(for: wsId),
              let leftColumn = root.columns.first
        else {
            Issue.record("Expected mapped workspace root for consume override test")
            return
        }

        let rightColumn = NiriContainer()
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let leftHandle = makeTestHandle(pid: 181)
        let rightHandle = makeTestHandle(pid: 182)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 0

        let moved = engine.moveWindow(
            leftWindow,
            direction: .right,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(moved)
        #expect(columns.count == 1)
        #expect(columns[0] === rightColumn)
        #expect(columns[0].windowNodes.map(\.token) == [leftHandle.id, rightHandle.id])
    }

    @Test func moveWindowHorizontalRightDoesNotConsumeSingleWindowColumnIntoNeighborWithoutMonitorOverride() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()
        let monitor = makeTestMonitor(displayId: 602, name: "GlobalOnly", x: 0)
        attachWorkspace(wsId, to: monitor, engine: engine)

        guard let root = engine.root(for: wsId),
              let leftColumn = root.columns.first
        else {
            Issue.record("Expected mapped workspace root for consume fallback test")
            return
        }

        let rightColumn = NiriContainer()
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let leftHandle = makeTestHandle(pid: 183)
        let rightHandle = makeTestHandle(pid: 184)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 0

        let moved = engine.moveWindow(
            leftWindow,
            direction: .right,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(!moved)
        #expect(columns.count == 2)
        #expect(columns[0].windowNodes.map(\.token) == [leftHandle.id])
        #expect(columns[1].windowNodes.map(\.token) == [rightHandle.id])
    }

    @Test func moveWindowHorizontalLeftConsumesSingleWindowColumnIntoNeighbor() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let leftHandle = makeTestHandle(pid: 83)
        let rightHandle = makeTestHandle(pid: 84)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 1

        let moved = engine.moveWindow(
            rightWindow,
            direction: .left,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(moved)
        #expect(columns.count == 1)
        #expect(columns[0] === leftColumn)
        #expect(columns[0].windowNodes.map(\.token) == [rightHandle.id, leftHandle.id])
        #expect(!columns[0].hasMoveAnimationRunning)

        let windowOffset = rightWindow.moveXAnimation?.fromOffset
        #expect(windowOffset != nil)
        #expect(windowOffset! > 300)
    }

    @Test func ensureSelectionVisibleUsesExplicitPreviousActivePositionAfterColumnRemoval() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        engine.centerFocusedColumn = .never
        engine.alwaysCenterSingleColumn = false
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)
        assignWidths(root.columns, widths: [300, 500])

        let leftHandle = makeTestHandle(pid: 85)
        let rightHandle = makeTestHandle(pid: 86)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 1
        state.viewOffsetPixels = .static(0)

        let previousActivePosition = state.columnX(
            at: state.activeColumnIndex,
            columns: engine.columns(in: wsId),
            gap: 8
        )

        leftColumn.remove()

        engine.ensureSelectionVisible(
            node: rightWindow,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 700, height: 900),
            gaps: 8,
            fromContainerIndex: 1,
            previousActiveContainerPosition: previousActivePosition
        )

        if case let .spring(animation) = state.viewOffsetPixels {
            #expect(abs(animation.from - Double(previousActivePosition)) < 0.1)
        } else {
            #expect(Bool(false))
        }
    }

    @Test func moveWindowHorizontalLeftNoOpsAtEdgeWithoutInfiniteLoop() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, infiniteLoop: false)
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let leftHandle = makeTestHandle(pid: 91)
        let rightHandle = makeTestHandle(pid: 92)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 0

        let moved = engine.moveWindow(
            leftWindow,
            direction: .left,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(!moved)
        #expect(columns.count == 2)
        #expect(columns[0].windowNodes.map(\.token) == [leftHandle.id])
        #expect(columns[1].windowNodes.map(\.token) == [rightHandle.id])
    }

    @Test func moveWindowHorizontalLeftWrapsAtEdgeWhenInfiniteLoopIsEnabled() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, infiniteLoop: true)
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let leftHandle = makeTestHandle(pid: 101)
        let rightHandle = makeTestHandle(pid: 102)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 0

        let moved = engine.moveWindow(
            leftWindow,
            direction: .left,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(moved)
        #expect(columns.count == 1)
        #expect(columns[0].windowNodes.map(\.token) == [leftHandle.id, rightHandle.id])
    }

    @Test func moveWindowHorizontalLeftWrapsAtEdgeWhenMonitorOverrideEnablesInfiniteLoop() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, infiniteLoop: false)
        let wsId = UUID()
        let monitor = makeTestMonitor(displayId: 701, name: "Wrap", x: 0)
        attachWorkspace(
            wsId,
            to: monitor,
            engine: engine,
            resolvedSettings: resolvedSettings(for: engine, infiniteLoop: true)
        )

        guard let root = engine.root(for: wsId),
              let leftColumn = root.columns.first
        else {
            Issue.record("Expected mapped workspace root for infinite-loop override test")
            return
        }

        let rightColumn = NiriContainer()
        root.appendChild(rightColumn)
        assignFixedWidths(root.columns)

        let leftHandle = makeTestHandle(pid: 191)
        let rightHandle = makeTestHandle(pid: 192)
        let leftWindow = NiriWindow(token: leftHandle.id)
        let rightWindow = NiriWindow(token: rightHandle.id)

        leftColumn.appendChild(leftWindow)
        rightColumn.appendChild(rightWindow)

        engine.tokenToNode[leftHandle.id] = leftWindow
        engine.tokenToNode[rightHandle.id] = rightWindow

        var state = ViewportState()
        state.activeColumnIndex = 0

        let moved = engine.moveWindow(
            leftWindow,
            direction: .left,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        #expect(moved)
        #expect(columns.count == 1)
        #expect(columns[0].windowNodes.map(\.token) == [leftHandle.id, rightHandle.id])
    }

    @Test func ensureSelectionVisibleUsesResolvedMonitorAlwaysCenterSingleColumn() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        engine.centerFocusedColumn = .never
        engine.alwaysCenterSingleColumn = false
        let wsId = UUID()
        let monitor = makeTestMonitor(displayId: 801, name: "CenterSingle", x: 0)
        attachWorkspace(
            wsId,
            to: monitor,
            engine: engine,
            resolvedSettings: resolvedSettings(
                for: engine,
                centerFocusedColumn: .never,
                alwaysCenterSingleColumn: true
            )
        )

        let window = engine.addWindow(handle: makeTestHandle(pid: 211), to: wsId, afterSelection: nil)
        assignFixedWidths(engine.columns(in: wsId))

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        engine.ensureSelectionVisible(
            node: window,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        #expect(abs(state.viewOffsetPixels.target() + 400) < 0.1)
    }

    @Test func ensureSelectionVisibleUsesResolvedMonitorCenterFocusedColumn() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        engine.centerFocusedColumn = .never
        engine.alwaysCenterSingleColumn = false
        let wsId = UUID()
        let monitor = makeTestMonitor(displayId: 802, name: "CenterMode", x: 0)
        attachWorkspace(
            wsId,
            to: monitor,
            engine: engine,
            resolvedSettings: resolvedSettings(
                for: engine,
                centerFocusedColumn: .always,
                alwaysCenterSingleColumn: false
            )
        )

        let first = engine.addWindow(handle: makeTestHandle(pid: 212), to: wsId, afterSelection: nil)
        let second = engine.addWindow(handle: makeTestHandle(pid: 213), to: wsId, afterSelection: first.id)
        assignFixedWidths(engine.columns(in: wsId))

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        engine.ensureSelectionVisible(
            node: second,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        #expect(abs(state.viewOffsetPixels.target() + 604) < 0.1)
    }

    @Test func moveWindowVerticalKeepsInColumnReorderBehavior() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let column = NiriContainer()
        root.appendChild(column)
        assignFixedWidths(root.columns)

        let firstHandle = makeTestHandle(pid: 111)
        let focusedHandle = makeTestHandle(pid: 112)
        let lastHandle = makeTestHandle(pid: 113)
        let firstWindow = NiriWindow(token: firstHandle.id)
        let focusedWindow = NiriWindow(token: focusedHandle.id)
        let lastWindow = NiriWindow(token: lastHandle.id)

        column.appendChild(firstWindow)
        column.appendChild(focusedWindow)
        column.appendChild(lastWindow)

        engine.tokenToNode[firstHandle.id] = firstWindow
        engine.tokenToNode[focusedHandle.id] = focusedWindow
        engine.tokenToNode[lastHandle.id] = lastWindow

        let beforeMove = column.windowNodes.map(\.token)
        var state = ViewportState()

        let moved = engine.moveWindow(
            focusedWindow,
            direction: .up,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gaps: 8
        )

        let afterMove = column.windowNodes.map(\.token)
        #expect(moved)
        #expect(beforeMove == [firstHandle.id, focusedHandle.id, lastHandle.id])
        #expect(afterMove == [firstHandle.id, lastHandle.id, focusedHandle.id])
    }

    @Test @MainActor func horizontalConsumeStartsAnimationLoopAndSettlesMovedWindowFrame() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for horizontal consume regression test")
            return
        }

        controller.enableNiriLayout(
            maxWindowsPerColumn: 3,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        controller.updateNiriConfig(
            maxVisibleColumns: 3,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.layoutRefreshController.stopAllScrollAnimations()
        controller.syncMonitorsToNiriEngine()

        let leftWindowId = 811
        let focusedWindowId = 812
        let rightWindowId = 813

        let leftToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: leftWindowId)
        let focusedToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: focusedWindowId)
        let rightToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: rightWindowId)

        _ = controller.workspaceManager.setManagedFocus(focusedToken, in: workspaceId, onMonitor: monitor.id)

        guard let engine = controller.niriEngine,
              let focusedHandle = controller.workspaceManager.handle(for: focusedToken)
        else {
            Issue.record("Expected Niri engine and focused handle for horizontal consume regression test")
            return
        }

        let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
        _ = engine.syncWindows(
            handles,
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: focusedHandle
        )

        let columns = engine.columns(in: workspaceId)
        guard columns.count == 3 else {
            Issue.record("Expected three visible columns before consuming the focused window")
            return
        }
        assignFixedWidths(columns)

        guard let focusedNode = engine.findNode(for: focusedToken) else {
            Issue.record("Expected focused node in Niri engine before consuming window")
            return
        }

        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: focusedNode.id,
            focusedToken: focusedToken,
            in: workspaceId,
            onMonitor: monitor.id
        )
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = focusedNode.id
            state.activeColumnIndex = 1
            state.viewOffsetPixels = .static(0)
        }

        controller.commandHandler.handleCommand(.move(.right))

        #expect(controller.niriLayoutHandler.scrollAnimationByDisplay[monitor.displayId] == workspaceId)

        await waitForLayoutPlanRefreshWork(on: controller)

        let settleTime = (engine.animationClock?.now() ?? 0) + 5.0
        controller.niriLayoutHandler.tickScrollAnimation(targetTime: settleTime, displayId: monitor.displayId)

        let movedColumns = engine.columns(in: workspaceId)
        #expect(movedColumns.count == 2)
        #expect(movedColumns[0].windowNodes.map(\.token) == [leftToken])
        #expect(movedColumns[1].windowNodes.map(\.token) == [focusedToken, rightToken])
        #expect(controller.niriLayoutHandler.scrollAnimationByDisplay[monitor.displayId] == nil)

        guard let movedNode = engine.findNode(for: focusedToken),
              let settledFrame = movedNode.renderedFrame ?? movedNode.frame,
              let appliedFrame = controller.axManager.lastAppliedFrame(for: focusedWindowId)
        else {
            Issue.record("Expected the consumed focused window to receive a settled visible frame")
            return
        }

        let workingFrame = controller.insetWorkingFrame(for: monitor)
        #expect(appliedFrame == settledFrame)
        #expect(workingFrame.intersects(appliedFrame))
    }

    @Test @MainActor func horizontalConsumeIntoTabbedColumnBottomInsertsAndActivatesConsumedWindow() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for tabbed horizontal consume regression test")
            return
        }

        controller.enableNiriLayout(
            maxWindowsPerColumn: 4,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        controller.updateNiriConfig(
            maxVisibleColumns: 3,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.layoutRefreshController.stopAllScrollAnimations()
        controller.syncMonitorsToNiriEngine()

        let consumedWindowId = 821
        let existingBottomWindowId = 822
        let existingTopWindowId = 823

        let consumedToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: consumedWindowId)
        let existingBottomToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: existingBottomWindowId
        )
        let existingTopToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: existingTopWindowId
        )

        _ = controller.workspaceManager.setManagedFocus(consumedToken, in: workspaceId, onMonitor: monitor.id)

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri engine for tabbed horizontal consume regression test")
            return
        }

        let root = NiriRoot(workspaceId: workspaceId)
        engine.roots[workspaceId] = root
        engine.ensureMonitor(for: monitor.id, monitor: monitor).workspaceRoots[workspaceId] = root

        let sourceColumn = NiriContainer()
        let targetColumn = NiriContainer()
        targetColumn.displayMode = .tabbed
        root.appendChild(sourceColumn)
        root.appendChild(targetColumn)
        assignFixedWidths(root.columns)

        let consumedWindow = NiriWindow(token: consumedToken)
        let existingBottomWindow = NiriWindow(token: existingBottomToken)
        let existingTopWindow = NiriWindow(token: existingTopToken)

        sourceColumn.appendChild(consumedWindow)
        targetColumn.appendChild(existingBottomWindow)
        targetColumn.appendChild(existingTopWindow)
        targetColumn.setActiveTileIdx(1)
        engine.updateTabbedColumnVisibility(column: targetColumn)

        engine.tokenToNode[consumedToken] = consumedWindow
        engine.tokenToNode[existingBottomToken] = existingBottomWindow
        engine.tokenToNode[existingTopToken] = existingTopWindow

        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: consumedWindow.id,
            focusedToken: consumedToken,
            in: workspaceId,
            onMonitor: monitor.id
        )
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = consumedWindow.id
            state.activeColumnIndex = 0
            state.viewOffsetPixels = .static(0)
        }

        controller.commandHandler.handleCommand(.move(.right))
        await waitForLayoutPlanRefreshWork(on: controller)

        let columns = engine.columns(in: workspaceId)
        #expect(columns.count == 1)
        #expect(columns[0].windowNodes.map(\.token) == [consumedToken, existingBottomToken, existingTopToken])
        #expect(columns[0].activeTileIdx == 0)
        #expect(columns[0].activeWindow?.token == consumedToken)

        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(state.selectedNodeId == consumedWindow.id)
        #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == consumedToken)
        #expect(controller.workspaceManager.focusedToken == consumedToken)

        #expect(!consumedWindow.isHiddenInTabbedMode)
        #expect(existingBottomWindow.isHiddenInTabbedMode)
        #expect(existingTopWindow.isHiddenInTabbedMode)
    }

    @Test func cleanupRemovedMonitorKeepsWorkspaceRootAuthoritativeForReattach() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let oldMonitor = makeTestMonitor(displayId: 100, name: "Old", x: 0)
        let newMonitor = makeTestMonitor(displayId: 200, name: "New", x: 1920)
        let wsId = UUID()

        let oldNiriMonitor = engine.ensureMonitor(for: oldMonitor.id, monitor: oldMonitor)
        let rescuedRoot = engine.ensureRoot(for: wsId)
        oldNiriMonitor.workspaceRoots[wsId] = rescuedRoot

        engine.cleanupRemovedMonitor(oldMonitor.id)
        #expect(engine.monitor(for: oldMonitor.id) == nil)
        #expect(engine.root(for: wsId) === rescuedRoot)

        engine.moveWorkspace(wsId, to: newMonitor.id, monitor: newMonitor)

        let newNiriMonitor = engine.monitor(for: newMonitor.id)
        #expect(newNiriMonitor != nil)
        #expect(newNiriMonitor?.workspaceRoots[wsId] != nil)
        if let restoredRoot = newNiriMonitor?.workspaceRoots[wsId] {
            #expect(restoredRoot === rescuedRoot)
        }
    }

    @Test func moveWindowToWorkspaceUsesExplicitDefaultWidthForTargetColumn() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.presetColumnWidths = [.proportion(0.85), .proportion(1.0), .proportion(0.5)]
        engine.defaultColumnWidth = 0.7
        let sourceWorkspaceId = UUID()
        let targetWorkspaceId = UUID()

        let window = engine.addWindow(handle: makeTestHandle(), to: sourceWorkspaceId, afterSelection: nil)
        var sourceState = ViewportState()
        var targetState = ViewportState()

        let moved = engine.moveWindowToWorkspace(
            window,
            from: sourceWorkspaceId,
            to: targetWorkspaceId,
            sourceState: &sourceState,
            targetState: &targetState
        )

        guard let targetColumn = engine.columns(in: targetWorkspaceId).first else {
            Issue.record("Expected target column after workspace move")
            return
        }

        #expect(moved != nil)
        #expect(targetColumn.width == .proportion(0.7))
        #expect(targetColumn.presetWidthIdx == nil)
    }

    @Test func workspaceSwitchAnimationUsesSnapshotOrdering() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let monitor = makeTestMonitor(displayId: 300, name: "Main", x: 0)
        let ws1 = UUID()
        let ws2 = UUID()
        let handle1 = makeTestHandle(pid: 11)
        let handle2 = makeTestHandle(pid: 12)

        let niriMonitor = engine.ensureMonitor(for: monitor.id, monitor: monitor)
        niriMonitor.animationClock = AnimationClock()

        _ = engine.addWindow(handle: handle1, to: ws1, afterSelection: nil)
        _ = engine.addWindow(handle: handle2, to: ws2, afterSelection: nil)
        engine.moveWorkspace(ws1, to: monitor.id, monitor: monitor)
        engine.moveWorkspace(ws2, to: monitor.id, monitor: monitor)

        niriMonitor.startWorkspaceSwitch(
            orderedWorkspaceIds: [ws1, ws2],
            from: ws1,
            to: ws2
        )

        guard let time = niriMonitor.animationClock?.now() else {
            Issue.record("Expected animation clock for workspace switch test")
            return
        }
        let state = ViewportState()
        let gaps = LayoutGaps(horizontal: 8, vertical: 8)

        let layout1 = engine.calculateCombinedLayoutWithVisibility(
            in: ws1,
            monitor: monitor,
            gaps: gaps,
            state: state,
            animationTime: time
        )
        let layout2 = engine.calculateCombinedLayoutWithVisibility(
            in: ws2,
            monitor: monitor,
            gaps: gaps,
            state: state,
            animationTime: time
        )

        #expect(niriMonitor.workspaceSwitch?.fromWorkspaceId == ws1)
        #expect(niriMonitor.workspaceSwitch?.toWorkspaceId == ws2)
        #expect(niriMonitor.workspaceSwitch?.orderedWorkspaceIds == [ws1, ws2])
        #expect(layout1.frames[handle1.id]?.minX == 0)
        #expect((layout2.frames[handle2.id]?.minX ?? 0) > 0)
    }

    @Test @MainActor func relayoutPlanUsesResolvedMonitorSingleWindowAspectRatio() async throws {
        let monitor = makeLayoutPlanTestMonitor(name: "SquareTest")
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing active workspace for Niri settings test")
            return
        }

        controller.enableNiriLayout(
            maxWindowsPerColumn: 3,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        controller.updateNiriConfig(
            maxVisibleColumns: 3,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false,
            singleWindowAspectRatio: .ratio4x3
        )
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 881)

        let baselinePlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let baselinePlan = baselinePlans.first,
              let baselineFrame = baselinePlan.diff.frameChanges.first(where: { $0.token == token })?.frame
        else {
            Issue.record("Expected a baseline Niri frame for the single window")
            return
        }

        controller.settings.updateNiriSettings(
            MonitorNiriSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                singleWindowAspectRatio: .square
            )
        )
        controller.updateMonitorNiriSettings()

        let overridePlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let overridePlan = overridePlans.first,
              let overrideFrame = overridePlan.diff.frameChanges.first(where: { $0.token == token })?.frame
        else {
            Issue.record("Expected a Niri frame after applying monitor override settings")
            return
        }

        #expect(baselineFrame.width > overrideFrame.width)
        #expect(abs(overrideFrame.width - overrideFrame.height) < 0.5)
    }

    @Test @MainActor func snapshotPlanIncludesViewportPatchAndActivationForNewWindow() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for Niri plan test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()
        controller.niriEngine?.presetColumnWidths = [.proportion(1.0), .proportion(0.5)]

        let firstToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 401)
        _ = controller.workspaceManager.setManagedFocus(firstToken, in: workspaceId, onMonitor: monitor.id)

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        let newToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 402)

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let plan = plans.first else {
            Issue.record("Expected a Niri layout plan for the active workspace")
            return
        }

        #expect(plan.sessionPatch.viewportState != nil)
        #expect(plan.sessionPatch.rememberedFocusToken == newToken)
        #expect(hasNiriScrollDirective(plan.animationDirectives, workspaceId: workspaceId))
        #expect(hasActivationDirective(plan.animationDirectives, token: newToken))
    }

    @Test @MainActor func snapshotPlanEmitsHideDiffForOffscreenWindows() async throws {
        let monitor = makeLayoutPlanTestMonitor(width: 1600, height: 900)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing active workspace for Niri hide-diff test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        for windowId in 501 ... 504 {
            _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId)
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .gesture(
                ViewGesture(currentViewOffset: -2500, isTrackpad: true)
            )
        }

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let plan = plans.first else {
            Issue.record("Expected a Niri layout plan after viewport shift")
            return
        }

        #expect(hasHiddenVisibilityChange(plan.diff.visibilityChanges))
        #expect(!hiddenVisibilitySides(plan.diff.visibilityChanges).isEmpty)
    }

    @Test @MainActor func snapshotPlanDoesNotHideFullscreenTokenOnRightVisibleColumn() async throws {
        let monitor = makeLayoutPlanTestMonitor(width: 1600, height: 900)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing active workspace for fullscreen hide-diff regression test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri engine for fullscreen hide-diff regression test")
            return
        }

        engine.maxVisibleColumns = 3
        engine.centerFocusedColumn = .never

        for windowId in 511 ... 515 {
            _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId)
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gap = CGFloat(controller.workspaceManager.gaps)
        let fixedWidth = (workingFrame.width - gap * CGFloat(engine.maxVisibleColumns - 1)) / CGFloat(engine.maxVisibleColumns)
        for column in engine.columns(in: workspaceId) {
            column.width = .fixed(fixedWidth)
            column.cachedWidth = fixedWidth
        }

        let columns = engine.columns(in: workspaceId)
        guard columns.indices.contains(engine.maxVisibleColumns - 1),
              let targetWindow = columns[engine.maxVisibleColumns - 1].windowNodes.first
        else {
            Issue.record("Expected a right visible-column target for fullscreen hide-diff regression test")
            return
        }

        var state = makeViewportStateForVisibleColumn(
            targetWindow: targetWindow,
            engine: engine,
            workspaceId: workspaceId,
            workingFrame: workingFrame,
            gap: gap
        )
        _ = controller.workspaceManager.setManagedFocus(targetWindow.token, in: workspaceId, onMonitor: monitor.id)
        engine.toggleFullscreen(targetWindow, state: &state)
        controller.workspaceManager.updateNiriViewportState(state, for: workspaceId)

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let plan = plans.first else {
            Issue.record("Expected a fullscreen Niri layout plan for hide-diff regression test")
            return
        }

        let expectedFullscreenFrame = workingFrame.roundedToPhysicalPixels(
            scale: controller.layoutRefreshController.backingScale(for: monitor)
        )
        #expect(!hasHideVisibilityChange(plan.diff.visibilityChanges, token: targetWindow.token))

        guard let frameChange = plan.diff.frameChanges.first(where: { $0.token == targetWindow.token }) else {
            Issue.record("Expected a frame change for the fullscreen token in hide-diff regression test")
            return
        }

        #expect(frameChange.forceApply)
        #expect(frameChange.frame == expectedFullscreenFrame)
    }

    @Test @MainActor func offscreenLeftPlaceholderFramesUseWorkingFrameOriginOnMonitorWithoutLeftNeighbor() async throws {
        let primaryMonitor = makeLayoutPlanTestMonitor(displayId: 1, name: "Primary", x: 0, width: 1600, height: 900)
        let secondaryMonitor = makeLayoutPlanTestMonitor(displayId: 2, name: "Secondary", x: 1600, width: 1600, height: 900)
        let controller = makeLayoutPlanTestController(monitors: [primaryMonitor, secondaryMonitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: primaryMonitor.id)?.id
        else {
            Issue.record("Missing active workspace for offscreen-left placeholder test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        var tokens: [WindowToken] = []
        for windowId in 701 ... 704 {
            tokens.append(addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId))
        }

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri engine for offscreen-left placeholder test")
            return
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .static(2500)
        }

        let gaps = LayoutGaps(
            horizontal: CGFloat(controller.workspaceManager.gaps),
            vertical: CGFloat(controller.workspaceManager.gaps),
            outer: controller.workspaceManager.outerGaps
        )
        let workingFrame = controller.insetWorkingFrame(for: primaryMonitor)
        let area = WorkingAreaContext(
            workingFrame: workingFrame,
            viewFrame: primaryMonitor.frame,
            scale: controller.layoutRefreshController.backingScale(for: primaryMonitor)
        )
        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let (frames, hiddenHandles) = engine.calculateCombinedLayoutUsingPools(
            in: workspaceId,
            monitor: primaryMonitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: nil
        )

        let hiddenLeftTokens = tokens.filter { hiddenHandles[$0] == .left }
        #expect(!hiddenLeftTokens.isEmpty)
        for token in hiddenLeftTokens {
            #expect(frames[token]?.origin.y == workingFrame.minY)
        }
    }

    @Test func hiddenLeftRevealPreservesBottomTileHeightOnFirstVisibleFrame() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 1)
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)

        let bottomHandle = makeTestHandle(pid: 41)
        let topHandle = makeTestHandle(pid: 42)
        let visibleHandle = makeTestHandle(pid: 43)

        let bottomWindow = NiriWindow(handle: bottomHandle)
        let topWindow = NiriWindow(handle: topHandle)
        let visibleWindow = NiriWindow(handle: visibleHandle)

        bottomWindow.height = .fixed(280)
        topWindow.height = .auto(weight: 1.0)

        leftColumn.appendChild(bottomWindow)
        leftColumn.appendChild(topWindow)
        rightColumn.appendChild(visibleWindow)

        engine.tokenToNode[bottomHandle.id] = bottomWindow
        engine.tokenToNode[topHandle.id] = topWindow
        engine.tokenToNode[visibleHandle.id] = visibleWindow

        let monitor = makeLayoutPlanTestMonitor(width: 960, height: 900)
        let gaps = LayoutGaps(horizontal: 8, vertical: 8)
        let area = WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )

        var hiddenState = ViewportState()
        hiddenState.activeColumnIndex = 1
        hiddenState.viewOffsetPixels = .static(0)

        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: hiddenState,
            workingArea: area,
            animationTime: nil
        )

        #expect(hiddenLayout.hiddenHandles[bottomHandle.id] == .left)
        guard let canonicalBottomFrame = bottomWindow.frame,
              let canonicalBottomHeight = bottomWindow.resolvedHeight
        else {
            Issue.record("Expected canonical bottom window geometry after hidden layout")
            return
        }

        var revealState = hiddenState
        revealState.viewOffsetPixels = .static(-20)

        let revealLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: revealState,
            workingArea: area,
            animationTime: nil
        )

        #expect(revealLayout.hiddenHandles[bottomHandle.id] == nil)
        #expect(bottomWindow.frame == canonicalBottomFrame)
        #expect(bottomWindow.resolvedHeight == canonicalBottomHeight)
        #expect(revealLayout.frames[bottomHandle.id]?.minY == canonicalBottomFrame.minY)
        #expect(revealLayout.frames[bottomHandle.id]?.height == canonicalBottomHeight)
    }

    @Test func fullscreenWindowsStayMonitorAnchoredAcrossVisibleColumns() {
        for visibleCount in 2 ... 5 {
            let fixture = makeVisibleColumnFixture(visibleCount: visibleCount)
            let expectedFullscreenFrame = fixture.monitor.visibleFrame.roundedToPhysicalPixels(scale: fixture.area.scale)

            var targetIndices = [visibleCount - 1]
            if visibleCount > 2 {
                targetIndices.append(1)
            }

            for targetIndex in targetIndices {
                let targetWindow = fixture.windows[targetIndex]
                var state = makeViewportStateForVisibleColumn(
                    targetWindow: targetWindow,
                    engine: fixture.engine,
                    workspaceId: fixture.workspaceId,
                    workingFrame: fixture.monitor.visibleFrame,
                    gap: fixture.gap
                )

                let tiledLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                    in: fixture.workspaceId,
                    monitor: fixture.monitor,
                    gaps: fixture.gaps,
                    state: state,
                    workingArea: fixture.area,
                    animationTime: nil
                )

                guard let tiledFrame = tiledLayout.frames[targetWindow.token] else {
                    Issue.record("Expected tiled frame for visibleCount=\(visibleCount) targetIndex=\(targetIndex)")
                    continue
                }

                #expect(tiledLayout.hiddenHandles[targetWindow.token] == nil)

                fixture.engine.toggleFullscreen(targetWindow, state: &state)
                let fullscreenLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                    in: fixture.workspaceId,
                    monitor: fixture.monitor,
                    gaps: fixture.gaps,
                    state: state,
                    workingArea: fixture.area,
                    animationTime: nil
                )

                #expect(fullscreenLayout.hiddenHandles[targetWindow.token] == nil)
                #expect(fullscreenLayout.frames[targetWindow.token] == expectedFullscreenFrame)
                #expect(targetWindow.renderedFrame == expectedFullscreenFrame)

                fixture.engine.toggleFullscreen(targetWindow, state: &state)
                let restoredLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                    in: fixture.workspaceId,
                    monitor: fixture.monitor,
                    gaps: fixture.gaps,
                    state: state,
                    workingArea: fixture.area,
                    animationTime: nil
                )

                #expect(restoredLayout.frames[targetWindow.token] == tiledFrame)
            }
        }
    }

    @Test func fullscreenBottomTileUsesFullMonitorHeightWithoutCarryoverOffset() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 1)
        engine.animationClock = AnimationClock()
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let column = NiriContainer()
        root.appendChild(column)

        let topHandle = makeTestHandle(pid: 71)
        let bottomHandle = makeTestHandle(pid: 72)
        let topWindow = NiriWindow(handle: topHandle)
        let bottomWindow = NiriWindow(handle: bottomHandle)

        topWindow.height = .auto(weight: 1.0)
        bottomWindow.height = .fixed(280)

        column.appendChild(topWindow)
        column.appendChild(bottomWindow)
        engine.tokenToNode[topHandle.id] = topWindow
        engine.tokenToNode[bottomHandle.id] = bottomWindow

        let monitor = makeLayoutPlanTestMonitor(width: 1200, height: 900)
        let gaps = LayoutGaps(horizontal: 8, vertical: 8)
        let area = WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )

        var state = ViewportState()
        state.selectedNodeId = bottomWindow.id
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        let tiledLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: nil
        )

        guard let tiledFrame = tiledLayout.frames[bottomHandle.id],
              let tiledHeight = bottomWindow.resolvedHeight
        else {
            Issue.record("Expected tiled frame for bottom-tile fullscreen regression test")
            return
        }

        bottomWindow.animateMoveFrom(
            displacement: CGPoint(x: 0, y: -220),
            clock: engine.animationClock,
            config: engine.windowMovementAnimationConfig,
            displayRefreshRate: engine.displayRefreshRate
        )

        engine.toggleFullscreen(bottomWindow, state: &state)
        let fullscreenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: engine.animationClock?.now()
        )

        let expectedFullscreenFrame = monitor.visibleFrame.roundedToPhysicalPixels(scale: area.scale)
        #expect(fullscreenLayout.frames[bottomHandle.id] == expectedFullscreenFrame)
        #expect(bottomWindow.resolvedHeight == monitor.visibleFrame.height)
        #expect(bottomWindow.hasMoveAnimationsRunning == false)

        engine.toggleFullscreen(bottomWindow, state: &state)
        let restoredLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: nil
        )

        #expect(restoredLayout.frames[bottomHandle.id] == tiledFrame)
        #expect(bottomWindow.resolvedHeight == tiledHeight)
    }

    @Test func focusHitTestPrefersFullscreenWindowOverCoveredTile() {
        let fixture = makeVisibleColumnFixture(visibleCount: 2, extraColumns: 0)
        let coveredWindow = fixture.windows[0]
        let fullscreenWindow = fixture.windows[1]

        var state = makeViewportStateForVisibleColumn(
            targetWindow: fullscreenWindow,
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            workingFrame: fixture.monitor.visibleFrame,
            gap: fixture.gap
        )

        _ = fixture.engine.calculateCombinedLayoutUsingPools(
            in: fixture.workspaceId,
            monitor: fixture.monitor,
            gaps: fixture.gaps,
            state: state,
            workingArea: fixture.area,
            animationTime: nil
        )

        fixture.engine.toggleFullscreen(fullscreenWindow, state: &state)
        _ = fixture.engine.calculateCombinedLayoutUsingPools(
            in: fixture.workspaceId,
            monitor: fixture.monitor,
            gaps: fixture.gaps,
            state: state,
            workingArea: fixture.area,
            animationTime: nil
        )

        guard let coveredFrame = coveredWindow.frame,
              let fullscreenFrame = fullscreenWindow.frame
        else {
            Issue.record("Expected frames for fullscreen focus hit-test regression")
            return
        }

        let overlapPoint = CGPoint(x: coveredFrame.midX, y: coveredFrame.midY)
        #expect(coveredFrame.contains(overlapPoint))
        #expect(fullscreenFrame.contains(overlapPoint))
        #expect(
            fixture.engine.hitTestFocusableWindow(point: overlapPoint, in: fixture.workspaceId)?.token == fullscreenWindow.token
        )
    }

    @Test func toggleFullWidthKeepsRightVisibleColumnInViewport() {
        for visibleCount in 2 ... 5 {
            let fixture = makeVisibleColumnFixture(visibleCount: visibleCount)
            fixture.engine.animationClock = AnimationClock()
            let targetWindow = fixture.windows[visibleCount - 1]
            guard let targetColumn = fixture.engine.column(of: targetWindow) else {
                Issue.record("Expected a target column for full-width visibility test visibleCount=\(visibleCount)")
                continue
            }

            var state = makeViewportStateForVisibleColumn(
                targetWindow: targetWindow,
                engine: fixture.engine,
                workspaceId: fixture.workspaceId,
                workingFrame: fixture.monitor.visibleFrame,
                gap: fixture.gap
            )
            let originalTargetOffset = state.viewOffsetPixels.target()

            fixture.engine.toggleFullWidth(
                targetColumn,
                in: fixture.workspaceId,
                state: &state,
                workingFrame: fixture.monitor.visibleFrame,
                gaps: fixture.gap
            )

            let widenedTargetOffset = state.viewOffsetPixels.target()
            #expect(widenedTargetOffset != originalTargetOffset)

            guard let settleBaseTime = fixture.engine.animationClock?.now() else {
                Issue.record("Expected animation clock for full-width visibility test visibleCount=\(visibleCount)")
                continue
            }
            let settleTime = settleBaseTime + 2.0
            let settledState = settledLayoutState(from: state, column: targetColumn, settleTime: settleTime)
            let settledLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                in: fixture.workspaceId,
                monitor: fixture.monitor,
                gaps: fixture.gaps,
                state: settledState,
                workingArea: fixture.area,
                animationTime: settleTime
            )

            guard let fullscreenWidthFrame = settledLayout.frames[targetWindow.token] else {
                Issue.record("Expected settled frame for full-width visibility test visibleCount=\(visibleCount)")
                continue
            }

            #expect(settledLayout.hiddenHandles[targetWindow.token] == nil)
            #expect(abs(fullscreenWidthFrame.minX - fixture.monitor.visibleFrame.minX) < 1.0)
            #expect(abs(fullscreenWidthFrame.maxX - fixture.monitor.visibleFrame.maxX) < 1.0)
        }
    }

    @Test func toggleColumnWidthKeepsRightVisibleColumnInViewport() {
        for visibleCount in 2 ... 5 {
            let fixture = makeVisibleColumnFixture(visibleCount: visibleCount)
            fixture.engine.animationClock = AnimationClock()
            let targetWindow = fixture.windows[visibleCount - 1]
            guard let targetColumn = fixture.engine.column(of: targetWindow) else {
                Issue.record("Expected a target column for cycle-width visibility test visibleCount=\(visibleCount)")
                continue
            }

            fixture.engine.presetColumnWidths = [
                .fixed(targetColumn.cachedWidth),
                .fixed(targetColumn.cachedWidth * 1.5)
            ]

            var state = makeViewportStateForVisibleColumn(
                targetWindow: targetWindow,
                engine: fixture.engine,
                workspaceId: fixture.workspaceId,
                workingFrame: fixture.monitor.visibleFrame,
                gap: fixture.gap
            )
            let originalLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                in: fixture.workspaceId,
                monitor: fixture.monitor,
                gaps: fixture.gaps,
                state: state,
                workingArea: fixture.area,
                animationTime: nil
            )
            let originalTargetOffset = state.viewOffsetPixels.target()

            fixture.engine.toggleColumnWidth(
                targetColumn,
                forwards: true,
                in: fixture.workspaceId,
                state: &state,
                workingFrame: fixture.monitor.visibleFrame,
                gaps: fixture.gap
            )

            let widenedTargetOffset = state.viewOffsetPixels.target()
            #expect(widenedTargetOffset != originalTargetOffset)

            guard let settleBaseTime = fixture.engine.animationClock?.now() else {
                Issue.record("Expected animation clock for cycle-width visibility test visibleCount=\(visibleCount)")
                continue
            }
            let settleTime = settleBaseTime + 2.0
            let settledState = settledLayoutState(from: state, column: targetColumn, settleTime: settleTime)
            let settledLayout = fixture.engine.calculateCombinedLayoutUsingPools(
                in: fixture.workspaceId,
                monitor: fixture.monitor,
                gaps: fixture.gaps,
                state: settledState,
                workingArea: fixture.area,
                animationTime: settleTime
            )

            guard let originalFrame = originalLayout.frames[targetWindow.token],
                  let widenedFrame = settledLayout.frames[targetWindow.token]
            else {
                Issue.record("Expected original and widened frames for cycle-width visibility test visibleCount=\(visibleCount)")
                continue
            }

            #expect(settledLayout.hiddenHandles[targetWindow.token] == nil)
            #expect(widenedFrame.width > originalFrame.width)
            #expect(widenedFrame.maxX <= fixture.monitor.visibleFrame.maxX + 1.0)
        }
    }

    @Test func splitAndExpelColumnCreationUseExplicitDefaultWidth() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.presetColumnWidths = [.proportion(0.85), .proportion(1.0), .proportion(0.5)]
        engine.defaultColumnWidth = 0.7
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let sourceColumn = NiriContainer()
        root.appendChild(sourceColumn)

        let movedWindow = NiriWindow(token: makeTestHandle(pid: 31).id)
        let expelledWindow = NiriWindow(token: makeTestHandle(pid: 32).id)
        let stationaryWindow = NiriWindow(token: makeTestHandle(pid: 33).id)
        sourceColumn.appendChild(movedWindow)
        sourceColumn.appendChild(expelledWindow)
        sourceColumn.appendChild(stationaryWindow)
        engine.tokenToNode[movedWindow.token] = movedWindow
        engine.tokenToNode[expelledWindow.token] = expelledWindow
        engine.tokenToNode[stationaryWindow.token] = stationaryWindow

        var state = ViewportState()
        engine.createColumnAndMove(
            movedWindow,
            from: sourceColumn,
            direction: .right,
            in: wsId,
            state: &state,
            gaps: 8,
            workingAreaWidth: 1600
        )

        let columnsAfterSplit = engine.columns(in: wsId)
        guard columnsAfterSplit.count == 2 else {
            Issue.record("Expected split operation to create a second column")
            return
        }

        let splitColumn = columnsAfterSplit[1]
        #expect(splitColumn.width == .proportion(0.7))
        #expect(splitColumn.presetWidthIdx == nil)

        var expelState = ViewportState()
        let expelled = engine.expelWindow(
            expelledWindow,
            to: .left,
            in: wsId,
            state: &expelState,
            workingFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            gaps: 8
        )

        let columnsAfterExpel = engine.columns(in: wsId)
        guard columnsAfterExpel.count == 3 else {
            Issue.record("Expected expel operation to create a third column")
            return
        }

        #expect(expelled)
        #expect(columnsAfterExpel[0].width == .proportion(0.7))
        #expect(columnsAfterExpel[0].presetWidthIdx == nil)
    }

    @Test func insertWindowInNewColumnUsesExplicitDefaultWidth() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.presetColumnWidths = [.proportion(0.85), .proportion(1.0), .proportion(0.5)]
        engine.defaultColumnWidth = 0.7
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let sourceColumn = NiriContainer()
        root.appendChild(sourceColumn)

        let stationaryWindow = NiriWindow(token: makeTestHandle(pid: 41).id)
        let movedWindow = NiriWindow(token: makeTestHandle(pid: 42).id)
        sourceColumn.appendChild(stationaryWindow)
        sourceColumn.appendChild(movedWindow)
        engine.tokenToNode[stationaryWindow.token] = stationaryWindow
        engine.tokenToNode[movedWindow.token] = movedWindow

        var state = ViewportState()
        let inserted = engine.insertWindowInNewColumn(
            movedWindow,
            insertIndex: 1,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            gaps: 8
        )

        let columns = engine.columns(in: wsId)
        guard columns.count == 2 else {
            Issue.record("Expected insert-window operation to create a second column")
            return
        }

        #expect(inserted)
        #expect(columns[1].width == .proportion(0.7))
        #expect(columns[1].presetWidthIdx == nil)
    }

    @Test func insertWindowInNewColumnPlacesWindowImmediatelyRightOfFocusedColumn() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        let wsId = UUID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let focusedColumn = NiriContainer()
        let trailingColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(focusedColumn)
        root.appendChild(trailingColumn)

        let targetWindow = NiriWindow(token: makeTestHandle(pid: 51).id)
        let focusedWindow = NiriWindow(token: makeTestHandle(pid: 52).id)
        let trailingWindow = NiriWindow(token: makeTestHandle(pid: 53).id)

        leftColumn.appendChild(targetWindow)
        focusedColumn.appendChild(focusedWindow)
        trailingColumn.appendChild(trailingWindow)

        engine.tokenToNode[targetWindow.token] = targetWindow
        engine.tokenToNode[focusedWindow.token] = focusedWindow
        engine.tokenToNode[trailingWindow.token] = trailingWindow

        var state = ViewportState()
        let inserted = engine.insertWindowInNewColumn(
            targetWindow,
            insertIndex: 2,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            gaps: 8
        )

        let orderedWindowIds = engine.columns(in: wsId).compactMap { $0.windowNodes.first?.token.windowId }

        #expect(inserted)
        #expect(orderedWindowIds == [focusedWindow.token.windowId, targetWindow.token.windowId, trailingWindow.token.windowId])
    }

    @Test func moveWindowToWorkspaceThenInsertColumnPreservesSourceFallbackSelection() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        let sourceWorkspaceId = UUID()
        let targetWorkspaceId = UUID()

        let targetWindow = engine.addWindow(handle: makeTestHandle(pid: 61), to: sourceWorkspaceId, afterSelection: nil)
        let fallbackWindow = engine.addWindow(
            handle: makeTestHandle(pid: 62),
            to: sourceWorkspaceId,
            afterSelection: targetWindow.id
        )
        let focusedWindow = engine.addWindow(handle: makeTestHandle(pid: 63), to: targetWorkspaceId, afterSelection: nil)

        var sourceState = ViewportState()
        sourceState.selectedNodeId = targetWindow.id
        var targetState = ViewportState()
        targetState.selectedNodeId = focusedWindow.id

        let moved = engine.moveWindowToWorkspace(
            targetWindow,
            from: sourceWorkspaceId,
            to: targetWorkspaceId,
            sourceState: &sourceState,
            targetState: &targetState
        )
        guard let movedWindow = engine.findNode(for: targetWindow.token) else {
            Issue.record("Expected moved window in target workspace")
            return
        }

        var targetInsertState = targetState
        let inserted = engine.insertWindowInNewColumn(
            movedWindow,
            insertIndex: 1,
            in: targetWorkspaceId,
            state: &targetInsertState,
            workingFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            gaps: 8
        )

        let orderedWindowIds = engine.columns(in: targetWorkspaceId).compactMap { $0.windowNodes.first?.token.windowId }

        #expect(moved?.newFocusNodeId == fallbackWindow.id)
        #expect(sourceState.selectedNodeId == fallbackWindow.id)
        #expect(inserted)
        #expect(orderedWindowIds == [focusedWindow.token.windowId, targetWindow.token.windowId])
    }

    @Test func toggleColumnWidthFollowsOrderedDuplicatePresetsFromExplicitDefaultMatch() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.presetColumnWidths = [
            .proportion(0.85),
            .proportion(1.0),
            .proportion(0.85),
            .proportion(0.5)
        ]
        engine.defaultColumnWidth = 0.85
        let wsId = UUID()

        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        guard let column = engine.column(of: window) else {
            Issue.record("Expected column for ordered preset cycle test")
            return
        }

        #expect(column.width == .proportion(0.85))
        #expect(column.presetWidthIdx == 0)

        var state = ViewportState()
        let workingFrame = CGRect(x: 0, y: 0, width: 1600, height: 900)

        engine.toggleColumnWidth(
            column,
            forwards: true,
            in: wsId,
            state: &state,
            workingFrame: workingFrame,
            gaps: 8
        )
        #expect(column.width == .proportion(1.0))
        #expect(column.presetWidthIdx == 1)

        engine.toggleColumnWidth(
            column,
            forwards: true,
            in: wsId,
            state: &state,
            workingFrame: workingFrame,
            gaps: 8
        )
        #expect(column.width == .proportion(0.85))
        #expect(column.presetWidthIdx == 2)

        engine.toggleColumnWidth(
            column,
            forwards: true,
            in: wsId,
            state: &state,
            workingFrame: workingFrame,
            gaps: 8
        )
        #expect(column.width == .proportion(0.5))
        #expect(column.presetWidthIdx == 3)
    }

    @Test func explicitDefaultOutsidePresetListReanchorsOnFirstResize() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        engine.presetColumnWidths = [
            .proportion(0.5),
            .proportion(0.85),
            .proportion(1.0)
        ]
        engine.defaultColumnWidth = 0.6
        let wsId = UUID()

        let window = engine.addWindow(handle: makeTestHandle(), to: wsId, afterSelection: nil)
        guard let column = engine.column(of: window) else {
            Issue.record("Expected column for custom default reanchor test")
            return
        }

        #expect(column.width == .proportion(0.6))
        #expect(column.presetWidthIdx == nil)

        var state = ViewportState()
        engine.toggleColumnWidth(
            column,
            forwards: true,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            gaps: 8
        )

        #expect(column.width == .proportion(0.85))
        #expect(column.presetWidthIdx == 1)
    }

    @Test func renderOffsetVisibilityUsesRenderedContainerFrame() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1, maxVisibleColumns: 1)
        engine.animationClock = AnimationClock()
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let visibleColumn = NiriContainer()
        let hiddenColumn = NiriContainer()
        root.appendChild(visibleColumn)
        root.appendChild(hiddenColumn)

        let visibleHandle = makeTestHandle(pid: 51)
        let revealedHandle = makeTestHandle(pid: 52)
        let visibleWindow = NiriWindow(handle: visibleHandle)
        let revealedWindow = NiriWindow(handle: revealedHandle)

        visibleColumn.appendChild(visibleWindow)
        hiddenColumn.appendChild(revealedWindow)

        engine.tokenToNode[visibleHandle.id] = visibleWindow
        engine.tokenToNode[revealedHandle.id] = revealedWindow

        let monitor = makeLayoutPlanTestMonitor(width: 1600, height: 900)
        let gaps = LayoutGaps(horizontal: 8, vertical: 8)
        let area = WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        guard let baseTime = engine.animationClock?.now() else {
            Issue.record("Expected animation clock for render-offset visibility test")
            return
        }
        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: baseTime
        )

        #expect(hiddenLayout.hiddenHandles[revealedHandle.id] == .right)

        hiddenColumn.animateMoveFrom(
            displacement: CGPoint(x: -40, y: 0),
            clock: engine.animationClock,
            config: engine.windowMovementAnimationConfig,
            displayRefreshRate: engine.displayRefreshRate
        )

        guard let animatedTime = engine.animationClock?.now() else {
            Issue.record("Expected animation clock after render-offset animation")
            return
        }
        let animatedLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: animatedTime
        )

        let sampledOffset = hiddenColumn.renderOffset(at: animatedTime).x
        #expect(sampledOffset < -8)
        #expect((hiddenColumn.frame?.minX ?? 0) + sampledOffset < monitor.visibleFrame.maxX)
        #expect(animatedLayout.hiddenHandles[revealedHandle.id] == nil)
        #expect(animatedLayout.frames[revealedHandle.id]?.minX ?? .greatestFiniteMagnitude < monitor.visibleFrame.maxX)
    }

    @Test @MainActor func visibilityChangesOnlyEmitOnActualTransitions() async throws {
        let monitor = makeLayoutPlanTestMonitor(width: 1600, height: 900)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing workspace for visibility-transition test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let firstToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 911)
        let transitioningToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 912)

        _ = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let engine = controller.niriEngine,
              let firstNode = engine.findNode(for: firstToken)
        else {
            Issue.record("Expected first node for visibility-transition test")
            return
        }

        let gap = CGFloat(controller.workspaceManager.gaps)
        let columnWidth = controller.insetWorkingFrame(for: monitor).width - gap
        for column in engine.columns(in: workspaceId) {
            column.width = .fixed(columnWidth)
            column.cachedWidth = columnWidth
        }

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = firstNode.id
            state.activeColumnIndex = 0
            state.viewOffsetPixels = .static(20)
        }

        let seededVisiblePlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard seededVisiblePlans.first != nil else {
            Issue.record("Expected visible seeding plan for visibility-transition test")
            return
        }
        controller.layoutRefreshController.executeLayoutPlans(seededVisiblePlans)

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .static(0)
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let initialPlan = initialPlans.first else {
            Issue.record("Expected hidden transition plan for visibility-transition test")
            return
        }

        #expect(hasHideVisibilityChange(initialPlan.diff.visibilityChanges, token: transitioningToken, side: .right))
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        let stableHiddenPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let stableHiddenPlan = stableHiddenPlans.first else {
            Issue.record("Expected repeated hidden-state plan for visibility-transition test")
            return
        }

        #expect(!hasAnyVisibilityChange(stableHiddenPlan.diff.visibilityChanges, token: transitioningToken))

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .static(20)
        }

        let revealPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let revealPlan = revealPlans.first else {
            Issue.record("Expected reveal plan for visibility-transition test")
            return
        }

        #expect(hasShowVisibilityChange(revealPlan.diff.visibilityChanges, token: transitioningToken))
        #expect(!hasHideVisibilityChange(revealPlan.diff.visibilityChanges, token: transitioningToken))
        controller.layoutRefreshController.executeLayoutPlans(revealPlans)

        let stableVisiblePlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let stableVisiblePlan = stableVisiblePlans.first else {
            Issue.record("Expected repeated visible-state plan for visibility-transition test")
            return
        }

        #expect(!hasAnyVisibilityChange(stableVisiblePlan.diff.visibilityChanges, token: transitioningToken))
    }

    @Test @MainActor func layoutHiddenPlacementMatchesLiveHideOriginForHiddenLeftColumn() async throws {
        let primaryMonitor = makeLayoutPlanTestMonitor(displayId: 1, name: "Primary", x: 0, width: 1600, height: 900)
        let secondaryMonitor = makeLayoutPlanTestMonitor(displayId: 2, name: "Secondary", x: 1600, width: 1600, height: 900)
        let controller = makeLayoutPlanTestController(monitors: [primaryMonitor, secondaryMonitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: primaryMonitor.id)?.id
        else {
            Issue.record("Missing workspace for hidden-placement parity test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        var tokens: [WindowToken] = []
        for windowId in 921 ... 924 {
            tokens.append(addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId))
        }

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri engine for hidden-placement parity test")
            return
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .static(2500)
        }

        let gaps = LayoutGaps(
            horizontal: CGFloat(controller.workspaceManager.gaps),
            vertical: CGFloat(controller.workspaceManager.gaps),
            outer: controller.workspaceManager.outerGaps
        )
        let workingFrame = controller.insetWorkingFrame(for: primaryMonitor)
        let area = WorkingAreaContext(
            workingFrame: workingFrame,
            viewFrame: primaryMonitor.frame,
            scale: controller.layoutRefreshController.backingScale(for: primaryMonitor)
        )
        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let (frames, hiddenHandles) = engine.calculateCombinedLayoutUsingPools(
            in: workspaceId,
            monitor: primaryMonitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: nil
        )

        guard let token = tokens.first(where: { hiddenHandles[$0] == .left }),
              let canonicalFrame = engine.findNode(for: token)?.frame,
              let hiddenFrame = frames[token],
              let liveOrigin = controller.layoutRefreshController.liveFrameHideOrigin(
                  for: canonicalFrame,
                  monitor: primaryMonitor,
                  side: .left,
                  pid: token.pid
              )
        else {
            Issue.record("Expected a hidden-left column and live hide origin for parity test")
            return
        }

        #expect(hiddenFrame.minX == liveOrigin.x)
        #expect(hiddenFrame.minY == liveOrigin.y)
    }

    @Test @MainActor func snapshotPlanUsesRemovalSeedForFallbackAndScrollParity() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for Niri removal-seed test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let removedToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 551)
        let survivingToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 552)
        _ = controller.workspaceManager.setManagedFocus(removedToken, in: workspaceId, onMonitor: monitor.id)

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        guard let engine = controller.niriEngine,
              let removedNodeId = engine.findNode(for: removedToken)?.id
        else {
            Issue.record("Expected Niri engine state for removal-seed test")
            return
        }

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = removedNodeId
        }
        let oldFrames = engine.captureWindowFrames(in: workspaceId)
        guard !oldFrames.isEmpty else {
            Issue.record("Expected non-empty Niri frame snapshot before removal")
            return
        }

        _ = controller.workspaceManager.removeWindow(pid: removedToken.pid, windowId: removedToken.windowId)

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId],
            useScrollAnimationPath: true,
            removalSeeds: [
                workspaceId: NiriWindowRemovalSeed(
                    removedNodeId: removedNodeId,
                    oldFrames: oldFrames
                )
            ]
        )
        guard let plan = plans.first else {
            Issue.record("Expected a Niri layout plan after removal")
            return
        }
        guard let survivingNodeId = engine.findNode(for: survivingToken)?.id else {
            Issue.record("Expected surviving node after Niri removal")
            return
        }

        #expect(!plan.diff.frameChanges.contains(where: { $0.token == removedToken }))
        #expect(
            plan.diff.frameChanges.contains(where: { $0.token == survivingToken }) ||
                hasAnyVisibilityChange(plan.diff.visibilityChanges, token: survivingToken)
        )
        #expect(plan.sessionPatch.rememberedFocusToken == survivingToken)
        #expect(plan.sessionPatch.viewportState?.selectedNodeId == survivingNodeId)
        #expect(hasNiriScrollDirective(plan.animationDirectives, workspaceId: workspaceId))
    }

    @Test @MainActor func nonFocusedWorkspacePlanDoesNotClearFocusedBorder() async throws {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        controller.setBordersEnabled(true)
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let primaryToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.primaryWorkspaceId,
            windowId: 601
        )
        _ = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.secondaryWorkspaceId,
            windowId: 602
        )
        _ = controller.workspaceManager.setManagedFocus(
            primaryToken,
            in: fixture.primaryWorkspaceId,
            onMonitor: fixture.primaryMonitor.id
        )

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [fixture.primaryWorkspaceId, fixture.secondaryWorkspaceId],
            useScrollAnimationPath: true
        )
        controller.layoutRefreshController.executeLayoutPlans(plans)

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 601)
    }

    @Test @MainActor func visibleSecondaryWorkspacePlanRestoresInactiveHiddenWindows() async throws {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let token = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.secondaryWorkspaceId,
            windowId: 650
        )
        setWorkspaceInactiveHiddenStateForLayoutPlanTests(
            on: controller,
            token: token,
            monitor: fixture.secondaryMonitor
        )

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [fixture.primaryWorkspaceId, fixture.secondaryWorkspaceId],
            useScrollAnimationPath: true
        )
        guard let secondaryPlan = plans.first(where: { $0.workspaceId == fixture.secondaryWorkspaceId }) else {
            Issue.record("Expected a plan for the visible secondary workspace")
            return
        }

        #expect(secondaryPlan.diff.restoreChanges.contains { $0.token == token })
    }

    @Test @MainActor func staleScrollAnimationStopsBeforeRestoringInactiveWorkspaceWindows() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let originalWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let replacementWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing monitor or workspaces for stale Niri animation test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: originalWorkspaceId, windowId: 603)
        _ = controller.workspaceManager.setManagedFocus(token, in: originalWorkspaceId, onMonitor: monitor.id)

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [originalWorkspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(plans)

        setWorkspaceInactiveHiddenStateForLayoutPlanTests(on: controller, token: token, monitor: monitor)
        controller.layoutRefreshController.stopAllScrollAnimations()
        #expect(controller.niriLayoutHandler.registerScrollAnimation(originalWorkspaceId, on: monitor.displayId))
        _ = controller.workspaceManager.setActiveWorkspace(replacementWorkspaceId, on: monitor.id)

        controller.niriLayoutHandler.tickScrollAnimation(targetTime: 1, displayId: monitor.displayId)

        #expect(controller.niriLayoutHandler.scrollAnimationByDisplay[monitor.displayId] == nil)
        #expect(controller.workspaceManager.hiddenState(for: token)?.workspaceInactive == true)
    }
}
