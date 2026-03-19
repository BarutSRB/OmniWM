import CoreGraphics
import Foundation

enum TrackedWindowMode: Equatable, Sendable {
    case tiling
    case floating
}

final class WindowModel {
    typealias WindowKey = WindowToken

    struct HiddenState: Equatable {
        let proportionalPosition: CGPoint
        let referenceMonitorId: Monitor.ID?
        let workspaceInactive: Bool
        let offscreenSide: HideSide?

        init(
            proportionalPosition: CGPoint,
            referenceMonitorId: Monitor.ID?,
            workspaceInactive: Bool,
            offscreenSide: HideSide? = nil
        ) {
            self.proportionalPosition = proportionalPosition
            self.referenceMonitorId = referenceMonitorId
            self.workspaceInactive = workspaceInactive
            self.offscreenSide = offscreenSide
        }
    }

    struct FloatingState: Equatable {
        var lastFrame: CGRect
        var normalizedOrigin: CGPoint?
        var referenceMonitorId: Monitor.ID?
        var restoreToFloating: Bool

        init(
            lastFrame: CGRect,
            normalizedOrigin: CGPoint?,
            referenceMonitorId: Monitor.ID?,
            restoreToFloating: Bool
        ) {
            self.lastFrame = lastFrame
            self.normalizedOrigin = normalizedOrigin
            self.referenceMonitorId = referenceMonitorId
            self.restoreToFloating = restoreToFloating
        }
    }

    final class Entry {
        let handle: WindowHandle
        var axRef: AXWindowRef
        var workspaceId: WorkspaceDescriptor.ID
        var mode: TrackedWindowMode
        var floatingState: FloatingState?
        var manualLayoutOverride: ManualWindowOverride?
        var ruleEffects: ManagedWindowRuleEffects = .none
        var hiddenProportionalPosition: CGPoint?
        var hiddenReferenceMonitorId: Monitor.ID?
        var hiddenByWorkspaceInactivity: Bool = false
        var hiddenOffscreenSide: HideSide?

        var layoutReason: LayoutReason = .standard
        var parentKind: ParentKind = .tilingContainer
        var prevParentKind: ParentKind?
        var cachedConstraints: WindowSizeConstraints?
        var constraintsCacheTime: Date?

        var token: WindowToken { handle.id }
        var pid: pid_t { token.pid }
        var windowId: Int { token.windowId }

        init(
            handle: WindowHandle,
            axRef: AXWindowRef,
            workspaceId: WorkspaceDescriptor.ID,
            mode: TrackedWindowMode,
            floatingState: FloatingState?,
            manualLayoutOverride: ManualWindowOverride?,
            ruleEffects: ManagedWindowRuleEffects,
            hiddenProportionalPosition: CGPoint?
        ) {
            self.handle = handle
            self.axRef = axRef
            self.workspaceId = workspaceId
            self.mode = mode
            self.floatingState = floatingState
            self.manualLayoutOverride = manualLayoutOverride
            self.ruleEffects = ruleEffects
            self.hiddenProportionalPosition = hiddenProportionalPosition
        }
    }

    private(set) var entries: [WindowToken: Entry] = [:]
    private var tokensByWorkspace: [WorkspaceDescriptor.ID: [WindowToken]] = [:]
    private var tokenIndexByWorkspace: [WorkspaceDescriptor.ID: [WindowToken: Int]] = [:]
    private var missingDetectionCountByToken: [WindowToken: Int] = [:]

    private func appendToken(_ token: WindowToken, to workspace: WorkspaceDescriptor.ID) {
        var tokens = tokensByWorkspace[workspace, default: []]
        var indexByToken = tokenIndexByWorkspace[workspace, default: [:]]
        guard indexByToken[token] == nil else { return }
        indexByToken[token] = tokens.count
        tokens.append(token)
        tokensByWorkspace[workspace] = tokens
        tokenIndexByWorkspace[workspace] = indexByToken
    }

    private func removeToken(_ token: WindowToken, from workspace: WorkspaceDescriptor.ID) {
        guard var tokens = tokensByWorkspace[workspace],
              var indexByToken = tokenIndexByWorkspace[workspace],
              let index = indexByToken[token] else { return }

        tokens.remove(at: index)
        indexByToken.removeValue(forKey: token)

        if index < tokens.count {
            for i in index ..< tokens.count {
                indexByToken[tokens[i]] = i
            }
        }

        if tokens.isEmpty {
            tokensByWorkspace.removeValue(forKey: workspace)
            tokenIndexByWorkspace.removeValue(forKey: workspace)
        } else {
            tokensByWorkspace[workspace] = tokens
            tokenIndexByWorkspace[workspace] = indexByToken
        }
    }

