// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
import CoreText
import Foundation

struct OverviewWindowRenderer {
    private typealias Colors = OverviewRenderStyle.Colors
    private typealias Metrics = OverviewRenderStyle.Metrics
    let context: CGContext
    let state: OverviewRenderState

    func render(
        window: OverviewWindowItem,
        frame: CGRect,
        thumbnail: CGImage?,
        textLineCache: inout OverviewTextLineCache
    ) {
        let isSelected = window.handle == state.selectedWindowHandle
        let isHovered = window.handle == state.hoveredWindowHandle
        let isCloseButtonHovered = isHovered && state.closeButtonHovered
        let alpha = CGFloat(state.progress) * (window.matchesSearch ? 1.0 : 0.3)

        context.saveGState()
        context.setAlpha(alpha)

        let path = CGPath(
            roundedRect: frame,
            cornerWidth: Metrics.windowCornerRadius,
            cornerHeight: Metrics.windowCornerRadius,
            transform: nil
        )

        context.addPath(path)
        context.setFillColor(Colors.windowBackground)
        context.fillPath()

        renderThumbnail(thumbnail, frame: frame)

        if !window.matchesSearch {
            context.addPath(path)
            context.setFillColor(Colors.windowDimmed)
            context.fillPath()
        }

        let borderColor = OverviewRenderer.borderColor(
            isSelected: isSelected,
            isHovered: isHovered,
            palette: state.palette
        )
        let borderWidth = isSelected ? Metrics.selectedBorderWidth : Metrics.windowBorderWidth

        context.addPath(path)
        context.setStrokeColor(borderColor)
        context.setLineWidth(borderWidth)
        context.strokePath()

        renderInfo(window: window, frame: frame, textLineCache: &textLineCache)

        if isHovered {
            renderCloseButton(
                frame: window.closeButtonFrame,
                isHovered: isCloseButtonHovered
            )
        }

        if window.groupCount > 1 {
            renderGroupBadge(
                count: window.groupCount,
                frame: frame,
                textLineCache: &textLineCache
            )
        }

        context.restoreGState()
    }

    private func renderThumbnail(_ thumbnail: CGImage?, frame: CGRect) {
        guard let thumbnail else { return }
        let thumbnailRect = frame.insetBy(dx: Metrics.thumbnailInset, dy: Metrics.thumbnailInset)
        let drawRect = OverviewRenderGeometry.aspectFitRect(
            contentSize: CGSize(width: thumbnail.width, height: thumbnail.height),
            in: thumbnailRect
        )
        context.saveGState()
        let clipPath = CGPath(
            roundedRect: thumbnailRect,
            cornerWidth: Metrics.windowCornerRadius - 1,
            cornerHeight: Metrics.windowCornerRadius - 1,
            transform: nil
        )
        context.addPath(clipPath)
        context.clip()
        context.draw(thumbnail, in: drawRect)
        context.restoreGState()
    }

    private func renderInfo(window: OverviewWindowItem, frame: CGRect, textLineCache: inout OverviewTextLineCache) {
        let infoHeight: CGFloat = 36
        let infoRect = CGRect(
            x: frame.minX,
            y: frame.minY,
            width: frame.width,
            height: infoHeight
        )

        renderInfoBackground(infoRect)

        if let icon = window.appIcon {
            let iconRect = CGRect(
                x: infoRect.minX + 8,
                y: infoRect.minY + (infoHeight - Metrics.iconSize) / 2,
                width: Metrics.iconSize,
                height: Metrics.iconSize
            )
            context.draw(icon, in: iconRect)
        }

        let textX = infoRect.minX + 8 + Metrics.iconSize + 6
        let maxTextWidth = infoRect.width - (textX - infoRect.minX) - 8

        let titleWidth = bucketedTitleWidth(maxTextWidth)
        let titleKey = OverviewTextLineCache.Key(
            role: .title,
            text: window.title,
            widthBucket: Int(titleWidth)
        )
        let titleFont = textLineCache.titleFont
        let titleLine = textLineCache.line(for: titleKey) {
            OverviewTextLineCache.makeTruncatedLine(
                text: window.title,
                font: titleFont,
                color: Colors.textWhiteNS,
                maxWidth: titleWidth
            )
        }

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: textX, y: infoRect.minY + 20)
        CTLineDraw(titleLine, context)
        context.restoreGState()

