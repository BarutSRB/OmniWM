import AppKit

private let menuWidth: CGFloat = 280

enum SettingsMenuAction {
    case export(SettingsExportMode)
    case `import`
    case revealSettingsFile
    case openSettingsFile
}

@MainActor
private func applyCurrentAppAppearance(to view: NSView) {
    view.appearance = NSApplication.shared.appearance
}

@MainActor
final class StatusBarMenuBuilder {
    private let settings: SettingsStore
    private weak var controller: WMController?
    var infoAlertPresenter: (String, String) -> Void

    private var toggleViews: [String: MenuToggleRowView] = [:]

    init(settings: SettingsStore, controller: WMController) {
        self.settings = settings
        self.controller = controller
        infoAlertPresenter = { title, message in
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            NSApplication.shared.activate(ignoringOtherApps: true)
            _ = alert.runModal()
        }
    }

    func buildMenu() -> NSMenu {
        toggleViews.removeAll(keepingCapacity: true)

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.appearance = NSApplication.shared.appearance

        let headerItem = NSMenuItem()
        headerItem.view = createHeaderView()
        menu.addItem(headerItem)

        menu.addItem(createDivider())

        menu.addItem(createSectionLabel("CONTROLS"))
        addControlsSection(to: menu)

        menu.addItem(createDivider())

        menu.addItem(createSectionLabel("SETTINGS"))
        addSettingsSection(to: menu)

        menu.addItem(createDivider())

        menu.addItem(createSectionLabel("LINKS"))
        addLinksSection(to: menu)

        menu.addItem(createDivider())

        addSponsorsSection(to: menu)

        menu.addItem(createDivider())

        addQuitSection(to: menu)

        return menu
    }

    func updateToggles() {
        toggleViews["focusFollowsMouse"]?.isOn = settings.focusFollowsMouse
        toggleViews["focusFollowsWindowToMonitor"]?.isOn = settings.focusFollowsWindowToMonitor
        toggleViews["moveMouseToFocusedWindow"]?.isOn = settings.moveMouseToFocusedWindow
        toggleViews["bordersEnabled"]?.isOn = settings.bordersEnabled
        toggleViews["workspaceBarEnabled"]?.isOn = settings.workspaceBarEnabled
        toggleViews["preventSleepEnabled"]?.isOn = settings.preventSleepEnabled
    }

    private func createHeaderView() -> NSView {
        MenuHeaderView()
    }

    private func createDivider() -> NSMenuItem {
        let item = NSMenuItem()
        item.view = MenuDividerView()
        return item
    }

    private func createSectionLabel(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = MenuSectionLabelView(text: text)
        return item
    }

    private func addControlsSection(to menu: NSMenu) {
        let focusToggle = MenuToggleRowView(
            icon: "cursorarrow.motionlines",
            label: "Focus Follows Mouse",
            isOn: settings.focusFollowsMouse
        ) { [weak self] newValue in
            self?.settings.focusFollowsMouse = newValue
            self?.controller?.setFocusFollowsMouse(newValue)
        }
        toggleViews["focusFollowsMouse"] = focusToggle
        let focusItem = NSMenuItem()
        focusItem.view = focusToggle
        menu.addItem(focusItem)

        let followMoveToggle = MenuToggleRowView(
            icon: "arrow.right.square",
            label: "Follow Window to Workspace",
            isOn: settings.focusFollowsWindowToMonitor
        ) { [weak self] newValue in
            self?.settings.focusFollowsWindowToMonitor = newValue
        }
        toggleViews["focusFollowsWindowToMonitor"] = followMoveToggle
        let followMoveItem = NSMenuItem()
        followMoveItem.view = followMoveToggle
        menu.addItem(followMoveItem)

        let mouseToFocusedToggle = MenuToggleRowView(
            icon: "arrow.up.left.and.down.right.magnifyingglass",
            label: "Mouse to Focused",
            isOn: settings.moveMouseToFocusedWindow
        ) { [weak self] newValue in
            self?.settings.moveMouseToFocusedWindow = newValue
            self?.controller?.setMoveMouseToFocusedWindow(newValue)
        }
        toggleViews["moveMouseToFocusedWindow"] = mouseToFocusedToggle
        let mouseItem = NSMenuItem()
        mouseItem.view = mouseToFocusedToggle
        menu.addItem(mouseItem)

        let bordersToggle = MenuToggleRowView(
            icon: "square.dashed",
            label: "Window Borders",
            isOn: settings.bordersEnabled
        ) { [weak self] newValue in
            self?.settings.bordersEnabled = newValue
            self?.controller?.setBordersEnabled(newValue)
        }
        toggleViews["bordersEnabled"] = bordersToggle
        let bordersItem = NSMenuItem()
        bordersItem.view = bordersToggle
        menu.addItem(bordersItem)

        let workspaceBarToggle = MenuToggleRowView(
            icon: "menubar.rectangle",
            label: "Workspace Bar",
            isOn: settings.workspaceBarEnabled
        ) { [weak self] newValue in
            self?.settings.workspaceBarEnabled = newValue
            self?.controller?.setWorkspaceBarEnabled(newValue)
        }
        toggleViews["workspaceBarEnabled"] = workspaceBarToggle
        let workspaceItem = NSMenuItem()
        workspaceItem.view = workspaceBarToggle
        menu.addItem(workspaceItem)

        let keepAwakeToggle = MenuToggleRowView(
            icon: "moon.zzz",
            label: "Keep Awake",
            isOn: settings.preventSleepEnabled
        ) { [weak self] newValue in
            self?.settings.preventSleepEnabled = newValue
            self?.controller?.setPreventSleepEnabled(newValue)
        }
        toggleViews["preventSleepEnabled"] = keepAwakeToggle
        let keepAwakeItem = NSMenuItem()
        keepAwakeItem.view = keepAwakeToggle
        menu.addItem(keepAwakeItem)
    }

