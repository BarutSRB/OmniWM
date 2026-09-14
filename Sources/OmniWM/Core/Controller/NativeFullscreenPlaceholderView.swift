// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreText

final class NativeFullscreenPlaceholderView: NSView {
    private static let title = "In macOS Full Screen"
    private static let subtitle = "Move or resize this slot; the window will return here."
    private static let activationModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift, .function]
    private static let titleFont = NSFont.systemFont(ofSize: 17, weight: .semibold) as CTFont
    private static let subtitleFont = NSFont.systemFont(ofSize: 12) as CTFont

    private let appName: String
    private let icon: CGImage?
    private let titleLine: CTLine
    private let subtitleLine: CTLine
    private let titleLineWidth: CGFloat
    private let subtitleLineWidth: CGFloat
    private var tracking: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false
    private var isTrackingPrimaryPress = false
    private var isSelected = false

    var onActivate: (() -> Void)?

    init(appName: String?, icon: NSImage?) {
        let resolvedAppName = appName ?? "Application"
        self.appName = resolvedAppName
        let sourceIcon = icon ?? NSImage(named: NSImage.applicationIconName)
        self.icon = sourceIcon?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let titleAttributed = Self.attributedLine(
            Self.title,
            font: Self.titleFont,
            color: .white
        )
        let subtitleAttributed = Self.attributedLine(
            Self.subtitle,
            font: Self.subtitleFont,
            color: NSColor.white.withAlphaComponent(0.78)
        )
        let resolvedTitleLine = CTLineCreateWithAttributedString(titleAttributed)
        let resolvedSubtitleLine = CTLineCreateWithAttributedString(subtitleAttributed)
        titleLine = resolvedTitleLine
        subtitleLine = resolvedSubtitleLine
        titleLineWidth = CGFloat(CTLineGetTypographicBounds(resolvedTitleLine, nil, nil, nil))
        subtitleLineWidth = CGFloat(CTLineGetTypographicBounds(resolvedSubtitleLine, nil, nil, nil))
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        toolTip = "Press to switch Spaces. The tiling position remains reserved."
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let tracking {
            removeTrackingArea(tracking)
        }
        let nextTracking = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTracking)
        tracking = nextTracking
        super.updateTrackingAreas()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let panelBounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(
            roundedRect: panelBounds,
            cornerWidth: 10,
            cornerHeight: 10,
            transform: nil
        )

        context.addPath(path)
        context.setFillColor(resolvedColor(.black, alpha: 0.98))
        context.fillPath()

        if isHovered || isPressed {
            context.addPath(path)
            let alpha: CGFloat = isPressed ? 0.16 : 0.07
            context.setFillColor(resolvedColor(.controlAccentColor, alpha: alpha))
            context.fillPath()
        }

        context.addPath(path)
        context.setLineWidth(isSelected ? 2 : 1)
        context.setStrokeColor(
            isSelected
                ? resolvedColor(.controlAccentColor, alpha: 1)
                : resolvedColor(.separatorColor, alpha: 0.9)
        )
        context.strokePath()

        drawContent(in: context)
    }

    override func mouseEntered(with _: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with _: NSEvent) {
        setHovered(false)
        if isTrackingPrimaryPress {
            setPressed(false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0,
              event.modifierFlags.isDisjoint(with: Self.activationModifiers)
        else { return }
        isTrackingPrimaryPress = true
        setPressed(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTrackingPrimaryPress else { return }
        let point = convert(event.locationInWindow, from: nil)
        setPressed(
            bounds.contains(point)
                && event.modifierFlags.isDisjoint(with: Self.activationModifiers)
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard isTrackingPrimaryPress else { return }
        let point = convert(event.locationInWindow, from: nil)
        let shouldActivate = event.buttonNumber == 0
            && bounds.contains(point)
            && event.modifierFlags.isDisjoint(with: Self.activationModifiers)
        isTrackingPrimaryPress = false
        setPressed(false)
        if shouldActivate {
            onActivate?()
        }
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }

    override func accessibilityChildren() -> [Any]? {
        []
    }

    override func accessibilityLabel() -> String? {
        "\(appName), in macOS Full Screen"
    }

    override func accessibilityHelp() -> String? {
        "Press to switch to the app's macOS Full Screen Space. Its tiling position remains reserved."
    }

    override func accessibilityValue() -> Any? {
        NSNumber(value: isSelected)
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }

    func setSelected(_ selected: Bool) {
        guard isSelected != selected else { return }
        isSelected = selected
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    func cancelInteraction() {
        isTrackingPrimaryPress = false
        setPressed(false)
        setHovered(false)
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
    }

    private func setPressed(_ pressed: Bool) {
        guard isPressed != pressed else { return }
        isPressed = pressed
        needsDisplay = true
    }

    private func drawContent(in context: CGContext) {
        let shortestSide = min(bounds.width, bounds.height)
        let maximumTextWidth = max(bounds.width - 48, 0)
        if bounds.width < 180
            || bounds.height < 140
            || titleLineWidth > maximumTextWidth
            || subtitleLineWidth > maximumTextWidth
        {
            let iconSide = min(64, max(min(shortestSide, 24), shortestSide - 24))
            drawIcon(
                in: CGRect(
                    x: (bounds.width - iconSide) / 2,
                    y: (bounds.height - iconSide) / 2,
                    width: iconSide,
                    height: iconSide
                ),
                context: context
            )
            return
        }
        let iconSide = min(96, max(48, shortestSide * 0.2))
        let titleHeight = CGFloat(CTFontGetAscent(Self.titleFont) + CTFontGetDescent(Self.titleFont))
        let subtitleHeight = CGFloat(CTFontGetAscent(Self.subtitleFont) + CTFontGetDescent(Self.subtitleFont))
        let contentHeight = iconSide + 16 + titleHeight + 6 + subtitleHeight
        let contentBottom = max((bounds.height - contentHeight) / 2, 16)
        let iconFrame = CGRect(
            x: (bounds.width - iconSide) / 2,
            y: contentBottom + titleHeight + subtitleHeight + 22,
            width: iconSide,
            height: iconSide
        )
        drawIcon(in: iconFrame, context: context)
        drawCentered(
            line: titleLine,
            lineWidth: titleLineWidth,
            baseline: contentBottom + subtitleHeight + 6,
            context: context
        )
        drawCentered(
            line: subtitleLine,
            lineWidth: subtitleLineWidth,
            baseline: contentBottom,
            context: context
        )
    }

    private func drawIcon(in frame: CGRect, context: CGContext) {
        guard let icon else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(icon, in: frame)
        context.restoreGState()
    }

    private func drawCentered(
        line: CTLine,
        lineWidth: CGFloat,
        baseline: CGFloat,
        context: CGContext
    ) {
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: (bounds.width - lineWidth) / 2, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func resolvedColor(_ color: NSColor, alpha: CGFloat) -> CGColor {
        var resolved: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.withAlphaComponent(alpha).cgColor
        }
        return resolved ?? color.withAlphaComponent(alpha).cgColor
    }

    private static func attributedLine(
        _ text: String,
        font: CTFont,
        color: NSColor
    ) -> NSAttributedString {
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color
            ]
        )
    }
}
