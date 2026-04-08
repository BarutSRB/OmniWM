import AppKit
import Foundation

enum KeyboardFocusBorderRenderPolicy: Equatable {
    case direct
    case coordinated

    var shouldDeferForAnimations: Bool {
        self == .coordinated
    }
}

enum ManagedBorderReapplyPhase: String, Equatable {
    case postLayout
    case animationSettled
    case retryExhaustedFallback
}

enum BorderOwner: Equatable {
    case none
    case managed(token: WindowToken, wid: Int, workspaceId: WorkspaceDescriptor.ID)
    case fallback(pid: pid_t, wid: Int)

    var token: WindowToken? {
        switch self {
        case let .managed(token, _, _):
            token
        case .none, .fallback:
            nil
        }
    }

    var pid: pid_t? {
        switch self {
        case let .managed(token, _, _):
            token.pid
        case let .fallback(pid, _):
            pid
        case .none:
            nil
        }
    }

    var wid: Int? {
        switch self {
        case let .managed(_, wid, _):
            wid
        case let .fallback(_, wid):
            wid
        case .none:
            nil
        }
    }

    var workspaceId: WorkspaceDescriptor.ID? {
        switch self {
        case let .managed(_, _, workspaceId):
            workspaceId
        case .none, .fallback:
            nil
        }
    }

    var isManaged: Bool {
        if case .managed = self {
            return true
        }
        return false
    }

    var isFallback: Bool {
        if case .fallback = self {
            return true
        }
        return false
    }

    var windowIdUInt32: UInt32? {
        guard let wid else { return nil }
        return UInt32(exactly: wid)
    }
}

struct BorderOwnerState: Equatable {
    var owner: BorderOwner = .none
    var generation: UInt64 = 0
    var leaseDeadline: Date?
    var isLiveMotion = false
    var cachedAXRef: AXWindowRef?
    var resolvedFrame: CGRect?
    var resolvedWindowInfo: WindowServerInfo?
    var resolvedAXFacts: AXWindowFacts?
    var orderingMetadata: BorderOrderingMetadata?
    var orderingDecision = "fallback:safe-default"
    var fallbackSubscribedWindowIds: Set<UInt32> = []
}

enum BorderTraceAction: String, Equatable {
    case update
    case hide
    case ignore
}

enum BorderReconcileSource: String, Equatable {
    case focusedWindowChanged
    case frontmostAppChanged
    case appHide
    case appUnhide
    case focusClear
    case cgsFrameChanged
    case cgsClosed
    case cgsDestroyed
    case managedRekey
    case replacementSettle
    case borderReapplyPostLayout
    case borderReapplyAnimationSettled
    case borderReapplyRetryExhaustedFallback
    case workspaceActivation
    case activeSpaceChanged
    case nativeFullscreenEnter
    case nativeFullscreenExit
    case monitorConfigurationChanged
    case appTerminated
    case fallbackLeaseExpired
    case manualRender
    case cleanup
}

enum BorderReconcileEvent {
    case renderRequested(
        source: BorderReconcileSource,
        target: KeyboardFocusTarget?,
        preferredFrame: CGRect?,
        policy: KeyboardFocusBorderRenderPolicy
    )
    case invalidate(
        source: BorderReconcileSource,
        reason: String,
        matchingToken: WindowToken?,
        matchingPid: pid_t?,
        matchingWindowId: Int?
    )
    case cgsFrameChanged(windowId: UInt32)
    case cgsClosed(windowId: UInt32)
    case cgsDestroyed(windowId: UInt32)
    case managedRekey(
        from: WindowToken,
        to: WindowToken,
        workspaceId: WorkspaceDescriptor.ID?,
        axRef: AXWindowRef?,
        preferredFrame: CGRect?,
        policy: KeyboardFocusBorderRenderPolicy
    )
    case cleanup
}

struct BorderTraceRecord: Equatable {
    let timestamp: Date
    let source: BorderReconcileSource
    let rawFocus: String?
    let owner: BorderOwner
    let action: BorderTraceAction
    let reason: String
    let generation: UInt64
    let frame: CGRect?
    let orderingDecision: String?
}

private struct BorderOrderingResolution {
    let metadata: BorderOrderingMetadata
    let decision: String
}

private struct BorderRenderContext {
    let target: KeyboardFocusTarget
    let owner: BorderOwner
    let frame: CGRect
    let ordering: BorderOrderingMetadata
    let orderingDecision: String
    let policy: KeyboardFocusBorderRenderPolicy
}

