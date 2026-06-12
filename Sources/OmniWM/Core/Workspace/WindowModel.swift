import CoreGraphics
import Foundation

enum TrackedWindowMode: Equatable, Hashable, Sendable {
    case tiling
    case floating
}

struct ManagedReplacementMetadata: Equatable, Sendable {
    var bundleId: String?
    var workspaceId: WorkspaceDescriptor.ID
    var mode: TrackedWindowMode
    var role: String?
    var subrole: String?
    var title: String?
    var windowLevel: Int32?
    var parentWindowId: UInt32?
    var frame: CGRect?
    var transientWindowServerEvidence = false
    var degradedWindowServerChildEvidence = false

    func mergingNonNilValues(from overlay: ManagedReplacementMetadata) -> ManagedReplacementMetadata {
        ManagedReplacementMetadata(
            bundleId: overlay.bundleId ?? bundleId,
            workspaceId: overlay.workspaceId,
            mode: overlay.mode,
            role: overlay.role ?? role,
            subrole: overlay.subrole ?? subrole,
            title: overlay.title ?? title,
            windowLevel: overlay.windowLevel ?? windowLevel,
            parentWindowId: overlay.parentWindowId ?? parentWindowId,
            frame: overlay.frame ?? frame,
            transientWindowServerEvidence: transientWindowServerEvidence || overlay.transientWindowServerEvidence,
            degradedWindowServerChildEvidence: degradedWindowServerChildEvidence
                || overlay.degradedWindowServerChildEvidence
        )
    }
}

final class WindowModel {
    typealias WindowKey = WindowToken

    private struct WorkspaceModeKey: Hashable {
        let workspaceId: WorkspaceDescriptor.ID
        let mode: TrackedWindowMode
    }

    enum HiddenReason: Equatable {
        case workspaceInactive
        case layoutTransient(HideSide)
        case scratchpad
    }

    struct HiddenState: Equatable {
        let proportionalPosition: CGPoint
        let referenceMonitorId: Monitor.ID?
        let reason: HiddenReason

        var workspaceInactive: Bool {
            if case .workspaceInactive = reason {
                return true
            }
            return false
        }

        var offscreenSide: HideSide? {
            if case let .layoutTransient(side) = reason {
                return side
            }
            return nil
        }

        var isScratchpad: Bool {
            if case .scratchpad = reason {
                return true
            }
            return false
        }

        var restoresViaFloatingState: Bool {
            switch reason {
            case .workspaceInactive,
                 .scratchpad:
                true
            case .layoutTransient:
                false
            }
        }

        init(
            proportionalPosition: CGPoint,
            referenceMonitorId: Monitor.ID?,
            reason: HiddenReason
        ) {
            self.proportionalPosition = proportionalPosition
            self.referenceMonitorId = referenceMonitorId
            self.reason = reason
        }

        init(
            proportionalPosition: CGPoint,
            referenceMonitorId: Monitor.ID?,
            workspaceInactive: Bool,
            offscreenSide: HideSide? = nil
        ) {
            self.proportionalPosition = proportionalPosition
            self.referenceMonitorId = referenceMonitorId
            if workspaceInactive {
                reason = .workspaceInactive
            } else if let offscreenSide {
                reason = .layoutTransient(offscreenSide)
            } else {
                reason = .scratchpad
            }
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
        var token: WindowToken
        var axRef: AXWindowRef
        var workspaceId: WorkspaceDescriptor.ID
        var mode: TrackedWindowMode
        var lifecyclePhase: WindowLifecyclePhase
        var observedState: ObservedWindowState
        var desiredState: DesiredWindowState
        var restoreIntent: RestoreIntent?
        var replacementCorrelation: ReplacementCorrelation?
        var managedReplacementMetadata: ManagedReplacementMetadata?
        var floatingState: FloatingState?
        var manualLayoutOverride: ManualWindowOverride?
        var ruleEffects: ManagedWindowRuleEffects = .none
        var hiddenState: HiddenState?
        var layoutReason: LayoutReason = .standard

        var pid: pid_t {
            token.pid
        }

        var windowId: Int {
            token.windowId
        }

        init(
            token: WindowToken,
            axRef: AXWindowRef,
            workspaceId: WorkspaceDescriptor.ID,
            mode: TrackedWindowMode,
            managedReplacementMetadata: ManagedReplacementMetadata?,
            ruleEffects: ManagedWindowRuleEffects
        ) {
            self.token = token
            self.axRef = axRef
            self.workspaceId = workspaceId
            self.mode = mode
            lifecyclePhase = mode == .floating ? .floating : .tiled
            observedState = .initial(
                workspaceId: workspaceId,
                monitorId: nil
            )
            desiredState = .initial(
                workspaceId: workspaceId,
                monitorId: nil,
                disposition: mode
            )
            self.managedReplacementMetadata = managedReplacementMetadata
            self.ruleEffects = ruleEffects
        }
    }

