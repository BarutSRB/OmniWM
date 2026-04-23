// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation
import Testing

@testable import OmniWM

@Suite(.serialized) @MainActor struct FrontmostApplicationStateTests {
    @Test func activationAndTerminationNotificationsDriveSnapshotAndMetrics() throws {
        guard let app = NSRunningApplication(processIdentifier: ProcessInfo.processInfo.processIdentifier) else {
            Issue.record("Missing running application for frontmost-state test")
            return
        }

        let state = FrontmostApplicationState(applicationProvider: { nil })

        let activation = Notification(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: app]
        )
        let termination = Notification(
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: app]
        )

        #expect(state.snapshot == nil)

        let activationSnapshot = try #require(state.update(from: activation))
        #expect(activationSnapshot.pid == app.processIdentifier)
        #expect(activationSnapshot.bundleIdentifier == app.bundleIdentifier)
        #expect(activationSnapshot.isLockScreen == false)

        #expect(state.clearIfNeeded(from: termination) == true)
        #expect(state.snapshot == nil)
    }

    @Test func primeFromWorkspaceUsesInjectedProvider() throws {
        guard let app = NSRunningApplication(processIdentifier: ProcessInfo.processInfo.processIdentifier) else {
            Issue.record("Missing running application for frontmost-state prime test")
            return
        }

        let state = FrontmostApplicationState(applicationProvider: { app })
        state.setSnapshotForTests(nil)

        state.primeFromWorkspace()

        let snapshot = try #require(state.snapshot)
        #expect(snapshot.pid == app.processIdentifier)
        #expect(snapshot.bundleIdentifier == app.bundleIdentifier)
    }
}
