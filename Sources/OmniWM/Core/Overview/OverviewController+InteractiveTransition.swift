// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension OverviewController {
    func activateForInteraction() {
        activateOwnedSession()
        windowSession.primaryOverviewWindow()?.show(asKeyWindow: true)
    }

    func commitOpen() {
        activateForInteraction()
        animator?.startOpenAnimation(displayIds: windowSession.displayIds)
    }

    func reverseClosingTransition() {
        guard case .closing = state else { return }
        resumeOpening()
        activateForInteraction()
        if motionPolicy.animationsEnabled {
            animator?.startOpenAnimation(displayIds: windowSession.displayIds)
        } else {
            animator?.settle(at: 1)
        }
    }

    var isInteractiveTransitionActive: Bool {
        animator?.isTracking == true
    }

    var transitionProgress: Double {
        animator?.currentProgress ?? 0
    }

    func presentProgress(_ progress: Double) {
        windowSession.presentProgress(progress)
    }

    func beginInteractiveTransition() -> Bool {
        guard motionPolicy.animationsEnabled, let animator else { return false }
        guard !animator.isTracking else { return true }
        switch state {
        case .closed:
            guard beginOpening() else { return false }
        case .open:
            let dismissal = input.selectionDismissal()
            resumeOpening()
            focusSession.pendingDismissReason = dismissal.reason
            focusSession.pendingFocusTargetWindow = dismissal.targetWindow
        case .closing:
            let reason = focusSession.pendingDismissReason
            let targetWindow = focusSession.pendingFocusTargetWindow
            resumeOpening()
            focusSession.pendingDismissReason = reason
            focusSession.pendingFocusTargetWindow = targetWindow
        case .opening:
            break
        }
        animator.beginTracking()
        return true
    }

    func updateInteractiveTransition(cumulativeUnits: Double, timestamp: TimeInterval) {
        animator?.track(
            cumulativeProgress: TrackpadGestureIntent.overviewProgress(units: cumulativeUnits),
            timestamp: timestamp
        )
    }

    func endInteractiveTransition(timestamp: TimeInterval?) {
        guard let animator, let target = animator.endTracking(timestamp: timestamp) else { return }
        guard case .opening = state else {
            animator.cancelAnimation()
            return
        }
        if target == 1 {
            commitOpen()
        } else {
            dismiss(
                reason: focusSession.pendingDismissReason,
                targetWindow: focusSession.pendingFocusTargetWindow,
                animated: true
            )
        }
    }
}
