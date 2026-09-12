// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@preconcurrency import AppKit
import Carbon
import Foundation
import IOKit.hidsystem

extension HotkeyCenter {
    nonisolated static func bindingFacts(for bindings: [HotkeyBinding]) -> [HotkeyBindingFact] {
        let failures = registrationPlan(for: bindings).failures
        return bindings.compactMap { binding in
            guard case let .chord(chord) = binding.binding, !chord.isUnassigned else { return nil }
            let route: String
            if let reason = failures[binding.command] {
                route = "unregistered(\(reason))"
            } else if chord.sidedModifiers.isEmpty {
                route = "carbon"
            } else {
                route = "sided"
            }
            return HotkeyBindingFact(command: binding.command.displayName, display: chord.displayString, route: route)
        }
    }

    static func decisionLabel(_ decision: HyperTriggerStateMachine.Decision) -> String {
        switch decision {
        case .suppress: "suppress"
        case .passThrough: "passThrough"
        case .inject: "inject"
        case .toggleCapsLock: "toggleCapsLock"
        }
    }

    nonisolated static func inputMonitoringAccessGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @discardableResult
    nonisolated static func requestInputMonitoringAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    nonisolated static func registrationPlan(for bindings: [HotkeyBinding]) -> HotkeyRegistrationPlan {
        var candidates: [(command: HotkeyCommand, binding: KeyBinding)] = []
        for binding in bindings {
            guard case let .chord(keyBinding) = binding.binding, !keyBinding.isUnassigned else { continue }
            candidates.append((binding.command, keyBinding))
        }

        var failures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [:]
        for index in candidates.indices {
            let overlaps = candidates.indices.contains { other in
                other != index && candidates[index].binding.conflicts(with: candidates[other].binding)
            }
            if overlaps {
                failures[candidates[index].command] = .duplicateBinding
            }
        }

        let registrable = candidates.filter { failures[$0.command] == nil }
        let registrations = registrable
            .filter { $0.binding.sidedModifiers.isEmpty }
            .map { HotkeyPlannedRegistration(binding: $0.binding, command: $0.command) }
        let sideSpecific = registrable
            .filter { !$0.binding.sidedModifiers.isEmpty }
            .map { HotkeyPlannedRegistration(binding: $0.binding, command: $0.command) }

        return HotkeyRegistrationPlan(
            registrations: registrations,
            sideSpecificRegistrations: sideSpecific,
            failures: failures
        )
    }
}
