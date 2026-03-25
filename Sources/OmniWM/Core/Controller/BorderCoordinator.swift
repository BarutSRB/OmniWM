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

@MainActor
final class BorderCoordinator {
    private static let ghosttyBundleId = "com.mitchellh.ghostty"

    private enum RenderEligibility {
        case hide
        case skip
        case update
    }

    weak var controller: WMController?
    var observedFrameProviderForTests: ((AXWindowRef) -> CGRect?)?
    var suppressNextKeyboardFocusBorderRenderForTests: ((KeyboardFocusTarget, KeyboardFocusBorderRenderPolicy) -> Bool)?
    var suppressNextManagedBorderUpdateForTests: ((WindowToken, KeyboardFocusBorderRenderPolicy) -> Bool)?

    init(controller: WMController) {
        self.controller = controller
    }

    @discardableResult
    func renderBorder(
        for target: KeyboardFocusTarget?,
        preferredFrame: CGRect? = nil,
        policy: KeyboardFocusBorderRenderPolicy
    ) -> Bool {
        guard let controller else { return false }
        guard let target else {
            controller.borderManager.hideBorder()
            return false
        }

        if suppressNextKeyboardFocusBorderRenderForTests?(target, policy) == true {
            suppressNextKeyboardFocusBorderRenderForTests = nil
            return false
        }

        if suppressNextManagedBorderUpdateForTests?(target.token, policy) == true {
            suppressNextManagedBorderUpdateForTests = nil
            return false
        }

        switch renderEligibility(for: target, policy: policy) {
        case .hide:
            controller.borderManager.hideBorder()
            return false
        case .skip:
            return false
        case .update:
            break
        }

        guard let frame = resolveFrame(for: target, preferredFrame: preferredFrame) else {
            controller.borderManager.hideBorder()
            return false
        }

        if policy.shouldDeferForAnimations,
           let workspaceId = target.workspaceId,
           shouldDeferBorderUpdates(for: workspaceId)
        {
            return false
        }

        controller.borderManager.updateFocusedWindow(
            frame: resolveGhosttyObservedFrame(for: target, fallback: frame),
            windowId: target.windowId
        )
        return true
    }

    private func renderEligibility(
        for target: KeyboardFocusTarget,
        policy _: KeyboardFocusBorderRenderPolicy
    ) -> RenderEligibility {
        guard let controller else { return .hide }

        if controller.isOwnedWindow(windowNumber: target.windowId) {
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
            return .skip
        }

        return .update
    }

    private func resolveFrame(
        for target: KeyboardFocusTarget,
        preferredFrame: CGRect?
    ) -> CGRect? {
        guard let controller else { return nil }

        if target.isManaged,
           let entry = controller.workspaceManager.entry(for: target.token)
        {
            let shouldPreferObservedFrame = controller.axManager.shouldPreferObservedFrame(for: entry.windowId)
            if !shouldPreferObservedFrame, let preferredFrame {
                return preferredFrame
            }

            return observedFrame(for: entry.axRef)
                ?? controller.axManager.lastAppliedFrame(for: entry.windowId)
                ?? (!shouldPreferObservedFrame
                    ? controller.niriEngine?.findNode(for: target.token).flatMap { $0.renderedFrame ?? $0.frame }
                    : nil)
                ?? preferredFrame
        }

        if let preferredFrame {
            return preferredFrame
        }

        return observedFrame(for: target.axRef)
    }

    private func resolveGhosttyObservedFrame(
        for target: KeyboardFocusTarget,
        fallback providedFrame: CGRect
    ) -> CGRect {
        guard let controller,
              controller.appInfoCache.bundleId(for: target.pid) == Self.ghosttyBundleId
        else {
            return providedFrame
        }

        let axRef = controller.workspaceManager.entry(for: target.token)?.axRef ?? target.axRef

        return observedFrame(for: axRef) ?? providedFrame
    }

    private func observedFrame(for axRef: AXWindowRef) -> CGRect? {
        if let observedFrameProviderForTests,
           let frame = observedFrameProviderForTests(axRef)
        {
            return frame
        }

        if let frame = AXWindowService.framePreferFast(axRef) {
            return frame
        }

        return try? AXWindowService.frame(axRef)
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
        guard let engine = controller.niriEngine,
              let windowNode = engine.findNode(for: token)
        else {
            return false
        }
        return windowNode.isFullscreen
    }
}
