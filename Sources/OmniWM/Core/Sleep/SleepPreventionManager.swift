import AppKit
import IOKit.pwr_mgt

@MainActor
final class SleepPreventionManager {
    static let shared = SleepPreventionManager()

    private var sleepAssertionID: IOPMAssertionID?
    private var assertionTimer: Timer?
    private var isUserSessionActive = true

    private init() {
        setupWorkspaceNotifications()
    }

    func preventSleep() {
        assertionTimer?.invalidate()
        assertionTimer = Timer.scheduledTimer(
            withTimeInterval: 10.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSleepAssertion()
            }
        }
        assertionTimer?.fire()
    }

    func allowSleep() {
        assertionTimer?.invalidate()
        assertionTimer = nil
        releaseSleepAssertion()
    }

    private func refreshSleepAssertion() {
        guard isUserSessionActive else { return }

        if let assertionID = sleepAssertionID {
            IOPMAssertionRelease(assertionID)
        }

        var assertionID: IOPMAssertionID = 0
        let reason = "OmniWM prevents sleep" as CFString
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            reason,
            nil,
            nil,
            nil,
            8,
            nil,
            &assertionID
        )

        if result == kIOReturnSuccess {
            sleepAssertionID = assertionID
        }
    }

    private func releaseSleepAssertion() {
        if let assertionID = sleepAssertionID {
            IOPMAssertionRelease(assertionID)
            sleepAssertionID = nil
        }
    }

    private func setupWorkspaceNotifications() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        notificationCenter.addObserver(
            self,
            selector: #selector(sessionDidResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )

        notificationCenter.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func sessionDidResignActive() {
        isUserSessionActive = false
    }

    @objc private func sessionDidBecomeActive() {
        isUserSessionActive = true
    }
}