private enum BorderResolutionDecision {
    case hide(reason: String)
    case ignore(reason: String)
    case update(BorderRenderContext)
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        let seconds = TimeInterval(components.seconds)
        let attoseconds = TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
        return seconds + attoseconds
    }
}

@MainActor
final class BorderCoordinator {
    private static let ghosttyBundleId = "com.mitchellh.ghostty"
    private static let traceLimit = 128
    private static let fallbackLeaseDuration: Duration = .milliseconds(500)
    private static let liveMotionIdleDuration: Duration = .milliseconds(150)
    private static let safeOrderingLevels: Set<Int32> = [0, 3, 8]
    private static let visibleAttributeMask: UInt32 = 0x2
    private static let visibleTagMask: UInt64 = 0x0040_0000_0000_0000
    private static let traceLoggingEnabled =
        ProcessInfo.processInfo.environment["OMNIWM_DEBUG_BORDER_TRACE"] == "1"

    weak var controller: WMController?
    var observedFrameProviderForTests: ((AXWindowRef) -> CGRect?)?
    var suppressNextKeyboardFocusBorderRenderForTests: ((KeyboardFocusTarget, KeyboardFocusBorderRenderPolicy) -> Bool)?
    var suppressNextManagedBorderUpdateForTests: ((WindowToken, KeyboardFocusBorderRenderPolicy) -> Bool)?
    var cornerRadiusProviderForTests: ((Int) -> CGFloat?)?
    var fallbackLeaseDurationForTests: Duration?
    var liveMotionIdleDurationForTests: Duration?

    private(set) var ownerState = BorderOwnerState()
    private var trace: [BorderTraceRecord] = []
    private var pendingFallbackLeaseTask: Task<Void, Never>?
    private var pendingLiveMotionResetTask: Task<Void, Never>?

    init(controller: WMController) {
        self.controller = controller
    }

    @discardableResult
    func renderBorder(
        for target: KeyboardFocusTarget?,
        preferredFrame: CGRect? = nil,
        policy: KeyboardFocusBorderRenderPolicy,
        source: BorderReconcileSource = .manualRender
    ) -> Bool {
        reconcile(
            event: .renderRequested(
                source: source,
                target: target,
                preferredFrame: preferredFrame,
                policy: policy
            )
        )
    }

    @discardableResult
    func hideBorder(
        source: BorderReconcileSource,
        reason: String,
        matchingToken: WindowToken? = nil,
        matchingPid: pid_t? = nil,
        matchingWindowId: Int? = nil
    ) -> Bool {
        reconcile(
            event: .invalidate(
                source: source,
                reason: reason,
                matchingToken: matchingToken,
                matchingPid: matchingPid,
                matchingWindowId: matchingWindowId
            )
        )
    }

    func cleanup() {
        _ = reconcile(event: .cleanup)
    }

    func traceSnapshotForTests() -> [BorderTraceRecord] {
        trace
    }

    func ownerStateSnapshotForTests() -> BorderOwnerState {
        ownerState
    }

    @discardableResult
    func reconcile(event: BorderReconcileEvent) -> Bool {
        guard let controller else { return false }

        switch event {
        case let .renderRequested(source, target, preferredFrame, policy):
            return reconcileRenderRequested(
                source: source,
                target: target ?? controller.currentKeyboardFocusTargetForRendering(),
                preferredFrame: preferredFrame,
                policy: policy
            )

        case let .invalidate(source, reason, matchingToken, matchingPid, matchingWindowId):
            guard currentOwnerMatches(
                token: matchingToken,
                pid: matchingPid,
                windowId: matchingWindowId
            ) else {
                recordTrace(
                    source: source,
                    action: .ignore,
                    reason: reason,
                    rawFocus: controller.currentKeyboardFocusTargetForRendering(),
                    frame: ownerState.resolvedFrame,
                    orderingDecision: ownerState.orderingDecision
                )
                return false
            }
            clearOwnerAndHide(source: source, reason: reason)
            return false

        case let .cgsFrameChanged(windowId):
            return reconcileCurrentOwnerFrameChange(windowId: windowId)

        case let .cgsClosed(windowId):
            return reconcileOwnerTeardown(windowId: windowId, source: .cgsClosed, reason: "window closed")

        case let .cgsDestroyed(windowId):
            return reconcileOwnerTeardown(windowId: windowId, source: .cgsDestroyed, reason: "window destroyed")

        case let .managedRekey(from, to, workspaceId, axRef, preferredFrame, policy):
            return reconcileManagedRekey(
                from: from,
                to: to,
                workspaceId: workspaceId,
                axRef: axRef,
                preferredFrame: preferredFrame,
                policy: policy
            )

        case .cleanup:
            cancelFallbackLease()
            cancelLiveMotionReset()
            clearTransientState(clearFallbackBookkeeping: true)
            ownerState.owner = .none
            ownerState.generation &+= 1
            recordTrace(
                source: .cleanup,
                action: .hide,
                reason: "cleanup",
                rawFocus: controller.currentKeyboardFocusTargetForRendering(),
                frame: ownerState.resolvedFrame,
                orderingDecision: ownerState.orderingDecision
            )
            controller.borderManager.cleanup()
            return false
        }
    }

