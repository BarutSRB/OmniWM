import AppKit
import Foundation

struct WorkspaceDescriptor: Identifiable, Hashable {
    typealias ID = UUID
    let id: ID
    var name: String
    var assignedMonitorPoint: CGPoint?

    init(name: String, assignedMonitorPoint: CGPoint? = nil) {
        id = UUID()
        self.name = name
        self.assignedMonitorPoint = assignedMonitorPoint
    }
}

@MainActor
final class WorkspaceManager {
    private(set) var monitors: [Monitor] = Monitor.current()
    private let settings: SettingsStore

    private var workspacesById: [WorkspaceDescriptor.ID: WorkspaceDescriptor] = [:]
    private var workspaceIdByName: [String: WorkspaceDescriptor.ID] = [:]

    private var screenPointToVisibleWorkspace: [CGPoint: WorkspaceDescriptor.ID] = [:]
    private var visibleWorkspaceToScreenPoint: [WorkspaceDescriptor.ID: CGPoint] = [:]
    private var screenPointToPrevVisibleWorkspace: [CGPoint: WorkspaceDescriptor.ID] = [:]

    private(set) var gaps: Double = 8
    private(set) var outerGaps: LayoutGaps.OuterGaps = .zero
    private let windows = WindowModel()

    private var niriViewportStates: [WorkspaceDescriptor.ID: ViewportState] = [:]
    private var currentAnimationSettings: ViewportState = .init()
    var animationClock: AnimationClock?

    var onGapsChanged: (() -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
        if monitors.isEmpty {
            monitors = [Monitor.fallback()]
        }
        applySettings()
    }

    var workspaces: [WorkspaceDescriptor] {
        sortedWorkspaces()
    }

    func descriptor(for id: WorkspaceDescriptor.ID) -> WorkspaceDescriptor? {
        workspacesById[id]
    }

    func workspaceId(for name: String, createIfMissing: Bool) -> WorkspaceDescriptor.ID? {
        if let existing = workspaceIdByName[name] {
            return existing
        }
        guard createIfMissing else { return nil }
        return createWorkspace(named: name)
    }

    func workspaceId(named name: String) -> WorkspaceDescriptor.ID? {
        workspaceIdByName[name]
    }

    func workspaces(on monitorId: Monitor.ID) -> [WorkspaceDescriptor] {
        guard let monitor = monitors.first(where: { $0.id == monitorId }) else { return [] }
        let assigned = sortedWorkspaces().filter { workspace in
            guard let workspaceMonitor = monitorForWorkspace(workspace.id) else { return false }
            return workspaceMonitor.id == monitor.id
        }
        return assigned
    }

    func primaryWorkspace() -> WorkspaceDescriptor? {
        let monitor = monitors.first(where: { $0.isMain }) ?? monitors.first
        guard let monitor else { return nil }
        return activeWorkspaceOrFirst(on: monitor.id)
    }

    func activeWorkspace(on monitor: Monitor.ID) -> WorkspaceDescriptor? {
        ensureVisibleWorkspaces()
        guard let monitor = monitors.first(where: { $0.id == monitor }) else { return nil }
        guard let workspaceId = screenPointToVisibleWorkspace[monitor.workspaceAnchorPoint] else { return nil }
        return descriptor(for: workspaceId)
    }

    func previousWorkspace(on monitorId: Monitor.ID) -> WorkspaceDescriptor? {
        guard let monitor = monitors.first(where: { $0.id == monitorId }) else { return nil }
        guard let prevId = screenPointToPrevVisibleWorkspace[monitor.workspaceAnchorPoint] else { return nil }
        guard prevId != screenPointToVisibleWorkspace[monitor.workspaceAnchorPoint] else { return nil }
        return descriptor(for: prevId)
    }

    func nextWorkspaceInOrder(
        on monitorId: Monitor.ID,
        from workspaceId: WorkspaceDescriptor.ID,
        wrapAround: Bool
    ) -> WorkspaceDescriptor? {
        adjacentWorkspaceInOrder(on: monitorId, from: workspaceId, offset: 1, wrapAround: wrapAround)
    }

    func previousWorkspaceInOrder(
        on monitorId: Monitor.ID,
        from workspaceId: WorkspaceDescriptor.ID,
        wrapAround: Bool
    ) -> WorkspaceDescriptor? {
        adjacentWorkspaceInOrder(on: monitorId, from: workspaceId, offset: -1, wrapAround: wrapAround)
    }