    private struct ConstraintsCacheRecord {
        let constraints: WindowSizeConstraints
        let cachedAt: Date
    }

    private(set) var entries: [WindowToken: Entry] = [:]
    private var entryByWindowId: [Int: Entry] = [:]
    private var handleByToken: [WindowToken: WindowHandle] = [:]
    private var constraintsCacheByToken: [WindowToken: ConstraintsCacheRecord] = [:]
    private var observedMinSizeByToken: [WindowToken: CGSize] = [:]
    private var tokensByWorkspace: [WorkspaceDescriptor.ID: [WindowToken]] = [:]
    private var tokenIndexByWorkspace: [WorkspaceDescriptor.ID: [WindowToken: Int]] = [:]
    private var tokensByWorkspaceMode: [WorkspaceModeKey: [WindowToken]] = [:]
    private var tokenIndexByWorkspaceMode: [WorkspaceModeKey: [WindowToken: Int]] = [:]
    private var tokensByPid: [pid_t: [WindowToken]] = [:]
    private var tokenIndexByPid: [pid_t: [WindowToken: Int]] = [:]
    private var missingDetectionCountByToken: [WindowToken: Int] = [:]

    private func appendToken<Key: Hashable>(
        _ token: WindowToken,
        to key: Key,
        tokensByKey: inout [Key: [WindowToken]],
        tokenIndexByKey: inout [Key: [WindowToken: Int]]
    ) {
        var tokens = tokensByKey[key, default: []]
        var indexByToken = tokenIndexByKey[key, default: [:]]
        guard indexByToken[token] == nil else { return }
        indexByToken[token] = tokens.count
        tokens.append(token)
        tokensByKey[key] = tokens
        tokenIndexByKey[key] = indexByToken
    }

    private func removeToken<Key: Hashable>(
        _ token: WindowToken,
        from key: Key,
        tokensByKey: inout [Key: [WindowToken]],
        tokenIndexByKey: inout [Key: [WindowToken: Int]]
    ) {
        guard var tokens = tokensByKey[key],
              var indexByToken = tokenIndexByKey[key],
              let index = indexByToken[token] else { return }

        tokens.remove(at: index)
        indexByToken.removeValue(forKey: token)

        if index < tokens.count {
            for i in index ..< tokens.count {
                indexByToken[tokens[i]] = i
            }
        }

        if tokens.isEmpty {
            tokensByKey.removeValue(forKey: key)
            tokenIndexByKey.removeValue(forKey: key)
        } else {
            tokensByKey[key] = tokens
            tokenIndexByKey[key] = indexByToken
        }
    }

    private func replaceToken<Key: Hashable>(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        in key: Key,
        tokensByKey: inout [Key: [WindowToken]],
        tokenIndexByKey: inout [Key: [WindowToken: Int]]
    ) {
        guard var tokens = tokensByKey[key],
              var indexByToken = tokenIndexByKey[key],
              let index = indexByToken.removeValue(forKey: oldToken)
        else {
            return
        }

        tokens[index] = newToken
        indexByToken[newToken] = index
        tokensByKey[key] = tokens
        tokenIndexByKey[key] = indexByToken
    }

    private func appendIndexes(for entry: Entry) {
        let token = entry.token
        entryByWindowId[entry.windowId] = entry
        appendToken(
            token,
            to: entry.workspaceId,
            tokensByKey: &tokensByWorkspace,
            tokenIndexByKey: &tokenIndexByWorkspace
        )
        appendToken(
            token,
            to: WorkspaceModeKey(workspaceId: entry.workspaceId, mode: entry.mode),
            tokensByKey: &tokensByWorkspaceMode,
            tokenIndexByKey: &tokenIndexByWorkspaceMode
        )
        appendToken(token, to: entry.pid, tokensByKey: &tokensByPid, tokenIndexByKey: &tokenIndexByPid)
    }

