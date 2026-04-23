// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation

struct FrontmostSnapshot: Equatable, Sendable {
    let pid: pid_t
    let bundleIdentifier: String?
    let isLockScreen: Bool

    init(pid: pid_t, bundleIdentifier: String?) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        isLockScreen = bundleIdentifier == LockScreenObserver.lockScreenAppBundleId
    }

    init(application: NSRunningApplication) {
        self.init(
            pid: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier
        )
    }
}

@MainActor
final class FrontmostApplicationState {
    static let shared = FrontmostApplicationState()

    private let applicationProvider: () -> NSRunningApplication?
    private(set) var snapshot: FrontmostSnapshot?

    init(
        applicationProvider: @escaping @MainActor () -> NSRunningApplication? = {
            NSWorkspace.shared.frontmostApplication
        }
    ) {
        self.applicationProvider = applicationProvider
        snapshot = Self.makeSnapshot(from: applicationProvider())
    }

    var runningApplication: NSRunningApplication? {
        guard let snapshot else { return nil }
        return NSRunningApplication(processIdentifier: snapshot.pid)
    }

    func primeFromWorkspace() {
        snapshot = Self.makeSnapshot(from: applicationProvider())
    }

    @discardableResult
    func update(from notification: Notification) -> FrontmostSnapshot? {
        guard let application = Self.application(from: notification) else {
            return snapshot
        }

        return update(
            pid: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier
        )
    }

    @discardableResult
    func update(pid: pid_t, bundleIdentifier: String?) -> FrontmostSnapshot {
        let snapshot = FrontmostSnapshot(pid: pid, bundleIdentifier: bundleIdentifier)
        self.snapshot = snapshot
        return snapshot
    }

    @discardableResult
    func clearIfNeeded(from notification: Notification) -> Bool {
        guard let application = Self.application(from: notification) else {
            return false
        }

        return clearIfNeeded(terminatedPid: application.processIdentifier)
    }

    @discardableResult
    func clearIfNeeded(terminatedPid: pid_t) -> Bool {
        guard snapshot?.pid == terminatedPid else { return false }
        snapshot = nil
        return true
    }

    func setSnapshotForTests(_ snapshot: FrontmostSnapshot?) {
        self.snapshot = snapshot
    }

    private static func application(from notification: Notification) -> NSRunningApplication? {
        notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    private static func makeSnapshot(from application: NSRunningApplication?) -> FrontmostSnapshot? {
        application.map(FrontmostSnapshot.init(application:))
    }
}
