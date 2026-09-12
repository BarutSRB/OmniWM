// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension AXWindowInspectionContext {
    static func fullRescanInspectionContext(
        activationPolicy: NSApplication.ActivationPolicy,
        bundleId: String?,
        appName: String?,
        requiresTitleForApp: (String?, String?) -> Bool
    ) -> AXWindowInspectionContext {
        AXWindowInspectionContext(
            appPolicy: activationPolicy,
            bundleId: bundleId,
            includeTitle: requiresTitleForApp(bundleId, appName)
        )
    }

    static func shouldEnumerateForFullRescan(
        activationPolicy: NSApplication.ActivationPolicy,
        hasDiscoveryEvidence: Bool
    ) -> Bool {
        fullRescanEnumerationRoute(
            activationPolicy: activationPolicy,
            hasDiscoveryEvidence: hasDiscoveryEvidence,
            hasContext: false,
            hasPreservedState: false
        ) != nil
    }

    static func fullRescanEnumerationRoute(
        activationPolicy: NSApplication.ActivationPolicy,
        hasDiscoveryEvidence: Bool,
        hasContext: Bool,
        hasPreservedState: Bool
    ) -> FullRescanEnumerationRoute? {
        guard activationPolicy != .prohibited else { return nil }
        if hasDiscoveryEvidence || hasContext || hasPreservedState {
            return .persistent
        }
        return activationPolicy == .regular ? .oneShot : nil
    }
}