    private func removeIndexes(for entry: Entry, token: WindowToken? = nil, windowId: Int? = nil) {
        let token = token ?? entry.token
        let windowId = windowId ?? entry.windowId

        entryByWindowId.removeValue(forKey: windowId)
        removeToken(
            token,
            from: entry.workspaceId,
            tokensByKey: &tokensByWorkspace,
            tokenIndexByKey: &tokenIndexByWorkspace
        )
        removeToken(
            token,
            from: WorkspaceModeKey(workspaceId: entry.workspaceId, mode: entry.mode),
            tokensByKey: &tokensByWorkspaceMode,
            tokenIndexByKey: &tokenIndexByWorkspaceMode
        )
        removeToken(token, from: token.pid, tokensByKey: &tokensByPid, tokenIndexByKey: &tokenIndexByPid)
    }

    private func rekeyIndexes(for entry: Entry, from oldToken: WindowToken, to newToken: WindowToken) {
        entryByWindowId.removeValue(forKey: oldToken.windowId)
        entryByWindowId[newToken.windowId] = entry

        replaceToken(
            from: oldToken,
            to: newToken,
            in: entry.workspaceId,
            tokensByKey: &tokensByWorkspace,
            tokenIndexByKey: &tokenIndexByWorkspace
        )
        replaceToken(
            from: oldToken,
            to: newToken,
            in: WorkspaceModeKey(workspaceId: entry.workspaceId, mode: entry.mode),
            tokensByKey: &tokensByWorkspaceMode,
            tokenIndexByKey: &tokenIndexByWorkspaceMode
        )

        if oldToken.pid == newToken.pid {
            replaceToken(
                from: oldToken,
                to: newToken,
                in: oldToken.pid,
                tokensByKey: &tokensByPid,
                tokenIndexByKey: &tokenIndexByPid
            )
        } else {
            removeToken(oldToken, from: oldToken.pid, tokensByKey: &tokensByPid, tokenIndexByKey: &tokenIndexByPid)
            appendToken(newToken, to: newToken.pid, tokensByKey: &tokensByPid, tokenIndexByKey: &tokenIndexByPid)
        }
    }

