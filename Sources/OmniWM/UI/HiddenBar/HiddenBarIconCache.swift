// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

@MainActor
final class HiddenBarIconCache {
    private(set) var icons: [MenuBarItemKey: CapturedIcon] = [:]
    private var resolvedItemsByBundleID: [String: [ResolvedMenuBarItem]] = [:]
    var onChange: (() -> Void)?

    func replaceResolvedItems(
        _ itemsByBundleID: [String: [ResolvedMenuBarItem]],
        capturedIcons: [MenuBarItemKey: CapturedIcon] = [:],
        replacingCapturedIcons: Bool = false
    ) {
        var changed = false
        for (bundleID, items) in itemsByBundleID {
            let sortedItems = items.sorted { $0.key.ordinal < $1.key.ordinal }
            let keys = sortedItems.map(\.key)
            let previousKeys = resolvedItemsByBundleID[bundleID]?.map(\.key)
            resolvedItemsByBundleID[bundleID] = sortedItems
            if previousKeys != keys {
                changed = true
            }
            let resolvedKeys = Set(keys)
            let stale = icons.keys.filter {
                $0.bundleID == bundleID && (replacingCapturedIcons || !resolvedKeys.contains($0))
            }
            for key in stale {
                icons.removeValue(forKey: key)
                changed = true
            }
        }
        let resolvedKeys = Set(resolvedItemsByBundleID.values.flatMap { $0.map(\.key) })
        for (key, icon) in capturedIcons
            where resolvedKeys.contains(key) && !Self.isVisuallyEqual(icons[key], icon)
        {
            icons[key] = icon
            changed = true
        }
        if changed {
            onChange?()
        }
    }

    func resolvedItems(for bundleID: String) -> [(key: MenuBarItemKey, icon: CapturedIcon?)]? {
        guard let items = resolvedItemsByBundleID[bundleID] else { return nil }
        return items.map { ($0.key, icons[$0.key]) }
    }

    func resolvedSnapshot(for bundleID: String) -> [ResolvedMenuBarItem]? {
        resolvedItemsByBundleID[bundleID]
    }

    func hasResolvedItems(for bundleID: String) -> Bool {
        resolvedItemsByBundleID[bundleID] != nil
    }

    func prune(keeping bundleIDs: Set<String>) {
        let staleIcons = icons.keys.filter { !bundleIDs.contains($0.bundleID) }
        let staleBundles = resolvedItemsByBundleID.keys.filter { !bundleIDs.contains($0) }
        guard !staleIcons.isEmpty || !staleBundles.isEmpty else { return }
        for key in staleIcons {
            icons.removeValue(forKey: key)
        }
        for bundleID in staleBundles {
            resolvedItemsByBundleID.removeValue(forKey: bundleID)
        }
        onChange?()
    }

    nonisolated static func isVisuallyEqual(_ lhs: CapturedIcon?, _ rhs: CapturedIcon?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        if lhs.image === rhs.image, lhs.scale == rhs.scale { return true }
        guard lhs.scale == rhs.scale,
              lhs.image.width == rhs.image.width,
              lhs.image.height == rhs.image.height,
              let dataA = lhs.image.dataProvider?.data,
              let dataB = rhs.image.dataProvider?.data
        else { return false }
        return CFEqual(dataA, dataB)
    }
}
