import Foundation
import QuartzCore
import Testing

@testable import OmniWM

@Suite struct NiriZigInteractionTests {
    @MainActor
    @Test func layoutPassV2PopulatesColumnFramesAndHiddenSides() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 8)
        let wsId = WorkspaceDescriptor.ID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        for i in 0 ..< 3 {
            let column = NiriContainer()
            column.cachedWidth = 620
            root.appendChild(column)

            let handle = makeTestHandle(pid: pid_t(6000 + i))
            let window = NiriWindow(handle: handle)
            engine.handleToNode[handle] = window
            column.appendChild(window)
        }

        var state = ViewportState()
        state.activeColumnIndex = 1
        state.viewOffsetPixels = .static(0)

        var frames: [WindowHandle: CGRect] = [:]
        var hidden: [WindowHandle: HideSide] = [:]

        let monitorFrame = CGRect(x: 0, y: 0, width: 500, height: 900)
        let area = WorkingAreaContext(
            workingFrame: monitorFrame,
            viewFrame: monitorFrame,
            scale: 2.0
        )

        engine.calculateLayoutInto(
            frames: &frames,
            hiddenHandles: &hidden,
            state: state,
            workspaceId: wsId,
            monitorFrame: monitorFrame,
            screenFrame: monitorFrame,
            gaps: (horizontal: 16, vertical: 12),
            scale: 2.0,
            workingArea: area,
            orientation: .horizontal,
            animationTime: CACurrentMediaTime()
        )

        let columns = engine.columns(in: wsId)
        #expect(columns.count == 3)
        #expect(columns.allSatisfy { $0.frame != nil })
        #expect(hidden.values.contains(.left))
        #expect(hidden.values.contains(.right))
    }

    @MainActor
    @Test func zigTiledHitTestReturnsMatchingWindow() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let wsId = WorkspaceDescriptor.ID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let column = NiriContainer()
        root.appendChild(column)

        let h1 = makeTestHandle(pid: 1001)
        let h2 = makeTestHandle(pid: 1002)
        let w1 = NiriWindow(handle: h1)
        let w2 = NiriWindow(handle: h2)
        w1.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        w2.frame = CGRect(x: 220, y: 0, width: 200, height: 200)
        column.appendChild(w1)
        column.appendChild(w2)
        engine.handleToNode[h1] = w1
        engine.handleToNode[h2] = w2

        let hit = engine.hitTestTiled(point: CGPoint(x: 350, y: 50), in: wsId)
        #expect(hit?.id == w2.id)

        let miss = engine.hitTestTiled(point: CGPoint(x: 999, y: 999), in: wsId)
        #expect(miss == nil)
    }

    @MainActor
    @Test func zigResizeHitTestDetectsEdgesAndSkipsFullscreen() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let wsId = WorkspaceDescriptor.ID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let column = NiriContainer()
        root.appendChild(column)

        let fullscreenHandle = makeTestHandle(pid: 1101)
        let fullscreenWindow = NiriWindow(handle: fullscreenHandle)
        fullscreenWindow.sizingMode = .fullscreen
        fullscreenWindow.frame = CGRect(x: 0, y: 0, width: 180, height: 180)
        column.appendChild(fullscreenWindow)
        engine.handleToNode[fullscreenHandle] = fullscreenWindow

        let normalHandle = makeTestHandle(pid: 1102)
        let normalWindow = NiriWindow(handle: normalHandle)
        normalWindow.frame = CGRect(x: 220, y: 20, width: 240, height: 220)
        column.appendChild(normalWindow)
        engine.handleToNode[normalHandle] = normalWindow

        let fullscreenEdgeHit = engine.hitTestResize(
            point: CGPoint(x: 1, y: 1),
            in: wsId,
            threshold: 8
        )
        #expect(fullscreenEdgeHit == nil)

        let normalEdgeHit = engine.hitTestResize(
            point: CGPoint(x: 460, y: 120),
            in: wsId,
            threshold: 8
        )
        #expect(normalEdgeHit != nil)
        #expect(normalEdgeHit?.nodeId == normalWindow.id)
        #expect(normalEdgeHit?.edges.contains(.right) == true)
    }

    @MainActor
    @Test func zigResizeComputeClampsWidthAndAdjustsViewportOffset() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let wsId = WorkspaceDescriptor.ID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let column = NiriContainer()
        column.cachedWidth = 400
        root.appendChild(column)

        let handle = makeTestHandle(pid: 1201)
        let window = NiriWindow(handle: handle)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        window.size = 1.0
        column.appendChild(window)
        engine.handleToNode[handle] = window

        let began = engine.interactiveResizeBegin(
            windowId: window.id,
            edges: [.left, .top],
            startLocation: .zero,
            in: wsId,
            viewOffset: 10
        )
        #expect(began)

        var viewport = ViewportState()
        let changed = engine.interactiveResizeUpdate(
            currentLocation: CGPoint(x: -1000, y: 300),
            monitorFrame: CGRect(x: 0, y: 0, width: 800, height: 1000),
            gaps: LayoutGaps(horizontal: 16, vertical: 16),
            viewportState: { mutate in
                mutate(&viewport)
            }
        )
        #expect(changed)
        #expect(abs(column.cachedWidth - 784) < 0.01)
        #expect(abs(viewport.viewOffsetPixels.current() - 394) < 0.01)
        #expect(window.size > 1.2)
    }
}
