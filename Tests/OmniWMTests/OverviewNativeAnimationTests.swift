// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class OverviewNativeAnimationTests: XCTestCase {
    func testNativeTransitionPreservesAcceptedCriticalSpringTrajectory() {
        let transition = OverviewNativeTransition(generation: 1, startTime: 100, from: 0, to: 1)
        let reference = SpringAnimation(from: 0, to: 1, startTime: 100, config: .balanced)

        for elapsed in [0.0, 0.01, 0.04, 0.1, 0.2] {
            XCTAssertEqual(
                transition.value(at: 100 + elapsed),
                reference.value(at: 100 + elapsed),
                accuracy: 0.000000001
            )
            XCTAssertEqual(
                transition.velocity(at: 100 + elapsed),
                reference.velocity(at: 100 + elapsed),
                accuracy: 0.000000001
            )
        }
        let animation = transition.makeAnimation(keyPath: "position")
        XCTAssertEqual(animation.mass, 1)
        XCTAssertEqual(animation.stiffness, SpringConfig.balanced.stiffness)
        XCTAssertEqual(animation.damping, 2 * sqrt(animation.stiffness))
        XCTAssertEqual(animation.beginTime, 100)
        XCTAssertEqual(animation.duration, animation.settlingDuration)
    }

    func testNativeReversalPreservesCurrentProgressAndVelocity() {
        let opening = OverviewNativeTransition(generation: 1, startTime: 100, from: 0, to: 1)
        let reversedAt = 100.06
        let closing = OverviewNativeTransition(
            generation: 2,
            startTime: reversedAt,
            from: opening.value(at: reversedAt),
            to: 0,
            initialVelocity: opening.velocity(at: reversedAt)
        )

        XCTAssertEqual(closing.value(at: reversedAt), opening.value(at: reversedAt), accuracy: 0.000000001)
        XCTAssertEqual(closing.velocity(at: reversedAt), opening.velocity(at: reversedAt), accuracy: 0.000000001)
        XCTAssertLessThan(closing.makeAnimation(keyPath: "opacity").initialVelocity, 0)
        XCTAssertEqual(closing.value(at: reversedAt + closing.duration + 1), 0)
        XCTAssertEqual(closing.velocity(at: reversedAt + closing.duration + 1), 0)
    }

    func testAlreadySettledTransitionHasNoDurationOrResidualVelocity() {
        let transition = OverviewNativeTransition(generation: 1, startTime: 100, from: 1, to: 1)

        XCTAssertEqual(transition.duration, 0)
        XCTAssertEqual(transition.value(at: 100), 1)
        XCTAssertEqual(transition.velocity(at: 100), 0)
    }

    func testNativeLayerMotionCommitsFinalModelAndAnimatesFromCapturedGeometry() throws {
        let layer = CALayer()
        layer.position = CGPoint(x: 400, y: 300)
        layer.bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        layer.opacity = 0
        let captured = OverviewLayerMotion(layer)
        let transition = OverviewNativeTransition(generation: 1, startTime: 100, from: 0, to: 1)
        let destination = CGPoint(x: 200, y: 200)
        let destinationBounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        layer.position = destination
        layer.bounds = destinationBounds
        layer.opacity = 1

        captured.apply(transition, at: 100, replacing: true)

        let position = try XCTUnwrap(layer.animation(forKey: "overview.position") as? CASpringAnimation)
        let bounds = try XCTUnwrap(layer.animation(forKey: "overview.bounds") as? CASpringAnimation)
        let opacity = try XCTUnwrap(layer.animation(forKey: "overview.opacity") as? CASpringAnimation)
        XCTAssertEqual((position.fromValue as? NSValue)?.pointValue, CGPoint(x: 400, y: 300))
        XCTAssertEqual((position.toValue as? NSValue)?.pointValue, destination)
        XCTAssertEqual((bounds.fromValue as? NSValue)?.rectValue, CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual((bounds.toValue as? NSValue)?.rectValue, destinationBounds)
        XCTAssertEqual((opacity.fromValue as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual((opacity.toValue as? NSNumber)?.doubleValue, 1)
        XCTAssertEqual(layer.position, destination)
        XCTAssertEqual(layer.bounds, destinationBounds)
        XCTAssertEqual(layer.opacity, 1)
        XCTAssertEqual(position.beginTime + position.duration, transition.startTime + transition.duration)
    }

    func testLateGeometryRerouteKeepsFiniteEndpointsAndOriginalDeadline() throws {
        let layer = CALayer()
        let current = CGPoint(x: 400, y: 300)
        let destination = CGPoint(x: -700, y: 1000)
        layer.position = current
        layer.bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let captured = OverviewLayerMotion(layer)
        let transition = OverviewNativeTransition(generation: 1, startTime: 100, from: 0, to: 1)
        let deadline = transition.startTime + transition.duration
        let eventTime = deadline - 0.001
        layer.position = destination

        captured.apply(transition, at: eventTime, replacing: false)

        let position = try XCTUnwrap(layer.animation(forKey: "overview.position") as? CASpringAnimation)
        XCTAssertEqual((position.fromValue as? NSValue)?.pointValue, current)
        XCTAssertEqual((position.toValue as? NSValue)?.pointValue, destination)
        XCTAssertEqual(position.beginTime, eventTime)
        XCTAssertEqual(position.beginTime + position.duration, deadline, accuracy: 0.000000001)
        XCTAssertGreaterThan(position.stiffness, transition.makeAnimation(keyPath: "position").stiffness)
        XCTAssertTrue(position.stiffness.isFinite)
        XCTAssertTrue(position.damping.isFinite)
        XCTAssertEqual(position.initialVelocity, 0)
        XCTAssertNil(layer.animation(forKey: "overview.bounds"))

        let settled = OverviewLayerMotion(layer)
        layer.position = .zero
        settled.apply(transition, at: deadline, replacing: false)
        XCTAssertNil(layer.animation(forKey: "overview.position"))
        XCTAssertEqual(layer.position, .zero)
    }

    func testReversalBeforeFirstLayerCommitPreservesUnpresentedStartGeometry() throws {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let layer = CALayer()
        let initialPosition = CGPoint(x: 10, y: 20)
        let initialBounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        layer.position = initialPosition
        layer.bounds = initialBounds
        layer.opacity = 0
        let now = CACurrentMediaTime()
        let initial = OverviewLayerMotion(layer)
        let opening = OverviewNativeTransition(generation: 1, startTime: now, from: 0, to: 1)
        layer.position = CGPoint(x: 100, y: 200)
        layer.bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        layer.opacity = 1
        initial.apply(opening, at: now, replacing: true)
        XCTAssertNil(layer.presentation())

        let reversed = OverviewLayerMotion(layer)
        layer.position = CGPoint(x: 30, y: 40)
        layer.bounds = CGRect(x: 0, y: 0, width: 700, height: 500)
        layer.opacity = 0.25
        let closing = OverviewNativeTransition(generation: 2, startTime: now, from: 1, to: 0)
        reversed.apply(closing, at: now, replacing: true)

        let position = try XCTUnwrap(layer.animation(forKey: "overview.position") as? CASpringAnimation)
        let bounds = try XCTUnwrap(layer.animation(forKey: "overview.bounds") as? CASpringAnimation)
        let opacity = try XCTUnwrap(layer.animation(forKey: "overview.opacity") as? CASpringAnimation)
        XCTAssertEqual((position.fromValue as? NSValue)?.pointValue, initialPosition)
        XCTAssertEqual((bounds.fromValue as? NSValue)?.rectValue, initialBounds)
        XCTAssertEqual((opacity.fromValue as? NSNumber)?.doubleValue, 0)
    }
}
