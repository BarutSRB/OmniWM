import AppKit

@MainActor
final class HiddenBarController {
    private let settings: SettingsStore

    private var separatorItem: NSStatusItem?

    private let separatorLength: CGFloat = 8
    private let collapseLength: CGFloat = 10000

    private var isToggling = false

    private var isCollapsed: Bool {
        separatorItem?.length == collapseLength
    }

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func setup() {
        guard separatorItem == nil else { return }

        separatorItem = NSStatusBar.system.statusItem(withLength: separatorLength)
        setupSeparator()
        separatorItem?.autosaveName = "omniwm_hiddenbar_separator"

        if settings.hiddenBarIsCollapsed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.collapse()
            }
        }
    }

    private func setupSeparator() {
        guard let button = separatorItem?.button else { return }
        button.image = NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: "Separator")
        button.image?.isTemplate = true
        button.appearsDisabled = true
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
        guard !isCollapsed else { return }

        separatorItem?.length = collapseLength
        settings.hiddenBarIsCollapsed = true
    }

    private func expand() {
        guard isCollapsed else { return }

        separatorItem?.length = separatorLength
        settings.hiddenBarIsCollapsed = false
    }

    func cleanup() {
        if let item = separatorItem {
            NSStatusBar.system.removeStatusItem(item)
            separatorItem = nil
        }
    }
}
