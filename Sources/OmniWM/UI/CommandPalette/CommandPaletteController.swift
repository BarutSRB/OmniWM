// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Observation
import SwiftUI

@MainActor
@Observable
final class CommandPaletteController: NSObject, NSWindowDelegate {
    private(set) var isVisible = false
    var searchText = "" {
        didSet { updateSelectionAfterFilterChange() }
    }

    var selectedMode: CommandPaletteMode = .windows {
        didSet { handleModeChange(from: oldValue) }
    }

    var selectedItemID: CommandPaletteSelectionID?
    private(set) var windows: [CommandPaletteWindowItem] = [] {
        didSet { updateSelectionAfterFilterChange() }
    }

    private(set) var menuItems: [MenuItemModel] = [] {
        didSet { updateSelectionAfterFilterChange() }
    }

    private(set) var isMenuLoading = false
    private(set) var clipboardItems: [ClipboardPaletteItem] = [] {
        didSet { updateSelectionAfterFilterChange() }
    }

    private(set) var isClipboardHistoryEnabled = false

    private let environment: CommandPaletteEnvironment
    private let presentation: CommandPalettePanel
    private var eventMonitor: Any?

    private weak var wmController: WMController?
    private let focusSession: CommandPaletteFocusSession
    private let actionExecutor: CommandPaletteActionExecutor
    private let menuSession: CommandPaletteMenuSession
    private var isProgrammaticDismiss = false

    private enum DismissReason {
        case cancel
        case selection
        case deactivation
        case superseded
    }

    init(
        motionPolicy: MotionPolicy,
        environment: CommandPaletteEnvironment = .init(),
        ownedWindowRegistry: OwnedWindowRegistry = .shared
    ) {
        self.environment = environment
        menuSession = CommandPaletteMenuSession(environment: environment)
        let focusSession = CommandPaletteFocusSession(environment: environment)
        self.focusSession = focusSession
        actionExecutor = CommandPaletteActionExecutor(environment: environment, focusSession: focusSession)
        presentation = CommandPalettePanel(motionPolicy: motionPolicy, ownedWindowRegistry: ownedWindowRegistry)
        super.init()
    }

    var filteredWindowItems: [CommandPaletteWindowItem] {
        CommandPaletteSearch.filterWindowItems(windows, query: searchText)
    }

    var filteredMenuItems: [MenuItemModel] {
        CommandPaletteSearch.filterMenuItems(menuItems, query: searchText)
    }

    var filteredClipboardItems: [ClipboardPaletteItem] {
        CommandPaletteSearch.filterClipboardItems(clipboardItems, query: searchText)
    }

    var isMenuModeAvailable: Bool {
        CommandPalettePresentation.menuModeAvailable(hasMenuFocusTarget: focusSession.menuFocusTarget != nil)
    }

    var isSummonRightAvailable: Bool {
        focusSession.summonAnchor != nil
    }

    var menuStatusText: String {
        if let menuFocusTarget = focusSession.menuFocusTarget {
            return CommandPalettePresentation.availableMenuStatusText(for: menuFocusTarget.app.localizedName)
        }
        return CommandPalettePresentation.unavailableMenuStatusText
    }

    var clipboardStatusText: String {
        guard isClipboardHistoryEnabled else {
            return "Clipboard history is disabled."
        }
        if clipboardItems.isEmpty {
            return "Clipboard history is empty."
        }
        return "Enter pastes. Shift-Enter copies."
    }

    func toggle(wmController: WMController) {
        if isVisible {
            dismiss(reason: .cancel)
        } else {
            show(wmController: wmController)
        }
    }

    func show(wmController: WMController) {
        if isVisible {
            dismiss(reason: .superseded)
        }

        self.wmController = wmController

        focusSession.begin(wmController: wmController)
        windows = CommandPaletteSearch.buildWindowItems(from: wmController)
        menuItems = []
        isClipboardHistoryEnabled = environment.isClipboardHistoryEnabled(wmController)
        clipboardItems = isClipboardHistoryEnabled ? environment.clipboardItems(wmController) : []
        menuSession.resetCache()
        isMenuLoading = false
        searchText = ""
        selectedItemID = nil
        menuSession.invalidate()

        if presentation.panel == nil {
            presentation.create(controller: self)
        }

        guard let panel = presentation.panel else { return }

        presentation.position(panel)

        let preferredMode = wmController.settings.commandPaletteLastMode
        selectedMode = resolvedInitialMode(preferredMode)

        installEventMonitor()

        isVisible = true
        panel.makeKeyAndOrderFront(nil)
        environment.activateOmniWM()

        if selectedMode == .menu {
            loadMenuItemsIfNeeded()
        }

        DispatchQueue.main.async { [weak self] in
            self?.presentation.focusSearchField()
        }
    }

