import AppKit
import Foundation

@MainActor
final class AXEventHandler: CGSEventDelegate {
    struct DebugCounters {
        var geometryRelayoutRequests = 0
        var geometryRelayoutsSuppressedDuringGesture = 0
    }

    private struct PreparedCreate {
        let windowId: UInt32
        let token: WindowToken
        let bundleId: String?
        let axRef: AXWindowRef
        let workspaceId: WorkspaceDescriptor.ID
        let mode: TrackedWindowMode
        let ruleEffects: ManagedWindowRuleEffects
    }

    private struct PreparedDestroy {
        let token: WindowToken
        let bundleId: String?
        let workspaceId: WorkspaceDescriptor.ID
    }

    private struct GhosttyReplacementKey: Hashable {
        let pid: pid_t
        let workspaceId: WorkspaceDescriptor.ID
    }

    private struct PendingGhosttyCreate {
        let sequence: UInt64
        let candidate: PreparedCreate
    }

    private struct PendingGhosttyDestroy {
        let sequence: UInt64
        let candidate: PreparedDestroy
    }

    private enum PendingGhosttyEvent {
        case create(PendingGhosttyCreate)
        case destroy(PendingGhosttyDestroy)

        var sequence: UInt64 {
            switch self {
            case let .create(create): create.sequence
            case let .destroy(destroy): destroy.sequence
            }
        }
    }

    private struct PendingGhosttyReplacementBurst {
        var creates: [PendingGhosttyCreate] = []
        var destroys: [PendingGhosttyDestroy] = []

        mutating func append(create: PendingGhosttyCreate) {
            guard !creates.contains(where: { $0.candidate.token == create.candidate.token }) else { return }
            creates.append(create)
        }

        mutating func append(destroy: PendingGhosttyDestroy) {
            guard !destroys.contains(where: { $0.candidate.token == destroy.candidate.token }) else { return }
            destroys.append(destroy)
        }

        var orderedEvents: [PendingGhosttyEvent] {
            let events = creates.map(PendingGhosttyEvent.create) + destroys.map(PendingGhosttyEvent.destroy)
            return events.sorted { $0.sequence < $1.sequence }
        }

        var hasSingleReplacementPair: Bool {
            creates.count == 1 && destroys.count == 1
        }
    }

    private static let ghosttyBundleId = "com.mitchellh.ghostty"
    private static let ghosttyReplacementGraceDelay: Duration = .milliseconds(150)
    private static let nativeFullscreenReplacementGraceDelay: Duration = .seconds(1)

    weak var controller: WMController?
    private var deferredCreatedWindowIds: Set<UInt32> = []
    private var deferredCreatedWindowOrder: [UInt32] = []
    private var pendingGhosttyReplacementBursts: [GhosttyReplacementKey: PendingGhosttyReplacementBurst] = [:]
    private var pendingGhosttyReplacementTasks: [GhosttyReplacementKey: Task<Void, Never>] = [:]
    private var pendingNativeFullscreenReplacementTasks: [WindowToken: Task<Void, Never>] = [:]
    private var pendingWindowRuleReevaluationTask: Task<Void, Never>?
    private var pendingWindowRuleReevaluationTargets: Set<WindowRuleReevaluationTarget> = []
    private var nextGhosttyEventSequence: UInt64 = 0
    var windowInfoProvider: ((UInt32) -> WindowServerInfo?)?
    var axWindowRefProvider: ((UInt32, pid_t) -> AXWindowRef?)?
    var bundleIdProvider: ((pid_t) -> String?)?
    var windowSubscriptionHandler: (([UInt32]) -> Void)?
    var focusedWindowValueProvider: ((pid_t) -> CFTypeRef?)?
    var windowFactsProvider: ((AXWindowRef, pid_t) -> WindowRuleFacts?)?
    var frameProvider: ((AXWindowRef) -> CGRect?)?
    var fastFrameProvider: ((AXWindowRef) -> CGRect?)?
    var isFullscreenProvider: ((AXWindowRef) -> Bool)?
    private(set) var debugCounters = DebugCounters()

    init(
        controller: WMController
    ) {
        self.controller = controller
    }

    func setup() {
        CGSEventObserver.shared.delegate = self
        CGSEventObserver.shared.start()
    }

    func cleanup() {
        resetGhosttyReplacementState()
        resetNativeFullscreenReplacementState()
        pendingWindowRuleReevaluationTask?.cancel()
        pendingWindowRuleReevaluationTask = nil
        pendingWindowRuleReevaluationTargets.removeAll()
        CGSEventObserver.shared.delegate = nil
        CGSEventObserver.shared.stop()
    }

