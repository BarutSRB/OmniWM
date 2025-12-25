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
        controller.updateWorkspaceConfig()
        controller.rebuildAppRulesCache()

        controller.setEnabled(true)
        controller.start()

        controller.setBordersEnabled(settings.bordersEnabled)
        controller.updateBorderConfig(BorderConfig.from(settings: settings))

        controller.setFocusFollowsMouse(settings.focusFollowsMouse)
        controller.setMoveMouseToFocusedWindow(settings.moveMouseToFocusedWindow)

        controller.setWorkspaceBarEnabled(settings.workspaceBarEnabled)
    }

    var body: some Scene {
        MenuBarExtra("O", systemImage: "o.circle") {
            Toggle("Focus Follows Mouse", isOn: $settings.focusFollowsMouse)
                .onChange(of: settings.focusFollowsMouse) { _, newValue in
                    controller.setFocusFollowsMouse(newValue)
                }
            Toggle("Move Mouse to Focused Window", isOn: $settings.moveMouseToFocusedWindow)
                .onChange(of: settings.moveMouseToFocusedWindow) { _, newValue in
                    controller.setMoveMouseToFocusedWindow(newValue)
                }
            Toggle("Window Borders", isOn: $settings.bordersEnabled)
                .onChange(of: settings.bordersEnabled) { _, newValue in
                    controller.setBordersEnabled(newValue)
                }
            Toggle("Workspace Bar", isOn: $settings.workspaceBarEnabled)
                .onChange(of: settings.workspaceBarEnabled) { _, newValue in
                    controller.setWorkspaceBarEnabled(newValue)
                }
            Divider()
            Button("App Rules…") {
                AppRulesWindowController.shared.show(settings: settings, controller: controller)
            }
            Button("Settings…") {
                SettingsWindowController.shared.show(settings: settings, controller: controller)
            }
            Divider()
            Button("GitHub") {
                if let url = URL(string: "https://github.com/BarutSRB/OmniWM") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Sponsor on GitHub") {
                if let url = URL(string: "https://github.com/sponsors/BarutSRB") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Sponsor on PayPal") {
                if let url = URL(string: "https://paypal.me/beacon2024") {
                    NSWorkspace.shared.open(url)
                }
            }
            Divider()
            Button("Quit OmniWM") { NSApplication.shared.terminate(nil) }
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
