import Foundation

@MainActor
final class FocusOperationCoordinator {
    // Transient sequencing only. Durable focus/session ownership lives in WorkspaceManager.
    private var pendingFocusHandle: WindowHandle?
    private var deferredFocusHandle: WindowHandle?
    private var isFocusOperationPending = false
    private var lastFocusTime: Date = .distantPast

    func discardPendingFocus(_ handle: WindowHandle) {
        if pendingFocusHandle?.id == handle.id {
            pendingFocusHandle = nil
        }
        if deferredFocusHandle?.id == handle.id {
            deferredFocusHandle = nil
        }
    }

    func focusWindow(
        _ handle: WindowHandle,
        performFocus: () -> Void,
        onDeferredFocus: @escaping (WindowHandle) -> Void
    ) {
        let now = Date()

        if pendingFocusHandle == handle {
            if now.timeIntervalSince(lastFocusTime) < 0.016 {
                return
            }
        }

        if isFocusOperationPending {
            deferredFocusHandle = handle
            return
        }

        isFocusOperationPending = true
        pendingFocusHandle = handle
        lastFocusTime = now

        performFocus()

        isFocusOperationPending = false
        if let deferred = deferredFocusHandle, deferred != handle {
            deferredFocusHandle = nil
            onDeferredFocus(deferred)
        }
    }
}
