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

    init(
        borderWindowOperations: BorderWindow.Operations = .live,
        cornerRadiusProvider: @escaping @MainActor (Int) -> CGFloat? = { SkyLight.shared.cornerRadius(forWindowId: $0) }
    ) {
        self.borderWindowOperations = borderWindowOperations
        self.cornerRadiusProvider = cornerRadiusProvider
    }

    func apply(_ desired: DesiredBorderSurface?, forceOrdering: Bool) {
        guard let desired else {
            hide()
            return
        }

        if borderWindow == nil {
            borderWindow = BorderWindow(config: desired.config, operations: borderWindowOperations)
        } else if let applied, applied.config != desired.config {
            borderWindow?.updateConfig(desired.config)
        }

        let cornerRadius = resolvedCornerRadius(for: desired.windowId)
        if let applied,
           applied.windowId == desired.windowId,
           applied.config == desired.config,
           appliedCornerRadius == cornerRadius,
           desired.frame.approximatelyEqual(to: applied.frame, tolerance: FrameTolerance.frameWrite)
        {
            if forceOrdering {
                borderWindow?.reorder(relativeTo: UInt32(desired.windowId))
            }
            return
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
            return
        }
        applied = desired
        appliedCornerRadius = cornerRadius
        syncSurfaceRegistration()
    }

    func cleanup() {
        hide()
        borderWindow?.destroy()
        borderWindow = nil
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
            return cachedCornerRadius
        }

        let cornerRadius = max(cornerRadiusProvider(windowId) ?? defaultCornerRadius, 0)
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
                self?.applied?.frame
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
