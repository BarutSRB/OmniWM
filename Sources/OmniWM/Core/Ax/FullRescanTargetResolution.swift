// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct FullRescanTargetInputs {
    let scope: RescanScope
    let resolvedTargetPIDs: Set<pid_t>
    let resolvedTargetWindowIds: Set<Int>
    let preservingPIDsByWindowId: [Int: pid_t]
    let identityDependencyPIDsByWindowId: [Int: Set<pid_t>]
}

struct FullRescanTargetResolution: Equatable {
    let explicitAppPIDs: Set<pid_t>
    let resolvedTargetPIDs: Set<pid_t>
    let resolvedTargetWindowIds: Set<Int>
    let targetPIDs: Set<pid_t>
    let nativeSpaceIds: Set<UInt64>
    let nativeSpaceWindowIdsByPID: [pid_t: Set<Int>]
    var relevantWindowIds: Set<Int>
    var targetPIDsByWindowId: [Int: Set<pid_t>]
    var dependencyPIDs: Set<pid_t>
    var targetPIDsByDependencyPID: [pid_t: Set<pid_t>]

    var effectiveScope: RescanScope {
        .targeted(
            appPIDs: targetPIDs.union(dependencyPIDs),
            nativeSpaceIds: nativeSpaceIds,
            nativeSpaceWindowIdsByPID: nativeSpaceWindowIdsByPID
        )
    }
}

extension FullRescanTargetResolution {
    static func fullRescanTargetResolution(
        _ inputs: FullRescanTargetInputs,
        ownerPIDByWindowId: [Int: pid_t]
    ) -> FullRescanTargetResolution? {
        guard case let .targeted(
            requestedPIDs,
            nativeSpaceIds,
            nativeSpaceWindowIdsByPID
        ) = inputs.scope else {
            return nil
        }
        let targetPIDs = requestedPIDs.union(inputs.resolvedTargetPIDs)
        var relevantWindowIds: Set<Int> = []
        var targetPIDsByWindowId: [Int: Set<pid_t>] = [:]
        for (windowId, pid) in inputs.preservingPIDsByWindowId where requestedPIDs.contains(pid) {
            relevantWindowIds.insert(windowId)
            targetPIDsByWindowId[windowId, default: []].insert(pid)
        }
        for (windowId, pid) in ownerPIDByWindowId where requestedPIDs.contains(pid) {
            relevantWindowIds.insert(windowId)
            targetPIDsByWindowId[windowId, default: []].insert(pid)
        }
        relevantWindowIds.formUnion(inputs.resolvedTargetWindowIds)
        for windowId in inputs.resolvedTargetWindowIds {
            if let pid = inputs.preservingPIDsByWindowId[windowId], targetPIDs.contains(pid) {
                targetPIDsByWindowId[windowId, default: []].insert(pid)
            }
            if let pid = ownerPIDByWindowId[windowId], targetPIDs.contains(pid) {
                targetPIDsByWindowId[windowId, default: []].insert(pid)
            }
        }
        var resolution = FullRescanTargetResolution(
            explicitAppPIDs: requestedPIDs,
            resolvedTargetPIDs: inputs.resolvedTargetPIDs,
            resolvedTargetWindowIds: inputs.resolvedTargetWindowIds,
            targetPIDs: targetPIDs,
            nativeSpaceIds: nativeSpaceIds,
            nativeSpaceWindowIdsByPID: nativeSpaceWindowIdsByPID,
            relevantWindowIds: relevantWindowIds,
            targetPIDsByWindowId: targetPIDsByWindowId,
            dependencyPIDs: [],
            targetPIDsByDependencyPID: [:]
        )
        includeFullRescanKnownDependencies(
            in: &resolution,
            preservingPIDsByWindowId: inputs.preservingPIDsByWindowId,
            ownerPIDByWindowId: ownerPIDByWindowId,
            identityDependencyPIDsByWindowId: inputs.identityDependencyPIDsByWindowId
        )
        return resolution
    }