    func cgsEventObserver(_: CGSEventObserver, didReceive event: CGSWindowEvent) {
        guard let controller else { return }

        switch event {
        case let .created(windowId, _):
            handleCGSWindowCreated(windowId: windowId)

        case let .destroyed(windowId, _):
            handleCGSWindowDestroyed(windowId: windowId)

        case let .closed(windowId):
            handleCGSWindowDestroyed(windowId: windowId)

        case let .frameChanged(windowId):
            handleFrameChanged(windowId: windowId)

        case let .frontAppChanged(pid):
            handleAppActivation(pid: pid)

        case let .titleChanged(windowId):
            controller.requestWorkspaceBarRefresh()
            if let token = resolveWindowToken(windowId) ?? resolveTrackedToken(windowId) {
                scheduleWindowRuleReevaluationIfNeeded(targets: [.window(token)])
            }
        }
    }

    private func scheduleWindowRuleReevaluationIfNeeded(
        targets: Set<WindowRuleReevaluationTarget>
    ) {
        guard let controller,
              controller.windowRuleEngine.needsWindowReevaluation,
              !targets.isEmpty
        else {
            return
        }

        pendingWindowRuleReevaluationTargets.formUnion(targets)
        pendingWindowRuleReevaluationTask?.cancel()
        pendingWindowRuleReevaluationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(25))
            guard let self, let controller = self.controller else { return }
            let targets = self.pendingWindowRuleReevaluationTargets
            self.pendingWindowRuleReevaluationTargets.removeAll()
            _ = await controller.reevaluateWindowRules(for: targets)
        }
    }

    private func isWindowDisplayable(token: WindowToken) -> Bool {
        guard let controller else { return false }
        guard let entry = controller.workspaceManager.entry(for: token) else {
            return false
        }
        return controller.isManagedWindowDisplayable(entry.handle)
    }

    private func handleCGSWindowCreated(windowId: UInt32) {
        guard let controller else { return }
        if controller.isDiscoveryInProgress {
            deferCreatedWindow(windowId)
            return
        }

        let windowInfo = resolveWindowInfo(windowId)
        guard let candidate = prepareCreateCandidate(
            windowId: windowId,
            windowInfo: windowInfo
        ) else {
            if let windowInfo {
                scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(pid_t(windowInfo.pid))])
            }
            return
        }

        if shouldDelayGhosttyLifecycle(for: candidate.token.pid, bundleId: candidate.bundleId) {
            enqueueGhosttyCreate(candidate)
            return
        }

        trackPreparedCreate(candidate)
    }

    func resetDebugStateForTests() {
        debugCounters = .init()
        resetGhosttyReplacementState()
        resetNativeFullscreenReplacementState()
        pendingWindowRuleReevaluationTask?.cancel()
        pendingWindowRuleReevaluationTask = nil
        pendingWindowRuleReevaluationTargets.removeAll()
    }

    private func handleFrameChanged(windowId: UInt32) {
        guard let controller else { return }
        guard let token = resolveTrackedToken(windowId) else { return }
        guard let entry = controller.workspaceManager.entry(for: token) else { return }

        updateFocusedBorderForFrameChange(token: token)

        guard isWindowDisplayable(token: token) else {
            return
        }

        if entry.mode == .floating {
            if let frame = frameProvider?(entry.axRef)
                ?? fastFrameProvider?(entry.axRef)
                ?? AXWindowService.framePreferFast(entry.axRef)
                ?? (try? AXWindowService.frame(entry.axRef))
            {
                controller.workspaceManager.updateFloatingGeometry(frame: frame, for: token)
            }
            return
        }

        if controller.isInteractiveGestureActive {
            debugCounters.geometryRelayoutsSuppressedDuringGesture += 1
            return
        }

        debugCounters.geometryRelayoutRequests += 1
        controller.layoutRefreshController.requestRelayout(reason: .axWindowChanged)
    }

    private func updateFocusedBorderForFrameChange(token: WindowToken) {
        guard let controller else { return }
        guard controller.workspaceManager.focusedToken == token,
              let entry = controller.workspaceManager.entry(for: token)
        else { return }

        if let frame = frameProvider?(entry.axRef)
            ?? fastFrameProvider?(entry.axRef)
            ?? AXWindowService.framePreferFast(entry.axRef)
            ?? (try? AXWindowService.frame(entry.axRef))
        {
            controller.borderCoordinator.updateBorderIfAllowed(token: token, frame: frame, windowId: entry.windowId)
        }
    }

    private func handleCGSWindowDestroyed(windowId: UInt32) {
        removeDeferredCreatedWindow(windowId)
        handleWindowDestroyed(windowId: windowId, pidHint: nil)
    }

    func subscribeToManagedWindows() {
        guard let controller else { return }
        let windowIds = controller.workspaceManager.allEntries().compactMap { entry -> UInt32? in
            UInt32(entry.windowId)
        }
        subscribeToWindows(windowIds)
    }

    func drainDeferredCreatedWindows() async {
        guard !deferredCreatedWindowOrder.isEmpty else { return }

        let deferredWindowIds = deferredCreatedWindowOrder
        deferredCreatedWindowOrder.removeAll()
        deferredCreatedWindowIds.removeAll()

        for windowId in deferredWindowIds {
            guard let controller else { return }
            guard let token = resolveWindowToken(windowId) else {
                continue
            }
            if controller.workspaceManager.entry(for: token) != nil {
                continue
            }
            guard let candidate = prepareCreateCandidate(
                windowId: windowId,
                windowInfo: resolveWindowInfo(windowId)
            ) else {
                continue
            }
            trackPreparedCreate(candidate)
        }
    }

    private func trackPreparedCreate(_ candidate: PreparedCreate) {
        guard let controller else { return }

        if restoreNativeFullscreenReplacementIfNeeded(
            token: candidate.token,
            windowId: candidate.windowId,
            axRef: candidate.axRef,
            workspaceId: candidate.workspaceId,
            appFullscreen: isFullscreenProvider?(candidate.axRef) ?? AXWindowService.isFullscreen(candidate.axRef)
        ) {
            controller.layoutRefreshController.requestRelayout(reason: .axWindowCreated)
            return
        }

        if candidate.workspaceId != controller.activeWorkspace()?.id {
            if let monitor = controller.workspaceManager.monitor(for: candidate.workspaceId),
               controller.workspaceManager.workspaces(on: monitor.id)
               .contains(where: { $0.id == candidate.workspaceId })
            {
                _ = controller.workspaceManager.setActiveWorkspace(candidate.workspaceId, on: monitor.id)
            }
        }

        _ = controller.workspaceManager.addWindow(
            candidate.axRef,
            pid: candidate.token.pid,
            windowId: candidate.token.windowId,
            to: candidate.workspaceId,
            mode: candidate.mode,
            ruleEffects: candidate.ruleEffects
        )

        if candidate.mode == .floating,
           let frame = frameProvider?(candidate.axRef)
            ?? fastFrameProvider?(candidate.axRef)
            ?? AXWindowService.framePreferFast(candidate.axRef)
            ?? (try? AXWindowService.frame(candidate.axRef))
        {
            controller.workspaceManager.updateFloatingGeometry(
                frame: frame,
                for: candidate.token,
                referenceMonitor: controller.workspaceManager.monitor(for: candidate.workspaceId)
            )
        }

        Task { @MainActor [weak self] in
            guard let self, let controller = self.controller else { return }
            if let app = NSRunningApplication(processIdentifier: candidate.token.pid) {
                _ = await controller.axManager.windowsForApp(app)
            }
        }

        controller.layoutRefreshController.requestRelayout(reason: .axWindowCreated)
        scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(candidate.token.pid)])
    }

    func handleRemoved(pid: pid_t, winId: Int) {
        guard let windowId = UInt32(exactly: winId) else { return }
        removeDeferredCreatedWindow(windowId)
        handleWindowDestroyed(windowId: windowId, pidHint: pid)
    }

    func handleRemoved(token: WindowToken) {
        guard let controller else { return }
        let entry = controller.workspaceManager.entry(for: token)
        let affectedWorkspaceId = entry?.workspaceId
        let removedHandle = entry?.handle

        if let removed = removedHandle {
            controller.focusCoordinator.discardPendingFocus(removed.id)
        }

        if handleNativeFullscreenDestroy(token) {
            return
        }

        let shouldRecoverFocus = token == controller.workspaceManager.focusedToken
        let layoutType = affectedWorkspaceId
            .flatMap { controller.workspaceManager.descriptor(for: $0)?.name }
            .map { controller.settings.layoutType(for: $0) } ?? .defaultLayout

        if let entry,
           let wsId = affectedWorkspaceId,
           let monitor = controller.workspaceManager.monitor(for: wsId),
           controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == wsId,
           layoutType != .dwindle
        {
           let shouldAnimate = if let engine = controller.niriEngine,
                                    let windowNode = engine.findNode(for: token)
            {
                !windowNode.isHiddenInTabbedMode
            } else {
                true
            }
            if shouldAnimate {
                controller.layoutRefreshController.startWindowCloseAnimation(
                    entry: entry,
                    monitor: monitor
                )
            }
        }

        var oldFrames: [WindowToken: CGRect] = [:]
        var removedNodeId: NodeId?
        if let wsId = affectedWorkspaceId, layoutType != .dwindle, let engine = controller.niriEngine {
            oldFrames = engine.captureWindowFrames(in: wsId)
            removedNodeId = engine.findNode(for: token)?.id
        }

        _ = controller.workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
        controller.clearManualWindowOverride(for: token)

        if let wsId = affectedWorkspaceId {
            controller.layoutRefreshController.requestWindowRemoval(
                workspaceId: wsId,
                layoutType: layoutType,
                removedNodeId: removedNodeId,
                niriOldFrames: oldFrames,
                shouldRecoverFocus: shouldRecoverFocus
            )
        }
        scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(token.pid)])
    }

    func handleAppActivation(pid: pid_t) {
        guard let controller else { return }
        guard controller.hasStartedServices else { return }

        if pid == getpid(), (controller.hasFrontmostOwnedWindow || controller.hasVisibleOwnedWindow) {
            _ = controller.workspaceManager.enterNonManagedFocus(
                appFullscreen: false,
                preserveFocusedToken: true
            )
            controller.borderManager.hideBorder()
            return
        }

        guard let axRef = resolveFocusedAXWindowRef(pid: pid) else {
            _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: false)
            controller.borderManager.hideBorder()
            return
        }
        let token = WindowToken(pid: pid, windowId: axRef.windowId)

        let appFullscreen = isFullscreenProvider?(axRef) ?? AXWindowService.isFullscreen(axRef)

        if let entry = controller.workspaceManager.entry(for: token) {
            if appFullscreen {
                suspendManagedWindowForNativeFullscreen(entry)
                return
            }
            _ = restoreManagedWindowFromNativeFullscreen(entry)
            let wsId = entry.workspaceId

            let targetMonitor = controller.workspaceManager.monitor(for: wsId)
            let isWorkspaceActive = targetMonitor.map { monitor in
                controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == wsId
            } ?? false

            handleManagedAppActivation(
                entry: entry,
                isWorkspaceActive: isWorkspaceActive,
                appFullscreen: appFullscreen
            )
            return
        }

        if restoreNativeFullscreenReplacementIfNeeded(
            token: token,
            windowId: UInt32(axRef.windowId),
            axRef: axRef,
            workspaceId: controller.activeWorkspace()?.id,
            appFullscreen: appFullscreen
        ),
            let restoredEntry = controller.workspaceManager.entry(for: token)
        {
            let wsId = restoredEntry.workspaceId
            let targetMonitor = controller.workspaceManager.monitor(for: wsId)
            let isWorkspaceActive = targetMonitor.map { monitor in
                controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == wsId
            } ?? false

            handleManagedAppActivation(
                entry: restoredEntry,
                isWorkspaceActive: isWorkspaceActive,
                appFullscreen: appFullscreen
            )
            return
        }

        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: appFullscreen)
        controller.borderManager.hideBorder()
    }

    func handleManagedAppActivation(
        entry: WindowModel.Entry,
        isWorkspaceActive: Bool,
        appFullscreen: Bool
    ) {
        guard let controller else { return }
        if appFullscreen {
            suspendManagedWindowForNativeFullscreen(entry)
            return
        }

        _ = restoreManagedWindowFromNativeFullscreen(entry)
        let wsId = entry.workspaceId
        let monitorId = controller.workspaceManager.monitorId(for: wsId)
        let shouldActivateWorkspace = !isWorkspaceActive && !controller.isTransferringWindow

        _ = controller.workspaceManager.confirmManagedFocus(
            entry.token,
            in: wsId,
            onMonitor: monitorId,
            appFullscreen: appFullscreen,
            activateWorkspaceOnMonitor: shouldActivateWorkspace
        )

        if let engine = controller.niriEngine,
           let node = engine.findNode(for: entry.handle),
           let _ = controller.workspaceManager.monitor(for: wsId)
        {
            var state = controller.workspaceManager.niriViewportState(for: wsId)
            controller.niriLayoutHandler.activateNode(
                node, in: wsId, state: &state,
                options: .init(layoutRefresh: isWorkspaceActive, axFocus: false)
            )
            _ = controller.workspaceManager.applySessionPatch(
                .init(
                    workspaceId: wsId,
                    viewportState: state,
                    rememberedFocusToken: nil
                )
            )

            if let frame = node.renderedFrame ?? node.frame {
                controller.borderCoordinator.updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
            } else if let frame = try? AXWindowService.frame(entry.axRef) {
                controller.borderCoordinator.updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
            }
        } else if let frame = try? AXWindowService.frame(entry.axRef) {
            controller.borderCoordinator.updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
        }
        controller.niriLayoutHandler.updateTabbedColumnOverlays()
        if shouldActivateWorkspace {
            controller.syncMonitorsToNiriEngine()
            controller.layoutRefreshController.commitWorkspaceTransition(
                reason: .appActivationTransition
            )
        }
    }

    func focusedWindowToken(for pid: pid_t) -> WindowToken? {
        guard let axRef = resolveFocusedAXWindowRef(pid: pid) else { return nil }
        return WindowToken(pid: pid, windowId: axRef.windowId)
    }

    @discardableResult
    private func suspendManagedWindowForNativeFullscreen(_ entry: WindowModel.Entry) -> Bool {
        guard let controller else { return false }
        cancelNativeFullscreenReplacementExpiry(containing: entry.token)
        let changed = controller.workspaceManager.markNativeFullscreenSuspended(entry.token)
        controller.borderManager.hideBorder()
        return changed
    }

    @discardableResult
    private func restoreManagedWindowFromNativeFullscreen(_ entry: WindowModel.Entry) -> Bool {
        guard let controller else { return false }
        let hadRecord = controller.workspaceManager.nativeFullscreenRecord(for: entry.token) != nil
        guard hadRecord || controller.workspaceManager.layoutReason(for: entry.token) == .nativeFullscreen else {
            return false
        }
        cancelNativeFullscreenReplacementExpiry(containing: entry.token)
        return controller.workspaceManager.restoreNativeFullscreenRecord(for: entry.token) != nil || hadRecord
    }

    @discardableResult
    func restoreNativeFullscreenReplacementIfNeeded(
        token: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef,
        workspaceId: WorkspaceDescriptor.ID?,
        appFullscreen: Bool
    ) -> Bool {
        guard let controller else { return false }
        guard let record = controller.workspaceManager.nativeFullscreenAwaitingReplacementCandidate(
            for: token.pid,
            activeWorkspaceId: workspaceId
        ) else {
            return false
        }
        guard rekeyManagedWindowIdentity(from: record.currentToken, to: token, windowId: windowId, axRef: axRef) != nil else {
            return false
        }

        cancelNativeFullscreenReplacementExpiry(for: record.originalToken)

        if appFullscreen {
            _ = controller.workspaceManager.markNativeFullscreenSuspended(token)
        } else {
            _ = controller.workspaceManager.restoreNativeFullscreenRecord(for: token)
        }

        return true
    }

    @discardableResult
    func rekeyManagedWindowIdentity(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef
    ) -> WindowModel.Entry? {
        guard let controller,
              let entry = controller.workspaceManager.rekeyWindow(
                  from: oldToken,
                  to: newToken,
                  newAXRef: axRef
              )
        else {
            return nil
        }

        _ = controller.niriEngine?.rekeyWindow(from: oldToken, to: newToken)
        if let workspaceId = controller.workspaceManager.workspace(for: newToken) {
            _ = controller.dwindleEngine?.rekeyWindow(from: oldToken, to: newToken, in: workspaceId)
        }

        controller.focusCoordinator.rekeyPendingFocus(from: oldToken, to: newToken)
        controller.axManager.rekeyWindowState(
            pid: newToken.pid,
            oldWindowId: oldToken.windowId,
            newWindow: axRef
        )
        subscribeToWindows([windowId])
        controller.requestWorkspaceBarRefresh()
        controller.niriLayoutHandler.updateTabbedColumnOverlays()
        refreshBorderAfterManagedRekey(entry: entry)

        Task { @MainActor [weak self] in
            guard let self, let controller = self.controller else { return }
            if let app = NSRunningApplication(processIdentifier: newToken.pid) {
                _ = await controller.axManager.windowsForApp(app)
            }
        }

        return entry
    }

    private func handleNativeFullscreenDestroy(_ token: WindowToken) -> Bool {
        guard let controller,
              let record = controller.workspaceManager.nativeFullscreenRecord(for: token),
              record.currentToken == token,
              record.transition != .awaitingReplacement
        else {
            return false
        }

        let deadline = Date().addingTimeInterval(1)
        guard let awaitingRecord = controller.workspaceManager.markNativeFullscreenAwaitingReplacement(
            token,
            replacementDeadline: deadline
        ) else {
            return false
        }

        controller.borderManager.hideBorder()
        scheduleNativeFullscreenReplacementExpiry(for: awaitingRecord.originalToken)
        return true
    }

    func handleAppHidden(pid: pid_t) {
        guard let controller else { return }
        controller.hiddenAppPIDs.insert(pid)

        for entry in controller.workspaceManager.entries(forPid: pid) {
            controller.workspaceManager.setLayoutReason(.macosHiddenApp, for: entry.token)
        }
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appHidden)
    }

    func handleAppUnhidden(pid: pid_t) {
        guard let controller else { return }
        controller.hiddenAppPIDs.remove(pid)

        for entry in controller.workspaceManager.entries(forPid: pid) {
            if controller.workspaceManager.layoutReason(for: entry.token) == .macosHiddenApp {
                _ = controller.workspaceManager.restoreFromNativeState(for: entry.token)
            }
        }
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appUnhidden)
    }

    func resetGhosttyReplacementState() {
        for (_, task) in pendingGhosttyReplacementTasks {
            task.cancel()
        }
        pendingGhosttyReplacementTasks.removeAll()
        pendingGhosttyReplacementBursts.removeAll()
        nextGhosttyEventSequence = 0
    }

    func flushPendingGhosttyReplacementEventsForTests() {
        let keys = pendingGhosttyReplacementBursts.keys.sorted {
            ($0.pid, $0.workspaceId.uuidString) < ($1.pid, $1.workspaceId.uuidString)
        }
        for key in keys {
            pendingGhosttyReplacementTasks.removeValue(forKey: key)?.cancel()
            flushGhosttyReplacementBurst(for: key)
        }
    }

    private func prepareCreateCandidate(
        windowId: UInt32,
        windowInfo: WindowServerInfo?
    ) -> PreparedCreate? {
        guard let controller else { return nil }
        guard let token = windowInfo.map({ WindowToken(pid: pid_t($0.pid), windowId: Int(windowId)) }) else { return nil }
        if controller.workspaceManager.entry(for: token) != nil { return nil }

        subscribeToWindows([windowId])

        guard let axRef = resolveAXWindowRef(windowId: windowId, pid: token.pid) else { return nil }

        let app = NSRunningApplication(processIdentifier: token.pid)
        let bundleId = resolveBundleId(token.pid) ?? app?.bundleIdentifier
        let appFullscreen = isFullscreenProvider?(axRef) ?? AXWindowService.isFullscreen(axRef)
        let evaluation = controller.evaluateWindowDisposition(
            axRef: axRef,
            pid: token.pid,
            appFullscreen: appFullscreen
        )
        guard let trackedMode = controller.trackedModeForLifecycle(
            decision: evaluation.decision,
            existingEntry: nil
        ) else {
            return nil
        }

        let workspaceId = controller.resolveWorkspaceForNewWindow(
            workspaceName: evaluation.decision.workspaceName,
            axRef: axRef,
            pid: token.pid,
            fallbackWorkspaceId: controller.activeWorkspace()?.id
        )

        return PreparedCreate(
            windowId: windowId,
            token: token,
            bundleId: bundleId,
            axRef: axRef,
            workspaceId: workspaceId,
            mode: trackedMode,
            ruleEffects: evaluation.decision.ruleEffects
        )
    }

    private func prepareDestroyCandidate(
        windowId: UInt32,
        pidHint: pid_t?
    ) -> PreparedDestroy? {
        guard let controller else { return nil }

        let hintedToken = pidHint.flatMap { hintedPid -> WindowToken? in
            let token = WindowToken(pid: hintedPid, windowId: Int(windowId))
            return controller.workspaceManager.entry(for: token) != nil ? token : nil
        }
        let resolvedToken = hintedToken
            ?? resolveTrackedToken(windowId)
            ?? pidHint.map { WindowToken(pid: $0, windowId: Int(windowId)) }

        guard let token = resolvedToken,
              let trackedWorkspaceId = controller.workspaceManager.workspace(for: token) else { return nil }

        return PreparedDestroy(
            token: token,
            bundleId: resolveBundleId(token.pid),
            workspaceId: trackedWorkspaceId
        )
    }

    private func handleWindowDestroyed(
        windowId: UInt32,
        pidHint: pid_t?
    ) {
        let resolvedToken = resolveWindowToken(windowId)
            ?? resolveTrackedToken(windowId)
            ?? pidHint.map { WindowToken(pid: $0, windowId: Int(windowId)) }
        if let resolvedToken {
            controller?.clearManualWindowOverride(for: resolvedToken)
        }

        guard let candidate = prepareDestroyCandidate(windowId: windowId, pidHint: pidHint) else {
            if let resolvedToken {
                scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(resolvedToken.pid)])
            } else if let pid = pidHint ?? resolveWindowInfo(windowId)?.pid {
                scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(pid_t(pid))])
            }
            return
        }

        if shouldDelayGhosttyLifecycle(for: candidate.token.pid, bundleId: candidate.bundleId) {
            enqueueGhosttyDestroy(candidate)
            return
        }

        processPreparedDestroy(candidate)
    }

    private func processPreparedDestroy(_ candidate: PreparedDestroy) {
        handleRemoved(token: candidate.token)
    }

    private func shouldDelayGhosttyLifecycle(for pid: pid_t, bundleId: String?) -> Bool {
        let resolvedBundleId = bundleId ?? resolveBundleId(pid)
        return resolvedBundleId == Self.ghosttyBundleId
    }

    private func enqueueGhosttyCreate(_ candidate: PreparedCreate) {
        let key = GhosttyReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        var burst = pendingGhosttyReplacementBursts[key] ?? PendingGhosttyReplacementBurst()
        let pendingCreate = PendingGhosttyCreate(sequence: nextGhosttySequence(), candidate: candidate)
        burst.append(create: pendingCreate)
        pendingGhosttyReplacementBursts[key] = burst

        if let matchedDestroy = matchedDestroyCandidate(in: burst, for: candidate.token) {
            completeGhosttyReplacement(for: key, destroy: matchedDestroy, create: pendingCreate)
            return
        }

        scheduleGhosttyReplacementFlush(for: key)
    }

    private func enqueueGhosttyDestroy(_ candidate: PreparedDestroy) {
        let key = GhosttyReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        var burst = pendingGhosttyReplacementBursts[key] ?? PendingGhosttyReplacementBurst()
        let pendingDestroy = PendingGhosttyDestroy(sequence: nextGhosttySequence(), candidate: candidate)
        burst.append(destroy: pendingDestroy)
        pendingGhosttyReplacementBursts[key] = burst

        if let matchedCreate = matchedCreateCandidate(in: burst, for: candidate.token) {
            completeGhosttyReplacement(for: key, destroy: pendingDestroy, create: matchedCreate)
            return
        }

        scheduleGhosttyReplacementFlush(for: key)
    }

    private func matchedCreateCandidate(
        in burst: PendingGhosttyReplacementBurst,
        for oldToken: WindowToken
    ) -> PendingGhosttyCreate? {
        guard burst.hasSingleReplacementPair,
              let create = burst.creates.first,
              create.candidate.token != oldToken
        else {
            return nil
        }
        return create
    }

    private func matchedDestroyCandidate(
        in burst: PendingGhosttyReplacementBurst,
        for newToken: WindowToken
    ) -> PendingGhosttyDestroy? {
        guard burst.hasSingleReplacementPair,
              let destroy = burst.destroys.first,
              destroy.candidate.token != newToken
        else {
            return nil
        }
        return destroy
    }

    private func completeGhosttyReplacement(
        for key: GhosttyReplacementKey,
        destroy: PendingGhosttyDestroy,
        create: PendingGhosttyCreate
    ) {
        pendingGhosttyReplacementTasks.removeValue(forKey: key)?.cancel()
        pendingGhosttyReplacementBursts.removeValue(forKey: key)

        let destroyCandidate = destroy.candidate
        let createCandidate = create.candidate

        guard destroyCandidate.workspaceId == createCandidate.workspaceId else {
            replayGhosttyReplacementEvents([.destroy(destroy), .create(create)])
            return
        }

        if !rekeyGhosttyReplacement(from: destroyCandidate.token, to: createCandidate) {
            replayGhosttyReplacementEvents([.destroy(destroy), .create(create)])
        }
    }

    private func replayGhosttyReplacementEvents(_ events: [PendingGhosttyEvent]) {
        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            switch event {
            case let .create(create):
                trackPreparedCreate(create.candidate)
            case let .destroy(destroy):
                processPreparedDestroy(destroy.candidate)
            }
        }
    }

    @discardableResult
    private func rekeyGhosttyReplacement(from oldToken: WindowToken, to create: PreparedCreate) -> Bool {
        rekeyManagedWindowIdentity(
            from: oldToken,
            to: create.token,
            windowId: create.windowId,
            axRef: create.axRef
        ) != nil
    }

    private func refreshBorderAfterManagedRekey(entry: WindowModel.Entry) {
        guard let controller else { return }
        guard controller.workspaceManager.focusedToken == entry.token else { return }

        if let engine = controller.niriEngine,
           let node = engine.findNode(for: entry.token),
           let frame = node.renderedFrame ?? node.frame
        {
            controller.borderCoordinator.updateBorderIfAllowed(
                token: entry.token,
                frame: frame,
                windowId: entry.windowId
            )
            return
        }

        if let frame = frameProvider?(entry.axRef) ?? (try? AXWindowService.frame(entry.axRef)) {
            controller.borderCoordinator.updateBorderIfAllowed(
                token: entry.token,
                frame: frame,
                windowId: entry.windowId
            )
        }
    }

    private func resetNativeFullscreenReplacementState() {
        for (_, task) in pendingNativeFullscreenReplacementTasks {
            task.cancel()
        }
        pendingNativeFullscreenReplacementTasks.removeAll()
    }

    private func scheduleNativeFullscreenReplacementExpiry(for originalToken: WindowToken) {
        cancelNativeFullscreenReplacementExpiry(for: originalToken)
        pendingNativeFullscreenReplacementTasks[originalToken] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.nativeFullscreenReplacementGraceDelay)
            guard !Task.isCancelled, let self, let controller = self.controller else { return }
            defer { self.pendingNativeFullscreenReplacementTasks.removeValue(forKey: originalToken) }
            guard let record = controller.workspaceManager.nativeFullscreenRecord(for: originalToken),
                  record.originalToken == originalToken,
                  record.transition == .awaitingReplacement
            else {
                return
            }
            controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        }
    }

    private func cancelNativeFullscreenReplacementExpiry(for originalToken: WindowToken) {
        pendingNativeFullscreenReplacementTasks.removeValue(forKey: originalToken)?.cancel()
    }

    private func cancelNativeFullscreenReplacementExpiry(containing token: WindowToken) {
        if let controller,
           let originalToken = controller.workspaceManager.nativeFullscreenRecord(for: token)?.originalToken
        {
            cancelNativeFullscreenReplacementExpiry(for: originalToken)
            return
        }
        cancelNativeFullscreenReplacementExpiry(for: token)
    }

    private func scheduleGhosttyReplacementFlush(for key: GhosttyReplacementKey) {
        pendingGhosttyReplacementTasks.removeValue(forKey: key)?.cancel()
        pendingGhosttyReplacementTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.ghosttyReplacementGraceDelay)
            guard !Task.isCancelled else { return }
            self?.flushGhosttyReplacementBurst(for: key)
        }
    }

    private func flushGhosttyReplacementBurst(for key: GhosttyReplacementKey) {
        pendingGhosttyReplacementTasks.removeValue(forKey: key)?.cancel()
        guard let burst = pendingGhosttyReplacementBursts.removeValue(forKey: key) else { return }

        for event in burst.orderedEvents {
            switch event {
            case let .create(create):
                trackPreparedCreate(create.candidate)
            case let .destroy(destroy):
                processPreparedDestroy(destroy.candidate)
            }
        }
    }

    private func nextGhosttySequence() -> UInt64 {
        defer { nextGhosttyEventSequence += 1 }
        return nextGhosttyEventSequence
    }

    private func deferCreatedWindow(_ windowId: UInt32) {
        guard deferredCreatedWindowIds.insert(windowId).inserted else { return }
        deferredCreatedWindowOrder.append(windowId)
    }

    private func removeDeferredCreatedWindow(_ windowId: UInt32) {
        guard deferredCreatedWindowIds.remove(windowId) != nil else { return }
        deferredCreatedWindowOrder.removeAll { $0 == windowId }
    }

    private func resolveWindowInfo(_ windowId: UInt32) -> WindowServerInfo? {
        windowInfoProvider?(windowId) ?? SkyLight.shared.queryWindowInfo(windowId)
    }

    private func resolveWindowToken(_ windowId: UInt32) -> WindowToken? {
        guard let windowInfo = resolveWindowInfo(windowId) else { return nil }
        return .init(pid: windowInfo.pid, windowId: Int(windowId))
    }

    private func resolveTrackedToken(_ windowId: UInt32) -> WindowToken? {
        if let token = resolveWindowToken(windowId) {
            return token
        }
        guard let controller else { return nil }
        let matches = controller.workspaceManager.allEntries().filter { $0.windowId == Int(windowId) }
        guard matches.count == 1 else { return nil }
        return matches[0].token
    }

    private func resolveAXWindowRef(windowId: UInt32, pid: pid_t) -> AXWindowRef? {
        axWindowRefProvider?(windowId, pid) ?? AXWindowService.axWindowRef(for: windowId, pid: pid)
    }

    private func subscribeToWindows(_ windowIds: [UInt32]) {
        if let windowSubscriptionHandler {
            windowSubscriptionHandler(windowIds)
            return
        }
        CGSEventObserver.shared.subscribeToWindows(windowIds)
    }

    private func resolveFocusedWindowValue(pid: pid_t) -> CFTypeRef? {
        if let focusedWindowValueProvider {
            return focusedWindowValueProvider(pid)
        }

        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard result == .success else { return nil }
        return focusedWindow
    }

    private func resolveFocusedAXWindowRef(pid: pid_t) -> AXWindowRef? {
        guard let windowElement = resolveFocusedWindowValue(pid: pid) else {
            return nil
        }
        guard CFGetTypeID(windowElement) == AXUIElementGetTypeID() else {
            return nil
        }
        let axElement = unsafeDowncast(windowElement, to: AXUIElement.self)
        return try? AXWindowRef(element: axElement)
    }

    private func resolveBundleId(_ pid: pid_t) -> String? {
        guard let controller else { return nil }
        if let bundleIdProvider {
            return bundleIdProvider(pid)
        }
        return controller.appInfoCache.bundleId(for: pid) ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}