    private func addSettingsSection(to menu: NSMenu) {
        let appRulesRow = MenuActionRowView(
            icon: "slider.horizontal.3",
            label: "App Rules",
            showChevron: true
        ) { [weak self] in
            guard let self, let controller = self.controller else { return }
            AppRulesWindowController.shared.show(settings: self.settings, controller: controller)
        }
        let appRulesItem = NSMenuItem()
        appRulesItem.view = appRulesRow
        menu.addItem(appRulesItem)

        let settingsRow = MenuActionRowView(
            icon: "gearshape",
            label: "Settings",
            showChevron: true
        ) { [weak self] in
            guard let self, let controller = self.controller else { return }
            SettingsWindowController.shared.show(settings: self.settings, controller: controller)
        }
        let settingsItem = NSMenuItem()
        settingsItem.view = settingsRow
        menu.addItem(settingsItem)

        let exportEditableRow = MenuActionRowView(
            icon: "square.and.arrow.up",
            label: "Export Editable Config"
        ) { [weak self] in
            self?.performSettingsMenuAction(.export(.full))
        }
        let exportEditableItem = NSMenuItem()
        exportEditableItem.view = exportEditableRow
        menu.addItem(exportEditableItem)

        let exportCompactRow = MenuActionRowView(
            icon: "archivebox",
            label: "Export Compact Backup"
        ) { [weak self] in
            self?.performSettingsMenuAction(.export(.compact))
        }
        let exportCompactItem = NSMenuItem()
        exportCompactItem.view = exportCompactRow
        menu.addItem(exportCompactItem)

        let importSettingsRow = MenuActionRowView(
            icon: "square.and.arrow.down",
            label: "Import Settings"
        ) { [weak self] in
            self?.performSettingsMenuAction(.import)
        }
        let importSettingsItem = NSMenuItem()
        importSettingsItem.view = importSettingsRow
        menu.addItem(importSettingsItem)

        let revealSettingsFileRow = MenuActionRowView(
            icon: "folder",
            label: "Reveal Settings File"
        ) { [weak self] in
            self?.performSettingsMenuAction(.revealSettingsFile)
        }
        let revealSettingsFileItem = NSMenuItem()
        revealSettingsFileItem.view = revealSettingsFileRow
        menu.addItem(revealSettingsFileItem)

        let openSettingsFileRow = MenuActionRowView(
            icon: "doc.text",
            label: "Open Settings File"
        ) { [weak self] in
            self?.performSettingsMenuAction(.openSettingsFile)
        }
        let openSettingsFileItem = NSMenuItem()
        openSettingsFileItem.view = openSettingsFileRow
        menu.addItem(openSettingsFileItem)
    }

    func performSettingsMenuAction(_ action: SettingsMenuAction) {
        switch action {
        case .export(let mode):
            exportSettings(mode: mode)
        case .import:
            importSettings()
        case .revealSettingsFile:
            revealSettingsFile()
        case .openSettingsFile:
            openSettingsFile()
        }
    }

    private func exportSettings(mode: SettingsExportMode) {
        do {
            try settings.exportSettings(mode: mode)
            presentInfoAlert(
                title: mode == .full ? "Editable Config Exported" : "Compact Backup Exported",
                message: SettingsStore.exportURL.path
            )
        } catch {
            presentInfoAlert(
                title: "Could Not Export Settings",
                message: error.localizedDescription
            )
        }
    }

