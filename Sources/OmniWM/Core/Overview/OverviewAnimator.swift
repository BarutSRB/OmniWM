// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

@MainActor
final class OverviewAnimationCompletion: NSObject, CAAnimationDelegate {
    weak var animator: OverviewAnimator?
    let displayId: CGDirectDisplayID
    let generation: UInt64

    init(animator: OverviewAnimator, displayId: CGDirectDisplayID, generation: UInt64) {
        self.animator = animator
        self.displayId = displayId
        self.generation = generation
    }

    func complete() {
        animator?.animationCompleted(displayId: displayId, generation: generation)
    }

    nonisolated func animationDidStop(_: CAAnimation, finished flag: Bool) {
        guard flag else { return }
        Task { @MainActor [self] in
            complete()
        }
    }
}

@MainActor
final class OverviewAnimator {
    typealias AnimationInstaller = @MainActor (
        CGDirectDisplayID,
        OverviewNativeTransition,
        OverviewAnimationCompletion
    ) -> Bool

    typealias MediaTimeProvider = @MainActor () -> CFTimeInterval

    private enum Transition {
        case opening
        case closing(targetWindow: WindowHandle?)
    }

    private struct Gesture {
        let baseline: Double
        let tracker = SwipeTracker(historyLimit: 0.15)
        var origin: Double?
        var progress: Double
        var velocity = 0.0
        var released = false
    }

    private weak var controller: OverviewController?
    private let animationInstaller: AnimationInstaller?
    private let mediaTimeProvider: MediaTimeProvider

    private var animation: OverviewNativeTransition?
    private var transition: Transition?
    private var gesture: Gesture?
    private var pendingDisplayIds: Set<CGDirectDisplayID> = []
    private var lastProgress = 0.0
    private var installing = false

    private(set) var generation: UInt64 = 0
    private(set) var completedGeneration: UInt64?
    private(set) var completionCount: UInt64 = 0

    var isAnimating: Bool {
        animation != nil
    }

    var isTracking: Bool {
        gesture.map { !$0.released } ?? false
    }

    var currentProgress: Double {
        animation?.value(at: mediaTimeProvider()) ?? gesture?.progress ?? lastProgress
    }

    var currentVelocity: Double {
        animation?.velocity(at: mediaTimeProvider()) ?? gesture?.velocity ?? 0
    }

    var activeDisplayIds: Set<CGDirectDisplayID> {
        pendingDisplayIds
    }

    init(
        controller: OverviewController,
        animationInstaller: AnimationInstaller? = nil,
        mediaTimeProvider: @escaping MediaTimeProvider = CACurrentMediaTime
    ) {
        self.controller = controller
        self.animationInstaller = animationInstaller
        self.mediaTimeProvider = mediaTimeProvider
    }

    func startOpenAnimation(displayIds: [CGDirectDisplayID]) {
        beginTransition(.opening, to: 1, displayIds: displayIds)
    }

    func startCloseAnimation(targetWindow: WindowHandle?, displayIds: [CGDirectDisplayID]) {
        beginTransition(.closing(targetWindow: targetWindow), to: 0, displayIds: displayIds)
    }

    func cancelAnimation() {
        settle(at: currentProgress)
    }

    func settle(at progress: Double) {
        lastProgress = progress
        gesture = nil
        discardAnimation()
    }

    func beginTracking() {
        guard !isTracking else { return }
        let progress = currentProgress
        discardAnimation()
        gesture = Gesture(baseline: OverviewNativeTransition.rubberBandInverse(progress), progress: progress)
        controller?.presentProgress(progress)
    }

    func track(cumulativeProgress: Double, timestamp: TimeInterval) {
        guard var gesture, !gesture.released else { return }
        let origin: Double
        if let latched = gesture.origin {
            origin = latched
        } else {
            origin = cumulativeProgress
            gesture.origin = origin
            gesture.tracker.reset()
            gesture.tracker.push(delta: 0, timestamp: timestamp)
        }
        let progress = OverviewNativeTransition.rubberBand(gesture.baseline + cumulativeProgress - origin)
        gesture.tracker.push(delta: progress - gesture.progress, timestamp: timestamp)
        gesture.progress = progress
        gesture.velocity = gesture.tracker.velocity()
        self.gesture = gesture
        controller?.presentProgress(progress)
    }

