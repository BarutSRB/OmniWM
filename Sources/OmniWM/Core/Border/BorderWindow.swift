import AppKit
import QuartzCore

@MainActor
final class BorderWindow {
    struct Operations {
        var createBorderWindow: @MainActor (CGRect) -> UInt32
        var releaseBorderWindow: @MainActor (UInt32) -> Void
        var configureWindow: @MainActor (UInt32, Float, Bool) -> Void
        var setWindowTags: @MainActor (UInt32, UInt64) -> Void
        var createWindowContext: @MainActor (UInt32) -> CGContext?
        var setWindowShape: @MainActor (UInt32, CGRect) -> Void
        var flushWindow: @MainActor (UInt32) -> Void
        var transactionMove: @MainActor (UInt32, CGPoint) -> Void
        var transactionMoveAndOrder: @MainActor (UInt32, CGPoint, Int32, UInt32, SkyLightWindowOrder) -> Void
        var transactionHide: @MainActor (UInt32) -> Void

        static let live = Self(
            createBorderWindow: { SkyLight.shared.createBorderWindow(frame: $0) },
            releaseBorderWindow: { SkyLight.shared.releaseBorderWindow($0) },
            configureWindow: { SkyLight.shared.configureWindow($0, resolution: $1, opaque: $2) },
            setWindowTags: { SkyLight.shared.setWindowTags($0, tags: $1) },
            createWindowContext: { SkyLight.shared.createWindowContext(for: $0) },
            setWindowShape: { SkyLight.shared.setWindowShape($0, frame: $1) },
            flushWindow: { SkyLight.shared.flushWindow($0) },
            transactionMove: { SkyLight.shared.transactionMove($0, origin: $1) },
            transactionMoveAndOrder: {
                SkyLight.shared.transactionMoveAndOrder($0, origin: $1, level: $2, relativeTo: $3, order: $4)
            },
            transactionHide: { SkyLight.shared.transactionHide($0) }
        )
    }

    private var wid: UInt32 = 0
    private var context: CGContext?
    private var config: BorderConfig
    private let operations: Operations

    private var currentFrame: CGRect = .zero
    private var currentTargetFrame: CGRect = .zero
    private var currentTargetWid: UInt32 = 0
    private var origin: CGPoint = .zero
    private var needsRedraw = true
    private var isVisible = false
    private var lastOrderedTargetWid: UInt32 = 0

    private let padding: CGFloat = 8.0
    private let cornerRadius: CGFloat = 9.0
    private let orderingLevel: Int32 = 3

    init(config: BorderConfig, operations: Operations = .live) {
        self.config = config
        self.operations = operations
    }

    func destroy() {
        context = nil
        if wid != 0 {
            operations.releaseBorderWindow(wid)
            wid = 0
        }
        isVisible = false
        lastOrderedTargetWid = 0
        currentTargetWid = 0
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

        let createdWindow: Bool
        if wid == 0 {
            createWindow(frame: frame, scale: scale)
            guard wid != 0 else { return }
            createdWindow = true
        } else {
            createdWindow = false
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

        let needsOrdering = createdWindow || !isVisible || lastOrderedTargetWid != targetWid
        move(relativeTo: targetWid, needsOrdering: needsOrdering)
        isVisible = true
        lastOrderedTargetWid = targetWid
    }

    private func createWindow(frame: CGRect, scale: CGFloat) {
        wid = operations.createBorderWindow(frame)
        guard wid != 0 else { return }

        operations.configureWindow(wid, Float(scale), false)

        let tags: UInt64 = (1 << 1) | (1 << 9)
        operations.setWindowTags(wid, tags)

        context = operations.createWindowContext(wid)
        context?.interpolationQuality = .none
    }

    private func reshapeWindow(frame: CGRect) {
        operations.setWindowShape(wid, frame)
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
        operations.flushWindow(wid)
    }

    private func move(relativeTo targetWid: UInt32, needsOrdering: Bool) {
        if needsOrdering {
            operations.transactionMoveAndOrder(wid, origin, orderingLevel, targetWid, .below)
            return
        }

        operations.transactionMove(wid, origin)
    }

    func hide() {
        guard wid != 0 else { return }
        operations.transactionHide(wid)
        isVisible = false
        lastOrderedTargetWid = 0
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