    private func reconcileRenderRequested(
        source: BorderReconcileSource,
        target: KeyboardFocusTarget?,
        preferredFrame: CGRect?,
        policy: KeyboardFocusBorderRenderPolicy
    ) -> Bool {
        guard let target else {
            clearOwnerAndHide(source: source, reason: "no focused target")
            return false
        }

        let previousOwner = ownerState.owner
        let nextOwner = owner(for: target)
        adoptOwnerIfNeeded(nextOwner)

        switch resolveRenderDecision(
            target: target,
            preferredFrame: preferredFrame,
            policy: policy
        ) {
        case let .update(context):
            applyRender(context, source: source, reason: "rendered")
            return true

        case let .hide(reason):
            clearOwnerAndHide(source: source, reason: reason)
            return false

        case let .ignore(reason):
            if previousOwner != nextOwner, previousOwner != .none {
                controller?.borderManager.hideBorder()
                recordTrace(
                    source: source,
                    action: .hide,
                    reason: "\(reason) after owner change",
                    rawFocus: target,
                    frame: ownerState.resolvedFrame,
                    orderingDecision: ownerState.orderingDecision
                )
            } else {
                recordTrace(
                    source: source,
                    action: .ignore,
                    reason: reason,
                    rawFocus: target,
                    frame: ownerState.resolvedFrame,
                    orderingDecision: ownerState.orderingDecision
                )
            }
            return false
        }
    }

    private func reconcileCurrentOwnerFrameChange(windowId: UInt32) -> Bool {
        let target: KeyboardFocusTarget?
        if ownerState.owner.windowIdUInt32 == windowId {
            let generation = ownerState.generation
            if ownerState.owner.isFallback {
                noteLiveMotion(for: generation)
            }
            target = targetForCurrentOwner(strictFallbackFocusMatch: false)
        } else if let rawTarget = controller?.currentKeyboardFocusTargetForRendering(),
                  rawTarget.windowId == Int(windowId)
        {
            let candidateOwner = owner(for: rawTarget)
            if let windowInfo = resolveWindowInfo(windowId) {
                guard windowInfo.id == windowId,
                      pid_t(windowInfo.pid) == candidateOwner.pid
                else {
                    recordTrace(
                        source: .cgsFrameChanged,
                        action: .ignore,
                        reason: "frame event failed pid/wid validation",
                        rawFocus: rawTarget,
                        frame: ownerState.resolvedFrame,
                        orderingDecision: ownerState.orderingDecision
                    )
                    return false
                }
            }
            adoptOwnerIfNeeded(candidateOwner)
            if candidateOwner.isFallback {
                noteLiveMotion(for: ownerState.generation)
            }
            target = rawTarget
        } else {
            recordTrace(
                source: .cgsFrameChanged,
                action: .ignore,
                reason: "stale frame event",
                rawFocus: controller?.currentKeyboardFocusTargetForRendering(),
                frame: ownerState.resolvedFrame,
                orderingDecision: ownerState.orderingDecision
            )
            return false
        }

        guard let target else {
            clearOwnerAndHide(source: .cgsFrameChanged, reason: "owner no longer resolves")
            return false
        }

        switch resolveRenderDecision(
            target: target,
            preferredFrame: nil,
            policy: .direct
        ) {
        case let .update(context):
            applyRender(context, source: .cgsFrameChanged, reason: "frame changed")
            return true

        case let .hide(reason):
            clearOwnerAndHide(source: .cgsFrameChanged, reason: reason)
            return false

        case let .ignore(reason):
            recordTrace(
                source: .cgsFrameChanged,
                action: .ignore,
                reason: reason,
                rawFocus: target,
                frame: ownerState.resolvedFrame,
                orderingDecision: ownerState.orderingDecision
            )
            return false
        }
    }

    private func reconcileOwnerTeardown(
        windowId: UInt32,
        source: BorderReconcileSource,
        reason: String
    ) -> Bool {
        guard ownerState.owner.windowIdUInt32 == windowId else {
            recordTrace(
                source: source,
                action: .ignore,
                reason: "stale teardown event",
                rawFocus: controller?.currentKeyboardFocusTargetForRendering(),
                frame: ownerState.resolvedFrame,
                orderingDecision: ownerState.orderingDecision
            )
            return false
        }

        clearOwnerAndHide(source: source, reason: reason)
        return false
    }

