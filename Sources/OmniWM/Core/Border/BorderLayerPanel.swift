// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import QuartzCore

@MainActor
class BorderLayerPanel: NSPanel {
    let borderLayer = CAShapeLayer()
    let glowColorLayer = CAGradientLayer()
    let glowMaskLayer = CALayer()
    private var glowBandLayers: [CAShapeLayer] = []
    private let gradientLayer = CAGradientLayer()
    private let gradientMaskLayer = CAShapeLayer()
    let containerLayer = CALayer()

    init(frame: CGRect) {
        super.init(
            contentRect: frame.integral,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isRestorable = false

        let view = NSView(frame: CGRect(origin: .zero, size: frame.integral.size))
        view.wantsLayer = true
        borderLayer.fillRule = .evenOdd
        borderLayer.strokeColor = nil
        borderLayer.actions = [
            "path": NSNull(), "fillColor": NSNull(), "bounds": NSNull(),
            "position": NSNull(), "contentsScale": NSNull(),
            "shadowColor": NSNull(), "shadowOpacity": NSNull(),
            "shadowRadius": NSNull(), "shadowOffset": NSNull(), "mask": NSNull()
        ]
        gradientLayer.isHidden = true
        gradientLayer.actions = [
            "colors": NSNull(), "startPoint": NSNull(), "endPoint": NSNull(),
            "bounds": NSNull(), "position": NSNull(), "contentsScale": NSNull(),
            "mask": NSNull()
        ]
        gradientMaskLayer.fillRule = .evenOdd
        gradientMaskLayer.strokeColor = nil
        gradientMaskLayer.actions = [
            "path": NSNull(), "fillColor": NSNull(), "bounds": NSNull(),
            "position": NSNull(), "contentsScale": NSNull()
        ]
        // The glow paints through a dedicated color layer below the border. It
        // carries the border's own colors - the solid color, or the exact
        // gradient endpoints and unit points - so a gradient border produces a
        // gradient glow. The band mask turns that color into an outward
        // falloff that reaches zero inside the overlay surface.
        //
        // Shadows are deliberately avoided: a shadow cast by the thin border
        // ring is weak, spreads wider than the surface padding, and gets
        // clipped at the panel edge, which reads as a hard edge at every glow
        // radius. Bands also render identically in live compositing and in
        // offline render(in:), so pixel tests keep matching what ships.
        glowColorLayer.isHidden = true
        glowColorLayer.actions = [
            "colors": NSNull(), "startPoint": NSNull(), "endPoint": NSNull(),
            "bounds": NSNull(), "position": NSNull(), "contentsScale": NSNull(),
            "mask": NSNull()
        ]
        glowMaskLayer.actions = [
            "bounds": NSNull(), "position": NSNull(), "contentsScale": NSNull()
        ]
        containerLayer.actions = ["hidden": NSNull()]
        glowColorLayer.mask = glowMaskLayer
        gradientLayer.mask = gradientMaskLayer
        borderLayer.addSublayer(gradientLayer)
        containerLayer.addSublayer(glowColorLayer)
        containerLayer.addSublayer(borderLayer)
        view.layer = containerLayer
        contentView = view
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect {
        frameRect
    }

    func applyFrame(_ targetFrame: CGRect) {
        let panelFrame = targetFrame.integral
        let layerFrame = targetFrame.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
        guard frame != panelFrame
            || borderLayer.frame != layerFrame
            || glowColorLayer.frame != layerFrame
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if frame != panelFrame {
            setFrame(panelFrame, display: false)
        }
        if borderLayer.frame != layerFrame {
            borderLayer.frame = layerFrame
        }
        if glowColorLayer.frame != layerFrame {
            glowColorLayer.frame = layerFrame
        }
        CATransaction.commit()
    }

    func setContentVisible(_ visible: Bool) {
        let hidden = !visible
        guard contentView?.isHidden != hidden
            || containerLayer.isHidden != hidden
            || borderLayer.isHidden != hidden
            || glowColorLayer.isHidden != hidden
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentView?.isHidden = hidden
        containerLayer.isHidden = hidden
        borderLayer.isHidden = hidden
        glowColorLayer.isHidden = hidden
        CATransaction.commit()
    }

    func updateBorder(
        surfaceFrame: CGRect,
        targetFrame: CGRect,
        cornerRadii: WindowCornerRadii,
        width: CGFloat,
        color: CGColor,
        scale: CGFloat,
        surfacePadding: CGFloat = 0,
        gradientStart: CGColor? = nil,
        gradientEnd: CGColor? = nil,
        gradientPoints: (start: CGPoint, end: CGPoint)? = nil,
        glowOpacity: CGFloat = 0
    ) {
        let ringFrame = surfaceFrame.insetBy(dx: surfacePadding, dy: surfacePadding)
        let path = CGMutablePath()
        path.addPath(BorderWindow.roundedRectPath(in: ringFrame, radii: cornerRadii.adding(width)))
        path.addPath(BorderWindow.roundedRectPath(in: targetFrame, radii: cornerRadii))
        let hasGradient = gradientStart != nil && gradientEnd != nil && gradientPoints != nil
        let hasGlow = glowOpacity > 0 && surfacePadding > 0
        let surfaceBounds = CGRect(origin: .zero, size: surfaceFrame.size)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentView?.isHidden = false
        containerLayer.isHidden = false
        borderLayer.isHidden = false
        borderLayer.bounds = surfaceFrame
        glowColorLayer.bounds = surfaceBounds
        glowMaskLayer.frame = surfaceBounds
        containerLayer.bounds = surfaceBounds
        containerLayer.contentsScale = scale
        borderLayer.contentsScale = scale
        glowColorLayer.contentsScale = scale
        glowMaskLayer.contentsScale = scale
        gradientLayer.contentsScale = scale
        gradientMaskLayer.contentsScale = scale
        borderLayer.path = path
        borderLayer.fillColor = hasGradient ? nil : color
        if hasGlow {
            glowColorLayer.isHidden = false
            if hasGradient, let gradientStart, let gradientEnd, let gradientPoints {
                glowColorLayer.colors = [gradientStart, gradientEnd]
                glowColorLayer.startPoint = gradientPoints.start
                glowColorLayer.endPoint = gradientPoints.end
            } else {
                glowColorLayer.colors = [color, color]
                glowColorLayer.startPoint = CGPoint(x: 0, y: 0)
                glowColorLayer.endPoint = CGPoint(x: 0, y: 1)
            }
            updateGlowBands(
                ringFrame: ringFrame,
                cornerRadii: cornerRadii,
                width: width,
                padding: surfacePadding,
                opacity: glowOpacity,
                scale: scale
            )
        } else {
            glowColorLayer.isHidden = true
        }
        if hasGradient, let gradientStart, let gradientEnd, let gradientPoints {
            gradientLayer.isHidden = false
            gradientLayer.frame = surfaceBounds
            gradientLayer.colors = [gradientStart, gradientEnd]
            gradientLayer.startPoint = gradientPoints.start
            gradientLayer.endPoint = gradientPoints.end
            gradientMaskLayer.frame = surfaceBounds
            gradientMaskLayer.path = path
        } else {
            gradientLayer.isHidden = true
        }
        CATransaction.commit()
    }

    private func updateGlowBands(
        ringFrame: CGRect,
        cornerRadii: WindowCornerRadii,
        width: CGFloat,
        padding: CGFloat,
        opacity: CGFloat,
        scale: CGFloat
    ) {
        // One band per physical pixel keeps the staircase below the visible
        // banding threshold; the cap bounds the layer count at large radii.
        let effectiveScale = max(scale, 1)
        let bandCount = min(48, max(8, Int((padding * effectiveScale).rounded(.up))))
        ensureGlowBandCount(bandCount)
        let bandWidth = padding / CGFloat(bandCount)
        let bounds = glowMaskLayer.bounds
        for index in 0 ..< bandCount {
            let innerOffset = CGFloat(index) * bandWidth
            // Sampling the outer edge keeps the outermost band at zero alpha,
            // so the glow always fades out before the overlay surface ends.
            let alpha = opacity * (1 - (innerOffset + bandWidth) / padding)
            let centerOffset = innerOffset + bandWidth / 2
            let band = glowBandLayers[index]
            band.isHidden = alpha <= 0.001
            band.frame = bounds
            band.bounds = bounds
            band.contentsScale = effectiveScale
            band.path = BorderWindow.roundedRectPath(
                in: ringFrame.insetBy(dx: -centerOffset, dy: -centerOffset),
                radii: cornerRadii.adding(width + centerOffset)
            )
            band.lineWidth = bandWidth
            band.strokeColor = CGColor(gray: 1, alpha: alpha)
        }
    }

    private func ensureGlowBandCount(_ count: Int) {
        while glowBandLayers.count < count {
            let band = CAShapeLayer()
            band.fillColor = nil
            band.actions = [
                "path": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull(),
                "bounds": NSNull(), "position": NSNull(), "contentsScale": NSNull(),
                "hidden": NSNull()
            ]
            glowMaskLayer.addSublayer(band)
            glowBandLayers.append(band)
        }
        while glowBandLayers.count > count {
            glowBandLayers.removeLast().removeFromSuperlayer()
        }
    }
}
