// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private func makeMenuBarRecoveryDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.menubar.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func preferredPositionKey(for autosaveName: String) -> String {
    StatusBarController.preferredPositionKeyForTests(for: autosaveName)
}

private func visibilityKeys(for autosaveName: String) -> [String] {
    StatusBarController.visibilityKeysForTests(for: autosaveName)
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
        yOffset: yOffset,
        accentColorRed: -1,
        accentColorGreen: -1,
        accentColorBlue: -1,
        accentColorAlpha: 1,
        textColorRed: -1,
        textColorGreen: -1,
        textColorBlue: -1,
        textColorAlpha: 1,
        labelFontSize: 12
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
        let mainKey = preferredPositionKey(for: StatusBarController.mainAutosaveName)
        let separatorKey = preferredPositionKey(for: HiddenBarController.separatorAutosaveName)
        let thirdPartyKey = preferredPositionKey(for: "third_party")

        defaults.set(11, forKey: mainKey)
        defaults.set(12, forKey: separatorKey)
        defaults.set(42, forKey: thirdPartyKey)

        StatusBarController.clearOwnedPreferredPositions(defaults: defaults)

        #expect(defaults.object(forKey: mainKey) == nil)
        #expect(defaults.object(forKey: separatorKey) == nil)
        #expect(defaults.integer(forKey: thirdPartyKey) == 42)
    }

    @Test func clearOwnedVisibilityPreferencesRemovesOnlyOmniItems() {
        let defaults = makeMenuBarRecoveryDefaults()
        let mainKeys = visibilityKeys(for: StatusBarController.mainAutosaveName)
        let separatorKeys = visibilityKeys(for: HiddenBarController.separatorAutosaveName)
        let thirdPartyKeys = visibilityKeys(for: "third_party")

        for key in mainKeys {
            defaults.set(true, forKey: key)
        }
        for key in separatorKeys {
            defaults.set(false, forKey: key)
        }
        for key in thirdPartyKeys {
            defaults.set(false, forKey: key)
        }

        StatusBarController.clearOwnedVisibilityPreferences(defaults: defaults)

        for key in mainKeys + separatorKeys {
            #expect(defaults.object(forKey: key) == nil)
        }
        for key in thirdPartyKeys {
            #expect(defaults.object(forKey: key) != nil)
            #expect(defaults.bool(forKey: key) == false)
        }
    }

    @Test func clearInvalidOwnedVisibilityPreferencesClearsMainWhenHidden() {
        let defaults = makeMenuBarRecoveryDefaults()
        let mainKeys = visibilityKeys(for: StatusBarController.mainAutosaveName)
        let separatorKeys = visibilityKeys(for: HiddenBarController.separatorAutosaveName)
        let thirdPartyKeys = visibilityKeys(for: "third_party")

        defaults.set(false, forKey: mainKeys[0])
        for key in mainKeys.dropFirst() + separatorKeys + thirdPartyKeys {
            defaults.set(true, forKey: key)
        }

        let didClear = StatusBarController.clearInvalidOwnedVisibilityPreferences(defaults: defaults)

        #expect(didClear)
        for key in mainKeys {
            #expect(defaults.object(forKey: key) == nil)
        }
        for key in separatorKeys + thirdPartyKeys {
            #expect(defaults.bool(forKey: key))
        }
    }

    @Test func clearInvalidOwnedVisibilityPreferencesClearsSeparatorWhenMalformed() {
        let defaults = makeMenuBarRecoveryDefaults()
        let mainKeys = visibilityKeys(for: StatusBarController.mainAutosaveName)
        let separatorKeys = visibilityKeys(for: HiddenBarController.separatorAutosaveName)

        for key in mainKeys + separatorKeys {
            defaults.set(true, forKey: key)
        }
        defaults.set("not a bool", forKey: separatorKeys[1])

        let didClear = StatusBarController.clearInvalidOwnedVisibilityPreferences(defaults: defaults)

        #expect(didClear)
        for key in mainKeys {
            #expect(defaults.bool(forKey: key))
        }
        for key in separatorKeys {
            #expect(defaults.object(forKey: key) == nil)
        }
    }

    @Test func clearInvalidOwnedVisibilityPreferencesPreservesValidAndAbsentValues() {
        let defaults = makeMenuBarRecoveryDefaults()
        let mainKeys = visibilityKeys(for: StatusBarController.mainAutosaveName)
        let separatorKeys = visibilityKeys(for: HiddenBarController.separatorAutosaveName)

        defaults.set(true, forKey: mainKeys[0])
        defaults.set(true, forKey: separatorKeys[2])

        let didClear = StatusBarController.clearInvalidOwnedVisibilityPreferences(defaults: defaults)

        #expect(!didClear)
        #expect(defaults.bool(forKey: mainKeys[0]))
        #expect(defaults.bool(forKey: separatorKeys[2]))
        #expect(defaults.object(forKey: mainKeys[1]) == nil)
        #expect(defaults.object(forKey: separatorKeys[0]) == nil)
    }

    @Test func storedVisibilityPreferenceRejectsNumericJunk() {
        #expect(StatusBarController.storedVisibilityPreferenceIsVisible(nil))
        #expect(StatusBarController.storedVisibilityPreferenceIsVisible(true))
        #expect(!StatusBarController.storedVisibilityPreferenceIsVisible(false))
        #expect(!StatusBarController.storedVisibilityPreferenceIsVisible(1))
    }

    @Test func preferredPositionVisibilityUsesGlobalScreenXRanges() {
        let screenFrames = [
            CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 0, width: 1440, height: 900)
        ]

        #expect(StatusBarController.preferredPositionXIsVisible(-1920, screenFrames: screenFrames))
        #expect(StatusBarController.preferredPositionXIsVisible(-1, screenFrames: screenFrames))
        #expect(StatusBarController.preferredPositionXIsVisible(0, screenFrames: screenFrames))
        #expect(StatusBarController.preferredPositionXIsVisible(1439, screenFrames: screenFrames))
        #expect(!StatusBarController.preferredPositionXIsVisible(-1921, screenFrames: screenFrames))
        #expect(!StatusBarController.preferredPositionXIsVisible(1440, screenFrames: screenFrames))
    }

    @Test func storedPreferredPositionVisibilityIsNoOpWhenAbsentOrScreensUnavailable() {
        let screenFrames = [CGRect(x: 0, y: 0, width: 1440, height: 900)]

        #expect(StatusBarController.storedPreferredPositionIsVisible(nil, screenFrames: screenFrames))
        #expect(StatusBarController.storedPreferredPositionIsVisible(9999, screenFrames: []))
    }

    @Test func clearInvalidOwnedPreferredPositionsClearsOwnedKeysWhenMainIsOffscreen() {
        let defaults = makeMenuBarRecoveryDefaults()
        let mainKey = preferredPositionKey(for: StatusBarController.mainAutosaveName)
        let separatorKey = preferredPositionKey(for: HiddenBarController.separatorAutosaveName)
        let thirdPartyKey = preferredPositionKey(for: "third_party")

        defaults.set(2756, forKey: mainKey)
        defaults.set(498, forKey: separatorKey)
        defaults.set(42, forKey: thirdPartyKey)

        let didClear = StatusBarController.clearInvalidOwnedPreferredPositions(
            defaults: defaults,
            screenFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        )

        #expect(didClear)
        #expect(defaults.object(forKey: mainKey) == nil)
        #expect(defaults.object(forKey: separatorKey) == nil)
        #expect(defaults.integer(forKey: thirdPartyKey) == 42)
    }

    @Test func clearInvalidOwnedPreferredPositionsClearsOwnedKeysWhenSeparatorIsOffscreen() {
        let defaults = makeMenuBarRecoveryDefaults()
        let mainKey = preferredPositionKey(for: StatusBarController.mainAutosaveName)
        let separatorKey = preferredPositionKey(for: HiddenBarController.separatorAutosaveName)

        defaults.set(900, forKey: mainKey)
        defaults.set(2756, forKey: separatorKey)

        let didClear = StatusBarController.clearInvalidOwnedPreferredPositions(
            defaults: defaults,
            screenFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        )

        #expect(didClear)
        #expect(defaults.object(forKey: mainKey) == nil)
        #expect(defaults.object(forKey: separatorKey) == nil)
    }

    @Test func clearInvalidOwnedPreferredPositionsPreservesValidMultiDisplayPositions() {
        let defaults = makeMenuBarRecoveryDefaults()
        let mainKey = preferredPositionKey(for: StatusBarController.mainAutosaveName)
        let separatorKey = preferredPositionKey(for: HiddenBarController.separatorAutosaveName)
        let screenFrames = [
            CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 0, width: 1440, height: 900)
        ]

        defaults.set(-400, forKey: mainKey)
        defaults.set(498, forKey: separatorKey)

        let didClear = StatusBarController.clearInvalidOwnedPreferredPositions(
            defaults: defaults,
            screenFrames: screenFrames
        )

        #expect(!didClear)
        #expect(defaults.integer(forKey: mainKey) == -400)
        #expect(defaults.integer(forKey: separatorKey) == 498)
    }

    @Test func clearInvalidOwnedPreferredPositionsDoesNotClearWhenScreensUnavailable() {
        let defaults = makeMenuBarRecoveryDefaults()
        let mainKey = preferredPositionKey(for: StatusBarController.mainAutosaveName)
        let separatorKey = preferredPositionKey(for: HiddenBarController.separatorAutosaveName)

        defaults.set(2756, forKey: mainKey)
        defaults.set(498, forKey: separatorKey)

        let didClear = StatusBarController.clearInvalidOwnedPreferredPositions(
            defaults: defaults,
            screenFrames: []
        )

        #expect(!didClear)
        #expect(defaults.integer(forKey: mainKey) == 2756)
        #expect(defaults.integer(forKey: separatorKey) == 498)
    }
}

