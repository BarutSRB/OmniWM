// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

struct HiddenBarRunningAppsSnapshot {
    let bundleIDs: Set<String>
    let candidates: [MenuBarAppCandidate]

    static func current() -> HiddenBarRunningAppsSnapshot {
        let applications = NSWorkspace.shared.runningApplications
        var bundleIDs: Set<String> = []
        var candidates: [MenuBarAppCandidate] = []
        bundleIDs.reserveCapacity(applications.count)
        candidates.reserveCapacity(applications.count)
        for app in applications {
            guard let bundleID = app.bundleIdentifier else { continue }
            bundleIDs.insert(bundleID)
            candidates.append(MenuBarAppCandidate(
                bundleID: bundleID,
                pid: app.processIdentifier,
                name: app.localizedName ?? bundleID
            ))
        }
        return HiddenBarRunningAppsSnapshot(bundleIDs: bundleIDs, candidates: candidates)
    }

    static func menuOwnerPIDs(for bundleIDs: Set<String>) -> Set<pid_t> {
        guard !bundleIDs.isEmpty else { return [] }
        return Set(NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.map(bundleIDs.contains) == true ? app.processIdentifier : nil
        })
    }
}
