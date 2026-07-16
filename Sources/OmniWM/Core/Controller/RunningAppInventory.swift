// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

struct RunningAppInfo: Identifiable {
    let id: String
    let pid: pid_t?
    let bundleId: String?
    let appName: String
    let icon: NSImage?
    let windowSize: CGSize

    var trackedWindowSize: CGSize? {
        guard windowSize.width > 0, windowSize.height > 0 else { return nil }
        return windowSize
    }
}

enum RunningAppInventory {
    @MainActor
    static func rulePickerCandidates(
        trackedApplications: [RunningAppInfo],
        runningApplications: [NSRunningApplication] = NSWorkspace.shared.runningApplications
    ) -> [RunningAppInfo] {
        let systemApplications = runningApplications.compactMap { app -> RunningAppInfo? in
            guard app.activationPolicy == .regular else { return nil }
            let bundleId = app.bundleIdentifier
            return RunningAppInfo(
                id: bundleId ?? "pid:\(app.processIdentifier)",
                pid: app.processIdentifier,
                bundleId: bundleId,
                appName: app.localizedName
                    ?? app.executableURL?.deletingPathExtension().lastPathComponent
                    ?? bundleId
                    ?? "Process \(app.processIdentifier)",
                icon: app.icon,
                windowSize: .zero
            )
        }
        return merge(systemApplications: systemApplications, trackedApplications: trackedApplications)
    }

    static func merge(
        systemApplications: [RunningAppInfo],
        trackedApplications: [RunningAppInfo]
    ) -> [RunningAppInfo] {
        var applicationsById: [String: RunningAppInfo] = [:]
        for application in systemApplications where applicationsById[application.id] == nil {
            applicationsById[application.id] = application
        }
        let applicationIdByPidId = Dictionary(
            uniqueKeysWithValues: systemApplications.compactMap { app in
                app.pid.map { ("pid:\($0)", app.id) }
            }
        )

        for tracked in trackedApplications {
            let id = applicationsById[tracked.id] != nil
                ? tracked.id
                : applicationIdByPidId[tracked.id] ?? tracked.id
            guard let system = applicationsById[id] else {
                applicationsById[id] = tracked
                continue
            }
            applicationsById[id] = RunningAppInfo(
                id: id,
                pid: tracked.pid ?? system.pid,
                bundleId: tracked.bundleId ?? system.bundleId,
                appName: tracked.appName == "Unknown" ? system.appName : tracked.appName,
                icon: tracked.icon ?? system.icon,
                windowSize: tracked.windowSize
            )
        }

        return applicationsById.values.sorted {
            let nameOrder = $0.appName.localizedStandardCompare($1.appName)
            return nameOrder == .orderedSame ? $0.id < $1.id : nameOrder == .orderedAscending
        }
    }
}
