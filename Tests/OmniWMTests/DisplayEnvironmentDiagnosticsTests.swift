// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class DisplayEnvironmentDiagnosticsTests: XCTestCase {
    private func monitor(
        id: CGDirectDisplayID,
        frame: CGRect,
        visible: CGRect,
        hasNotch: Bool = false
    ) -> Monitor {
        Monitor(
            id: Monitor.ID(displayId: id),
            displayId: id,
            frame: frame,
            visibleFrame: visible,
            hasNotch: hasNotch,
            name: "Display \(id)"
        )
    }

    private func hasFixedDock(_ issues: [DiagnosticsIssue]) -> Bool {
        issues.contains { if case .fixedDock = $0.kind { true } else { false } }
    }

    private func hasHorizontalArrangement(_ issues: [DiagnosticsIssue]) -> Bool {
        issues.contains { if case .horizontalDisplayArrangement = $0.kind { true } else { false } }
    }

    func testFixedDockBottomDetected() {
        let display = monitor(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            visible: CGRect(x: 0, y: 30, width: 1000, height: 940)
        )
        XCTAssertTrue(hasFixedDock(DisplayEnvironmentDiagnostics.issues(monitors: [display], spacesMode: .disabled)))
    }

    func testTopInsetNotFlagged() {
        let display = monitor(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            visible: CGRect(x: 0, y: 0, width: 1000, height: 975),
            hasNotch: true
        )
        XCTAssertTrue(DisplayEnvironmentDiagnostics.issues(monitors: [display], spacesMode: .disabled).isEmpty)
    }

    func testHorizontalArrangementFiresWhenSeparateSpacesOff() {
        let issues = DisplayEnvironmentDiagnostics.issues(monitors: sideBySide(), spacesMode: .disabled)
        XCTAssertTrue(hasHorizontalArrangement(issues))
    }

    func testHorizontalArrangementSuppressedWhenSeparateSpacesOn() {
        let issues = DisplayEnvironmentDiagnostics.issues(monitors: sideBySide(), spacesMode: .enabled)
        XCTAssertFalse(hasHorizontalArrangement(issues))
    }

    func testVerticallyStackedDoesNotFire() {
        let top = monitor(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            visible: CGRect(x: 0, y: 0, width: 1000, height: 1000)
        )
        let bottom = monitor(
            id: 2,
            frame: CGRect(x: 0, y: 1000, width: 1000, height: 1000),
            visible: CGRect(x: 0, y: 1000, width: 1000, height: 1000)
        )
        let issues = DisplayEnvironmentDiagnostics.issues(monitors: [top, bottom], spacesMode: .disabled)
        XCTAssertFalse(hasHorizontalArrangement(issues))
    }

    private func sideBySide() -> [Monitor] {
        [
            monitor(
                id: 1,
                frame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                visible: CGRect(x: 0, y: 0, width: 1000, height: 1000)
            ),
            monitor(
                id: 2,
                frame: CGRect(x: 1000, y: 0, width: 1000, height: 1000),
                visible: CGRect(x: 1000, y: 0, width: 1000, height: 1000)
            )
        ]
    }
}
