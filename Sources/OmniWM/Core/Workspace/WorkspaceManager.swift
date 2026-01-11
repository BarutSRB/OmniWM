import AppKit
import Foundation

struct WorkspaceDescriptor: Identifiable, Hashable {
    typealias ID = UUID
    let id: ID
    var name: String
    var assignedMonitorPoint: CGPoint?
    var hasUserContent: Bool = false

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
        guard let workspaceId = screenPointToVisibleWorkspace[monitor.frame.topLeftCorner] else { return nil }
        return descriptor(for: workspaceId)
    }

    func activeWorkspaceOrFirst(on monitor: Monitor.ID) -> WorkspaceDescriptor? {
        if let active = activeWorkspace(on: monitor) {
            return active
        }
        guard let monitor = monitors.first(where: { $0.id == monitor }) else { return nil }
        let stubId = getStubWorkspaceId(forPoint: monitor.frame.topLeftCorner)
        _ = setActiveWorkspace(stubId, on: monitor)
        return descriptor(for: stubId)
    }

    func visibleWorkspaceIds() -> Set<WorkspaceDescriptor.ID> {
        Set(screenPointToVisibleWorkspace.values)
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
        reconcileForcedVisibleWorkspaces()
        fillMissingVisibleWorkspaces()
        applyAnimationSettingsFromStore()
    }

    private func applyAnimationSettingsFromStore() {
        currentAnimationSettings.animationsEnabled = settings.animationsEnabled
    }

    func updateMonitors(_ newMonitors: [Monitor]) {
        monitors = newMonitors.isEmpty ? [Monitor.fallback()] : newMonitors
        ensureVisibleWorkspaces()
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

    func hiddenProportionalPosition(for handle: WindowHandle) -> CGPoint? {
        windows.hiddenProportionalPosition(for: handle)
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

    func parentKind(for handle: WindowHandle) -> ParentKind {
        windows.parentKind(for: handle)
    }

    func setLayoutReason(_ reason: LayoutReason, for handle: WindowHandle) {
        windows.setLayoutReason(reason, for: handle)
    }

    func setParentKind(_ kind: ParentKind, for handle: WindowHandle) {
        windows.setParentKind(kind, for: handle)
    }

    func restoreFromNativeState(for handle: WindowHandle) -> ParentKind? {
        windows.restoreFromNativeState(for: handle)
    }

    func isInNativeState(_ handle: WindowHandle) -> Bool {
        windows.isInNativeState(handle)
    }

    func windows(withLayoutReason reason: LayoutReason) -> [WindowModel.Entry] {
        windows.windows(withLayoutReason: reason)
    }

    func cachedConstraints(for handle: WindowHandle, maxAge: TimeInterval = 5.0) -> WindowSizeConstraints? {
        windows.cachedConstraints(for: handle, maxAge: maxAge)
    }

    func setCachedConstraints(_ constraints: WindowSizeConstraints, for handle: WindowHandle) {
        windows.setCachedConstraints(constraints, for: handle)
    }

    func invalidateConstraintsCache(for handle: WindowHandle) {
        windows.invalidateConstraintsCache(for: handle)
    }

    @discardableResult
    func moveWorkspaceToMonitor(_ workspaceId: WorkspaceDescriptor.ID, to targetMonitorId: Monitor.ID) -> Bool {
        guard let targetMonitor = monitors.first(where: { $0.id == targetMonitorId }) else { return false }
        guard let sourceMonitor = monitorForWorkspace(workspaceId) else { return false }

        if sourceMonitor.id == targetMonitor.id { return false }

        let targetScreen = targetMonitor.frame.topLeftCorner
        guard isValidAssignment(workspaceId: workspaceId, screen: targetScreen) else { return false }

        let targetCurrentWorkspaceId = screenPointToVisibleWorkspace[targetScreen]

        if let targetWsId = targetCurrentWorkspaceId {
            let sourceScreen = sourceMonitor.frame.topLeftCorner

            guard isValidAssignment(workspaceId: targetWsId, screen: sourceScreen) else { return false }

            visibleWorkspaceToScreenPoint[workspaceId] = targetScreen
            visibleWorkspaceToScreenPoint[targetWsId] = sourceScreen
            screenPointToVisibleWorkspace[targetScreen] = workspaceId
            screenPointToVisibleWorkspace[sourceScreen] = targetWsId

            updateWorkspace(workspaceId) { $0.assignedMonitorPoint = targetScreen }
            updateWorkspace(targetWsId) { $0.assignedMonitorPoint = sourceScreen }
        } else {
            let sourceScreen = sourceMonitor.frame.topLeftCorner

            visibleWorkspaceToScreenPoint.removeValue(forKey: workspaceId)
            screenPointToVisibleWorkspace.removeValue(forKey: sourceScreen)

            visibleWorkspaceToScreenPoint[workspaceId] = targetScreen
            screenPointToVisibleWorkspace[targetScreen] = workspaceId
            updateWorkspace(workspaceId) { $0.assignedMonitorPoint = targetScreen }

            let stubId = getStubWorkspaceId(forPoint: sourceScreen)
            visibleWorkspaceToScreenPoint[stubId] = sourceScreen
            screenPointToVisibleWorkspace[sourceScreen] = stubId
        }

        return true
    }

    func summonWorkspace(named workspaceName: String, to focusedMonitorId: Monitor.ID) -> WorkspaceDescriptor? {
        guard let workspaceId = workspaceId(for: workspaceName, createIfMissing: false) else { return nil }
        guard let focusedMonitor = monitors.first(where: { $0.id == focusedMonitorId }) else { return nil }

        let focusedScreen = focusedMonitor.frame.topLeftCorner
        if screenPointToVisibleWorkspace[focusedScreen] == workspaceId { return nil }

        if let existingScreen = visibleWorkspaceToScreenPoint[workspaceId] {
            let currentWorkspaceId = screenPointToVisibleWorkspace[focusedScreen]

            visibleWorkspaceToScreenPoint[workspaceId] = focusedScreen
            screenPointToVisibleWorkspace[focusedScreen] = workspaceId
            updateWorkspace(workspaceId) { $0.assignedMonitorPoint = focusedScreen }

            if let currentWsId = currentWorkspaceId {
                visibleWorkspaceToScreenPoint[currentWsId] = existingScreen
                screenPointToVisibleWorkspace[existingScreen] = currentWsId
                updateWorkspace(currentWsId) { $0.assignedMonitorPoint = existingScreen }
            } else {
                screenPointToVisibleWorkspace.removeValue(forKey: existingScreen)
            }
        } else {
            if let currentWsId = screenPointToVisibleWorkspace[focusedScreen] {
                visibleWorkspaceToScreenPoint.removeValue(forKey: currentWsId)
                screenPointToPrevVisibleWorkspace[focusedScreen] = currentWsId
            }

            visibleWorkspaceToScreenPoint[workspaceId] = focusedScreen
            screenPointToVisibleWorkspace[focusedScreen] = workspaceId
            updateWorkspace(workspaceId) { $0.assignedMonitorPoint = focusedScreen }
        }

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

    func activeWorkspaceId(on monitorId: Monitor.ID) -> WorkspaceDescriptor.ID? {
        activeWorkspace(on: monitorId)?.id
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
        let currentCenter = current.frame.center
        let currentFrame = current.frame

        func isCandidate(_ candidate: Monitor) -> Bool {
            let center = candidate.frame.center
            let candidateFrame = candidate.frame

            let hasOverlap: Bool = switch direction {
            case .left, .right:
                currentFrame.maxY > candidateFrame.minY && currentFrame.minY < candidateFrame.maxY
            case .down, .up:
                currentFrame.maxX > candidateFrame.minX && currentFrame.minX < candidateFrame.maxX
            }

            guard hasOverlap else { return false }

            switch direction {
            case .left: return center.x < currentCenter.x
            case .right: return center.x > currentCenter.x
            case .up: return center.y > currentCenter.y
            case .down: return center.y < currentCenter.y
            }
        }

        func distanceSquared(_ candidate: Monitor) -> CGFloat {
            let center = candidate.frame.center
            let dx = center.x - currentCenter.x
            let dy = center.y - currentCenter.y
            return dx * dx + dy * dy
        }

        let candidates = monitors.filter { $0.id != monitorId && isCandidate($0) }
        if let adjacent = candidates.min(by: { distanceSquared($0) < distanceSquared($1) }) {
            return adjacent
        }

        if wrapAround, monitors.count > 1 {
            let sorted = Monitor.sortedMonitors(monitors)
            switch direction {
            case .left:
                return sorted.last(where: { $0.id != monitorId })
            case .right:
                return sorted.first(where: { $0.id != monitorId })
            case .up:
                let bottomSorted = monitors.sorted { $0.frame.minY < $1.frame.minY }
                return bottomSorted.first(where: { $0.id != monitorId })
            case .down:
                let topSorted = monitors.sorted { $0.frame.minY > $1.frame.minY }
                return topSorted.first(where: { $0.id != monitorId })
            }
        }

        return nil
    }

    func previousMonitor(from monitorId: Monitor.ID) -> Monitor? {
        guard monitors.count > 1 else { return nil }

        let sorted = Monitor.sortedMonitors(monitors)
        guard let currentIdx = sorted.firstIndex(where: { $0.id == monitorId }) else { return nil }

        let prevIdx = currentIdx > 0 ? currentIdx - 1 : sorted.count - 1
        return sorted[prevIdx]
    }

    func nextMonitor(from monitorId: Monitor.ID) -> Monitor? {
        guard monitors.count > 1 else { return nil }

        let sorted = Monitor.sortedMonitors(monitors)
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

        let sortedMonitors = Monitor.sortedMonitors(monitors)
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
            if currentPoint != forcedMonitor.frame.topLeftCorner {
                _ = setActiveWorkspace(workspaceId, on: forcedMonitor)
            }
        }
    }

    private func ensureVisibleWorkspaces() {
        let currentScreens = Set(monitors.map(\.frame.topLeftCorner))
        let mappingScreens = Set(screenPointToVisibleWorkspace.keys)
        screenPointToPrevVisibleWorkspace = screenPointToPrevVisibleWorkspace.filter { currentScreens.contains($0.key) }
        if currentScreens != mappingScreens {
            rearrangeWorkspacesOnMonitors()
        }
    }

    private func fillMissingVisibleWorkspaces() {
        let assignments = settings.workspaceToMonitorAssignments()
        let sortedMonitors = Monitor.sortedMonitors(monitors)

        let sortedNames = assignments.keys.sorted { a, b in
            a.toLogicalSegments() < b.toLogicalSegments()
        }

        for monitor in monitors {
            let point = monitor.frame.topLeftCorner
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
        let newScreens = monitors.map(\.frame.topLeftCorner)

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
            if forceAssignedMonitor(for: name) != nil {
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
            return forced.frame.topLeftCorner
        }
        if let visiblePoint = visibleWorkspaceToScreenPoint[workspaceId] {
            return visiblePoint
        }
        if let assigned = workspace.assignedMonitorPoint {
            return assigned
        }
        return monitors.first(where: { $0.isMain })?.frame.topLeftCorner ?? monitors.first?.frame.topLeftCorner
    }

    private func forceAssignedMonitor(for workspaceName: String) -> Monitor? {
        let assignments = settings.workspaceToMonitorAssignments()
        guard let descriptions = assignments[workspaceName], !descriptions.isEmpty else { return nil }
        let sorted = Monitor.sortedMonitors(monitors)
        return descriptions.compactMap { $0.resolveMonitor(sortedMonitors: sorted) }.first
    }

    private func isValidAssignment(workspaceId: WorkspaceDescriptor.ID, screen: CGPoint) -> Bool {
        guard let workspace = descriptor(for: workspaceId) else { return false }
        if let forced = forceAssignedMonitor(for: workspace.name) {
            return forced.frame.topLeftCorner == screen
        }
        return true
    }

    private func setActiveWorkspace(_ workspaceId: WorkspaceDescriptor.ID, on monitor: Monitor) -> Bool {
        setActiveWorkspace(workspaceId, onScreenPoint: monitor.frame.topLeftCorner)
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
