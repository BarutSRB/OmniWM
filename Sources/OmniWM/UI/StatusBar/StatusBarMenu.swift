import AppKit
import Observation
import SwiftUI

let statusBarMenuWidth: CGFloat = 280

private let menuCornerRadius: CGFloat = 14
private let rowCornerRadius: CGFloat = 6

enum StatusBarMenuItemID: String, CaseIterable {
    case focusFollowsMouse
    case followWindowToWorkspace
    case mouseToFocused
    case windowBorders
    case workspaceBar
    case keepAwake
    case appRules
    case settings
    case github
    case sponsorGithub
    case sponsorPaypal
    case sponsors
    case quit

    static let interactiveItems: [StatusBarMenuItemID] = [
        .focusFollowsMouse,
        .followWindowToWorkspace,
        .mouseToFocused,
        .windowBorders,
        .workspaceBar,
        .keepAwake,
        .appRules,
        .settings,
        .github,
        .sponsorGithub,
        .sponsorPaypal,
        .sponsors,
        .quit,
    ]
}

@MainActor @Observable
final class StatusBarMenuViewModel {
    let settings: SettingsStore

    private weak var controller: WMController?
    private var dismissMenu: ((Bool) -> Void)?

    var focusedItemID: StatusBarMenuItemID?

    init(settings: SettingsStore, controller: WMController) {
        self.settings = settings
        self.controller = controller
        focusedItemID = StatusBarMenuItemID.interactiveItems.first
    }

    func setDismissHandler(_ dismiss: @escaping (Bool) -> Void) {
        dismissMenu = dismiss
    }

    func resetFocus() {
        focusedItemID = StatusBarMenuItemID.interactiveItems.first
    }

    func focus(_ itemID: StatusBarMenuItemID) {
        focusedItemID = itemID
    }

    func moveFocus(by delta: Int) {
        let items = StatusBarMenuItemID.interactiveItems
        guard !items.isEmpty else { return }

        let currentIndex = focusedItemID.flatMap { items.firstIndex(of: $0) } ?? 0
        let nextIndex = (currentIndex + delta + items.count) % items.count
        focusedItemID = items[nextIndex]
    }

    func focusFirstItem() {
        focusedItemID = StatusBarMenuItemID.interactiveItems.first
    }

    func focusLastItem() {
        focusedItemID = StatusBarMenuItemID.interactiveItems.last
    }

