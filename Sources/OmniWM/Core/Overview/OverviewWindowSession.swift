// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
import Foundation
import QuartzCore
import ScreenCaptureKit

@MainActor
final class OverviewWindowSession {
    private let projection: OverviewViewportProjection
    private let ownedWindowRegistry: OwnedWindowRegistry
    private let motionPolicy: MotionPolicy
    var onLayoutsUpdated: (() -> Void)?
    var previewForHandle: ((WindowHandle) -> OverviewPreviewFrame?)?
    private var dragPreview: (handle: WindowHandle, ghost: OverviewDragGhost)?

    var dragPreviewRequest: OverviewPreviewRequest? {
        guard let dragPreview else { return nil }
        let scale = dragPreview.ghost.backingScaleFactor
        return OverviewPreviewRequest(
            handle: dragPreview.handle,
            pixelWidth: Int(ceil(dragPreview.ghost.frame.width * scale)),
            pixelHeight: Int(ceil(dragPreview.ghost.frame.height * scale))
        )
    }

    func beginDragPreview(for handle: WindowHandle, originalFrame: CGRect, cursorLocation: CGPoint) {
        endDragPreview()
        let ghost = OverviewDragGhost(originalFrame: originalFrame, ownedWindowRegistry: ownedWindowRegistry)
        dragPreview = (handle, ghost)
        ghost.updatePreview(previewForHandle?(handle))
        ghost.showAt(cursorLocation: cursorLocation)
        onLayoutsUpdated?()
    }

    func updateDragPreviewPosition(cursorLocation: CGPoint) {
        dragPreview?.ghost.moveTo(cursorLocation: cursorLocation)
    }

    func endDragPreview() {
        guard let dragPreview else { return }
        self.dragPreview = nil
        dragPreview.ghost.destroy()
        onLayoutsUpdated?()
    }

    private var windows: [OverviewWindow] = []
    private var windowsByDisplayId: [CGDirectDisplayID: OverviewWindow] = [:]

    init(
        projection: OverviewViewportProjection,
        ownedWindowRegistry: OwnedWindowRegistry,
        motionPolicy: MotionPolicy
    ) {
        self.projection = projection
        self.ownedWindowRegistry = ownedWindowRegistry
        self.motionPolicy = motionPolicy
    }

    var displayIds: [CGDirectDisplayID] {
        windows.map(\.displayId)
    }

    func updatePalette(_ palette: OverviewRenderPalette) {
        for window in windows { window.updatePalette(palette) }
    }

    func createWindows(controller: OverviewController, monitors: [Monitor], palette: OverviewRenderPalette) {
        closeWindows()

        for monitor in monitors {
            let window = OverviewWindow(monitor: monitor, palette: palette)

            window.onWindowSelected = { [weak controller, weak self] monitorId, handle in
                self?.projection.activeInteractionMonitorId = monitorId
                controller?.input.selectAndActivateWindow(handle)
            }
            window.onWindowClosed = { [weak controller, weak self] monitorId, handle in
                self?.projection.activeInteractionMonitorId = monitorId
                controller?.closeWindow(handle)
            }
            window.onDismiss = { [weak controller, weak self] monitorId in
                self?.projection.activeInteractionMonitorId = monitorId
                controller?.input.dismissToSelection(animated: true)
            }
            window.onScroll = { [weak controller] monitorId, delta in
                controller?.input.adjustScrollOffset(by: delta, on: monitorId)
            }
            window.onScrollWithModifiers = { [weak controller] monitorId, delta, modifiers, isPrecise in
                controller?.input.handleScroll(
                    delta: delta,
                    modifiers: modifiers,
                    isPrecise: isPrecise,
                    on: monitorId
                )
            }
            window.onDragBegin = { [weak controller] monitorId, handle, start in
                controller?.drag.beginDrag(on: monitorId, handle: handle, startPoint: start)
            }
            window.onDragUpdate = { [weak controller] monitorId, point in
                controller?.drag.updateDrag(on: monitorId, at: point)
            }
            window.onDragEnd = { [weak controller] monitorId, point in
                controller?.drag.endDrag(on: monitorId, at: point)
            }
            window.onDragCancel = { [weak controller] in
                controller?.drag.cancelDrag()
            }

            windows.append(window)
            windowsByDisplayId[monitor.displayId] = window
        }
    }

    func showWindows() {
        let primaryWindow = primaryOverviewWindow()

        if let primaryWindow {
            primaryWindow.show(asKeyWindow: true)
            ownedWindowRegistry.register(
                primaryWindow,
                surfaceId: "overview-\(String(describing: primaryWindow.monitorId))",
                policy: SurfacePolicy(
                    kind: .overview,
                    hitTestPolicy: .interactive,
                    capturePolicy: .included,
                    suppressesManagedFocusRecovery: true
                )
            )
        }

        for window in windows where primaryWindow == nil || window !== primaryWindow {
            window.show(asKeyWindow: false)
            ownedWindowRegistry.register(
                window,
                surfaceId: "overview-\(String(describing: window.monitorId))",
                policy: SurfacePolicy(
                    kind: .overview,
                    hitTestPolicy: .interactive,
                    capturePolicy: .included,
                    suppressesManagedFocusRecovery: true
                )
            )
        }
    }

    func primaryOverviewWindow() -> OverviewWindow? {
        guard let primaryMonitorId = projection.activeInteractionMonitorId ?? windows.first?.monitorId
        else { return nil }
        return windows.first(where: { $0.monitorId == primaryMonitorId })
    }

    func closeWindows() {
        endDragPreview()
        for window in windows {
            ownedWindowRegistry.unregister(surfaceId: "overview-\(String(describing: window.monitorId))")
            window.hide()
            window.close()
        }
        windows.removeAll()
        windowsByDisplayId.removeAll(keepingCapacity: true)
    }

    func updateWindowDisplays(
        state: OverviewState,
        palette: OverviewRenderPalette? = nil
    ) {
        for window in windows {
            let layout = projection.layoutsByMonitor[window.monitorId] ?? .init()
            window.updateLayout(
                layout,
                state: state,
                searchQuery: projection.searchQuery,
                selectedWindowHandle: projection.selectedWindowHandle,
                palette: palette,
                animationsEnabled: motionPolicy.animationsEnabled
            )
        }
        onLayoutsUpdated?()
    }

    func updatePreview(_ frame: OverviewPreviewFrame?, for handle: WindowHandle) {
        if dragPreview?.handle === handle { dragPreview?.ghost.updatePreview(frame) }
        for window in windows where projection.layoutsByMonitor[window.monitorId]?.window(for: handle) != nil {
            window.updatePreview(frame, for: handle)
        }
    }

    func installAnimation(
        _ transition: OverviewNativeTransition,
        on displayId: CGDirectDisplayID,
        completion: OverviewAnimationCompletion
    ) -> Bool {
        windowsByDisplayId[displayId]?.installAnimation(transition, completion: completion) ?? false
    }

    func cancelAnimations() {
        for window in windows { window.cancelAnimation() }
    }

    func handleModifierFlagsChanged(_ modifierFlags: NSEvent.ModifierFlags) {
        let optionPressed = modifierFlags.contains(.option)
        for window in windows {
            window.cancelPendingDragIfNeeded(optionPressed: optionPressed)
        }
    }
}
