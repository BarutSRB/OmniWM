import AppKit
import CoreGraphics
import Foundation
@testable import OmniWM
import Testing

private func makeMenuBarRecoveryDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.menubar.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func preferredPositionKey(for autosaveName: String) -> String {
    StatusItemPersistence.preferredPositionKey(for: autosaveName)
}

private func visibilityKeys(for autosaveName: String) -> [String] {
    StatusItemPersistence.visibilityKeys(for: autosaveName)
}

private func ownedStatusDefaultKeys() -> [String] {
    StatusItemPersistence.OwnedItem.allCases.flatMap { item in
        [preferredPositionKey(for: item.autosaveName)] + visibilityKeys(for: item.autosaveName)
    }
}

private func capturedDefaultValues(
    for keys: [String],
    defaults: UserDefaults = .standard
) -> [(key: String, value: Any?)] {
    keys.map { ($0, defaults.object(forKey: $0)) }
}

private func restoreDefaultValues(
    _ values: [(key: String, value: Any?)],
    defaults: UserDefaults = .standard
) {
    for (key, value) in values {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
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

@Suite struct StatusItemPersistenceRepairTests {
    @Test func appKitRestoreKeyContractUsesExpectedLiteralNames() {
        #expect(StatusItemPersistence.OwnedItem.main.autosaveName == "omniwm_main")
        #expect(StatusItemPersistence.OwnedItem.hiddenBarSeparator.autosaveName == "omniwm_hiddenbar_separator")
        #expect(preferredPositionKey(for: "omniwm_main") == "NSStatusItem Preferred Position omniwm_main")
        #expect(preferredPositionKey(for: "omniwm_hiddenbar_separator") ==
            "NSStatusItem Preferred Position omniwm_hiddenbar_separator")
        #expect(visibilityKeys(for: "omniwm_main") == [
            "NSStatusItem Visible omniwm_main",
            "NSStatusItem Visible Preference omniwm_main",
            "NSStatusItem Visibility omniwm_main"
        ])
        #expect(visibilityKeys(for: "omniwm_hiddenbar_separator") == [
            "NSStatusItem Visible omniwm_hiddenbar_separator",
            "NSStatusItem Visible Preference omniwm_hiddenbar_separator",
            "NSStatusItem Visibility omniwm_hiddenbar_separator"
        ])
    }

    @Test func clearOwnedPreferredPositionsRemovesOnlyOmniItems() {
        let defaults = makeMenuBarRecoveryDefaults()
        let mainKey = preferredPositionKey(for: StatusItemPersistence.OwnedItem.main.autosaveName)
        let separatorKey = preferredPositionKey(for: StatusItemPersistence.OwnedItem.hiddenBarSeparator.autosaveName)
        let thirdPartyKey = preferredPositionKey(for: "third_party")

        defaults.set(11, forKey: mainKey)
        defaults.set(12, forKey: separatorKey)
        defaults.set(42, forKey: thirdPartyKey)

        StatusItemPersistence.clearOwnedPreferredPositions(defaults: defaults)

        #expect(defaults.object(forKey: mainKey) == nil)
        #expect(defaults.object(forKey: separatorKey) == nil)
        #expect(defaults.integer(forKey: thirdPartyKey) == 42)
    }

    @Test func clearOwnedVisibilityPreferencesRemovesOnlyOmniItems() {
        let defaults = makeMenuBarRecoveryDefaults()
        let mainKeys = visibilityKeys(for: StatusItemPersistence.OwnedItem.main.autosaveName)
        let separatorKeys = visibilityKeys(for: StatusItemPersistence.OwnedItem.hiddenBarSeparator.autosaveName)
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

        StatusItemPersistence.clearOwnedVisibilityPreferences(defaults: defaults)

        for key in mainKeys + separatorKeys {
            #expect(defaults.object(forKey: key) == nil)
        }
        for key in thirdPartyKeys {
            #expect(defaults.object(forKey: key) != nil)
            #expect(defaults.bool(forKey: key) == false)
        }
    }

    @Test func repairOwnedRestoreStateClearsInvalidOwnedStatusKeysOnly() {
        let defaults = makeMenuBarRecoveryDefaults()
        let mainName = StatusItemPersistence.OwnedItem.main.autosaveName
        let separatorName = StatusItemPersistence.OwnedItem.hiddenBarSeparator.autosaveName
        let mainPositionKey = preferredPositionKey(for: mainName)
        let separatorPositionKey = preferredPositionKey(for: separatorName)
        let thirdPartyPositionKey = preferredPositionKey(for: "third_party")
        let mainVisibilityKeys = visibilityKeys(for: mainName)
        let thirdPartyVisibilityKeys = visibilityKeys(for: "third_party")

        defaults.set(2756, forKey: mainPositionKey)
        defaults.set(498, forKey: separatorPositionKey)
        defaults.set(42, forKey: thirdPartyPositionKey)
        defaults.set(false, forKey: mainVisibilityKeys[0])
        defaults.set(false, forKey: thirdPartyVisibilityKeys[0])
        defaults.set("keep", forKey: "unrelated")

        let didRepair = StatusItemPersistence.repairOwnedRestoreState(
            defaults: defaults,
            screenFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        )

        #expect(didRepair)
        #expect(defaults.object(forKey: mainPositionKey) == nil)
        #expect(defaults.object(forKey: separatorPositionKey) == nil)
        for key in mainVisibilityKeys {
            #expect(defaults.object(forKey: key) == nil)
        }
        #expect(defaults.integer(forKey: thirdPartyPositionKey) == 42)
        #expect(defaults.object(forKey: thirdPartyVisibilityKeys[0]) != nil)
        #expect(defaults.bool(forKey: thirdPartyVisibilityKeys[0]) == false)
        #expect(defaults.string(forKey: "unrelated") == "keep")
    }

    @Test func clearInvalidOwnedVisibilityPreferencesClearsMalformedSeparatorOnly() {
        let defaults = makeMenuBarRecoveryDefaults()
        let mainKeys = visibilityKeys(for: StatusItemPersistence.OwnedItem.main.autosaveName)
        let separatorKeys = visibilityKeys(for: StatusItemPersistence.OwnedItem.hiddenBarSeparator.autosaveName)

        for key in mainKeys + separatorKeys {
            defaults.set(true, forKey: key)
        }
        defaults.set("not a bool", forKey: separatorKeys[1])

        let didClear = StatusItemPersistence.clearInvalidOwnedVisibilityPreferences(defaults: defaults)

        #expect(didClear)
        for key in mainKeys {
            #expect(defaults.bool(forKey: key))
        }
        for key in separatorKeys {
            #expect(defaults.object(forKey: key) == nil)
        }
    }

    @Test func preferredPositionVisibilityUsesGlobalScreenXRanges() {
        let screenFrames = [
            CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 0, width: 1440, height: 900)
        ]

        #expect(StatusItemPersistence.preferredPositionXCanBeKept(-1920, screenFrames: screenFrames))
        #expect(StatusItemPersistence.preferredPositionXCanBeKept(-1, screenFrames: screenFrames))
        #expect(StatusItemPersistence.preferredPositionXCanBeKept(0, screenFrames: screenFrames))
        #expect(StatusItemPersistence.preferredPositionXCanBeKept(1439, screenFrames: screenFrames))
        #expect(!StatusItemPersistence.preferredPositionXCanBeKept(-1921, screenFrames: screenFrames))
        #expect(!StatusItemPersistence.preferredPositionXCanBeKept(1440, screenFrames: screenFrames))
    }

    @Test func storedPreferredPositionRejectsBooleanAndNonFiniteJunk() {
        let screenFrames = [CGRect(x: 0, y: 0, width: 1440, height: 900)]

        #expect(StatusItemPersistence.storedPreferredPositionCanBeKept(nil, screenFrames: screenFrames))
        #expect(StatusItemPersistence.storedPreferredPositionCanBeKept(320, screenFrames: screenFrames))
        #expect(!StatusItemPersistence.storedPreferredPositionCanBeKept(true, screenFrames: screenFrames))
        #expect(!StatusItemPersistence.storedPreferredPositionCanBeKept(false, screenFrames: screenFrames))
        #expect(!StatusItemPersistence.storedPreferredPositionCanBeKept(Double.nan, screenFrames: screenFrames))
        #expect(!StatusItemPersistence.storedPreferredPositionCanBeKept(Double.infinity, screenFrames: screenFrames))
    }

    @Test func restoreStatePreservesValidAndAbsentValues() {
        let defaults = makeMenuBarRecoveryDefaults()
        let mainPositionKey = preferredPositionKey(for: StatusItemPersistence.OwnedItem.main.autosaveName)
        let separatorKeys = visibilityKeys(for: StatusItemPersistence.OwnedItem.hiddenBarSeparator.autosaveName)

        defaults.set(-400, forKey: mainPositionKey)
        defaults.set(true, forKey: separatorKeys[2])

        let didRepair = StatusItemPersistence.repairOwnedRestoreState(
            defaults: defaults,
            screenFrames: [
                CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                CGRect(x: 0, y: 0, width: 1440, height: 900)
            ]
        )

        #expect(!didRepair)
        #expect(defaults.integer(forKey: mainPositionKey) == -400)
        #expect(defaults.bool(forKey: separatorKeys[2]))
    }

    @Test func storedVisibilityPreferenceRejectsNumericJunk() {
        #expect(StatusItemPersistence.storedVisibilityPreferenceCanBeKept(nil))
        #expect(StatusItemPersistence.storedVisibilityPreferenceCanBeKept(true))
        #expect(!StatusItemPersistence.storedVisibilityPreferenceCanBeKept(false))
        #expect(!StatusItemPersistence.storedVisibilityPreferenceCanBeKept(1))
    }
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
        #expect(!HiddenBarController.canCollapseSafely(
            omniMinX: 100,
            separatorMinX: 200,
            layoutDirection: .leftToRight
        ))
        #expect(HiddenBarController.canCollapseSafely(omniMinX: 100, separatorMinX: 200, layoutDirection: .rightToLeft))
        #expect(!HiddenBarController.canCollapseSafely(
            omniMinX: 200,
            separatorMinX: 100,
            layoutDirection: .rightToLeft
        ))
        #expect(!HiddenBarController.canCollapseSafely(
            omniMinX: nil,
            separatorMinX: 100,
            layoutDirection: .leftToRight
        ))
    }
}

