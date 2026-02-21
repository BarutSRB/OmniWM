import Foundation

enum OmniWMFocusNotificationKey {
    static let oldWorkspaceId = "oldWorkspaceId"
    static let newWorkspaceId = "newWorkspaceId"
    static let oldWorkspaceName = "oldWorkspaceName"
    static let newWorkspaceName = "newWorkspaceName"
    static let oldMonitorIndex = "oldMonitorIndex"
    static let newMonitorIndex = "newMonitorIndex"
    static let oldMonitorName = "oldMonitorName"
    static let newMonitorName = "newMonitorName"
    static let oldWindowId = "oldWindowId"
    static let newWindowId = "newWindowId"
    static let oldHandleId = "oldHandleId"
    static let newHandleId = "newHandleId"
}

extension Notification.Name {
    static let omniwmFocusChanged = Notification.Name("OmniWM.FocusChanged")
    static let omniwmFocusedWorkspaceChanged = Notification.Name("OmniWM.FocusedWorkspaceChanged")
    static let omniwmFocusedMonitorChanged = Notification.Name("OmniWM.FocusedMonitorChanged")
}

@MainActor
final class FocusNotificationDispatcher {
    weak var controller: WMController?

    private var lastNotifiedWorkspaceId: WorkspaceDescriptor.ID?
    private var lastNotifiedMonitorId: Monitor.ID?
    private var lastNotifiedFocusedHandleId: UUID?
    private var lastNotifiedFocusedWindowId: Int?

    init(controller: WMController) {
        self.controller = controller
    }

    func notifyFocusChangesIfNeeded() {
        guard let controller else { return }

        let currentWorkspaceId = controller.focusedHandle
            .flatMap { controller.workspaceManager.workspace(for: $0) }
            ?? controller.activeWorkspace()?.id
        let currentMonitorId = controller.activeMonitorId ?? controller.monitorForInteraction()?.id

        let currentHandleId = controller.focusedHandle?.id
        let currentWindowId = controller.focusedHandle.flatMap { controller.workspaceManager.entry(for: $0)?.windowId }

        if currentHandleId != lastNotifiedFocusedHandleId || currentWindowId != lastNotifiedFocusedWindowId {
            var info: [AnyHashable: Any] = [:]
            if let oldHandleId = lastNotifiedFocusedHandleId { info[OmniWMFocusNotificationKey.oldHandleId] = oldHandleId }
            if let newHandleId = currentHandleId { info[OmniWMFocusNotificationKey.newHandleId] = newHandleId }
            if let oldWindowId = lastNotifiedFocusedWindowId { info[OmniWMFocusNotificationKey.oldWindowId] = oldWindowId }
            if let newWindowId = currentWindowId { info[OmniWMFocusNotificationKey.newWindowId] = newWindowId }

            NotificationCenter.default.post(name: .omniwmFocusChanged, object: controller, userInfo: info.isEmpty ? nil : info)
            lastNotifiedFocusedHandleId = currentHandleId
            lastNotifiedFocusedWindowId = currentWindowId
        }

        var workspaceInfo: [AnyHashable: Any] = [:]
        if let oldId = lastNotifiedWorkspaceId {
            workspaceInfo[OmniWMFocusNotificationKey.oldWorkspaceId] = oldId
            if let name = controller.workspaceManager.descriptor(for: oldId)?.name { workspaceInfo[OmniWMFocusNotificationKey.oldWorkspaceName] = name }
        }
        if let newId = currentWorkspaceId {
            workspaceInfo[OmniWMFocusNotificationKey.newWorkspaceId] = newId
            if let name = controller.workspaceManager.descriptor(for: newId)?.name { workspaceInfo[OmniWMFocusNotificationKey.newWorkspaceName] = name }
        }
        postNotificationIfChanged(name: .omniwmFocusedWorkspaceChanged, current: currentWorkspaceId, last: &lastNotifiedWorkspaceId, info: workspaceInfo, sender: controller)

        var monitorInfo: [AnyHashable: Any] = [:]
        if let oldId = lastNotifiedMonitorId {
            monitorInfo[OmniWMFocusNotificationKey.oldMonitorIndex] = oldId.displayId
            if let name = controller.workspaceManager.monitor(byId: oldId)?.name { monitorInfo[OmniWMFocusNotificationKey.oldMonitorName] = name }
        }
        if let newId = currentMonitorId {
            monitorInfo[OmniWMFocusNotificationKey.newMonitorIndex] = newId.displayId
            if let name = controller.workspaceManager.monitor(byId: newId)?.name { monitorInfo[OmniWMFocusNotificationKey.newMonitorName] = name }
        }
        postNotificationIfChanged(name: .omniwmFocusedMonitorChanged, current: currentMonitorId, last: &lastNotifiedMonitorId, info: monitorInfo, sender: controller)
    }

    private func postNotificationIfChanged<T: Equatable>(
        name: Notification.Name,
        current: T?,
        last: inout T?,
        info: [AnyHashable: Any],
        sender: AnyObject
    ) {
        guard current != last else { return }
        NotificationCenter.default.post(
            name: name,
            object: sender,
            userInfo: info.isEmpty ? nil : info
        )
        last = current
    }
}
