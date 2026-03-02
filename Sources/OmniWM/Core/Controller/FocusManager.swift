import Foundation

@MainActor
final class FocusManager {
    private(set) var focusedHandle: WindowHandle?
    private(set) var lastFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowHandle] = [:]
    private(set) var isNonManagedFocusActive: Bool = false
    private(set) var isAppFullscreenActive: Bool = false

    private var pendingFocusHandle: WindowHandle?
    private var deferredFocusHandle: WindowHandle?
    private var isFocusOperationPending = false
    private var lastFocusTime: Date = .distantPast

    var onFocusedHandleChanged: ((WindowHandle?) -> Void)?

    func setNonManagedFocus(active: Bool) {
        isNonManagedFocusActive = active
    }

    func setAppFullscreen(active: Bool) {
        isAppFullscreenActive = active
    }

    func setFocus(_ handle: WindowHandle, in workspaceId: WorkspaceDescriptor.ID) {
        focusedHandle = handle
        lastFocusedByWorkspace[workspaceId] = handle
        onFocusedHandleChanged?(handle)
    }

    func clearFocus() {
        focusedHandle = nil
        onFocusedHandleChanged?(nil)
    }

    func updateWorkspaceFocusMemory(_ handle: WindowHandle, for workspaceId: WorkspaceDescriptor.ID) {
        lastFocusedByWorkspace[workspaceId] = handle
    }

    func clearWorkspaceFocusMemory(for workspaceId: WorkspaceDescriptor.ID) {
        lastFocusedByWorkspace[workspaceId] = nil
    }

    func resolveWorkspaceFocus(
        for workspaceId: WorkspaceDescriptor.ID,
        entries: [WindowModel.Entry]
    ) -> WindowHandle? {
        lastFocusedByWorkspace[workspaceId] ?? entries.first?.handle
    }

    @discardableResult
    func resolveAndSetWorkspaceFocus(
        for workspaceId: WorkspaceDescriptor.ID,
        entries: [WindowModel.Entry]
    ) -> WindowHandle? {
        if let handle = resolveWorkspaceFocus(for: workspaceId, entries: entries) {
            setFocus(handle, in: workspaceId)
            return handle
        } else {
            clearFocus()
            return nil
        }
    }

    func recoverSourceFocusAfterMove(
        in workspaceId: WorkspaceDescriptor.ID,
        preferredNodeId: NodeId?,
        engine: NiriLayoutEngine?,
        entries: [WindowModel.Entry]
    ) {
        if let engine,
           let preferredId = preferredNodeId,
           let node = engine.findNode(by: preferredId) as? NiriWindow
        {
            setFocus(node.handle, in: workspaceId)
        } else if let fallback = entries.first?.handle {
            setFocus(fallback, in: workspaceId)
        } else {
            clearFocus()
        }
    }

    func handleWindowRemoved(_ handle: WindowHandle, in workspaceId: WorkspaceDescriptor.ID?) {
        if pendingFocusHandle?.id == handle.id {
            pendingFocusHandle = nil
        }
        if deferredFocusHandle?.id == handle.id {
            deferredFocusHandle = nil
        }
        if focusedHandle?.id == handle.id {
            clearFocus()
        }
        if let wsId = workspaceId,
           lastFocusedByWorkspace[wsId]?.id == handle.id
        {
            lastFocusedByWorkspace[wsId] = nil
        }
    }

    func focusWindow(
        _ handle: WindowHandle,
        workspaceId: WorkspaceDescriptor.ID,
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
        lastFocusedByWorkspace[workspaceId] = handle

        performFocus()

        isFocusOperationPending = false
        if let deferred = deferredFocusHandle, deferred != handle {
            deferredFocusHandle = nil
            onDeferredFocus(deferred)
        }
    }

    func ensureFocusedHandleValid(
        in workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine?,
        workspaceManager: WorkspaceManager,
        focusWindowAction: (WindowHandle) -> Void
    ) {
        if let focused = focusedHandle,
           workspaceManager.entry(for: focused)?.workspaceId == workspaceId
        {
            lastFocusedByWorkspace[workspaceId] = focused
            if let engine,
               let node = engine.findNode(for: focused)
            {
                workspaceManager.setSelection(node.id, for: workspaceId)
            }
            return
        }

        if let remembered = lastFocusedByWorkspace[workspaceId],
           workspaceManager.entry(for: remembered) != nil
        {
            setFocus(remembered, in: workspaceId)
            if let engine,
               let node = engine.findNode(for: remembered)
            {
                workspaceManager.setSelection(node.id, for: workspaceId)
            }
            focusWindowAction(remembered)
            return
        }

        let newHandle = workspaceManager.entries(in: workspaceId).first?.handle
        if let newHandle {
            setFocus(newHandle, in: workspaceId)
            if let engine,
               let node = engine.findNode(for: newHandle)
            {
                workspaceManager.setSelection(node.id, for: workspaceId)
            }
            focusWindowAction(newHandle)
        } else {
            clearFocus()
        }
    }
}
