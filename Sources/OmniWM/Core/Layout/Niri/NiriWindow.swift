// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

class NiriWindow: NiriNode {
    var token: WindowToken

    var sizingMode: SizingMode = .normal

    var height: WeightedSize = .default {
        didSet {
            if oldValue != height {
                invalidateAxisSolveInputs()
            }
        }
    }

    var savedHeight: WeightedSize?

    var windowWidth: WeightedSize = .default {
        didSet {
            if oldValue != windowWidth {
                invalidateAxisSolveInputs()
            }
        }
    }

    var constraints: WindowSizeConstraints = .unconstrained {
        didSet {
            if oldValue != constraints {
                invalidateAxisSolveInputs()
            }
        }
    }

    var resolvedHeight: CGFloat?

    var resolvedWidth: CGFloat?

    var heightFixedByConstraint: Bool = false

    var widthFixedByConstraint: Bool = false

    var lastFocusedTime: Date?

    var isHiddenInTabbedMode: Bool = false

    var moveXAnimation: MoveAnimation?
    var moveYAnimation: MoveAnimation?
    private(set) var moveYContainmentFrame: CGRect?

    init(token: WindowToken) {
        self.token = token
        super.init()
    }

    override var size: CGFloat {
        get {
            switch height {
            case let .auto(weight): weight
            case .fixed,
                 .preset: 1.0
            }
        }
        set {
            height = .auto(weight: newValue)
        }
    }

    var heightWeight: CGFloat {
        switch height {
        case let .auto(weight): weight
        case .fixed,
             .preset: 1.0
        }
    }

    var widthWeight: CGFloat {
        switch windowWidth {
        case let .auto(weight): weight
        case .fixed,
             .preset: 1.0
        }
    }

    var isFullscreen: Bool {
        sizingMode == .fullscreen
    }

    var isMaximized: Bool {
        sizingMode == .maximized
    }

    func renderOffset(at time: TimeInterval = CACurrentMediaTime()) -> CGPoint {
        var offset = CGPoint.zero
        if let moveX = moveXAnimation {
            offset.x = moveX.currentOffset(at: time)
        }
        if let moveY = moveYAnimation {
            offset.y = moveY.currentOffset(at: time)
        }
        return offset
    }

    func animateMoveFrom(
        displacement: CGPoint,
        yContainmentFrame: CGRect? = nil,
        clock: AnimationClock?,
        config: SpringConfig = .default,
        displayRefreshRate: Double = 60.0,
        animated: Bool
    ) {
        guard animated else {
            stopMoveAnimations()
            return
        }

        let now = clock?.now() ?? CACurrentMediaTime()
        let currentOffset = renderOffset(at: now)
        let currentVelX = moveXAnimation?.currentVelocity(at: now) ?? 0
        let currentVelY = moveYAnimation?.currentVelocity(at: now) ?? 0

        if displacement.x != 0 {
            let totalOffsetX = displacement.x + currentOffset.x
            let anim = SpringAnimation(
                from: 1,
                to: 0,
                initialVelocity: currentVelX,
                startTime: now,
                config: config,
                displayRefreshRate: displayRefreshRate
            )
            moveXAnimation = MoveAnimation(animation: anim, fromOffset: totalOffsetX)
        }
        if displacement.y != 0 {
            let totalOffsetY = displacement.y + currentOffset.y
            let anim = SpringAnimation(
                from: 1,
                to: 0,
                initialVelocity: currentVelY,
                startTime: now,
                config: config,
                displayRefreshRate: displayRefreshRate
            )
            moveYAnimation = MoveAnimation(animation: anim, fromOffset: totalOffsetY)
            moveYContainmentFrame = yContainmentFrame
        }
    }

    func tickMoveAnimations(at time: TimeInterval) -> Bool {
        var running = false
        if let moveX = moveXAnimation {
            if moveX.isComplete(at: time) {
                moveXAnimation = nil
            } else {
                running = true
            }
        }
        if let moveY = moveYAnimation {
            if moveY.isComplete(at: time) {
                moveYAnimation = nil
                moveYContainmentFrame = nil
            } else {
                running = true
            }
        }
        return running
    }

    func stopMoveAnimations() {
        moveXAnimation = nil
        moveYAnimation = nil
        moveYContainmentFrame = nil
    }

    var hasMoveAnimationsRunning: Bool {
        moveXAnimation != nil || moveYAnimation != nil
    }

    var hasAnyAnimationRunning: Bool {
        hasMoveAnimationsRunning
    }
}
