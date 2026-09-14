// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct FullRescanAppTarget: Sendable {
    let app: NSRunningApplication
    let route: FullRescanEnumerationRoute
    let inspectionContext: AXWindowInspectionContext
    let includedWindowIds: Set<Int>?
}

struct FullRescanDiscoveryEvidence {
    var pidsWithWindows: Set<pid_t>
    var windowServerInfoByWindowId: [Int: WindowServerInfo]
    var ownerPIDByWindowId: [Int: pid_t]
}

struct FullRescanCandidateCollection {
    var candidatesByWindowId: [Int: [FullRescanWindowCandidate]]
    var identityAliasesByWindowId: [Int: FullRescanWindowIdentityAliases]
    var failedPIDs: Set<pid_t>
}

struct FullRescanEnumerationCoverage {
    let targetPIDs: Set<pid_t>
    let dependencyPIDs: Set<pid_t>
    let targetPIDsByDependencyPID: [pid_t: Set<pid_t>]
    let unavailableTargetPIDs: Set<pid_t>
    let unavailableDependencyPIDs: Set<pid_t>
    let exactWindowIds: Set<Int>?
}

struct FullRescanEnumeration {
    let appTargets: [FullRescanAppTarget]
    let results: [FullRescanAppEnumerationResult]
    let coverage: FullRescanEnumerationCoverage
    let discoveryEvidence: FullRescanDiscoveryEvidence
}

struct AXManagedWindowRebindAcknowledgement {
    let oldPID: pid_t
    let oldContext: AppAXContext?
    let oldCallbackGeneration: UInt64?
    let destinationContext: AppAXContext
    let destinationCallbackGeneration: UInt64
    let destinationBinding: AppAXWindowRebindBinding
}

enum FullRescanCandidatePreferenceReason: String, Equatable, Sendable {
    case manageability = "manageability"
    case preservedLogicalPID = "preserved_logical_pid"
    case regularActivationPolicy = "regular_activation_policy"
    case axHostPID = "ax_host_pid"
    case windowServerOwnerPID = "window_server_owner_pid"
    case lowerPID = "lower_pid"
    case stableFirstCandidate = "stable_first_candidate"
}

struct FullRescanCandidatePreference: Equatable, Sendable {
    let prefersCandidate: Bool
    let reason: FullRescanCandidatePreferenceReason
}

struct FullRescanWindowIdentityAliases {
    var pids: Set<pid_t> = []
    var axRefs: [AXWindowRef] = []
}

extension FullRescanEnumeration {
    func snapshot(
        selected: [FullRescanWindowCandidate],
        collection: inout FullRescanCandidateCollection,
        successfullyEnumeratedPIDs: Set<pid_t>,
        authoritativeTargetPIDs: Set<pid_t>
    ) -> AXManager.FullRescanEnumerationSnapshot {
        let selectedWindowIds = Set(selected.map(\.windowId))
        collection.identityAliasesByWindowId = collection.identityAliasesByWindowId.filter {
            selectedWindowIds.contains($0.key)
        }
        let windowServerInfoByWindowId: [Int: WindowServerInfo]
        if let exactWindowIds = coverage.exactWindowIds {
            windowServerInfoByWindowId = discoveryEvidence.windowServerInfoByWindowId.filter {
                exactWindowIds.contains($0.key)
            }
        } else {
            windowServerInfoByWindowId = discoveryEvidence.windowServerInfoByWindowId
        }
        return .init(
            windows: selected,
            successfullyEnumeratedPIDs: successfullyEnumeratedPIDs,
            failedPIDs: collection.failedPIDs,
            authoritativeTargetPIDs: authoritativeTargetPIDs,
            exactWindowIds: coverage.exactWindowIds,
            identityAliasesByWindowId: collection.identityAliasesByWindowId,
            windowServerInfoByWindowId: windowServerInfoByWindowId
        )
    }
}
