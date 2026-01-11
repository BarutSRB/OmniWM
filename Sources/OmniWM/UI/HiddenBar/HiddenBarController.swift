import AppKit

@MainActor
final class HiddenBarController {
    private let settings: SettingsStore

    private var toggleButton: NSStatusItem?
    private var separatorItem: NSStatusItem?
    private var alwaysHiddenItem: NSStatusItem?

    private let buttonLength: CGFloat = 22
    private let separatorLength: CGFloat = 8
    private let collapseLength: CGFloat = 10000

    private var isToggling = false

    private var isCollapsed: Bool {
        separatorItem?.length == collapseLength
    }

    private var isSeparatorValidPosition: Bool {
        guard let toggleX = toggleButton?.button?.window?.frame.origin.x,
              let separatorX = separatorItem?.button?.window?.frame.origin.x
        else { return false }

        let isLTR = NSApp.userInterfaceLayoutDirection == .leftToRight
        return isLTR ? toggleX >= separatorX : toggleX <= separatorX
    }

    private var isAlwaysHiddenValidPosition: Bool {
        guard settings.hiddenBarAlwaysHiddenEnabled else { return true }
        guard let separatorX = separatorItem?.button?.window?.frame.origin.x,
              let alwaysHiddenX = alwaysHiddenItem?.button?.window?.frame.origin.x
        else { return false }

        let isLTR = NSApp.userInterfaceLayoutDirection == .leftToRight
        return isLTR ? separatorX >= alwaysHiddenX : separatorX <= alwaysHiddenX
    }

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func setup() {
        guard toggleButton == nil else { return }

        toggleButton = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        separatorItem = NSStatusBar.system.statusItem(withLength: separatorLength)

        setupToggleButton()
        setupSeparator()
        setupAlwaysHiddenIfEnabled()

        toggleButton?.autosaveName = "omniwm_hiddenbar_toggle"
        separatorItem?.autosaveName = "omniwm_hiddenbar_separator"

        if settings.hiddenBarIsCollapsed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.collapse()
            }
        }
    }

    private func setupToggleButton() {
        guard let button = toggleButton?.button else { return }
        let imageName = settings.hiddenBarIsCollapsed ? "chevron.right" : "chevron.left"
        button.image = NSImage(systemSymbolName: imageName, accessibilityDescription: "Toggle Hidden Bar")
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(toggleButtonPressed)
        button.sendAction(on: [.leftMouseUp])
    }

    private func setupSeparator() {
        guard let button = separatorItem?.button else { return }
        button.image = NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: "Separator")
        button.image?.isTemplate = true
        button.appearsDisabled = true
    }

    private func setupAlwaysHiddenIfEnabled() {
        if settings.hiddenBarAlwaysHiddenEnabled && alwaysHiddenItem == nil {
            alwaysHiddenItem = NSStatusBar.system.statusItem(withLength: separatorLength)
            if let button = alwaysHiddenItem?.button {
                button.image = NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: "Always Hidden")
                button.image?.isTemplate = true
                button.appearsDisabled = true
            }
            alwaysHiddenItem?.autosaveName = "omniwm_hiddenbar_alwayshidden"
        }
    }

    @objc private func toggleButtonPressed() {
        toggle()
    }

    func toggle() {
        guard !isToggling else { return }
        isToggling = true

        if isCollapsed {
            expand()
        } else {
            collapse()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isToggling = false
        }
    }

    private func collapse() {
        guard isSeparatorValidPosition, !isCollapsed else { return }

        separatorItem?.length = collapseLength
        toggleButton?.button?.image = NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: "Expand Hidden Bar"
        )
        toggleButton?.button?.image?.isTemplate = true
        settings.hiddenBarIsCollapsed = true

        if settings.hiddenBarAlwaysHiddenEnabled, isAlwaysHiddenValidPosition {
            alwaysHiddenItem?.length = collapseLength
        }
    }

    private func expand() {
        guard isCollapsed else { return }

        separatorItem?.length = separatorLength
        toggleButton?.button?.image = NSImage(
            systemSymbolName: "chevron.left",
            accessibilityDescription: "Collapse Hidden Bar"
        )
        toggleButton?.button?.image?.isTemplate = true
        settings.hiddenBarIsCollapsed = false

        if settings.hiddenBarAlwaysHiddenEnabled {
            alwaysHiddenItem?.length = separatorLength
        }
    }

    func cleanup() {
        if let item = toggleButton {
            NSStatusBar.system.removeStatusItem(item)
            toggleButton = nil
        }
        if let item = separatorItem {
            NSStatusBar.system.removeStatusItem(item)
            separatorItem = nil
        }
        if let item = alwaysHiddenItem {
            NSStatusBar.system.removeStatusItem(item)
            alwaysHiddenItem = nil
        }
    }

    func updateAlwaysHiddenSection() {
        if settings.hiddenBarAlwaysHiddenEnabled && alwaysHiddenItem == nil {
            setupAlwaysHiddenIfEnabled()
        } else if !settings.hiddenBarAlwaysHiddenEnabled, let item = alwaysHiddenItem {
            NSStatusBar.system.removeStatusItem(item)
            alwaysHiddenItem = nil
        }
    }
}
