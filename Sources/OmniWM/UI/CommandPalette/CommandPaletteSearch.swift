// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Observation
import SwiftUI

@MainActor
enum CommandPaletteSearch {
    static func filterWindowItems(
        _ items: [CommandPaletteWindowItem],
        query rawQuery: String
    ) -> [CommandPaletteWindowItem] {
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return items
        }
        let query = trimmedQuery.lowercased()

        let scored: [(CommandPaletteWindowItem, Int)] = items.compactMap { item in
            let titleLower = item.title.lowercased()
            let appLower = item.appName.lowercased()

            if let range = titleLower.range(of: query) {
                let pos = titleLower.distance(from: titleLower.startIndex, to: range.lowerBound)
                return (item, pos)
            }

            if let range = appLower.range(of: query) {
                let pos = appLower.distance(from: appLower.startIndex, to: range.lowerBound)
                return (item, 1000 + pos)
            }

            let workspaceLower = item.workspaceName.lowercased()
            if let range = workspaceLower.range(of: query) {
                let pos = workspaceLower.distance(from: workspaceLower.startIndex, to: range.lowerBound)
                return (item, 2000 + pos)
            }

            if item.isAppHidden, let range = "hidden".range(of: query) {
                let pos = "hidden".distance(from: "hidden".startIndex, to: range.lowerBound)
                return (item, 3000 + pos)
            }

            return nil
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.0.title.count != rhs.0.title.count { return lhs.0.title.count < rhs.0.title.count }
                return lhs.0.title < rhs.0.title
            }
            .map(\.0)
    }

    static func filterMenuItems(_ items: [MenuItemModel], query rawQuery: String) -> [MenuItemModel] {
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return items
        }
        let query = trimmedQuery.lowercased()

        let scored: [(MenuItemModel, Int)] = items.compactMap { item in
            let titleLower = item.title.lowercased()
            let pathLower = item.fullPath.lowercased()

            if let range = titleLower.range(of: query) {
                let pos = titleLower.distance(from: titleLower.startIndex, to: range.lowerBound)
                return (item, pos)
            }

            if let range = pathLower.range(of: query) {
                let pos = pathLower.distance(from: pathLower.startIndex, to: range.lowerBound)
                return (item, 1000 + pos)
            }

            return nil
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.0.title.count != rhs.0.title.count { return lhs.0.title.count < rhs.0.title.count }
                return lhs.0.title < rhs.0.title
            }
            .map(\.0)
    }

    static func filterClipboardItems(
        _ items: [ClipboardPaletteItem],
        query rawQuery: String
    ) -> [ClipboardPaletteItem] {
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return items
        }
        let query = trimmedQuery.lowercased()

        let scored: [(ClipboardPaletteItem, Int)] = items.compactMap { item in
            let titleLower = item.title.lowercased()
            let subtitleLower = item.subtitle.lowercased()
            let kindLower = item.kind.rawValue.lowercased()

            if let range = titleLower.range(of: query) {
                let pos = titleLower.distance(from: titleLower.startIndex, to: range.lowerBound)
                return (item, pos)
            }

            if let range = subtitleLower.range(of: query) {
                let pos = subtitleLower.distance(from: subtitleLower.startIndex, to: range.lowerBound)
                return (item, 1000 + pos)
            }

            if let range = kindLower.range(of: query) {
                let pos = kindLower.distance(from: kindLower.startIndex, to: range.lowerBound)
                return (item, 2000 + pos)
            }

            return nil
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.0.title.count != rhs.0.title.count { return lhs.0.title.count < rhs.0.title.count }
                return lhs.0.title < rhs.0.title
            }
            .map(\.0)
    }

    static func buildWindowItems(from wmController: WMController) -> [CommandPaletteWindowItem] {
        let entries = wmController.workspaceManager.allEntries()
        var items: [CommandPaletteWindowItem] = []
        items.reserveCapacity(entries.count)

        for entry in entries {
            guard entry.layoutReason == .standard,
                  let handle = wmController.workspaceManager.handle(for: entry.token) else { continue }

            let title = AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId)) ?? ""
            let appInfo = wmController.appInfoCache.info(for: entry.pid)
            let workspaceName = wmController.workspaceManager.descriptor(for: entry.workspaceId)?.name ?? "?"

            items.append(CommandPaletteWindowItem(
                id: entry.token,
                handle: handle,
                title: title,
                appName: appInfo?.name ?? "Unknown",
                appIcon: appInfo?.icon,
                workspaceName: workspaceName,
                isAppHidden: wmController.workspaceManager.isAppHidden(pid: entry.pid)
            ))
        }

        items.sort {
            ($0.isAppHidden ? 1 : 0, $0.appName, $0.title)
                < ($1.isAppHidden ? 1 : 0, $1.appName, $1.title)
        }
        return items
    }
}
