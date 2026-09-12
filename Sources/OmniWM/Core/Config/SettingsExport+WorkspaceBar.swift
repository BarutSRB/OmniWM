// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension SettingsExport {
    struct WorkspaceBar: Codable, Equatable {
        var enabled: Bool
        var showLabels: Bool
        var showFloatingWindows: Bool
        var windowLevel: WorkspaceBarWindowLevel
        var position: WorkspaceBarPosition
        var notchMode: WorkspaceBarNotchMode
        var notchActiveZoneWidth: Double
        var systemStatsButton: Bool
        var deduplicateAppIcons: Bool
        var hideEmptyWorkspaces: Bool
        var excludedBundleIDs: [String]
        var iconOverrides: [String: String]
        var reserveLayoutSpace: Bool
        var revealModifier: WorkspaceBarRevealModifier
        var revealHoldMilliseconds: Double
        var hideInNativeFullscreen: Bool
        var height: Double
        var backgroundOpacity: Double
        var xOffset: Double
        var yOffset: Double
        var accentColor: SettingsColor?
        var textColor: SettingsColor?
    }
}

extension SettingsExport.WorkspaceBar {
    static func defaults() -> Self {
        Self(
            enabled: true,
            showLabels: true,
            showFloatingWindows: false,
            windowLevel: .popup,
            position: .overlappingMenuBar,
            notchMode: .moveBelowMenuBar,
            notchActiveZoneWidth: 180,
            systemStatsButton: false,
            deduplicateAppIcons: false,
            hideEmptyWorkspaces: false,
            excludedBundleIDs: [],
            iconOverrides: [:],
            reserveLayoutSpace: false,
            revealModifier: .off,
            revealHoldMilliseconds: 200,
            hideInNativeFullscreen: false,
            height: 24.0,
            backgroundOpacity: 0.1,
            xOffset: 0.0,
            yOffset: 0.0,
            accentColor: nil,
            textColor: nil
        )
    }
}

@MainActor
extension SettingsExport.WorkspaceBar {
    private struct NormalizedIconOverride {
        let foldedBundleID: String
        let bundleID: String
        let value: String
    }

    static func normalizedExcludedBundleIDs(_ bundleIDs: [String]) -> Set<String> {
        var normalized: Set<String> = []
        normalized.reserveCapacity(bundleIDs.count)
        for rawBundleID in bundleIDs {
            let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty,
                  !normalized.contains(where: {
                      $0.caseInsensitiveCompare(bundleID) == .orderedSame
                  })
            else {
                continue
            }
            normalized.insert(bundleID)
        }
        return normalized
    }

    static func sortedExcludedBundleIDs(_ bundleIDs: Set<String>) -> [String] {
        bundleIDs.sorted { lhs, rhs in
            let order = lhs.caseInsensitiveCompare(rhs)
            return order == .orderedSame ? lhs < rhs : order == .orderedAscending
        }
    }

    static func normalizedIconOverrides(_ overrides: [String: String]) -> [String: String] {
        let candidates = overrides.compactMap { rawBundleID, rawValue -> NormalizedIconOverride? in
            let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty, !value.isEmpty else { return nil }
            return NormalizedIconOverride(
                foldedBundleID: bundleID.lowercased(),
                bundleID: bundleID,
                value: value
            )
        }.sorted { lhs, rhs in
            if lhs.foldedBundleID != rhs.foldedBundleID {
                return lhs.foldedBundleID < rhs.foldedBundleID
            }
            if lhs.bundleID != rhs.bundleID {
                return lhs.bundleID < rhs.bundleID
            }
            return lhs.value < rhs.value
        }

        var normalized: [String: String] = [:]
        normalized.reserveCapacity(candidates.count)
        var seenBundleIDs: Set<String> = []
        seenBundleIDs.reserveCapacity(candidates.count)
        for candidate in candidates where seenBundleIDs.insert(candidate.foldedBundleID).inserted {
            normalized[candidate.bundleID] = candidate.value
        }
        return normalized
    }
}
