// SPDX-License-Identifier: GPL-2.0-only
import ApplicationServices
import CoreGraphics
import Testing

@testable import OmniWM

@Suite struct AXWindowServiceTests {
    @Test func axWindowRoleIsAcceptedDuringTopLevelEnumeration() {
        #expect(
            AXWindowService.shouldTreatAsTopLevelWindow(
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String
            )
        )
    }

    @Test func emacsLikeStandardSubroleIsAcceptedDuringTopLevelEnumeration() {
        #expect(
            AXWindowService.shouldTreatAsTopLevelWindow(
                role: kAXTextFieldRole as String,
                subrole: kAXStandardWindowSubrole as String
            )
        )
    }

    @Test func missingRoleWithStandardSubroleIsAcceptedDuringTopLevelEnumeration() {
        #expect(
            AXWindowService.shouldTreatAsTopLevelWindow(
                role: nil,
                subrole: kAXStandardWindowSubrole as String
            )
        )
    }

    @Test func nonStandardSubroleWithoutWindowRoleIsRejectedDuringTopLevelEnumeration() {
        #expect(
            !AXWindowService.shouldTreatAsTopLevelWindow(
                role: kAXTextFieldRole as String,
                subrole: "AXDialog"
            )
        )
    }

    @Test func attributeFetchFailureProducesUndecidedDispositionAndFailureReason() {
        let decision = AXWindowService.heuristicDisposition(
            for: AXWindowFacts(
                role: nil,
                subrole: nil,
                title: nil,
                hasCloseButton: false,
                hasFullscreenButton: false,
                fullscreenButtonEnabled: nil,
                hasZoomButton: false,
                hasMinimizeButton: false,
                appPolicy: .regular,
                bundleId: "com.example.app",
                attributeFetchSucceeded: false
            )
        )

        #expect(decision.disposition == .undecided)
        #expect(decision.reasons == [AXWindowHeuristicReason.attributeFetchFailed])
    }

    @Test func missingFullscreenButtonProducesFloatingDisposition() {
        let decision = AXWindowService.heuristicDisposition(
            for: AXWindowFacts(
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "Illustrator",
                hasCloseButton: true,
                hasFullscreenButton: false,
                fullscreenButtonEnabled: nil,
                hasZoomButton: true,
                hasMinimizeButton: true,
                appPolicy: .regular,
                bundleId: "com.adobe.illustrator",
                attributeFetchSucceeded: true
            )
        )

        #expect(decision.disposition == .floating)
        #expect(decision.reasons == [AXWindowHeuristicReason.missingFullscreenButton])
    }

    @Test func enabledFullscreenButtonKeepsStandardWindowTiling() {
        let decision = AXWindowService.heuristicDisposition(
            for: AXWindowFacts(
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "Document",
                hasCloseButton: true,
                hasFullscreenButton: true,
                fullscreenButtonEnabled: true,
                hasZoomButton: true,
                hasMinimizeButton: true,
                appPolicy: .regular,
                bundleId: "com.example.app",
                attributeFetchSucceeded: true
            )
        )

        #expect(decision.disposition == .managed)
        #expect(decision.reasons.isEmpty)
    }

    @Test func heuristicOverrideBypassesRecordedReasons() {
        let decision = AXWindowService.heuristicDisposition(
            for: AXWindowFacts(
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "Document",
                hasCloseButton: true,
                hasFullscreenButton: false,
                fullscreenButtonEnabled: nil,
                hasZoomButton: true,
                hasMinimizeButton: true,
                appPolicy: .regular,
                bundleId: "com.example.app",
                attributeFetchSucceeded: true
            ),
            overriddenWindowType: AXWindowType.tiling
        )

        #expect(decision.disposition == .managed)
        #expect(decision.reasons.isEmpty)
    }

    @Test func fixedSizeStandardWindowNoLongerForcesFloating() {
        let decision = AXWindowService.heuristicDisposition(
            for: AXWindowFacts(
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "Dialog",
                hasCloseButton: true,
                hasFullscreenButton: true,
                fullscreenButtonEnabled: true,
                hasZoomButton: true,
                hasMinimizeButton: true,
                appPolicy: .regular,
                bundleId: "com.example.dialog",
                attributeFetchSucceeded: true
            ),
            sizeConstraints: .fixed(size: CGSize(width: 440, height: 320))
        )

        #expect(decision.disposition == .managed)
        #expect(decision.reasons.isEmpty)
    }

    @Test func nonStandardSubroleDefaultsToFloating() {
        let decision = AXWindowService.heuristicDisposition(
            for: AXWindowFacts(
                role: kAXWindowRole as String,
                subrole: "AXDialog",
                title: "Save",
                hasCloseButton: true,
                hasFullscreenButton: false,
                fullscreenButtonEnabled: nil,
                hasZoomButton: false,
                hasMinimizeButton: false,
                appPolicy: .regular,
                bundleId: "com.example.dialog",
                attributeFetchSucceeded: true
            )
        )

        #expect(decision.disposition == .floating)
        #expect(decision.reasons == [.nonStandardSubrole])
    }

    @Test func noButtonsOnNonStandardSubroleDefaultsToFloating() {
        let decision = AXWindowService.heuristicDisposition(
            for: AXWindowFacts(
                role: kAXWindowRole as String,
                subrole: "AXWeirdPopover",
                title: "Transient",
                hasCloseButton: false,
                hasFullscreenButton: false,
                fullscreenButtonEnabled: nil,
                hasZoomButton: false,
                hasMinimizeButton: false,
                appPolicy: .regular,
                bundleId: "com.example.popover",
                attributeFetchSucceeded: true
            )
        )

        #expect(decision.disposition == .floating)
        #expect(decision.reasons == [.noButtonsOnNonStandardSubrole])
    }

    @Test func fullscreenEntryFromRightColumnUsesPositionThenSize() {
        let current = CGRect(x: 1276, y: 0, width: 1276, height: 1410)
        let target = CGRect(x: 0, y: 0, width: 2560, height: 1410)

        #expect(
            AXWindowService.frameWriteOrder(currentFrame: current, targetFrame: target) == .positionThenSize
        )
    }

    @Test func fullscreenEntryFromLeftColumnUsesPositionThenSize() {
        let current = CGRect(x: 8, y: 0, width: 1276, height: 1410)
        let target = CGRect(x: 0, y: 0, width: 2560, height: 1410)

        #expect(
            AXWindowService.frameWriteOrder(currentFrame: current, targetFrame: target) == .positionThenSize
        )
    }

    @Test func fullscreenEntryFromHalfHeightTileUsesPositionThenSize() {
        let current = CGRect(x: 8, y: 709, width: 1276, height: 701)
        let target = CGRect(x: 0, y: 0, width: 2560, height: 1410)

        #expect(
            AXWindowService.frameWriteOrder(currentFrame: current, targetFrame: target) == .positionThenSize
        )
    }

    @Test func fullscreenExitBackToTileUsesSizeThenPosition() {
        let current = CGRect(x: 0, y: 0, width: 2560, height: 1410)
        let target = CGRect(x: 1276, y: 709, width: 1276, height: 701)

        #expect(
            AXWindowService.frameWriteOrder(currentFrame: current, targetFrame: target) == .sizeThenPosition
        )
    }
}