    func windowDidResignKey(_: Notification) {
        guard isVisible, !isProgrammaticDismiss else { return }
        dismiss(reason: .deactivation)
    }

    private func handleModeChange(from oldValue: CommandPaletteMode) {
        guard selectedMode != oldValue else { return }
        guard isModeAvailable(selectedMode) else {
            selectedMode = .windows
            return
        }
        wmController?.settings.commandPaletteLastMode = selectedMode
        if selectedMode == .menu {
            loadMenuItemsIfNeeded()
        } else if selectedMode == .clipboard {
            refreshClipboardItems()
        }
        updateSelectionAfterFilterChange()
        DispatchQueue.main.async { [weak self] in
            self?.presentation.focusSearchField()
        }
    }

    private func resolvedInitialMode(_ preferredMode: CommandPaletteMode) -> CommandPaletteMode {
        isModeAvailable(preferredMode) ? preferredMode : .windows
    }

    private func isModeAvailable(_ mode: CommandPaletteMode) -> Bool {
        switch mode {
        case .windows,
             .clipboard:
            return true
        case .menu:
            return isMenuModeAvailable
        }
    }

    private func loadMenuItemsIfNeeded() {
        guard isVisible, selectedMode == .menu else { return }
        guard isMenuModeAvailable else {
            menuItems = []
            isMenuLoading = false
            return
        }
        menuSession.load(target: focusSession.menuFocusTarget, canStart: { [weak self] in
            self?.isVisible == true && self?.selectedMode == .menu
        }, canPublish: { [weak self] in
            self?.isVisible == true
        }, publish: { [weak self] publication in
            guard let self else { return }
            switch publication {
            case .loading:
                self.isMenuLoading = true
                self.menuItems = []
            case let .loaded(items):
                self.menuItems = items
                self.isMenuLoading = false
            }
        })
    }

    func selectCurrent(trigger: CommandPaletteSelectionTrigger = .primary) {
        guard let action = resolvedSelectionAction(for: trigger) else { return }
        dismiss(reason: .selection)
        actionExecutor.perform(action)
    }

    private func dismiss(reason: DismissReason) {
        removeEventMonitor()
        isVisible = false
        isMenuLoading = false
        menuSession.invalidate()

        isProgrammaticDismiss = true
        presentation.panel?.orderOut(nil)
        isProgrammaticDismiss = false

        let restoreTarget = reason == .cancel ? focusSession.restoreFocusTarget : nil

        focusSession.clear()
        wmController = nil
        menuSession.resetCache()
        searchText = ""
        selectedItemID = nil
        windows = []
        menuItems = []
        clipboardItems = []
        isClipboardHistoryEnabled = false

        if let restoreTarget {
            _ = focusSession.focus(target: restoreTarget)
        }
    }

    private func resolvedSelectionAction(
        for trigger: CommandPaletteSelectionTrigger
    ) -> CommandPaletteActionExecutor.Action? {
        switch selectedMode {
        case .windows:
            let filtered = filteredWindowItems
            guard let wmController,
                  case let .window(token)? = selectedItemID,
                  let item = filtered.first(where: { $0.id == token })
            else {
                return nil
            }
            switch trigger {
            case .primary:
                return .navigateWindow(wmController, item.handle)
            case .alternate:
                guard CommandPalettePresentation.allowsSummonRight(item),
                      let summonAnchor = focusSession.summonAnchor else { return nil }
                return .summonWindowRight(wmController, item.handle, summonAnchor)
            }
        case .menu:
            let filtered = filteredMenuItems
            guard case let .menu(id)? = selectedItemID,
                  let item = filtered.first(where: { $0.id == id }),
                  let menuFocusTarget = focusSession.menuFocusTarget
            else {
                return nil
            }
            return .pressMenu(menuFocusTarget, item.axElement)
        case .clipboard:
            guard let wmController,
                  isClipboardHistoryEnabled,
                  case let .clipboard(id)? = selectedItemID,
                  filteredClipboardItems.contains(where: { $0.id == id })
            else {
                return nil
            }
            switch trigger {
            case .primary:
                return .pasteClipboard(wmController, id, focusSession.clipboardPasteTarget())
            case .alternate:
                return .copyClipboard(wmController, id)
            }
        }
    }

