import CoreGraphics
import Foundation

final class WindowModel {
    struct Entry {
        let handle: WindowHandle
        var axRef: AXWindowRef
        var workspaceId: WorkspaceDescriptor.ID
        let windowId: Int
        var hiddenProportionalPosition: CGPoint?

        var layoutReason: LayoutReason = .standard

        var parentKind: ParentKind = .tilingContainer

        var prevParentKind: ParentKind?
    }

    private(set) var entries: [WindowHandle: Entry] = [:]
    private var keyToHandle: [WindowKey: WindowHandle] = [:]

    struct WindowKey: Hashable {
        let pid: pid_t
        let windowId: Int
    }

    func reset() {
        entries.removeAll()
        keyToHandle.removeAll()
    }

    func upsert(window: AXWindowRef, pid: pid_t, windowId: Int, workspace: WorkspaceDescriptor.ID) -> WindowHandle {
        let key = WindowKey(pid: pid, windowId: windowId)
        if let handle = keyToHandle[key], var entry = entries[handle] {
            entry.axRef = window
            entries[handle] = entry
            return handle
        } else {
            let handle = WindowHandle(id: UUID(), pid: pid, axElement: window.element)
            let entry = Entry(
                handle: handle,
                axRef: window,
                workspaceId: workspace,
                windowId: windowId,
                hiddenProportionalPosition: nil
            )
            entries[handle] = entry
            keyToHandle[key] = handle
            return handle
        }
    }

    func updateWorkspace(for handle: WindowHandle, workspace: WorkspaceDescriptor.ID) {
        guard var entry = entries[handle] else { return }
        entry.workspaceId = workspace
        entries[handle] = entry
    }

    func windows(in workspace: WorkspaceDescriptor.ID) -> [Entry] {
        entries.values.filter { $0.workspaceId == workspace }
    }

    func entry(for handle: WindowHandle) -> Entry? {
        entries[handle]
    }

    func hiddenProportionalPosition(for handle: WindowHandle) -> CGPoint? {
        entries[handle]?.hiddenProportionalPosition
    }

    func setHiddenProportionalPosition(_ position: CGPoint?, for handle: WindowHandle) {
        guard var entry = entries[handle] else { return }
        entry.hiddenProportionalPosition = position
        entries[handle] = entry
    }

    func isHiddenInCorner(_ handle: WindowHandle) -> Bool {
        entries[handle]?.hiddenProportionalPosition != nil
    }

    func layoutReason(for handle: WindowHandle) -> LayoutReason {
        entries[handle]?.layoutReason ?? .standard
    }

    func parentKind(for handle: WindowHandle) -> ParentKind {
        entries[handle]?.parentKind ?? .tilingContainer
    }

    func setLayoutReason(_ reason: LayoutReason, for handle: WindowHandle) {
        guard var entry = entries[handle] else { return }

        if reason != .standard, entry.layoutReason == .standard {
            entry.prevParentKind = entry.parentKind
        }
        entry.layoutReason = reason
        entries[handle] = entry
    }

    func setParentKind(_ kind: ParentKind, for handle: WindowHandle) {
        guard var entry = entries[handle] else { return }
        entry.parentKind = kind
        entries[handle] = entry
    }

    func restoreFromNativeState(for handle: WindowHandle) -> ParentKind? {
        guard var entry = entries[handle],
              entry.layoutReason != .standard,
              let prevKind = entry.prevParentKind else { return nil }
        entry.layoutReason = .standard
        entry.parentKind = prevKind
        entry.prevParentKind = nil
        entries[handle] = entry
        return prevKind
    }

    func isInNativeState(_ handle: WindowHandle) -> Bool {
        guard let entry = entries[handle] else { return false }
        return entry.layoutReason != .standard
    }

    func windows(withLayoutReason reason: LayoutReason) -> [Entry] {
        entries.values.filter { $0.layoutReason == reason }
    }

    func removeMissing(keys activeKeys: Set<WindowKey>) {
        let toRemove = keyToHandle.keys.filter { !activeKeys.contains($0) }
        for key in toRemove {
            if let handle = keyToHandle[key] {
                entries.removeValue(forKey: handle)
                keyToHandle.removeValue(forKey: key)
            }
        }
    }

    func removeWindow(key: WindowKey) {
        if let handle = keyToHandle[key] {
            entries.removeValue(forKey: handle)
            keyToHandle.removeValue(forKey: key)
        }
    }
}
