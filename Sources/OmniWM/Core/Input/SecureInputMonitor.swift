import Carbon
import Foundation

@MainActor @Observable
final class SecureInputMonitor {
    private(set) var isSecureInputActive: Bool = false

    private var pollTimer: Timer?
    private var onStateChange: ((Bool) -> Void)?

    func start(onStateChange: @escaping (Bool) -> Void) {
        self.onStateChange = onStateChange
        startPolling()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkSecureInput()
            }
        }
        if let timer = pollTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        checkSecureInput()
    }

    private func checkSecureInput() {
        let newState = IsSecureEventInputEnabled()
        if newState != isSecureInputActive {
            isSecureInputActive = newState
            onStateChange?(newState)
        }
    }
}
