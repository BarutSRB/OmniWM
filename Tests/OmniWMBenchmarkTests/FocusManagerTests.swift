import ApplicationServices
import XCTest

@testable import OmniWM

@MainActor
final class FocusManagerTests: XCTestCase {
    func testPreviousFocusedHandleReturnsMRUEntryBeforeCurrent() {
        let workspaceId = WorkspaceDescriptor(name: "focus-mru-primary").id
        let manager = FocusManager()
        let first = makeWindowHandle()
        let second = makeWindowHandle()

        manager.setFocus(first, in: workspaceId)
        manager.setFocus(second, in: workspaceId)

        let previous = manager.previousFocusedHandle(
            in: workspaceId,
            excluding: second
        )

        XCTAssertEqual(previous?.id, first.id)
    }

    func testPreviousFocusedHandleSkipsAndPrunesInvalidEntries() {
        let workspaceId = WorkspaceDescriptor(name: "focus-mru-invalid").id
        let manager = FocusManager()
        let first = makeWindowHandle()
        let stale = makeWindowHandle()
        let current = makeWindowHandle()

        manager.setFocus(first, in: workspaceId)
        manager.setFocus(stale, in: workspaceId)
        manager.setFocus(current, in: workspaceId)

        let previous = manager.previousFocusedHandle(
            in: workspaceId,
            excluding: current,
            isValid: { $0.id != stale.id }
        )
        XCTAssertEqual(previous?.id, first.id)

        let afterPrune = manager.previousFocusedHandle(
            in: workspaceId,
            excluding: current
        )
        XCTAssertEqual(afterPrune?.id, first.id)
    }

    func testPreviousFocusedHandleReturnsNilWhenNoPriorFocusExists() {
        let workspaceId = WorkspaceDescriptor(name: "focus-mru-empty").id
        let manager = FocusManager()
        let current = makeWindowHandle()

        manager.setFocus(current, in: workspaceId)

        let previous = manager.previousFocusedHandle(
            in: workspaceId,
            excluding: current
        )

        XCTAssertNil(previous)
    }

    func testHandleWindowRemovedPrunesPreviousFocusHistory() {
        let workspaceId = WorkspaceDescriptor(name: "focus-mru-remove").id
        let manager = FocusManager()
        let first = makeWindowHandle()
        let second = makeWindowHandle()

        manager.setFocus(first, in: workspaceId)
        manager.setFocus(second, in: workspaceId)
        manager.handleWindowRemoved(first, in: workspaceId)

        let previous = manager.previousFocusedHandle(
            in: workspaceId,
            excluding: second
        )
        XCTAssertNil(previous)
    }

    private func makeWindowHandle() -> WindowHandle {
        let pid = getpid()
        return WindowHandle(
            id: UUID(),
            pid: pid,
            axElement: AXUIElementCreateApplication(pid)
        )
    }
}