    private func ensureSettingsFileExists() throws -> Bool {
        guard !settings.settingsFileExists else { return false }
        try settings.exportSettings(mode: .full)
        return true
    }

    private func importSettings() {
        do {
            guard let controller else {
                throw CocoaError(.coderInvalidValue)
            }
            try settings.importSettings(applyingTo: controller)
            presentInfoAlert(
                title: "Settings Imported",
                message: SettingsStore.exportURL.path
            )
        } catch {
            presentInfoAlert(
                title: "Could Not Import Settings",
                message: error.localizedDescription
            )
        }
    }

    private func revealSettingsFile() {
        do {
            let created = try ensureSettingsFileExists()
            NSWorkspace.shared.activateFileViewerSelecting([SettingsStore.exportURL])
            presentInfoAlert(
                title: created ? "Settings File Created" : "Settings File Revealed",
                message: SettingsStore.exportURL.path
            )
        } catch {
            presentInfoAlert(
                title: "Could Not Reveal Settings File",
                message: error.localizedDescription
            )
        }
    }

    private func openSettingsFile() {
        do {
            let created = try ensureSettingsFileExists()
            guard NSWorkspace.shared.open(SettingsStore.exportURL) else {
                throw CocoaError(.fileNoSuchFile)
            }
            presentInfoAlert(
                title: created ? "Settings File Created" : "Settings File Opened",
                message: SettingsStore.exportURL.path
            )
        } catch {
            presentInfoAlert(
                title: "Could Not Open Settings File",
                message: error.localizedDescription
            )
        }
    }

    private func presentInfoAlert(title: String, message: String) {
        infoAlertPresenter(title, message)
    }

    private func addLinksSection(to menu: NSMenu) {
        let githubRow = MenuActionRowView(
            icon: "link",
            label: "GitHub",
            isExternal: true
        ) {
            if let url = URL(string: "https://github.com/BarutSRB/OmniWM") {
                NSWorkspace.shared.open(url)
            }
        }
        let githubItem = NSMenuItem()
        githubItem.view = githubRow
        menu.addItem(githubItem)

        let sponsorGithubRow = MenuActionRowView(
            icon: "heart",
            label: "Sponsor on GitHub",
            isExternal: true
        ) {
            if let url = URL(string: "https://github.com/sponsors/BarutSRB") {
                NSWorkspace.shared.open(url)
            }
        }
        let sponsorGithubItem = NSMenuItem()
        sponsorGithubItem.view = sponsorGithubRow
        menu.addItem(sponsorGithubItem)

        let sponsorPaypalRow = MenuActionRowView(
            icon: "heart",
            label: "Sponsor on PayPal",
            isExternal: true
        ) {
            if let url = URL(string: "https://paypal.me/beacon2024") {
                NSWorkspace.shared.open(url)
            }
        }
        let sponsorPaypalItem = NSMenuItem()
        sponsorPaypalItem.view = sponsorPaypalRow
        menu.addItem(sponsorPaypalItem)
    }

    private func addSponsorsSection(to menu: NSMenu) {
        let sponsorsRow = MenuActionRowView(
            icon: "sparkles",
            label: "Omni Sponsors"
        ) {
            SponsorsWindowController.shared.show()
        }
        let sponsorsItem = NSMenuItem()
        sponsorsItem.view = sponsorsRow
        menu.addItem(sponsorsItem)
    }

    private func addQuitSection(to menu: NSMenu) {
        let quitRow = MenuActionRowView(
            icon: "power",
            label: "Quit OmniWM",
            isDestructive: true
        ) {
            NSApplication.shared.terminate(nil)
        }
        let quitItem = NSMenuItem()
        quitItem.view = quitRow
        menu.addItem(quitItem)
    }
}

final class MenuHeaderView: NSView {
    private var appVersion: String {
        Bundle.main.appVersion ?? "0.3.1"
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 56))
        applyCurrentAppAppearance(to: self)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        let iconContainer = NSView(frame: NSRect(x: 12, y: 10, width: 36, height: 36))
        iconContainer.wantsLayer = true
        iconContainer.layer?.cornerRadius = 18
        iconContainer.layer?.backgroundColor = NSColor(calibratedRed: 0.3, green: 0.4, blue: 0.8, alpha: 0.2).cgColor
        addSubview(iconContainer)

        let iconImageView = NSImageView(frame: NSRect(x: 9, y: 9, width: 18, height: 18))
        if let iconImage = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            iconImageView.image = iconImage.withSymbolConfiguration(config)
            iconImageView.contentTintColor = .labelColor
        }
        iconContainer.addSubview(iconImageView)

        let titleLabel = NSTextField(labelWithString: "OmniWM")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 56, y: 28, width: 80, height: 18)
        addSubview(titleLabel)

        let statusDot = NSView(frame: NSRect(x: 140, y: 33, width: 6, height: 6))
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3
        statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        addSubview(statusDot)

        let versionLabel = NSTextField(labelWithString: "v\(appVersion)")
        versionLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.frame = NSRect(x: 56, y: 10, width: 80, height: 14)
        addSubview(versionLabel)
    }
}

