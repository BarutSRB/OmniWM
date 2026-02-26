import CoreGraphics
import Foundation

final class WindowModel {
    final class Entry {
        let handle: WindowHandle
        var axRef: AXWindowRef
        var workspaceId: WorkspaceDescriptor.ID
        let windowId: Int
        var hiddenProportionalPosition: CGPoint?

        var layoutReason: LayoutReason = .standard

        var parentKind: ParentKind = .tilingContainer

        var prevParentKind: ParentKind?

        var cachedConstraints: WindowSizeConstraints?
        var constraintsCacheTime: Date?

        init(
            handle: WindowHandle,
            axRef: AXWindowRef,
            workspaceId: WorkspaceDescriptor.ID,
            windowId: Int,
            hiddenProportionalPosition: CGPoint?
        ) {
            self.handle = handle
            self.axRef = axRef
            self.workspaceId = workspaceId
            self.windowId = windowId
            self.hiddenProportionalPosition = hiddenProportionalPosition
        }
    }

    private(set) var entries: [WindowHandle: Entry] = [:]
    private var keyToHandle: [WindowKey: WindowHandle] = [:]
    private var handlesByWorkspace: [WorkspaceDescriptor.ID: [WindowHandle]] = [:]
    private var handleIndexByWorkspace: [WorkspaceDescriptor.ID: [WindowHandle: Int]] = [:]
    private var windowIdToHandle: [Int: WindowHandle] = [:]
    private var missingDetectionCountByKey: [WindowKey: Int] = [:]

    struct WindowKey: Hashable {
        let pid: pid_t
        let windowId: Int
    }

    private func appendHandle(_ handle: WindowHandle, to workspace: WorkspaceDescriptor.ID) {
        var handles = handlesByWorkspace[workspace, default: []]
        var indexByHandle = handleIndexByWorkspace[workspace, default: [:]]
        guard indexByHandle[handle] == nil else { return }
        indexByHandle[handle] = handles.count
        handles.append(handle)
        handlesByWorkspace[workspace] = handles
        handleIndexByWorkspace[workspace] = indexByHandle
    }

    private func removeHandle(_ handle: WindowHandle, from workspace: WorkspaceDescriptor.ID) {
        guard var handles = handlesByWorkspace[workspace],
              var indexByHandle = handleIndexByWorkspace[workspace],
              let index = indexByHandle[handle] else { return }

        handles.remove(at: index)
        indexByHandle.removeValue(forKey: handle)

        if index < handles.count {
            for i in index ..< handles.count {
                indexByHandle[handles[i]] = i
            }
        }

        if handles.isEmpty {
            handlesByWorkspace.removeValue(forKey: workspace)
            handleIndexByWorkspace.removeValue(forKey: workspace)
        } else {
            handlesByWorkspace[workspace] = handles
            handleIndexByWorkspace[workspace] = indexByHandle
        }
    }

    func upsert(window: AXWindowRef, pid: pid_t, windowId: Int, workspace: WorkspaceDescriptor.ID) -> WindowHandle {
        let key = WindowKey(pid: pid, windowId: windowId)
        if let handle = keyToHandle[key] {
            entries[handle]?.axRef = window
            missingDetectionCountByKey.removeValue(forKey: key)
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
            appendHandle(handle, to: workspace)
            windowIdToHandle[windowId] = handle
            missingDetectionCountByKey.removeValue(forKey: key)
            return handle
        }
    }

    func updateWorkspace(for handle: WindowHandle, workspace: WorkspaceDescriptor.ID) {
        guard let oldWorkspace = entries[handle]?.workspaceId else { return }
        if oldWorkspace != workspace {
            removeHandle(handle, from: oldWorkspace)
            appendHandle(handle, to: workspace)
        }
        entries[handle]?.workspaceId = workspace
    }

    func windows(in workspace: WorkspaceDescriptor.ID) -> [Entry] {
        guard let handles = handlesByWorkspace[workspace] else { return [] }
        return handles.compactMap { entries[$0] }
    }

    func workspace(for handle: WindowHandle) -> WorkspaceDescriptor.ID? {
        entries[handle]?.workspaceId
    }

    func entry(for handle: WindowHandle) -> Entry? {
        entries[handle]
    }

    func entry(forPid pid: pid_t, windowId: Int) -> Entry? {
        let key = WindowKey(pid: pid, windowId: windowId)
        guard let handle = keyToHandle[key] else { return nil }
        return entries[handle]
    }

