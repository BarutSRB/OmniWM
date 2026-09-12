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
    private var windows: [OverviewWindow] = []
    private var windowsByDisplayId: [CGDirectDisplayID: OverviewWindow] = [:]

    init(projection: OverviewViewportProjection, ownedWindowRegistry: OwnedWindowRegistry) {
        self.projection = projection
        self.ownedWindowRegistry = ownedWindowRegistry
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
        palette: OverviewRenderPalette? = nil,
        thumbnails: [Int: CGImage]? = nil
    ) {
        for window in windows {
            let layout = projection.layoutsByMonitor[window.monitorId] ?? .init()
            window.updateLayout(
                layout,
                state: state,
                searchQuery: projection.searchQuery,
                selectedWindowHandle: projection.selectedWindowHandle,
                palette: palette,
                thumbnails: thumbnails
            )
        }
    }

    func updateWindowThumbnails(_ thumbnailCache: [Int: CGImage]) {
        for window in windows {
            window.updateThumbnails(thumbnailCache)
        }
    }

    func updateAnimationProgress(
        _ progress: Double,
        on displayId: CGDirectDisplayID,
        generation: UInt64,
        sequence: UInt64
    ) {
        windowsByDisplayId[displayId]?.updateAnimationProgress(
            progress,
            generation: generation,
            sequence: sequence
        )
    }

    func handleModifierFlagsChanged(_ modifierFlags: NSEvent.ModifierFlags) {
        let optionPressed = modifierFlags.contains(.option)
        for window in windows {
            window.cancelPendingDragIfNeeded(optionPressed: optionPressed)
        }
    }
}