    func activeWorkspaceOrFirst(on monitor: Monitor.ID) -> WorkspaceDescriptor? {
        if let active = activeWorkspace(on: monitor) {
            return active
        }
        guard let monitor = monitors.first(where: { $0.id == monitor }) else { return nil }
        let stubId = getStubWorkspaceId(forPoint: monitor.workspaceAnchorPoint)
        _ = setActiveWorkspace(stubId, on: monitor)
        return descriptor(for: stubId)
    }

    func visibleWorkspaceIds() -> Set<WorkspaceDescriptor.ID> {
        Set(screenPointToVisibleWorkspace.values)
    }

    private func adjacentWorkspaceInOrder(
        on monitorId: Monitor.ID,
        from workspaceId: WorkspaceDescriptor.ID,
        offset: Int,
        wrapAround: Bool
    ) -> WorkspaceDescriptor? {
        let ordered = workspaces(on: monitorId)
        guard ordered.count > 1 else { return nil }
        guard let currentIdx = ordered.firstIndex(where: { $0.id == workspaceId }) else { return nil }

        let targetIdx = currentIdx + offset
        if wrapAround {
            let wrappedIdx = (targetIdx % ordered.count + ordered.count) % ordered.count
            return ordered[wrappedIdx]
        }
        guard ordered.indices.contains(targetIdx) else { return nil }
        return ordered[targetIdx]
    }

    func focusWorkspace(named name: String) -> (workspace: WorkspaceDescriptor, monitor: Monitor)? {
        ensureVisibleWorkspaces()
        guard let workspaceId = workspaceId(for: name, createIfMissing: true) else { return nil }
        guard let targetMonitor = monitorForWorkspace(workspaceId) else { return nil }
        guard setActiveWorkspace(workspaceId, on: targetMonitor) else { return nil }
        guard let workspace = descriptor(for: workspaceId) else { return nil }
        return (workspace, targetMonitor)
    }

    func applySettings() {
        ensurePersistentWorkspaces()
        applyForcedAssignments()
        ensureVisibleWorkspaces()
        reconcileForcedVisibleWorkspaces()
        applyAnimationSettingsFromStore()
    }

    private func applyAnimationSettingsFromStore() {
        currentAnimationSettings.animationsEnabled = settings.animationsEnabled
    }

    func updateMonitors(_ newMonitors: [Monitor]) {
        monitors = newMonitors.isEmpty ? [Monitor.fallback()] : newMonitors
        ensureVisibleWorkspaces()
        reconcileForcedVisibleWorkspaces()
    }

    func reconcileAfterMonitorChange() {
        ensureVisibleWorkspaces()
        reconcileForcedVisibleWorkspaces()
    }

    func setGaps(to size: Double) {
        let clamped = max(0, min(64, size))
        guard clamped != gaps else { return }
        gaps = clamped
        onGapsChanged?()
    }

    func setOuterGaps(left: Double, right: Double, top: Double, bottom: Double) {
        let newGaps = LayoutGaps.OuterGaps(
            left: max(0, CGFloat(left)),
            right: max(0, CGFloat(right)),
            top: max(0, CGFloat(top)),
            bottom: max(0, CGFloat(bottom))
        )
        if outerGaps.left == newGaps.left,
           outerGaps.right == newGaps.right,
           outerGaps.top == newGaps.top,
           outerGaps.bottom == newGaps.bottom
        {
            return
        }
        outerGaps = newGaps
        onGapsChanged?()
    }

    func monitorForWorkspace(_ workspaceId: WorkspaceDescriptor.ID) -> Monitor? {
        guard let point = workspaceMonitorPoint(for: workspaceId) else { return monitors.first }
        return point.monitorApproximation(in: monitors) ?? monitors.first
    }

    func monitor(for workspaceId: WorkspaceDescriptor.ID) -> Monitor? {
        monitorForWorkspace(workspaceId)
    }