final class MenuSectionLabelView: NSView {
    init(text: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 24))
        applyCurrentAppAppearance(to: self)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .tertiaryLabelColor
        label.frame = NSRect(x: 14, y: 4, width: menuWidth - 28, height: 12)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class MenuDividerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 9))
        applyCurrentAppAppearance(to: self)

        let divider = NSBox(frame: NSRect(x: 8, y: 4, width: menuWidth - 16, height: 1))
        divider.boxType = .separator
        addSubview(divider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class MenuToggleSwitchView: NSView {
    var isOn: Bool {
        didSet {
            guard oldValue != isOn else { return }
            updateAppearance(animated: true)
        }
    }

    var onToggle: ((Bool) -> Void)?

    private let trackLayer = CALayer()
    private let thumbLayer = CALayer()
    private var trackingAreaRef: NSTrackingArea?
    private var isHovered: Bool = false

    override var isFlipped: Bool { true }

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: 42, height: 22))
        applyCurrentAppAppearance(to: self)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        trackLayer.cornerCurve = .continuous
        thumbLayer.cornerCurve = .continuous
        thumbLayer.backgroundColor = NSColor.white.cgColor
        thumbLayer.shadowColor = NSColor.black.withAlphaComponent(0.18).cgColor
        thumbLayer.shadowOpacity = 1
        thumbLayer.shadowRadius = 1.8
        thumbLayer.shadowOffset = CGSize(width: 0, height: 0.6)

        layer?.addSublayer(trackLayer)
        layer?.addSublayer(thumbLayer)
        updateAppearance(animated: false)
        updateTrackingAreas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateAppearance(animated: false)
    }

    override func updateTrackingAreas() {
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance(animated: true)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hoveredNow = bounds.contains(point)
        guard hoveredNow != isHovered else { return }
        isHovered = hoveredNow
        updateAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        onToggle?(isOn)
    }

    private func updateAppearance(animated: Bool) {
        let inset: CGFloat = 2
        let thumbSize = max(0, bounds.height - inset * 2)
        let thumbX = isOn
            ? bounds.width - inset - thumbSize
            : inset

        let onColor = NSColor.systemGreen.withAlphaComponent(isHovered ? 1.0 : 0.95).cgColor
        let offColor = NSColor(white: isHovered ? 0.32 : 0.26, alpha: 1.0).cgColor
        let targetTrack = isOn ? onColor : offColor

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(animated ? 0.14 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        trackLayer.frame = bounds
        trackLayer.cornerRadius = bounds.height / 2
        trackLayer.backgroundColor = targetTrack

        thumbLayer.frame = NSRect(x: thumbX, y: inset, width: thumbSize, height: thumbSize)
        thumbLayer.cornerRadius = thumbSize / 2
        CATransaction.commit()
    }
}

final class MenuToggleRowView: NSView {
    var isOn: Bool {
        get { toggle.isOn }
        set {
            toggle.isOn = newValue
        }
    }

    private let toggle: MenuToggleSwitchView
    private let onChange: (Bool) -> Void
    private var trackingArea: NSTrackingArea?
    private var backgroundLayer: CALayer?
    private var iconView: NSImageView?
    private var labelField: NSTextField?

