// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class HiddenBarActivationResolveTests: XCTestCase {
    private let bundleID = "com.example.status"

    private func key(_ ordinal: Int) -> MenuBarItemKey {
        MenuBarItemKey(bundleID: bundleID, ordinal: ordinal)
    }

    private func identity(_ value: String) -> MenuBarItemSemanticIdentity {
        MenuBarItemSemanticIdentity(
            identifier: value,
            title: nil,
            accessibilityDescription: nil,
            help: nil
        )
    }

    private func item(
        ordinal: Int,
        pid: pid_t = 1234,
        identity: MenuBarItemSemanticIdentity? = nil
    ) -> ResolvedMenuBarItem {
        ResolvedMenuBarItem(
            key: key(ordinal),
            pid: pid,
            bounds: CGRect(x: CGFloat(ordinal) * 30, y: 0, width: 24, height: 24),
            semanticIdentity: identity
        )
    }

    private func icon(red: CGFloat, green: CGFloat = 0) -> CapturedIcon {
        let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: red, green: green, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return CapturedIcon(image: context.makeImage()!, scale: 2)
    }

    func testMissingCachedIdentityRejectsActivation() {
        XCTAssertNil(HiddenBarController.activationTarget(
            for: key(0),
            cachedItems: nil,
            cachedIcons: [:],
            freshItems: [item(ordinal: 0, identity: identity("a"))],
            freshIcons: [:]
        ))
    }

    func testAuthoritativeEmptyResolutionRejectsActivation() {
        XCTAssertNil(HiddenBarController.activationTarget(
            for: key(0),
            cachedItems: [item(ordinal: 0, identity: identity("a"))],
            cachedIcons: [:],
            freshItems: [],
            freshIcons: [:]
        ))
    }

    func testAuthoritativeEmptyRequiresResolutionDeadlineGrace() {
        XCTAssertFalse(MenuBarItemLocator.shouldAcceptAuthoritativeEmpty(
            continuouslyEmptyFor: .milliseconds(50)
        ))
        XCTAssertFalse(MenuBarItemLocator.shouldAcceptAuthoritativeEmpty(
            continuouslyEmptyFor: .milliseconds(1999)
        ))
        XCTAssertTrue(MenuBarItemLocator.shouldAcceptAuthoritativeEmpty(
            continuouslyEmptyFor: .seconds(2)
        ))
    }

    func testSemanticIdentitySurvivesInsertionBeforeItem() {
        let a = identity("a")
        let cached = [item(ordinal: 0, identity: a), item(ordinal: 1, identity: identity("b"))]
        let fresh = [
            item(ordinal: 0, identity: identity("inserted")),
            item(ordinal: 1, identity: a),
            item(ordinal: 2, identity: identity("b"))
        ]

        XCTAssertEqual(
            HiddenBarController.activationTarget(
                for: key(0),
                cachedItems: cached,
                cachedIcons: [:],
                freshItems: fresh,
                freshIcons: [:]
            )?.key,
            key(1)
        )
    }

    func testSemanticIdentitySurvivesDeletionBeforeItem() {
        let b = identity("b")
        let cached = [item(ordinal: 0, identity: identity("a")), item(ordinal: 1, identity: b)]
        let fresh = [item(ordinal: 0, identity: b)]

        XCTAssertEqual(
            HiddenBarController.activationTarget(
                for: key(1),
                cachedItems: cached,
                cachedIcons: [:],
                freshItems: fresh,
                freshIcons: [:]
            )?.key,
            key(0)
        )
    }

    func testSemanticIdentitySurvivesReorder() {
        let a = identity("a")
        let cached = [item(ordinal: 0, identity: a), item(ordinal: 1, identity: identity("b"))]
        let fresh = [item(ordinal: 0, identity: identity("b")), item(ordinal: 1, identity: a)]

        XCTAssertEqual(
            HiddenBarController.activationTarget(
                for: key(0),
                cachedItems: cached,
                cachedIcons: [:],
                freshItems: fresh,
                freshIcons: [:]
            )?.key,
            key(1)
        )
    }

    func testDuplicateSemanticIdentityRejectsAmbiguousActivation() {
        let duplicate = identity("duplicate")
        XCTAssertNil(HiddenBarController.activationTarget(
            for: key(0),
            cachedItems: [item(ordinal: 0, identity: duplicate)],
            cachedIcons: [:],
            freshItems: [
                item(ordinal: 0, identity: duplicate),
                item(ordinal: 1, identity: duplicate)
            ],
            freshIcons: [:]
        ))
    }

    func testDuplicateCachedSemanticIdentityRejectsAmbiguousActivation() {
        let duplicate = identity("duplicate")
        XCTAssertNil(HiddenBarController.activationTarget(
            for: key(0),
            cachedItems: [
                item(ordinal: 0, identity: duplicate),
                item(ordinal: 1, identity: duplicate)
            ],
            cachedIcons: [:],
            freshItems: [item(ordinal: 0, identity: duplicate)],
            freshIcons: [:]
        ))
    }

    func testSemanticMismatchDoesNotFallBackToMatchingPixels() {
        let red = icon(red: 1)
        XCTAssertNil(HiddenBarController.activationTarget(
            for: key(0),
            cachedItems: [item(ordinal: 0, identity: identity("cached"))],
            cachedIcons: [key(0): red],
            freshItems: [item(ordinal: 0, identity: identity("fresh"))],
            freshIcons: [key(0): icon(red: 1)]
        ))
    }

    func testPixelIdentitySurvivesReorderWithoutAXIdentity() {
        let red = icon(red: 1)
        let green = icon(red: 0, green: 1)
        let cached = [item(ordinal: 0), item(ordinal: 1)]
        let fresh = [item(ordinal: 0), item(ordinal: 1)]

        XCTAssertEqual(
            HiddenBarController.activationTarget(
                for: key(0),
                cachedItems: cached,
                cachedIcons: [key(0): red, key(1): green],
                freshItems: fresh,
                freshIcons: [key(0): green, key(1): red]
            )?.key,
            key(1)
        )
    }

    func testDuplicatePixelIdentityRejectsAmbiguousActivation() {
        let red = icon(red: 1)
        XCTAssertNil(HiddenBarController.activationTarget(
            for: key(0),
            cachedItems: [item(ordinal: 0)],
            cachedIcons: [key(0): red],
            freshItems: [item(ordinal: 0), item(ordinal: 1)],
            freshIcons: [key(0): icon(red: 1), key(1): icon(red: 1)]
        ))
    }

    func testDuplicateCachedPixelIdentityRejectsAmbiguousActivation() {
        let red = icon(red: 1)
        XCTAssertNil(HiddenBarController.activationTarget(
            for: key(0),
            cachedItems: [item(ordinal: 0), item(ordinal: 1)],
            cachedIcons: [key(0): red, key(1): icon(red: 1)],
            freshItems: [item(ordinal: 0)],
            freshIcons: [key(0): icon(red: 1)]
        ))
    }

    func testIncompletePixelSnapshotRejectsActivation() {
        let red = icon(red: 1)
        XCTAssertNil(HiddenBarController.activationTarget(
            for: key(0),
            cachedItems: [item(ordinal: 0), item(ordinal: 1)],
            cachedIcons: [key(0): red],
            freshItems: [item(ordinal: 0), item(ordinal: 1)],
            freshIcons: [key(0): icon(red: 1), key(1): icon(red: 0, green: 1)]
        ))
    }

    func testChangedProcessRejectsActivation() {
        let stableIdentity = identity("a")
        XCTAssertNil(HiddenBarController.activationTarget(
            for: key(0),
            cachedItems: [item(ordinal: 0, identity: stableIdentity)],
            cachedIcons: [:],
            freshItems: [item(ordinal: 0, pid: 5678, identity: stableIdentity)],
            freshIcons: [:]
        ))
    }

    func testActivationOwnerPrefersSelectedCachedPIDAcrossMultipleProcesses() {
        let selected = item(ordinal: 0, pid: 42)
        XCTAssertEqual(
            HiddenBarController.activationOwner(
                bundleID: bundleID,
                selectedItem: selected,
                cachedItems: [selected],
                runningCandidates: [
                    MenuBarAppCandidate(bundleID: bundleID, pid: 41, name: "Helper"),
                    MenuBarAppCandidate(bundleID: bundleID, pid: 42, name: "Owner")
                ]
            ),
            HiddenBarActivationOwner(pid: 42, allowsAuthoritativeEmpty: true)
        )
    }

    func testActivationOwnerRejectsAmbiguousUncachedProcesses() {
        XCTAssertNil(HiddenBarController.activationOwner(
            bundleID: bundleID,
            selectedItem: nil,
            cachedItems: nil,
            runningCandidates: [
                MenuBarAppCandidate(bundleID: bundleID, pid: 41, name: "Helper"),
                MenuBarAppCandidate(bundleID: bundleID, pid: 42, name: "Owner")
            ]
        ))
    }

    func testActivationOwnerUsesKnownBundlePIDWhenSelectedItemIsMissing() {
        XCTAssertEqual(
            HiddenBarController.activationOwner(
                bundleID: bundleID,
                selectedItem: nil,
                cachedItems: [item(ordinal: 1, pid: 42)],
                runningCandidates: [
                    MenuBarAppCandidate(bundleID: bundleID, pid: 41, name: "Helper"),
                    MenuBarAppCandidate(bundleID: bundleID, pid: 42, name: "Owner")
                ]
            ),
            HiddenBarActivationOwner(pid: 42, allowsAuthoritativeEmpty: true)
        )
    }

    func testSoleUncachedProcessCannotAuthoritativelyClearItems() {
        XCTAssertEqual(
            HiddenBarController.activationOwner(
                bundleID: bundleID,
                selectedItem: nil,
                cachedItems: nil,
                runningCandidates: [
                    MenuBarAppCandidate(bundleID: bundleID, pid: 41, name: "Possible Helper")
                ]
            ),
            HiddenBarActivationOwner(pid: 41, allowsAuthoritativeEmpty: false)
        )
    }

    func testStaleCachedOwnerDoesNotFallBackToAnotherProcess() {
        XCTAssertNil(HiddenBarController.activationOwner(
            bundleID: bundleID,
            selectedItem: nil,
            cachedItems: [item(ordinal: 0, pid: 42)],
            runningCandidates: [
                MenuBarAppCandidate(bundleID: bundleID, pid: 41, name: "Helper")
            ]
        ))
    }

    func testActivationResolveHealsCachedOrdinals() {
        let cache = HiddenBarIconCache()
        cache.replaceResolvedItems([bundleID: [item(ordinal: 0), item(ordinal: 1), item(ordinal: 2)]])
        XCTAssertEqual(cache.resolvedItems(for: bundleID)?.count, 3)

        cache.replaceResolvedItems([bundleID: [item(ordinal: 0), item(ordinal: 1)]])

        let healed = cache.resolvedItems(for: bundleID)
        XCTAssertEqual(healed?.map(\.key.ordinal), [0, 1])
    }
}
