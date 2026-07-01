// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import QuartzCore

@MainActor
final class AnimationDriver {
    nonisolated static let gestureWorkingAreaMovement: Double = 1200.0

    final class ViewportGesture {
        let tracker = SwipeTracker()
        let isTrackpad: Bool
        private(set) var normFactor: Double = 1.0

        init(isTrackpad: Bool) {
            self.isTrackpad = isTrackpad
        }

        var relativeOffset: Double {
            tracker.position * normFactor
        }

        var velocity: Double {
            tracker.velocity() * normFactor
        }

        func update(delta: Double, timestamp: TimeInterval, viewportWidth: Double) {
            tracker.push(delta: delta, timestamp: timestamp)
            if isTrackpad {
                normFactor = viewportWidth / AnimationDriver.gestureWorkingAreaMovement
            }
        }
    }

    enum ViewportMotion {
        case gesture(ViewportGesture)
        case spring(SpringAnimation)
        case deceleration(DecelerationAnimation)
    }

    struct GestureEndSample {
        let relativeOffset: Double
        let relativeProjectedOffset: Double
    }

    private var motions: [WorkspaceDescriptor.ID: ViewportMotion] = [:]

    func hasMotion(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        motions[workspaceId] != nil
    }

    func hasGesture(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        if case .gesture = motions[workspaceId] { return true }
        return false
    }

    func trackpadGestureActive(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        if case let .gesture(gesture) = motions[workspaceId] { return gesture.isTrackpad }
        return false
    }

    func liveViewOffset(
        in workspaceId: WorkspaceDescriptor.ID,
        semanticOffset: CGFloat,
        at time: TimeInterval = CACurrentMediaTime()
    ) -> CGFloat? {
        switch motions[workspaceId] {
        case let .gesture(gesture):
            semanticOffset + CGFloat(gesture.relativeOffset)
        case let .spring(animation):
            CGFloat(animation.value(at: time))
        case let .deceleration(animation):
            CGFloat(animation.value(at: time))
        case nil:
            nil
        }
    }

    func settledVisibilityOffset(
        in workspaceId: WorkspaceDescriptor.ID,
        semanticOffset: CGFloat
    ) -> CGFloat? {
        switch motions[workspaceId] {
        case .spring,
             .deceleration:
            semanticOffset
        case .gesture,
             nil:
            nil
        }
    }

    func plannedRenderOffset(
        in workspaceId: WorkspaceDescriptor.ID,
        localState: ViewportState,
        storeOffset: CGFloat,
        at time: TimeInterval = CACurrentMediaTime()
    ) -> CGFloat {
        let transition = localState.offsetTransition
        switch transition.kind {
        case .spring,
             .deceleration:
            let base = liveViewOffset(in: workspaceId, semanticOffset: storeOffset, at: time) ?? storeOffset
            return base + transition.rebaseDelta
        case .jump:
            return localState.viewOffset
        case nil:
            switch motions[workspaceId] {
            case .gesture:
                return liveViewOffset(in: workspaceId, semanticOffset: localState.viewOffset, at: time)
                    ?? localState.viewOffset
            case let .spring(animation):
                return CGFloat(animation.value(at: time)) + transition.rebaseDelta
            case let .deceleration(animation):
                return CGFloat(animation.value(at: time)) + transition.rebaseDelta
            case nil:
                return localState.viewOffset
            }
        }
    }

    func beginGesture(in workspaceId: WorkspaceDescriptor.ID, isTrackpad: Bool) {
        motions[workspaceId] = .gesture(ViewportGesture(isTrackpad: isTrackpad))
    }

    func updateGesture(
        in workspaceId: WorkspaceDescriptor.ID,
        delta: Double,
        timestamp: TimeInterval,
        isTrackpad: Bool,
        viewportWidth: Double
    ) {
        guard case let .gesture(gesture) = motions[workspaceId], gesture.isTrackpad == isTrackpad else { return }
        gesture.update(delta: delta, timestamp: timestamp, viewportWidth: viewportWidth)
    }

