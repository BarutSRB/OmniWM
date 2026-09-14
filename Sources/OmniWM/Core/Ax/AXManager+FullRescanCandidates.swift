// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension AXManager {
    func finalizeFullRescanSnapshot(
        _ enumeration: FullRescanEnumeration,
        preservingPIDsByWindowId: [Int: pid_t]
    ) async throws -> FullRescanEnumerationSnapshot {
        let activationPolicyByPID = Dictionary(
            uniqueKeysWithValues: enumeration.appTargets.map { ($0.app.processIdentifier, $0.app.activationPolicy) }
        )
        let appsByPID = Dictionary(
            uniqueKeysWithValues: enumeration.appTargets.map { ($0.app.processIdentifier, $0.app) }
        )
        try Task.checkCancellation()
        let initialCollection = collectFullRescanCandidates(
            enumeration.results,
            discoveryEvidence: enumeration.discoveryEvidence
        )
        try Task.checkCancellation()
        var collection = initialCollection
        collection.failedPIDs.formUnion(enumeration.coverage.unavailableTargetPIDs)
        collection.failedPIDs.formUnion(enumeration.coverage.unavailableDependencyPIDs)
        var selected = FullRescanCandidateSelection.selectFullRescanCandidates(
            collection.candidatesByWindowId,
            activationPolicyByPID: activationPolicyByPID,
            preservingPIDsByWindowId: preservingPIDsByWindowId
        )
        let failedPromotions = try await promoteOneShotCandidates(selected, appsByPID: appsByPID)
        try Task.checkCancellation()
        removeFailedFullRescanPromotions(
            failedPromotions,
            selected: &selected,
            failedPIDs: &collection.failedPIDs,
            preservingPIDsByWindowId: preservingPIDsByWindowId
        )
        var successfullyEnumeratedPIDs = Set(
            enumeration.results.lazy.filter { !$0.failed }.map(\.pid)
        )
        successfullyEnumeratedPIDs.subtract(collection.failedPIDs)
        let authoritativeTargetPIDs = FullRescanTargetResolution.authoritativeFullRescanTargetPIDs(
            targetPIDs: enumeration.coverage.targetPIDs,
            successfullyEnumeratedPIDs: successfullyEnumeratedPIDs,
            failedPIDs: collection.failedPIDs,
            dependencyPIDs: enumeration.coverage.dependencyPIDs,
            targetPIDsByDependencyPID: enumeration.coverage.targetPIDsByDependencyPID
        )

        recordSelectedFullRescanCandidates(selected)
        return enumeration.snapshot(
            selected: selected,
            collection: &collection,
            successfullyEnumeratedPIDs: successfullyEnumeratedPIDs,
            authoritativeTargetPIDs: authoritativeTargetPIDs
        )
    }

    func collectFullRescanCandidates(
        _ results: [FullRescanAppEnumerationResult],
        discoveryEvidence: FullRescanDiscoveryEvidence
    ) -> FullRescanCandidateCollection {
        var collection = FullRescanCandidateCollection(
            candidatesByWindowId: [:],
            identityAliasesByWindowId: [:],
            failedPIDs: []
        )
        for result in results {
            if result.failed {
                collection.failedPIDs.insert(result.pid)
            }
            for window in result.windows {
                let windowId = window.axRef.windowId
                let ownerPID = discoveryEvidence.ownerPIDByWindowId[windowId]
                appendFullRescanAliases(
                    for: window,
                    logicalPID: result.pid,
                    ownerPID: ownerPID,
                    to: &collection.identityAliasesByWindowId
                )
                let candidate = FullRescanWindowCandidate(
                    enumeratedWindow: window,
                    logicalPID: result.pid,
                    windowServerInfo: discoveryEvidence.windowServerInfoByWindowId[windowId],
                    windowServerOwnerPID: ownerPID,
                    enumerationRoute: result.route,
                    callbackGeneration: result.callbackGeneration
                )
                collection.candidatesByWindowId[windowId, default: []].append(candidate)
                recordFullRescanCandidate(candidate)
            }
        }
        return collection
    }

    func appendFullRescanAliases(
        for window: AXEnumeratedWindow,
        logicalPID: pid_t,
        ownerPID: pid_t?,
        to aliasesByWindowId: inout [Int: FullRescanWindowIdentityAliases]
    ) {
        let windowId = window.axRef.windowId
        var aliases = aliasesByWindowId[windowId] ?? .init()
        aliases.pids.insert(logicalPID)
        if let axPid = window.axPid {
            aliases.pids.insert(axPid)
        }
        if let ownerPID {
            aliases.pids.insert(ownerPID)
        }
        if !aliases.axRefs.contains(where: { CFEqual($0.element, window.axRef.element) }) {
            aliases.axRefs.append(window.axRef)
        }
        aliasesByWindowId[windowId] = aliases
    }

    func recordFullRescanCandidate(_ candidate: FullRescanWindowCandidate) {
        WindowAdmissionTrace.record(
            .init(
                action: .fullRescanCandidate,
                pid: candidate.pid,
                windowId: candidate.windowId,
                axPid: candidate.axPid,
                windowServerPid: candidate.windowServerOwnerPID,
                callbackGeneration: candidate.callbackGeneration,
                manageable: candidate.isManageable,
                axRef: candidate.axRef
            )
        )
    }

    func promoteOneShotCandidates(
        _ candidates: [FullRescanWindowCandidate],
        appsByPID: [pid_t: NSRunningApplication]
    ) async throws -> Set<pid_t> {
        try Task.checkCancellation()
        var failedPIDs: Set<pid_t> = []
        try await FullRescanCandidateSelection.forEachOneShotPromotionBatch(candidates) { pid, _ in
            try Task.checkCancellation()
            guard let app = appsByPID[pid] else {
                failedPIDs.insert(pid)
                return
            }
            let hadContext = AppAXContextRegistry.contexts[pid] != nil
            var callbackGeneration: UInt64?
            do {
                guard let context = try await AppAXContextRegistry.getOrCreate(app) else {
                    failedPIDs.insert(pid)
                    if !hadContext {
                        destroyContextIfPresent(for: pid, reason: "promotion-failed")
                    }
                    return
                }
                callbackGeneration = context.callbackGeneration
            } catch is CancellationError {
                if !hadContext {
                    destroyContextIfPresent(for: pid, reason: "promotion-cancelled")
                }
                throw CancellationError()
            } catch {
                failedPIDs.insert(pid)
                if !hadContext {
                    destroyContextIfPresent(for: pid, reason: "promotion-failed")
                }
                Self.recordFullRescanEnumerationFailure(
                    app,
                    reason: "promotion_\(error)",
                    callbackGeneration: callbackGeneration
                )
            }
        }
        return failedPIDs
    }

    private func recordSelectedFullRescanCandidates(_ selected: [FullRescanWindowCandidate]) {
        if WindowAdmissionTrace.shared.isActive {
            for candidate in selected {
                WindowAdmissionTrace.record(
                    .init(
                        action: .fullRescanSelected,
                        pid: candidate.pid,
                        windowId: candidate.windowId,
                        axPid: candidate.axPid,
                        windowServerPid: candidate.windowServerOwnerPID,
                        reason: "final_selection",
                        callbackGeneration: candidate.callbackGeneration
                            ?? AppAXContextRegistry.contexts[candidate.pid]?.callbackGeneration,
                        manageable: candidate.isManageable,
                        axRef: candidate.axRef
                    )
                )
            }
        }
    }

    private func removeFailedFullRescanPromotions(
        _ failedPromotions: Set<pid_t>,
        selected: inout [FullRescanWindowCandidate],
        failedPIDs: inout Set<pid_t>,
        preservingPIDsByWindowId: [Int: pid_t]
    ) {
        if !failedPromotions.isEmpty {
            failedPIDs.formUnion(failedPromotions)
            for candidate in selected
                where candidate.enumerationRoute == .oneShot && failedPromotions.contains(candidate.pid)
            {
                if let preservedPID = preservingPIDsByWindowId[candidate.windowId] {
                    failedPIDs.insert(preservedPID)
                }
            }
            selected.removeAll {
                $0.enumerationRoute == .oneShot && failedPromotions.contains($0.pid)
            }
        }
    }
}
