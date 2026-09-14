// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import IOSurface
import QuartzCore

@MainActor
final class OverviewWindowLayer {
    private typealias Colors = OverviewRenderStyle.Colors
    private typealias Metrics = OverviewRenderStyle.Metrics

    let root = CALayer()
    let thumbnail = CALayer()
    private let thumbnailClip = CALayer()
    private let dimming = CALayer()
    let border = CALayer()
    private let info = CALayer()
    private let icon = CALayer()
    private let title = OverviewRenderer.textLayer(size: 12, color: Colors.textWhite)
    private let appName = OverviewRenderer.textLayer(size: 10, color: Colors.textGray)
    private let closeButton = CALayer()
    private let closeMark = CAShapeLayer()
    private let badge = CALayer()
    private let badgeText = OverviewRenderer.textLayer(size: 11, color: Colors.textWhite, alignment: .center)
    private(set) var preview: OverviewPreviewFrame?
    private var previewContentSize = CGSize.zero
    private var activeTransition: OverviewNativeTransition?
    private var badgeWidth: CGFloat = 22

    init() {
        root.backgroundColor = Colors.windowBackground
        root.cornerRadius = Metrics.windowCornerRadius
        root.addSublayer(thumbnailClip)
        thumbnailClip.cornerRadius = Metrics.windowCornerRadius - 1
        thumbnailClip.masksToBounds = true
        thumbnailClip.addSublayer(thumbnail)
        thumbnail.contentsGravity = .resize
        root.addSublayer(dimming)
        dimming.backgroundColor = Colors.windowDimmed
        dimming.cornerRadius = Metrics.windowCornerRadius
        root.addSublayer(info)
        info.backgroundColor = Colors.infoBackground
        info.cornerRadius = Metrics.windowCornerRadius
        info.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        info.masksToBounds = true
        for layer in [icon, title, appName] { info.addSublayer(layer) }
        root.addSublayer(border)
        border.cornerRadius = Metrics.windowCornerRadius
        root.addSublayer(closeButton)
        closeButton.cornerRadius = Metrics.closeButtonSize / 2
        closeButton.addSublayer(closeMark)
        closeMark.strokeColor = Colors.closeButtonX
        closeMark.lineWidth = 2
        closeMark.lineCap = .round
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 6, y: 6))
        path.addLine(to: CGPoint(x: 14, y: 14))
        path.move(to: CGPoint(x: 14, y: 6))
        path.addLine(to: CGPoint(x: 6, y: 14))
        closeMark.path = path
        root.addSublayer(badge)
        badge.backgroundColor = CGColor(gray: 0.05, alpha: 0.82)
        badge.cornerRadius = Metrics.groupBadgeHeight / 2
        badge.addSublayer(badgeText)
    }

    func updateContent(_ window: OverviewWindowItem, contentsScale: CGFloat) {
        if title.string as? String != window.title { title.string = window.title }
        if appName.string as? String != window.appName { appName.string = window.appName }
        if (icon.contents as AnyObject?) !== window.appIcon { icon.contents = window.appIcon }
        let textX = 8 + Metrics.iconSize + 6
        let textWidth = max(1, window.overviewFrame.width - textX - 8)
        title.frame = CGRect(x: textX, y: 18, width: textWidth, height: 16)
        appName.frame = CGRect(x: textX, y: 4, width: textWidth, height: 14)
        icon.frame = CGRect(x: 8, y: 6, width: Metrics.iconSize, height: Metrics.iconSize)
        for layer in [title, appName, badgeText] { layer.contentsScale = contentsScale }
        badge.isHidden = window.groupCount <= 1
        let count = String(window.groupCount)
        if badgeText.string as? String != count {
            badgeText.string = count
            badgeWidth = max(
                Metrics.groupBadgeHeight,
                ceil((count as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width) + Metrics
                    .groupBadgePadding * 2
            )
            badgeText.frame = CGRect(x: 0, y: 4, width: badgeWidth, height: 15)
        }
    }

    func updateGeometry(
        _ window: OverviewWindowItem,
        frame: CGRect,
        state: OverviewRenderState,
        transition: OverviewNativeTransition? = nil,
        replacing: Bool = false,
        time: CFTimeInterval = CACurrentMediaTime()
    ) {
        let motion = transition.map { _ in motionLayers.map(OverviewLayerMotion.init) } ?? []
        activeTransition = transition
        root.frame = frame
        root.opacity = Float(state.progress * (window.matchesSearch ? 1 : 0.3))
        thumbnailClip.frame = root.bounds.insetBy(dx: Metrics.thumbnailInset, dy: Metrics.thumbnailInset)
        updateThumbnailGeometry()
        dimming.frame = root.bounds
        dimming.isHidden = window.matchesSearch
        border.frame = root.bounds
        info.frame = CGRect(x: 0, y: 0, width: root.bounds.width, height: 36)
        closeButton.frame = CGRect(
            x: root.bounds.maxX - Metrics.closeButtonSize - Metrics.closeButtonPadding,
            y: root.bounds.maxY - Metrics.closeButtonSize - Metrics.closeButtonPadding,
            width: Metrics.closeButtonSize,
            height: Metrics.closeButtonSize
        )
        badge.frame = CGRect(
            x: 8,
            y: root.bounds.maxY - Metrics.groupBadgeHeight - 8,
            width: badgeWidth,
            height: Metrics.groupBadgeHeight
        )
        updateEmphasis(window, state: state)
        if let transition {
            for snapshot in motion { snapshot.apply(transition, at: time, replacing: replacing) }
        }
    }

    func updateEmphasis(_ window: OverviewWindowItem, state: OverviewRenderState) {
        let selected = window.handle == state.selectedWindowHandle
        let hovered = window.handle == state.hoveredWindowHandle
        border.borderColor = OverviewRenderer.borderColor(
            isSelected: selected,
            isHovered: hovered,
            palette: state.palette
        )
        border.borderWidth = selected ? Metrics.selectedBorderWidth : Metrics.windowBorderWidth
        closeButton.isHidden = !hovered
        closeButton.backgroundColor = hovered && state.closeButtonHovered ? Colors.closeButtonHover : Colors
            .closeButtonBackground
    }

    func updatePreview(_ frame: OverviewPreviewFrame?) {
        guard preview !== frame else { return }
        let previous = preview
        let motion = activeTransition.map { _ in OverviewLayerMotion(thumbnail) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { withExtendedLifetime(previous) {} }
        preview = frame
        thumbnail.contents = frame?.surface
        thumbnail.contentsRect = frame?.contentsRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        if let frame {
            previewContentSize = CGSize(
                width: CGFloat(frame.surface.width) * frame.contentsRect.width,
                height: CGFloat(frame.surface.height) * frame.contentsRect.height
            )
        } else {
            previewContentSize = .zero
        }
        updateThumbnailGeometry()
        if let activeTransition { motion?.apply(activeTransition, at: CACurrentMediaTime(), replacing: false) }
        CATransaction.commit()
    }

    private var motionLayers: [CALayer] {
        [root, thumbnailClip, thumbnail, dimming, border, info, closeButton, badge]
    }

    func cancelAnimation() {
        activeTransition = nil
        for layer in motionLayers { OverviewLayerMotion.remove(from: layer) }
    }

    func hit(at point: CGPoint) -> Bool? {
        let displayed = root.presentation() ?? root
        guard !root.isHidden, displayed.opacity > 0, displayed.frame.contains(point) else { return nil }
        let local = CGPoint(
            x: point.x - displayed.frame.minX + displayed.bounds.minX,
            y: point.y - displayed.frame.minY + displayed.bounds.minY
        )
        return (closeButton.presentation() ?? closeButton).frame.contains(local)
    }

    private func updateThumbnailGeometry() {
        thumbnail.frame = OverviewRenderGeometry.aspectFitRect(
            contentSize: previewContentSize,
            in: thumbnailClip.bounds
        )
    }
}
