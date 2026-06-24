// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

struct MenuToggleTileConfig {
    let key: String
    let icon: String
    let label: String
    let accessibilityName: String
    let isOn: Bool
    let onChange: (Bool) -> Void
}

@MainActor
final class MenuToggleGridView: NSView {
    private(set) var tiles: [String: MenuToggleTileView] = [:]

    override var isFlipped: Bool {
        true
    }

    init(width: CGFloat, configs: [MenuToggleTileConfig], motionPolicy: MotionPolicy) {
        let columns = 3
        let outerPadding: CGFloat = 10
        let gap: CGFloat = 6
        let tileHeight: CGFloat = 64
        let available = width - outerPadding * 2 - gap * CGFloat(columns - 1)
        let tileWidth = (available / CGFloat(columns)).rounded(.down)
        let rows = Int((Double(configs.count) / Double(columns)).rounded(.up))
        let totalHeight = outerPadding * 2 + CGFloat(rows) * tileHeight + CGFloat(max(0, rows - 1)) * gap

        super.init(frame: NSRect(x: 0, y: 0, width: width, height: totalHeight))
        applyCurrentAppAppearance(to: self)

        for (index, config) in configs.enumerated() {
            let row = index / columns
            let column = index % columns
            let originX = outerPadding + CGFloat(column) * (tileWidth + gap)
            let originY = outerPadding + CGFloat(row) * (tileHeight + gap)
            let tile = MenuToggleTileView(
                frame: NSRect(x: originX, y: originY, width: tileWidth, height: tileHeight),
                config: config,
                motionPolicy: motionPolicy
            )
            addSubview(tile)
            tiles[config.key] = tile
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setOn(_ isOn: Bool, forKey key: String) {
        tiles[key]?.isOn = isOn
    }
}

@MainActor
final class MenuToggleTileView: NSView {
    private let motionPolicy: MotionPolicy
    private let onChange: (Bool) -> Void

    var isOn: Bool {
        didSet {
            guard oldValue != isOn else { return }
            updateAppearance(animated: true)
        }
    }

    private let backgroundLayer = CALayer()
    private var iconView: NSImageView?
    private var labelField: NSTextField?
    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false

    override var isFlipped: Bool {
        true
    }

    init(frame: NSRect, config: MenuToggleTileConfig, motionPolicy: MotionPolicy) {
        self.motionPolicy = motionPolicy
        onChange = config.onChange
        isOn = config.isOn
        super.init(frame: frame)
        applyCurrentAppAppearance(to: self)
        wantsLayer = true

        backgroundLayer.cornerRadius = 8
        backgroundLayer.cornerCurve = .continuous
        backgroundLayer.frame = bounds
        layer?.addSublayer(backgroundLayer)

        let iconSize: CGFloat = 20
        let iconImageView = NSImageView(
            frame: NSRect(x: (bounds.width - iconSize) / 2, y: 10, width: iconSize, height: iconSize)
        )
        if let image = NSImage(systemSymbolName: config.icon, accessibilityDescription: config.accessibilityName) {
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            iconImageView.image = image.withSymbolConfiguration(symbolConfig)
        }
        addSubview(iconImageView)
        iconView = iconImageView

        let label = NSTextField(labelWithString: config.label)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.frame = NSRect(x: 2, y: 33, width: bounds.width - 4, height: 26)
        addSubview(label)
        labelField = label

        toolTip = config.accessibilityName
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(config.accessibilityName)

        updateAppearance(animated: false)
        updateTrackingAreas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance(animated: true)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hoveredNow = bounds.contains(point)
        guard hoveredNow != isHovered else { return }
        isHovered = hoveredNow
        updateAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        onChange(isOn)
    }

    override func layout() {
        super.layout()
        backgroundLayer.frame = bounds
    }

    private func updateAppearance(animated: Bool) {
        let shouldAnimate = animated && motionPolicy.animationsEnabled
        let fill: CGColor
        let tint: NSColor
        if isOn {
            fill = NSColor.controlAccentColor.withAlphaComponent(isHovered ? 1.0 : 0.9).cgColor
            tint = .white
        } else {
            fill = NSColor.secondaryLabelColor.withAlphaComponent(isHovered ? 0.20 : 0.12).cgColor
            tint = isHovered ? .labelColor : .secondaryLabelColor
        }

        CATransaction.begin()
        CATransaction.setDisableActions(!shouldAnimate)
        CATransaction.setAnimationDuration(shouldAnimate ? 0.12 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        backgroundLayer.frame = bounds
        backgroundLayer.backgroundColor = fill
        CATransaction.commit()

        iconView?.contentTintColor = tint
        labelField?.textColor = isOn ? .white : .labelColor
        setAccessibilityValue(isOn)
    }
}