    private func reconcileManagedRekey(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        workspaceId: WorkspaceDescriptor.ID?,
        axRef: AXWindowRef?,
        preferredFrame: CGRect?,
        policy: KeyboardFocusBorderRenderPolicy
    ) -> Bool {
        let currentOwner = ownerState.owner
        let currentWorkspaceId: WorkspaceDescriptor.ID?
        if case let .managed(token, _, workspaceIdFromOwner) = currentOwner,
           token == oldToken || token == newToken
        {
            currentWorkspaceId = workspaceIdFromOwner
        } else {
            let currentFocusToken = controller?.currentKeyboardFocusTargetForRendering()?.token
                ?? controller?.workspaceManager.focusedToken
                ?? controller?.workspaceManager.pendingFocusedToken
            guard currentFocusToken == oldToken || currentFocusToken == newToken else {
                recordTrace(
                    source: .managedRekey,
                    action: .ignore,
                    reason: "rekey did not match current owner",
                    rawFocus: controller?.currentKeyboardFocusTargetForRendering(),
                    frame: ownerState.resolvedFrame,
                    orderingDecision: ownerState.orderingDecision
                )
                return false
            }
            currentWorkspaceId = controller?.workspaceManager.entry(for: newToken)?.workspaceId
                ?? controller?.workspaceManager.entry(for: oldToken)?.workspaceId
        }

        guard let resolvedWorkspaceId = workspaceId ?? currentWorkspaceId else {
            recordTrace(
                source: .managedRekey,
                action: .ignore,
                reason: "rekey workspace unresolved",
                rawFocus: controller?.currentKeyboardFocusTargetForRendering(),
                frame: ownerState.resolvedFrame,
                orderingDecision: ownerState.orderingDecision
            )
            return false
        }

        adoptOwnerIfNeeded(.managed(token: newToken, wid: newToken.windowId, workspaceId: resolvedWorkspaceId))
        ownerState.cachedAXRef = axRef

        let target = controller?.managedKeyboardFocusTarget(for: newToken)
            ?? axRef.map {
                KeyboardFocusTarget(
                    token: newToken,
                    axRef: $0,
                    workspaceId: resolvedWorkspaceId,
                    isManaged: true
                )
            }

        return reconcileRenderRequested(
            source: .managedRekey,
            target: target,
            preferredFrame: preferredFrame,
            policy: policy
        )
    }

    private func resolveRenderDecision(
        target: KeyboardFocusTarget,
        preferredFrame: CGRect?,
        policy: KeyboardFocusBorderRenderPolicy
    ) -> BorderResolutionDecision {
        guard let controller else { return .hide(reason: "controller unavailable") }

        if suppressNextKeyboardFocusBorderRenderForTests?(target, policy) == true {
            suppressNextKeyboardFocusBorderRenderForTests = nil
            return .ignore(reason: "suppressed by test hook")
        }

        if target.isManaged,
           suppressNextManagedBorderUpdateForTests?(target.token, policy) == true
        {
            suppressNextManagedBorderUpdateForTests = nil
            return .ignore(reason: "managed update suppressed by test hook")
        }

        let owner = owner(for: target)
        guard owner != .none else { return .hide(reason: "no owner") }

        if controller.isOwnedWindow(windowNumber: target.windowId) {
            return .hide(reason: "owned window")
        }

        if controller.workspaceManager.hasPendingNativeFullscreenTransition {
            return .hide(reason: "native fullscreen transition active")
        }

        if controller.hiddenAppPIDs.contains(target.pid) {
            return .hide(reason: "app hidden")
        }

        guard let axRef = resolveAXRef(for: owner, target: target) else {
            return owner.isManaged && policy.shouldDeferForAnimations
                ? .ignore(reason: "managed AX ref unresolved")
                : .hide(reason: "AX ref unresolved")
        }

        let validatedWindowInfo = resolveValidatedWindowInfo(for: owner)
        let windowInfo = sanitizedWindowInfo(validatedWindowInfo, for: owner)
        let evaluation = evaluateEligibility(
            target: target,
            owner: owner,
            axRef: axRef,
            windowInfo: windowInfo
        )
        ownerState.resolvedAXFacts = evaluation?.facts.ax

        if let resolution = eligibilityDecision(
            target: target,
            owner: owner,
            axRef: axRef,
            evaluation: evaluation,
            windowInfo: windowInfo
        ) {
            return resolution
        }

        guard let frame = resolveFrame(
            for: target,
            owner: owner,
            axRef: axRef,
            preferredFrame: preferredFrame,
            windowInfo: windowInfo
        ) else {
            return owner.isManaged && policy.shouldDeferForAnimations
                ? .ignore(reason: "managed frame unresolved")
                : .hide(reason: "frame unresolved")
        }

        if owner.isManaged,
           policy.shouldDeferForAnimations,
           let workspaceId = owner.workspaceId,
           shouldDeferBorderUpdates(for: workspaceId)
        {
            return .ignore(reason: "managed animation deferred")
        }

        let ordering = resolveOrdering(for: target, windowInfo: windowInfo)
        ownerState.cachedAXRef = axRef
        ownerState.resolvedFrame = frame
        ownerState.resolvedWindowInfo = windowInfo
        ownerState.orderingMetadata = ordering.metadata
        ownerState.orderingDecision = ordering.decision

        return .update(
            BorderRenderContext(
                target: target,
                owner: owner,
                frame: frame,
                ordering: ordering.metadata,
                orderingDecision: ordering.decision,
                policy: policy
            )
        )
    }

