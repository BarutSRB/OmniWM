// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import IOSurface
import QuartzCore

@MainActor
final class OverviewDragGhost: NSPanel {
    let thumbnail = CALayer()
    private let root = CALayer()
    private let ownedWindowRegistry: OwnedWindowRegistry
    private var surfaceId: String?
    private(set) var preview: OverviewPreviewFrame?

    init(originalFrame: CGRect, ownedWindowRegistry: OwnedWindowRegistry) {
        self.ownedWindowRegistry = ownedWindowRegistry
        let size = CGSize(width: originalFrame.width * 0.5, height: originalFrame.height * 0.5)
        super.init(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        ignoresMouseEvents = true
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        alphaValue = 0.5

        let view = NSView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer = root
        contentView = view
        root.frame = view.bounds
        root.backgroundColor = OverviewRenderStyle.Colors.windowBackground
        root.cornerRadius = OverviewRenderStyle.Metrics.windowCornerRadius
        root.masksToBounds = true
        thumbnail.contentsGravity = .resize
        thumbnail.frame = root.bounds
        root.addSublayer(thumbnail)

        let surfaceId = "overview-drag-ghost-\(ObjectIdentifier(self).hashValue)"
        self.surfaceId = surfaceId
        ownedWindowRegistry.register(
            self,
            surfaceId: surfaceId,
            policy: SurfacePolicy(
                kind: .dragGhost,
                hitTestPolicy: .passthrough,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
    }

    isolated deinit {
        destroy()
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    func updatePreview(_ frame: OverviewPreviewFrame?) {
        guard surfaceId != nil, preview !== frame else { return }
        let previous = preview
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { withExtendedLifetime(previous) {} }
        preview = frame
        thumbnail.contents = frame?.surface
        thumbnail.contentsRect = frame?.contentsRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let contentSize = frame.map {
            CGSize(
                width: CGFloat($0.surface.width) * $0.contentsRect.width,
                height: CGFloat($0.surface.height) * $0.contentsRect.height
            )
        } ?? .zero
        thumbnail.frame = OverviewRenderGeometry.aspectFitRect(contentSize: contentSize, in: root.bounds)
        CATransaction.commit()
    }

    func moveTo(cursorLocation: CGPoint) {
        guard surfaceId != nil else { return }
        setFrameOrigin(CGPoint(
            x: cursorLocation.x + 10,
            y: cursorLocation.y - frame.height - 10
        ))
    }

    func showAt(cursorLocation: CGPoint) {
        guard surfaceId != nil else { return }
        moveTo(cursorLocation: cursorLocation)
        orderFrontRegardless()
    }

    func destroy() {
        guard let surfaceId else { return }
        updatePreview(nil)
        self.surfaceId = nil
        ownedWindowRegistry.unregister(surfaceId: surfaceId)
        orderOut(nil)
        close()
    }
}
