import AppKit
import Foundation
import QuartzCore

@MainActor
final class OverviewAnimator {
    private weak var controller: OverviewController?

    private var openAnimation: SpringAnimation?
    private var closeAnimation: SpringAnimation?
    private var targetWindowHandle: WindowHandle?

    private var displayLink: CADisplayLink?
    private var displayId: CGDirectDisplayID?

    private let animationConfig: SpringConfig = .balanced

    var isAnimating: Bool {
        openAnimation != nil || closeAnimation != nil
    }

    var currentProgress: Double {
        let now = CACurrentMediaTime()
        if let open = openAnimation {
            return open.value(at: now)
        }
        if let close = closeAnimation {
            return 1.0 - close.value(at: now)
        }
        return 0
    }

    init(controller: OverviewController) {
        self.controller = controller
    }

    func startOpenAnimation(displayId: CGDirectDisplayID, refreshRate: Double) {
        closeAnimation = nil
        targetWindowHandle = nil

        let now = CACurrentMediaTime()
        openAnimation = SpringAnimation(
            from: 0,
            to: 1,
            startTime: now,
            config: animationConfig,
            displayRefreshRate: refreshRate
        )

        startDisplayLink(displayId: displayId)
    }

    func startCloseAnimation(
        targetWindow: WindowHandle?,
        displayId: CGDirectDisplayID,
        refreshRate: Double
    ) {
        openAnimation = nil
        targetWindowHandle = targetWindow

        let now = CACurrentMediaTime()
        closeAnimation = SpringAnimation(
            from: 0,
            to: 1,
            startTime: now,
            config: animationConfig,
            displayRefreshRate: refreshRate
        )

        startDisplayLink(displayId: displayId)
    }

    func cancelAnimation() {
        openAnimation = nil
        closeAnimation = nil
        targetWindowHandle = nil
        stopDisplayLink()
    }

    private func startDisplayLink(displayId: CGDirectDisplayID) {
        stopDisplayLink()

        self.displayId = displayId

        guard let screen = NSScreen.screens.first(where: { $0.displayId == displayId }) else {
            return
        }

        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.remove(from: .main, forMode: .common)
        displayLink?.invalidate()
        displayLink = nil
        displayId = nil
    }

    @objc private func tick(_ displayLink: CADisplayLink) {
        let targetTime = displayLink.targetTimestamp

        if let open = openAnimation {
            let progress = open.value(at: targetTime)
            controller?.updateAnimationProgress(progress, state: .opening(progress: progress))

            if open.isComplete(at: targetTime) {
                openAnimation = nil
                stopDisplayLink()
                controller?.onAnimationComplete(state: .open)
            }
            return
        }

        if let close = closeAnimation {
            let progress = close.value(at: targetTime)
            controller?.updateAnimationProgress(
                1.0 - progress,
                state: .closing(targetWindow: targetWindowHandle, progress: progress)
            )

            if close.isComplete(at: targetTime) {
                let target = targetWindowHandle
                closeAnimation = nil
                targetWindowHandle = nil
                stopDisplayLink()
                controller?.onAnimationComplete(state: .closed)

                if let target {
                    controller?.focusTargetWindow(target)
                }
            }
            return
        }
    }

    func targetWindow() -> WindowHandle? {
        targetWindowHandle
    }

    deinit {
        MainActor.assumeIsolated {
            stopDisplayLink()
        }
    }
}
