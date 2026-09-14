// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class SplitNodeGeometryTests: XCTestCase {
    func testNestedGeometryPreservesLeafIdentityAndDividerAddressOrder() {
        let views = (0 ..< 4).map { _ in GhosttySurfaceView(occlusionHandlerForTests: { _ in }) }
        let tree = SplitNode.split(
            .horizontal,
            0.5,
            .split(.vertical, 0.25, .leaf(views[0]), .leaf(views[1])),
            .split(.vertical, 0.75, .leaf(views[2]), .leaf(views[3]))
        )
        let rect = CGRect(x: 10, y: 20, width: 800, height: 400)
        let bounds = tree.calculateBounds(in: rect)
        XCTAssertEqual(bounds.count, 4)
        for (actual, expected) in zip(bounds, views) {
            XCTAssertTrue(actual.view === expected)
        }
        XCTAssertEqual(bounds.map(\.rect), [
            CGRect(x: 10, y: 320, width: 400, height: 100),
            CGRect(x: 10, y: 20, width: 400, height: 300),
            CGRect(x: 410, y: 120, width: 400, height: 300),
            CGRect(x: 410, y: 20, width: 400, height: 100)
        ])
        let dividers = tree.calculateDividers(in: rect, visibleThickness: 2, hitThickness: 8, address: [.right])
        XCTAssertEqual(dividers.map(\.address), [[.right], [.right, .left], [.right, .right]])
        XCTAssertEqual(dividers.map(\.direction), [.horizontal, .vertical, .vertical])
        XCTAssertEqual(dividers.map(\.visibleRect), [
            CGRect(x: 409, y: 20, width: 2, height: 400),
            CGRect(x: 10, y: 319, width: 400, height: 2),
            CGRect(x: 410, y: 119, width: 400, height: 2)
        ])
        XCTAssertEqual(dividers.map(\.hitRect), [
            CGRect(x: 406, y: 20, width: 8, height: 400),
            CGRect(x: 10, y: 316, width: 400, height: 8),
            CGRect(x: 410, y: 116, width: 400, height: 8)
        ])
    }

    func testRatioClampingPreservesFractionalBoundsInBothDirections() {
        let first = GhosttySurfaceView(occlusionHandlerForTests: { _ in })
        let second = GhosttySurfaceView(occlusionHandlerForTests: { _ in })
        let rect = CGRect(x: 1.25, y: -2.5, width: 125, height: 75)
        let cases: [(SplitNode, [CGRect])] = [
            (.split(.horizontal, -2, .leaf(first), .leaf(second)), [
                CGRect(x: 1.25, y: -2.5, width: 12.5, height: 75),
                CGRect(x: 13.75, y: -2.5, width: 112.5, height: 75)
            ]),
            (.split(.horizontal, 2, .leaf(first), .leaf(second)), [
                CGRect(x: 1.25, y: -2.5, width: 112.5, height: 75),
                CGRect(x: 113.75, y: -2.5, width: 12.5, height: 75)
            ]),
            (.split(.vertical, -2, .leaf(first), .leaf(second)), [
                CGRect(x: 1.25, y: 65, width: 125, height: 7.5),
                CGRect(x: 1.25, y: -2.5, width: 125, height: 67.5)
            ]),
            (.split(.vertical, 2, .leaf(first), .leaf(second)), [
                CGRect(x: 1.25, y: 5, width: 125, height: 67.5),
                CGRect(x: 1.25, y: -2.5, width: 125, height: 7.5)
            ])
        ]
        for (tree, expected) in cases {
            XCTAssertEqual(tree.calculateBounds(in: rect).map(\.rect), expected)
        }
    }

    func testNegativeDimensionsPreserveOriginalSplitCoordinates() {
        let first = GhosttySurfaceView(occlusionHandlerForTests: { _ in })
        let second = GhosttySurfaceView(occlusionHandlerForTests: { _ in })
        let rect = CGRect(x: 100, y: 200, width: -800, height: -400)
        let horizontal = SplitNode.split(.horizontal, 0.25, .leaf(first), .leaf(second))
        let vertical = SplitNode.split(.vertical, 0.25, .leaf(first), .leaf(second))
        XCTAssertEqual(horizontal.calculateBounds(in: rect).map(\.rect), [
            CGRect(x: -700, y: -200, width: 200, height: 400),
            CGRect(x: -500, y: -200, width: 600, height: 400)
        ])
        XCTAssertEqual(vertical.calculateBounds(in: rect).map(\.rect), [
            CGRect(x: -700, y: 100, width: 800, height: 100),
            CGRect(x: -700, y: -200, width: 800, height: 300)
        ])
        let horizontalDividers = horizontal.calculateDividers(in: rect, visibleThickness: 2, hitThickness: 8)
        XCTAssertEqual(horizontalDividers.map(\.visibleRect), [CGRect(x: -501, y: -200, width: 2, height: 400)])
        XCTAssertEqual(horizontalDividers.map(\.hitRect), [CGRect(x: -504, y: -200, width: 8, height: 400)])
        let verticalDividers = vertical.calculateDividers(in: rect, visibleThickness: 2, hitThickness: 8)
        XCTAssertEqual(verticalDividers.map(\.visibleRect), [CGRect(x: -700, y: 99, width: 800, height: 2)])
        XCTAssertEqual(verticalDividers.map(\.hitRect), [CGRect(x: -700, y: 96, width: 800, height: 8)])
    }

    func testLeafPreservesIdentityAndRawNonFiniteRectangleWithoutDividers() throws {
        let view = GhosttySurfaceView(occlusionHandlerForTests: { _ in })
        let leaf = SplitNode.leaf(view)
        let rect = CGRect(x: CGFloat.nan, y: -CGFloat.infinity, width: -0.0, height: CGFloat.infinity)
        let bounds = leaf.calculateBounds(in: rect)
        XCTAssertEqual(bounds.count, 1)
        let result = try XCTUnwrap(bounds.first)
        XCTAssertTrue(result.view === view)
        XCTAssertEqual(componentBits(result.rect), componentBits(rect))
        XCTAssertTrue(leaf.calculateDividers(in: rect, visibleThickness: 2, hitThickness: 8).isEmpty)
    }

    private func componentBits(_ rect: CGRect) -> [UInt64] {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].map { Double($0).bitPattern }
    }
}