    func sampleGestureEnd(
        in workspaceId: WorkspaceDescriptor.ID,
        isTrackpad: Bool? = nil,
        viewportWidth: Double,
        timestamp: TimeInterval?
    ) -> GestureEndSample? {
        guard case let .gesture(gesture) = motions[workspaceId] else { return nil }
        if let isTrackpad, gesture.isTrackpad != isTrackpad { return nil }
        gesture.update(delta: 0, timestamp: timestamp ?? CACurrentMediaTime(), viewportWidth: viewportWidth)
        return GestureEndSample(
            relativeOffset: gesture.relativeOffset,
            relativeProjectedOffset: gesture.tracker.projectedEndPosition() * gesture.normFactor
        )
    }

    func reconcileViewportCommit(
        workspaceId: WorkspaceDescriptor.ID,
        previous: ViewportState?,
        next: ViewportState,
        transition: OffsetTransition
    ) {
        recordViewportCommitTrace(
            workspaceId: workspaceId,
            previous: previous,
            next: next,
            transition: transition
        )
        let rebaseDelta = Double(transition.rebaseDelta)
        if rebaseDelta != 0 {
            switch motions[workspaceId] {
            case let .spring(animation):
                animation.offsetBy(rebaseDelta)
            case let .deceleration(animation):
                animation.offsetBy(rebaseDelta)
            default:
                break
            }
        }

        let time = CACurrentMediaTime()
        let origin = gestureCommitOrigin(
            workspaceId: workspaceId,
            previous: previous,
            next: next,
            rebaseDelta: rebaseDelta,
            at: time
        )

        switch transition.kind {
        case nil:
            break

        case .jump:
            motions.removeValue(forKey: workspaceId)

        case let .spring(config):
            motions[workspaceId] = .spring(
                SpringAnimation(
                    from: origin.from,
                    to: Double(next.viewOffset),
                    initialVelocity: origin.velocity,
                    startTime: time,
                    config: config,
                    displayRefreshRate: next.displayRefreshRate
                )
            )

        case .deceleration:
            motions[workspaceId] = .deceleration(
                DecelerationAnimation(
                    from: origin.from,
                    velocity: origin.velocity,
                    startTime: time
                )
            )
        }
    }

    private func recordViewportCommitTrace(
        workspaceId: WorkspaceDescriptor.ID,
        previous: ViewportState?,
        next: ViewportState,
        transition: OffsetTransition
    ) {
        guard transition.kind != nil || transition.rebaseDelta != 0 else { return }
        let kind = switch transition.kind {
        case .jump: "jump"
        case .spring: "spring"
        case .deceleration: "decelerate"
        case nil: "rebase"
        }
        NiriLayoutTrace.record(
            .viewport,
            workspaceId: workspaceId,
            "\(kind) \(Int(previous?.viewOffset ?? next.viewOffset))→\(Int(next.viewOffset)) col=\(next.activeColumnIndex) rebase=\(Int(transition.rebaseDelta))"
        )
    }

    private func gestureCommitOrigin(
        workspaceId: WorkspaceDescriptor.ID,
        previous: ViewportState?,
        next: ViewportState,
        rebaseDelta: Double,
        at time: TimeInterval
    ) -> (from: Double, velocity: Double) {
        switch motions[workspaceId] {
        case let .gesture(gesture):
            (Double(previous?.viewOffset ?? next.viewOffset) + rebaseDelta + gesture.relativeOffset, gesture.velocity)
        case let .spring(animation):
            (animation.value(at: time), animation.velocity(at: time))
        case let .deceleration(animation):
            (animation.value(at: time), animation.velocity(at: time))
        case nil:
            (Double(previous?.viewOffset ?? next.viewOffset) + rebaseDelta, 0)
        }
    }

    func tick(in workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) -> Bool {
        switch motions[workspaceId] {
        case .gesture:
            return true
        case let .spring(animation):
            if animation.isComplete(at: time) {
                motions.removeValue(forKey: workspaceId)
                return false
            }
            return true
        case let .deceleration(animation):
            if animation.isComplete(at: time) {
                motions.removeValue(forKey: workspaceId)
                return false
            }
            return true
        case nil:
            return false
        }
    }

    func removeMotions<S: Sequence>(for workspaceIds: S) where S.Element == WorkspaceDescriptor.ID {
        for workspaceId in workspaceIds {
            motions.removeValue(forKey: workspaceId)
        }
    }
}
