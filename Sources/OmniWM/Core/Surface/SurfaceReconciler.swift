// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct DesiredBorderSurface: Equatable {
    var windowId: Int
    var frame: CGRect
    var config: BorderConfig
}

struct DesiredBarSurface: Equatable {
    var monitor: Monitor
    var visible: Bool
    var snapshot: WorkspaceBarSnapshot
}

struct DesiredSurfaceScene: Equatable {
    var border: DesiredBorderSurface?
    var tabRails: [TabbedColumnOverlayInfo] = []
    var placeholders: [NativeFullscreenPlaceholderUpdate] = []
    var bars: [DesiredBarSurface] = []

    static let empty = DesiredSurfaceScene()
}

enum SurfaceDerivation {
    @MainActor
    static func derive(world: WorldView) -> DesiredSurfaceScene {
        guard world.hasStartedServices else { return .empty }
        return DesiredSurfaceScene(
            border: deriveBorder(world: world),
            tabRails: world.tabRailInfos(),
            placeholders: world.nativeFullscreenPlaceholders()
        )
    }

    @MainActor
    static func deriveBorder(world: WorldView) -> DesiredBorderSurface? {
        let config = world.borderConfig
        guard config.enabled else { return nil }
        guard let token = world.renderableFocusToken else { return nil }
        guard !world.isOwnedWindow(windowId: token.windowId) else { return nil }
        guard !world.hasPendingNativeFullscreenTransition else { return nil }
        guard world.systemModalFocusToken != token else { return nil }

        if let entry = world.entry(for: token) {
            guard world.suppressedFocusToken != token,
                  !world.isAppFullscreenActive,
                  !world.isWindowFullscreenInLayout(token),
                  world.isManagedWindowDisplayable(entry.token),
                  world.isWorkspaceVisible(entry.workspaceId)
            else {
                return nil
            }
            guard let frame = world.borderFrame(forWindowId: entry.windowId),
                  frame.width > 0, frame.height > 0
            else {
                return nil
            }
            return DesiredBorderSurface(windowId: entry.windowId, frame: frame, config: config)
        }

        guard world.isNonManagedFocusActive else { return nil }
        guard let frame = world.observedWindowBounds(windowId: token.windowId) else { return nil }
        return DesiredBorderSurface(windowId: token.windowId, frame: frame, config: config)
    }
}

@MainActor
final class SurfaceReconciler {
    private weak var controller: WMController?
    private var reconcileScheduled = false
    private var forceOrderingOnNextReconcile = false
    private let borderApplier = BorderSurfaceApplier()
    private(set) var appliedScene = DesiredSurfaceScene.empty

    init(controller: WMController) {
        self.controller = controller
    }

    func noteWorldChanged() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                self.flushScheduledReconcile()
            }
        }
        CFRunLoopWakeUp(mainRunLoop)
    }

    func noteRestackOccurred() {
        forceOrderingOnNextReconcile = true
        noteWorldChanged()
    }

    func reconcileNow() {
        runReconcile(deriveBars: true)
    }

    func reconcileAnimationTick() {
        runReconcile(deriveBars: false)
    }

    func cleanup() {
        borderApplier.cleanup()
        appliedScene = .empty
    }

    private func flushScheduledReconcile() {
        guard reconcileScheduled else { return }
        reconcileNow()
    }

    private func runReconcile(deriveBars: Bool) {
        reconcileScheduled = false
        let forceOrdering = forceOrderingOnNextReconcile
        forceOrderingOnNextReconcile = false
        guard let controller else { return }
        let world = WorldView(controller: controller)
        var desired = SurfaceDerivation.derive(world: world)
        desired.bars = deriveBars ? world.barSurfaces() : appliedScene.bars
        apply(desired, on: controller, forceOrdering: forceOrdering, applyBars: deriveBars)
    }

    private func apply(
        _ desired: DesiredSurfaceScene,
        on controller: WMController,
        forceOrdering: Bool,
        applyBars: Bool
    ) {
        if applyBars {
            controller.workspaceBarManager.apply(desired.bars)
            if desired.bars != appliedScene.bars {
                controller.publishWorkspaceDataChanged()
            }
        }
        guard desired != appliedScene || forceOrdering else { return }
        borderApplier.apply(desired.border, forceOrdering: forceOrdering)
        if desired.tabRails != appliedScene.tabRails || forceOrdering {
            controller.tabbedOverlayManager.updateOverlays(desired.tabRails, forceOrdering: forceOrdering)
        }
        if desired.placeholders != appliedScene.placeholders {
            controller.nativeFullscreenPlaceholderManager.apply(desired.placeholders)
        }
        appliedScene = desired
    }
}
