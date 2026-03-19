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
    enum NativeFullscreenTransition {
        case enterRequested
        case suspended
        case exitRequested
        case awaitingReplacement
    }

    struct NativeFullscreenRecord {
        let originalToken: WindowToken
        var currentToken: WindowToken
        let workspaceId: WorkspaceDescriptor.ID
        var replacementDeadline: Date?
        var exitRequestedByCommand: Bool
        var transition: NativeFullscreenTransition
    }

    private struct DisconnectedVisibleWorkspaceMigration {
        let removedMonitor: Monitor
        let workspaceId: WorkspaceDescriptor.ID
    }

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
            var lastTiledFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowToken] = [:]
            var lastFloatingFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowToken] = [:]
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
    private var disconnectedVisibleWorkspaceCache: [MonitorRestoreKey: WorkspaceDescriptor.ID] = [:]

    private(set) var gaps: Double = 8
    private(set) var outerGaps: LayoutGaps.OuterGaps = .zero
    private let windows = WindowModel()
    private var nativeFullscreenRecordsByOriginalToken: [WindowToken: NativeFullscreenRecord] = [:]
    private var nativeFullscreenOriginalTokenByCurrentToken: [WindowToken: WindowToken] = [:]

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

    var hasPendingNativeFullscreenTransition: Bool {
        nativeFullscreenRecordsByOriginalToken.values.contains {
            $0.transition == .enterRequested || $0.transition == .awaitingReplacement
        }
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

    func nativeFullscreenRecord(for token: WindowToken) -> NativeFullscreenRecord? {
        guard let originalToken = nativeFullscreenOriginalToken(for: token) else {
            return nil
        }
        return nativeFullscreenRecordsByOriginalToken[originalToken]
    }

    @discardableResult
    func requestNativeFullscreenEnter(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        var changed = rememberFocus(token, in: workspaceId)
        let originalToken = nativeFullscreenOriginalToken(for: token) ?? token
        let existing = nativeFullscreenRecordsByOriginalToken[originalToken]
        var record = existing ?? NativeFullscreenRecord(
            originalToken: originalToken,
            currentToken: token,
            workspaceId: workspaceId,
            replacementDeadline: nil,
            exitRequestedByCommand: false,
            transition: .enterRequested
        )

        if record.currentToken != token {
            record.currentToken = token
            changed = true
        }
        if record.replacementDeadline != nil {
            record.replacementDeadline = nil
            changed = true
        }
        if record.exitRequestedByCommand {
            record.exitRequestedByCommand = false
            changed = true
        }
        if record.transition != .enterRequested {
            record.transition = .enterRequested
            changed = true
        }
        if existing == nil || changed {
            upsertNativeFullscreenRecord(record)
        }

        return changed || existing == nil
    }

    @discardableResult
    func markNativeFullscreenSuspended(_ token: WindowToken) -> Bool {
        guard let entry = entry(for: token) else { return false }

        var changed = rememberFocus(token, in: entry.workspaceId)
        let originalToken = nativeFullscreenOriginalToken(for: token) ?? token
        let existing = nativeFullscreenRecordsByOriginalToken[originalToken]
        var record = existing ?? NativeFullscreenRecord(
            originalToken: originalToken,
            currentToken: token,
            workspaceId: entry.workspaceId,
            replacementDeadline: nil,
            exitRequestedByCommand: false,
            transition: .suspended
        )

        if record.currentToken != token {
            record.currentToken = token
            changed = true
        }
        if record.replacementDeadline != nil {
            record.replacementDeadline = nil
            changed = true
        }
        if record.exitRequestedByCommand {
            record.exitRequestedByCommand = false
            changed = true
        }
        if record.transition != .suspended {
            record.transition = .suspended
            changed = true
        }
        if existing == nil || changed {
            upsertNativeFullscreenRecord(record)
        }

        if layoutReason(for: token) != .nativeFullscreen {
            setLayoutReason(.nativeFullscreen, for: token)
            changed = true
        }
        changed = enterNonManagedFocus(appFullscreen: true) || changed
        return changed
    }

    @discardableResult
    func requestNativeFullscreenExit(
        _ token: WindowToken,
        initiatedByCommand: Bool
    ) -> Bool {
        let existing = nativeFullscreenRecord(for: token)
        if existing == nil, entry(for: token) == nil {
            return false
        }

        let originalToken = existing?.originalToken ?? token
        let workspaceId = existing?.workspaceId ?? workspace(for: token)
        guard let workspaceId else { return false }

        var record = existing ?? NativeFullscreenRecord(
            originalToken: originalToken,
            currentToken: token,
            workspaceId: workspaceId,
            replacementDeadline: nil,
            exitRequestedByCommand: initiatedByCommand,
            transition: .exitRequested
        )

        var changed = existing == nil
        if record.currentToken != token {
            record.currentToken = token
            changed = true
        }
        if record.replacementDeadline != nil {
            record.replacementDeadline = nil
            changed = true
        }
        if record.exitRequestedByCommand != initiatedByCommand {
            record.exitRequestedByCommand = initiatedByCommand
            changed = true
        }
        if record.transition != .exitRequested {
            record.transition = .exitRequested
            changed = true
        }
        if changed {
            upsertNativeFullscreenRecord(record)
        }

        return changed
    }

    @discardableResult
    func markNativeFullscreenAwaitingReplacement(
        _ token: WindowToken,
        replacementDeadline: Date
    ) -> NativeFullscreenRecord? {
        guard let originalToken = nativeFullscreenOriginalToken(for: token),
              var record = nativeFullscreenRecordsByOriginalToken[originalToken]
        else {
            return nil
        }

        if layoutReason(for: record.currentToken) != .nativeFullscreen {
            setLayoutReason(.nativeFullscreen, for: record.currentToken)
        }

        record.transition = .awaitingReplacement
        record.replacementDeadline = replacementDeadline
        upsertNativeFullscreenRecord(record)
        _ = setManagedAppFullscreen(false)
        return record
    }

    func nativeFullscreenAwaitingReplacementCandidate(
        for pid: pid_t,
        activeWorkspaceId: WorkspaceDescriptor.ID?,
        now: Date = Date()
    ) -> NativeFullscreenRecord? {
        let candidates = nativeFullscreenRecordsByOriginalToken.values.filter { record in
            guard record.currentToken.pid == pid,
                  record.transition == .awaitingReplacement
            else {
                return false
            }
            if let deadline = record.replacementDeadline, deadline < now {
                return false
            }
            return true
        }
        guard !candidates.isEmpty else { return nil }

        if let activeWorkspaceId {
            let workspaceMatches = candidates.filter { $0.workspaceId == activeWorkspaceId }
            if workspaceMatches.count == 1 {
                return workspaceMatches[0]
            }
        }

        let commandMatches = candidates.filter(\.exitRequestedByCommand)
        if commandMatches.count == 1 {
            return commandMatches[0]
        }

        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    @discardableResult
    func attachNativeFullscreenReplacement(
        _ originalToken: WindowToken,
        to newToken: WindowToken
    ) -> Bool {
        guard var record = nativeFullscreenRecordsByOriginalToken[originalToken] else {
            return false
        }
        guard record.currentToken != newToken else { return false }
        record.currentToken = newToken
        record.replacementDeadline = nil
        upsertNativeFullscreenRecord(record)
        return true
    }

    @discardableResult
    func restoreNativeFullscreenRecord(for token: WindowToken) -> ParentKind? {
        let record = nativeFullscreenRecord(for: token)
        let resolvedToken = record?.currentToken ?? token
        if let record {
            _ = removeNativeFullscreenRecord(originalToken: record.originalToken)
        }
        let restoredParentKind = restoreFromNativeState(for: resolvedToken)
        _ = setManagedAppFullscreen(false)
        return restoredParentKind
    }

    func nativeFullscreenCommandTarget(frontmostToken: WindowToken?) -> WindowToken? {
        if let frontmostToken,
           let record = nativeFullscreenRecord(for: frontmostToken),
           record.currentToken == frontmostToken,
           record.transition == .suspended || record.transition == .exitRequested
        {
            return record.currentToken
        }

        let candidates = nativeFullscreenRecordsByOriginalToken.values.filter {
            $0.transition == .suspended || $0.transition == .exitRequested
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0].currentToken
    }

    @discardableResult
    func expireNativeFullscreenAwaitingReplacementRecords(
        now: Date = Date()
    ) -> [WindowModel.Entry] {
        let expiredOriginalTokens = nativeFullscreenRecordsByOriginalToken.values.compactMap { record -> WindowToken? in
            guard record.transition == .awaitingReplacement,
                  let deadline = record.replacementDeadline,
                  deadline < now
            else {
                return nil
            }
            return record.originalToken
        }

        guard !expiredOriginalTokens.isEmpty else { return [] }

        var removedEntries: [WindowModel.Entry] = []
        removedEntries.reserveCapacity(expiredOriginalTokens.count)

        for originalToken in expiredOriginalTokens {
            guard let record = removeNativeFullscreenRecord(originalToken: originalToken) else {
                continue
            }
            if layoutReason(for: record.currentToken) == .nativeFullscreen {
                _ = restoreFromNativeState(for: record.currentToken)
            }
            if let removed = removeWindow(pid: record.currentToken.pid, windowId: record.currentToken.windowId) {
                removedEntries.append(removed)
            }
        }

        return removedEntries
    }

    @discardableResult
    func rememberFocus(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        let mode = windowMode(for: token) ?? .tiling
        return setRememberedFocus(
            token,
            in: workspaceId,
            mode: mode,
            focus: &sessionState.focus
        )
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
        sessionState.focus.lastTiledFocusedByWorkspace[workspaceId]
    }

    func lastFloatingFocusedToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        sessionState.focus.lastFloatingFocusedByWorkspace[workspaceId]
    }

    func preferredFocusToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        if let pendingToken = sessionState.focus.pendingManagedFocus.token,
           sessionState.focus.pendingManagedFocus.workspaceId == workspaceId,
           windowMode(for: pendingToken) == .tiling,
           entry(for: pendingToken)?.workspaceId == workspaceId
        {
            return pendingToken
        }

        if let remembered = sessionState.focus.lastTiledFocusedByWorkspace[workspaceId],
           entry(for: remembered)?.workspaceId == workspaceId
        {
            return remembered
        }

        if let confirmed = sessionState.focus.focusedToken,
           windowMode(for: confirmed) == .tiling,
           entry(for: confirmed)?.workspaceId == workspaceId
        {
            return confirmed
        }

        return tiledEntries(in: workspaceId).first?.token
    }

    func resolveWorkspaceFocusToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        if let remembered = sessionState.focus.lastTiledFocusedByWorkspace[workspaceId],
           entry(for: remembered)?.workspaceId == workspaceId
        {
            return remembered
        }
        if let preferredTiled = preferredFocusToken(in: workspaceId) {
            return preferredTiled
        }
        if let rememberedFloating = sessionState.focus.lastFloatingFocusedByWorkspace[workspaceId],
           entry(for: rememberedFloating)?.workspaceId == workspaceId
        {
            return rememberedFloating
        }
        if let confirmed = sessionState.focus.focusedToken,
           windowMode(for: confirmed) == .floating,
           entry(for: confirmed)?.workspaceId == workspaceId
        {
            return confirmed
        }
        return floatingEntries(in: workspaceId).first?.token
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
    func enterNonManagedFocus(
        appFullscreen: Bool,
        preserveFocusedToken: Bool = false
    ) -> Bool {
        updateFocusSession(notify: true) { focus in
            var changed = false

            if !preserveFocusedToken, focus.focusedToken != nil {
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

            focusChanged = self.clearRememberedFocus(
                token,
                workspaceId: workspaceId,
                focus: &focus
            ) || focusChanged

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
        let mode = windowMode(for: token) ?? .tiling

        if focus.focusedToken != token {
            focus.focusedToken = token
            changed = true
        }
        changed = setRememberedFocus(token, in: workspaceId, mode: mode, focus: &focus) || changed
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

    private func setRememberedFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode,
        focus: inout SessionState.FocusSession
    ) -> Bool {
        switch mode {
        case .tiling:
            guard focus.lastTiledFocusedByWorkspace[workspaceId] != token else { return false }
            focus.lastTiledFocusedByWorkspace[workspaceId] = token
            return true
        case .floating:
            guard focus.lastFloatingFocusedByWorkspace[workspaceId] != token else { return false }
            focus.lastFloatingFocusedByWorkspace[workspaceId] = token
            return true
        }
    }

    private func clearRememberedFocus(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID?,
        focus: inout SessionState.FocusSession
    ) -> Bool {
        var changed = false

        if let workspaceId {
            if focus.lastTiledFocusedByWorkspace[workspaceId] == token {
                focus.lastTiledFocusedByWorkspace[workspaceId] = nil
                changed = true
            }
            if focus.lastFloatingFocusedByWorkspace[workspaceId] == token {
                focus.lastFloatingFocusedByWorkspace[workspaceId] = nil
                changed = true
            }
            return changed
        }

        for (id, rememberedToken) in focus.lastTiledFocusedByWorkspace where rememberedToken == token {
            focus.lastTiledFocusedByWorkspace[id] = nil
            changed = true
        }
        for (id, rememberedToken) in focus.lastFloatingFocusedByWorkspace where rememberedToken == token {
            focus.lastFloatingFocusedByWorkspace[id] = nil
            changed = true
        }

        return changed
    }

    private func replaceRememberedFocus(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        focus: inout SessionState.FocusSession
    ) -> Bool {
        var changed = false

        for (workspaceId, token) in focus.lastTiledFocusedByWorkspace where token == oldToken {
            focus.lastTiledFocusedByWorkspace[workspaceId] = newToken
            changed = true
        }
        for (workspaceId, token) in focus.lastFloatingFocusedByWorkspace where token == oldToken {
            focus.lastFloatingFocusedByWorkspace[workspaceId] = newToken
            changed = true
        }

        return changed
    }

    private func reconcileRememberedFocusAfterModeChange(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        oldMode: TrackedWindowMode,
        newMode: TrackedWindowMode,
        focus: inout SessionState.FocusSession
    ) -> Bool {
        guard oldMode != newMode else { return false }

        var changed = false
        switch oldMode {
        case .tiling:
            if focus.lastTiledFocusedByWorkspace[workspaceId] == token {
                focus.lastTiledFocusedByWorkspace[workspaceId] = nil
                changed = true
            }
        case .floating:
            if focus.lastFloatingFocusedByWorkspace[workspaceId] == token {
                focus.lastFloatingFocusedByWorkspace[workspaceId] = nil
                changed = true
            }
        }

        if focus.focusedToken == token || focus.pendingManagedFocus.token == token {
            changed = setRememberedFocus(token, in: workspaceId, mode: newMode, focus: &focus) || changed
        }

        return changed
    }

    private func normalizedFloatingOrigin(
        for frame: CGRect,
        in visibleFrame: CGRect
    ) -> CGPoint {
        let availableWidth = max(1, visibleFrame.width - frame.width)
        let availableHeight = max(1, visibleFrame.height - frame.height)
        let normalizedX = (frame.origin.x - visibleFrame.minX) / availableWidth
        let normalizedY = (frame.origin.y - visibleFrame.minY) / availableHeight
        return CGPoint(
            x: min(max(0, normalizedX), 1),
            y: min(max(0, normalizedY), 1)
        )
    }

    private func floatingOrigin(
        from normalizedOrigin: CGPoint,
        windowSize: CGSize,
        in visibleFrame: CGRect
    ) -> CGPoint {
        let availableWidth = max(0, visibleFrame.width - windowSize.width)
        let availableHeight = max(0, visibleFrame.height - windowSize.height)
        return CGPoint(
            x: visibleFrame.minX + min(max(0, normalizedOrigin.x), 1) * availableWidth,
            y: visibleFrame.minY + min(max(0, normalizedOrigin.y), 1) * availableHeight
        )
    }

    private func clampedFloatingFrame(
        _ frame: CGRect,
        in visibleFrame: CGRect
    ) -> CGRect {
        let maxX = visibleFrame.maxX - frame.width
        let maxY = visibleFrame.maxY - frame.height
        let clampedX = min(max(frame.origin.x, visibleFrame.minX), maxX >= visibleFrame.minX ? maxX : visibleFrame.minX)
        let clampedY = min(max(frame.origin.y, visibleFrame.minY), maxY >= visibleFrame.minY ? maxY : visibleFrame.minY)
        return CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: frame.size)
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
        guard configuredWorkspaceNames().contains(name) else { return nil }
        return createWorkspace(named: name)
    }

    func workspaceId(named name: String) -> WorkspaceDescriptor.ID? {
        workspaceIdByName[name]
    }

    func workspaces(on monitorId: Monitor.ID) -> [WorkspaceDescriptor] {
        sortedWorkspaces().filter { workspace in
            workspaceMonitorId(for: workspace.id) == monitorId
        }
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
        guard let defaultWorkspaceId = defaultVisibleWorkspaceId(on: monitorId) else { return nil }
        _ = setActiveWorkspaceInternal(defaultWorkspaceId, on: monitorId)
        return descriptor(for: defaultWorkspaceId)
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
        guard let workspaceId = workspaceId(for: name, createIfMissing: false) else { return nil }
        guard let targetMonitor = monitorForWorkspace(workspaceId) else { return nil }
        guard setActiveWorkspace(workspaceId, on: targetMonitor.id) else { return nil }
        guard let workspace = descriptor(for: workspaceId) else { return nil }
        return (workspace, targetMonitor)
    }

    func applySettings() {
        synchronizeConfiguredWorkspaces()
        ensureVisibleWorkspaces()
        reconcileConfiguredVisibleWorkspaces()
    }

    func applyMonitorConfigurationChange(_ newMonitors: [Monitor]) {
        let restoreSnapshots = captureVisibleWorkspaceRestoreSnapshots()
        let previousMonitors = monitors
        let previousMonitorIds = Set(previousMonitors.map(\.id))
        let disconnectedVisibleMigrations = captureDisconnectedVisibleWorkspaceMigrations(
            removedFrom: previousMonitors,
            survivingMonitors: newMonitors
        )
        let hasNewMonitor = !Set(newMonitors.map(\.id)).subtracting(previousMonitorIds).isEmpty
        replaceMonitors(with: newMonitors, notify: false)
        restoreVisibleWorkspacesAfterMonitorConfigurationChange(from: restoreSnapshots)
        restoreDisconnectedVisibleWorkspacesToHomeMonitors(monitorsWereAdded: hasNewMonitor)
        applyDisconnectedVisibleWorkspaceMigrations(disconnectedVisibleMigrations)
        reconcileConfiguredVisibleWorkspaces(notify: false)
        pruneRestoredDisconnectedVisibleWorkspaces()
        reconcileInteractionMonitorState(notify: false)
        notifySessionStateChanged()
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
        guard let monitorId = workspaceMonitorId(for: workspaceId) else { return nil }
        return monitor(byId: monitorId)
    }

    func monitor(for workspaceId: WorkspaceDescriptor.ID) -> Monitor? {
        monitorForWorkspace(workspaceId)
    }

    func monitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        monitorForWorkspace(workspaceId)?.id
    }

    @discardableResult
    func addWindow(
        _ ax: AXWindowRef,
        pid: pid_t,
        windowId: Int,
        to workspace: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode = .tiling,
        ruleEffects: ManagedWindowRuleEffects = .none
    ) -> WindowToken {
        windows.upsert(
            window: ax,
            pid: pid,
            windowId: windowId,
            workspace: workspace,
            mode: mode,
            ruleEffects: ruleEffects
        )
    }

    @discardableResult
    func rekeyWindow(from oldToken: WindowToken, to newToken: WindowToken, newAXRef: AXWindowRef) -> WindowModel.Entry? {
        guard let entry = windows.rekeyWindow(from: oldToken, to: newToken, newAXRef: newAXRef) else {
            return nil
        }

        if let originalToken = nativeFullscreenOriginalToken(for: oldToken),
           var record = nativeFullscreenRecordsByOriginalToken[originalToken]
        {
            record.currentToken = newToken
            record.replacementDeadline = nil
            upsertNativeFullscreenRecord(record)
        }

        let focusChanged = updateFocusSession(notify: false) { focus in
            var changed = false

            if focus.focusedToken == oldToken {
                focus.focusedToken = newToken
                changed = true
            }

            if focus.pendingManagedFocus.token == oldToken {
                focus.pendingManagedFocus.token = newToken
                changed = true
            }

            changed = self.replaceRememberedFocus(from: oldToken, to: newToken, focus: &focus) || changed

            return changed
        }

        if focusChanged {
            notifySessionStateChanged()
        }

        return entry
    }

    func entries(in workspace: WorkspaceDescriptor.ID) -> [WindowModel.Entry] {
        windows.windows(in: workspace)
    }

    func tiledEntries(in workspace: WorkspaceDescriptor.ID) -> [WindowModel.Entry] {
        windows.windows(in: workspace, mode: .tiling)
    }

    func floatingEntries(in workspace: WorkspaceDescriptor.ID) -> [WindowModel.Entry] {
        windows.windows(in: workspace, mode: .floating)
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

    func allTiledEntries() -> [WindowModel.Entry] {
        windows.allEntries(mode: .tiling)
    }

    func allFloatingEntries() -> [WindowModel.Entry] {
        windows.allEntries(mode: .floating)
    }

    func windowMode(for token: WindowToken) -> TrackedWindowMode? {
        windows.mode(for: token)
    }

    @discardableResult
    func setWindowMode(_ mode: TrackedWindowMode, for token: WindowToken) -> Bool {
        guard let entry = entry(for: token) else { return false }
        let oldMode = entry.mode
        guard oldMode != mode else { return false }

        windows.setMode(mode, for: token)
        let workspaceId = entry.workspaceId
        let focusChanged = updateFocusSession(notify: false) { focus in
            self.reconcileRememberedFocusAfterModeChange(
                token,
                workspaceId: workspaceId,
                oldMode: oldMode,
                newMode: mode,
                focus: &focus
            )
        }
        if focusChanged {
            notifySessionStateChanged()
        }
        return true
    }

    func floatingState(for token: WindowToken) -> WindowModel.FloatingState? {
        windows.floatingState(for: token)
    }

    func setFloatingState(_ state: WindowModel.FloatingState?, for token: WindowToken) {
        windows.setFloatingState(state, for: token)
    }

    func manualLayoutOverride(for token: WindowToken) -> ManualWindowOverride? {
        windows.manualLayoutOverride(for: token)
    }

    func setManualLayoutOverride(_ override: ManualWindowOverride?, for token: WindowToken) {
        windows.setManualLayoutOverride(override, for: token)
    }

    func updateFloatingGeometry(
        frame: CGRect,
        for token: WindowToken,
        referenceMonitor: Monitor? = nil,
        restoreToFloating: Bool = true
    ) {
        guard let entry = entry(for: token) else { return }

        let resolvedReferenceMonitor = referenceMonitor
            ?? frame.center.monitorApproximation(in: monitors)
            ?? monitor(for: entry.workspaceId)
        let referenceVisibleFrame = resolvedReferenceMonitor?.visibleFrame ?? frame
        let normalizedOrigin = normalizedFloatingOrigin(
            for: frame,
            in: referenceVisibleFrame
        )

        windows.setFloatingState(
            .init(
                lastFrame: frame,
                normalizedOrigin: normalizedOrigin,
                referenceMonitorId: resolvedReferenceMonitor?.id,
                restoreToFloating: restoreToFloating
            ),
            for: token
        )
    }

    func resolvedFloatingFrame(
        for token: WindowToken,
        preferredMonitor: Monitor? = nil
    ) -> CGRect? {
        guard let entry = entry(for: token),
              let floatingState = floatingState(for: token)
        else {
            return nil
        }

        let targetMonitor = preferredMonitor
            ?? monitor(for: entry.workspaceId)
            ?? floatingState.referenceMonitorId.flatMap { monitor(byId: $0) }
        let visibleFrame = targetMonitor?.visibleFrame ?? floatingState.lastFrame

        if let targetMonitor,
           floatingState.referenceMonitorId == targetMonitor.id || floatingState.normalizedOrigin == nil
        {
            return clampedFloatingFrame(floatingState.lastFrame, in: visibleFrame)
        }

        let origin = floatingOrigin(
            from: floatingState.normalizedOrigin ?? .zero,
            windowSize: floatingState.lastFrame.size,
            in: visibleFrame
        )
        return clampedFloatingFrame(
            CGRect(origin: origin, size: floatingState.lastFrame.size),
            in: visibleFrame
        )
    }

    func removeMissing(keys activeKeys: Set<WindowModel.WindowKey>, requiredConsecutiveMisses: Int = 1) {
        let removedEntries = windows.removeMissing(keys: activeKeys, requiredConsecutiveMisses: requiredConsecutiveMisses)
        for entry in removedEntries {
            _ = removeNativeFullscreenRecord(containing: entry.token)
            handleWindowRemoved(entry.token, in: entry.workspaceId)
        }
    }

    @discardableResult
    func removeWindow(pid: pid_t, windowId: Int) -> WindowModel.Entry? {
        guard let entry = windows.entry(forPid: pid, windowId: windowId) else { return nil }
        _ = removeNativeFullscreenRecord(containing: entry.token)
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
            _ = removeNativeFullscreenRecord(containing: entry.token)
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

    func isNativeFullscreenSuspended(_ token: WindowToken) -> Bool {
        windows.isNativeFullscreenSuspended(token)
    }

    func setLayoutReason(_ reason: LayoutReason, for token: WindowToken) {
        windows.setLayoutReason(reason, for: token)
    }

    func restoreFromNativeState(for token: WindowToken) -> ParentKind? {
        windows.restoreFromNativeState(for: token)
    }

    private func nativeFullscreenOriginalToken(for token: WindowToken) -> WindowToken? {
        if nativeFullscreenRecordsByOriginalToken[token] != nil {
            return token
        }
        return nativeFullscreenOriginalTokenByCurrentToken[token]
    }

    private func upsertNativeFullscreenRecord(_ record: NativeFullscreenRecord) {
        if let previous = nativeFullscreenRecordsByOriginalToken[record.originalToken] {
            nativeFullscreenOriginalTokenByCurrentToken.removeValue(forKey: previous.currentToken)
        }
        nativeFullscreenRecordsByOriginalToken[record.originalToken] = record
        nativeFullscreenOriginalTokenByCurrentToken[record.currentToken] = record.originalToken
    }

    @discardableResult
    private func removeNativeFullscreenRecord(originalToken: WindowToken) -> NativeFullscreenRecord? {
        guard let record = nativeFullscreenRecordsByOriginalToken.removeValue(forKey: originalToken) else {
            return nil
        }
        nativeFullscreenOriginalTokenByCurrentToken.removeValue(forKey: record.currentToken)
        return record
    }

    @discardableResult
    private func removeNativeFullscreenRecord(containing token: WindowToken) -> NativeFullscreenRecord? {
        guard let originalToken = nativeFullscreenOriginalToken(for: token) else {
            return nil
        }
        return removeNativeFullscreenRecord(originalToken: originalToken)
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

        replaceVisibleWorkspaceIfNeeded(on: sourceMonitor.id)

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
        guard isValidAssignment(workspaceId: workspaceId, monitorId: monitor.id) else { return }
        updateWorkspace(workspaceId) { $0.assignedMonitorPoint = monitor.workspaceAnchorPoint }
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
        let configured = Set(configuredWorkspaceNames())
        var toRemove: [WorkspaceDescriptor.ID] = []
        for (id, workspace) in workspacesById {
            if configured.contains(workspace.name) {
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
            sessionState.focus.lastTiledFocusedByWorkspace.removeValue(forKey: id)
            sessionState.focus.lastFloatingFocusedByWorkspace.removeValue(forKey: id)
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

    private func configuredWorkspaceNames() -> [String] {
        settings.configuredWorkspaceNames()
    }

    private func synchronizeConfiguredWorkspaces() {
        let configuredNames = configuredWorkspaceNames()
        let configuredSet = Set(configuredNames)

        for name in configuredNames {
            _ = workspaceId(for: name, createIfMissing: true)
        }

        let toRemove = workspacesById.compactMap { workspaceId, workspace -> WorkspaceDescriptor.ID? in
            guard !configuredSet.contains(workspace.name) else { return nil }
            guard windows.windows(in: workspaceId).isEmpty else { return nil }
            return workspaceId
        }
        removeWorkspaces(toRemove)
    }

    private func removeWorkspaces(_ ids: [WorkspaceDescriptor.ID]) {
        guard !ids.isEmpty else { return }

        let toRemove = Set(ids)
        for id in ids {
            workspacesById.removeValue(forKey: id)
            sessionState.workspaceSessions.removeValue(forKey: id)
            sessionState.focus.lastTiledFocusedByWorkspace.removeValue(forKey: id)
            sessionState.focus.lastFloatingFocusedByWorkspace.removeValue(forKey: id)
        }

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

    private func captureDisconnectedVisibleWorkspaceMigrations(
        removedFrom previousMonitors: [Monitor],
        survivingMonitors: [Monitor]
    ) -> [DisconnectedVisibleWorkspaceMigration] {
        let survivingIds = Set(survivingMonitors.map(\.id))
        var migrations: [DisconnectedVisibleWorkspaceMigration] = []
        migrations.reserveCapacity(previousMonitors.count)

        for monitor in previousMonitors where !survivingIds.contains(monitor.id) {
            guard let workspaceId = visibleWorkspaceId(on: monitor.id),
                  descriptor(for: workspaceId) != nil
            else {
                continue
            }
            disconnectedVisibleWorkspaceCache[MonitorRestoreKey(monitor: monitor)] = workspaceId
            migrations.append(
                DisconnectedVisibleWorkspaceMigration(
                    removedMonitor: monitor,
                    workspaceId: workspaceId
                )
            )
        }

        migrations.sort { lhs, rhs in
            monitorSortKey(lhs.removedMonitor) < monitorSortKey(rhs.removedMonitor)
        }
        return migrations
    }

    private func restoreDisconnectedVisibleWorkspacesToHomeMonitors(monitorsWereAdded: Bool) {
        guard monitorsWereAdded, !disconnectedVisibleWorkspaceCache.isEmpty else { return }

        let sortedCacheEntries = disconnectedVisibleWorkspaceCache.sorted { lhs, rhs in
            restoreKeySortKey(lhs.key) < restoreKeySortKey(rhs.key)
        }

        var reconnectAssignments: [Monitor.ID: WorkspaceDescriptor.ID] = [:]
        for (_, workspaceId) in sortedCacheEntries {
            guard descriptor(for: workspaceId) != nil else { continue }
            guard let homeMonitor = homeMonitor(for: workspaceId) else { continue }
            guard reconnectAssignments[homeMonitor.id] == nil else { continue }
            reconnectAssignments[homeMonitor.id] = workspaceId
        }

        for monitor in Monitor.sortedByPosition(monitors) {
            guard let workspaceId = reconnectAssignments[monitor.id] else { continue }
            _ = setActiveWorkspaceInternal(
                workspaceId,
                on: monitor.id,
                anchorPoint: monitor.workspaceAnchorPoint,
                updateInteractionMonitor: false,
                notify: false
            )
        }
    }

    private func applyDisconnectedVisibleWorkspaceMigrations(
        _ migrations: [DisconnectedVisibleWorkspaceMigration]
    ) {
        guard !migrations.isEmpty else { return }

        var winnerByFallbackMonitorId: [Monitor.ID: DisconnectedVisibleWorkspaceMigration] = [:]
        for migration in migrations {
            guard descriptor(for: migration.workspaceId) != nil else { continue }
            guard let fallbackMonitor = effectiveMonitor(for: migration.workspaceId) else { continue }
            guard winnerByFallbackMonitorId[fallbackMonitor.id] == nil else { continue }
            winnerByFallbackMonitorId[fallbackMonitor.id] = migration
        }

        for monitor in Monitor.sortedByPosition(monitors) {
            guard let migration = winnerByFallbackMonitorId[monitor.id] else { continue }
            _ = setActiveWorkspaceInternal(
                migration.workspaceId,
                on: monitor.id,
                anchorPoint: monitor.workspaceAnchorPoint,
                updateInteractionMonitor: false,
                notify: false
            )
        }
    }

    private func pruneRestoredDisconnectedVisibleWorkspaces() {
        disconnectedVisibleWorkspaceCache = disconnectedVisibleWorkspaceCache.filter { _, workspaceId in
            guard descriptor(for: workspaceId) != nil else { return false }
            guard let homeMonitorId = homeMonitorId(for: workspaceId) else { return true }
            return visibleWorkspaceId(on: homeMonitorId) != workspaceId
        }
    }

    private func reconcileConfiguredVisibleWorkspaces(notify: Bool = true) {
        var changed = false

        for monitor in Monitor.sortedByPosition(monitors) {
            let assigned = workspaces(on: monitor.id)
            guard !assigned.isEmpty else {
                if visibleWorkspaceId(on: monitor.id) != nil || previousVisibleWorkspaceId(on: monitor.id) != nil {
                    updateMonitorSession(monitor.id) { session in
                        session.visibleWorkspaceId = nil
                        session.previousVisibleWorkspaceId = nil
                    }
                    changed = true
                }
                continue
            }

            if let currentVisibleId = visibleWorkspaceId(on: monitor.id),
               assigned.contains(where: { $0.id == currentVisibleId })
            {
                continue
            }

            guard let defaultWorkspaceId = assigned.first?.id else { continue }
            if setActiveWorkspaceInternal(
                defaultWorkspaceId,
                on: monitor.id,
                anchorPoint: monitor.workspaceAnchorPoint,
                notify: false
            ) {
                changed = true
            }
        }

        if notify, changed {
            notifySessionStateChanged()
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

        let sortedMonitors = Monitor.sortedByPosition(monitors)
        var restoredWorkspaces: Set<WorkspaceDescriptor.ID> = []

        for monitor in sortedMonitors {
            guard let workspaceId = assignments[monitor.id] else { continue }
            guard workspaceMonitorId(for: workspaceId) == monitor.id else { continue }
            guard restoredWorkspaces.insert(workspaceId).inserted else { continue }
            _ = setActiveWorkspaceInternal(
                workspaceId,
                on: monitor.id,
                anchorPoint: monitor.workspaceAnchorPoint,
                updateInteractionMonitor: false,
                notify: false
            )
        }
    }

    private func ensureVisibleWorkspaces(previousMonitors: [Monitor]? = nil, notify: Bool = true) {
        let currentMonitorIds = Set(monitors.map(\.id))
        let previousMonitorSessions = sessionState.monitorSessions
        let mappingMonitorIds = Set(previousMonitorSessions.keys)
        sessionState.monitorSessions = previousMonitorSessions.filter { currentMonitorIds.contains($0.key) }
        if currentMonitorIds != mappingMonitorIds {
            rearrangeWorkspacesOnMonitors(
                previousMonitors: previousMonitors,
                previousMonitorSessions: previousMonitorSessions,
                notify: notify
            )
        }
    }

    private func replaceMonitors(with newMonitors: [Monitor], notify: Bool = true) {
        let previousMonitors = monitors
        monitors = newMonitors.isEmpty ? [Monitor.fallback()] : newMonitors
        ensureVisibleWorkspaces(previousMonitors: previousMonitors, notify: notify)
    }

    private func rearrangeWorkspacesOnMonitors(
        previousMonitors: [Monitor]? = nil,
        previousMonitorSessions: [Monitor.ID: SessionState.MonitorSession]? = nil,
        notify: Bool = true
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
               workspaceMonitorId(for: existingWorkspaceId) == newMonitor.id,
               setActiveWorkspaceInternal(
                   existingWorkspaceId,
                   on: newMonitor.id,
                   anchorPoint: newMonitor.workspaceAnchorPoint,
                   notify: false
               )
            {
                continue
            }
            if let defaultWorkspaceId = defaultVisibleWorkspaceId(on: newMonitor.id) {
                _ = setActiveWorkspaceInternal(
                    defaultWorkspaceId,
                    on: newMonitor.id,
                    anchorPoint: newMonitor.workspaceAnchorPoint,
                    notify: false
                )
            }
        }

        if notify {
            notifySessionStateChanged()
        }
    }

    private func defaultVisibleWorkspaceId(on monitorId: Monitor.ID) -> WorkspaceDescriptor.ID? {
        let assigned = workspaces(on: monitorId)
        guard !assigned.isEmpty else { return nil }
        return assigned.first?.id
    }

    private func replaceVisibleWorkspaceIfNeeded(on monitorId: Monitor.ID) {
        guard let monitor = monitor(byId: monitorId) else { return }
        if let defaultWorkspaceId = defaultVisibleWorkspaceId(on: monitor.id) {
            _ = setActiveWorkspaceInternal(
                defaultWorkspaceId,
                on: monitor.id,
                anchorPoint: monitor.workspaceAnchorPoint
            )
        } else {
            updateMonitorSession(monitor.id) { session in
                session.visibleWorkspaceId = nil
                session.previousVisibleWorkspaceId = nil
            }
            notifySessionStateChanged()
        }
    }

    private func workspaceMonitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        guard let workspace = descriptor(for: workspaceId) else { return nil }
        if configuredWorkspaceNames().contains(workspace.name) {
            return effectiveMonitor(for: workspaceId)?.id
        }
        return monitorIdShowingWorkspace(workspaceId)
    }

    private func configuredMonitorDescriptions(for workspaceName: String) -> [MonitorDescription]? {
        let assignments = settings.workspaceToMonitorAssignments()
        guard let descriptions = assignments[workspaceName], !descriptions.isEmpty else { return nil }
        return descriptions
    }

    private func homeMonitor(for workspaceId: WorkspaceDescriptor.ID) -> Monitor? {
        guard let workspace = descriptor(for: workspaceId) else { return nil }
        guard let descriptions = configuredMonitorDescriptions(for: workspace.name) else { return nil }
        let sorted = Monitor.sortedByPosition(monitors)
        return descriptions.compactMap { $0.resolveMonitor(sortedMonitors: sorted) }.first
    }

    private func homeMonitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        homeMonitor(for: workspaceId)?.id
    }

    private func effectiveMonitor(for workspaceId: WorkspaceDescriptor.ID) -> Monitor? {
        if let home = homeMonitor(for: workspaceId) {
            return home
        }

        let sortedMonitors = Monitor.sortedByPosition(monitors)
        guard !sortedMonitors.isEmpty else { return nil }
        guard let workspace = descriptor(for: workspaceId) else { return nil }

        let anchorPoint = workspace.assignedMonitorPoint
            ?? monitorIdShowingWorkspace(workspaceId).flatMap { monitor(byId: $0)?.workspaceAnchorPoint }
        guard let anchorPoint else { return sortedMonitors.first }

        return sortedMonitors.min { lhs, rhs in
            let lhsDistance = lhs.workspaceAnchorPoint.distanceSquared(to: anchorPoint)
            let rhsDistance = rhs.workspaceAnchorPoint.distanceSquared(to: anchorPoint)
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }
            return monitorSortKey(lhs) < monitorSortKey(rhs)
        }
    }

    private func isValidAssignment(workspaceId: WorkspaceDescriptor.ID, monitorId: Monitor.ID) -> Bool {
        guard let workspace = descriptor(for: workspaceId) else { return false }
        guard configuredWorkspaceNames().contains(workspace.name) else { return false }
        return effectiveMonitor(for: workspaceId)?.id == monitorId
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
        guard WorkspaceConfiguration.allowedNames.contains(parsed.raw) else { return nil }
        guard configuredWorkspaceNames().contains(parsed.raw) else { return nil }
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

    private func restoreKeySortKey(_ restoreKey: MonitorRestoreKey) -> (CGFloat, CGFloat, UInt32) {
        (restoreKey.anchorPoint.x, -restoreKey.anchorPoint.y, restoreKey.displayId)
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