    func monitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        monitorForWorkspace(workspaceId)?.id
    }

    @discardableResult
    func addWindow(_ ax: AXWindowRef, pid: pid_t, windowId: Int, to workspace: WorkspaceDescriptor.ID) -> WindowHandle {
        windows.upsert(window: ax, pid: pid, windowId: windowId, workspace: workspace)
    }

    func entries(in workspace: WorkspaceDescriptor.ID) -> [WindowModel.Entry] {
        windows.windows(in: workspace)
    }

    func entry(for handle: WindowHandle) -> WindowModel.Entry? {
        windows.entry(for: handle)
    }

    func entry(forPid pid: pid_t, windowId: Int) -> WindowModel.Entry? {
        windows.entry(forPid: pid, windowId: windowId)
    }

    func entries(forPid pid: pid_t) -> [WindowModel.Entry] {
        windows.entries(forPid: pid)
    }

    func entry(forWindowId windowId: Int) -> WindowModel.Entry? {
        windows.entry(forWindowId: windowId)
    }

    func entry(forWindowId windowId: Int, inVisibleWorkspaces: Bool) -> WindowModel.Entry? {
        guard inVisibleWorkspaces else {
            return windows.entry(forWindowId: windowId)
        }
        return windows.entry(forWindowId: windowId, inVisibleWorkspaces: visibleWorkspaceIds())
    }

    func allEntries() -> [WindowModel.Entry] {
        windows.allEntries()
    }

    func removeMissing(keys activeKeys: Set<WindowModel.WindowKey>) {
        windows.removeMissing(keys: activeKeys)
    }

    func removeWindow(pid: pid_t, windowId: Int) {
        windows.removeWindow(key: .init(pid: pid, windowId: windowId))
    }

    func removeWindowsForApp(pid: pid_t) {
        for ws in workspaces {
            let entriesToRemove = entries(in: ws.id).filter { $0.handle.pid == pid }
            for entry in entriesToRemove {
                removeWindow(pid: pid, windowId: entry.windowId)
            }
        }
    }

    func setWorkspace(for handle: WindowHandle, to workspace: WorkspaceDescriptor.ID) {
        windows.updateWorkspace(for: handle, workspace: workspace)
    }

    func workspace(for handle: WindowHandle) -> WorkspaceDescriptor.ID? {
        windows.entry(for: handle)?.workspaceId
    }

    func setHiddenProportionalPosition(_ position: CGPoint?, for handle: WindowHandle) {
        windows.setHiddenProportionalPosition(position, for: handle)
    }

    func isHiddenInCorner(_ handle: WindowHandle) -> Bool {
        windows.isHiddenInCorner(handle)
    }

    func layoutReason(for handle: WindowHandle) -> LayoutReason {
        windows.layoutReason(for: handle)
    }

    func setLayoutReason(_ reason: LayoutReason, for handle: WindowHandle) {
        windows.setLayoutReason(reason, for: handle)
    }

    func restoreFromNativeState(for handle: WindowHandle) -> ParentKind? {
        windows.restoreFromNativeState(for: handle)
    }

    func cachedConstraints(for handle: WindowHandle, maxAge: TimeInterval = 5.0) -> WindowSizeConstraints? {
        windows.cachedConstraints(for: handle, maxAge: maxAge)
    }

    func setCachedConstraints(_ constraints: WindowSizeConstraints, for handle: WindowHandle) {
        windows.setCachedConstraints(constraints, for: handle)
    }

    @discardableResult
    func moveWorkspaceToMonitor(_ workspaceId: WorkspaceDescriptor.ID, to targetMonitorId: Monitor.ID) -> Bool {
        guard let targetMonitor = monitors.first(where: { $0.id == targetMonitorId }) else { return false }
        guard let sourceMonitor = monitorForWorkspace(workspaceId) else { return false }

        if sourceMonitor.id == targetMonitor.id { return false }

        let targetScreen = targetMonitor.workspaceAnchorPoint
        guard isValidAssignment(workspaceId: workspaceId, screen: targetScreen) else { return false }

        guard setActiveWorkspace(workspaceId, on: targetMonitor) else { return false }

        let sourceScreen = sourceMonitor.workspaceAnchorPoint
        let stubId = getStubWorkspaceId(forPoint: sourceScreen)
        _ = setActiveWorkspace(stubId, onScreenPoint: sourceScreen)

        return true
    }

    @discardableResult
    func swapWorkspaces(
        _ workspace1Id: WorkspaceDescriptor.ID,
        on monitor1Id: Monitor.ID,
        with workspace2Id: WorkspaceDescriptor.ID,
        on monitor2Id: Monitor.ID
    ) -> Bool {
        guard let monitor1 = monitors.first(where: { $0.id == monitor1Id }),
              let monitor2 = monitors.first(where: { $0.id == monitor2Id }),
              monitor1Id != monitor2Id else { return false }

        let point1 = monitor1.workspaceAnchorPoint
        let point2 = monitor2.workspaceAnchorPoint

        guard isValidAssignment(workspaceId: workspace1Id, screen: point2),
              isValidAssignment(workspaceId: workspace2Id, screen: point1) else { return false }

        screenPointToPrevVisibleWorkspace[point1] = screenPointToVisibleWorkspace[point1]
        screenPointToPrevVisibleWorkspace[point2] = screenPointToVisibleWorkspace[point2]

        visibleWorkspaceToScreenPoint.removeValue(forKey: workspace1Id)
        visibleWorkspaceToScreenPoint.removeValue(forKey: workspace2Id)
        screenPointToVisibleWorkspace.removeValue(forKey: point1)
        screenPointToVisibleWorkspace.removeValue(forKey: point2)

        visibleWorkspaceToScreenPoint[workspace2Id] = point1
        screenPointToVisibleWorkspace[point1] = workspace2Id
        updateWorkspace(workspace2Id) { workspace in
            workspace.assignedMonitorPoint = point1
        }

        visibleWorkspaceToScreenPoint[workspace1Id] = point2
        screenPointToVisibleWorkspace[point2] = workspace1Id
        updateWorkspace(workspace1Id) { workspace in
            workspace.assignedMonitorPoint = point2
        }

        return true
    }

    func summonWorkspace(named workspaceName: String, to focusedMonitorId: Monitor.ID) -> WorkspaceDescriptor? {
        guard let workspaceId = workspaceId(for: workspaceName, createIfMissing: false) else { return nil }
        guard let focusedMonitor = monitors.first(where: { $0.id == focusedMonitorId }) else { return nil }

        let focusedScreen = focusedMonitor.workspaceAnchorPoint
        if screenPointToVisibleWorkspace[focusedScreen] == workspaceId { return nil }
        guard setActiveWorkspace(workspaceId, onScreenPoint: focusedScreen) else { return nil }
        return descriptor(for: workspaceId)
    }

    @discardableResult
    func summonWorkspace(_ workspaceId: WorkspaceDescriptor.ID, to targetMonitorId: Monitor.ID) -> Bool {
        guard let workspace = descriptor(for: workspaceId) else { return false }
        return summonWorkspace(named: workspace.name, to: targetMonitorId) != nil
    }

    func setActiveWorkspace(_ workspaceId: WorkspaceDescriptor.ID, on monitorId: Monitor.ID) -> Bool {
        guard let monitor = monitors.first(where: { $0.id == monitorId }) else { return false }
        return setActiveWorkspace(workspaceId, on: monitor)
    }

    @discardableResult
    func move(
        handle: WindowHandle,
        from workspaceId: WorkspaceDescriptor.ID,
        direction: Direction
    ) -> WorkspaceDescriptor? {
        guard let sourceWorkspace = descriptor(for: workspaceId) else { return nil }
        guard let sourceMonitor = monitorForWorkspace(sourceWorkspace.id) else { return nil }
        guard let targetMonitor = adjacentMonitor(from: sourceMonitor.id, direction: direction) else { return nil }
        guard let targetWorkspace = activeWorkspaceOrFirst(on: targetMonitor.id) else { return nil }

        windows.updateWorkspace(for: handle, workspace: targetWorkspace.id)
        return targetWorkspace
    }

    func niriViewportState(for workspaceId: WorkspaceDescriptor.ID) -> ViewportState {
        if let state = niriViewportStates[workspaceId] {
            return state
        }
        var newState = ViewportState()
        newState.animationsEnabled = currentAnimationSettings.animationsEnabled
        newState.animationClock = animationClock
        return newState
    }

    func updateNiriViewportState(_ state: ViewportState, for workspaceId: WorkspaceDescriptor.ID) {
        niriViewportStates[workspaceId] = state
    }

    func updateAnimationSettings(animationsEnabled: Bool? = nil) {
        if let enabled = animationsEnabled {
            currentAnimationSettings.animationsEnabled = enabled
        }
        for workspaceId in niriViewportStates.keys {
            if let enabled = animationsEnabled {
                niriViewportStates[workspaceId]?.animationsEnabled = enabled
            }
        }
    }

    func updateAnimationClock(_ clock: AnimationClock?) {
        animationClock = clock
        currentAnimationSettings.animationClock = clock
        for workspaceId in niriViewportStates.keys {
            niriViewportStates[workspaceId]?.animationClock = clock
        }
    }

    func garbageCollectUnusedWorkspaces(focusedWorkspaceId: WorkspaceDescriptor.ID?) {
        let persistent = Set(settings.persistentWorkspaceNames())
        let visible = visibleWorkspaceIds()
        var toRemove: [WorkspaceDescriptor.ID] = []
        for (id, workspace) in workspacesById {
            if persistent.contains(workspace.name) {
                continue
            }
            if visible.contains(id) {
                continue
            }
            if focusedWorkspaceId == id {
                continue
            }
            if !windows.windows(in: id).isEmpty {
                continue
            }
            toRemove.append(id)
        }

        for id in toRemove {
            workspacesById.removeValue(forKey: id)
            visibleWorkspaceToScreenPoint.removeValue(forKey: id)
            niriViewportStates.removeValue(forKey: id)
        }
        if !toRemove.isEmpty {
            workspaceIdByName = workspaceIdByName.filter { !toRemove.contains($0.value) }
            screenPointToVisibleWorkspace = screenPointToVisibleWorkspace.filter { !toRemove.contains($0.value) }
            screenPointToPrevVisibleWorkspace = screenPointToPrevVisibleWorkspace
                .filter { !toRemove.contains($0.value) }
        }
    }

    func adjacentMonitor(from monitorId: Monitor.ID, direction: Direction, wrapAround: Bool = false) -> Monitor? {
        guard let current = monitors.first(where: { $0.id == monitorId }) else { return nil }
        let axis: Monitor.Orientation = switch direction {
        case .left, .right: .horizontal
        case .up, .down: .vertical
        }

        let sorted = Monitor.sortedByPosition(monitors)
        let candidates = sorted.filter { candidate in
            candidate.id == current.id || candidate.relation(to: current) == axis
        }

        guard candidates.count > 1 else { return nil }
        guard let currentIdx = candidates.firstIndex(where: { $0.id == current.id }) else { return nil }

        let offset = (direction == .left || direction == .up) ? -1 : 1
        let targetIdx = currentIdx + offset

        if wrapAround {
            let wrappedIdx = (targetIdx % candidates.count + candidates.count) % candidates.count
            return candidates[wrappedIdx]
        }

        guard candidates.indices.contains(targetIdx) else { return nil }
        return candidates[targetIdx]
    }

    func previousMonitor(from monitorId: Monitor.ID) -> Monitor? {
        guard monitors.count > 1 else { return nil }

        let sorted = Monitor.sortedByPosition(monitors)
        guard let currentIdx = sorted.firstIndex(where: { $0.id == monitorId }) else { return nil }

        let prevIdx = currentIdx > 0 ? currentIdx - 1 : sorted.count - 1
        return sorted[prevIdx]
    }

    func nextMonitor(from monitorId: Monitor.ID) -> Monitor? {
        guard monitors.count > 1 else { return nil }

        let sorted = Monitor.sortedByPosition(monitors)
        guard let currentIdx = sorted.firstIndex(where: { $0.id == monitorId }) else { return nil }

        let nextIdx = (currentIdx + 1) % sorted.count
        return sorted[nextIdx]
    }

    private func sortedWorkspaces() -> [WorkspaceDescriptor] {
        workspacesById.values.sorted {
            let a = $0.name.toLogicalSegments()
            let b = $1.name.toLogicalSegments()
            return a < b
        }
    }

    private func ensurePersistentWorkspaces() {
        for name in settings.persistentWorkspaceNames() {
            _ = workspaceId(for: name, createIfMissing: true)
        }
    }

    private func applyForcedAssignments() {
        let assignments = settings.workspaceToMonitorAssignments()
        for (name, descriptions) in assignments {
            guard !descriptions.isEmpty else { continue }
            _ = workspaceId(for: name, createIfMissing: true)
        }
    }

    private func reconcileForcedVisibleWorkspaces() {
        let assignments = settings.workspaceToMonitorAssignments()
        guard !assignments.isEmpty else { return }

        let sortedMonitors = Monitor.sortedByPosition(monitors)
        var forcedTargets: [WorkspaceDescriptor.ID: Monitor] = [:]
        for (name, descriptions) in assignments {
            guard let workspaceId = workspaceIdByName[name] else { continue }
            guard let target = descriptions.compactMap({ $0.resolveMonitor(sortedMonitors: sortedMonitors) }).first
            else {
                continue
            }
            forcedTargets[workspaceId] = target
        }

        for (workspaceId, forcedMonitor) in forcedTargets {
            guard let currentPoint = visibleWorkspaceToScreenPoint[workspaceId] else { continue }
            if currentPoint != forcedMonitor.workspaceAnchorPoint {
                _ = setActiveWorkspace(workspaceId, on: forcedMonitor)
            }
        }
    }

    private func ensureVisibleWorkspaces() {
        let currentScreens = Set(monitors.map(\.workspaceAnchorPoint))
        let mappingScreens = Set(screenPointToVisibleWorkspace.keys)
        screenPointToPrevVisibleWorkspace = screenPointToPrevVisibleWorkspace.filter { currentScreens.contains($0.key) }
        if currentScreens != mappingScreens {
            rearrangeWorkspacesOnMonitors()
        }
    }

    private func fillMissingVisibleWorkspaces() {
        let assignments = settings.workspaceToMonitorAssignments()
        let sortedMonitors = Monitor.sortedByPosition(monitors)

        let sortedNames = assignments.keys.sorted { a, b in
            a.toLogicalSegments() < b.toLogicalSegments()
        }

        for monitor in monitors {
            let point = monitor.workspaceAnchorPoint
            if screenPointToVisibleWorkspace[point] == nil {
                var assignedWorkspaceId: WorkspaceDescriptor.ID?
                for name in sortedNames {
                    guard let descriptions = assignments[name] else { continue }
                    if let target = descriptions.compactMap({ $0.resolveMonitor(sortedMonitors: sortedMonitors) })
                        .first,
                        target.id == monitor.id,
                        let workspaceId = workspaceIdByName[name],
                        !visibleWorkspaceIds().contains(workspaceId)
                    {
                        assignedWorkspaceId = workspaceId
                        break
                    }
                }

                let workspaceId = assignedWorkspaceId ?? getStubWorkspaceId(forPoint: point)
                _ = setActiveWorkspace(workspaceId, onScreenPoint: point)
            }
        }
    }

    private func rearrangeWorkspacesOnMonitors() {
        var oldVisibleScreens = Set(screenPointToVisibleWorkspace.keys)
        let newScreens = monitors.map(\.workspaceAnchorPoint)

        var newScreenToOldScreenMapping: [CGPoint: CGPoint] = [:]
        for newScreen in newScreens {
            if let oldScreen = oldVisibleScreens
                .min(by: { $0.distanceSquared(to: newScreen) < $1.distanceSquared(to: newScreen) })
            {
                oldVisibleScreens.remove(oldScreen)
                newScreenToOldScreenMapping[newScreen] = oldScreen
            }
        }

        let oldScreenPointToVisibleWorkspace = screenPointToVisibleWorkspace
        screenPointToVisibleWorkspace = [:]
        visibleWorkspaceToScreenPoint = [:]

        for newScreen in newScreens {
            if let oldScreen = newScreenToOldScreenMapping[newScreen],
               let existingWorkspaceId = oldScreenPointToVisibleWorkspace[oldScreen],
               setActiveWorkspace(existingWorkspaceId, onScreenPoint: newScreen)
            {
                continue
            }
            let stubId = getStubWorkspaceId(forPoint: newScreen)
            _ = setActiveWorkspace(stubId, onScreenPoint: newScreen)
        }
    }

    private func getStubWorkspaceId(forPoint point: CGPoint) -> WorkspaceDescriptor.ID {
        if let prevId = screenPointToPrevVisibleWorkspace[point],
           let prev = descriptor(for: prevId),
           !visibleWorkspaceIds().contains(prevId),
           forceAssignedMonitor(for: prev.name) == nil,
           workspaceMonitorPoint(for: prevId) == point
        {
            return prevId
        }

        if let candidate = workspacesById.values.first(where: { workspace in
            guard !visibleWorkspaceIds().contains(workspace.id) else { return false }
            guard forceAssignedMonitor(for: workspace.name) == nil else { return false }
            guard let monitorPoint = workspaceMonitorPoint(for: workspace.id) else { return false }
            return monitorPoint == point
        }) {
            return candidate.id
        }

        let persistent = Set(settings.persistentWorkspaceNames())
        var idx = 1
        while idx < 10000 {
            let name = String(idx)
            if persistent.contains(name) {
                idx += 1
                continue
            }
            if let forced = forceAssignedMonitor(for: name),
               forced.workspaceAnchorPoint != point
            {
                idx += 1
                continue
            }
            if let existingId = workspaceIdByName[name] {
                if !visibleWorkspaceIds().contains(existingId), windows.windows(in: existingId).isEmpty {
                    return existingId
                }
            } else if let newId = createWorkspace(named: name) {
                return newId
            }
            idx += 1
        }

        if let fallback = createWorkspace(named: UUID().uuidString) {
            return fallback
        }
        if let existing = workspacesById.values.first {
            return existing.id
        }
        if let fallback = createWorkspace(named: "1") {
            return fallback
        }
        let workspace = WorkspaceDescriptor(name: "fallback")
        workspacesById[workspace.id] = workspace
        workspaceIdByName[workspace.name] = workspace.id
        return workspace.id
    }

    private func workspaceMonitorPoint(for workspaceId: WorkspaceDescriptor.ID) -> CGPoint? {
        guard let workspace = descriptor(for: workspaceId) else { return nil }
        if let forced = forceAssignedMonitor(for: workspace.name) {
            return forced.workspaceAnchorPoint
        }
        if let visiblePoint = visibleWorkspaceToScreenPoint[workspaceId] {
            return visiblePoint
        }
        if let assigned = workspace.assignedMonitorPoint {
            return assigned
        }
        return monitors.first(where: { $0.isMain })?.workspaceAnchorPoint ?? monitors.first?.workspaceAnchorPoint
    }

    private func forceAssignedMonitor(for workspaceName: String) -> Monitor? {
        let assignments = settings.workspaceToMonitorAssignments()
        guard let descriptions = assignments[workspaceName], !descriptions.isEmpty else { return nil }
        let sorted = Monitor.sortedByPosition(monitors)
        return descriptions.compactMap { $0.resolveMonitor(sortedMonitors: sorted) }.first
    }

    private func isValidAssignment(workspaceId: WorkspaceDescriptor.ID, screen: CGPoint) -> Bool {
        guard let workspace = descriptor(for: workspaceId) else { return false }
        if let forced = forceAssignedMonitor(for: workspace.name) {
            return forced.workspaceAnchorPoint == screen
        }
        return true
    }

    private func setActiveWorkspace(_ workspaceId: WorkspaceDescriptor.ID, on monitor: Monitor) -> Bool {
        setActiveWorkspace(workspaceId, onScreenPoint: monitor.workspaceAnchorPoint)
    }

    private func setActiveWorkspace(_ workspaceId: WorkspaceDescriptor.ID, onScreenPoint screen: CGPoint) -> Bool {
        guard isValidAssignment(workspaceId: workspaceId, screen: screen) else { return false }

        if let prevMonitorPoint = visibleWorkspaceToScreenPoint[workspaceId] {
            visibleWorkspaceToScreenPoint.removeValue(forKey: workspaceId)
            screenPointToPrevVisibleWorkspace[prevMonitorPoint] = screenPointToVisibleWorkspace
                .removeValue(forKey: prevMonitorPoint)
        }

        if let prevWorkspace = screenPointToVisibleWorkspace[screen] {
            screenPointToPrevVisibleWorkspace[screen] = prevWorkspace
            visibleWorkspaceToScreenPoint.removeValue(forKey: prevWorkspace)
        }

        visibleWorkspaceToScreenPoint[workspaceId] = screen
        screenPointToVisibleWorkspace[screen] = workspaceId
        updateWorkspace(workspaceId) { workspace in
            workspace.assignedMonitorPoint = screen
        }
        return true
    }

    private func updateWorkspace(_ workspaceId: WorkspaceDescriptor.ID, update: (inout WorkspaceDescriptor) -> Void) {
        guard var workspace = workspacesById[workspaceId] else { return }
        update(&workspace)
        workspacesById[workspaceId] = workspace
    }

    private func createWorkspace(named name: String) -> WorkspaceDescriptor.ID? {
        guard case let .success(parsed) = WorkspaceName.parse(name) else { return nil }
        let workspace = WorkspaceDescriptor(name: parsed.raw)
        workspacesById[workspace.id] = workspace
        workspaceIdByName[workspace.name] = workspace.id
        return workspace.id
    }
}

private extension CGPoint {
    func distanceSquared(to point: CGPoint) -> CGFloat {
        let dx = x - point.x
        let dy = y - point.y
        return dx * dx + dy * dy
    }
}
