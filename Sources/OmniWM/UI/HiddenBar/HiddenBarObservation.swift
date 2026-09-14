// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

@MainActor
final class HiddenBarObservation {
    private enum ObserverEvent: Sendable {
        case didBecomeActive
        case runningApplicationChanged(bundleID: String?, terminated: Bool)
        case applicationActivated
        case screenParametersChanged
    }

    private var didBecomeActiveObserver: NSObjectProtocol?
    private var appLaunchObserver: NSObjectProtocol?
    private var appTerminationObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?
    private var topologyRefreshTask: Task<Void, Never>?
    private var topologyRefreshGeneration = 0
    private var observerGeneration = 0
    var topologyRefreshSleeper: @MainActor (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }

    var onTopologyRefreshForTests: (() -> Void)?
    private static let topologyRefreshDelay: Duration = .milliseconds(150)
    private weak var controller: HiddenBarController?

    func connect(controller: HiddenBarController) {
        self.controller = controller
    }

    func start() {
        if didBecomeActiveObserver == nil, appLaunchObserver == nil,
           appTerminationObserver == nil, screenParametersObserver == nil
        {
            observerGeneration &+= 1
        }
    }

    func install() {
        installDidBecomeActiveObserver(generation: observerGeneration)
        installRunningApplicationObservers(generation: observerGeneration)
        installApplicationActivationObserver(generation: observerGeneration)
        installScreenParametersObserver(generation: observerGeneration)
    }

    func invalidate() {
        observerGeneration &+= 1
        cancelTopologyRefresh()
    }

    func removeObservers() {
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
            self.didBecomeActiveObserver = nil
        }
        removeRunningApplicationObservers()
        removeScreenParametersObserver()
    }

    private func installDidBecomeActiveObserver(generation: Int) {
        guard didBecomeActiveObserver == nil else { return }
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.enqueueObserverEvent(.didBecomeActive, generation: generation)
        }
    }

    private func installRunningApplicationObservers(generation: Int) {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        if appLaunchObserver == nil {
            appLaunchObserver = notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = app?.bundleIdentifier
                self?.enqueueObserverEvent(
                    .runningApplicationChanged(bundleID: bundleID, terminated: false),
                    generation: generation
                )
            }
        }
        if appTerminationObserver == nil {
            appTerminationObserver = notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = app?.bundleIdentifier
                self?.enqueueObserverEvent(
                    .runningApplicationChanged(bundleID: bundleID, terminated: true),
                    generation: generation
                )
            }
        }
    }

    private func installApplicationActivationObserver(generation: Int) {
        guard appActivationObserver == nil else { return }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.enqueueObserverEvent(.applicationActivated, generation: generation)
        }
    }

    private func installScreenParametersObserver(generation: Int) {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.enqueueObserverEvent(.screenParametersChanged, generation: generation)
        }
    }

    private nonisolated func enqueueObserverEvent(_ event: ObserverEvent, generation: Int) {
        Task { @MainActor [weak self] in
            guard let self, generation == observerGeneration, let controller else { return }
            switch event {
            case .didBecomeActive:
                controller.refreshAvailabilityAndItems()
            case .applicationActivated:
                controller.refreshItems()
            case let .runningApplicationChanged(bundleID, terminated):
                controller.handleRunningApplicationChanged(bundleID: bundleID, terminated: terminated)
            case .screenParametersChanged:
                guard controller.isConcealing else { return }
                scheduleTopologyRefresh()
            }
        }
    }

    func enqueueDidBecomeActiveForTests() {
        enqueueObserverEvent(.didBecomeActive, generation: observerGeneration)
    }

    private func removeScreenParametersObserver() {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
    }

    func scheduleTopologyRefresh() {
        topologyRefreshTask?.cancel()
        topologyRefreshGeneration += 1
        let generation = topologyRefreshGeneration
        topologyRefreshTask = Task { @MainActor [weak self] in
            guard let self, let controller else { return }
            try? await topologyRefreshSleeper(Self.topologyRefreshDelay)
            guard !Task.isCancelled, generation == topologyRefreshGeneration else { return }
            topologyRefreshTask = nil
            onTopologyRefreshForTests?()
            controller.statusItems.syncFallbackIcon()
        }
    }

    func cancelTopologyRefresh() {
        topologyRefreshGeneration += 1
        topologyRefreshTask?.cancel()
        topologyRefreshTask = nil
    }

    private func removeRunningApplicationObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        if let appLaunchObserver {
            notificationCenter.removeObserver(appLaunchObserver)
            self.appLaunchObserver = nil
        }
        if let appTerminationObserver {
            notificationCenter.removeObserver(appTerminationObserver)
            self.appTerminationObserver = nil
        }
        if let appActivationObserver {
            notificationCenter.removeObserver(appActivationObserver)
            self.appActivationObserver = nil
        }
    }

    var hasPendingTopologyRefreshForTests: Bool {
        topologyRefreshTask != nil
    }

    var hasScreenParametersObserverForTests: Bool {
        screenParametersObserver != nil
    }
}
