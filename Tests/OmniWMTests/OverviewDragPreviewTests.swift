// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import IOSurface
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class OverviewDragPreviewTests: XCTestCase {
    func testGhostPreservesDragGeometryAndRegistersExcludedPassthroughPanel() {
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
        let ghost = OverviewDragGhost(
            originalFrame: CGRect(x: 100, y: 200, width: 800, height: 600),
            ownedWindowRegistry: registry
        )
        defer { ghost.destroy() }

        XCTAssertEqual(ghost.frame.size, CGSize(width: 400, height: 300))
        XCTAssertEqual(ghost.alphaValue, 0.5)
        XCTAssertGreaterThan(ghost.level.rawValue, NSWindow.Level.screenSaver.rawValue)
        XCTAssertFalse(ghost.canBecomeKey)
        XCTAssertFalse(ghost.canBecomeMain)
        XCTAssertTrue(ghost.ignoresMouseEvents)
        XCTAssertTrue(registry.contains(window: ghost))
        XCTAssertFalse(registry.isCaptureEligible(windowNumber: ghost.windowNumber))
        XCTAssertNotNil(ghost.contentView?.layer?.backgroundColor)
        XCTAssertNil(ghost.thumbnail.contents)

        ghost.moveTo(cursorLocation: CGPoint(x: 1200, y: 700))
        XCTAssertEqual(ghost.frame, CGRect(x: 1210, y: 390, width: 400, height: 300))
        ghost.moveTo(cursorLocation: CGPoint(x: -900, y: 400))
        XCTAssertEqual(ghost.frame, CGRect(x: -890, y: 90, width: 400, height: 300))
    }

    func testGhostUsesLiveSurfaceCropAndRefitsEachPreviewWithoutChangingPanelSize() throws {
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
        let ghost = OverviewDragGhost(
            originalFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            ownedWindowRegistry: registry
        )
        defer { ghost.destroy() }
        let cropped = try makeOverviewPreviewFrame(
            width: 200,
            height: 100,
            contentRect: CGRect(x: 25, y: 10, width: 100, height: 50)
        )
        ghost.updatePreview(cropped)

        XCTAssertTrue(ghost.preview === cropped)
        XCTAssertTrue((ghost.thumbnail.contents as? IOSurface) === cropped.surface)
        XCTAssertEqual(ghost.thumbnail.contentsRect, CGRect(x: 0.125, y: 0.1, width: 0.5, height: 0.5))
        XCTAssertEqual(ghost.thumbnail.frame, CGRect(x: 0, y: 50, width: 400, height: 200))

        let portrait = try makeOverviewPreviewFrame(width: 100, height: 200)
        ghost.updatePreview(portrait)
        ghost.moveTo(cursorLocation: CGPoint(x: 500, y: 500))

        XCTAssertTrue(ghost.preview === portrait)
        XCTAssertTrue((ghost.thumbnail.contents as? IOSurface) === portrait.surface)
        XCTAssertEqual(ghost.thumbnail.frame, CGRect(x: 125, y: 0, width: 150, height: 300))
        XCTAssertEqual(ghost.frame.size, CGSize(width: 400, height: 300))
        XCTAssertNil(ghost.thumbnail.animationKeys())

        ghost.updatePreview(nil)
        XCTAssertNil(ghost.preview)
        XCTAssertNil(ghost.thumbnail.contents)
        XCTAssertEqual(ghost.thumbnail.frame, CGRect(x: 0, y: 0, width: 400, height: 300))
    }

    func testReplacedPreviewRemainsPinnedUntilLayerTransactionCompletes() async throws {
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
        let ghost = OverviewDragGhost(
            originalFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            ownedWindowRegistry: registry
        )
        defer { ghost.destroy() }
        var first: OverviewPreviewFrame? = try makeOverviewPreviewFrame()
        weak let firstLifetime = first
        ghost.updatePreview(first)
        let replacement = try makeOverviewPreviewFrame(width: 160, height: 120)
        let committed = expectation(description: "Replacement layer transaction completed")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { committed.fulfill() }
        ghost.updatePreview(replacement)
        first = nil
        XCTAssertNotNil(firstLifetime)
        CATransaction.commit()
        CATransaction.flush()

        await fulfillment(of: [committed], timeout: 2)
        XCTAssertNil(firstLifetime)
        XCTAssertTrue(ghost.preview === replacement)
    }

    func testDestroyRetiresPreviewAndIgnoresLateUpdatesIdempotently() throws {
        let scene = SurfaceScene()
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator(scene: scene))
        let ghost = OverviewDragGhost(
            originalFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            ownedWindowRegistry: registry
        )
        ghost.updatePreview(try makeOverviewPreviewFrame())
        ghost.destroy()
        let retiredFrame = ghost.frame
        ghost.destroy()
        ghost.updatePreview(try makeOverviewPreviewFrame())
        ghost.moveTo(cursorLocation: CGPoint(x: 2000, y: 2000))

        XCTAssertNil(ghost.preview)
        XCTAssertNil(ghost.thumbnail.contents)
        XCTAssertEqual(ghost.frame, retiredFrame)
        XCTAssertFalse(ghost.isVisible)
        XCTAssertFalse(registry.contains(window: ghost))
        XCTAssertEqual(scene.runtimeSnapshot().total, 0)
        XCTAssertEqual(scene.runtimeSnapshot().orphanReverseEntries, 0)
    }
}
