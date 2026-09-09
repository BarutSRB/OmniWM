// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarPanelPolicyTests: XCTestCase {
    func testFillModeUsesAboveStatusLevelWithoutFullscreenAuxiliary() {
        let resolved = makeResolved(notchMode: .fillLeftOfNotch, windowLevel: .screensaver)

        XCTAssertEqual(
            WorkspaceBarManager.panelLevel(for: resolved).rawValue,
            NSWindow.Level.statusBar.rawValue + 1
        )
        let behavior = WorkspaceBarManager.panelCollectionBehavior(for: resolved)
        XCTAssertTrue(behavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(behavior.contains(.stationary))
        XCTAssertFalse(behavior.contains(.fullScreenAuxiliary))
    }

    func testNonFillModeUsesConfiguredLevelAndExistingFlags() {
        let resolved = makeResolved(notchMode: .off, windowLevel: .screensaver)

        XCTAssertEqual(WorkspaceBarManager.panelLevel(for: resolved), .screenSaver)
        XCTAssertEqual(
            WorkspaceBarManager.panelCollectionBehavior(for: resolved),
            [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        )
    }

    private func makeResolved(
        notchMode: WorkspaceBarNotchMode,
        windowLevel: WorkspaceBarWindowLevel
    ) -> ResolvedBarSettings {
        ResolvedBarSettings(
            enabled: true,
            showLabels: true,
            showFloatingWindows: false,
            deduplicateAppIcons: false,
            hideEmptyWorkspaces: false,
            excludedBundleIDs: [],
            reserveLayoutSpace: false,
            notchMode: notchMode,
            notchActiveZoneWidth: 180,
            systemStatsButton: false,
            position: .overlappingMenuBar,
            windowLevel: windowLevel,
            height: 24,
            backgroundOpacity: 0.6,
            inactiveIconOpacity: nil,
            transparentBackground: false,
            solidBlackBackground: false,
            showItemBackgrounds: true,
            showAccentHighlights: true,
            xOffset: 0,
            yOffset: 0,
            accentColor: nil,
            textColor: nil
        )
    }
}
