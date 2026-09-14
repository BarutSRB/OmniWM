// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import OmniWMLayerCorners
import QuartzCore

@MainActor
class BorderLayerPanel: NSPanel {
    let borderLayer = CALayer()
    private let containerLayer = CALayer()
    let glowColorLayer = CAGradientLayer()
    let glowMaskLayer = CALayer()
    private var glowBandLayers: [CAShapeLayer] = []
    let gradientStrokeLayer = CAGradientLayer()
    let gradientRingMaskLayer = CAShapeLayer()

    init?(frame: CGRect) {
        guard omniwm_layer_border_available() else { return nil }
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
        borderLayer.cornerCurve = .continuous
        borderLayer.rimOpacity = 1
        borderLayer.actions = [
            "rimWidth": NSNull(), "rimColor": NSNull(), "rimOpacity": NSNull(), "cornerRadii": NSNull(),
            "bounds": NSNull(), "position": NSNull(), "contentsScale": NSNull()
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
        gradientStrokeLayer.isHidden = true
        gradientStrokeLayer.actions = [
            "colors": NSNull(), "startPoint": NSNull(), "endPoint": NSNull(),
            "bounds": NSNull(), "position": NSNull(), "contentsScale": NSNull(),
            "mask": NSNull()
        ]
        gradientRingMaskLayer.fillRule = .evenOdd
        gradientRingMaskLayer.strokeColor = nil
        gradientRingMaskLayer.actions = [
            "path": NSNull(), "fillColor": NSNull(), "bounds": NSNull(),
            "position": NSNull(), "contentsScale": NSNull()
        ]
        containerLayer.actions = ["hidden": NSNull()]
        glowColorLayer.mask = glowMaskLayer
        gradientStrokeLayer.mask = gradientRingMaskLayer
        containerLayer.addSublayer(glowColorLayer)
        containerLayer.addSublayer(borderLayer)
        containerLayer.addSublayer(gradientStrokeLayer)
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

    func applyFrame(targetFrame: CGRect, surfaceFrame: CGRect) {
        let panelFrame = surfaceFrame.integral
        let layerFrame = targetFrame.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
        guard frame != panelFrame || borderLayer.frame != layerFrame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if frame != panelFrame {
            setFrame(panelFrame, display: false)
        }
        if borderLayer.frame != layerFrame {
            borderLayer.frame = layerFrame
        }
        CATransaction.commit()
    }

    func updateBorder(
        geometry: BorderConfig.ResolvedGeometry,
        cornerRadii: WindowCornerRadii,
        color: CGColor,
        scale: CGFloat
    ) {
        let radii = cornerRadii.normalized(to: geometry.targetFrame.size)
        let nativeRadii = CACornerRadii(
            topLeft: CGSize(width: radii.topLeft, height: radii.topLeft),
            topRight: CGSize(width: radii.topRight, height: radii.topRight),
            bottomRight: CGSize(width: radii.bottomRight, height: radii.bottomRight),
            bottomLeft: CGSize(width: radii.bottomLeft, height: radii.bottomLeft)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if containerLayer.contentsScale != scale { containerLayer.contentsScale = scale }
        if borderLayer.contentsScale != scale { borderLayer.contentsScale = scale }
        if borderLayer.rimWidth != geometry.width { borderLayer.rimWidth = geometry.width }
        if borderLayer.rimColor != color { borderLayer.rimColor = color }
        let currentRadii = borderLayer.cornerRadii
        if currentRadii.topLeft != nativeRadii.topLeft || currentRadii.topRight != nativeRadii.topRight
            || currentRadii.bottomRight != nativeRadii.bottomRight || currentRadii.bottomLeft != nativeRadii.bottomLeft
        {
            borderLayer.cornerRadii = nativeRadii
        }
        CATransaction.commit()
    }

    /// Updates the optional gradient ring and the glow band falloff.
    ///
    /// The native rim keeps drawing the solid border; when a gradient is
    /// active the rim is faded out and a masked gradient stroke replaces it,
    /// so the ring geometry and corner treatment stay identical between the
    /// solid and gradient paths.
    func updateEffects(
        geometry: BorderConfig.ResolvedGeometry,
        cornerRadii: WindowCornerRadii,
        scale: CGFloat,
        baseColor: CGColor,
        gradientStart: CGColor?,
        gradientEnd: CGColor?,
        gradientPoints: (start: CGPoint, end: CGPoint)?,
        glowOpacity: CGFloat
    ) {
        let radii = cornerRadii.normalized(to: geometry.targetFrame.size)
        let ringFrame = geometry.targetFrame.insetBy(dx: -geometry.width, dy: -geometry.width)
        let surfaceBounds = CGRect(origin: .zero, size: geometry.surfaceFrame.size)
        let hasGradient = gradientStart != nil && gradientEnd != nil && gradientPoints != nil
        let hasGlow = glowOpacity > 0 && geometry.surfacePadding > 0

        if hasGradient, let gradientStart, let gradientEnd, let gradientPoints {
            let path = CGMutablePath()
            path.addPath(Self.roundedRectPath(in: ringFrame, radii: radii.adding(geometry.width)))
            path.addPath(Self.roundedRectPath(in: geometry.targetFrame, radii: radii))
            gradientStrokeLayer.isHidden = false
            gradientStrokeLayer.frame = surfaceBounds
            gradientStrokeLayer.colors = [gradientStart, gradientEnd]
            gradientStrokeLayer.startPoint = gradientPoints.start
            gradientStrokeLayer.endPoint = gradientPoints.end
            gradientRingMaskLayer.frame = surfaceBounds
            gradientRingMaskLayer.path = path
        } else {
            gradientStrokeLayer.isHidden = true
        }

        if hasGlow {
            glowColorLayer.isHidden = false
            glowColorLayer.bounds = surfaceBounds
            glowColorLayer.position = surfaceBounds.origin
            if hasGradient, let gradientStart, let gradientEnd, let gradientPoints {
                glowColorLayer.colors = [gradientStart, gradientEnd]
                glowColorLayer.startPoint = gradientPoints.start
                glowColorLayer.endPoint = gradientPoints.end
            } else {
                glowColorLayer.colors = [baseColor, baseColor]
                glowColorLayer.startPoint = CGPoint(x: 0, y: 0)
                glowColorLayer.endPoint = CGPoint(x: 0, y: 1)
            }
            updateGlowBands(
                ringFrame: ringFrame,
                cornerRadii: cornerRadii,
                width: geometry.width,
                padding: geometry.surfacePadding,
                opacity: glowOpacity,
                scale: scale
            )
        } else {
            glowColorLayer.isHidden = true
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowColorLayer.contentsScale = scale
        glowMaskLayer.contentsScale = scale
        glowMaskLayer.bounds = surfaceBounds
        glowMaskLayer.position = surfaceBounds.origin
        gradientStrokeLayer.contentsScale = scale
        gradientRingMaskLayer.contentsScale = scale
        // The gradient stroke replaces the rim visually, so fade the native
        // rim out while the masked gradient draws the same ring geometry.
        borderLayer.rimOpacity = hasGradient ? 0 : 1
        CATransaction.commit()
    }

    /// Rebuilds the concentric band falloff for the current surface geometry.
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
        let radii = cornerRadii.normalized(to: ringFrame.insetBy(dx: width, dy: width).size)
        let bounds = CGRect(origin: .zero, size: glowMaskLayer.bounds.size)
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
            band.path = Self.roundedRectPath(
                in: ringFrame.insetBy(dx: -centerOffset, dy: -centerOffset),
                radii: radii.adding(width + centerOffset)
            )
            band.lineWidth = bandWidth
            band.strokeColor = CGColor(gray: 1, alpha: alpha)
        }
    }

    /// Reuses or trims mask layers to match the requested band count.
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

    /// Builds a normalized rounded-rectangle path with per-corner radii.
    private static func roundedRectPath(in rect: CGRect, radii: WindowCornerRadii) -> CGPath {
        let path = CGMutablePath()
        guard rect.width > 0, rect.height > 0, !rect.isInfinite, !rect.isNull else { return path }
        let radii = radii.normalized(to: rect.size)

        path.move(to: CGPoint(x: rect.minX + radii.bottomLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radii.bottomRight, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY + radii.bottomRight),
            radius: radii.bottomRight
        )

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radii.topRight))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX - radii.topRight, y: rect.maxY),
            radius: radii.topRight
        )

        path.addLine(to: CGPoint(x: rect.minX + radii.topLeft, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY - radii.topLeft),
            radius: radii.topLeft
        )

        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radii.bottomLeft))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX + radii.bottomLeft, y: rect.minY),
            radius: radii.bottomLeft
        )
        path.closeSubpath()
        return path
    }
}

private extension WindowCornerRadii {
    /// Expands every corner radius outward, keeping corners concentric.
    func adding(_ value: CGFloat) -> WindowCornerRadii {
        WindowCornerRadii(
            topLeft: topLeft + value,
            topRight: topRight + value,
            bottomLeft: bottomLeft + value,
            bottomRight: bottomRight + value
        )
    }
}