@Suite(.serialized) @MainActor struct StatusBarAutosaveContractTests {
    @Test func ownedStatusItemsKeepAutosaveNamesForOrderingRecovery() {
        let capturedDefaults = capturedDefaultValues(for: ownedStatusDefaultKeys())
        let controller = makeLayoutPlanTestController()
        controller.settings.hiddenBarIsCollapsed = false
        let hiddenBarController = HiddenBarController(settings: controller.settings)
        let statusBarController = StatusBarController(
            settings: controller.settings,
            controller: controller,
            hiddenBarController: hiddenBarController
        )
        controller.statusBarController = statusBarController
        defer {
            statusBarController.cleanup()
            restoreDefaultValues(capturedDefaults)
        }

        statusBarController.setup()

        #expect(statusBarController.statusItemAutosaveNameForTests() == StatusBarController.mainAutosaveName)
        #expect(hiddenBarController.separatorAutosaveNameForTests() == HiddenBarController.separatorAutosaveName)
        #expect(statusBarController.statusItemIsVisibleForTests() == true)
        #expect(hiddenBarController.separatorIsVisibleForTests() == true)
    }

    @Test func setupRepairsOwnedRestoreStateBeforeInstall() {
        let defaults = makeMenuBarRecoveryDefaults()
        let mainName = StatusItemPersistence.OwnedItem.main.autosaveName
        let mainPositionKey = preferredPositionKey(for: mainName)
        let mainVisibilityKeys = visibilityKeys(for: mainName)
        let thirdPartyPositionKey = preferredPositionKey(for: "third_party")
        let thirdPartyVisibilityKey = visibilityKeys(for: "third_party")[0]
        let unrelatedKey = "omniwm.status.integration.unrelated"
        let capturedDefaults = capturedDefaultValues(for: ownedStatusDefaultKeys())
        let controller = makeLayoutPlanTestController()
        controller.settings.hiddenBarIsCollapsed = false
        let hiddenBarController = HiddenBarController(settings: controller.settings)
        let statusBarController = StatusBarController(
            settings: controller.settings,
            controller: controller,
            hiddenBarController: hiddenBarController,
            statusItemDefaults: defaults
        )
        controller.statusBarController = statusBarController
        defer {
            statusBarController.cleanup()
            restoreDefaultValues(capturedDefaults)
        }

        defaults.set("bad", forKey: mainPositionKey)
        defaults.set(false, forKey: mainVisibilityKeys[0])
        defaults.set(42, forKey: thirdPartyPositionKey)
        defaults.set(false, forKey: thirdPartyVisibilityKey)
        defaults.set("keep", forKey: unrelatedKey)

        statusBarController.setup()

        #expect(defaults.object(forKey: mainPositionKey) == nil)
        for key in mainVisibilityKeys {
            #expect(defaults.object(forKey: key) == nil)
        }
        #expect(defaults.integer(forKey: thirdPartyPositionKey) == 42)
        #expect(defaults.bool(forKey: thirdPartyVisibilityKey) == false)
        #expect(defaults.string(forKey: unrelatedKey) == "keep")
    }

