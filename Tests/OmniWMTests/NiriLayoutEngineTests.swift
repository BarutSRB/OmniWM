import ApplicationServices
import Foundation
import Testing

@testable import OmniWM

func makeTestHandle(pid: pid_t = 1) -> WindowHandle {
    WindowHandle(
        id: UUID(),
        pid: pid,
        axElement: AXUIElementCreateSystemWide()
    )
}

@Suite struct NiriLayoutEngineTests {

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

    @Test func selectionFallbackAfterColumnRemoval() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        engine.animationsEnabled = false
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

    @Test func ensureSelectionVisibleMovesViewport() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        engine.animationsEnabled = false
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
            gaps: gap,
            alwaysCenterSingleColumn: false
        )

        #expect(state.activeColumnIndex == 2)
    }
}
