// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension AXManager {
    func fullRescanEnumerationSnapshot(
        scope: RescanScope = .all,
        resolvedTargetPIDs: Set<pid_t> = [],
        resolvedTargetWindowIds: Set<Int> = [],
        supplementalWindowServerInfoByWindowId: [Int: WindowServerInfo] = [:],
        preservingPIDsByWindowId: [Int: pid_t] = [:],
        identityDependencyPIDsByWindowId: [Int: Set<pid_t>] = [:],
        requiresTitleForApp: (String?, String?) -> Bool = { _, _ in false }
    ) async throws -> FullRescanEnumerationSnapshot {
        try Task.checkCancellation()
        garbageCollectContexts()
        let enumeration: FullRescanEnumeration
        switch scope {
        case .all:
            enumeration = try await fullRescanEnumeration(
                preservingPIDsByWindowId: preservingPIDsByWindowId,
                requiresTitleForApp: requiresTitleForApp
            )
        case .targeted:
            enumeration = try await targetedFullRescanEnumeration(
                inputs: FullRescanTargetInputs(
                    scope: scope,
                    resolvedTargetPIDs: resolvedTargetPIDs,
                    resolvedTargetWindowIds: resolvedTargetWindowIds,
                    preservingPIDsByWindowId: preservingPIDsByWindowId,
                    identityDependencyPIDsByWindowId: identityDependencyPIDsByWindowId
                ),
                discoveryEvidence: targetedFullRescanDiscoveryEvidence(supplementalWindowServerInfoByWindowId),
                requiresTitleForApp: requiresTitleForApp
            )
        }
        return try await finalizeFullRescanSnapshot(enumeration, preservingPIDsByWindowId: preservingPIDsByWindowId)
    }

    private func fullRescanEnumeration(
        preservingPIDsByWindowId: [Int: pid_t],
        requiresTitleForApp: (String?, String?) -> Bool
    ) async throws -> FullRescanEnumeration {
        var discoveryEvidence = fullRescanDiscoveryEvidence()
        _ = try await mergeFullRescanWindowServerEvidence(
            windowIds: Set(preservingPIDsByWindowId.keys),
            expectedPIDsByWindowId: preservingPIDsByWindowId,
            into: &discoveryEvidence
        )
        let runningApplications = NSWorkspace.shared.runningApplications
        let appTargets = fullRescanAppTargets(
            runningApplications,
            selection: FullRescanAppTargetSelection(
                discoveryEvidence: discoveryEvidence,
                preservingPIDsByWindowId: preservingPIDsByWindowId,
                persistentEvidencePIDs: [],
                includedPIDs: nil,
                allowsEvidenceFreeOneShot: false
            ),
            requiresTitleForApp: requiresTitleForApp
        )
        let enumerationResults = try await enumerateFullRescanApps(appTargets)
        let coverage = FullRescanEnumerationCoverage(
            targetPIDs: Set(appTargets.map { $0.app.processIdentifier }),
            dependencyPIDs: [],
            targetPIDsByDependencyPID: [:],
            unavailableTargetPIDs: [],
            unavailableDependencyPIDs: [],
            exactWindowIds: nil
        )
        return FullRescanEnumeration(
            appTargets: appTargets,
            results: enumerationResults,
            coverage: coverage,
            discoveryEvidence: discoveryEvidence
        )
    }

    func targetedFullRescanEnumeration(
        inputs: FullRescanTargetInputs,
        discoveryEvidence initialDiscoveryEvidence: FullRescanDiscoveryEvidence,
        requiresTitleForApp: (String?, String?) -> Bool
    ) async throws -> FullRescanEnumeration {
        var discoveryEvidence = initialDiscoveryEvidence
        let targetedAppPIDs = inputs.scope.appPIDs
        let nativeSpaceWindowIds = inputs.scope.nativeSpaceWindowIds
        let preservedTargetWindowIds = Set(
            inputs.preservingPIDsByWindowId.compactMap { windowId, pid in
                targetedAppPIDs.contains(pid) || nativeSpaceWindowIds.contains(windowId)
                    ? windowId
                    : nil
            }
        )
        let windowServerEvidenceSucceeded = try await mergeFullRescanWindowServerEvidence(
            windowIds: preservedTargetWindowIds,
            into: &discoveryEvidence
        )
        guard let resolution = FullRescanTargetResolution.fullRescanTargetResolution(
            inputs,
            ownerPIDByWindowId: discoveryEvidence.ownerPIDByWindowId
        ) else {
            return .empty(discoveryEvidence: discoveryEvidence)
        }

        var traversal = TargetedFullRescanTraversal(
            inputs: inputs,
            resolution: resolution,
            discoveryEvidence: discoveryEvidence,
            windowServerEvidenceSucceeded: windowServerEvidenceSucceeded,
            persistentEvidencePIDs: Set(inputs.preservingPIDsByWindowId.values)
                .union(inputs.identityDependencyPIDsByWindowId.values.joined())
        )
        try await traversal.enumerateTargets(manager: self, requiresTitleForApp: requiresTitleForApp)
        try await traversal.enumerateDependencies(manager: self, requiresTitleForApp: requiresTitleForApp)
        return traversal.finish()
    }
}

