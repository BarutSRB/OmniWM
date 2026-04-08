import AppKit
import QuartzCore

struct BorderOrderingMetadata: Equatable {
    let level: Int32
    let relativeTo: UInt32
    let order: SkyLightWindowOrder
    let cornerRadius: CGFloat?

    static func fallback(
        relativeTo targetWid: UInt32,
        level: Int32 = 3,
        cornerRadius: CGFloat? = nil
    ) -> Self {
        Self(
            level: level,
            relativeTo: targetWid,
            order: .below,
            cornerRadius: cornerRadius
        )
    }

    var resolvedCornerRadius: CGFloat? {
        guard let cornerRadius, cornerRadius >= 0 else { return nil }
        return cornerRadius
    }
}

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
        var backingScaleForFrame: @MainActor (CGRect) -> CGFloat

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
            transactionHide: { SkyLight.shared.transactionHide($0) },
            backingScaleForFrame: { targetFrame in
                let targetScreen = NSScreen.screens.first(where: {
                    $0.frame.contains(targetFrame.center)
                }) ?? NSScreen.main ?? NSScreen.screens.first
                return targetScreen?.backingScaleFactor ?? 2.0
            }
        )
    }

    private var wid: UInt32 = 0
    private var context: CGContext?
    private var config: BorderConfig
    private let operations: Operations

    private var currentFrame: CGRect = .zero
    private var currentTargetFrame: CGRect = .zero
    private var currentTargetWid: UInt32 = 0
    private var currentOrderingMetadata: BorderOrderingMetadata?
    private var origin: CGPoint = .zero
    private var needsRedraw = true
    private var isVisible = false
    private var hasLiveOwner = false
    private var lastAppliedOrderingMetadata: BorderOrderingMetadata?
    private var lastConfiguredScale: CGFloat = 0

    private let padding: CGFloat = 8.0
    private let defaultCornerRadius: CGFloat = 9.0
    private let fallbackOrderingLevel: Int32 = 3

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
        clearOwnerDerivedState()
        lastConfiguredScale = 0
    }

    func update(
        frame targetFrame: CGRect,
        targetWid: UInt32,
        ordering orderingMetadata: BorderOrderingMetadata? = nil
    ) {
        let borderWidth = config.width
        let scale = operations.backingScaleForFrame(targetFrame)
        let resolvedOrderingMetadata = orderingMetadata
            ?? .fallback(relativeTo: targetWid, level: fallbackOrderingLevel)

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

        if scale != lastConfiguredScale, wid != 0 {
            operations.configureWindow(wid, Float(scale), false)
            lastConfiguredScale = scale
            needsRedraw = true
        }

        if frame.size != currentFrame.size {
            reshapeWindow(frame: frame)
            needsRedraw = true
        }
        if currentOrderingMetadata?.resolvedCornerRadius != resolvedOrderingMetadata.resolvedCornerRadius {
            needsRedraw = true
        }
        currentTargetFrame = targetFrame
        currentTargetWid = targetWid
        currentFrame = frame
        currentOrderingMetadata = resolvedOrderingMetadata
        hasLiveOwner = true

        if needsRedraw {
            draw(frame: frame, drawingBounds: drawingBounds)
        }

        let needsOrdering = createdWindow
            || !isVisible
            || lastAppliedOrderingMetadata != resolvedOrderingMetadata
        move(ordering: resolvedOrderingMetadata, needsOrdering: needsOrdering)
        isVisible = true
        lastAppliedOrderingMetadata = resolvedOrderingMetadata
    }

    private func createWindow(frame: CGRect, scale: CGFloat) {
        wid = operations.createBorderWindow(frame)
        guard wid != 0 else { return }

        operations.configureWindow(wid, Float(scale), false)
        lastConfiguredScale = scale

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
        let cornerRadius = currentOrderingMetadata?.resolvedCornerRadius ?? defaultCornerRadius
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

    private func move(ordering: BorderOrderingMetadata, needsOrdering: Bool) {
        if needsOrdering {
            operations.transactionMoveAndOrder(
                wid,
                origin,
                ordering.level,
                ordering.relativeTo,
                ordering.order
            )
            return
        }

        operations.transactionMove(wid, origin)
    }

    func hide() {
        if wid != 0 {
            operations.transactionHide(wid)
        }
        clearOwnerDerivedState()
    }

    func updateConfig(_ newConfig: BorderConfig) {
        let needsRedrawForColor = config.color != newConfig.color
        let needsRedrawForWidth = config.width != newConfig.width
        config = newConfig
        guard needsRedrawForColor || needsRedrawForWidth else { return }

        needsRedraw = true

        guard isVisible,
              hasLiveOwner,
              wid != 0,
              currentTargetWid != 0,
              !currentTargetFrame.isEmpty
        else {
            return
        }

        update(
            frame: currentTargetFrame,
            targetWid: currentTargetWid,
            ordering: currentOrderingMetadata
        )
    }

    var windowId: UInt32? {
        wid == 0 ? nil : wid
    }

    private func clearOwnerDerivedState() {
        currentFrame = .zero
        currentTargetFrame = .zero
        currentTargetWid = 0
        currentOrderingMetadata = nil
        origin = .zero
        isVisible = false
        hasLiveOwner = false
        lastAppliedOrderingMetadata = nil
    }
}