        let appKey = OverviewTextLineCache.Key(role: .appName, text: window.appName, widthBucket: 0)
        let appNameFont = textLineCache.appNameFont
        let appLine = textLineCache.line(for: appKey) {
            OverviewTextLineCache.makeLine(text: window.appName, font: appNameFont, color: Colors.textGrayNS)
        }

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: textX, y: infoRect.minY + 6)
        CTLineDraw(appLine, context)
        context.restoreGState()
    }

    private func renderInfoBackground(_ infoRect: CGRect) {
        context.saveGState()
        let infoPath = CGMutablePath()
        infoPath.move(to: CGPoint(x: infoRect.minX + Metrics.windowCornerRadius, y: infoRect.minY))
        infoPath.addLine(to: CGPoint(x: infoRect.maxX - Metrics.windowCornerRadius, y: infoRect.minY))
        infoPath.addArc(
            center: CGPoint(
                x: infoRect.maxX - Metrics.windowCornerRadius,
                y: infoRect.minY + Metrics.windowCornerRadius
            ),
            radius: Metrics.windowCornerRadius,
            startAngle: -.pi / 2,
            endAngle: 0,
            clockwise: false
        )
        infoPath.addLine(to: CGPoint(x: infoRect.maxX, y: infoRect.maxY))
        infoPath.addLine(to: CGPoint(x: infoRect.minX, y: infoRect.maxY))
        infoPath.addLine(to: CGPoint(x: infoRect.minX, y: infoRect.minY + Metrics.windowCornerRadius))
        infoPath.addArc(
            center: CGPoint(
                x: infoRect.minX + Metrics.windowCornerRadius,
                y: infoRect.minY + Metrics.windowCornerRadius
            ),
            radius: Metrics.windowCornerRadius,
            startAngle: .pi,
            endAngle: -.pi / 2,
            clockwise: false
        )
        infoPath.closeSubpath()

        context.addPath(infoPath)
        context.setFillColor(Colors.infoBackground)
        context.fillPath()
        context.restoreGState()
    }

    private func renderGroupBadge(
        count: Int,
        frame: CGRect,
        textLineCache: inout OverviewTextLineCache
    ) {
        let text = "\(count)"
        let key = OverviewTextLineCache.Key(role: .groupBadge, text: text, widthBucket: 0)
        let font = textLineCache.groupBadgeFont
        let line = textLineCache.line(for: key) {
            OverviewTextLineCache.makeLine(text: text, font: font, color: Colors.textWhiteNS)
        }
        let textBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let badgeWidth = max(
            Metrics.groupBadgeHeight,
            ceil(textBounds.width) + Metrics.groupBadgePadding * 2
        )
        let badgeFrame = CGRect(
            x: frame.minX + 8,
            y: frame.maxY - Metrics.groupBadgeHeight - 8,
            width: badgeWidth,
            height: Metrics.groupBadgeHeight
        )
        let badgePath = CGPath(
            roundedRect: badgeFrame,
            cornerWidth: Metrics.groupBadgeHeight / 2,
            cornerHeight: Metrics.groupBadgeHeight / 2,
            transform: nil
        )

        context.saveGState()
        context.addPath(badgePath)
        context.setFillColor(CGColor(gray: 0.05, alpha: 0.82))
        context.fillPath()
        context.textMatrix = .identity
        context.translateBy(
            x: badgeFrame.midX - textBounds.midX,
            y: badgeFrame.midY - textBounds.midY
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func renderCloseButton(
        frame: CGRect,
        isHovered: Bool
    ) {
        let bgColor = isHovered ? Colors.closeButtonHover : Colors.closeButtonBackground
        let path = CGPath(ellipseIn: frame, transform: nil)

        context.saveGState()
        context.addPath(path)
        context.setFillColor(bgColor)
        context.fillPath()

        let xInset: CGFloat = 6
        context.setStrokeColor(Colors.closeButtonX)
        context.setLineWidth(2)
        context.setLineCap(.round)

        context.move(to: CGPoint(x: frame.minX + xInset, y: frame.minY + xInset))
        context.addLine(to: CGPoint(x: frame.maxX - xInset, y: frame.maxY - xInset))
        context.strokePath()

        context.move(to: CGPoint(x: frame.maxX - xInset, y: frame.minY + xInset))
        context.addLine(to: CGPoint(x: frame.minX + xInset, y: frame.maxY - xInset))
        context.strokePath()
        context.restoreGState()
    }

    private func bucketedTitleWidth(_ maxWidth: CGFloat) -> CGFloat {
        max(1, floor(maxWidth / Metrics.titleWidthBucket) * Metrics.titleWidthBucket)
    }
}
