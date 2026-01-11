import AppKit
import SwiftUI

struct StatusBarMenuView: View {
    @Binding var settings: SettingsStore
    let controller: WMController

    private var appVersion: String {
        Bundle.main.appVersion ?? "0.2.2"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerSection
                GlassMenuDivider()

                GlassSectionLabel("CONTROLS")
                controlsSection
                GlassMenuDivider()

                GlassSectionLabel("SETTINGS")
                settingsSection
                GlassMenuDivider()

                GlassSectionLabel("LINKS")
                linksSection
                GlassMenuDivider()

                sponsorsSection
                GlassMenuDivider()

                quitSection
            }
            .padding(.vertical, 8)
        }
        .frame(width: 280, height: 500)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    private var headerSection: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.3), .purple.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("OmniWM")
                        .font(.system(size: 15, weight: .semibold))
                    StatusIndicator()
                }
                Text("v\(appVersion)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var controlsSection: some View {
        GlassMenuSection {
            GlassToggleRow(
                icon: "cursorarrow.motionlines",
                label: "Focus Follows Mouse",
                isOn: $settings.focusFollowsMouse,
                animationsEnabled: settings.animationsEnabled
            )
            .onChange(of: settings.focusFollowsMouse) { _, newValue in
                controller.setFocusFollowsMouse(newValue)
            }
            GlassToggleRow(
                icon: "arrow.up.left.and.down.right.magnifyingglass",
                label: "Mouse to Focused",
                isOn: $settings.moveMouseToFocusedWindow,
                animationsEnabled: settings.animationsEnabled
            )
            .onChange(of: settings.moveMouseToFocusedWindow) { _, newValue in
                controller.setMoveMouseToFocusedWindow(newValue)
            }
            GlassToggleRow(
                icon: "square.dashed",
                label: "Window Borders",
                isOn: $settings.bordersEnabled,
                animationsEnabled: settings.animationsEnabled
            )
            .onChange(of: settings.bordersEnabled) { _, newValue in
                controller.setBordersEnabled(newValue)
            }
            GlassToggleRow(
                icon: "menubar.rectangle",
                label: "Workspace Bar",
                isOn: $settings.workspaceBarEnabled,
                animationsEnabled: settings.animationsEnabled
            )
            .onChange(of: settings.workspaceBarEnabled) { _, newValue in
                controller.setWorkspaceBarEnabled(newValue)
            }
            GlassToggleRow(
                icon: "moon.zzz",
                label: "Keep Awake",
                isOn: $settings.preventSleepEnabled,
                animationsEnabled: settings.animationsEnabled
            )
            .onChange(of: settings.preventSleepEnabled) { _, newValue in
                controller.setPreventSleepEnabled(newValue)
            }
        }
    }

    private var settingsSection: some View {
        GlassMenuSection {
            GlassMenuRow(icon: "slider.horizontal.3", showChevron: true, animationsEnabled: settings.animationsEnabled, action: {
                AppRulesWindowController.shared.show(settings: settings, controller: controller)
            }) {
                Text("App Rules")
                    .font(.system(size: 13))
            }
            GlassMenuRow(icon: "gearshape", showChevron: true, animationsEnabled: settings.animationsEnabled, action: {
                SettingsWindowController.shared.show(settings: settings, controller: controller)
            }) {
                Text("Settings")
                    .font(.system(size: 13))
            }
        }
    }

    private var linksSection: some View {
        GlassMenuSection {
            GlassMenuRow(icon: "link", isExternal: true, animationsEnabled: settings.animationsEnabled, action: {
                if let url = URL(string: "https://github.com/BarutSRB/OmniWM") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                Text("GitHub")
                    .font(.system(size: 13))
            }
            GlassMenuRow(icon: "heart", isExternal: true, animationsEnabled: settings.animationsEnabled, action: {
                if let url = URL(string: "https://github.com/sponsors/BarutSRB") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                Text("Sponsor on GitHub")
                    .font(.system(size: 13))
            }
            GlassMenuRow(icon: "heart", isExternal: true, animationsEnabled: settings.animationsEnabled, action: {
                if let url = URL(string: "https://paypal.me/beacon2024") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                Text("Sponsor on PayPal")
                    .font(.system(size: 13))
            }
        }
    }

    private var sponsorsSection: some View {
        GlassMenuRow(icon: "sparkles", animationsEnabled: settings.animationsEnabled, action: {
            SponsorsWindowController.shared.show()
        }) {
            Text("Omni Sponsors")
                .font(.system(size: 13))
        }
    }

    private var quitSection: some View {
        GlassMenuRow(icon: "power", isDestructive: true, animationsEnabled: settings.animationsEnabled, action: {
            NSApplication.shared.terminate(nil)
        }) {
            Text("Quit OmniWM")
                .font(.system(size: 13))
        }
    }
}
