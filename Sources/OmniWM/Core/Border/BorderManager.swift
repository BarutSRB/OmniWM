import AppKit
import Foundation

@MainActor
final class BorderManager {
    private var borderWindow: BorderWindow?
    private var config: BorderConfig
    private var lastAppliedFrame: CGRect?
    private var lastAppliedWindowId: Int?
    private let borderWindowOperations: BorderWindow.Operations
    private let surfaceCoordinator = SurfaceCoordinator.shared

    init(
        config: BorderConfig = BorderConfig(),
        borderWindowOperations: BorderWindow.Operations = .live
    ) {
        self.config = config
        self.borderWindowOperations = borderWindowOperations
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
        forceOrdering: Bool = false
    ) {
        guard config.enabled else { return }
        guard frame.width > 0, frame.height > 0 else {
            hideBorder()
            return
        }

        if borderWindow == nil {
            borderWindow = BorderWindow(config: config, operations: borderWindowOperations)
        }

        guard let windowId else {
            borderWindow?.hide()
            lastAppliedFrame = nil
            lastAppliedWindowId = nil
            return
        }

        let targetWid = UInt32(windowId)
        if let last = lastAppliedFrame,
           let lastWid = lastAppliedWindowId,
           frame.approximatelyEqual(to: last, tolerance: 0.5)
        {
            if forceOrdering || lastWid != windowId {
                borderWindow?.reorder(relativeTo: targetWid)
                lastAppliedWindowId = windowId
                syncSurfaceRegistration()
            }
            return
        }

        borderWindow?.update(frame: frame, targetWid: targetWid, forceOrdering: forceOrdering)
        lastAppliedFrame = frame
        lastAppliedWindowId = windowId
        syncSurfaceRegistration()
    }

    func hideBorder() {
        borderWindow?.hide()
        lastAppliedFrame = nil
        lastAppliedWindowId = nil
        surfaceCoordinator.unregister(id: surfaceID)
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
    }

    private func syncSurfaceRegistration() {
        guard let borderWindow, let windowNumber = borderWindow.windowId.map(Int.init) else {
            surfaceCoordinator.unregister(id: surfaceID)
            return
        }

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
    }

    private var surfaceID: String {
        "border-surface"
    }
}
