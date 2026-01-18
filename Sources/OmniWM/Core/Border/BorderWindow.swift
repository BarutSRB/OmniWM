import AppKit
import QuartzCore

@MainActor
final class BorderWindow {
    private var wid: UInt32 = 0
    private var context: CGContext?
    private var config: BorderConfig

    private var currentFrame: CGRect = .zero
    private var currentTargetFrame: CGRect = .zero
    private var currentTargetWid: UInt32 = 0
    private var origin: CGPoint = .zero
    private var needsRedraw = true

    private let padding: CGFloat = 8.0
    private let cornerRadius: CGFloat = 9.0

    init(config: BorderConfig) {
        self.config = config
    }

    func destroy() {
        context = nil
        if wid != 0 {
            SkyLight.shared.releaseBorderWindow(wid)
            wid = 0
        }
    }

    func update(frame targetFrame: CGRect, targetWid: UInt32) {
        let borderWidth = config.width
        let targetScreen = NSScreen.screens.first(where: {
            $0.frame.contains(targetFrame.center)
        }) ?? NSScreen.main ?? NSScreen.screens.first
        let scale = targetScreen?.backingScaleFactor ?? 2.0

        let borderOffset = -borderWidth - padding
        var frame = targetFrame.insetBy(dx: borderOffset, dy: borderOffset)
            .roundedToPhysicalPixels(scale: scale)

        origin = ScreenCoordinateSpace.toWindowServer(rect: frame).origin
        frame.origin = .zero

        let drawingBounds = CGRect(
            x: -borderOffset,
            y: -borderOffset,
            width: targetFrame.width,
            height: targetFrame.height
        )

        if wid == 0 {
            createWindow(frame: frame, scale: scale)
        }

        if frame.size != currentFrame.size {
            reshapeWindow(frame: frame)
            needsRedraw = true
        }
        currentTargetFrame = targetFrame
        currentTargetWid = targetWid
        currentFrame = frame

        if needsRedraw {
            draw(frame: frame, drawingBounds: drawingBounds)
        }

        moveAndOrder(relativeTo: targetWid)
    }

    private func createWindow(frame: CGRect, scale: CGFloat) {
        wid = SkyLight.shared.createBorderWindow(frame: frame)
        guard wid != 0 else { return }

        SkyLight.shared.configureWindow(wid, resolution: Float(scale), opaque: false)

        let tags: UInt64 = (1 << 1) | (1 << 9)
        SkyLight.shared.setWindowTags(wid, tags: tags)

        context = SkyLight.shared.createWindowContext(for: wid)
        context?.interpolationQuality = .none
    }

    private func reshapeWindow(frame: CGRect) {
        SkyLight.shared.setWindowShape(wid, frame: frame)
    }

    private func draw(frame: CGRect, drawingBounds: CGRect) {
        guard let context else { return }
        needsRedraw = false

        let borderWidth = config.width
        let outerRadius = cornerRadius + borderWidth

        context.saveGState()
        context.clear(frame)

        let innerRect = drawingBounds.insetBy(dx: borderWidth, dy: borderWidth)
        let innerPath = CGPath(
            roundedRect: innerRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        let clipPath = CGMutablePath()
        clipPath.addRect(frame)
        clipPath.addPath(innerPath)
        context.addPath(clipPath)
        context.clip(using: .evenOdd)

        context.setFillColor(config.color.cgColor)

        let outerPath = CGPath(
            roundedRect: drawingBounds,
            cornerWidth: outerRadius,
            cornerHeight: outerRadius,
            transform: nil
        )
        context.addPath(outerPath)
        context.fillPath()

        context.restoreGState()
        context.flush()
        SkyLight.shared.flushWindow(wid)
    }

    private func moveAndOrder(relativeTo targetWid: UInt32) {
        SkyLight.shared.transactionMoveAndOrder(
            wid,
            origin: origin,
            level: 3,
            relativeTo: targetWid,
            order: .below
        )
    }

    func hide() {
        guard wid != 0 else { return }
        SkyLight.shared.transactionHide(wid)
    }

    func updateConfig(_ newConfig: BorderConfig) {
        let needsRedrawForColor = config.color != newConfig.color
        let needsRedrawForWidth = config.width != newConfig.width
        config = newConfig
        if needsRedrawForColor || needsRedrawForWidth {
            if wid != 0, currentTargetWid != 0 {
                needsRedraw = true
                update(frame: currentTargetFrame, targetWid: currentTargetWid)
            }
        }
    }
}
