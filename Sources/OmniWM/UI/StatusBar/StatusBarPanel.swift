import AppKit
import SwiftUI

@MainActor
final class StatusBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StatusBarPanelController: NSObject, NSWindowDelegate {
    private weak var statusButton: NSStatusBarButton?
    private let ownedWindowRegistry = OwnedWindowRegistry.shared

    private(set) var panel: StatusBarPanel?

    var onDismiss: ((Bool) -> Void)?

    func show(using viewModel: StatusBarMenuViewModel, anchoredTo button: NSStatusBarButton) {
        statusButton = button

        if panel == nil {
            panel = makePanel(viewModel: viewModel)
        } else if let panel {
            let hosting = NSHostingView(rootView: StatusBarMenuView(viewModel: viewModel))
            hosting.translatesAutoresizingMaskIntoConstraints = false
            panel.contentView = hosting
            panel.setContentSize(hosting.fittingSize)
        }

        guard let panel else { return }

        panel.contentView?.layoutSubtreeIfNeeded()
        position(panel: panel, relativeTo: button)
        viewModel.resetFocus()
        panel.orderFrontRegardless()
        panel.makeKey()
        ownedWindowRegistry.register(panel)
    }

    func close(restoreFocus: Bool) {
        hideWithoutCallbacks()
        onDismiss?(restoreFocus)
    }

    func hideWithoutCallbacks() {
        guard let panel else { return }
        panel.orderOut(nil)
        ownedWindowRegistry.unregister(panel)
    }

    func windowDidResignKey(_: Notification) {
        close(restoreFocus: true)
    }

    private func makePanel(viewModel: StatusBarMenuViewModel) -> StatusBarPanel {
        let hosting = NSHostingView(rootView: StatusBarMenuView(viewModel: viewModel))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let panel = StatusBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: statusBarMenuWidth, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.animationBehavior = .utilityWindow
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        return panel
    }

    private func position(panel: StatusBarPanel, relativeTo button: NSStatusBarButton) {
        guard let screen = button.window?.screen ?? NSScreen.main,
              let buttonWindow = button.window
        else {
            return
        }

        let buttonFrame = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrame)
        let panelSize = panel.contentView?.fittingSize ?? NSSize(width: statusBarMenuWidth, height: 380)

        let x = min(
            max(screen.visibleFrame.minX + 8, buttonFrameOnScreen.maxX - panelSize.width),
            screen.visibleFrame.maxX - panelSize.width - 8
        )
        let y = buttonFrameOnScreen.minY - panelSize.height - 8

        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: panelSize), display: true)
    }
}
