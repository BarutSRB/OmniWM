// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
import Foundation
import QuartzCore
import ScreenCaptureKit

@MainActor
final class OverviewInputSession {
    private let environment: OverviewEnvironment
    private var keyEventMonitor: Any?
    private var flagsEventMonitor: Any?
    private var applicationDidResignObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?
    private var inputHandler: OverviewInputHandler?
    private var onFlagsChanged: ((NSEvent.ModifierFlags) -> Void)?
    private var onResignActive: (() -> Void)?
    private var onDisplayChange: (() -> Void)?

    init(environment: OverviewEnvironment) {
        self.environment = environment
    }

    func start(
        inputHandler: OverviewInputHandler?,
        onFlagsChanged: @escaping (NSEvent.ModifierFlags) -> Void,
        onResignActive: @escaping () -> Void,
        onDisplayChange: @escaping () -> Void
    ) {
        self.inputHandler = inputHandler
        self.onFlagsChanged = onFlagsChanged
        self.onResignActive = onResignActive
        self.onDisplayChange = onDisplayChange
        installEventMonitors()
        installApplicationDidResignObserver()
        installScreenParametersObserver()
    }

    func stop() {
        removeEventMonitors()
        removeApplicationDidResignObserver()
        removeScreenParametersObserver()
        inputHandler = nil
        onFlagsChanged = nil
        onResignActive = nil
        onDisplayChange = nil
    }

    private func installEventMonitors() {
        removeEventMonitors()
        keyEventMonitor = environment.addLocalEventMonitor([.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.inputHandler?.handleKeyDown(event) == true ? nil : event
        }
        flagsEventMonitor = environment.addLocalEventMonitor([.flagsChanged]) { [weak self] event in
            self?.onFlagsChanged?(event.modifierFlags)
            return event
        }
    }

    private func removeEventMonitors() {
        if let keyEventMonitor {
            environment.removeEventMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
        if let flagsEventMonitor {
            environment.removeEventMonitor(flagsEventMonitor)
            self.flagsEventMonitor = nil
        }
    }

    private func installApplicationDidResignObserver() {
        removeApplicationDidResignObserver()
        applicationDidResignObserver = environment.notificationCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onResignActive?()
            }
        }
    }

    private func removeApplicationDidResignObserver() {
        if let applicationDidResignObserver {
            environment.notificationCenter.removeObserver(applicationDidResignObserver)
            self.applicationDidResignObserver = nil
        }
    }

    private func installScreenParametersObserver() {
        removeScreenParametersObserver()
        screenParametersObserver = environment.notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onDisplayChange?()
            }
        }
    }

    private func removeScreenParametersObserver() {
        if let screenParametersObserver {
            environment.notificationCenter.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
    }
}
