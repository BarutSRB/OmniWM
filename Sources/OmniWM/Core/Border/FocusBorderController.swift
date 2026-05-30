import CoreGraphics
import Foundation
import os

enum ManagedBorderReapplyPhase: String, Equatable {
    case postLayout
    case animationSettled
    case retryExhaustedFallback
}

enum BorderFrameSource: Equatable {
    case layout
    case observed
}

@MainActor
final class FocusBorderController {
    private enum RenderEligibility {
        case clear
        case hide
        case update
    }

    weak var controller: WMController?
    var observedFrameProviderForTests: ((AXWindowRef) -> CGRect?)?
    var suppressNextRenderForTests: ((KeyboardFocusTarget) -> Bool)?
    var suppressNextFrameHintForTests: ((WindowToken) -> Bool)?

    private let borderManager: BorderManager
    private var lastAXConfirmedTarget: KeyboardFocusTarget?
    private var requiresFocusValidationBeforeRender = false
    private var suppressedManagedTargets: Set<WindowToken> = []

    init(
        controller: WMController,
        borderManager: BorderManager = .init()
    ) {
        self.controller = controller
        self.borderManager = borderManager
    }

    @discardableResult
    func focusChanged(
        to target: KeyboardFocusTarget?,
        preferredFrame: CGRect? = nil,
        preferredFrameSource: BorderFrameSource = .layout,
        forceOrdering: Bool = true
    ) -> Bool {
        if let target {
            WMLog.focus.debug("Focus changed to: token=\(String(describing: target.token))")
        }
        lastAXConfirmedTarget = target
        requiresFocusValidationBeforeRender = false
        if let target {
            suppressedManagedTargets.remove(target.token)
        }
        return refresh(
            preferredFrame: preferredFrame,
            preferredFrameSource: preferredFrameSource,
            forceOrdering: forceOrdering
        )
    }

    @discardableResult
    func refresh(
        preferredFrame: CGRect? = nil,
        preferredFrameSource: BorderFrameSource = .layout,
        forceOrdering: Bool = false
    ) -> Bool {
        guard let target = lastAXConfirmedTarget else {
            borderManager.hideBorder()
            return false
        }

        if requiresFocusValidationBeforeRender {
            guard isStillKeyboardFocused(target) else {
                clear()
                return false
            }
            requiresFocusValidationBeforeRender = false
        }

        return render(
            target: target,
            preferredFrame: preferredFrame,
            preferredFrameSource: preferredFrameSource,
            forceOrdering: forceOrdering
        )
    }

    @discardableResult
    func updateFrameHint(
        for token: WindowToken,
        frame: CGRect,
        source: BorderFrameSource = .layout,
        forceOrdering: Bool = false
    ) -> Bool {
        guard lastAXConfirmedTarget?.token == token else { return false }
        if suppressNextFrameHintForTests?(token) == true {
            suppressNextFrameHintForTests = nil
            return false
        }
        return refresh(
            preferredFrame: frame,
            preferredFrameSource: source,
            forceOrdering: forceOrdering
        )
    }

    func hide() {
        WMLog.focus.debug("Focus border hidden")
        requiresFocusValidationBeforeRender = lastAXConfirmedTarget != nil
        borderManager.hideBorder()
    }

    func clear() {
        WMLog.focus.debug("Focus cleared")
        lastAXConfirmedTarget = nil
        requiresFocusValidationBeforeRender = false
        borderManager.hideBorder()
    }

    func clear(
        matching token: WindowToken? = nil,
        pid: pid_t? = nil
    ) {
        clearSuppressedManagedTargets(matching: token, pid: pid)
        guard let target = lastAXConfirmedTarget else { return }
        let matchesToken = token.map { target.token == $0 } ?? true
        let matchesPid = pid.map { target.pid == $0 } ?? true
        guard matchesToken, matchesPid else { return }
        clear()
    }

    @discardableResult
    func clearCurrentTarget(
        matching pid: pid_t,
        where shouldClear: (KeyboardFocusTarget) -> Bool
    ) -> KeyboardFocusTarget? {
        guard let target = lastAXConfirmedTarget,
              target.pid == pid,
              shouldClear(target)
        else { return nil }
        clear()
        return target
    }

    func rekeyFocusedTarget(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        axRef: AXWindowRef,
        workspaceId: WorkspaceDescriptor.ID?
    ) {
        if suppressedManagedTargets.remove(oldToken) != nil {
            suppressedManagedTargets.insert(newToken)
        }
        guard let target = lastAXConfirmedTarget,
              target.token == oldToken
        else { return }
        lastAXConfirmedTarget = KeyboardFocusTarget(
            token: newToken,
            axRef: axRef,
            workspaceId: workspaceId,
            isManaged: target.isManaged
        )
        requiresFocusValidationBeforeRender = true
    }

    func updateFocusedTargetWorkspace(
        matching token: WindowToken,
        axRef: AXWindowRef,
        workspaceId: WorkspaceDescriptor.ID?
    ) {
        guard let target = lastAXConfirmedTarget,
              target.token == token
        else { return }
        lastAXConfirmedTarget = KeyboardFocusTarget(
            token: token,
            axRef: axRef,
            workspaceId: workspaceId,
            isManaged: workspaceId != nil
        )
    }

    func setEnabled(_ enabled: Bool) {
        borderManager.setEnabled(enabled)
        if enabled {
            _ = refresh(forceOrdering: true)
        }
    }

