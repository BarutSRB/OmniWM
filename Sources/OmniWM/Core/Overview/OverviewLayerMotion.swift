// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import QuartzCore

@MainActor
struct OverviewLayerMotion {
    private let layer: CALayer
    private let position: CGPoint
    private let bounds: CGRect
    private let opacity: Float
    private let modelPosition: CGPoint
    private let modelBounds: CGRect
    private let modelOpacity: Float

    init(_ layer: CALayer) {
        self.layer = layer
        let presentation = layer.presentation()
        if let animation = layer.animation(forKey: "overview.position") as? CABasicAnimation {
            position = presentation?.position ?? (animation.fromValue as? NSValue)?.pointValue ?? layer.position
        } else {
            position = layer.position
        }
        if let animation = layer.animation(forKey: "overview.bounds") as? CABasicAnimation {
            bounds = presentation?.bounds ?? (animation.fromValue as? NSValue)?.rectValue ?? layer.bounds
        } else {
            bounds = layer.bounds
        }
        if let animation = layer.animation(forKey: "overview.opacity") as? CABasicAnimation {
            opacity = presentation?.opacity ?? (animation.fromValue as? NSNumber)?.floatValue ?? layer.opacity
        } else {
            opacity = layer.opacity
        }
        modelPosition = layer.position
        modelBounds = layer.bounds
        modelOpacity = layer.opacity
    }

    func apply(_ transition: OverviewNativeTransition, at time: CFTimeInterval, replacing: Bool) {
        guard time < transition.startTime + transition.duration else {
            Self.remove(from: layer)
            return
        }
        guard replacing || modelPosition != layer.position || modelBounds != layer.bounds || modelOpacity != layer
            .opacity else { return }
        let animation = transition.makeAnimation(keyPath: "")
        if replacing {
            animation.beginTime = layer.convertTime(transition.startTime, from: nil)
        } else {
            let remaining = transition.startTime + transition.duration - time
            let rate = transition.duration / remaining
            animation.stiffness *= rate * rate
            animation.damping *= rate
            animation.initialVelocity = 0
            animation.duration = remaining
            animation.beginTime = layer.convertTime(time, from: nil)
        }
        if replacing || modelPosition != layer.position {
            add(
                animation,
                keyPath: "position",
                from: NSValue(point: position),
                to: NSValue(point: layer.position),
                changed: position != layer.position
            )
        }
        if replacing || modelBounds != layer.bounds {
            add(
                animation,
                keyPath: "bounds",
                from: NSValue(rect: bounds),
                to: NSValue(rect: layer.bounds),
                changed: bounds != layer.bounds
            )
        }
        if replacing || modelOpacity != layer.opacity {
            add(
                animation,
                keyPath: "opacity",
                from: opacity,
                to: layer.opacity,
                changed: opacity != layer.opacity
            )
        }
    }

    static func remove(from layer: CALayer) {
        for key in ["position", "bounds", "opacity"] { layer.removeAnimation(forKey: "overview.\(key)") }
    }

    private func add(
        _ animation: CASpringAnimation,
        keyPath: String,
        from: Any,
        to: Any,
        changed: Bool
    ) {
        let key = "overview.\(keyPath)"
        guard changed else {
            layer.removeAnimation(forKey: key)
            return
        }
        animation.keyPath = keyPath
        animation.fromValue = from
        animation.toValue = to
        layer.add(animation, forKey: key)
    }
}
