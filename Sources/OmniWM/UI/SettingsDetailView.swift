import SwiftUI

struct SettingsDetailView: View {
    let section: SettingsSection
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        ScrollView {
            contentView
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .omniBackgroundExtensionEffect()
    }

    @ViewBuilder
    private var contentView: some View {
        switch section {
        case .general:
            GeneralSettingsTab(settings: settings, controller: controller)
        case .niri:
            NiriSettingsTab(settings: settings, controller: controller)
        case .dwindle:
            DwindleSettingsTab(settings: settings, controller: controller)
        case .monitors:
            MonitorSettingsTab(settings: settings, controller: controller)
        case .workspaces:
            WorkspacesSettingsTab(settings: settings, controller: controller)
        case .borders:
            BorderSettingsTab(settings: settings, controller: controller)
        case .bar:
            WorkspaceBarSettingsTab(settings: settings, controller: controller)
        case .hiddenBar:
            HiddenBarSettingsTab(settings: settings, controller: controller)
        case .menu:
            MenuAnywhereSettingsTab(settings: settings)
        case .hotkeys:
            HotkeySettingsView(settings: settings, controller: controller)
        case .quakeTerminal:
            QuakeTerminalSettingsTab(settings: settings, controller: controller)
        }
    }
}