    init(icon: String, label: String, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        self.toggle = MenuToggleSwitchView(isOn: isOn)
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 28))
        applyCurrentAppAppearance(to: self)

        wantsLayer = true

        backgroundLayer = CALayer()
        backgroundLayer?.cornerRadius = 6
        backgroundLayer?.cornerCurve = .continuous
        backgroundLayer?.backgroundColor = .clear
        layer?.addSublayer(backgroundLayer!)

        if let iconImage = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
            let iconView = NSImageView(frame: NSRect(x: 12, y: 6, width: 16, height: 16))
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            iconView.image = iconImage.withSymbolConfiguration(config)
            iconView.contentTintColor = .secondaryLabelColor
            addSubview(iconView)
            self.iconView = iconView
        }

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 13)
        labelField.textColor = .labelColor
        labelField.frame = NSRect(x: 38, y: 5, width: menuWidth - 100, height: 18)
        addSubview(labelField)
        self.labelField = labelField

        toggle.frame = NSRect(x: menuWidth - 54, y: 3, width: 42, height: 22)
        toggle.onToggle = { [weak self] newValue in
            self?.onChange(newValue)
        }
        addSubview(toggle)

        updateTrackingAreas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHovered(bounds.contains(point))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func layout() {
        super.layout()
        backgroundLayer?.frame = NSRect(x: 4, y: 2, width: menuWidth - 8, height: 24)
    }

    private func setHovered(_ hovered: Bool) {
        backgroundLayer?.frame = NSRect(x: 4, y: 2, width: menuWidth - 8, height: 24)
        let targetBackground = hovered
            ? NSColor.controlAccentColor.withAlphaComponent(0.34).cgColor
            : NSColor.clear.cgColor

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        backgroundLayer?.backgroundColor = targetBackground
        CATransaction.commit()

        iconView?.contentTintColor = hovered ? .white : .secondaryLabelColor
        labelField?.textColor = hovered ? .white : .labelColor
    }
}

final class MenuActionRowView: NSView {
    private let action: () -> Void
    private let isDestructive: Bool
    private var trackingArea: NSTrackingArea?
    private var backgroundLayer: CALayer?
    private var iconView: NSImageView?
    private var labelField: NSTextField?
    private var isHovered = false

    init(
        icon: String,
        label: String,
        showChevron: Bool = false,
        isExternal: Bool = false,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.action = action
        self.isDestructive = isDestructive
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 28))
        applyCurrentAppAppearance(to: self)

        wantsLayer = true

        backgroundLayer = CALayer()
        backgroundLayer?.cornerRadius = 6
        backgroundLayer?.backgroundColor = .clear
        layer?.addSublayer(backgroundLayer!)

        if let iconImage = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
            let iv = NSImageView(frame: NSRect(x: 12, y: 6, width: 16, height: 16))
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            iv.image = iconImage.withSymbolConfiguration(config)
            iv.contentTintColor = .secondaryLabelColor
            addSubview(iv)
            iconView = iv
        }

        let lf = NSTextField(labelWithString: label)
        lf.font = .systemFont(ofSize: 13)
        lf.textColor = .labelColor
        lf.frame = NSRect(x: 38, y: 5, width: menuWidth - 70, height: 18)
        addSubview(lf)
        labelField = lf

        if showChevron {
            if let chevronImage = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) {
                let chevronView = NSImageView(frame: NSRect(x: menuWidth - 24, y: 8, width: 10, height: 12))
                let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                chevronView.image = chevronImage.withSymbolConfiguration(config)
                chevronView.contentTintColor = .tertiaryLabelColor
                addSubview(chevronView)
            }
        }

        if isExternal {
            if let externalImage = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil) {
                let externalView = NSImageView(frame: NSRect(x: menuWidth - 24, y: 8, width: 10, height: 12))
                let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
                externalView.image = externalImage.withSymbolConfiguration(config)
                externalView.contentTintColor = .tertiaryLabelColor
                addSubview(externalView)
            }
        }

        updateTrackingAreas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        setHoveredStyle(true)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hoveredNow = bounds.contains(point)
        guard hoveredNow != isHovered else { return }
        isHovered = hoveredNow
        setHoveredStyle(hoveredNow)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        setHoveredStyle(false)
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) {
            if let menu = enclosingMenuItem?.menu {
                menu.cancelTracking()
            }
            DispatchQueue.main.async { [weak self] in
                self?.action()
            }
        }
    }

    override func layout() {
        super.layout()
        backgroundLayer?.frame = NSRect(x: 4, y: 2, width: menuWidth - 8, height: 24)
    }

    private func setHoveredStyle(_ hovered: Bool) {
        backgroundLayer?.frame = NSRect(x: 4, y: 2, width: menuWidth - 8, height: 24)

        let background: CGColor
        if hovered {
            if isDestructive {
                background = NSColor.systemRed.withAlphaComponent(0.14).cgColor
            } else {
                background = NSColor.controlAccentColor.withAlphaComponent(0.32).cgColor
            }
        } else {
            background = NSColor.clear.cgColor
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        backgroundLayer?.backgroundColor = background
        CATransaction.commit()

        if isDestructive && hovered {
            iconView?.contentTintColor = .systemRed
            labelField?.textColor = .systemRed
        } else {
            iconView?.contentTintColor = hovered ? .white : .secondaryLabelColor
            labelField?.textColor = hovered ? .white : .labelColor
        }
    }
}
