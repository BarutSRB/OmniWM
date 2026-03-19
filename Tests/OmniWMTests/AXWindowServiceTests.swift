import ApplicationServices
import CoreGraphics
import Testing

@testable import OmniWM

@Suite struct AXWindowServiceTests {
    @Test func attributeFetchFailureProducesManagedDispositionAndFailureReason() {
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

        #expect(decision.disposition == .managed)
        #expect(decision.reasons == [AXWindowHeuristicReason.attributeFetchFailed])
    }

    @Test func missingFullscreenButtonProducesWeakManagedHint() {
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

        #expect(decision.disposition == .managed)
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

    @Test func fixedSizeStandardWindowDefaultsToFloating() {
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

        #expect(decision.disposition == .floating)
        #expect(decision.reasons == [.fixedSizeWindow])
    }

    @Test func trustedFloatingSubroleDefaultsToFloating() {
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
        #expect(decision.reasons == [.trustedFloatingSubrole])
    }

    @Test func untrustedNonStandardSubroleDefaultsToUnmanaged() {
        let decision = AXWindowService.heuristicDisposition(
            for: AXWindowFacts(
                role: kAXWindowRole as String,
                subrole: "AXWeirdPopover",
                title: "Transient",
                hasCloseButton: true,
                hasFullscreenButton: false,
                fullscreenButtonEnabled: nil,
                hasZoomButton: false,
                hasMinimizeButton: false,
                appPolicy: .regular,
                bundleId: "com.example.popover",
                attributeFetchSucceeded: true
            )
        )

        #expect(decision.disposition == .unmanaged)
        #expect(decision.reasons == [.nonStandardSubrole])
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
