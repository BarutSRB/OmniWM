// SPDX-License-Identifier: GPL-2.0-only
import Foundation

@testable import OmniWM

extension WorkspaceManager {
    @discardableResult
    func setManagedFocus(
        _ handle: WindowHandle,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil
    ) -> Bool {
        setManagedFocus(handle.id, in: workspaceId, onMonitor: monitorId)
    }

    @discardableResult
    func beginManagedFocusRequest(
        _ handle: WindowHandle,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil
    ) -> Bool {
        beginManagedFocusRequest(handle.id, in: workspaceId, onMonitor: monitorId)
    }

    @discardableResult
    func confirmManagedFocus(
        _ handle: WindowHandle,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil,
        appFullscreen: Bool,
        activateWorkspaceOnMonitor: Bool
    ) -> Bool {
        confirmManagedFocus(
            handle.id,
            in: workspaceId,
            onMonitor: monitorId,
            appFullscreen: appFullscreen,
            activateWorkspaceOnMonitor: activateWorkspaceOnMonitor
        )
    }

    @discardableResult
    func rememberFocus(_ handle: WindowHandle, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        rememberFocus(handle.id, in: workspaceId)
    }

    @discardableResult
    func syncWorkspaceFocus(
        _ handle: WindowHandle,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil
    ) -> Bool {
        syncWorkspaceFocus(handle.id, in: workspaceId, onMonitor: monitorId)
    }

    func lastFocusedHandle(in workspaceId: WorkspaceDescriptor.ID) -> WindowHandle? {
        lastFocusedToken(in: workspaceId).flatMap(handle(for:))
    }

    func preferredFocusHandle(in workspaceId: WorkspaceDescriptor.ID) -> WindowHandle? {
        preferredFocusToken(in: workspaceId).flatMap(handle(for:))
    }

    func resolveWorkspaceFocus(in workspaceId: WorkspaceDescriptor.ID) -> WindowHandle? {
        resolveWorkspaceFocusToken(in: workspaceId).flatMap(handle(for:))
    }

    @discardableResult
    func resolveAndSetWorkspaceFocus(
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil
    ) -> WindowHandle? {
        resolveAndSetWorkspaceFocusToken(in: workspaceId, onMonitor: monitorId).flatMap(handle(for:))
    }

    func setWorkspace(for handle: WindowHandle, to workspace: WorkspaceDescriptor.ID) {
        setWorkspace(for: handle.id, to: workspace)
    }

    func isHiddenInCorner(_ handle: WindowHandle) -> Bool {
        isHiddenInCorner(handle.id)
    }

    func setHiddenState(_ state: WindowModel.HiddenState?, for handle: WindowHandle) {
        setHiddenState(state, for: handle.id)
    }

    func hiddenState(for handle: WindowHandle) -> WindowModel.HiddenState? {
        hiddenState(for: handle.id)
    }

    func layoutReason(for handle: WindowHandle) -> LayoutReason {
        layoutReason(for: handle.id)
    }

    func setLayoutReason(_ reason: LayoutReason, for handle: WindowHandle) {
        setLayoutReason(reason, for: handle.id)
    }

    func restoreFromNativeState(for handle: WindowHandle) -> ParentKind? {
        restoreFromNativeState(for: handle.id)
    }
}

extension NiriLayoutEngine {
    @discardableResult
    func addWindow(
        handle: WindowHandle,
        to workspaceId: WorkspaceDescriptor.ID,
        afterSelection selectedNodeId: NodeId?,
        focusedHandle: WindowHandle? = nil
    ) -> NiriWindow {
        addWindow(
            token: handle.id,
            to: workspaceId,
            afterSelection: selectedNodeId,
            focusedToken: focusedHandle?.id
        )
    }

    @discardableResult
    func syncWindows(
        _ handles: [WindowHandle],
        in workspaceId: WorkspaceDescriptor.ID,
        selectedNodeId: NodeId?,
        focusedHandle: WindowHandle? = nil
    ) -> Set<WindowToken> {
        syncWindows(
            handles.map(\.id),
            in: workspaceId,
            selectedNodeId: selectedNodeId,
            focusedToken: focusedHandle?.id
        )
    }

    func updateWindowConstraints(for handle: WindowHandle, constraints: WindowSizeConstraints) {
        updateWindowConstraints(for: handle.id, constraints: constraints)
    }
}

extension DwindleLayoutEngine {
    @discardableResult
    func syncWindows(
        _ handles: [WindowHandle],
        in workspaceId: WorkspaceDescriptor.ID,
        focusedHandle: WindowHandle?
    ) -> Set<WindowToken> {
        syncWindows(handles.map(\.id), in: workspaceId, focusedToken: focusedHandle?.id)
    }

    func updateWindowConstraints(for handle: WindowHandle, constraints: WindowSizeConstraints) {
        updateWindowConstraints(for: handle.id, constraints: constraints)
    }
}

extension WindowActionHandler {
    func navigateToWindowInternal(handle: WindowHandle, workspaceId: WorkspaceDescriptor.ID) {
        navigateToWindowInternal(token: handle.id, workspaceId: workspaceId)
    }
}

extension NiriWindow {
    convenience init(handle: WindowHandle) {
        self.init(token: handle.id)
    }
}
