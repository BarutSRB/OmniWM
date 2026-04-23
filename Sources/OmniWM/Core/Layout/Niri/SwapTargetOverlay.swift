// SPDX-License-Identifier: GPL-2.0-only
import AppKit

@MainActor
final class SwapTargetOverlay {
    private var overlayWindow: NSPanel?

    func show(at frame: CGRect) {
        if overlayWindow == nil {
            overlayWindow = createOverlayWindow()
        }

        guard let window = overlayWindow else { return }
        window.setFrame(frame, display: false)
        window.contentView?.frame = CGRect(origin: .zero, size: frame.size)
        window.orderFront(nil)
    }

    func hide() {
        overlayWindow?.orderOut(nil)
    }

    private func createOverlayWindow() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false

        let contentView = NSView(frame: .zero)
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 9
        contentView.layer?.masksToBounds = true
        contentView.layer?.backgroundColor = NSColor(red: 0, green: 120.0 / 255.0, blue: 1.0, alpha: 0.25).cgColor
        panel.contentView = contentView

        return panel
    }
}