    static func includeFullRescanTargetWindows(
        _ results: [FullRescanAppEnumerationResult],
        in resolution: inout FullRescanTargetResolution,
        preservingPIDsByWindowId: [Int: pid_t],
        ownerPIDByWindowId: [Int: pid_t],
        identityDependencyPIDsByWindowId: [Int: Set<pid_t>]
    ) {
        for result in results where resolution.targetPIDs.contains(result.pid) {
            for window in result.windows {
                let windowId = window.axRef.windowId
                resolution.relevantWindowIds.insert(windowId)
                resolution.targetPIDsByWindowId[windowId, default: []].insert(result.pid)
            }
        }
        includeFullRescanObservedDependencies(results, in: &resolution)
        includeFullRescanKnownDependencies(
            in: &resolution,
            preservingPIDsByWindowId: preservingPIDsByWindowId,
            ownerPIDByWindowId: ownerPIDByWindowId,
            identityDependencyPIDsByWindowId: identityDependencyPIDsByWindowId
        )
    }

    static func includeFullRescanDependencyWindows(
        _ results: [FullRescanAppEnumerationResult],
        in resolution: inout FullRescanTargetResolution,
        preservingPIDsByWindowId: [Int: pid_t],
        ownerPIDByWindowId: [Int: pid_t],
        identityDependencyPIDsByWindowId: [Int: Set<pid_t>]
    ) {
        includeFullRescanObservedDependencies(results, in: &resolution)
        includeFullRescanKnownDependencies(
            in: &resolution,
            preservingPIDsByWindowId: preservingPIDsByWindowId,
            ownerPIDByWindowId: ownerPIDByWindowId,
            identityDependencyPIDsByWindowId: identityDependencyPIDsByWindowId
        )
    }

    private static func includeFullRescanObservedDependencies(
        _ results: [FullRescanAppEnumerationResult],
        in resolution: inout FullRescanTargetResolution
    ) {
        for result in results {
            for window in result.windows {
                let windowId = window.axRef.windowId
                guard resolution.relevantWindowIds.contains(windowId),
                      let targetPIDs = resolution.targetPIDsByWindowId[windowId],
                      let axPid = window.axPid
                else {
                    continue
                }
                let dependentTargetPIDs = targetPIDs.subtracting([axPid])
                guard !dependentTargetPIDs.isEmpty else { continue }
                resolution.dependencyPIDs.insert(axPid)
                resolution.targetPIDsByDependencyPID[axPid, default: []]
                    .formUnion(dependentTargetPIDs)
            }
        }
    }

    private static func includeFullRescanKnownDependencies(
        in resolution: inout FullRescanTargetResolution,
        preservingPIDsByWindowId: [Int: pid_t],
        ownerPIDByWindowId: [Int: pid_t],
        identityDependencyPIDsByWindowId: [Int: Set<pid_t>]
    ) {
        for windowId in resolution.relevantWindowIds {
            guard let targetPIDs = resolution.targetPIDsByWindowId[windowId] else { continue }
            var relatedPIDs = identityDependencyPIDsByWindowId[windowId] ?? []
            if let preservedPID = preservingPIDsByWindowId[windowId] {
                relatedPIDs.insert(preservedPID)
            }
            if let ownerPID = ownerPIDByWindowId[windowId] {
                relatedPIDs.insert(ownerPID)
            }
            for pid in relatedPIDs {
                let dependentTargetPIDs = targetPIDs.subtracting([pid])
                guard !dependentTargetPIDs.isEmpty else { continue }
                resolution.dependencyPIDs.insert(pid)
                resolution.targetPIDsByDependencyPID[pid, default: []]
                    .formUnion(dependentTargetPIDs)
            }
        }
    }

    static func authoritativeFullRescanTargetPIDs(
        targetPIDs: Set<pid_t>,
        successfullyEnumeratedPIDs: Set<pid_t>,
        failedPIDs: Set<pid_t>,
        dependencyPIDs: Set<pid_t>,
        targetPIDsByDependencyPID: [pid_t: Set<pid_t>]
    ) -> Set<pid_t> {
        var authoritative = targetPIDs
            .intersection(successfullyEnumeratedPIDs)
            .subtracting(failedPIDs)
        for failedDependencyPID in dependencyPIDs.intersection(failedPIDs) {
            authoritative.subtract(targetPIDsByDependencyPID[failedDependencyPID] ?? [])
        }
        return authoritative
    }
}