    func endTracking(timestamp: TimeInterval?) -> Double? {
        guard var gesture, !gesture.released else { return nil }
        if let timestamp, gesture.origin != nil {
            gesture.tracker.push(delta: 0, timestamp: timestamp)
            gesture.velocity = gesture.tracker.velocity()
        } else {
            gesture.velocity = 0
        }
        gesture.released = true
        self.gesture = gesture
        return OverviewNativeTransition.releaseTarget(progress: gesture.progress, velocity: gesture.velocity)
    }

    func targetWindow() -> WindowHandle? {
        guard case let .closing(targetWindow) = transition else { return nil }
        return targetWindow
    }

    func animationCompleted(displayId: CGDirectDisplayID, generation: UInt64) {
        guard generation == self.generation,
              pendingDisplayIds.remove(displayId) != nil,
              let animation
        else { return }
        record(.animationComplete, displayId: displayId, animation: animation, completed: true)
        completeTransition(generation: generation)
    }

    private func discardAnimation() {
        generation &+= 1
        pendingDisplayIds.removeAll(keepingCapacity: true)
        animation = nil
        transition = nil
        controller?.cancelAnimations()
    }

    private func beginTransition(
        _ transition: Transition,
        to: Double,
        displayIds: [CGDirectDisplayID]
    ) {
        let startTime = mediaTimeProvider()
        let from = animation?.value(at: startTime) ?? gesture?.progress ?? (to == 1 ? 0 : 1)
        let initialVelocity = animation?.velocity(at: startTime) ?? gesture?.velocity ?? 0
        let response = gesture.map { OverviewNativeTransition.compressedResponse(forReleaseVelocity: $0.velocity) }
            ?? OverviewNativeTransition.response
        gesture = nil
        generation &+= 1
        let animation = OverviewNativeTransition(
            generation: generation,
            startTime: startTime,
            from: from,
            to: to,
            initialVelocity: initialVelocity,
            response: response
        )
        completedGeneration = nil
        self.transition = transition
        self.animation = animation
        lastProgress = from
        pendingDisplayIds = Set(displayIds)
        installing = true
        for displayId in pendingDisplayIds {
            let completion = OverviewAnimationCompletion(
                animator: self,
                displayId: displayId,
                generation: generation
            )
            record(.animationSubmit, displayId: displayId, animation: animation, completed: false)
            let installed = if let animationInstaller {
                animationInstaller(displayId, animation, completion)
            } else {
                controller?.installAnimation(animation, on: displayId, completion: completion) ?? false
            }
            if !installed {
                pendingDisplayIds.remove(displayId)
            }
        }
        installing = false
        completeTransition(generation: generation)
    }

    private func completeTransition(generation: UInt64) {
        guard generation == self.generation,
              !installing,
              pendingDisplayIds.isEmpty,
              let transition
        else { return }

        completedGeneration = generation
        completionCount &+= 1
        animation = nil
        self.transition = nil

        switch transition {
        case .opening:
            lastProgress = 1
            controller?.onAnimationComplete(state: .open)
        case let .closing(targetWindow):
            lastProgress = 0
            controller?.completeCloseTransition(targetWindow: targetWindow)
        }
    }

    private func record(
        _ event: OverviewFrameTrace.Event,
        displayId: CGDirectDisplayID,
        animation: OverviewNativeTransition,
        completed: Bool
    ) {
        OverviewFrameTrace.shared.record(OverviewFrameTrace.Record(
            event: event,
            mediaTime: CACurrentMediaTime(),
            displayId: displayId,
            generation: animation.generation,
            sequence: 0,
            progress: completed ? animation.target : animation.from,
            durationMs: 0,
            waitMs: 0,
            targetLeadMs: 0,
            pendingInvalidations: 0,
            endpointScheduled: true,
            sessionCompleted: completed
        ))
    }
}