    @discardableResult
    func upsert(
        window: AXWindowRef,
        pid: pid_t,
        windowId: Int,
        workspace: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode = .tiling,
        ruleEffects: ManagedWindowRuleEffects = .none
    ) -> WindowToken {
        let token = WindowToken(pid: pid, windowId: windowId)
        if let entry = entries[token] {
            entry.axRef = window
            updateWorkspace(for: token, workspace: workspace)
            entry.mode = mode
            if entry.ruleEffects != ruleEffects {
                entry.ruleEffects = ruleEffects
                entry.cachedConstraints = nil
                entry.constraintsCacheTime = nil
            }
            missingDetectionCountByToken.removeValue(forKey: token)
            return token
        }

        let handle = WindowHandle(id: token)
        let entry = Entry(
            handle: handle,
            axRef: window,
            workspaceId: workspace,
            mode: mode,
            floatingState: nil,
            manualLayoutOverride: nil,
            ruleEffects: ruleEffects,
            hiddenProportionalPosition: nil
        )
        entries[token] = entry
        appendToken(token, to: workspace)
        missingDetectionCountByToken.removeValue(forKey: token)
        return token
    }

    @discardableResult
    func rekeyWindow(from oldToken: WindowToken, to newToken: WindowToken, newAXRef: AXWindowRef) -> Entry? {
        if oldToken == newToken {
            guard let entry = entries[oldToken] else { return nil }
            entry.axRef = newAXRef
            return entry
        }

        guard entries[newToken] == nil,
              let entry = entries.removeValue(forKey: oldToken)
        else {
            return nil
        }

        entry.handle.id = newToken
        entry.axRef = newAXRef
        entries[newToken] = entry

        if var tokens = tokensByWorkspace[entry.workspaceId],
           var indexByToken = tokenIndexByWorkspace[entry.workspaceId],
           let index = indexByToken.removeValue(forKey: oldToken)
        {
            tokens[index] = newToken
            indexByToken[newToken] = index
            tokensByWorkspace[entry.workspaceId] = tokens
            tokenIndexByWorkspace[entry.workspaceId] = indexByToken
        }

        if let missingCount = missingDetectionCountByToken.removeValue(forKey: oldToken) {
            missingDetectionCountByToken[newToken] = missingCount
        }

        return entry
    }

    func handle(for token: WindowToken) -> WindowHandle? {
        entries[token]?.handle
    }

    func updateWorkspace(for token: WindowToken, workspace: WorkspaceDescriptor.ID) {
        guard let oldWorkspace = entries[token]?.workspaceId else { return }
        if oldWorkspace != workspace {
            removeToken(token, from: oldWorkspace)
            appendToken(token, to: workspace)
        }
        entries[token]?.workspaceId = workspace
    }

    func windows(in workspace: WorkspaceDescriptor.ID) -> [Entry] {
        guard let tokens = tokensByWorkspace[workspace] else { return [] }
        return tokens.compactMap { entries[$0] }
    }

    func windows(
        in workspace: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode
    ) -> [Entry] {
        windows(in: workspace).filter { $0.mode == mode }
    }

    func workspace(for token: WindowToken) -> WorkspaceDescriptor.ID? {
        entries[token]?.workspaceId
    }

    func entry(for token: WindowToken) -> Entry? {
        entries[token]
    }

    func entry(for handle: WindowHandle) -> Entry? {
        entry(for: handle.id)
    }

    func entry(forPid pid: pid_t, windowId: Int) -> Entry? {
        entry(for: WindowToken(pid: pid, windowId: windowId))
    }

    func entries(forPid pid: pid_t) -> [Entry] {
        entries.values.filter { $0.pid == pid }
    }

    func entry(forWindowId windowId: Int) -> Entry? {
        entries.values.first { $0.windowId == windowId }
    }

    func entry(forWindowId windowId: Int, inVisibleWorkspaces visibleIds: Set<WorkspaceDescriptor.ID>) -> Entry? {
        entries.values.first { entry in
            entry.windowId == windowId && visibleIds.contains(entry.workspaceId)
        }
    }

    func allEntries() -> [Entry] {
        Array(entries.values)
    }

    func allEntries(mode: TrackedWindowMode) -> [Entry] {
        entries.values.filter { $0.mode == mode }
    }

    func mode(for token: WindowToken) -> TrackedWindowMode? {
        entries[token]?.mode
    }

    func setMode(_ mode: TrackedWindowMode, for token: WindowToken) {
        entries[token]?.mode = mode
    }

    func floatingState(for token: WindowToken) -> FloatingState? {
        entries[token]?.floatingState
    }

    func setFloatingState(_ state: FloatingState?, for token: WindowToken) {
        entries[token]?.floatingState = state
    }