    @Test func unsafeOrderingRepairClearsOwnedRestoreStateAndReinstallsItems() {
        let defaults = makeMenuBarRecoveryDefaults()
        let mainName = StatusItemPersistence.OwnedItem.main.autosaveName
        let separatorName = StatusItemPersistence.OwnedItem.hiddenBarSeparator.autosaveName
        let mainPositionKey = preferredPositionKey(for: mainName)
        let separatorPositionKey = preferredPositionKey(for: separatorName)
        let mainVisibilityKey = visibilityKeys(for: mainName)[0]
        let separatorVisibilityKey = visibilityKeys(for: separatorName)[1]
        let thirdPartyPositionKey = preferredPositionKey(for: "third_party")
        let thirdPartyVisibilityKey = visibilityKeys(for: "third_party")[0]
        let capturedDefaults = capturedDefaultValues(for: ownedStatusDefaultKeys())
        let controller = makeLayoutPlanTestController()
        controller.settings.hiddenBarIsCollapsed = true
        let hiddenBarController = HiddenBarController(settings: controller.settings)
        let statusBarController = StatusBarController(
            settings: controller.settings,
            controller: controller,
            hiddenBarController: hiddenBarController,
            statusItemDefaults: defaults
        )
        controller.statusBarController = statusBarController
        defer {
            statusBarController.cleanup()
            restoreDefaultValues(capturedDefaults)
        }

        statusBarController.setup()

        defaults.set(500, forKey: mainPositionKey)
        defaults.set(300, forKey: separatorPositionKey)
        defaults.set(false, forKey: mainVisibilityKey)
        defaults.set(false, forKey: separatorVisibilityKey)
        defaults.set(42, forKey: thirdPartyPositionKey)
        defaults.set(false, forKey: thirdPartyVisibilityKey)

        statusBarController.rebuildOwnedStatusItemsAfterUnsafeOrderingForTests()

        #expect(controller.settings.hiddenBarIsCollapsed == false)
        #expect(defaults.object(forKey: mainPositionKey) == nil)
        #expect(defaults.object(forKey: separatorPositionKey) == nil)
        #expect(defaults.object(forKey: mainVisibilityKey) == nil)
        #expect(defaults.object(forKey: separatorVisibilityKey) == nil)
        #expect(defaults.integer(forKey: thirdPartyPositionKey) == 42)
        #expect(defaults.bool(forKey: thirdPartyVisibilityKey) == false)
        #expect(statusBarController.statusItemAutosaveNameForTests() == StatusBarController.mainAutosaveName)
        #expect(hiddenBarController.separatorAutosaveNameForTests() == HiddenBarController.separatorAutosaveName)
        #expect(statusBarController.statusItemIsVisibleForTests() == true)
        #expect(hiddenBarController.separatorIsVisibleForTests() == true)
    }