@MainActor
private struct TargetedFullRescanTraversal {
    let inputs: FullRescanTargetInputs
    var resolution: FullRescanTargetResolution
    var discoveryEvidence: FullRescanDiscoveryEvidence
    var windowServerEvidenceSucceeded: Bool
    var appTargets: [FullRescanAppTarget] = []
    var attemptedPIDs: Set<pid_t> = []
    var unavailableTargetPIDs: Set<pid_t> = []
    var unavailableDependencyPIDs: Set<pid_t> = []
    var results: [FullRescanAppEnumerationResult] = []

    let persistentEvidencePIDs: Set<pid_t>

    mutating func enumerateTargets(manager: AXManager, requiresTitleForApp: (String?, String?) -> Bool) async throws {
        let targetInspectionWindowIdsByPID = targetInspectionWindowIds()
        let targetAppTargets = manager.fullRescanAppTargets(
            manager.fullRescanRunningApplications(for: resolution.targetPIDs),
            selection: FullRescanAppTargetSelection(
                discoveryEvidence: discoveryEvidence,
                preservingPIDsByWindowId: inputs.preservingPIDsByWindowId,
                persistentEvidencePIDs: persistentEvidencePIDs,
                includedPIDs: resolution.targetPIDs,
                includedWindowIdsByPID: targetInspectionWindowIdsByPID,
                allowsEvidenceFreeOneShot: true
            ),
            requiresTitleForApp: requiresTitleForApp
        )
        appTargets = targetAppTargets
        attemptedPIDs = Set(targetAppTargets.map { $0.app.processIdentifier })
        unavailableTargetPIDs = resolution.targetPIDs.subtracting(attemptedPIDs)
        results = try await manager.enumerateFullRescanApps(targetAppTargets).map { result in
            let windows = resolution.explicitAppPIDs.contains(result.pid)
                ? result.windows
                : result.windows.filter {
                    resolution.resolvedTargetWindowIds.contains($0.axRef.windowId)
                }
            return FullRescanAppEnumerationResult(
                pid: result.pid,
                route: result.route,
                windows: windows,
                failed: result.failed,
                callbackGeneration: result.callbackGeneration
            )
        }
        if try await !manager.mergeFullRescanWindowServerEvidence(
            for: results,
            into: &discoveryEvidence
        ) {
            windowServerEvidenceSucceeded = false
        }
        FullRescanTargetResolution.includeFullRescanTargetWindows(
            results,
            in: &resolution,
            preservingPIDsByWindowId: inputs.preservingPIDsByWindowId,
            ownerPIDByWindowId: discoveryEvidence.ownerPIDByWindowId,
            identityDependencyPIDsByWindowId: inputs.identityDependencyPIDsByWindowId
        )
    }