    func entries(forPid pid: pid_t) -> [Entry] {
        entries.values.filter { $0.handle.pid == pid }
    }

    func entry(forWindowId windowId: Int) -> Entry? {
        guard let handle = windowIdToHandle[windowId] else { return nil }
        return entries[handle]
    }

    func entry(forWindowId windowId: Int, inVisibleWorkspaces visibleIds: Set<WorkspaceDescriptor.ID>) -> Entry? {
        guard let handle = windowIdToHandle[windowId] else { return nil }
        guard let entry = entries[handle] else { return nil }
        guard visibleIds.contains(entry.workspaceId) else { return nil }
        return entry
    }

    func allEntries() -> [Entry] {
        Array(entries.values)
    }

    func setHiddenProportionalPosition(_ position: CGPoint?, for handle: WindowHandle) {
        entries[handle]?.hiddenProportionalPosition = position
    }

    func isHiddenInCorner(_ handle: WindowHandle) -> Bool {
        entries[handle]?.hiddenProportionalPosition != nil
    }

    func layoutReason(for handle: WindowHandle) -> LayoutReason {
        entries[handle]?.layoutReason ?? .standard
    }

    func setLayoutReason(_ reason: LayoutReason, for handle: WindowHandle) {
        guard let entry = entries[handle] else { return }
        if reason != .standard, entry.layoutReason == .standard {
            entry.prevParentKind = entry.parentKind
        }
        entry.layoutReason = reason
    }

    func restoreFromNativeState(for handle: WindowHandle) -> ParentKind? {
        guard let entry = entries[handle],
              entry.layoutReason != .standard,
              let prevKind = entry.prevParentKind else { return nil }
        entry.layoutReason = .standard
        entry.parentKind = prevKind
        entry.prevParentKind = nil
        return prevKind
    }

    func removeMissing(keys activeKeys: Set<WindowKey>, requiredConsecutiveMisses: Int = 1) {
        let threshold = max(1, requiredConsecutiveMisses)
        let knownKeys = Array(keyToHandle.keys)

        for key in knownKeys where activeKeys.contains(key) {
            missingDetectionCountByKey.removeValue(forKey: key)
        }

        let missingKeys = knownKeys.filter { !activeKeys.contains($0) }
        var confirmedMissing: [WindowKey] = []
        confirmedMissing.reserveCapacity(missingKeys.count)

        for key in missingKeys {
            let misses = (missingDetectionCountByKey[key] ?? 0) + 1
            if misses >= threshold {
                confirmedMissing.append(key)
                missingDetectionCountByKey.removeValue(forKey: key)
            } else {
                missingDetectionCountByKey[key] = misses
            }
        }

        for key in confirmedMissing {
            if let handle = keyToHandle[key] {
                if let entry = entries[handle] {
                    removeHandle(handle, from: entry.workspaceId)
                    windowIdToHandle.removeValue(forKey: entry.windowId)
                }
                entries.removeValue(forKey: handle)
                keyToHandle.removeValue(forKey: key)
            }
        }

        if !missingDetectionCountByKey.isEmpty {
            missingDetectionCountByKey = missingDetectionCountByKey.filter { keyToHandle[$0.key] != nil }
        }
    }

    func removeWindow(key: WindowKey) {
        missingDetectionCountByKey.removeValue(forKey: key)
        if let handle = keyToHandle[key] {
            if let entry = entries[handle] {
                removeHandle(handle, from: entry.workspaceId)
                windowIdToHandle.removeValue(forKey: entry.windowId)
            }
            entries.removeValue(forKey: handle)
            keyToHandle.removeValue(forKey: key)
        }
    }

    func cachedConstraints(for handle: WindowHandle, maxAge: TimeInterval = 5.0) -> WindowSizeConstraints? {
        guard let entry = entries[handle],
              let cached = entry.cachedConstraints,
              let cacheTime = entry.constraintsCacheTime,
              Date().timeIntervalSince(cacheTime) < maxAge else {
            return nil
        }
        return cached
    }

    func setCachedConstraints(_ constraints: WindowSizeConstraints, for handle: WindowHandle) {
        guard let entry = entries[handle] else { return }
        entry.cachedConstraints = constraints
        entry.constraintsCacheTime = Date()
    }

}