    @Test func persistedCollapsedStateRechecksUnknownOrderingBeforeApplyingHiddenLength() {
        let defaults = makeMenuBarRecoveryDefaults()
        let mainName = StatusItemPersistence.OwnedItem.main.autosaveName
        let separatorName = StatusItemPersistence.OwnedItem.hiddenBarSeparator.autosaveName
        let mainPositionKey = preferredPositionKey(for: mainName)
        let separatorPositionKey = preferredPositionKey(for: separatorName)
        let capturedDefaults = capturedDefaultValues(for: ownedStatusDefaultKeys())
        let controller = makeLayoutPlanTestController()
        controller.settings.hiddenBarIsCollapsed = true
        let hiddenBarController = HiddenBarController(settings: controller.settings)
        let statusBarController = StatusBarController(
            settings: controller.settings,
            controller: controller,
            hiddenBarController: hiddenBarController,
            statusItemDefaults: defaults
        )
        controller.statusBarController = statusBarController
        defer {
            statusBarController.cleanup()
            restoreDefaultValues(capturedDefaults)
        }

        defaults.set(500, forKey: mainPositionKey)
        defaults.set(300, forKey: separatorPositionKey)

        statusBarController.setup()

        hiddenBarController.updateCollapseLengthForTests()

        #expect(controller.settings.hiddenBarIsCollapsed)
        #expect(defaults.integer(forKey: mainPositionKey) == 500)
        #expect(defaults.integer(forKey: separatorPositionKey) == 300)

        hiddenBarController.setCollapseSafetyForTests(
            omniMinX: nil,
            separatorMinX: 200,
            layoutDirection: .leftToRight
        )
        hiddenBarController.runPersistedCollapseSafetyCheckForTests()

        #expect(controller.settings.hiddenBarIsCollapsed == false)
        #expect(defaults.object(forKey: mainPositionKey) == nil)
        #expect(defaults.object(forKey: separatorPositionKey) == nil)
        #expect(statusBarController.statusItemAutosaveNameForTests() == StatusBarController.mainAutosaveName)
        #expect(hiddenBarController.separatorAutosaveNameForTests() == HiddenBarController.separatorAutosaveName)
        #expect(statusBarController.statusItemIsVisibleForTests() == true)
        #expect(hiddenBarController.separatorIsVisibleForTests() == true)
    }