    func manualLayoutOverride(for token: WindowToken) -> ManualWindowOverride? {
        entries[token]?.manualLayoutOverride
    }

    func setManualLayoutOverride(_ override: ManualWindowOverride?, for token: WindowToken) {
        entries[token]?.manualLayoutOverride = override
    }

    func setHiddenState(_ state: HiddenState?, for token: WindowToken) {
        guard let entry = entries[token] else { return }
        if let state {
            entry.hiddenProportionalPosition = state.proportionalPosition
            entry.hiddenReferenceMonitorId = state.referenceMonitorId
            entry.hiddenByWorkspaceInactivity = state.workspaceInactive
            entry.hiddenOffscreenSide = state.offscreenSide
        } else {
            entry.hiddenProportionalPosition = nil
            entry.hiddenReferenceMonitorId = nil
            entry.hiddenByWorkspaceInactivity = false
            entry.hiddenOffscreenSide = nil
        }
    }

    func hiddenState(for token: WindowToken) -> HiddenState? {
        guard let entry = entries[token],
              let proportionalPosition = entry.hiddenProportionalPosition else { return nil }
        return HiddenState(
            proportionalPosition: proportionalPosition,
            referenceMonitorId: entry.hiddenReferenceMonitorId,
            workspaceInactive: entry.hiddenByWorkspaceInactivity,
            offscreenSide: entry.hiddenOffscreenSide
        )
    }

    func isHiddenInCorner(_ token: WindowToken) -> Bool {
        entries[token]?.hiddenProportionalPosition != nil
    }

    func layoutReason(for token: WindowToken) -> LayoutReason {
        entries[token]?.layoutReason ?? .standard
    }

    func isNativeFullscreenSuspended(_ token: WindowToken) -> Bool {
        entries[token]?.layoutReason == .nativeFullscreen
    }

    func setLayoutReason(_ reason: LayoutReason, for token: WindowToken) {
        guard let entry = entries[token] else { return }
        if reason != .standard, entry.layoutReason == .standard {
            entry.prevParentKind = entry.parentKind
        }
        entry.layoutReason = reason
    }

    func restoreFromNativeState(for token: WindowToken) -> ParentKind? {
        guard let entry = entries[token],
              entry.layoutReason != .standard,
              let prevKind = entry.prevParentKind else { return nil }
        entry.layoutReason = .standard
        entry.parentKind = prevKind
        entry.prevParentKind = nil
        return prevKind
    }

    @discardableResult
    func removeMissing(keys activeKeys: Set<WindowKey>, requiredConsecutiveMisses: Int = 1) -> [Entry] {
        let threshold = max(1, requiredConsecutiveMisses)
        let knownTokens = Array(entries.keys)
        var removedEntries: [Entry] = []

        for token in knownTokens where activeKeys.contains(token) {
            missingDetectionCountByToken.removeValue(forKey: token)
        }

        let missingTokens = knownTokens.filter { !activeKeys.contains($0) }
        var confirmedMissing: [WindowToken] = []
        confirmedMissing.reserveCapacity(missingTokens.count)

        for token in missingTokens {
            if entries[token]?.layoutReason == .nativeFullscreen {
                missingDetectionCountByToken.removeValue(forKey: token)
                continue
            }
            let misses = (missingDetectionCountByToken[token] ?? 0) + 1
            if misses >= threshold {
                confirmedMissing.append(token)
                missingDetectionCountByToken.removeValue(forKey: token)
            } else {
                missingDetectionCountByToken[token] = misses
            }
        }

        for token in confirmedMissing {
            if let entry = entries[token] {
                removedEntries.append(entry)
                removeToken(token, from: entry.workspaceId)
            }
            entries.removeValue(forKey: token)
        }

        if !missingDetectionCountByToken.isEmpty {
            missingDetectionCountByToken = missingDetectionCountByToken.filter { entries[$0.key] != nil }
        }

        return removedEntries
    }

    @discardableResult
    func removeWindow(key: WindowKey) -> Entry? {
        missingDetectionCountByToken.removeValue(forKey: key)
        guard let entry = entries[key] else { return nil }
        removeToken(key, from: entry.workspaceId)
        entries.removeValue(forKey: key)
        return entry
    }

    func cachedConstraints(for token: WindowToken, maxAge: TimeInterval = 5.0) -> WindowSizeConstraints? {
        guard let entry = entries[token],
              let cached = entry.cachedConstraints,
              let cacheTime = entry.constraintsCacheTime,
              Date().timeIntervalSince(cacheTime) < maxAge
        else {
            return nil
        }
        return cached
    }

    func setCachedConstraints(_ constraints: WindowSizeConstraints, for token: WindowToken) {
        guard let entry = entries[token] else { return }
        entry.cachedConstraints = constraints
        entry.constraintsCacheTime = Date()
    }
}
