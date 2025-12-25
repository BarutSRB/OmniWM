import AppKit
import QuartzCore

final class BorderWindow: NSWindow {
    private let borderLayer: CAShapeLayer
    private var config: BorderConfig
    private var currentCornerRadius: CGFloat = 9

    init(config: BorderConfig) {
        self.config = config
        borderLayer = CAShapeLayer()

        super.init(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        setupWindow()
        setupLayer()
    }

    private func setupWindow() {
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        ignoresMouseEvents = true
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary]

        contentView?.wantsLayer = true
        contentView?.layer?.addSublayer(borderLayer)
    }

    private func setupLayer() {
        borderLayer.fillColor = nil
        borderLayer.strokeColor = config.color.cgColor
        borderLayer.lineWidth = config.width
    }

    private var wid: UInt32 { UInt32(windowNumber) }

    func update(frame targetFrame: CGRect, cornerRadius: CGFloat, config: BorderConfig, targetWid: UInt32? = nil) {
        self.config = config
        currentCornerRadius = cornerRadius

        let expansion = config.width / 2
        let borderFrame = targetFrame.insetBy(dx: -expansion, dy: -expansion)

        SkyLight.shared.disableUpdates()
        defer { SkyLight.shared.reenableUpdates() }

        setFrame(borderFrame, display: false)

        borderLayer.frame = CGRect(origin: .zero, size: borderFrame.size)
        borderLayer.strokeColor = config.color.cgColor
        borderLayer.lineWidth = config.width

        let pathRect = CGRect(origin: .zero, size: borderFrame.size).insetBy(
            dx: config.width / 2,
            dy: config.width / 2
        )

        let adjustedRadius = max(0, cornerRadius + config.width / 2)
        let path = CGPath(
            roundedRect: pathRect,
            cornerWidth: adjustedRadius,
            cornerHeight: adjustedRadius,
            transform: nil
        )
        borderLayer.path = path

        if let targetWid {
            SkyLight.shared.orderWindow(wid, relativeTo: targetWid, order: .below)
        }
    }

    func updateConfig(_ config: BorderConfig) {
        self.config = config
        borderLayer.strokeColor = config.color.cgColor
        borderLayer.lineWidth = config.width

        if frame.size != .zero {
            let windowBounds = CGRect(origin: .zero, size: frame.size)
            let pathRect = windowBounds.insetBy(dx: config.width / 2, dy: config.width / 2)
            let adjustedRadius = max(0, currentCornerRadius + config.width / 2)
            let path = CGPath(
                roundedRect: pathRect,
                cornerWidth: adjustedRadius,
                cornerHeight: adjustedRadius,
                transform: nil
            )
            borderLayer.path = path
        }
    }
}
