// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation

@MainActor
final class LockScreenObserver {
    nonisolated static let lockScreenAppBundleId = "com.apple.loginwindow"

    enum LockState {
        case unlocked
        case locked
        case transitioning
    }

    private(set) var state: LockState = .unlocked

    var onLockDetected: (() -> Void)?
    var onUnlockDetected: (() -> Void)?
    var frontmostSnapshotProvider: @MainActor () -> FrontmostSnapshot? = {
        FrontmostApplicationState.shared.snapshot
    }

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

    func syncWithFrontmostApplicationState() {
        handleFrontmostApplicationDidActivate(bundleId: frontmostSnapshotProvider()?.bundleIdentifier)
    }

    func handleFrontmostApplicationDidActivate(bundleId: String?) {
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
        frontmostSnapshotProvider()?.isLockScreen == true
    }

    func cleanup() {
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
