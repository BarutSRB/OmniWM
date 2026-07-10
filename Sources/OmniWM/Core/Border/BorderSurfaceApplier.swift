// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
final class BorderSurfaceApplier {
    private var borderWindow: BorderWindow?
    private var applied: DesiredBorderSurface?
    private var appliedCornerRadius: CGFloat?
    private var cachedCornerRadiusWindowId: Int?
    private var cachedCornerRadius: CGFloat?
    private let borderWindowOperations: BorderWindow.Operations
    private let cornerRadiusProvider: @MainActor (Int) -> CGFloat?
    private let surfaceCoordinator = SurfaceCoordinator.shared
    private var registeredSurfaceWindowNumber: Int?
    private let defaultCornerRadius: CGFloat = 9.0
    private let surfaceID = "border-surface"
    private var screenParametersObserver: NSObjectProtocol?

    init(
        borderWindowOperations: BorderWindow.Operations = .live,
        cornerRadiusProvider: @escaping @MainActor (Int) -> CGFloat? = {
            SkyLight.shared.cornerRadius(forWindowId: $0)
        }
    ) {
        self.borderWindowOperations = borderWindowOperations
        self.cornerRadiusProvider = cornerRadiusProvider
        installScreenParametersObserverIfNeeded()
    }

    private func installScreenParametersObserverIfNeeded() {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.borderWindow?.invalidateScaleCache()
            }
        }
    }

    @discardableResult
    func apply(_ desired: DesiredBorderSurface?, forceOrdering: Bool) -> Bool {
        guard let desired else {
            hide()
            return true
        }

        installScreenParametersObserverIfNeeded()
        BorderOpMetricsRecorder.shared.noteApply()

        if borderWindow == nil {
            borderWindow = BorderWindow(config: desired.config, operations: borderWindowOperations)
        } else {
            borderWindow?.updateConfig(desired.config)
        }

        if let applied,
           applied.windowId == desired.windowId,
           abs(applied.frame.width - desired.frame.width) > FrameTolerance.frameWrite
           || abs(applied.frame.height - desired.frame.height) > FrameTolerance.frameWrite
        {
            clearCornerRadiusCache()
        }

        let cornerRadius = resolvedCornerRadius(for: desired.windowId)
        if let applied,
           applied.windowId == desired.windowId,
           applied.config == desired.config,
           appliedCornerRadius == cornerRadius,
           desired.frame.approximatelyEqual(to: applied.frame, tolerance: FrameTolerance.frameWrite)
        {
            BorderOpMetricsRecorder.shared.noteShortCircuit()
            if forceOrdering {
                borderWindow?.reorder(relativeTo: UInt32(desired.windowId))
            }
            return true
        }

        guard borderWindow?.update(
            frame: desired.frame,
            targetWid: UInt32(desired.windowId),
            cornerRadius: cornerRadius,
            forceOrdering: forceOrdering
        ) == true else {
            applied = nil
            appliedCornerRadius = nil
            clearCornerRadiusCache()
            return false
        }
        applied = desired
        appliedCornerRadius = cornerRadius
        syncSurfaceRegistration()
        return true
    }

    func cleanup() {
        hide()
        borderWindow?.destroy()
        borderWindow = nil
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
    }

    private func hide() {
        guard applied != nil || registeredSurfaceWindowNumber != nil else { return }
        borderWindow?.hide()
        applied = nil
        appliedCornerRadius = nil
        clearCornerRadiusCache()
        surfaceCoordinator.unregister(id: surfaceID)
        registeredSurfaceWindowNumber = nil
    }

    private func resolvedCornerRadius(for windowId: Int) -> CGFloat {
        if cachedCornerRadiusWindowId == windowId, let cachedCornerRadius {
            BorderOpMetricsRecorder.shared.noteCornerRadiusHit()
            return cachedCornerRadius
        }

        BorderOpMetricsRecorder.shared.noteCornerRadiusQuery()
        let providedCornerRadius = cornerRadiusProvider(windowId)
        if providedCornerRadius == nil {
            FallbackFiringRecorder.shared.note(.skylight, "cornerRadiusDefault")
        }
        let cornerRadius = max(providedCornerRadius ?? defaultCornerRadius, 0)
        cachedCornerRadiusWindowId = windowId
        cachedCornerRadius = cornerRadius
        return cornerRadius
    }

    private func clearCornerRadiusCache() {
        cachedCornerRadiusWindowId = nil
        cachedCornerRadius = nil
    }

    private func syncSurfaceRegistration() {
        guard let borderWindow, let windowNumber = borderWindow.windowId.map(Int.init) else {
            surfaceCoordinator.unregister(id: surfaceID)
            registeredSurfaceWindowNumber = nil
            return
        }
        guard registeredSurfaceWindowNumber != windowNumber else { return }

        surfaceCoordinator.registerWindowNumber(
            id: surfaceID,
            windowNumber: windowNumber,
            frameProvider: { [weak self] in
                self?.borderWindow?.frameOnScreen ?? self?.applied?.frame
            },
            visibilityProvider: { [weak self] in
                self?.applied != nil
            },
            policy: SurfacePolicy(
                kind: .border,
                hitTestPolicy: .passthrough,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        registeredSurfaceWindowNumber = windowNumber
    }
}
