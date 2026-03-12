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
    struct SessionState {
        struct MonitorSession {
            var visibleWorkspaceId: WorkspaceDescriptor.ID?
            var previousVisibleWorkspaceId: WorkspaceDescriptor.ID?
        }

        struct WorkspaceSession {
            var niriViewportState: ViewportState?
        }

        struct FocusSession {
            struct PendingManagedFocusRequest {
                var token: WindowToken?
                var workspaceId: WorkspaceDescriptor.ID?
                var monitorId: Monitor.ID?
            }

            var focusedToken: WindowToken?
            var pendingManagedFocus = PendingManagedFocusRequest()
            var lastFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowToken] = [:]
            var isNonManagedFocusActive: Bool = false
            var isAppFullscreenActive: Bool = false
        }

        var interactionMonitorId: Monitor.ID?
        var previousInteractionMonitorId: Monitor.ID?
        var monitorSessions: [Monitor.ID: MonitorSession] = [:]
        var workspaceSessions: [WorkspaceDescriptor.ID: WorkspaceSession] = [:]
        var focus = FocusSession()
    }

    private(set) var monitors: [Monitor] = Monitor.current() {
        didSet { rebuildMonitorIndexes() }
    }
    private var _monitorsById: [Monitor.ID: Monitor] = [:]
    private var _monitorsByName: [String: [Monitor]] = [:]
    private let settings: SettingsStore

    private var workspacesById: [WorkspaceDescriptor.ID: WorkspaceDescriptor] = [:]
    private var workspaceIdByName: [String: WorkspaceDescriptor.ID] = [:]

    private(set) var gaps: Double = 8
    private(set) var outerGaps: LayoutGaps.OuterGaps = .zero
    private let windows = WindowModel()

    private var _cachedSortedWorkspaces: [WorkspaceDescriptor]?
    var animationClock: AnimationClock?
    private var sessionState = SessionState()

    var onGapsChanged: (() -> Void)?
    var onSessionStateChanged: (() -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
        if monitors.isEmpty {
            monitors = [Monitor.fallback()]
        }
        rebuildMonitorIndexes()
        applySettings()
        reconcileInteractionMonitorState(notify: false)
    }

    func monitor(byId id: Monitor.ID) -> Monitor? {
        _monitorsById[id]
    }

    func monitor(named name: String) -> Monitor? {
        guard let matches = _monitorsByName[name], matches.count == 1 else { return nil }
        return matches[0]
    }

    func monitors(named name: String) -> [Monitor] {
        _monitorsByName[name] ?? []
    }

    var interactionMonitorId: Monitor.ID? {
        sessionState.interactionMonitorId
    }

    var previousInteractionMonitorId: Monitor.ID? {
        sessionState.previousInteractionMonitorId
    }

    var focusedToken: WindowToken? {
        sessionState.focus.focusedToken
    }

    var focusedHandle: WindowHandle? {
        focusedToken.flatMap { windows.handle(for: $0) }
    }

    var pendingFocusedToken: WindowToken? {
        sessionState.focus.pendingManagedFocus.token
    }

    var pendingFocusedHandle: WindowHandle? {
        pendingFocusedToken.flatMap { windows.handle(for: $0) }
    }

    var pendingFocusedWorkspaceId: WorkspaceDescriptor.ID? {
        sessionState.focus.pendingManagedFocus.workspaceId
    }

    var pendingFocusedMonitorId: Monitor.ID? {
        sessionState.focus.pendingManagedFocus.monitorId
    }

    var isNonManagedFocusActive: Bool {
        sessionState.focus.isNonManagedFocusActive
    }

    var isAppFullscreenActive: Bool {
        sessionState.focus.isAppFullscreenActive
    }

    @discardableResult
    func setInteractionMonitor(_ monitorId: Monitor.ID?, preservePrevious: Bool = true) -> Bool {
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id }
        return updateInteractionMonitor(normalizedMonitorId, preservePrevious: preservePrevious, notify: true)
    }

    @discardableResult
    func setManagedFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil
    ) -> Bool {
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id }
        var changed = false
        if let normalizedMonitorId {
            changed = updateInteractionMonitor(normalizedMonitorId, preservePrevious: true, notify: false) || changed
        }
        changed = updateFocusSession(notify: false) { focus in
            let appFullscreen = focus.isNonManagedFocusActive ? false : focus.isAppFullscreenActive
            var changed = self.applyConfirmedManagedFocus(
                token,
                in: workspaceId,
                appFullscreen: appFullscreen,
                focus: &focus
            )
            changed = self.clearPendingManagedFocusRequest(
                matching: token,
                workspaceId: workspaceId,
                focus: &focus
            ) || changed
            return changed
        } || changed
        if changed {
            notifySessionStateChanged()
        }
        return changed
    }

    @discardableResult
    func beginManagedFocusRequest(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil
    ) -> Bool {
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id }
        var changed = rememberFocus(token, in: workspaceId)
        changed = updateFocusSession(notify: true) { focus in
            self.updatePendingManagedFocusRequest(
                token,
                workspaceId: workspaceId,
                monitorId: normalizedMonitorId,
                focus: &focus
            )
        } || changed
        return changed
    }

    @discardableResult
    func confirmManagedFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil,
        appFullscreen: Bool,
        activateWorkspaceOnMonitor: Bool
    ) -> Bool {
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id } ?? self.monitorId(for: workspaceId)
        var changed = false

        if activateWorkspaceOnMonitor,
           let normalizedMonitorId,
           let monitor = monitor(byId: normalizedMonitorId)
        {
            changed = setActiveWorkspaceInternal(
                workspaceId,
                on: normalizedMonitorId,
                anchorPoint: monitor.workspaceAnchorPoint,
                updateInteractionMonitor: false,
                notify: false
            ) || changed
        }

        if let normalizedMonitorId {
            changed = updateInteractionMonitor(normalizedMonitorId, preservePrevious: true, notify: false) || changed
        }

        changed = updateFocusSession(notify: false) { focus in
            var focusChanged = self.applyConfirmedManagedFocus(
                token,
                in: workspaceId,
                appFullscreen: appFullscreen,
                focus: &focus
            )
            focusChanged = self.clearPendingManagedFocusRequest(focus: &focus) || focusChanged
            return focusChanged
        } || changed

        if changed {
            notifySessionStateChanged()
        }

        return changed
    }

    @discardableResult
    func setManagedAppFullscreen(_ active: Bool) -> Bool {
        updateFocusSession(notify: true) { focus in
            var changed = false

            if focus.isNonManagedFocusActive {
                focus.isNonManagedFocusActive = false
                changed = true
            }
            if focus.isAppFullscreenActive != active {
                focus.isAppFullscreenActive = active
                changed = true
            }

            return changed
        }
    }

    @discardableResult
    func rememberFocus(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard sessionState.focus.lastFocusedByWorkspace[workspaceId] != token else { return false }
        sessionState.focus.lastFocusedByWorkspace[workspaceId] = token
        return true
    }

    @discardableResult
    func syncWorkspaceFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor _: Monitor.ID? = nil
    ) -> Bool {
        rememberFocus(token, in: workspaceId)
    }

    @discardableResult
    func commitWorkspaceSelection(
        nodeId: NodeId?,
        focusedToken: WindowToken?,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil
    ) -> Bool {
        var changed = false

        if let nodeId {
            let currentSelection = niriViewportState(for: workspaceId).selectedNodeId
            if currentSelection != nodeId {
                withNiriViewportState(for: workspaceId) { $0.selectedNodeId = nodeId }
                changed = true
            }
        }

        if let focusedToken {
            changed = syncWorkspaceFocus(
                focusedToken,
                in: workspaceId,
                onMonitor: monitorId
            ) || changed
        }

        return changed
    }

    @discardableResult
    func applySessionPatch(_ patch: WorkspaceSessionPatch) -> Bool {
        var changed = false

        if let viewportState = patch.viewportState {
            updateNiriViewportState(viewportState, for: patch.workspaceId)
            changed = true
        }

        if let rememberedFocusToken = patch.rememberedFocusToken {
            changed = rememberFocus(rememberedFocusToken, in: patch.workspaceId) || changed
        }

        return changed
    }

    @discardableResult
    func applySessionTransfer(_ transfer: WorkspaceSessionTransfer) -> Bool {
        var changed = false

        if let sourcePatch = transfer.sourcePatch {
            changed = applySessionPatch(sourcePatch) || changed
        }

        if let targetPatch = transfer.targetPatch {
            changed = applySessionPatch(targetPatch) || changed
        }

        return changed
    }

    func lastFocusedToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        sessionState.focus.lastFocusedByWorkspace[workspaceId]
    }

    func preferredFocusToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        if let pendingToken = sessionState.focus.pendingManagedFocus.token,
           sessionState.focus.pendingManagedFocus.workspaceId == workspaceId,
           entry(for: pendingToken)?.workspaceId == workspaceId
        {
            return pendingToken
        }

        if let remembered = sessionState.focus.lastFocusedByWorkspace[workspaceId],
           entry(for: remembered)?.workspaceId == workspaceId
        {
            return remembered
        }

        if let confirmed = sessionState.focus.focusedToken,
           entry(for: confirmed)?.workspaceId == workspaceId
        {
            return confirmed
        }

        return entries(in: workspaceId).first?.token
    }

    func resolveWorkspaceFocusToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        if let remembered = sessionState.focus.lastFocusedByWorkspace[workspaceId],
           entry(for: remembered)?.workspaceId == workspaceId
        {
            return remembered
        }
        return entries(in: workspaceId).first?.token
    }

    @discardableResult
    func resolveAndSetWorkspaceFocusToken(
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor _: Monitor.ID? = nil
    ) -> WindowToken? {
        if let token = resolveWorkspaceFocusToken(in: workspaceId) {
            _ = rememberFocus(token, in: workspaceId)
            return token
        }

        _ = updateFocusSession(notify: true) { focus in
            var focusChanged = self.clearPendingManagedFocusRequest(
                matching: nil,
                workspaceId: workspaceId,
                focus: &focus
            )

            if let confirmed = focus.focusedToken,
               self.entry(for: confirmed)?.workspaceId == workspaceId
            {
                focus.focusedToken = nil
                focus.isAppFullscreenActive = false
                focusChanged = true
            }

            return focusChanged
        }

        return nil
    }

    @discardableResult
    func enterNonManagedFocus(appFullscreen: Bool) -> Bool {
        updateFocusSession(notify: true) { focus in
            var changed = false

            if focus.focusedToken != nil {
                focus.focusedToken = nil
                changed = true
            }
            changed = self.clearPendingManagedFocusRequest(matching: nil, workspaceId: nil, focus: &focus) || changed
            if !focus.isNonManagedFocusActive {
                focus.isNonManagedFocusActive = true
                changed = true
            }
            if focus.isAppFullscreenActive != appFullscreen {
                focus.isAppFullscreenActive = appFullscreen
                changed = true
            }

            return changed
        }
    }

    func handleWindowRemoved(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID?) {
        _ = updateFocusSession(notify: true) { focus in
            var focusChanged = false

            if focus.focusedToken == token {
                focus.focusedToken = nil
                focus.isAppFullscreenActive = false
                focusChanged = true
            }

            focusChanged = self.clearPendingManagedFocusRequest(
                matching: token,
                workspaceId: workspaceId,
                focus: &focus
            ) || focusChanged

            if let workspaceId,
               focus.lastFocusedByWorkspace[workspaceId] == token
            {
                focus.lastFocusedByWorkspace[workspaceId] = nil
            }

            return focusChanged
        }
    }

    @discardableResult
    private func updateFocusSession(
        notify: Bool,
        _ mutate: (inout SessionState.FocusSession) -> Bool
    ) -> Bool {
        let changed = mutate(&sessionState.focus)
        if changed, notify {
            notifySessionStateChanged()
        }
        return changed
    }

    private func applyConfirmedManagedFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        appFullscreen: Bool,
        focus: inout SessionState.FocusSession
    ) -> Bool {
        var changed = false

        if focus.focusedToken != token {
            focus.focusedToken = token
            changed = true
        }
        if focus.lastFocusedByWorkspace[workspaceId] != token {
            focus.lastFocusedByWorkspace[workspaceId] = token
            changed = true
        }
        if focus.isNonManagedFocusActive {
            focus.isNonManagedFocusActive = false
            changed = true
        }
        if focus.isAppFullscreenActive != appFullscreen {
            focus.isAppFullscreenActive = appFullscreen
            changed = true
        }

        return changed
    }

    private func updatePendingManagedFocusRequest(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        focus: inout SessionState.FocusSession
    ) -> Bool {
        var changed = false

        if focus.pendingManagedFocus.token != token {
            focus.pendingManagedFocus.token = token
            changed = true
        }
        if focus.pendingManagedFocus.workspaceId != workspaceId {
            focus.pendingManagedFocus.workspaceId = workspaceId
            changed = true
        }
        if focus.pendingManagedFocus.monitorId != monitorId {
            focus.pendingManagedFocus.monitorId = monitorId
            changed = true
        }

        return changed
    }

    private func clearPendingManagedFocusRequest(
        focus: inout SessionState.FocusSession
    ) -> Bool {
        guard focus.pendingManagedFocus.token != nil
            || focus.pendingManagedFocus.workspaceId != nil
            || focus.pendingManagedFocus.monitorId != nil
        else {
            return false
        }
        focus.pendingManagedFocus = .init()
        return true
    }

    private func clearPendingManagedFocusRequest(
        matching token: WindowToken?,
        workspaceId: WorkspaceDescriptor.ID?,
        focus: inout SessionState.FocusSession
    ) -> Bool {
        let request = focus.pendingManagedFocus
        let matchesHandle = token.map { request.token == $0 } ?? true
        let matchesWorkspace = workspaceId.map { request.workspaceId == $0 } ?? true
        guard matchesHandle, matchesWorkspace else { return false }
        guard request.token != nil || request.workspaceId != nil || request.monitorId != nil else { return false }
        focus.pendingManagedFocus = .init()
        return true
    }

    private func rebuildMonitorIndexes() {
        _monitorsById = Dictionary(uniqueKeysWithValues: monitors.map { ($0.id, $0) })
        var byName: [String: [Monitor]] = [:]
        for monitor in monitors {
            byName[monitor.name, default: []].append(monitor)
        }
        for key in byName.keys {
            byName[key] = Monitor.sortedByPosition(byName[key] ?? [])
        }
        _monitorsByName = byName
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
        guard let monitor = monitor(byId: monitorId) else { return [] }
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

    func activeWorkspace(on monitorId: Monitor.ID) -> WorkspaceDescriptor? {
        ensureVisibleWorkspaces()
        return currentActiveWorkspace(on: monitorId)
    }

    func currentActiveWorkspace(on monitorId: Monitor.ID) -> WorkspaceDescriptor? {
        guard let mon = monitor(byId: monitorId) else { return nil }
        guard let workspaceId = visibleWorkspaceId(on: mon.id) else { return nil }
        return descriptor(for: workspaceId)
    }

    func previousWorkspace(on monitorId: Monitor.ID) -> WorkspaceDescriptor? {
        guard let monitor = monitor(byId: monitorId) else { return nil }
        guard let prevId = previousVisibleWorkspaceId(on: monitor.id) else { return nil }
        guard prevId != visibleWorkspaceId(on: monitor.id) else { return nil }
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

    func activeWorkspaceOrFirst(on monitorId: Monitor.ID) -> WorkspaceDescriptor? {
        if let active = activeWorkspace(on: monitorId) {
            return active
        }
        guard let mon = monitor(byId: monitorId) else { return nil }
        let stubId = getStubWorkspaceId(for: mon.id)
        _ = setActiveWorkspaceInternal(stubId, on: mon.id, anchorPoint: mon.workspaceAnchorPoint)
        return descriptor(for: stubId)
    }

    func visibleWorkspaceIds() -> Set<WorkspaceDescriptor.ID> {
        Set(activeVisibleWorkspaceMap().values)
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
        guard setActiveWorkspace(workspaceId, on: targetMonitor.id) else { return nil }
        guard let workspace = descriptor(for: workspaceId) else { return nil }
        return (workspace, targetMonitor)
    }

    func applySettings() {
        ensurePersistentWorkspaces()
        applyForcedAssignments()
        ensureVisibleWorkspaces()
        reconcileForcedVisibleWorkspaces()
    }

    func applyMonitorConfigurationChange(_ newMonitors: [Monitor]) {
        let restoreSnapshots = captureVisibleWorkspaceRestoreSnapshots()
        replaceMonitors(with: newMonitors)
        restoreVisibleWorkspacesAfterMonitorConfigurationChange(from: restoreSnapshots)
        reconcileForcedVisibleWorkspaces()
        reconcileInteractionMonitorState()
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
        guard let monitorId = workspaceMonitorId(for: workspaceId) else { return monitors.first }
        return monitor(byId: monitorId) ?? monitors.first
    }

    func monitor(for workspaceId: WorkspaceDescriptor.ID) -> Monitor? {
        monitorForWorkspace(workspaceId)
    }

    func monitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        monitorForWorkspace(workspaceId)?.id
    }

    @discardableResult
    func addWindow(_ ax: AXWindowRef, pid: pid_t, windowId: Int, to workspace: WorkspaceDescriptor.ID) -> WindowToken {
        windows.upsert(window: ax, pid: pid, windowId: windowId, workspace: workspace)
    }

    func entries(in workspace: WorkspaceDescriptor.ID) -> [WindowModel.Entry] {
        windows.windows(in: workspace)
    }

    func handle(for token: WindowToken) -> WindowHandle? {
        windows.handle(for: token)
    }

    func entry(for token: WindowToken) -> WindowModel.Entry? {
        windows.entry(for: token)
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

    func removeMissing(keys activeKeys: Set<WindowModel.WindowKey>, requiredConsecutiveMisses: Int = 1) {
        let removedEntries = windows.removeMissing(keys: activeKeys, requiredConsecutiveMisses: requiredConsecutiveMisses)
        for entry in removedEntries {
            handleWindowRemoved(entry.token, in: entry.workspaceId)
        }
    }

    @discardableResult
    func removeWindow(pid: pid_t, windowId: Int) -> WindowModel.Entry? {
        guard let entry = windows.entry(forPid: pid, windowId: windowId) else { return nil }
        handleWindowRemoved(entry.token, in: entry.workspaceId)
        _ = windows.removeWindow(key: .init(pid: pid, windowId: windowId))
        return entry
    }

    @discardableResult
    func removeWindowsForApp(pid: pid_t) -> Set<WorkspaceDescriptor.ID> {
        var affectedWorkspaces: Set<WorkspaceDescriptor.ID> = []
        let entriesToRemove = entries(forPid: pid)

        for entry in entriesToRemove {
            affectedWorkspaces.insert(entry.workspaceId)
            handleWindowRemoved(entry.token, in: entry.workspaceId)
            _ = windows.removeWindow(key: .init(pid: pid, windowId: entry.windowId))
        }

        return affectedWorkspaces
    }

    func setWorkspace(for token: WindowToken, to workspace: WorkspaceDescriptor.ID) {
        windows.updateWorkspace(for: token, workspace: workspace)
    }

    func workspace(for token: WindowToken) -> WorkspaceDescriptor.ID? {
        windows.workspace(for: token)
    }

    func isHiddenInCorner(_ token: WindowToken) -> Bool {
        windows.isHiddenInCorner(token)
    }

    func setHiddenState(_ state: WindowModel.HiddenState?, for token: WindowToken) {
        windows.setHiddenState(state, for: token)
    }

    func hiddenState(for token: WindowToken) -> WindowModel.HiddenState? {
        windows.hiddenState(for: token)
    }

    func layoutReason(for token: WindowToken) -> LayoutReason {
        windows.layoutReason(for: token)
    }

    func setLayoutReason(_ reason: LayoutReason, for token: WindowToken) {
        windows.setLayoutReason(reason, for: token)
    }

    func restoreFromNativeState(for token: WindowToken) -> ParentKind? {
        windows.restoreFromNativeState(for: token)
    }

    func cachedConstraints(for token: WindowToken, maxAge: TimeInterval = 5.0) -> WindowSizeConstraints? {
        windows.cachedConstraints(for: token, maxAge: maxAge)
    }

    func setCachedConstraints(_ constraints: WindowSizeConstraints, for token: WindowToken) {
        windows.setCachedConstraints(constraints, for: token)
    }

    @discardableResult
    func moveWorkspaceToMonitor(_ workspaceId: WorkspaceDescriptor.ID, to targetMonitorId: Monitor.ID) -> Bool {
        guard let targetMonitor = monitor(byId: targetMonitorId) else { return false }
        guard let sourceMonitor = monitorForWorkspace(workspaceId) else { return false }

        if sourceMonitor.id == targetMonitor.id { return false }

        guard isValidAssignment(workspaceId: workspaceId, monitorId: targetMonitor.id) else { return false }

        guard setActiveWorkspaceInternal(
            workspaceId,
            on: targetMonitor.id,
            anchorPoint: targetMonitor.workspaceAnchorPoint,
            updateInteractionMonitor: true
        ) else {
            return false
        }

        let stubId = getStubWorkspaceId(for: sourceMonitor.id)
        _ = setActiveWorkspaceInternal(
            stubId,
            on: sourceMonitor.id,
            anchorPoint: sourceMonitor.workspaceAnchorPoint
        )

        return true
    }

    @discardableResult
    func swapWorkspaces(
        _ workspace1Id: WorkspaceDescriptor.ID,
        on monitor1Id: Monitor.ID,
        with workspace2Id: WorkspaceDescriptor.ID,
        on monitor2Id: Monitor.ID
    ) -> Bool {
        guard let monitor1 = monitor(byId: monitor1Id),
              let monitor2 = monitor(byId: monitor2Id),
              monitor1Id != monitor2Id else { return false }

        guard isValidAssignment(workspaceId: workspace1Id, monitorId: monitor2.id),
              isValidAssignment(workspaceId: workspace2Id, monitorId: monitor1.id) else { return false }

        let previousWorkspace1 = visibleWorkspaceId(on: monitor1.id)
        let previousWorkspace2 = visibleWorkspaceId(on: monitor2.id)

        updateMonitorSession(monitor1.id) { session in
            session.previousVisibleWorkspaceId = previousWorkspace1
            session.visibleWorkspaceId = workspace2Id
        }
        updateWorkspace(workspace2Id) { workspace in
            workspace.assignedMonitorPoint = monitor1.workspaceAnchorPoint
        }

        updateMonitorSession(monitor2.id) { session in
            session.previousVisibleWorkspaceId = previousWorkspace2
            session.visibleWorkspaceId = workspace1Id
        }
        updateWorkspace(workspace1Id) { workspace in
            workspace.assignedMonitorPoint = monitor2.workspaceAnchorPoint
        }

        notifySessionStateChanged()
        return true
    }

    func summonWorkspace(named workspaceName: String, to focusedMonitorId: Monitor.ID) -> WorkspaceDescriptor? {
        guard let workspaceId = workspaceId(for: workspaceName, createIfMissing: false) else { return nil }
        guard let focusedMonitor = monitor(byId: focusedMonitorId) else { return nil }

        if visibleWorkspaceId(on: focusedMonitor.id) == workspaceId { return nil }
        guard setActiveWorkspace(workspaceId, on: focusedMonitor.id) else { return nil }
        return descriptor(for: workspaceId)
    }

    @discardableResult
    func summonWorkspace(_ workspaceId: WorkspaceDescriptor.ID, to targetMonitorId: Monitor.ID) -> Bool {
        guard let workspace = descriptor(for: workspaceId) else { return false }
        return summonWorkspace(named: workspace.name, to: targetMonitorId) != nil
    }

    func setActiveWorkspace(
        _ workspaceId: WorkspaceDescriptor.ID,
        on monitorId: Monitor.ID,
        updateInteractionMonitor: Bool = true
    ) -> Bool {
        guard let monitor = monitor(byId: monitorId) else { return false }
        return setActiveWorkspaceInternal(
            workspaceId,
            on: monitor.id,
            anchorPoint: monitor.workspaceAnchorPoint,
            updateInteractionMonitor: updateInteractionMonitor
        )
    }

    func assignWorkspaceToMonitor(_ workspaceId: WorkspaceDescriptor.ID, monitorId: Monitor.ID) {
        guard let monitor = monitor(byId: monitorId) else { return }
        updateWorkspace(workspaceId) { $0.assignedMonitorPoint = monitor.workspaceAnchorPoint }
    }

    func resolveTargetForMonitorMove(
        from workspaceId: WorkspaceDescriptor.ID,
        direction: Direction
    ) -> (workspace: WorkspaceDescriptor, monitor: Monitor)? {
        guard let sourceWorkspace = descriptor(for: workspaceId) else { return nil }
        guard let sourceMonitor = monitorForWorkspace(sourceWorkspace.id) else { return nil }
        guard let targetMonitor = adjacentMonitor(from: sourceMonitor.id, direction: direction) else { return nil }
        guard let targetWorkspace = activeWorkspaceOrFirst(on: targetMonitor.id) else { return nil }
        return (targetWorkspace, targetMonitor)
    }

    func niriViewportState(for workspaceId: WorkspaceDescriptor.ID) -> ViewportState {
        if let state = sessionState.workspaceSessions[workspaceId]?.niriViewportState {
            return state
        }
        var newState = ViewportState()
        newState.animationClock = animationClock
        return newState
    }

    func updateNiriViewportState(_ state: ViewportState, for workspaceId: WorkspaceDescriptor.ID) {
        var workspaceSession = sessionState.workspaceSessions[workspaceId] ?? SessionState.WorkspaceSession()
        workspaceSession.niriViewportState = state
        sessionState.workspaceSessions[workspaceId] = workspaceSession
    }

    func withNiriViewportState(
        for workspaceId: WorkspaceDescriptor.ID,
        _ mutate: (inout ViewportState) -> Void
    ) {
        var state = niriViewportState(for: workspaceId)
        mutate(&state)
        updateNiriViewportState(state, for: workspaceId)
    }

    func setSelection(_ nodeId: NodeId?, for workspaceId: WorkspaceDescriptor.ID) {
        withNiriViewportState(for: workspaceId) { $0.selectedNodeId = nodeId }
    }

    func updateAnimationClock(_ clock: AnimationClock?) {
        animationClock = clock
        for workspaceId in sessionState.workspaceSessions.keys {
            sessionState.workspaceSessions[workspaceId]?.niriViewportState?.animationClock = clock
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
            sessionState.workspaceSessions.removeValue(forKey: id)
            sessionState.focus.lastFocusedByWorkspace.removeValue(forKey: id)
        }
        if !toRemove.isEmpty {
            _cachedSortedWorkspaces = nil
            workspaceIdByName = workspaceIdByName.filter { !toRemove.contains($0.value) }
            for monitorId in sessionState.monitorSessions.keys {
                updateMonitorSession(monitorId) { session in
                    if let visibleWorkspaceId = session.visibleWorkspaceId,
                       toRemove.contains(visibleWorkspaceId)
                    {
                        session.visibleWorkspaceId = nil
                    }
                    if let previousVisibleWorkspaceId = session.previousVisibleWorkspaceId,
                       toRemove.contains(previousVisibleWorkspaceId)
                    {
                        session.previousVisibleWorkspaceId = nil
                    }
                }
            }
        }
    }

    func adjacentMonitor(from monitorId: Monitor.ID, direction: Direction, wrapAround: Bool = false) -> Monitor? {
        guard let current = monitor(byId: monitorId) else { return nil }
        let others = monitors.filter { $0.id != current.id }
        guard !others.isEmpty else { return nil }

        let directional = others.filter { candidate in
            let delta = monitorDelta(from: current, to: candidate)
            switch direction {
            case .left: return delta.dx < 0
            case .right: return delta.dx > 0
            case .up: return delta.dy > 0
            case .down: return delta.dy < 0
            }
        }

        if let bestDirectional = bestMonitor(in: directional, from: current, direction: direction) {
            return bestDirectional
        }

        guard wrapAround else { return nil }
        return wrappedMonitor(in: others, from: current, direction: direction)
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

    private func monitorDelta(from source: Monitor, to target: Monitor) -> (dx: CGFloat, dy: CGFloat) {
        let dx = target.frame.center.x - source.frame.center.x
        let dy = target.frame.center.y - source.frame.center.y
        return (dx, dy)
    }

    private func bestMonitor(in candidates: [Monitor], from current: Monitor, direction: Direction) -> Monitor? {
        candidates.min(by: {
            isBetterMonitorCandidate($0, than: $1, from: current, direction: direction, mode: .directional)
        })
    }

    private func wrappedMonitor(in candidates: [Monitor], from current: Monitor, direction: Direction) -> Monitor? {
        candidates.min(by: {
            isBetterMonitorCandidate($0, than: $1, from: current, direction: direction, mode: .wrapped)
        })
    }

    private enum MonitorSelectionMode {
        case directional
        case wrapped
    }

    private struct MonitorSelectionRank {
        let primary: CGFloat
        let secondary: CGFloat
        let distance: CGFloat?
    }

    private func isBetterMonitorCandidate(
        _ lhs: Monitor,
        than rhs: Monitor,
        from current: Monitor,
        direction: Direction,
        mode: MonitorSelectionMode
    ) -> Bool {
        let lhsRank = monitorSelectionRank(for: lhs, from: current, direction: direction, mode: mode)
        let rhsRank = monitorSelectionRank(for: rhs, from: current, direction: direction, mode: mode)

        if lhsRank.primary != rhsRank.primary {
            return lhsRank.primary < rhsRank.primary
        }
        if lhsRank.secondary != rhsRank.secondary {
            return lhsRank.secondary < rhsRank.secondary
        }
        if let lhsDistance = lhsRank.distance,
           let rhsDistance = rhsRank.distance,
           lhsDistance != rhsDistance
        {
            return lhsDistance < rhsDistance
        }
        return monitorSortKey(lhs) < monitorSortKey(rhs)
    }

    private func monitorSelectionRank(
        for candidate: Monitor,
        from current: Monitor,
        direction: Direction,
        mode: MonitorSelectionMode
    ) -> MonitorSelectionRank {
        let delta = monitorDelta(from: current, to: candidate)

        switch mode {
        case .directional:
            switch direction {
            case .left, .right:
                return MonitorSelectionRank(
                    primary: abs(delta.dx),
                    secondary: abs(delta.dy),
                    distance: candidate.frame.center.distanceSquared(to: current.frame.center)
                )
            case .up, .down:
                return MonitorSelectionRank(
                    primary: abs(delta.dy),
                    secondary: abs(delta.dx),
                    distance: candidate.frame.center.distanceSquared(to: current.frame.center)
                )
            }
        case .wrapped:
            switch direction {
            case .right:
                return MonitorSelectionRank(primary: candidate.frame.center.x, secondary: abs(delta.dy), distance: nil)
            case .left:
                return MonitorSelectionRank(primary: -candidate.frame.center.x, secondary: abs(delta.dy), distance: nil)
            case .up:
                return MonitorSelectionRank(primary: candidate.frame.center.y, secondary: abs(delta.dx), distance: nil)
            case .down:
                return MonitorSelectionRank(primary: -candidate.frame.center.y, secondary: abs(delta.dx), distance: nil)
            }
        }
    }

    private func monitorSortKey(_ monitor: Monitor) -> (CGFloat, CGFloat, UInt32) {
        (monitor.frame.minX, -monitor.frame.maxY, monitor.displayId)
    }

    private func sortedWorkspaces() -> [WorkspaceDescriptor] {
        if let cached = _cachedSortedWorkspaces {
            return cached
        }
        let sorted = workspacesById.values.sorted {
            let a = $0.name.toLogicalSegments()
            let b = $1.name.toLogicalSegments()
            return a < b
        }
        _cachedSortedWorkspaces = sorted
        return sorted
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

    private func captureVisibleWorkspaceRestoreSnapshots() -> [WorkspaceRestoreSnapshot] {
        activeVisibleWorkspaceMap()
            .sorted { lhs, rhs in
                guard let lhsMonitor = monitor(byId: lhs.key), let rhsMonitor = monitor(byId: rhs.key) else {
                    return lhs.key.displayId < rhs.key.displayId
                }
                let lhsKey = (lhsMonitor.frame.minX, -lhsMonitor.frame.maxY, lhsMonitor.displayId)
                let rhsKey = (rhsMonitor.frame.minX, -rhsMonitor.frame.maxY, rhsMonitor.displayId)
                return lhsKey < rhsKey
            }
            .compactMap { monitorId, workspaceId in
            guard let monitor = monitor(byId: monitorId) else { return nil }
            return WorkspaceRestoreSnapshot(
                monitor: MonitorRestoreKey(monitor: monitor),
                workspaceId: workspaceId
            )
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
            guard let currentMonitorId = monitorIdShowingWorkspace(workspaceId) else { continue }
            if currentMonitorId != forcedMonitor.id {
                _ = setActiveWorkspaceInternal(
                    workspaceId,
                    on: forcedMonitor.id,
                    anchorPoint: forcedMonitor.workspaceAnchorPoint
                )
            }
        }
    }

    private func restoreVisibleWorkspacesAfterMonitorConfigurationChange(
        from snapshots: [WorkspaceRestoreSnapshot]
    ) {
        guard !snapshots.isEmpty else { return }

        let assignments = resolveWorkspaceRestoreAssignments(
            snapshots: snapshots,
            monitors: monitors,
            workspaceExists: { descriptor(for: $0) != nil }
        )
        guard !assignments.isEmpty else { return }

        let forcedWorkspaceIds = forcedWorkspaceIdsForCurrentSettings()
        let forcedMonitorIds = forcedMonitorIdsForCurrentSettings()
        let sortedMonitors = Monitor.sortedByPosition(monitors)
        var restoredWorkspaces: Set<WorkspaceDescriptor.ID> = []

        for monitor in sortedMonitors {
            guard let workspaceId = assignments[monitor.id] else { continue }
            guard !forcedWorkspaceIds.contains(workspaceId) else { continue }
            guard !forcedMonitorIds.contains(monitor.id) else { continue }
            guard restoredWorkspaces.insert(workspaceId).inserted else { continue }
            _ = setActiveWorkspaceInternal(
                workspaceId,
                on: monitor.id,
                anchorPoint: monitor.workspaceAnchorPoint,
                updateInteractionMonitor: false
            )
        }
    }

    private func forcedWorkspaceIdsForCurrentSettings() -> Set<WorkspaceDescriptor.ID> {
        let assignmentNames = settings.workspaceToMonitorAssignments().keys
        return Set(assignmentNames.compactMap { workspaceId(named: $0) })
    }

    private func forcedMonitorIdsForCurrentSettings() -> Set<Monitor.ID> {
        let assignments = settings.workspaceToMonitorAssignments()
        let sortedMonitors = Monitor.sortedByPosition(monitors)
        var forcedMonitorIds: Set<Monitor.ID> = []

        for descriptions in assignments.values {
            guard let monitor = descriptions.compactMap({ $0.resolveMonitor(sortedMonitors: sortedMonitors) }).first else {
                continue
            }
            forcedMonitorIds.insert(monitor.id)
        }

        return forcedMonitorIds
    }

    private func ensureVisibleWorkspaces(previousMonitors: [Monitor]? = nil) {
        let currentMonitorIds = Set(monitors.map(\.id))
        let previousMonitorSessions = sessionState.monitorSessions
        let mappingMonitorIds = Set(previousMonitorSessions.keys)
        sessionState.monitorSessions = previousMonitorSessions.filter { currentMonitorIds.contains($0.key) }
        if currentMonitorIds != mappingMonitorIds {
            rearrangeWorkspacesOnMonitors(
                previousMonitors: previousMonitors,
                previousMonitorSessions: previousMonitorSessions
            )
        }
    }

    private func replaceMonitors(with newMonitors: [Monitor]) {
        let previousMonitors = monitors
        monitors = newMonitors.isEmpty ? [Monitor.fallback()] : newMonitors
        ensureVisibleWorkspaces(previousMonitors: previousMonitors)
    }

    private func rearrangeWorkspacesOnMonitors(
        previousMonitors: [Monitor]? = nil,
        previousMonitorSessions: [Monitor.ID: SessionState.MonitorSession]? = nil
    ) {
        // Keep traversal deterministic so startup workspace mapping is stable.
        let sortedNewMonitors = Monitor.sortedByPosition(monitors)

        let oldForward = activeVisibleWorkspaceMap(from: previousMonitorSessions ?? sessionState.monitorSessions)
        var oldMonitorById: [Monitor.ID: Monitor] = [:]

        let oldCandidates = previousMonitors ?? monitors
        for monitor in oldCandidates {
            oldMonitorById[monitor.id] = monitor
        }

        var remainingOldMonitorIds = Set(oldForward.keys.filter { oldMonitorById[$0] != nil })
        var newToOld: [Monitor.ID: Monitor.ID] = [:]

        for newMonitor in sortedNewMonitors where remainingOldMonitorIds.contains(newMonitor.id) {
            newToOld[newMonitor.id] = newMonitor.id
            remainingOldMonitorIds.remove(newMonitor.id)
        }

        for newMonitor in sortedNewMonitors where newToOld[newMonitor.id] == nil {
            guard let bestOldId = remainingOldMonitorIds.min(by: { lhs, rhs in
                guard let lhsMonitor = oldMonitorById[lhs], let rhsMonitor = oldMonitorById[rhs] else {
                    return lhs.displayId < rhs.displayId
                }
                let lhsDistance = lhsMonitor.frame.center.distanceSquared(to: newMonitor.frame.center)
                let rhsDistance = rhsMonitor.frame.center.distanceSquared(to: newMonitor.frame.center)
                if lhsDistance != rhsDistance {
                    return lhsDistance < rhsDistance
                }
                return monitorSortKey(lhsMonitor) < monitorSortKey(rhsMonitor)
            }) else {
                continue
            }
            remainingOldMonitorIds.remove(bestOldId)
            newToOld[newMonitor.id] = bestOldId
        }

        sessionState.monitorSessions = sessionState.monitorSessions.mapValues { session in
            var pruned = session
            pruned.visibleWorkspaceId = nil
            return pruned
        }

        for newMonitor in sortedNewMonitors {
            if let oldId = newToOld[newMonitor.id],
               let existingWorkspaceId = oldForward[oldId],
               setActiveWorkspaceInternal(
                   existingWorkspaceId,
                   on: newMonitor.id,
                   anchorPoint: newMonitor.workspaceAnchorPoint
               )
            {
                continue
            }
            let stubId = getStubWorkspaceId(for: newMonitor.id)
            _ = setActiveWorkspaceInternal(
                stubId,
                on: newMonitor.id,
                anchorPoint: newMonitor.workspaceAnchorPoint
            )
        }

        notifySessionStateChanged()
    }

    private func getStubWorkspaceId(for monitorId: Monitor.ID) -> WorkspaceDescriptor.ID {
        guard monitor(byId: monitorId) != nil else {
            return getFallbackWorkspaceId()
        }

        if let prevId = previousVisibleWorkspaceId(on: monitorId),
           let prev = descriptor(for: prevId),
           !visibleWorkspaceIds().contains(prevId),
           forceAssignedMonitor(for: prev.name) == nil,
           workspaceMonitorId(for: prevId) == monitorId
        {
            return prevId
        }

        // Choose stub candidates in deterministic workspace order to avoid relaunch variance.
        if let candidate = sortedWorkspaces().first(where: { workspace in
            guard !visibleWorkspaceIds().contains(workspace.id) else { return false }
            guard forceAssignedMonitor(for: workspace.name) == nil else { return false }
            guard let candidateMonitorId = workspaceMonitorId(for: workspace.id) else { return false }
            return candidateMonitorId == monitorId
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
               forced.id != monitorId
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
        return getFallbackWorkspaceId()
    }

    private func getFallbackWorkspaceId() -> WorkspaceDescriptor.ID {
        if let existing = workspacesById.values.first {
            return existing.id
        }
        if let fallback = createWorkspace(named: "1") {
            return fallback
        }
        let workspace = WorkspaceDescriptor(name: "fallback")
        workspacesById[workspace.id] = workspace
        workspaceIdByName[workspace.name] = workspace.id
        _cachedSortedWorkspaces = nil
        return workspace.id
    }

    private func workspaceMonitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        guard let workspace = descriptor(for: workspaceId) else { return nil }
        if let forced = forceAssignedMonitor(for: workspace.name) {
            return forced.id
        }
        if let visibleMonitorId = monitorIdShowingWorkspace(workspaceId) {
            return visibleMonitorId
        }
        if let assigned = workspace.assignedMonitorPoint {
            if let exact = monitors.first(where: { $0.workspaceAnchorPoint == assigned }) {
                return exact.id
            }
            return assigned.monitorApproximation(in: monitors)?.id
        }
        return monitors.first(where: { $0.isMain })?.id ?? monitors.first?.id
    }

    private func forceAssignedMonitor(for workspaceName: String) -> Monitor? {
        let assignments = settings.workspaceToMonitorAssignments()
        guard let descriptions = assignments[workspaceName], !descriptions.isEmpty else { return nil }
        let sorted = Monitor.sortedByPosition(monitors)
        return descriptions.compactMap { $0.resolveMonitor(sortedMonitors: sorted) }.first
    }

    private func isValidAssignment(workspaceId: WorkspaceDescriptor.ID, monitorId: Monitor.ID) -> Bool {
        guard let workspace = descriptor(for: workspaceId) else { return false }
        if let forced = forceAssignedMonitor(for: workspace.name) {
            return forced.id == monitorId
        }
        return true
    }

    private func setActiveWorkspaceInternal(
        _ workspaceId: WorkspaceDescriptor.ID,
        on monitorId: Monitor.ID,
        anchorPoint: CGPoint? = nil,
        updateInteractionMonitor: Bool = false,
        notify: Bool = true
    ) -> Bool {
        guard isValidAssignment(workspaceId: workspaceId, monitorId: monitorId) else { return false }
        let effectiveAnchorPoint = anchorPoint ?? monitor(byId: monitorId)?.workspaceAnchorPoint
        var workspaceVisibilityChanged = false

        if let prevMonitorId = monitorIdShowingWorkspace(workspaceId),
           prevMonitorId != monitorId
        {
            updateMonitorSession(prevMonitorId) { session in
                session.previousVisibleWorkspaceId = workspaceId
                session.visibleWorkspaceId = nil
            }
            workspaceVisibilityChanged = true
        }

        let previousWorkspaceOnMonitor = visibleWorkspaceId(on: monitorId)
        if previousWorkspaceOnMonitor != workspaceId {
            updateMonitorSession(monitorId) { session in
                if let previousWorkspaceOnMonitor {
                    session.previousVisibleWorkspaceId = previousWorkspaceOnMonitor
                }
                session.visibleWorkspaceId = workspaceId
            }
            workspaceVisibilityChanged = true
        }

        updateWorkspace(workspaceId) { workspace in
            workspace.assignedMonitorPoint = effectiveAnchorPoint
        }

        if updateInteractionMonitor {
            let interactionChanged = self.updateInteractionMonitor(monitorId, preservePrevious: true, notify: false)
            if notify, workspaceVisibilityChanged || interactionChanged {
                notifySessionStateChanged()
            }
        } else if workspaceVisibilityChanged, notify {
            notifySessionStateChanged()
        }

        return true
    }

    private func updateWorkspace(_ workspaceId: WorkspaceDescriptor.ID, update: (inout WorkspaceDescriptor) -> Void) {
        guard var workspace = workspacesById[workspaceId] else { return }
        let oldName = workspace.name
        update(&workspace)
        workspacesById[workspaceId] = workspace
        if workspace.name != oldName {
            workspaceIdByName.removeValue(forKey: oldName)
            workspaceIdByName[workspace.name] = workspaceId
            _cachedSortedWorkspaces = nil
        }
    }

    private func createWorkspace(named name: String) -> WorkspaceDescriptor.ID? {
        guard case let .success(parsed) = WorkspaceName.parse(name) else { return nil }
        let workspace = WorkspaceDescriptor(name: parsed.raw)
        workspacesById[workspace.id] = workspace
        workspaceIdByName[workspace.name] = workspace.id
        _cachedSortedWorkspaces = nil
        return workspace.id
    }

    private func visibleWorkspaceId(on monitorId: Monitor.ID) -> WorkspaceDescriptor.ID? {
        sessionState.monitorSessions[monitorId]?.visibleWorkspaceId
    }

    private func previousVisibleWorkspaceId(on monitorId: Monitor.ID) -> WorkspaceDescriptor.ID? {
        sessionState.monitorSessions[monitorId]?.previousVisibleWorkspaceId
    }

    private func monitorIdShowingWorkspace(_ workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        sessionState.monitorSessions.first { $0.value.visibleWorkspaceId == workspaceId }?.key
    }

    private func activeVisibleWorkspaceMap() -> [Monitor.ID: WorkspaceDescriptor.ID] {
        activeVisibleWorkspaceMap(from: sessionState.monitorSessions)
    }

    private func activeVisibleWorkspaceMap(
        from monitorSessions: [Monitor.ID: SessionState.MonitorSession]
    ) -> [Monitor.ID: WorkspaceDescriptor.ID] {
        Dictionary(uniqueKeysWithValues: monitorSessions.compactMap { monitorId, session in
            guard let visibleWorkspaceId = session.visibleWorkspaceId else { return nil }
            return (monitorId, visibleWorkspaceId)
        })
    }

    private func updateMonitorSession(
        _ monitorId: Monitor.ID,
        _ mutate: (inout SessionState.MonitorSession) -> Void
    ) {
        var monitorSession = sessionState.monitorSessions[monitorId] ?? SessionState.MonitorSession()
        mutate(&monitorSession)
        if monitorSession.visibleWorkspaceId == nil, monitorSession.previousVisibleWorkspaceId == nil {
            sessionState.monitorSessions.removeValue(forKey: monitorId)
        } else {
            sessionState.monitorSessions[monitorId] = monitorSession
        }
    }

    @discardableResult
    private func updateInteractionMonitor(
        _ monitorId: Monitor.ID?,
        preservePrevious: Bool,
        notify: Bool
    ) -> Bool {
        guard sessionState.interactionMonitorId != monitorId else { return false }
        if preservePrevious,
           let currentMonitorId = sessionState.interactionMonitorId,
           currentMonitorId != monitorId
        {
            sessionState.previousInteractionMonitorId = currentMonitorId
        }
        sessionState.interactionMonitorId = monitorId
        if notify {
            notifySessionStateChanged()
        }
        return true
    }

    private func reconcileInteractionMonitorState(notify: Bool = true) {
        let validMonitorIds = Set(monitors.map(\.id))
        let focusedWorkspaceMonitorId = sessionState.focus.focusedToken
            .flatMap { entry(for: $0)?.workspaceId }
            .flatMap { monitorId(for: $0) }
        let newInteractionMonitorId = sessionState.interactionMonitorId.flatMap {
            validMonitorIds.contains($0) ? $0 : nil
        } ?? focusedWorkspaceMonitorId.flatMap {
            validMonitorIds.contains($0) ? $0 : nil
        } ?? monitors.first?.id
        let newPreviousInteractionMonitorId = sessionState.previousInteractionMonitorId.flatMap {
            validMonitorIds.contains($0) ? $0 : nil
        }

        let changed = sessionState.interactionMonitorId != newInteractionMonitorId
            || sessionState.previousInteractionMonitorId != newPreviousInteractionMonitorId

        sessionState.interactionMonitorId = newInteractionMonitorId
        sessionState.previousInteractionMonitorId = newPreviousInteractionMonitorId

        if changed, notify {
            notifySessionStateChanged()
        }
    }

    private func notifySessionStateChanged() {
        onSessionStateChanged?()
    }
}

private extension CGPoint {
    func distanceSquared(to point: CGPoint) -> CGFloat {
        let dx = x - point.x
        let dy = y - point.y
        return dx * dx + dy * dy
    }
}