    private func eligibilityDecision(
        target: KeyboardFocusTarget,
        owner: BorderOwner,
        axRef: AXWindowRef,
        evaluation: WMController.WindowDecisionEvaluation?,
        windowInfo: WindowServerInfo?
    ) -> BorderResolutionDecision? {
        guard let controller else { return .hide(reason: "controller unavailable") }

        if owner.isManaged,
           let token = owner.token,
           (controller.workspaceManager.isAppFullscreenActive
               || isManagedWindowFullscreen(token)
               || AXWindowService.isFullscreen(axRef))
        {
            return .hide(reason: "fullscreen target")
        }

        if owner.isManaged,
           let token = owner.token
        {
            guard let entry = controller.workspaceManager.entry(for: token) else {
                return .hide(reason: "managed entry missing")
            }
            guard controller.isManagedWindowDisplayable(entry.handle) else {
                return .hide(reason: "managed target not displayable")
            }
        }

        if isAXWindowMinimized(axRef) {
            return .hide(reason: "window minimized")
        }

        if let facts = evaluation?.facts.ax {
            if let role = facts.role, role != kAXWindowRole as String {
                return .hide(reason: "AX role is not window")
            }
            if facts.subrole == "AXFullScreenWindow" {
                return .hide(reason: "AX fullscreen subrole")
            }
        }

        if let windowInfo {
            if owner.isFallback, !isWindowServerInfoDisplayable(windowInfo) {
                return .hide(reason: "unsafe window server metadata")
            }
            if owner.isManaged,
               (windowInfo.parentId != 0 || !Self.safeOrderingLevels.contains(windowInfo.level))
            {
                return .hide(reason: "unsafe window server metadata")
            }
        }

        if owner.isFallback {
            guard let evaluation else { return .hide(reason: "fallback evaluation unavailable") }
            guard evaluation.decision.disposition != .unmanaged,
                  evaluation.decision.disposition != .undecided
            else {
                return .hide(reason: "fallback target not border eligible")
            }
        }

        return nil
    }

    private func evaluateEligibility(
        target: KeyboardFocusTarget,
        owner _: BorderOwner,
        axRef: AXWindowRef,
        windowInfo: WindowServerInfo?
    ) -> WMController.WindowDecisionEvaluation? {
        guard let controller else { return nil }
        return controller.evaluateWindowDisposition(
            axRef: axRef,
            pid: target.pid,
            appFullscreen: nil,
            applyingManualOverride: false,
            windowInfo: windowInfo
        )
    }

    private func resolveFrame(
        for target: KeyboardFocusTarget,
        owner: BorderOwner,
        axRef: AXWindowRef,
        preferredFrame: CGRect?,
        windowInfo: WindowServerInfo?
    ) -> CGRect? {
        guard let controller else { return nil }
        let prefersGhosttyObservedFrame = controller.appInfoCache.bundleId(for: target.pid) == Self.ghosttyBundleId

        if owner.isManaged,
           let entry = controller.workspaceManager.entry(for: target.token)
        {
            let shouldPreferObservedFrame = controller.axManager.shouldPreferObservedFrame(for: entry.windowId)
            let prefersObservedFrame = shouldPreferObservedFrame || prefersGhosttyObservedFrame

            if !prefersObservedFrame, let preferredFrame {
                return preferredFrame
            }

            if let observed = observedFrame(for: axRef) {
                return observed
            }

            if let preferredFrame {
                return preferredFrame
            }

            return controller.axManager.lastAppliedFrame(for: entry.windowId)
                ?? (!prefersObservedFrame
                    ? controller.niriEngine?.findNode(for: target.token).flatMap { $0.renderedFrame ?? $0.frame }
                    : nil)
                ?? controller.dwindleEngine?.findNode(for: target.token)?.cachedFrame
                ?? controller.workspaceManager.floatingState(for: target.token)?.lastFrame
        }

        return observedFrame(for: axRef) ?? windowInfo?.frame ?? preferredFrame
    }