@Suite(.serialized) @MainActor struct StatusBarAutosaveContractTests {
    @Test func ownedStatusItemsKeepAutosaveNamesForOrderingRecovery() {
        let controller = makeLayoutPlanTestController()
        controller.settings.hiddenBarIsCollapsed = false
        let hiddenBarController = HiddenBarController(settings: controller.settings)
        let statusBarController = StatusBarController(
            settings: controller.settings,
            controller: controller,
            hiddenBarController: hiddenBarController,
            defaults: makeMenuBarRecoveryDefaults()
        )
        controller.statusBarController = statusBarController
        defer { statusBarController.cleanup() }

        statusBarController.setup()

        #expect(statusBarController.statusItemAutosaveNameForTests() == StatusBarController.mainAutosaveName)
        #expect(hiddenBarController.separatorAutosaveNameForTests() == HiddenBarController.separatorAutosaveName)
        #expect(statusBarController.statusItemIsVisibleForTests() == true)
        #expect(hiddenBarController.separatorIsVisibleForTests() == true)
    }

    @Test func setupRepairsHiddenOwnedVisibilityPreferences() {
        let controller = makeLayoutPlanTestController()
        controller.settings.hiddenBarIsCollapsed = false
        let defaults = makeMenuBarRecoveryDefaults()
        let mainKeys = visibilityKeys(for: StatusBarController.mainAutosaveName)
        let separatorKeys = visibilityKeys(for: HiddenBarController.separatorAutosaveName)
        let thirdPartyKeys = visibilityKeys(for: "third_party")
        let hiddenBarController = HiddenBarController(settings: controller.settings)
        let statusBarController = StatusBarController(
            settings: controller.settings,
            controller: controller,
            hiddenBarController: hiddenBarController,
            defaults: defaults
        )
        controller.statusBarController = statusBarController
        defer { statusBarController.cleanup() }

        defaults.set(500, forKey: preferredPositionKey(for: StatusBarController.mainAutosaveName))
        defaults.set(300, forKey: preferredPositionKey(for: HiddenBarController.separatorAutosaveName))
        defaults.set(false, forKey: mainKeys[0])
        defaults.set(false, forKey: separatorKeys[2])
        defaults.set(false, forKey: thirdPartyKeys[0])

        statusBarController.setup()

        #expect(statusBarController.statusItemIsVisibleForTests() == true)
        #expect(hiddenBarController.separatorIsVisibleForTests() == true)
        #expect(defaults.object(forKey: mainKeys[0]) == nil)
        #expect(defaults.object(forKey: separatorKeys[2]) == nil)
        #expect(defaults.object(forKey: thirdPartyKeys[0]) != nil)
        #expect(defaults.bool(forKey: thirdPartyKeys[0]) == false)
        #expect(defaults.integer(forKey: preferredPositionKey(for: StatusBarController.mainAutosaveName)) == 500)
        #expect(defaults.integer(forKey: preferredPositionKey(for: HiddenBarController.separatorAutosaveName)) == 300)
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

    @Test func nonNotchedDisplaysUseOverlappingPlacement() {
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