@Suite @MainActor struct AXWindowTitleCacheTests {
    @Test func titleCacheReusesLookupWithinTTL() async {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        AXWindowService.clearTitleCacheForTests()
        defer {
            AXWindowService.titleLookupProviderForTests = nil
            AXWindowService.timeSourceForTests = nil
            AXWindowService.clearTitleCacheForTests()
        }

        let now: TimeInterval = 10
        var lookups: [UInt32] = []
        AXWindowService.timeSourceForTests = { now }
        AXWindowService.titleLookupProviderForTests = { windowId in
            lookups.append(windowId)
            return "Window \(windowId)"
        }

        #expect(AXWindowService.titlePreferFast(windowId: 12) == "Window 12")
        #expect(AXWindowService.titlePreferFast(windowId: 12) == "Window 12")
        #expect(lookups == [12])
    }

    @Test func titleCacheRefreshesAfterTTLExpires() async {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        AXWindowService.clearTitleCacheForTests()
        defer {
            AXWindowService.titleLookupProviderForTests = nil
            AXWindowService.timeSourceForTests = nil
            AXWindowService.clearTitleCacheForTests()
        }

        var now: TimeInterval = 20
        var lookupCount = 0
        AXWindowService.timeSourceForTests = { now }
        AXWindowService.titleLookupProviderForTests = { _ in
            lookupCount += 1
            return "Title \(lookupCount)"
        }

        #expect(AXWindowService.titlePreferFast(windowId: 24) == "Title 1")
        now += 30.1
        #expect(AXWindowService.titlePreferFast(windowId: 24) == "Title 2")
        #expect(lookupCount == 2)
    }

    @Test func titleCacheStoresNilResultsWithinTTL() async {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        AXWindowService.clearTitleCacheForTests()
        defer {
            AXWindowService.titleLookupProviderForTests = nil
            AXWindowService.timeSourceForTests = nil
            AXWindowService.clearTitleCacheForTests()
        }

        let now: TimeInterval = 30
        var lookupCount = 0
        AXWindowService.timeSourceForTests = { now }
        AXWindowService.titleLookupProviderForTests = { _ in
            lookupCount += 1
            return nil
        }

        #expect(AXWindowService.titlePreferFast(windowId: 36) == nil)
        #expect(AXWindowService.titlePreferFast(windowId: 36) == nil)
        #expect(lookupCount == 1)
    }

    @Test func explicitTitleInvalidationForcesReload() async {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        AXWindowService.clearTitleCacheForTests()
        defer {
            AXWindowService.titleLookupProviderForTests = nil
            AXWindowService.timeSourceForTests = nil
            AXWindowService.clearTitleCacheForTests()
        }

        let now: TimeInterval = 40
        var lookupCount = 0
        AXWindowService.timeSourceForTests = { now }
        AXWindowService.titleLookupProviderForTests = { _ in
            lookupCount += 1
            return "Lookup \(lookupCount)"
        }

        #expect(AXWindowService.titlePreferFast(windowId: 48) == "Lookup 1")
        AXWindowService.invalidateCachedTitle(windowId: 48)
        #expect(AXWindowService.titlePreferFast(windowId: 48) == "Lookup 2")
        #expect(lookupCount == 2)
    }
}
