import ApplicationServices
import XCTest

@testable import OmniWM

@MainActor
final class NiriLayoutHandlerSelectionTests: XCTestCase {
    func testResolveActionableWindowIdPrefersFocusedWindowInSelectedColumn() {
        let columnId = NodeId()
        let firstWindowId = NodeId()
        let secondWindowId = NodeId()

        let view = makeWorkspaceView(
            selectedNodeId: columnId,
            focusedWindowId: secondWindowId,
            columnId: columnId,
            windowIds: [firstWindowId, secondWindowId],
            activeIndex: 0
        )

        let resolved = NiriLayoutHandler.resolveActionableWindowId(
            for: columnId,
            in: view
        )

        XCTAssertEqual(resolved, secondWindowId)
    }

    func testResolveActionableWindowIdFallsBackToColumnActiveIndex() {
        let columnId = NodeId()
        let firstWindowId = NodeId()
        let secondWindowId = NodeId()

        let view = makeWorkspaceView(
            selectedNodeId: columnId,
            focusedWindowId: nil,
            columnId: columnId,
            windowIds: [firstWindowId, secondWindowId],
            activeIndex: 1
        )

        let resolved = NiriLayoutHandler.resolveActionableWindowId(
            for: columnId,
            in: view
        )

        XCTAssertEqual(resolved, secondWindowId)
    }

    func testResolveActionableWindowIdFallsBackToFirstWindow() {
        let columnId = NodeId()
        let firstWindowId = NodeId()
        let secondWindowId = NodeId()

        let view = makeWorkspaceView(
            selectedNodeId: columnId,
            focusedWindowId: nil,
            columnId: columnId,
            windowIds: [firstWindowId, secondWindowId],
            activeIndex: nil
        )

        let resolved = NiriLayoutHandler.resolveActionableWindowId(
            for: columnId,
            in: view
        )

        XCTAssertEqual(resolved, firstWindowId)
    }

    private func makeWorkspaceView(
        selectedNodeId: NodeId?,
        focusedWindowId: NodeId?,
        columnId: NodeId,
        windowIds: [NodeId],
        activeIndex: Int?
    ) -> ZigNiriWorkspaceView {
        let pid = getpid()

        var windowsById: [NodeId: ZigNiriWindowView] = [:]
        for windowId in windowIds {
            let handle = WindowHandle(
                id: windowId.uuid,
                pid: pid,
                axElement: AXUIElementCreateApplication(pid)
            )
            windowsById[windowId] = ZigNiriWindowView(
                nodeId: windowId,
                handle: handle,
                columnId: columnId,
                frame: nil,
                sizingMode: .normal,
                height: .default,
                isFocused: false
            )
        }

        return ZigNiriWorkspaceView(
            workspaceId: WorkspaceDescriptor(name: "niri-layout-handler-selection").id,
            columns: [
                ZigNiriColumnView(
                    nodeId: columnId,
                    windowIds: windowIds,
                    display: .normal,
                    activeWindowIndex: activeIndex
                ),
            ],
            windowsById: windowsById,
            selection: ZigNiriSelection(
                selectedNodeId: selectedNodeId,
                focusedWindowId: focusedWindowId
            )
        )
    }
}
