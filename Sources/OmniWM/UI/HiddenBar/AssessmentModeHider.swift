// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMMenuBarAssertion

@MainActor
final class AssessmentModeHider {
    private static let systemItemNumbers: [NSNumber] =
        HiddenBarAllowlistResolver.allowedSystemItemIdentifiers.map { NSNumber(value: $0) }

    static var isAvailable: Bool {
        omniwm_assessment_available()
    }

    private(set) var available: Bool = AssessmentModeHider.isAvailable

    var onConcealingChanged: ((Bool) -> Void)?

    private static let retryBackoff: Duration = .seconds(3)

    private var handle: UnsafeMutableRawPointer?
    private var currentConfig: HiddenBarAppliedConfig?
    private var previousConfig: HiddenBarAppliedConfig?
    private var lastFailed: (allowed: Set<String>, at: ContinuousClock.Instant)?
    private(set) var activationGeneration = 0
    private var learnedNames: [String: String] = [:]
    private let clock = ContinuousClock()

    var isConcealing: Bool {
        handle != nil
    }

    func conceals(_ bundleID: String) -> Bool {
        Self.appliedConfig(currentConfig, conceals: bundleID)
    }

    nonisolated static func appliedConfig(_ config: HiddenBarAppliedConfig?, conceals bundleID: String) -> Bool {
        config?.concealed.contains(bundleID) == true
    }

    private var protectedBundleIDs: Set<String> {
        [Bundle.main.bundleIdentifier ?? "com.barut.OmniWM"]
    }

    @discardableResult
    func refreshAvailability() -> Bool {
        available = Self.isAvailable
        if !available {
            drop()
        }
        return available
    }

    @discardableResult
    func apply(
        hiddenBundleIDs: Set<String>,
        runningBundleIDs: Set<String>,
        bypassHysteresis: Bool = false
    ) -> Bool {
        guard available else { return false }

        let resolved = HiddenBarAllowlistResolver.resolve(
            hiddenBundleIDs: hiddenBundleIDs,
            runningBundleIDs: runningBundleIDs,
            protectedBundleIDs: protectedBundleIDs
        )

        guard !resolved.concealed.isEmpty else {
            drop()
            return false
        }

        let now = clock.now
        let desired = HiddenBarDesiredConfig(allowed: resolved.allowed, concealed: resolved.concealed)

        if !bypassHysteresis, !shouldActivate(desired: desired, now: now) {
            return handle != nil
        }

        return activate(desired: desired, now: now)
    }

    private func shouldActivate(desired: HiddenBarDesiredConfig, now: ContinuousClock.Instant) -> Bool {
        if let lastFailed, desired.allowed == lastFailed.allowed,
           lastFailed.at.duration(to: now) < Self.retryBackoff
        {
            return false
        }
        return HiddenBarAntiFlap.shouldReactivate(
            desired: desired,
            current: currentConfig,
            previousConfig: previousConfig,
            now: now
        )
    }

    private func activate(desired: HiddenBarDesiredConfig, now: ContinuousClock.Instant) -> Bool {
        let generation = activationGeneration + 1
        let attemptedAllowed = desired.allowed

        let newHandle = omniwm_assessment_activate(
            desired.allowed.sorted(),
            Self.systemItemNumbers,
            { [weak self] in
                Task { @MainActor in
                    self?.handleActivationFailure(generation: generation, attemptedAllowed: attemptedAllowed)
                }
            }
        )

        guard let newHandle else {
            lastFailed = (attemptedAllowed, now)
            return handle != nil
        }

        activationGeneration = generation
        let oldHandle = handle
        if let currentConfig {
            previousConfig = currentConfig
        }
        handle = newHandle
        if let oldHandle {
            omniwm_assessment_invalidate(oldHandle)
        }
        currentConfig = HiddenBarAppliedConfig(allowed: desired.allowed, concealed: desired.concealed, at: now)
        lastFailed = nil
        onConcealingChanged?(true)
        return true
    }

    func drop() {
        activationGeneration += 1
        let wasConcealing = handle != nil
        if let handle {
            omniwm_assessment_invalidate(handle)
        }
        handle = nil
        currentConfig = nil
        previousConfig = nil
        lastFailed = nil
        if wasConcealing {
            onConcealingChanged?(false)
        }
    }

    func learn(_ apps: [DetectedMenuBarApp]) {
        for app in apps {
            learnedNames[app.bundleID] = app.name
        }
    }

    func displayName(for bundleID: String) -> String? {
        learnedNames[bundleID]
    }

    private func handleActivationFailure(generation: Int, attemptedAllowed: Set<String>) {
        guard generation == activationGeneration else { return }
        let wasConcealing = handle != nil
        if let handle {
            omniwm_assessment_invalidate(handle)
        }
        handle = nil
        currentConfig = nil
        lastFailed = (attemptedAllowed, clock.now)
        if wasConcealing {
            onConcealingChanged?(false)
        }
    }

    isolated deinit {
        if let handle {
            omniwm_assessment_invalidate(handle)
        }
    }
}