    @discardableResult
    func upsert(
        window: AXWindowRef,
        pid: pid_t,
        windowId: Int,
        workspace: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode = .tiling,
        ruleEffects: ManagedWindowRuleEffects = .none,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> WindowToken {
        let token = WindowToken(pid: pid, windowId: windowId)
        if let entry = entries[token] {
            entry.axRef = window
            updateWorkspace(for: token, workspace: workspace)
            setMode(mode, for: token)
            if let managedReplacementMetadata {
                entry.managedReplacementMetadata = managedReplacementMetadata
            }
            if entry.ruleEffects != ruleEffects {
                entry.ruleEffects = ruleEffects
                constraintsCacheByToken.removeValue(forKey: token)
            }
            missingDetectionCountByToken.removeValue(forKey: token)
            return token
        }

        let entry = Entry(
            token: token,
            axRef: window,
            workspaceId: workspace,
            mode: mode,
            managedReplacementMetadata: managedReplacementMetadata,
            ruleEffects: ruleEffects
        )
        entries[token] = entry
        handleByToken[token] = WindowHandle(id: token)
        appendIndexes(for: entry)
        missingDetectionCountByToken.removeValue(forKey: token)
        return token
    }

    @discardableResult
    func rekeyWindow(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        newAXRef: AXWindowRef,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> Entry? {
        if oldToken == newToken {
            guard let entry = entries[oldToken] else { return nil }
            entry.axRef = newAXRef
            constraintsCacheByToken.removeValue(forKey: oldToken)
            if let managedReplacementMetadata {
                entry.managedReplacementMetadata = managedReplacementMetadata
            }
            return entry
        }

        guard entries[newToken] == nil,
              let entry = entries.removeValue(forKey: oldToken)
        else {
            return nil
        }

        entry.token = newToken
        entry.axRef = newAXRef
        constraintsCacheByToken.removeValue(forKey: oldToken)
        if let minSize = observedMinSizeByToken.removeValue(forKey: oldToken) {
            observedMinSizeByToken[newToken] = minSize
        }
        if let handle = handleByToken.removeValue(forKey: oldToken) {
            handle.id = newToken
            handleByToken[newToken] = handle
        }
        if let managedReplacementMetadata {
            entry.managedReplacementMetadata = managedReplacementMetadata
        }
        entries[newToken] = entry
        rekeyIndexes(for: entry, from: oldToken, to: newToken)

        if let missingCount = missingDetectionCountByToken.removeValue(forKey: oldToken) {
            missingDetectionCountByToken[newToken] = missingCount
        }

        return entry
    }

    func handle(for token: WindowToken) -> WindowHandle? {
        handleByToken[token]
    }

    func updateWorkspace(for token: WindowToken, workspace: WorkspaceDescriptor.ID) {
        guard let entry = entries[token] else { return }
        let oldWorkspace = entry.workspaceId
        if oldWorkspace != workspace {
            removeToken(
                token,
                from: oldWorkspace,
                tokensByKey: &tokensByWorkspace,
                tokenIndexByKey: &tokenIndexByWorkspace
            )
            removeToken(
                token,
                from: WorkspaceModeKey(workspaceId: oldWorkspace, mode: entry.mode),
                tokensByKey: &tokensByWorkspaceMode,
                tokenIndexByKey: &tokenIndexByWorkspaceMode
            )
            appendToken(token, to: workspace, tokensByKey: &tokensByWorkspace, tokenIndexByKey: &tokenIndexByWorkspace)
            appendToken(
                token,
                to: WorkspaceModeKey(workspaceId: workspace, mode: entry.mode),
                tokensByKey: &tokensByWorkspaceMode,
                tokenIndexByKey: &tokenIndexByWorkspaceMode
            )
        }
        entry.workspaceId = workspace
    }

    func windows(in workspace: WorkspaceDescriptor.ID) -> [Entry] {
        guard let tokens = tokensByWorkspace[workspace] else { return [] }
        return tokens.compactMap { entries[$0] }
    }

    func windows(
        in workspace: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode
    ) -> [Entry] {
        let key = WorkspaceModeKey(workspaceId: workspace, mode: mode)
        guard let tokens = tokensByWorkspaceMode[key] else { return [] }
        return tokens.compactMap { entries[$0] }
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
        guard let tokens = tokensByPid[pid] else { return [] }
        return tokens.compactMap { entries[$0] }
    }

    func entry(forWindowId windowId: Int) -> Entry? {
        entryByWindowId[windowId]
    }

    func entry(forWindowId windowId: Int, inVisibleWorkspaces visibleIds: Set<WorkspaceDescriptor.ID>) -> Entry? {
        guard let entry = entryByWindowId[windowId],
              visibleIds.contains(entry.workspaceId) else { return nil }
        return entry
    }

    func allEntries() -> [Entry] {
        Array(entries.values)
    }

    func allEntries(mode: TrackedWindowMode) -> [Entry] {
        tokensByWorkspaceMode
            .filter { $0.key.mode == mode }
            .values
            .flatMap { $0.compactMap { entries[$0] } }
    }

    func mode(for token: WindowToken) -> TrackedWindowMode? {
        entries[token]?.mode
    }

    func setMode(_ mode: TrackedWindowMode, for token: WindowToken) {
        guard let entry = entries[token], entry.mode != mode else { return }
        let oldMode = entry.mode
        removeToken(
            token,
            from: WorkspaceModeKey(workspaceId: entry.workspaceId, mode: oldMode),
            tokensByKey: &tokensByWorkspaceMode,
            tokenIndexByKey: &tokenIndexByWorkspaceMode
        )
        entry.mode = mode
        appendToken(
            token,
            to: WorkspaceModeKey(workspaceId: entry.workspaceId, mode: mode),
            tokensByKey: &tokensByWorkspaceMode,
            tokenIndexByKey: &tokenIndexByWorkspaceMode
        )
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

    func lifecyclePhase(for token: WindowToken) -> WindowLifecyclePhase? {
        entries[token]?.lifecyclePhase
    }

    func setLifecyclePhase(_ phase: WindowLifecyclePhase, for token: WindowToken) {
        entries[token]?.lifecyclePhase = phase
    }

    func observedState(for token: WindowToken) -> ObservedWindowState? {
        entries[token]?.observedState
    }

    func setObservedState(_ state: ObservedWindowState, for token: WindowToken) {
        entries[token]?.observedState = state
    }

    func desiredState(for token: WindowToken) -> DesiredWindowState? {
        entries[token]?.desiredState
    }

    func setDesiredState(_ state: DesiredWindowState, for token: WindowToken) {
        entries[token]?.desiredState = state
    }

    func restoreIntent(for token: WindowToken) -> RestoreIntent? {
        entries[token]?.restoreIntent
    }

    func setRestoreIntent(_ intent: RestoreIntent?, for token: WindowToken) {
        entries[token]?.restoreIntent = intent
    }

    func replacementCorrelation(for token: WindowToken) -> ReplacementCorrelation? {
        entries[token]?.replacementCorrelation
    }

    func setReplacementCorrelation(_ correlation: ReplacementCorrelation?, for token: WindowToken) {
        entries[token]?.replacementCorrelation = correlation
    }

    func managedReplacementMetadata(for token: WindowToken) -> ManagedReplacementMetadata? {
        entries[token]?.managedReplacementMetadata
    }

    func setManagedReplacementMetadata(_ metadata: ManagedReplacementMetadata?, for token: WindowToken) {
        entries[token]?.managedReplacementMetadata = metadata
    }

    func setHiddenState(_ state: HiddenState?, for token: WindowToken) {
        entries[token]?.hiddenState = state
    }

    func hiddenState(for token: WindowToken) -> HiddenState? {
        entries[token]?.hiddenState
    }

    func isHiddenInCorner(_ token: WindowToken) -> Bool {
        entries[token]?.hiddenState != nil
    }

    func layoutReason(for token: WindowToken) -> LayoutReason {
        entries[token]?.layoutReason ?? .standard
    }

    func isNativeFullscreenSuspended(_ token: WindowToken) -> Bool {
        entries[token]?.layoutReason == .nativeFullscreen
    }

    func setLayoutReason(_ reason: LayoutReason, for token: WindowToken) {
        entries[token]?.layoutReason = reason
    }

    @discardableResult
    func restoreFromNativeState(for token: WindowToken) -> Bool {
        guard let entry = entries[token],
              entry.layoutReason != .standard
        else { return false }
        entry.layoutReason = .standard
        return true
    }

    func confirmedMissingKeys(keys activeKeys: Set<WindowKey>, requiredConsecutiveMisses: Int = 1) -> [WindowKey] {
        let threshold = max(1, requiredConsecutiveMisses)
        let knownTokens = Array(entries.keys)

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

        if !missingDetectionCountByToken.isEmpty {
            missingDetectionCountByToken = missingDetectionCountByToken.filter { entries[$0.key] != nil }
        }

        return confirmedMissing
    }

    @discardableResult
    func removeWindow(key: WindowKey) -> Entry? {
        missingDetectionCountByToken.removeValue(forKey: key)
        handleByToken.removeValue(forKey: key)
        constraintsCacheByToken.removeValue(forKey: key)
        observedMinSizeByToken.removeValue(forKey: key)
        guard let entry = entries[key] else { return nil }
        removeIndexes(for: entry, token: key, windowId: key.windowId)
        entries.removeValue(forKey: key)
        return entry
    }

    func cachedConstraints(for token: WindowToken, maxAge: TimeInterval = 5.0) -> WindowSizeConstraints? {
        guard let record = constraintsCacheByToken[token],
              Date().timeIntervalSince(record.cachedAt) < maxAge
        else {
            return nil
        }
        return record.constraints
    }

    func setCachedConstraints(_ constraints: WindowSizeConstraints, for token: WindowToken) {
        guard entries[token] != nil else { return }
        constraintsCacheByToken[token] = ConstraintsCacheRecord(
            constraints: constraints.normalized(),
            cachedAt: Date()
        )
    }

    func observedMinSize(for token: WindowToken) -> CGSize? {
        observedMinSizeByToken[token]
    }

    func setObservedMinSize(_ size: CGSize, for token: WindowToken) -> Bool {
        guard entries[token] != nil else { return false }
        if let existing = observedMinSizeByToken[token],
           abs(existing.width - size.width) <= FrameTolerance.frameWrite,
           abs(existing.height - size.height) <= FrameTolerance.frameWrite
        {
            return false
        }
        observedMinSizeByToken[token] = size
        return true
    }
}