    mutating func enumerateDependencies(
        manager: AXManager,
        requiresTitleForApp: (String?, String?) -> Bool
    ) async throws {
        while true {
            try Task.checkCancellation()
            let pendingDependencyPIDs = resolution.dependencyPIDs.subtracting(attemptedPIDs)
            guard !pendingDependencyPIDs.isEmpty else { break }
            attemptedPIDs.formUnion(pendingDependencyPIDs)
            let dependencyTargets = dependencyTargets(
                for: pendingDependencyPIDs,
                manager: manager,
                requiresTitleForApp: requiresTitleForApp
            )
            let dependencyTargetPIDs = Set(dependencyTargets.map { $0.app.processIdentifier })
            unavailableDependencyPIDs.formUnion(
                pendingDependencyPIDs.subtracting(dependencyTargetPIDs)
            )
            appTargets.append(contentsOf: dependencyTargets)
            let dependencyResults = try await manager.enumerateFullRescanApps(dependencyTargets).map { result in
                FullRescanAppEnumerationResult(
                    pid: result.pid,
                    route: result.route,
                    windows: result.windows.filter {
                        resolution.relevantWindowIds.contains($0.axRef.windowId)
                    },
                    failed: result.failed,
                    callbackGeneration: result.callbackGeneration
                )
            }
            if try await !manager.mergeFullRescanWindowServerEvidence(
                for: dependencyResults,
                into: &discoveryEvidence
            ) {
                windowServerEvidenceSucceeded = false
            }
            results.append(contentsOf: dependencyResults)
            FullRescanTargetResolution.includeFullRescanDependencyWindows(
                dependencyResults,
                in: &resolution,
                preservingPIDsByWindowId: inputs.preservingPIDsByWindowId,
                ownerPIDByWindowId: discoveryEvidence.ownerPIDByWindowId,
                identityDependencyPIDsByWindowId: inputs.identityDependencyPIDsByWindowId
            )
        }
    }

    mutating func finish() -> FullRescanEnumeration {
        if !windowServerEvidenceSucceeded {
            unavailableTargetPIDs.formUnion(resolution.targetPIDs)
        }

        return FullRescanEnumeration(
            appTargets: appTargets,
            results: results,
            coverage: FullRescanEnumerationCoverage(
                targetPIDs: resolution.targetPIDs,
                dependencyPIDs: resolution.dependencyPIDs,
                targetPIDsByDependencyPID: resolution.targetPIDsByDependencyPID,
                unavailableTargetPIDs: unavailableTargetPIDs,
                unavailableDependencyPIDs: unavailableDependencyPIDs,
                exactWindowIds: resolution.relevantWindowIds
            ),
            discoveryEvidence: discoveryEvidence
        )
    }

    private func dependencyTargets(
        for pendingDependencyPIDs: Set<pid_t>,
        manager: AXManager,
        requiresTitleForApp: (String?, String?) -> Bool
    ) -> [FullRescanAppTarget] {
        return manager.fullRescanAppTargets(
            manager.fullRescanRunningApplications(for: pendingDependencyPIDs),
            selection: FullRescanAppTargetSelection(
                discoveryEvidence: discoveryEvidence,
                preservingPIDsByWindowId: inputs.preservingPIDsByWindowId,
                persistentEvidencePIDs: persistentEvidencePIDs
                    .union(pendingDependencyPIDs),
                includedPIDs: pendingDependencyPIDs,
                includedWindowIdsByPID: Dictionary(
                    uniqueKeysWithValues: pendingDependencyPIDs.map {
                        ($0, resolution.relevantWindowIds)
                    }
                ),
                allowsEvidenceFreeOneShot: true
            ),
            requiresTitleForApp: requiresTitleForApp
        )
    }

    private func targetInspectionWindowIds() -> [pid_t: Set<Int>] {
        var targetInspectionWindowIdsByPID: [pid_t: Set<Int>] = [:]
        for pid in resolution.targetPIDs where !resolution.explicitAppPIDs.contains(pid) {
            targetInspectionWindowIdsByPID[pid] = Set(
                resolution.targetPIDsByWindowId.compactMap { windowId, targetPIDs in
                    targetPIDs.contains(pid) ? windowId : nil
                }
            )
        }
        return targetInspectionWindowIdsByPID
    }
}

extension FullRescanEnumeration {
    fileprivate static func empty(discoveryEvidence: FullRescanDiscoveryEvidence) -> Self {
        return Self(
            appTargets: [],
            results: [],
            coverage: FullRescanEnumerationCoverage(
                targetPIDs: [],
                dependencyPIDs: [],
                targetPIDsByDependencyPID: [:],
                unavailableTargetPIDs: [],
                unavailableDependencyPIDs: [],
                exactWindowIds: []
            ),
            discoveryEvidence: discoveryEvidence
        )
    }
}