    @discardableResult
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.shift, .command, .control, .option])
        let allowsNavigationShortcut = modifiers.isEmpty || modifiers == [.shift]

        guard allowsNavigationShortcut else {
            return false
        }

        switch event.keyCode {
        case 48:
            moveFocus(by: modifiers.contains(.shift) ? -1 : 1)
            return true
        case 125:
            moveFocus(by: 1)
            return true
        case 126:
            moveFocus(by: -1)
            return true
        case 115:
            focusFirstItem()
            return true
        case 119:
            focusLastItem()
            return true
        case 49, 36, 76:
            activateFocusedItem()
            return true
        case 53:
            dismissMenu?(true)
            return true
        default:
            return false
        }
    }

    func activateFocusedItem() {
        guard let focusedItemID else { return }
        activate(itemID: focusedItemID)
    }

    func activate(itemID: StatusBarMenuItemID) {
        focus(itemID)

        switch itemID {
        case .focusFollowsMouse:
            settings.focusFollowsMouse.toggle()
            controller?.setFocusFollowsMouse(settings.focusFollowsMouse)
        case .followWindowToWorkspace:
            settings.focusFollowsWindowToMonitor.toggle()
        case .mouseToFocused:
            settings.moveMouseToFocusedWindow.toggle()
            controller?.setMoveMouseToFocusedWindow(settings.moveMouseToFocusedWindow)
        case .windowBorders:
            settings.bordersEnabled.toggle()
            controller?.setBordersEnabled(settings.bordersEnabled)
        case .workspaceBar:
            settings.workspaceBarEnabled.toggle()
            controller?.setWorkspaceBarEnabled(settings.workspaceBarEnabled)
        case .keepAwake:
            settings.preventSleepEnabled.toggle()
            controller?.setPreventSleepEnabled(settings.preventSleepEnabled)
        case .appRules:
            dismissAndPerform { [weak self] in
                guard let self, let controller = self.controller else { return }
                AppRulesWindowController.shared.show(settings: self.settings, controller: controller)
            }
        case .settings:
            dismissAndPerform { [weak self] in
                guard let self, let controller = self.controller else { return }
                SettingsWindowController.shared.show(settings: self.settings, controller: controller)
            }
        case .github:
            dismissAndPerform {
                guard let url = URL(string: "https://github.com/BarutSRB/OmniWM") else { return }
                NSWorkspace.shared.open(url)
            }
        case .sponsorGithub:
            dismissAndPerform {
                guard let url = URL(string: "https://github.com/sponsors/BarutSRB") else { return }
                NSWorkspace.shared.open(url)
            }
        case .sponsorPaypal:
            dismissAndPerform {
                guard let url = URL(string: "https://paypal.me/beacon2024") else { return }
                NSWorkspace.shared.open(url)
            }
        case .sponsors:
            dismissAndPerform {
                SponsorsWindowController.shared.show()
            }
        case .quit:
            dismissAndPerform {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func dismissAndPerform(_ action: @escaping () -> Void) {
        dismissMenu?(false)
        action()
    }
}

struct StatusBarMenuView: View {
    let viewModel: StatusBarMenuViewModel

    private var settings: SettingsStore { viewModel.settings }

    var body: some View {
        VStack(spacing: 0) {
            StatusBarMenuHeaderView()
            StatusBarMenuDividerView()
            StatusBarMenuSectionLabelView(text: "CONTROLS")

            StatusBarMenuToggleRow(
                itemID: .focusFollowsMouse,
                icon: "cursorarrow.motionlines",
                label: "Focus Follows Mouse",
                isOn: settings.focusFollowsMouse,
                viewModel: viewModel
            )
            StatusBarMenuToggleRow(
                itemID: .followWindowToWorkspace,
                icon: "arrow.right.square",
                label: "Follow Window to Workspace",
                isOn: settings.focusFollowsWindowToMonitor,
                viewModel: viewModel
            )
            StatusBarMenuToggleRow(
                itemID: .mouseToFocused,
                icon: "arrow.up.left.and.down.right.magnifyingglass",
                label: "Mouse to Focused",
                isOn: settings.moveMouseToFocusedWindow,
                viewModel: viewModel
            )
            StatusBarMenuToggleRow(
                itemID: .windowBorders,
                icon: "square.dashed",
                label: "Window Borders",
                isOn: settings.bordersEnabled,
                viewModel: viewModel
            )
            StatusBarMenuToggleRow(
                itemID: .workspaceBar,
                icon: "menubar.rectangle",
                label: "Workspace Bar",
                isOn: settings.workspaceBarEnabled,
                viewModel: viewModel
            )
            StatusBarMenuToggleRow(
                itemID: .keepAwake,
                icon: "moon.zzz",
                label: "Keep Awake",
                isOn: settings.preventSleepEnabled,
                viewModel: viewModel
            )

            StatusBarMenuDividerView()
            StatusBarMenuSectionLabelView(text: "SETTINGS")

            StatusBarMenuActionRow(
                itemID: .appRules,
                icon: "slider.horizontal.3",
                label: "App Rules",
                accessory: .chevron,
                viewModel: viewModel
            )
            StatusBarMenuActionRow(
                itemID: .settings,
                icon: "gearshape",
                label: "Settings",
                accessory: .chevron,
                viewModel: viewModel
            )

            StatusBarMenuDividerView()
            StatusBarMenuSectionLabelView(text: "LINKS")

            StatusBarMenuActionRow(
                itemID: .github,
                icon: "link",
                label: "GitHub",
                accessory: .external,
                viewModel: viewModel
            )
            StatusBarMenuActionRow(
                itemID: .sponsorGithub,
                icon: "heart",
                label: "Sponsor on GitHub",
                accessory: .external,
                viewModel: viewModel
            )
            StatusBarMenuActionRow(
                itemID: .sponsorPaypal,
                icon: "heart",
                label: "Sponsor on PayPal",
                accessory: .external,
                viewModel: viewModel
            )

            StatusBarMenuDividerView()

            StatusBarMenuActionRow(
                itemID: .sponsors,
                icon: "sparkles",
                label: "Omni Sponsors",
                accessory: .none,
                viewModel: viewModel
            )

            StatusBarMenuDividerView()

            StatusBarMenuActionRow(
                itemID: .quit,
                icon: "power",
                label: "Quit OmniWM",
                accessory: .none,
                isDestructive: true,
                viewModel: viewModel
            )
        }
        .padding(8)
        .frame(width: statusBarMenuWidth)
        .background(
            RoundedRectangle(cornerRadius: menuCornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: menuCornerRadius, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                )
        )
    }
}

private struct StatusBarMenuHeaderView: View {
    private var appVersion: String {
        Bundle.main.appVersion ?? "0.3.1"
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: NSColor(calibratedRed: 0.3, green: 0.4, blue: 0.8, alpha: 0.2)))
                    .frame(width: 36, height: 36)

                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color(nsColor: .labelColor))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("OmniWM")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .labelColor))

                    Circle()
                        .fill(Color(nsColor: .systemGreen))
                        .frame(width: 6, height: 6)
                }

                Text("v\(appVersion)")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("OmniWM version \(appVersion)")
    }
}