    func updateConfig(_ config: BorderConfig) {
        borderManager.updateConfig(config)
        if config.enabled {
            _ = refresh(forceOrdering: true)
        }
    }

    func cleanup() {
        lastAXConfirmedTarget = nil
        requiresFocusValidationBeforeRender = false
        suppressedManagedTargets.removeAll()
        borderManager.cleanup()
    }

    func suppressManagedTarget(_ token: WindowToken) {
        suppressedManagedTargets.insert(token)
    }

    func isManagedTargetSuppressed(_ token: WindowToken) -> Bool {
        suppressedManagedTargets.contains(token)
    }

    var currentTarget: KeyboardFocusTarget? {
        lastAXConfirmedTarget
    }

    var lastAppliedFocusedWindowIdForTests: Int? {
        borderManager.lastAppliedFocusedWindowIdForTests
    }

    var lastAppliedFocusedFrameForTests: CGRect? {
        borderManager.lastAppliedFocusedFrameForTests
    }

    @discardableResult
    private func render(
        target: KeyboardFocusTarget,
        preferredFrame: CGRect?,
        preferredFrameSource: BorderFrameSource,
        forceOrdering: Bool
    ) -> Bool {
        guard controller != nil else { return false }

        if suppressNextRenderForTests?(target) == true {
            suppressNextRenderForTests = nil
            return false
        }

        switch renderEligibility(for: target) {
        case .clear:
            clear()
            return false
        case .hide:
            borderManager.hideBorder()
            return false
        case .update:
            break
        }

        guard let frame = resolveFrame(
            for: target,
            preferredFrame: preferredFrame,
            preferredFrameSource: preferredFrameSource
        ) else {
            borderManager.hideBorder()
            return false
        }

        return borderManager.updateFocusedWindow(
            frame: frame,
            windowId: target.windowId,
            forceOrdering: forceOrdering
        )
    }

    private func renderEligibility(for target: KeyboardFocusTarget) -> RenderEligibility {
        guard let controller else { return .clear }

        if controller.isOwnedWindow(windowNumber: target.windowId) {
            return .clear
        }

        if target.isManaged,
           controller.workspaceManager.entry(for: target.token) == nil
        {
            suppressedManagedTargets.remove(target.token)
            return .clear
        }

        if target.isManaged,
           suppressedManagedTargets.contains(target.token)
        {
            return .hide
        }

        if controller.workspaceManager.hasPendingNativeFullscreenTransition {
            return .hide
        }

        if target.isManaged,
           (controller.workspaceManager.isAppFullscreenActive || isManagedWindowFullscreen(target.token))
        {
            return .hide
        }

        if target.isManaged,
           let entry = controller.workspaceManager.entry(for: target.token),
           !controller.isManagedWindowDisplayable(entry.handle)
        {
            return .hide
        }

        return .update
    }

    private func isStillKeyboardFocused(_ target: KeyboardFocusTarget) -> Bool {
        guard let controller else { return false }
        guard controller.hasStartedServices else { return true }
        return controller.axEventHandler.focusedWindowToken(for: target.pid) == target.token
    }

    private func clearSuppressedManagedTargets(
        matching token: WindowToken?,
        pid: pid_t?
    ) {
        if let token {
            suppressedManagedTargets.remove(token)
            return
        }
        if let pid {
            suppressedManagedTargets = suppressedManagedTargets.filter { $0.pid != pid }
        }
    }

    private func resolveFrame(
        for target: KeyboardFocusTarget,
        preferredFrame: CGRect?,
        preferredFrameSource: BorderFrameSource
    ) -> CGRect? {
        guard let controller else { return nil }
        let preferred = preferredFrame

        if target.isManaged,
           let entry = controller.workspaceManager.entry(for: target.token)
        {
            if let pendingFrame = controller.axManager.pendingFrameWrite(for: entry.windowId) {
                return pendingFrame
            }

            if preferredFrameSource == .observed, let preferred {
                return preferred
            }

            var _cachedObserved: CGRect?? = .none
            func cachedObserved() -> CGRect? {
                if case let .some(value) = _cachedObserved { return value }
                let result = observedFrame(for: entry.axRef)
                _cachedObserved = .some(result)
                return result
            }

            if entry.managedReplacementMetadata != nil, let observed = cachedObserved() {
                return observed
            }

            let hasRecentFrameWriteFailure = controller.axManager.recentFrameWriteFailure(for: entry.windowId) != nil

            if !hasRecentFrameWriteFailure, let preferred {
                return preferred
            }

            if hasRecentFrameWriteFailure, let observed = cachedObserved() {
                return observed
            }

            if let preferred {
                return preferred
            }

            if let frame = controller.axManager.lastAppliedFrame(for: entry.windowId) {
                return frame
            }

            if let frame = controller.preferredKeyboardFocusFrame(for: target.token) {
                return frame
            }

            if let observed = cachedObserved() {
                return observed
            }

            return nil
        }

        if preferredFrameSource == .observed, let preferred {
            return preferred
        }

        if let observed = observedFrame(for: target.axRef) {
            return observed
        }

        return preferred
    }

    private func observedFrame(for axRef: AXWindowRef) -> CGRect? {
        if let observedFrameProviderForTests {
            return observedFrameProviderForTests(axRef)
        }

        if let frame = AXWindowService.framePreferFast(axRef) {
            return frame
        }

        return try? AXWindowService.frame(axRef)
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
