// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension AXManager {
    func targetedFullRescanDiscoveryEvidence(
        _ windowServerInfoByWindowId: [Int: WindowServerInfo]
    ) -> FullRescanDiscoveryEvidence {
        var evidence = FullRescanDiscoveryEvidence(
            pidsWithWindows: [],
            windowServerInfoByWindowId: [:],
            ownerPIDByWindowId: [:]
        )
        for (windowId, info) in windowServerInfoByWindowId where Int(info.id) == windowId {
            evidence.pidsWithWindows.insert(info.pid)
            evidence.windowServerInfoByWindowId[windowId] = info
            evidence.ownerPIDByWindowId[windowId] = info.pid
        }
        return evidence
    }

    @discardableResult
    func mergeFullRescanWindowServerEvidence(
        for results: [FullRescanAppEnumerationResult],
        into evidence: inout FullRescanDiscoveryEvidence
    ) async throws -> Bool {
        let windowIds = Set(results.lazy.flatMap(\.windows).map(\.axRef.windowId))
        return try await mergeFullRescanWindowServerEvidence(windowIds: windowIds, into: &evidence)
    }

    @discardableResult
    func mergeFullRescanWindowServerEvidence(
        windowIds: Set<Int>,
        expectedPIDsByWindowId: [Int: pid_t]? = nil,
        into evidence: inout FullRescanDiscoveryEvidence
    ) async throws -> Bool {
        guard let windowInfoById = try await queryFullRescanWindowServerEvidence(
            windowIds: windowIds,
            excludingWindowIds: Set(evidence.windowServerInfoByWindowId.keys),
            expectedPIDsByWindowId: expectedPIDsByWindowId
        ) else {
            return false
        }
        for (key, info) in windowInfoById {
            evidence.pidsWithWindows.insert(info.pid)
            evidence.windowServerInfoByWindowId[key] = info
            evidence.ownerPIDByWindowId[key] = info.pid
        }
        return true
    }

    func queryFullRescanWindowServerEvidence(
        windowIds: Set<Int>,
        excludingWindowIds: Set<Int>,
        expectedPIDsByWindowId: [Int: pid_t]? = nil
    ) async throws -> [Int: WindowServerInfo]? {
        let missingWindowIds = Set(
            windowIds.subtracting(excludingWindowIds).compactMap(UInt32.init(exactly:))
        )
        guard !missingWindowIds.isEmpty else { return [:] }
        let queriedInfoById = try await fullRescanWindowInfoProvider(missingWindowIds)
        try Task.checkCancellation()
        guard let queriedInfoById else {
            return nil
        }
        return Dictionary(
            uniqueKeysWithValues: queriedInfoById.compactMap { windowId, info in
                let key = Int(windowId)
                if let expectedPIDsByWindowId,
                   expectedPIDsByWindowId[key] != info.pid
                {
                    return nil
                }
                return (key, info)
            }
        )
    }

    func fullRescanRunningApplications(
        for pids: Set<pid_t>
    ) -> [NSRunningApplication] {
        pids.sorted().compactMap(NSRunningApplication.init(processIdentifier:))
    }

    func fullRescanAppTargets(
        _ runningApplications: [NSRunningApplication],
        selection: FullRescanAppTargetSelection,
        requiresTitleForApp: (String?, String?) -> Bool
    ) -> [FullRescanAppTarget] {
        let existingContextPIDs = Set(AppAXContextRegistry.contexts.keys)
        let preservingPIDs = Set(selection.preservingPIDsByWindowId.values)
        return runningApplications.compactMap { app in
            let pid = app.processIdentifier
            guard selection.includedPIDs?.contains(pid) ?? true,
                  shouldTrack(app)
            else {
                return nil
            }
            let route = AXWindowInspectionContext.fullRescanEnumerationRoute(
                activationPolicy: app.activationPolicy,
                hasDiscoveryEvidence: selection.discoveryEvidence.pidsWithWindows.contains(pid),
                hasContext: existingContextPIDs.contains(pid),
                hasPreservedState: preservingPIDs.contains(pid)
                    || selection.persistentEvidencePIDs.contains(pid)
            ) ?? (selection.allowsEvidenceFreeOneShot ? .oneShot : nil)
            guard let route else { return nil }
            return FullRescanAppTarget(
                app: app,
                route: route,
                inspectionContext: AXWindowInspectionContext.fullRescanInspectionContext(
                    activationPolicy: app.activationPolicy,
                    bundleId: app.bundleIdentifier,
                    appName: app.localizedName,
                    requiresTitleForApp: requiresTitleForApp
                ),
                includedWindowIds: selection.includedWindowIdsByPID[pid]
            )
        }
    }

    func fullRescanDiscoveryEvidence() -> FullRescanDiscoveryEvidence {
        let visibleWindows = SkyLight.shared.queryAllVisibleWindows()
        var evidence = FullRescanDiscoveryEvidence(
            pidsWithWindows: Set(visibleWindows.map { $0.pid }),
            windowServerInfoByWindowId: [:],
            ownerPIDByWindowId: [:]
        )
        for window in visibleWindows {
            evidence.windowServerInfoByWindowId[Int(window.id)] = window
            evidence.ownerPIDByWindowId[Int(window.id)] = pid_t(window.pid)
        }
        let skyLightPIDCount = evidence.pidsWithWindows.count
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            FallbackFiringRecorder.shared.note(.capture, "cgWindowListNull")
            return evidence
        }
        for window in windows {
            guard let pidNumber = window[kCGWindowOwnerPID as String] as? Int,
                  let windowNumber = window[kCGWindowNumber as String] as? Int,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let alpha = window[kCGWindowAlpha as String] as? Double,
                  alpha > 0
            else { continue }
            let pid = pid_t(pidNumber)
            evidence.pidsWithWindows.insert(pid)
            evidence.ownerPIDByWindowId[windowNumber] = evidence.ownerPIDByWindowId[windowNumber] ?? pid
        }
        FallbackFiringRecorder.shared.note(
            .capture,
            "cgWindowListSupplementPids",
            evidence.pidsWithWindows.count - skyLightPIDCount
        )
        return evidence
    }
}