private struct StatusBarMenuSectionLabelView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 7)
            .padding(.bottom, 5)
            .accessibilityHidden(true)
    }
}

private struct StatusBarMenuDividerView: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .accessibilityHidden(true)
    }
}

private enum StatusBarMenuAccessory {
    case none
    case chevron
    case external
}

private struct StatusBarMenuActionRow: View {
    let itemID: StatusBarMenuItemID
    let icon: String
    let label: String
    let accessory: StatusBarMenuAccessory
    let isDestructive: Bool
    let viewModel: StatusBarMenuViewModel

    init(
        itemID: StatusBarMenuItemID,
        icon: String,
        label: String,
        accessory: StatusBarMenuAccessory,
        isDestructive: Bool = false,
        viewModel: StatusBarMenuViewModel
    ) {
        self.itemID = itemID
        self.icon = icon
        self.label = label
        self.accessory = accessory
        self.isDestructive = isDestructive
        self.viewModel = viewModel
    }

    private var isFocused: Bool {
        viewModel.focusedItemID == itemID
    }

    var body: some View {
        Button {
            viewModel.activate(itemID: itemID)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(iconColor)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(labelColor)

                Spacer(minLength: 8)

                accessoryView
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered in
            if hovered {
                viewModel.focus(itemID)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint(accessibilityHint)
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .none:
            EmptyView()
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accessoryColor)
        case .external:
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(accessoryColor)
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
            .fill(backgroundColor)
    }

    private var backgroundColor: Color {
        if isFocused {
            if isDestructive {
                return Color(nsColor: .systemRed).opacity(0.14)
            }
            return Color(nsColor: .controlAccentColor).opacity(0.32)
        }
        return .clear
    }

    private var iconColor: Color {
        if isDestructive, isFocused {
            return Color(nsColor: .systemRed)
        }
        return isFocused ? Color(nsColor: .alternateSelectedControlTextColor) : Color(nsColor: .secondaryLabelColor)
    }

    private var labelColor: Color {
        if isDestructive, isFocused {
            return Color(nsColor: .systemRed)
        }
        return isFocused ? Color(nsColor: .alternateSelectedControlTextColor) : Color(nsColor: .labelColor)
    }

    private var accessoryColor: Color {
        isFocused ? Color(nsColor: .alternateSelectedControlTextColor) : Color(nsColor: .tertiaryLabelColor)
    }

    private var accessibilityHint: String {
        switch accessory {
        case .external:
            return "Opens in your browser"
        case .chevron:
            return "Opens a window"
        case .none:
            return isDestructive ? "Quits OmniWM" : "Activates this action"
        }
    }
}

private struct StatusBarMenuToggleRow: View {
    let itemID: StatusBarMenuItemID
    let icon: String
    let label: String
    let isOn: Bool
    let viewModel: StatusBarMenuViewModel

    private var isFocused: Bool {
        viewModel.focusedItemID == itemID
    }

    var body: some View {
        Button {
            viewModel.activate(itemID: itemID)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(
                        isFocused ? Color(nsColor: .alternateSelectedControlTextColor) : Color(nsColor: .secondaryLabelColor)
                    )
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(isFocused ? Color(nsColor: .alternateSelectedControlTextColor) : Color(nsColor: .labelColor))

                Spacer(minLength: 8)

                StatusBarMenuSwitch(isOn: isOn, isFocused: isFocused)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                    .fill(isFocused ? Color(nsColor: .controlAccentColor).opacity(0.34) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered in
            if hovered {
                viewModel.focus(itemID)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint("Press Space to toggle")
    }
}

private struct StatusBarMenuSwitch: View {
    let isOn: Bool
    let isFocused: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule(style: .continuous)
                .fill(trackColor)
                .frame(width: 42, height: 22)

            Circle()
                .fill(.white)
                .frame(width: 18, height: 18)
                .shadow(color: Color.black.opacity(0.18), radius: 1.8, x: 0, y: 0.6)
                .padding(2)
        }
        .overlay {
            if isFocused {
                Capsule(style: .continuous)
                    .stroke(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 1)
            }
        }
        .animation(.easeOut(duration: 0.14), value: isOn)
        .accessibilityHidden(true)
    }

    private var trackColor: Color {
        if isOn {
            return Color(nsColor: .systemGreen).opacity(0.95)
        }
        return Color(nsColor: NSColor(white: 0.26, alpha: 1.0))
    }
}
