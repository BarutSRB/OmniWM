// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices

struct MenuBarAppCandidate: Equatable, Sendable {
    let bundleID: String
    let pid: pid_t
    let name: String
}

struct DetectedMenuBarApp: Equatable, Sendable, Identifiable {
    let bundleID: String
    let pid: pid_t
    let name: String

    var id: String {
        bundleID
    }
}

enum MenuBarExtrasScanner {
    private static let messagingTimeoutSeconds: Float = 0.25
    static func scan(
        candidates: [MenuBarAppCandidate],
        ownBundleID: String?,
        job: RunLoopJob
    ) throws -> [DetectedMenuBarApp] {
        var seen: Set<String> = []
        var result: [DetectedMenuBarApp] = []

        for candidate in candidates {
            try job.checkCancellation()
            guard candidate.bundleID != ownBundleID,
                  !HiddenBarSettingsPolicy.protectedSystemHostBundleIDs.contains(candidate.bundleID),
                  !seen.contains(candidate.bundleID),
                  ownsMenuBarExtra(pid: candidate.pid)
            else { continue }

            seen.insert(candidate.bundleID)
            result.append(
                DetectedMenuBarApp(
                    bundleID: candidate.bundleID,
                    pid: candidate.pid,
                    name: candidate.name
                )
            )
        }

        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func ownsMenuBarExtra(pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeoutSeconds)
        defer { AXUIElementSetMessagingTimeout(appElement, 0) }

        var extrasRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, "AXExtrasMenuBar" as CFString, &extrasRef) == .success,
              let extras = extrasRef, CFGetTypeID(extras) == AXUIElementGetTypeID()
        else { return false }

        let extrasElement = unsafeDowncast(extras as AnyObject, to: AXUIElement.self)
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(extrasElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return false }

        return !children.isEmpty
    }
}
