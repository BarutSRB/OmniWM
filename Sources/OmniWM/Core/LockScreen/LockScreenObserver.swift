import AppKit
import Foundation

@MainActor
final class LockScreenObserver {
    static let lockScreenAppBundleId = "com.apple.loginwindow"

    enum LockState {
        case unlocked
        case locked
        case transitioning
    }

    private(set) var state: LockState = .unlocked

    var onLockDetected: (() -> Void)?
    var onUnlockDetected: (() -> Void)?

    private var activationObserver: NSObjectProtocol?
    private var screenLockObserver: NSObjectProtocol?
    private var screenUnlockObserver: NSObjectProtocol?

    init() {}

    func start() {
        setupObservers()
    }

    func stop() {
        cleanup()
    }

    private func setupObservers() {
        let nc = NSWorkspace.shared.notificationCenter

        activationObserver = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let bundleId = app.bundleIdentifier
            Task { @MainActor in
                self?.handleAppActivation(bundleId: bundleId)
            }
        }

        let dnc = DistributedNotificationCenter.default()

        screenLockObserver = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleLockEvent()
            }
        }

        screenUnlockObserver = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleUnlockEvent()
            }
        }
    }

    private func handleAppActivation(bundleId: String?) {
        if bundleId == Self.lockScreenAppBundleId {
            handleLockEvent()
        } else if state == .locked || state == .transitioning {
            handleUnlockEvent()
        }
    }

    private func handleLockEvent() {
        guard state != .locked else { return }
        state = .locked
        onLockDetected?()
    }

    private func handleUnlockEvent() {
        guard state != .unlocked else { return }
        state = .transitioning
        onUnlockDetected?()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if self.state == .transitioning {
                self.state = .unlocked
            }
        }
    }

    func isFrontmostAppLockScreen() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.lockScreenAppBundleId
    }

    func cleanup() {
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activationObserver = nil
        }
        let dnc = DistributedNotificationCenter.default()
        if let observer = screenLockObserver {
            dnc.removeObserver(observer)
            screenLockObserver = nil
        }
        if let observer = screenUnlockObserver {
            dnc.removeObserver(observer)
            screenUnlockObserver = nil
        }
    }
}