    func enableClipboardHistory() {
        guard let wmController else { return }
        environment.setClipboardHistoryEnabled(wmController, true)
        isClipboardHistoryEnabled = true
        refreshClipboardItems()
    }

    func refreshClipboardItems() {
        guard let wmController else {
            clipboardItems = []
            return
        }
        isClipboardHistoryEnabled = environment.isClipboardHistoryEnabled(wmController)
        clipboardItems = isClipboardHistoryEnabled ? environment.clipboardItems(wmController) : []
    }

    func copyClipboardItem(_ id: UUID) {
        guard let wmController else { return }
        Task { @MainActor [weak self, environment, wmController] in
            _ = await environment.copyClipboardItem(wmController, id)
            self?.refreshClipboardItems()
        }
    }

    func deleteClipboardItem(_ id: UUID) {
        guard let wmController else { return }
        Task { @MainActor [weak self, environment, wmController] in
            self?.clipboardItems = await environment.deleteClipboardItem(wmController, id)
        }
    }

    func clearClipboardHistory() {
        guard let wmController, environment.confirmClearClipboardHistory() else { return }
        Task { @MainActor [weak self, environment, wmController] in
            self?.clipboardItems = await environment.clearClipboardHistory(wmController)
        }
    }

    private func currentSelectionList() -> [CommandPaletteSelectionID] {
        switch selectedMode {
        case .windows:
            return filteredWindowItems.map { CommandPaletteSelectionID.window($0.id) }
        case .menu:
            return filteredMenuItems.map { CommandPaletteSelectionID.menu($0.id) }
        case .clipboard:
            guard isClipboardHistoryEnabled else { return [] }
            return filteredClipboardItems.map { CommandPaletteSelectionID.clipboard($0.id) }
        }
    }

    private func updateSelectionAfterFilterChange() {
        let selectionList = currentSelectionList()
        if selectionList.isEmpty {
            selectedItemID = nil
            return
        }

        if let selectedItemID, !selectionList.contains(selectedItemID) {
            self.selectedItemID = selectionList.first
        } else if selectedItemID == nil {
            selectedItemID = selectionList.first
        }
    }
}

extension CommandPaletteController {
    private func installEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, isVisible else { return event }
            return handleKeyDown(event) ? nil : event
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let relevantModifiers = event.modifierFlags.intersection([.shift, .command, .control, .option])

        if let targetMode = CommandPalettePresentation.modeNavigationTarget(
            currentMode: selectedMode,
            isMenuModeAvailable: isMenuModeAvailable,
            keyCode: event.keyCode,
            relevantModifiers: relevantModifiers,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) {
            selectedMode = targetMode
            return true
        }

        switch event.keyCode {
        case 53:
            dismiss(reason: .cancel)
            return true
        case 126:
            moveSelection(by: -1)
            return true
        case 125:
            moveSelection(by: 1)
            return true
        default:
            guard let trigger = Self.selectionTrigger(
                forKeyCode: event.keyCode,
                modifierFlags: relevantModifiers
            ) else {
                return false
            }
            selectCurrent(trigger: trigger)
            return true
        }
    }

    private static func selectionTrigger(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> CommandPaletteSelectionTrigger? {
        switch keyCode {
        case 36,
             76:
            return modifierFlags == .shift ? .alternate : .primary
        default:
            return nil
        }
    }

    func moveSelection(by delta: Int) {
        let selectionList = currentSelectionList()
        guard !selectionList.isEmpty else { return }

        let currentIndex: Int = if let selectedItemID,
                                   let idx = selectionList.firstIndex(of: selectedItemID)
        {
            idx
        } else {
            0
        }

        let newIndex = (currentIndex + delta + selectionList.count) % selectionList.count
        selectedItemID = selectionList[newIndex]
    }
}
