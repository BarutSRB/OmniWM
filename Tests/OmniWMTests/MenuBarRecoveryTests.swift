import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private func makeMenuBarRecoveryDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.menubar.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeBarSettings(
    notchAware: Bool = true,
    position: WorkspaceBarPosition = .overlappingMenuBar,
    reserveLayoutSpace: Bool = false,
    height: Double = 24,
    xOffset: Double = 0,
    yOffset: Double = 0
) -> ResolvedBarSettings {
    ResolvedBarSettings(
        enabled: true,
        showLabels: true,
        showFloatingWindows: false,
        deduplicateAppIcons: false,
        hideEmptyWorkspaces: false,
        reserveLayoutSpace: reserveLayoutSpace,
        notchAware: notchAware,
        position: position,
        windowLevel: .popup,
        height: height,
        backgroundOpacity: 0.1,
        xOffset: xOffset,
        yOffset: yOffset
    )
}

private func makeMonitorForBarTests(hasNotch: Bool) -> Monitor {
    Monitor(
        id: Monitor.ID(displayId: 1),
        displayId: 1,
        frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 772),
        hasNotch: hasNotch,
        name: "Test Display"
    )
}

@Suite struct HiddenBarControllerHelperTests {
    @Test func boundedCollapseLengthClampsExpectedRange() {
        #expect(HiddenBarController.boundedCollapseLength(screenWidth: nil) == 1928)
        #expect(HiddenBarController.boundedCollapseLength(screenWidth: 200) == 500)
        #expect(HiddenBarController.boundedCollapseLength(screenWidth: 1200) == 1400)
        #expect(HiddenBarController.boundedCollapseLength(screenWidth: 5000) == 4000)
    }

    @Test func canCollapseSafelyUsesNormalizedScreenSpaceOrdering() {
        #expect(HiddenBarController.canCollapseSafely(omniMinX: 200, separatorMinX: 100, layoutDirection: .leftToRight))
        #expect(!HiddenBarController.canCollapseSafely(omniMinX: 100, separatorMinX: 200, layoutDirection: .leftToRight))
        #expect(HiddenBarController.canCollapseSafely(omniMinX: 100, separatorMinX: 200, layoutDirection: .rightToLeft))
        #expect(!HiddenBarController.canCollapseSafely(omniMinX: 200, separatorMinX: 100, layoutDirection: .rightToLeft))
        #expect(!HiddenBarController.canCollapseSafely(omniMinX: nil, separatorMinX: 100, layoutDirection: .leftToRight))
    }
}

@Suite struct StatusBarControllerHelperTests {
    @Test func clearOwnedPreferredPositionsRemovesOnlyOmniItems() {
        let defaults = makeMenuBarRecoveryDefaults()
        let mainKey = "NSStatusItem Preferred Position \(StatusBarController.mainAutosaveName)"
        let separatorKey = "NSStatusItem Preferred Position \(HiddenBarController.separatorAutosaveName)"
        let thirdPartyKey = "NSStatusItem Preferred Position third_party"

        defaults.set(11, forKey: mainKey)
        defaults.set(12, forKey: separatorKey)
        defaults.set(42, forKey: thirdPartyKey)

        StatusBarController.clearOwnedPreferredPositions(defaults: defaults)

        #expect(defaults.object(forKey: mainKey) == nil)
        #expect(defaults.object(forKey: separatorKey) == nil)
        #expect(defaults.integer(forKey: thirdPartyKey) == 42)
    }
}

@Suite struct WorkspaceBarManagerPlacementTests {
    @Test func notchAwareOverlappingBarFallsBelowMenuBarAtRuntime() {
        let monitor = makeMonitorForBarTests(hasNotch: true)
        let frame = WorkspaceBarManager.barFrame(
            fittingWidth: 340,
            monitor: monitor,
            resolved: makeBarSettings(notchAware: true, position: .overlappingMenuBar),
            menuBarHeight: 28
        )

        #expect(frame.minX == 330)
        #expect(frame.minY == 744)
        #expect(frame.width == 340)
        #expect(frame.height == 28)
    }

    @Test func notchDisabledKeepsOverlappingPlacementOnNotchedDisplays() {
        let monitor = makeMonitorForBarTests(hasNotch: true)
        let frame = WorkspaceBarManager.barFrame(
            fittingWidth: 340,
            monitor: monitor,
            resolved: makeBarSettings(notchAware: false, position: .overlappingMenuBar),
            menuBarHeight: 28
        )

        #expect(frame.minX == 330)
        #expect(frame.minY == 772)
    }

    @Test func nonNotchedDisplaysKeepLegacyOverlappingPlacement() {
        let monitor = makeMonitorForBarTests(hasNotch: false)
        let frame = WorkspaceBarManager.barFrame(
            fittingWidth: 340,
            monitor: monitor,
            resolved: makeBarSettings(notchAware: true, position: .overlappingMenuBar),
            menuBarHeight: 28
        )

        #expect(frame.minX == 330)
        #expect(frame.minY == 772)
    }

    @Test func belowMenuBarReservationMatchesEffectiveBarHeight() {
        let monitor = makeMonitorForBarTests(hasNotch: false)
        let inset = WorkspaceBarManager.reservedTopInset(
            for: monitor,
            resolved: makeBarSettings(position: .belowMenuBar, reserveLayoutSpace: true),
            isVisible: true,
            menuBarHeight: 28
        )

        #expect(inset == 28)
    }

    @Test func overlappingPlacementReservesConfiguredHeightWhenMenuBarIsTaller() {
        let monitor = makeMonitorForBarTests(hasNotch: false)
        let inset = WorkspaceBarManager.reservedTopInset(
            for: monitor,
            resolved: makeBarSettings(position: .overlappingMenuBar, reserveLayoutSpace: true),
            isVisible: true,
            menuBarHeight: 28
        )

        #expect(inset == 24)
    }

    @Test func overlappingPlacementReservesConfiguredHeightWhenBarIsTallerThanMenuBar() {
        let monitor = makeMonitorForBarTests(hasNotch: false)
        let inset = WorkspaceBarManager.reservedTopInset(
            for: monitor,
            resolved: makeBarSettings(position: .overlappingMenuBar, reserveLayoutSpace: true, height: 36),
            isVisible: true,
            menuBarHeight: 28
        )

        #expect(inset == 36)
    }

    @Test func notchAwareOverlapReservationUsesRuntimeBelowMenuBarHeight() {
        let monitor = makeMonitorForBarTests(hasNotch: true)
        let inset = WorkspaceBarManager.reservedTopInset(
            for: monitor,
            resolved: makeBarSettings(notchAware: true, position: .overlappingMenuBar, reserveLayoutSpace: true),
            isVisible: true,
            menuBarHeight: 28
        )

        #expect(inset == 28)
    }
}
