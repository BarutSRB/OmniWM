// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
struct WorkspaceEventObservation {
    private var activeDisplayObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var appDeactivationObserver: NSObjectProtocol?
    private var appHideObserver: NSObjectProtocol?
    private var appUnhideObserver: NSObjectProtocol?
    private var workspaceObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    mutating func setupWorkspaceObservation() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            EventIntake.post(.activeSpaceChanged)
        }
        activeDisplayObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: Notification.Name("NSWorkspaceActiveDisplayDidChangeNotification"),
            object: nil,
            queue: .main
        ) { _ in
            EventIntake.post(.activeSpaceChanged)
        }
    }

    mutating func setupAppActivationObserver() {
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            EventIntake.post(.application(.activated(pid: app.processIdentifier)))
        }
    }

    mutating func setupAppDeactivationObserver() {
        appDeactivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            EventIntake.post(.application(.deactivated(pid: app.processIdentifier)))
        }
    }

    mutating func setupAppHideObservers() {
        appHideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            Self.postVisibilityNotification(notification, hidden: true)
        }
        appUnhideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            Self.postVisibilityNotification(notification, hidden: false)
        }
    }

    private nonisolated static func postVisibilityNotification(_ notification: Notification, hidden: Bool) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        DiagnosticsEventRecorder.shared.recordLifecycle(
            name: hidden ? "workspace.appHidden" : "workspace.appUnhidden",
            pid: app.processIdentifier
        )
        AppVisibilityTrace.record(
            .notification,
            pid: app.processIdentifier,
            visibility: hidden ? .hidden : .visible,
            outcome: .observed,
            source: .service
        )
        let didEnqueue = EventIntake
            .post(hidden ? .application(.hidden(pid: app.processIdentifier)) :
                .application(.unhidden(pid: app.processIdentifier)))
        AppVisibilityTrace.record(
            .intake,
            pid: app.processIdentifier,
            visibility: hidden ? .hidden : .visible,
            outcome: didEnqueue ? .enqueued : .dropped,
            reason: didEnqueue ? nil : .intakeClosed,
            source: .service
        )
    }

    mutating func setupSleepWakeObservation() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            EventIntake.post(.systemSleep)
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            EventIntake.post(.systemWake)
        }
    }

    mutating func stop() {
        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appActivationObserver = nil
        }
        if let observer = appDeactivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appDeactivationObserver = nil
        }
        if let observer = appHideObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appHideObserver = nil
        }
        if let observer = appUnhideObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appUnhideObserver = nil
        }
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
        if let observer = activeDisplayObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activeDisplayObserver = nil
        }
        if let observer = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            sleepObserver = nil
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
    }
}
