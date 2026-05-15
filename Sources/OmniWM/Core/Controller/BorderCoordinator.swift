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

enum BorderFrameSource: Equatable {
    case layout
    case observed
}

@MainActor
final class BorderCoordinator {
    private enum RenderEligibility {
        case hide
        case skip
        case update
    }

    private struct BorderRenderRequest {
        let target: KeyboardFocusTarget
        let frame: CGRect
        let forceOrdering: Bool
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
        preferredFrameSource: BorderFrameSource = .layout,
        policy: KeyboardFocusBorderRenderPolicy,
        forceOrdering: Bool = false
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

        if policy.shouldDeferForAnimations,
           let workspaceId = target.workspaceId,
           shouldDeferBorderUpdates(for: workspaceId)
        {
            return false
        }

        guard let request = renderRequest(
            for: target,
            preferredFrame: preferredFrame,
            preferredFrameSource: preferredFrameSource,
            forceOrdering: forceOrdering
        ) else {
            if target.isManaged, policy == .coordinated {
                return false
            }
            controller.borderManager.hideBorder()
            return false
        }

        controller.borderManager.updateFocusedWindow(
            frame: request.frame,
            windowId: request.target.windowId,
            forceOrdering: request.forceOrdering
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

    private func renderRequest(
        for target: KeyboardFocusTarget,
        preferredFrame: CGRect?,
        preferredFrameSource: BorderFrameSource,
        forceOrdering: Bool
    ) -> BorderRenderRequest? {
        guard let frame = resolveFrame(
            for: target,
            preferredFrame: preferredFrame,
            preferredFrameSource: preferredFrameSource
        ) else {
            return nil
        }

        return BorderRenderRequest(
            target: target,
            frame: frame,
            forceOrdering: forceOrdering
        )
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

            if entry.managedReplacementMetadata != nil, let observed = observedFrame(for: entry.axRef) {
                return observed
            }

            let hasRecentFrameWriteFailure = controller.axManager.recentFrameWriteFailure(for: entry.windowId) != nil

            if !hasRecentFrameWriteFailure, let preferred {
                return preferred
            }

            if hasRecentFrameWriteFailure, let observed = observedFrame(for: entry.axRef) {
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

            if let observed = observedFrame(for: entry.axRef) {
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