    @Test func persistedCollapsedStartupUnknownOrderingRunsRealCollapseRecoveryPath() {
        let defaults = makeMenuBarRecoveryDefaults()
        let mainName = StatusItemPersistence.OwnedItem.main.autosaveName
        let separatorName = StatusItemPersistence.OwnedItem.hiddenBarSeparator.autosaveName
        let mainPositionKey = preferredPositionKey(for: mainName)
        let separatorPositionKey = preferredPositionKey(for: separatorName)
        let mainVisibilityKey = visibilityKeys(for: mainName)[0]
        let separatorVisibilityKey = visibilityKeys(for: separatorName)[0]
        let capturedDefaults = capturedDefaultValues(for: ownedStatusDefaultKeys())
        let controller = makeLayoutPlanTestController()
        controller.settings.hiddenBarIsCollapsed = true
        let hiddenBarController = HiddenBarController(settings: controller.settings)
        let statusBarController = StatusBarController(
            settings: controller.settings,
            controller: controller,
            hiddenBarController: hiddenBarController,
            statusItemDefaults: defaults
        )
        controller.statusBarController = statusBarController
        defer {
            statusBarController.cleanup()
            restoreDefaultValues(capturedDefaults)
        }

        defaults.set(500, forKey: mainPositionKey)
        defaults.set(300, forKey: separatorPositionKey)
        defaults.set(false, forKey: mainVisibilityKey)
        defaults.set(false, forKey: separatorVisibilityKey)

        statusBarController.setup()
        hiddenBarController.setCollapseSafetyForTests(
            omniMinX: nil,
            separatorMinX: 200,
            layoutDirection: .leftToRight
        )
        hiddenBarController.runPersistedCollapseSafetyCheckForTests()

        #expect(controller.settings.hiddenBarIsCollapsed == false)
        #expect(defaults.object(forKey: mainPositionKey) == nil)
        #expect(defaults.object(forKey: separatorPositionKey) == nil)
        #expect(defaults.object(forKey: mainVisibilityKey) == nil)
        #expect(defaults.object(forKey: separatorVisibilityKey) == nil)
        #expect(statusBarController.statusItemAutosaveNameForTests() == StatusBarController.mainAutosaveName)
        #expect(hiddenBarController.separatorAutosaveNameForTests() == HiddenBarController.separatorAutosaveName)
        #expect(statusBarController.statusItemIsVisibleForTests() == true)
        #expect(hiddenBarController.separatorIsVisibleForTests() == true)
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
