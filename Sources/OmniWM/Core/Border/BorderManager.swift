// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation

@MainActor
final class BorderManager {
    private var borderWindow: BorderWindow?
    private var config: BorderConfig
    private var lastAppliedFrame: CGRect?
    private var lastAppliedWindowId: Int?
    private var lastAppliedOrderingMetadata: BorderOrderingMetadata?






    private var registeredBorderWindowNumber: Int?
    private let surfaceCoordinator = SurfaceCoordinator.shared
    private let borderWindowFactory: @MainActor (BorderConfig) -> BorderWindow

    init(
        config: BorderConfig = BorderConfig(),
        borderWindowFactory: @escaping @MainActor (BorderConfig) -> BorderWindow = { BorderWindow(config: $0) }
    ) {
        self.config = config
        self.borderWindowFactory = borderWindowFactory
    }

    func setEnabled(_ enabled: Bool) {
        config.enabled = enabled
        if !enabled {
            hideBorder()
        }
    }

    func updateConfig(_ newConfig: BorderConfig) {
        let wasEnabled = config.enabled
        config = newConfig

        if !config.enabled, wasEnabled {
            hideBorder()
        } else if config.enabled {
            borderWindow?.updateConfig(config)
        }
    }

    func updateFocusedWindow(
        frame: CGRect,
        windowId: Int?,
        ordering: BorderOrderingMetadata? = nil
    ) {
        guard config.enabled else { return }
        guard frame.width > 0, frame.height > 0 else {
            hideBorder()
            return
        }

        if let last = lastAppliedFrame,
           let lastWid = lastAppliedWindowId,
           lastWid == windowId,
           lastAppliedOrderingMetadata == ordering,
           frame.approximatelyEqual(to: last, tolerance: 0.5) {
            return
        }

        if borderWindow == nil {
            borderWindow = borderWindowFactory(config)
        }

        guard let windowId else {
            borderWindow?.hide()
            lastAppliedFrame = nil
            lastAppliedWindowId = nil
            lastAppliedOrderingMetadata = nil
            return
        }

        let targetWid = UInt32(windowId)
        borderWindow?.update(frame: frame, targetWid: targetWid, ordering: ordering)
        lastAppliedFrame = frame
        lastAppliedWindowId = windowId
        lastAppliedOrderingMetadata = ordering
        syncSurfaceRegistration()
    }

    func hideBorder() {
        borderWindow?.hide()
        lastAppliedFrame = nil
        lastAppliedWindowId = nil
        lastAppliedOrderingMetadata = nil
        surfaceCoordinator.unregister(id: surfaceID)
        registeredBorderWindowNumber = nil
    }

    var lastAppliedFocusedWindowIdForTests: Int? {
        lastAppliedWindowId
    }

    var lastAppliedFocusedFrameForTests: CGRect? {
        lastAppliedFrame
    }

    func cleanup() {
        hideBorder()
        borderWindow?.destroy()
        borderWindow = nil
        surfaceCoordinator.unregister(id: surfaceID)
        registeredBorderWindowNumber = nil
    }

    private func syncSurfaceRegistration() {
        guard let borderWindow, let windowNumber = borderWindow.windowId.map(Int.init) else {
            if registeredBorderWindowNumber != nil {
                surfaceCoordinator.unregister(id: surfaceID)
                registeredBorderWindowNumber = nil
            }
            return
        }

        if registeredBorderWindowNumber == windowNumber { return }

        surfaceCoordinator.registerWindowNumber(
            id: surfaceID,
            windowNumber: windowNumber,
            frameProvider: { [weak self] in
                self?.lastAppliedFrame
            },
            visibilityProvider: { [weak self] in
                self?.lastAppliedFrame != nil && self?.config.enabled == true
            },
            policy: SurfacePolicy(
                kind: .border,
                hitTestPolicy: .passthrough,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        registeredBorderWindowNumber = windowNumber
    }

    private var surfaceID: String {
        "border-surface"
    }
}
