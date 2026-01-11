import AppKit
import SwiftUI

@main
struct OmniWMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: SettingsStore
    @State private var controller: WMController

    init() {
        let settings = SettingsStore()
        let controller = WMController(settings: settings)
        _settings = State(wrappedValue: settings)
        _controller = State(wrappedValue: controller)

        controller.updateHotkeyBindings(settings.hotkeyBindings)
        controller.setHotkeysEnabled(settings.hotkeysEnabled)
        controller.setGapSize(settings.gapSize)
        controller.setOuterGaps(
            left: settings.outerGapLeft,
            right: settings.outerGapRight,
            top: settings.outerGapTop,
            bottom: settings.outerGapBottom
        )
        controller.enableNiriLayout(maxWindowsPerColumn: settings.niriMaxWindowsPerColumn)
        controller.updateNiriConfig(
            maxVisibleColumns: settings.niriMaxVisibleColumns,
            infiniteLoop: settings.niriInfiniteLoop,
            centerFocusedColumn: settings.niriCenterFocusedColumn,
            alwaysCenterSingleColumn: settings.niriAlwaysCenterSingleColumn,
            singleWindowAspectRatio: settings.niriSingleWindowAspectRatio
        )
        controller.enableDwindleLayout()
        controller.updateDwindleConfig(
            smartSplit: settings.dwindleSmartSplit,
            defaultSplitRatio: settings.dwindleDefaultSplitRatio,
            splitWidthMultiplier: settings.dwindleSplitWidthMultiplier,
            singleWindowAspectRatio: settings.dwindleSingleWindowAspectRatio.size
        )
        controller.updateWorkspaceConfig()
        controller.rebuildAppRulesCache()

        controller.setEnabled(true)

        controller.setBordersEnabled(settings.bordersEnabled)
        controller.updateBorderConfig(BorderConfig.from(settings: settings))

        controller.setFocusFollowsMouse(settings.focusFollowsMouse)
        controller.setMoveMouseToFocusedWindow(settings.moveMouseToFocusedWindow)

        controller.setWorkspaceBarEnabled(settings.workspaceBarEnabled)
        controller.setPreventSleepEnabled(settings.preventSleepEnabled)
        controller.setHiddenBarEnabled(settings.hiddenBarEnabled)
    }

    var body: some Scene {
        MenuBarExtra("O", systemImage: "o.circle") {
            StatusBarMenuView(settings: $settings, controller: controller)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settings, controller: controller)
                .frame(minWidth: 480, minHeight: 500)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
