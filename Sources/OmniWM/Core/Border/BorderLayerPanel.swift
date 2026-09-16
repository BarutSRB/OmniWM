// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import OmniWMLayerCorners
import QuartzCore

@MainActor
class BorderLayerPanel: NSPanel {
    let borderLayer = CALayer()
    private let containerLayer = CALayer()
    private let effectsContainerLayer = CALayer()
    private static let borderColorSpace = CGColorSpaceCreateDeviceRGB()
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
        configureEffects()
        view.layer = containerLayer
        contentView = view
    }

    private func configureEffects() {
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
        effectsContainerLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        effectsContainerLayer.addSublayer(glowColorLayer)
        effectsContainerLayer.addSublayer(gradientStrokeLayer)
        containerLayer.addSublayer(effectsContainerLayer)
        containerLayer.addSublayer(borderLayer)
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
        let effectsFrame = surfaceFrame.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
        guard frame != panelFrame || borderLayer.frame != layerFrame
            || effectsContainerLayer.frame != effectsFrame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if frame != panelFrame {
            setFrame(panelFrame, display: false)
        }
        if borderLayer.frame != layerFrame {
            borderLayer.frame = layerFrame
        }
        if effectsContainerLayer.frame != effectsFrame {
            effectsContainerLayer.frame = effectsFrame
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
}

extension BorderLayerPanel {
    func updateEffects(
        geometry: BorderConfig.ResolvedGeometry,
        cornerRadii: WindowCornerRadii,
        config: BorderConfig,
        baseColor: CGColor,
        scale: CGFloat
    ) {
        let gradient = config.gradient.flatMap { $0.enabled ? $0 : nil }
        let surfaceBounds = CGRect(origin: .zero, size: geometry.surfaceFrame.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateGradient(gradient, geometry: geometry, cornerRadii: cornerRadii)
        glowColorLayer.frame = surfaceBounds
        glowMaskLayer.frame = surfaceBounds
        if let glow = config.glow, glow.enabled, glow.opacity > 0, geometry.surfacePadding > 0 {
            glowColorLayer.isHidden = false
            if let color = glow.color {
                let color = Self.cgColor(color)
                glowColorLayer.colors = [color, color]
            } else if gradient != nil {
                glowColorLayer.colors = gradientStrokeLayer.colors
            } else {
                glowColorLayer.colors = [baseColor, baseColor]
            }
            let points = glow.color == nil ? gradient.map { Self.gradientUnitPoints(for: $0.direction) } : nil
            glowColorLayer.startPoint = points?.start ?? CGPoint(x: 0, y: 0)
            glowColorLayer.endPoint = points?.end ?? CGPoint(x: 0, y: 1)
            updateGlowBands(
                geometry: geometry,
                cornerRadii: cornerRadii,
                opacity: Self.component(glow.opacity),
                scale: scale
            )
        } else {
            glowColorLayer.isHidden = true
        }
        glowColorLayer.contentsScale = scale
        glowMaskLayer.contentsScale = scale
        gradientStrokeLayer.contentsScale = scale
        gradientRingMaskLayer.contentsScale = scale
        borderLayer.rimOpacity = gradient == nil ? 1 : 0
        CATransaction.commit()
    }

    private func updateGradient(
        _ gradient: BorderGradient?,
        geometry: BorderConfig.ResolvedGeometry,
        cornerRadii: WindowCornerRadii
    ) {
        guard let gradient else {
            gradientStrokeLayer.isHidden = true
            return
        }
        let radii = cornerRadii.normalized(to: geometry.targetFrame.size)
        let ringFrame = geometry.targetFrame.insetBy(dx: -geometry.width, dy: -geometry.width)
        let outerRadii = radii == .zero ? .zero : radii.adding(geometry.width)
        let path = CGMutablePath()
        path.addPath(Self.roundedRectPath(in: ringFrame, radii: outerRadii))
        path.addPath(Self.roundedRectPath(in: geometry.targetFrame, radii: radii))
        let surfaceBounds = CGRect(origin: .zero, size: geometry.surfaceFrame.size)
        let points = Self.gradientUnitPoints(for: gradient.direction)
        gradientStrokeLayer.isHidden = false
        gradientStrokeLayer.frame = surfaceBounds
        gradientStrokeLayer.colors = [Self.cgColor(gradient.start), Self.cgColor(gradient.end)]
        gradientStrokeLayer.startPoint = points.start
        gradientStrokeLayer.endPoint = points.end
        gradientRingMaskLayer.frame = surfaceBounds
        gradientRingMaskLayer.path = path
    }

    private func updateGlowBands(
        geometry: BorderConfig.ResolvedGeometry,
        cornerRadii: WindowCornerRadii,
        opacity: CGFloat,
        scale: CGFloat
    ) {
        let padding = geometry.surfacePadding
        let width = geometry.width
        let ringFrame = geometry.targetFrame.insetBy(dx: -width, dy: -width)
        let effectiveScale = max(scale, 1)
        let bandCount = min(48, max(8, Int((padding * effectiveScale).rounded(.up))))
        ensureGlowBandCount(bandCount)
        let bandWidth = padding / CGFloat(bandCount)
        let radii = cornerRadii.normalized(to: geometry.targetFrame.size)
        let bounds = CGRect(origin: .zero, size: geometry.surfaceFrame.size)
        for index in 0 ..< bandCount {
            let innerOffset = CGFloat(index) * bandWidth
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

extension BorderLayerPanel {
    private static func gradientUnitPoints(
        for direction: BorderGradientDirection
    ) -> (start: CGPoint, end: CGPoint) {
        switch direction {
        case .topLeftToBottomRight:
            return (start: CGPoint(x: 0, y: 1), end: CGPoint(x: 1, y: 0))
        case .topRightToBottomLeft:
            return (start: CGPoint(x: 1, y: 1), end: CGPoint(x: 0, y: 0))
        }
    }

    static func cgColor(_ color: SettingsColor) -> CGColor {
        CGColor(
            colorSpace: borderColorSpace,
            components: [
                component(color.red),
                component(color.green),
                component(color.blue),
                component(color.alpha)
            ]
        )!
    }

    private static func component(_ value: Double) -> CGFloat {
        guard value.isFinite else { return 0 }
        return CGFloat(min(max(value, 0), 1))
    }
}

extension WindowCornerRadii {
    fileprivate func adding(_ value: CGFloat) -> WindowCornerRadii {
        WindowCornerRadii(
            topLeft: topLeft + value,
            topRight: topRight + value,
            bottomLeft: bottomLeft + value,
            bottomRight: bottomRight + value
        )
    }
}
