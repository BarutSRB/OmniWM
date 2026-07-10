// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class QuakeClipboardPromptTests: XCTestCase {
    private final class AttachmentFlag {
        var value = true
    }

    func testCompletionResolvesOnceAndSecondResolutionIsNoOp() {
        let coordinator = QuakeClipboardPromptCoordinator()
        let origin = NSObject()
        var completion: (@MainActor (Bool) -> Void)?
        var resolutions: [Bool] = []

        coordinator.request(
            origin: origin,
            isOriginAttached: { true },
            present: { completion = $0 },
            dismiss: {},
            resolve: { resolutions.append($0) }
        )

        XCTAssertTrue(coordinator.hasActivePrompt)
        completion?(true)
        completion?(true)
        XCTAssertEqual(resolutions, [true])
        XCTAssertFalse(coordinator.hasActivePrompt)
    }

    func testSecondRequestWhileActiveIsDeniedImmediately() {
        let coordinator = QuakeClipboardPromptCoordinator()
        var firstCompletion: (@MainActor (Bool) -> Void)?
        var firstResolutions: [Bool] = []
        var secondPresented = false
        var secondResolutions: [Bool] = []

        coordinator.request(
            origin: NSObject(),
            isOriginAttached: { true },
            present: { firstCompletion = $0 },
            dismiss: {},
            resolve: { firstResolutions.append($0) }
        )
        coordinator.request(
            origin: NSObject(),
            isOriginAttached: { true },
            present: { _ in secondPresented = true },
            dismiss: {},
            resolve: { secondResolutions.append($0) }
        )

        XCTAssertFalse(secondPresented)
        XCTAssertEqual(secondResolutions, [false])
        XCTAssertEqual(firstResolutions, [])
        XCTAssertTrue(coordinator.hasActivePrompt)

        firstCompletion?(true)
        XCTAssertEqual(firstResolutions, [true])
        XCTAssertEqual(secondResolutions, [false])
    }

    func testCancelForOriginDismissesAndResolvesDenyExactlyOnce() {
        let coordinator = QuakeClipboardPromptCoordinator()
        let origin = NSObject()
        var completion: (@MainActor (Bool) -> Void)?
        var dismissCount = 0
        var resolutions: [Bool] = []

        coordinator.request(
            origin: origin,
            isOriginAttached: { true },
            present: { completion = $0 },
            dismiss: { dismissCount += 1 },
            resolve: { resolutions.append($0) }
        )
        coordinator.cancelPrompt(for: origin)

        XCTAssertEqual(dismissCount, 1)
        XCTAssertEqual(resolutions, [false])
        XCTAssertFalse(coordinator.hasActivePrompt)

        completion?(true)
        coordinator.cancelPrompt(for: origin)
        coordinator.cancelActivePrompt()
        XCTAssertEqual(dismissCount, 1)
        XCTAssertEqual(resolutions, [false])
    }

    func testCancelForDifferentOriginKeepsPromptActive() {
        let coordinator = QuakeClipboardPromptCoordinator()
        let promptOrigin = NSObject()
        let otherOrigin = NSObject()
        var dismissCount = 0
        var resolutions: [Bool] = []

        coordinator.request(
            origin: promptOrigin,
            isOriginAttached: { true },
            present: { _ in },
            dismiss: { dismissCount += 1 },
            resolve: { resolutions.append($0) }
        )
        coordinator.cancelPrompt(for: otherOrigin)

        XCTAssertTrue(coordinator.hasActivePrompt)
        XCTAssertEqual(dismissCount, 0)
        XCTAssertEqual(resolutions, [])
    }

    func testCancelActivePromptResolvesDenyExactlyOnce() {
        let coordinator = QuakeClipboardPromptCoordinator()
        var completion: (@MainActor (Bool) -> Void)?
        var dismissCount = 0
        var resolutions: [Bool] = []

        coordinator.request(
            origin: NSObject(),
            isOriginAttached: { true },
            present: { completion = $0 },
            dismiss: { dismissCount += 1 },
            resolve: { resolutions.append($0) }
        )
        coordinator.cancelActivePrompt()
        coordinator.cancelActivePrompt()
        completion?(true)

        XCTAssertEqual(dismissCount, 1)
        XCTAssertEqual(resolutions, [false])
        XCTAssertFalse(coordinator.hasActivePrompt)
    }

    func testAllowAfterOriginDetachedResolvesDenyAndSkipsWrite() {
        let coordinator = QuakeClipboardPromptCoordinator()
        let originAttached = AttachmentFlag()
        var completion: (@MainActor (Bool) -> Void)?
        var appliedWrites = 0
        var resolutions: [Bool] = []

        coordinator.request(
            origin: NSObject(),
            isOriginAttached: { originAttached.value },
            present: { completion = $0 },
            dismiss: {},
            resolve: { allowed in
                resolutions.append(allowed)
                if allowed {
                    appliedWrites += 1
                }
            }
        )
        originAttached.value = false
        completion?(true)

        XCTAssertEqual(resolutions, [false])
        XCTAssertEqual(appliedWrites, 0)
        XCTAssertFalse(coordinator.hasActivePrompt)
    }

    func testRequestWithDetachedOriginIsDeniedWithoutPresenting() {
        let coordinator = QuakeClipboardPromptCoordinator()
        var presented = false
        var resolutions: [Bool] = []

        coordinator.request(
            origin: NSObject(),
            isOriginAttached: { false },
            present: { _ in presented = true },
            dismiss: {},
            resolve: { resolutions.append($0) }
        )

        XCTAssertFalse(presented)
        XCTAssertEqual(resolutions, [false])
        XCTAssertFalse(coordinator.hasActivePrompt)
    }

    func testNewRequestPresentsAfterPriorResolution() {
        let coordinator = QuakeClipboardPromptCoordinator()
        var firstCompletion: (@MainActor (Bool) -> Void)?
        var secondPresented = false
        var secondResolutions: [Bool] = []

        coordinator.request(
            origin: NSObject(),
            isOriginAttached: { true },
            present: { firstCompletion = $0 },
            dismiss: {},
            resolve: { _ in }
        )
        firstCompletion?(false)
        coordinator.request(
            origin: NSObject(),
            isOriginAttached: { true },
            present: { _ in secondPresented = true },
            dismiss: {},
            resolve: { secondResolutions.append($0) }
        )

        XCTAssertTrue(secondPresented)
        XCTAssertTrue(coordinator.hasActivePrompt)
        XCTAssertEqual(secondResolutions, [])
    }

    func testClipboardPromptDefaultsToDeny() {
        for kind in [QuakeTerminalController.ClipboardPromptKind.read, .write, .unsafePaste] {
            let alert = QuakeTerminalController.protectedClipboardAlert(kind: kind, contents: "payload")
            XCTAssertEqual(alert.buttons.first?.title, "Deny")
            XCTAssertEqual(alert.buttons.first?.keyEquivalent, "\r")
            XCTAssertEqual(alert.buttons.last?.title, "Allow")
        }
    }

    func testClipboardPromptResponseMapsSecondButtonToAllow() {
        XCTAssertFalse(QuakeTerminalController.clipboardPromptResponseAllows(.alertFirstButtonReturn))
        XCTAssertTrue(QuakeTerminalController.clipboardPromptResponseAllows(.alertSecondButtonReturn))
        XCTAssertFalse(QuakeTerminalController.clipboardPromptResponseAllows(.cancel))
    }
}