    private func observedFrame(for axRef: AXWindowRef) -> CGRect? {
        if let observedFrameProviderForTests {
            return observedFrameProviderForTests(axRef)
        }

        if let controller {
            if let frame = controller.axEventHandler.frameProvider?(axRef) {
                return frame
            }
            if let frame = controller.axEventHandler.fastFrameProvider?(axRef) {
                return frame
            }
        }

        if let frame = AXWindowService.framePreferFast(axRef) {
            return frame
        }

        return try? AXWindowService.frame(axRef)
    }

    private func resolveOrdering(
        for target: KeyboardFocusTarget,
        windowInfo: WindowServerInfo?
    ) -> BorderOrderingResolution {
        let fallback = BorderOrderingMetadata.fallback(relativeTo: UInt32(target.windowId))
        guard let windowInfo else {
            return BorderOrderingResolution(
                metadata: fallback,
                decision: "fallback:missing-window-server-info"
            )
        }

        guard Self.safeOrderingLevels.contains(windowInfo.level) else {
            return BorderOrderingResolution(
                metadata: fallback,
                decision: "fallback:unsafe-level=\(windowInfo.level)"
            )
        }

        let cornerRadius = cornerRadiusProviderForTests?(target.windowId)
            ?? SkyLight.shared.cornerRadius(forWindowId: target.windowId)
        let overlayMetadata = BorderOrderingMetadata.fallback(
            relativeTo: UInt32(target.windowId),
            cornerRadius: cornerRadius
        )
        return BorderOrderingResolution(
            metadata: overlayMetadata,
            decision: "derived:overlay-level=\(overlayMetadata.level)\(cornerRadius == nil ? "" : ",corner-radius")"
        )
    }

    private func resolveValidatedWindowInfo(for owner: BorderOwner) -> WindowServerInfo? {
        guard let windowId = owner.windowIdUInt32,
              let pid = owner.pid,
              let windowInfo = resolveWindowInfo(windowId),
              windowInfo.id == windowId,
              pid_t(windowInfo.pid) == pid
        else {
            return nil
        }
        return windowInfo
    }

    private func resolveWindowInfo(_ windowId: UInt32) -> WindowServerInfo? {
        guard let controller else { return nil }
        return controller.axEventHandler.windowInfoProvider?(windowId)
            ?? SkyLight.shared.queryWindowInfo(windowId)
    }

    private func sanitizedWindowInfo(
        _ windowInfo: WindowServerInfo?,
        for owner: BorderOwner
    ) -> WindowServerInfo? {
        guard let windowInfo else { return nil }
        guard owner.isManaged else { return windowInfo }
        guard windowInfo.parentId == 0,
              Self.safeOrderingLevels.contains(windowInfo.level)
        else {
            return nil
        }
        return windowInfo
    }

    private func resolveAXRef(
        for owner: BorderOwner,
        target: KeyboardFocusTarget?
    ) -> AXWindowRef? {
        if let target,
           target.windowId == owner.wid,
           target.pid == owner.pid
        {
            return target.axRef
        }

        if let cachedAXRef = ownerState.cachedAXRef,
           cachedAXRef.windowId == owner.wid
        {
            return cachedAXRef
        }

        guard let windowId = owner.windowIdUInt32,
              let pid = owner.pid
        else {
            return nil
        }

        if owner.isManaged,
           let token = owner.token,
           let entry = controller?.workspaceManager.entry(for: token)
        {
            return entry.axRef
        }

        return AXWindowService.axWindowRef(for: windowId, pid: pid)
    }

