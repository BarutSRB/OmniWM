import AppKit
import CoreGraphics
import Foundation

enum OverviewRenderer {

    private enum Colors {
        static let background = CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 0.85)
        static let windowBackground = CGColor(red: 0.15, green: 0.15, blue: 0.18, alpha: 1.0)
        static let windowBorder = CGColor(red: 0.3, green: 0.3, blue: 0.35, alpha: 1.0)
        static let windowHoverBorder = CGColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)
        static let windowSelectedBorder = CGColor(red: 0.3, green: 0.8, blue: 0.4, alpha: 1.0)
        static let windowDimmed = CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 0.7)
        static let closeButtonBackground = CGColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 0.9)
        static let closeButtonHover = CGColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0)
        static let closeButtonX = CGColor(gray: 1.0, alpha: 1.0)
        static let searchBarBackground = CGColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 0.95)
        static let searchBarBorder = CGColor(red: 0.25, green: 0.25, blue: 0.3, alpha: 1.0)
        static let textWhite = CGColor(gray: 1.0, alpha: 1.0)
        static let textGray = CGColor(gray: 0.7, alpha: 1.0)
        static let textDimmed = CGColor(gray: 0.4, alpha: 1.0)
        static let workspaceLabelActive = CGColor(red: 0.3, green: 0.7, blue: 1.0, alpha: 1.0)
        static let workspaceLabelInactive = CGColor(gray: 0.6, alpha: 1.0)
    }

    private enum Metrics {
        static let windowCornerRadius: CGFloat = 8
        static let windowBorderWidth: CGFloat = 2
        static let selectedBorderWidth: CGFloat = 3
        static let closeButtonSize: CGFloat = 20
        static let closeButtonPadding: CGFloat = 6
        static let thumbnailInset: CGFloat = 1
        static let searchBarCornerRadius: CGFloat = 10
        static let searchBarBorderWidth: CGFloat = 1.5
        static let iconSize: CGFloat = 24
        static let titleFontSize: CGFloat = 12
        static let appNameFontSize: CGFloat = 10
        static let workspaceLabelFontSize: CGFloat = 16
        static let searchFontSize: CGFloat = 16
    }

    static func render(
        context: CGContext,
        layout: OverviewLayout,
        thumbnails: [Int: CGImage],
        searchQuery: String,
        progress: Double,
        bounds: CGRect
    ) {
        let alpha = CGFloat(progress)

        context.saveGState()
        context.setFillColor(Colors.background.copy(alpha: alpha * 0.85)!)
        context.fill(bounds)
        context.restoreGState()

        guard progress > 0 else { return }

        let scrollOffset = layout.scrollOffset

        context.saveGState()
        context.translateBy(x: 0, y: -scrollOffset)

        for section in layout.workspaceSections {
            renderWorkspaceLabel(context: context, section: section, alpha: alpha)

            for window in section.windows {
                renderWindow(
                    context: context,
                    window: window,
                    thumbnail: thumbnails[window.windowId],
                    progress: progress
                )
            }
        }

        context.restoreGState()

        renderSearchBar(
            context: context,
            frame: layout.searchBarFrame,
            searchQuery: searchQuery,
            alpha: alpha
        )
    }

    private static func renderWorkspaceLabel(
        context: CGContext,
        section: OverviewWorkspaceSection,
        alpha: CGFloat
    ) {
        let font = CTFontCreateWithName("SF Pro Display" as CFString, Metrics.workspaceLabelFontSize, nil)
        let color = section.isActive ? Colors.workspaceLabelActive : Colors.workspaceLabelInactive

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color.copy(alpha: alpha)!)!
        ]

        let attributedString = NSAttributedString(string: section.name, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributedString)

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: section.labelFrame.minX, y: section.labelFrame.minY + 8)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func renderWindow(
        context: CGContext,
        window: OverviewWindowItem,
        thumbnail: CGImage?,
        progress: Double
    ) {
        let frame = window.interpolatedFrame(progress: progress)
        let alpha = CGFloat(progress) * (window.matchesSearch ? 1.0 : 0.3)

        context.saveGState()

        let path = CGPath(roundedRect: frame, cornerWidth: Metrics.windowCornerRadius, cornerHeight: Metrics.windowCornerRadius, transform: nil)
        context.addPath(path)
        context.setFillColor(Colors.windowBackground.copy(alpha: alpha)!)
        context.fillPath()

        if let thumbnail {
            let thumbnailRect = frame.insetBy(dx: Metrics.thumbnailInset, dy: Metrics.thumbnailInset)
            context.saveGState()
            let clipPath = CGPath(roundedRect: thumbnailRect, cornerWidth: Metrics.windowCornerRadius - 1, cornerHeight: Metrics.windowCornerRadius - 1, transform: nil)
            context.addPath(clipPath)
            context.clip()
            context.draw(thumbnail, in: thumbnailRect)
            context.restoreGState()
        }

        if !window.matchesSearch {
            context.addPath(path)
            context.setFillColor(Colors.windowDimmed)
            context.fillPath()
        }

        let borderColor: CGColor
        let borderWidth: CGFloat
        if window.isSelected {
            borderColor = Colors.windowSelectedBorder.copy(alpha: alpha)!
            borderWidth = Metrics.selectedBorderWidth
        } else if window.isHovered {
            borderColor = Colors.windowHoverBorder.copy(alpha: alpha)!
            borderWidth = Metrics.windowBorderWidth
        } else {
            borderColor = Colors.windowBorder.copy(alpha: alpha * 0.5)!
            borderWidth = Metrics.windowBorderWidth
        }

        context.addPath(path)
        context.setStrokeColor(borderColor)
        context.setLineWidth(borderWidth)
        context.strokePath()

        let infoHeight: CGFloat = 36
        let infoRect = CGRect(
            x: frame.minX,
            y: frame.minY,
            width: frame.width,
            height: infoHeight
        )

        context.saveGState()
        let infoPath = CGMutablePath()
        infoPath.move(to: CGPoint(x: infoRect.minX + Metrics.windowCornerRadius, y: infoRect.minY))
        infoPath.addLine(to: CGPoint(x: infoRect.maxX - Metrics.windowCornerRadius, y: infoRect.minY))
        infoPath.addArc(center: CGPoint(x: infoRect.maxX - Metrics.windowCornerRadius, y: infoRect.minY + Metrics.windowCornerRadius),
                        radius: Metrics.windowCornerRadius, startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        infoPath.addLine(to: CGPoint(x: infoRect.maxX, y: infoRect.maxY))
        infoPath.addLine(to: CGPoint(x: infoRect.minX, y: infoRect.maxY))
        infoPath.addLine(to: CGPoint(x: infoRect.minX, y: infoRect.minY + Metrics.windowCornerRadius))
        infoPath.addArc(center: CGPoint(x: infoRect.minX + Metrics.windowCornerRadius, y: infoRect.minY + Metrics.windowCornerRadius),
                        radius: Metrics.windowCornerRadius, startAngle: .pi, endAngle: -.pi / 2, clockwise: false)
        infoPath.closeSubpath()

        context.addPath(infoPath)
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: alpha * 0.9))
        context.fillPath()
        context.restoreGState()

        if let icon = window.appIcon {
            let iconRect = CGRect(
                x: infoRect.minX + 8,
                y: infoRect.minY + (infoHeight - Metrics.iconSize) / 2,
                width: Metrics.iconSize,
                height: Metrics.iconSize
            )
            if let cgIcon = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                context.draw(cgIcon, in: iconRect)
            }
        }

        let textX = infoRect.minX + 8 + Metrics.iconSize + 6
        let maxTextWidth = infoRect.width - (textX - infoRect.minX) - 8

        let titleFont = CTFontCreateWithName("SF Pro Text" as CFString, Metrics.titleFontSize, nil)
        let truncatedTitle = truncateText(window.title, font: titleFont, maxWidth: maxTextWidth)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor(cgColor: Colors.textWhite.copy(alpha: alpha)!)!
        ]
        let titleString = NSAttributedString(string: truncatedTitle, attributes: titleAttributes)
        let titleLine = CTLineCreateWithAttributedString(titleString)

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: textX, y: infoRect.minY + 20)
        CTLineDraw(titleLine, context)
        context.restoreGState()

        let appFont = CTFontCreateWithName("SF Pro Text" as CFString, Metrics.appNameFontSize, nil)
        let appAttributes: [NSAttributedString.Key: Any] = [
            .font: appFont,
            .foregroundColor: NSColor(cgColor: Colors.textGray.copy(alpha: alpha)!)!
        ]
        let appString = NSAttributedString(string: window.appName, attributes: appAttributes)
        let appLine = CTLineCreateWithAttributedString(appString)

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: textX, y: infoRect.minY + 6)
        CTLineDraw(appLine, context)
        context.restoreGState()

        if window.isHovered {
            renderCloseButton(
                context: context,
                frame: window.closeButtonFrame,
                isHovered: window.closeButtonHovered,
                alpha: alpha
            )
        }

        context.restoreGState()
    }

    private static func renderCloseButton(
        context: CGContext,
        frame: CGRect,
        isHovered: Bool,
        alpha: CGFloat
    ) {
        let bgColor = isHovered ? Colors.closeButtonHover : Colors.closeButtonBackground
        let path = CGPath(ellipseIn: frame, transform: nil)

        context.addPath(path)
        context.setFillColor(bgColor.copy(alpha: alpha)!)
        context.fillPath()

        let xInset: CGFloat = 6
        context.setStrokeColor(Colors.closeButtonX.copy(alpha: alpha)!)
        context.setLineWidth(2)
        context.setLineCap(.round)

        context.move(to: CGPoint(x: frame.minX + xInset, y: frame.minY + xInset))
        context.addLine(to: CGPoint(x: frame.maxX - xInset, y: frame.maxY - xInset))
        context.strokePath()

        context.move(to: CGPoint(x: frame.maxX - xInset, y: frame.minY + xInset))
        context.addLine(to: CGPoint(x: frame.minX + xInset, y: frame.maxY - xInset))
        context.strokePath()
    }

    private static func renderSearchBar(
        context: CGContext,
        frame: CGRect,
        searchQuery: String,
        alpha: CGFloat
    ) {
        let path = CGPath(roundedRect: frame, cornerWidth: Metrics.searchBarCornerRadius, cornerHeight: Metrics.searchBarCornerRadius, transform: nil)

        context.addPath(path)
        context.setFillColor(Colors.searchBarBackground.copy(alpha: alpha)!)
        context.fillPath()

        context.addPath(path)
        context.setStrokeColor(Colors.searchBarBorder.copy(alpha: alpha)!)
        context.setLineWidth(Metrics.searchBarBorderWidth)
        context.strokePath()

        let displayText = searchQuery.isEmpty ? "Type to search..." : searchQuery
        let textColor = searchQuery.isEmpty ? Colors.textDimmed : Colors.textWhite

        let font = CTFontCreateWithName("SF Pro Text" as CFString, Metrics.searchFontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: textColor.copy(alpha: alpha)!)!
        ]
        let attributedString = NSAttributedString(string: displayText, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributedString)

        let textBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let textX = frame.midX - textBounds.width / 2
        let textY = frame.midY - textBounds.height / 2

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: textX, y: textY)
        CTLineDraw(line, context)
        context.restoreGState()

        if !searchQuery.isEmpty {
            let cursorX = textX + textBounds.width + 2
            let cursorHeight: CGFloat = 18
            let cursorY = frame.midY - cursorHeight / 2

            let time = CACurrentMediaTime()
            let cursorAlpha = (sin(time * 3) + 1) / 2

            context.setFillColor(Colors.textWhite.copy(alpha: alpha * CGFloat(cursorAlpha))!)
            context.fill(CGRect(x: cursorX, y: cursorY, width: 2, height: cursorHeight))
        }
    }

    private static func truncateText(_ text: String, font: CTFont, maxWidth: CGFloat) -> String {
        var result = text
        while result.count > 0 {
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let attrString = NSAttributedString(string: result + "...", attributes: attributes)
            let line = CTLineCreateWithAttributedString(attrString)
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

            if bounds.width <= maxWidth || result.count <= 3 {
                return result == text ? text : result + "..."
            }
            result = String(result.dropLast())
        }
        return text
    }
}
