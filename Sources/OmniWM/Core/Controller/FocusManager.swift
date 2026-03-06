import Foundation

@MainActor
final class FocusManager {
    private(set) var focusedHandle: WindowHandle?
    private(set) var lastFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowHandle] = [:]
    private(set) var isNonManagedFocusActive: Bool = false
    private(set) var isAppFullscreenActive: Bool = false

    private var focusHistoryByWorkspace: [WorkspaceDescriptor.ID: [WindowHandle]] = [:]
    private let maxHistoryPerWorkspace = 32

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
        recordFocus(handle, in: workspaceId)
        onFocusedHandleChanged?(handle)
    }

    func clearFocus() {
        focusedHandle = nil
        onFocusedHandleChanged?(nil)
    }

    func updateWorkspaceFocusMemory(_ handle: WindowHandle, for workspaceId: WorkspaceDescriptor.ID) {
        lastFocusedByWorkspace[workspaceId] = handle
        recordFocus(handle, in: workspaceId)
    }

    func previousFocusedHandle(
        in workspaceId: WorkspaceDescriptor.ID,
        excluding excludedHandle: WindowHandle? = nil,
        isValid: ((WindowHandle) -> Bool)? = nil
    ) -> WindowHandle? {
        guard var history = focusHistoryByWorkspace[workspaceId], !history.isEmpty else {
            return nil
        }

        if let isValid {
            history.removeAll { !isValid($0) }
            focusHistoryByWorkspace[workspaceId] = history
        }

        return history.first { candidate in
            guard let excludedHandle else { return true }
            return candidate.id != excludedHandle.id
        }
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
        zigEngine: ZigNiriEngine?,
        entries: [WindowModel.Entry]
    ) {
        if let preferredId = preferredNodeId,
           let handle = zigEngine?.windowHandle(for: preferredId)
        {
            setFocus(handle, in: workspaceId)
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

        for workspaceId in Array(focusHistoryByWorkspace.keys) {
            focusHistoryByWorkspace[workspaceId]?.removeAll { $0.id == handle.id }
            if focusHistoryByWorkspace[workspaceId]?.isEmpty == true {
                focusHistoryByWorkspace[workspaceId] = nil
            }
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
        recordFocus(handle, in: workspaceId)

        performFocus()

        isFocusOperationPending = false
        if let deferred = deferredFocusHandle, deferred != handle {
            deferredFocusHandle = nil
            onDeferredFocus(deferred)
        }
    }

    func ensureFocusedHandleValid(
        in workspaceId: WorkspaceDescriptor.ID,
        zigEngine: ZigNiriEngine?,
        workspaceManager: WorkspaceManager,
        focusWindowAction: (WindowHandle) -> Void
    ) {
        if let focused = focusedHandle,
           workspaceManager.entry(for: focused)?.workspaceId == workspaceId
        {
            lastFocusedByWorkspace[workspaceId] = focused
            let nodeId = zigEngine?.nodeId(for: focused)
            if let nodeId {
                workspaceManager.setSelection(nodeId, for: workspaceId)
            }
            return
        }

        if let remembered = lastFocusedByWorkspace[workspaceId],
           workspaceManager.entry(for: remembered) != nil
        {
            setFocus(remembered, in: workspaceId)
            let nodeId = zigEngine?.nodeId(for: remembered)
            if let nodeId {
                workspaceManager.setSelection(nodeId, for: workspaceId)
            }
            focusWindowAction(remembered)
            return
        }

        let newHandle = workspaceManager.entries(in: workspaceId).first?.handle
        if let newHandle {
            setFocus(newHandle, in: workspaceId)
            let nodeId = zigEngine?.nodeId(for: newHandle)
            if let nodeId {
                workspaceManager.setSelection(nodeId, for: workspaceId)
            }
            focusWindowAction(newHandle)
        } else {
            clearFocus()
        }
    }

    private func recordFocus(_ handle: WindowHandle, in workspaceId: WorkspaceDescriptor.ID) {
        var history = focusHistoryByWorkspace[workspaceId] ?? []
        history.removeAll { $0.id == handle.id }
        history.insert(handle, at: 0)
        if history.count > maxHistoryPerWorkspace {
            history.removeLast(history.count - maxHistoryPerWorkspace)
        }
        focusHistoryByWorkspace[workspaceId] = history
    }
}