    private func isAXWindowMinimized(_ axRef: AXWindowRef) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            axRef.element,
            kAXMinimizedAttribute as CFString,
            &value
        )
        guard result == .success else { return false }
        return (value as? Bool) == true
    }

    private func isWindowServerInfoDisplayable(_ windowInfo: WindowServerInfo) -> Bool {
        guard windowInfo.parentId == 0 else { return false }
        guard Self.safeOrderingLevels.contains(windowInfo.level) else { return false }

        let hasVisibleAttribute = (windowInfo.attributes & Self.visibleAttributeMask) != 0
        let hasVisibleTag = (windowInfo.tags & Self.visibleTagMask) != 0
        return hasVisibleAttribute || hasVisibleTag
    }

    private func currentOwnerMatches(
        token: WindowToken?,
        pid: pid_t?,
        windowId: Int?
    ) -> Bool {
        if token == nil, pid == nil, windowId == nil {
            return true
        }

        let owner = ownerState.owner
        let matchesToken = token.map { owner.token == $0 } ?? true
        let matchesPid = pid.map { owner.pid == $0 } ?? true
        let matchesWindowId = windowId.map { owner.wid == $0 } ?? true
        return matchesToken && matchesPid && matchesWindowId
    }

    private func owner(for target: KeyboardFocusTarget) -> BorderOwner {
        if target.isManaged, let workspaceId = target.workspaceId {
            return .managed(token: target.token, wid: target.windowId, workspaceId: workspaceId)
        }

        return .fallback(pid: target.pid, wid: target.windowId)
    }

    private func adoptOwnerIfNeeded(_ owner: BorderOwner) {
        guard ownerState.owner != owner else { return }

        ownerState.generation &+= 1
        cancelFallbackLease()
        cancelLiveMotionReset()
        clearTransientState(clearFallbackBookkeeping: true)
        ownerState.owner = owner

        if case let .fallback(_, wid) = owner,
           let fallbackWindowId = UInt32(exactly: wid)
        {
            requestFallbackSubscription(fallbackWindowId)
        }
    }

    private func clearOwnerAndHide(source: BorderReconcileSource, reason: String) {
        let rawFocus = controller?.currentKeyboardFocusTargetForRendering()
        controller?.borderManager.hideBorder()
        ownerState.generation &+= 1
        cancelFallbackLease()
        cancelLiveMotionReset()
        clearTransientState(clearFallbackBookkeeping: true)
        ownerState.owner = .none
        recordTrace(
            source: source,
            action: .hide,
            reason: reason,
            rawFocus: rawFocus,
            frame: nil,
            orderingDecision: nil
        )
    }

    private func clearTransientState(clearFallbackBookkeeping: Bool) {
        ownerState.leaseDeadline = nil
        ownerState.isLiveMotion = false
        ownerState.cachedAXRef = nil
        ownerState.resolvedFrame = nil
        ownerState.resolvedWindowInfo = nil
        ownerState.resolvedAXFacts = nil
        ownerState.orderingMetadata = nil
        ownerState.orderingDecision = "fallback:safe-default"
        if clearFallbackBookkeeping {
            ownerState.fallbackSubscribedWindowIds.removeAll()
        }
    }

    private func applyRender(
        _ context: BorderRenderContext,
        source: BorderReconcileSource,
        reason: String
    ) {
        controller?.borderManager.updateFocusedWindow(
            frame: context.frame,
            windowId: context.target.windowId,
            ordering: context.ordering
        )

        if context.owner.isFallback {
            refreshFallbackLease()
        } else {
            cancelFallbackLease()
        }

        recordTrace(
            source: source,
            action: .update,
            reason: reason,
            rawFocus: context.target,
            frame: context.frame,
            orderingDecision: context.orderingDecision
        )
    }

    private func requestFallbackSubscription(_ windowId: UInt32) {
        ownerState.fallbackSubscribedWindowIds.insert(windowId)
        controller?.axEventHandler.requestWindowNotificationSubscription([windowId])
    }

    private func refreshFallbackLease() {
        guard ownerState.owner.isFallback else { return }

        let duration = fallbackLeaseDurationForTests ?? Self.fallbackLeaseDuration
        ownerState.leaseDeadline = Date().addingTimeInterval(duration.timeInterval)
        let generation = ownerState.generation

        pendingFallbackLeaseTask?.cancel()
        pendingFallbackLeaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.handleFallbackLeaseExpiry(expectedGeneration: generation)
        }
    }

    private func handleFallbackLeaseExpiry(expectedGeneration: UInt64) {
        guard ownerState.generation == expectedGeneration,
              ownerState.owner.isFallback
        else {
            return
        }

        if ownerState.isLiveMotion {
            refreshFallbackLease()
            recordTrace(
                source: .fallbackLeaseExpired,
                action: .ignore,
                reason: "lease extended during live motion",
                rawFocus: controller?.currentKeyboardFocusTargetForRendering(),
                frame: ownerState.resolvedFrame,
                orderingDecision: ownerState.orderingDecision
            )
            return
        }

        guard let target = targetForCurrentOwner(strictFallbackFocusMatch: true) else {
            clearOwnerAndHide(source: .fallbackLeaseExpired, reason: "fallback focus changed")
            return
        }

        switch resolveRenderDecision(
            target: target,
            preferredFrame: nil,
            policy: .direct
        ) {
        case let .update(context):
            applyRender(context, source: .fallbackLeaseExpired, reason: "fallback lease revalidated")

        case let .hide(reason):
            clearOwnerAndHide(source: .fallbackLeaseExpired, reason: reason)

        case let .ignore(reason):
            clearOwnerAndHide(source: .fallbackLeaseExpired, reason: reason)
        }
    }

    private func cancelFallbackLease() {
        pendingFallbackLeaseTask?.cancel()
        pendingFallbackLeaseTask = nil
        ownerState.leaseDeadline = nil
    }

    private func noteLiveMotion(for generation: UInt64) {
        ownerState.isLiveMotion = true
        let duration = liveMotionIdleDurationForTests ?? Self.liveMotionIdleDuration

        pendingLiveMotionResetTask?.cancel()
        pendingLiveMotionResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled,
                  let self,
                  self.ownerState.generation == generation
            else {
                return
            }
            self.ownerState.isLiveMotion = false
        }
    }

    private func cancelLiveMotionReset() {
        pendingLiveMotionResetTask?.cancel()
        pendingLiveMotionResetTask = nil
        ownerState.isLiveMotion = false
    }

    private func targetForCurrentOwner(
        strictFallbackFocusMatch: Bool
    ) -> KeyboardFocusTarget? {
        guard let controller else { return nil }

        switch ownerState.owner {
        case let .managed(token, _, _):
            return controller.managedKeyboardFocusTarget(for: token)

        case let .fallback(pid, wid):
            if let currentTarget = controller.currentKeyboardFocusTargetForRendering(),
               !currentTarget.isManaged,
               currentTarget.pid == pid,
               currentTarget.windowId == wid
            {
                return currentTarget
            }

            guard !strictFallbackFocusMatch,
                  let fallbackAXRef = resolveAXRef(
                      for: ownerState.owner,
                      target: nil
                  )
            else {
                return nil
            }

            return KeyboardFocusTarget(
                token: WindowToken(pid: pid, windowId: wid),
                axRef: fallbackAXRef,
                workspaceId: nil,
                isManaged: false
            )

        case .none:
            return nil
        }
    }

    private func recordTrace(
        source: BorderReconcileSource,
        action: BorderTraceAction,
        reason: String,
        rawFocus: KeyboardFocusTarget?,
        frame: CGRect?,
        orderingDecision: String?
    ) {
        let record = BorderTraceRecord(
            timestamp: Date(),
            source: source,
            rawFocus: rawFocusDescription(rawFocus),
            owner: ownerState.owner,
            action: action,
            reason: reason,
            generation: ownerState.generation,
            frame: frame,
            orderingDecision: orderingDecision
        )

        if trace.count == Self.traceLimit {
            trace.removeFirst()
        }
        trace.append(record)

        if Self.traceLoggingEnabled {
            let focus = record.rawFocus ?? "nil"
            let frameString = frame.map(String.init(describing:)) ?? "nil"
            let ordering = orderingDecision ?? "nil"
            fputs(
                "[BorderTrace] source=\(source.rawValue) raw_focus=\(focus) owner=\(String(describing: record.owner)) action=\(action.rawValue) reason=\(reason) generation=\(record.generation) frame=\(frameString) ordering=\(ordering)\n",
                stderr
            )
        }
    }

    private func rawFocusDescription(_ target: KeyboardFocusTarget?) -> String? {
        guard let target else { return nil }
        if target.isManaged {
            return "token=\(target.token)"
        }
        return "pid=\(target.pid) wid=\(target.windowId)"
    }

    private func shouldDeferBorderUpdates(for workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller else { return false }

        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        if state.viewOffsetPixels.isAnimating {
            return true
        }

        if controller.layoutRefreshController.hasDwindleAnimationRunning(in: workspaceId) {
            return true
        }

        guard let engine = controller.niriEngine else { return false }
        if engine.hasAnyWindowAnimationsRunning(in: workspaceId) {
            return true
        }
        if engine.hasAnyColumnAnimationsRunning(in: workspaceId) {
            return true
        }
        return false
    }

    private func isManagedWindowFullscreen(_ token: WindowToken) -> Bool {
        guard let controller else { return false }

        if controller.niriEngine?.findNode(for: token)?.isFullscreen == true {
            return true
        }

        if controller.dwindleEngine?.findNode(for: token)?.isFullscreen == true {
            return true
        }

        return false
    }
}
