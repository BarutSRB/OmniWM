import AppKit
import Foundation

@MainActor
final class BorderManager {
    private var borderWindow: BorderWindow?
    private var config: BorderConfig
    private var lastFrame: CGRect = .zero
    private var currentWindowId: Int?

    private var pendingUpdate: Task<Void, Never>?
    private var lastUpdateTime: Date = .distantPast
    private let debounceInterval: TimeInterval = 0.016

    init(config: BorderConfig = BorderConfig()) {
        self.config = config
    }

    func setEnabled(_ enabled: Bool) {
        config.enabled = enabled
        if enabled {
        } else {
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

    func updateFocusedWindow(frame: CGRect, windowId: Int?) {
        guard config.enabled else { return }
        guard frame.width > 0, frame.height > 0 else {
            hideBorder()
            return
        }

        currentWindowId = windowId

        if lastFrame.equalTo(frame, tolerance: 0.5) {
            return
        }

        pendingUpdate?.cancel()

        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastUpdateTime)

        if timeSinceLastUpdate >= debounceInterval {
            performUpdate(frame: frame)
        } else {
            let delay = debounceInterval - timeSinceLastUpdate
            pendingUpdate = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.performUpdate(frame: frame)
            }
        }
    }

    func hideBorder() {
        pendingUpdate?.cancel()
        pendingUpdate = nil
        borderWindow?.orderOut(nil)
        lastFrame = .zero
    }

    func cleanup() {
        hideBorder()
        borderWindow?.close()
        borderWindow = nil
    }

    private func performUpdate(frame: CGRect) {
        lastUpdateTime = Date()
        lastFrame = frame

        if borderWindow == nil {
            borderWindow = BorderWindow(config: config)
        }

        let cornerRadius = currentWindowId.flatMap { SkyLight.shared.cornerRadius(forWindowId: $0) } ?? 9
        let targetWid = currentWindowId.map { UInt32($0) }

        borderWindow?.orderFront(nil)
        borderWindow?.update(
            frame: frame,
            cornerRadius: cornerRadius,
            config: config,
            targetWid: targetWid
        )
    }
}

private extension CGRect {
    func equalTo(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(origin.x - other.origin.x) < tolerance &&
            abs(origin.y - other.origin.y) < tolerance &&
            abs(size.width - other.size.width) < tolerance &&
            abs(size.height - other.size.height) < tolerance
    }
}
