// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
import Foundation

@MainActor
final class OverviewInputHandler {
    enum KeyAction: Equatable {
        case dismissSelection
        case activateSelection
        case closeSelection
        case navigate(Direction)
        case cycleSelection(forward: Bool)
        case deleteBackward
        case appendToSearch(String)
        case consume
    }

    struct KeyHandlingResult: Equatable {
        let action: KeyAction
        let shouldConsume: Bool
    }

    private enum KeyCode {
        static let escape = UInt16(kVK_Escape)
        static let returnKey = UInt16(kVK_Return)
        static let keypadEnter = UInt16(kVK_ANSI_KeypadEnter)
        static let leftArrow = UInt16(kVK_LeftArrow)
        static let rightArrow = UInt16(kVK_RightArrow)
        static let downArrow = UInt16(kVK_DownArrow)
        static let upArrow = UInt16(kVK_UpArrow)
        static let tab = UInt16(kVK_Tab)
        static let delete = UInt16(kVK_Delete)
        static let closeWindow = UInt16(kVK_ANSI_W)
    }

    private weak var controller: OverviewController?
    private let projection: OverviewViewportProjection
    private let windowSession: OverviewWindowSession
    private let focusSession: OverviewFocusSession
    private let overviewSnapshot: OverviewSnapshot
    private var state: OverviewState {
        controller?.state ?? .closed
    }

    var searchQuery: String = ""

    init(
        projection: OverviewViewportProjection,
        windowSession: OverviewWindowSession,
        focusSession: OverviewFocusSession,
        snapshot: OverviewSnapshot
    ) {
        self.projection = projection
        self.windowSession = windowSession
        self.focusSession = focusSession
        overviewSnapshot = snapshot
    }

    func connect(controller: OverviewController) {
        self.controller = controller
    }

    private func updateWindowDisplays() {
        windowSession.updateWindowDisplays(state: state)
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let controller else { return false }
        guard controller.state.isOpen else { return false }

        let result = Self.keyHandlingResult(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            searchQuery: searchQuery,
            isRepeat: event.isARepeat
        )
        guard result.shouldConsume else { return false }

        switch controller.state {
        case .closed:
            return false
        case .closing:
            return true
        case .opening:
            switch result.action {
            case .dismissSelection:
                dismissToSelection(animated: true)
            case .activateSelection:
                dismissToSelection(animated: true)
            case .closeSelection,
                 .navigate,
                 .cycleSelection,
                 .deleteBackward,
                 .appendToSearch,
                 .consume:
                break
            }
            return true
        case .open:
            break
        }

        performAction(result.action, controller: controller)
        return true
    }

    private func performAction(_ action: KeyAction, controller: OverviewController) {
        switch action {
        case .dismissSelection:
            dismissToSelection(animated: true)
        case .activateSelection:
            activateSelectedWindow()
        case .closeSelection:
            closeSelectedWindow()
        case let .navigate(direction):
            navigateSelection(direction)
        case let .cycleSelection(forward):
            cycleSelection(forward: forward)
        case .deleteBackward:
            if !searchQuery.isEmpty {
                searchQuery = String(searchQuery.dropLast())
                updateSearchQuery(searchQuery)
            }
        case let .appendToSearch(text):
            searchQuery += text
            updateSearchQuery(searchQuery)
        case .consume:
            break
        }
    }

    static func keyHandlingResult(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?,
        searchQuery _: String,
        isRepeat: Bool = false
    ) -> KeyHandlingResult {
        let relevantModifiers = modifierFlags.intersection([.shift, .command, .control, .option])

        switch keyCode {
        case KeyCode.escape:
            guard !isRepeat else { return .init(action: .consume, shouldConsume: true) }
            return .init(action: .dismissSelection, shouldConsume: true)
        case KeyCode.returnKey,
             KeyCode.keypadEnter:
            guard relevantModifiers.isEmpty else { break }
            guard !isRepeat else { return .init(action: .consume, shouldConsume: true) }
            return .init(action: .activateSelection, shouldConsume: true)
        case KeyCode.leftArrow,
             KeyCode.rightArrow,
             KeyCode.downArrow,
             KeyCode.upArrow:
            guard relevantModifiers.isEmpty, let direction = navigationDirection(for: keyCode) else { break }
            return .init(action: .navigate(direction), shouldConsume: true)
        case KeyCode.tab:
            guard relevantModifiers.isEmpty || relevantModifiers == .shift else { break }
            return .init(
                action: .cycleSelection(forward: !relevantModifiers.contains(.shift)),
                shouldConsume: true
            )
        case KeyCode.delete:
            guard relevantModifiers.isEmpty else { break }
            return .init(action: .deleteBackward, shouldConsume: true)
        case KeyCode.closeWindow:
            guard relevantModifiers == .command else { break }
            guard !isRepeat else { return .init(action: .consume, shouldConsume: true) }
            return .init(action: .closeSelection, shouldConsume: true)
        default:
            if relevantModifiers.isDisjoint(with: [.command, .control, .option]),
               let charactersIgnoringModifiers,
               let character = charactersIgnoringModifiers.first,
               charactersIgnoringModifiers.count == 1,
               character.isLetter || character.isNumber || character == " "
            {
                return .init(action: .appendToSearch(String(character)), shouldConsume: true)
            }
        }

        return .init(action: .consume, shouldConsume: true)
    }

    private static func navigationDirection(for keyCode: UInt16) -> Direction? {
        switch keyCode {
        case KeyCode.leftArrow: .left
        case KeyCode.rightArrow: .right
        case KeyCode.downArrow: .down
        case KeyCode.upArrow: .up
        default: nil
        }
    }

    func reset() {
        searchQuery = ""
    }
}

extension OverviewInputHandler {
    func handleHotkeyInvocation(_ invocation: HotkeyInvocation) -> OverviewHotkeyDisposition {
        guard state.isOpen else { return .inactive }
        if let trigger = invocation.trigger,
           let action = Self.physicalHotkeyAction(for: trigger)
        {
            guard !trigger.isRepeat else { return .handled }
            switch action {
            case .dismissSelection:
                dismissToSelection(animated: true)
            case .closeSelection:
                closeSelectedWindow()
            }
            return .handled
        }
        return handleHotkeyCommand(invocation.command)
    }

    static func physicalHotkeyAction(for trigger: PhysicalHotkeyTrigger) -> OverviewPhysicalHotkeyAction? {
        let relevantModifiers = trigger.modifiers
            & UInt32(controlKey | optionKey | shiftKey | cmdKey)
        switch trigger.keyCode {
        case UInt32(kVK_Escape):
            return .dismissSelection
        case UInt32(kVK_Return),
             UInt32(kVK_ANSI_KeypadEnter):
            return relevantModifiers == 0 ? .dismissSelection : nil
        case UInt32(kVK_ANSI_W):
            return relevantModifiers == UInt32(cmdKey) ? .closeSelection : nil
        default:
            return nil
        }
    }

    func handleHotkeyCommand(_ command: HotkeyCommand) -> OverviewHotkeyDisposition {
        guard state.isOpen else { return .inactive }

        switch command {
        case .presentation(.overview):
            controller?.toggle()
            return .handled
        case let .focus(direction):
            guard case .open = state, controller?.hasActiveDragSession == false else { return .handled }
            navigateSelection(direction)
            return .handled
        default:
            guard OverviewStructuralActions.isStructuralHotkey(command) else { return .blocked }
            guard case .open = state,
                  controller?.hasActiveDragSession == false,
                  controller?.canPerformStructuralHotkey == true
            else {
                return .handled
            }
            guard let selectedWindowHandle = projection.selectedWindowHandle else { return .handled }
            controller?.executeStructuralHotkey(command, selectedHandle: selectedWindowHandle)
            return .handled
        }
    }

    func selectAndActivateWindow(_ handle: WindowHandle) {
        guard case .open = state else { return }
        projection.setSelectedWindowHandle(handle)
        updateWindowDisplays()

        focusSession.scheduleSelectionDismissal(handle)
    }

    func updateSearchQuery(_ query: String) {
        projection.searchQuery = query
        searchQuery = query
        projection.rebuildProjectedLayouts()
        updateWindowDisplays()
    }

    func navigateSelection(_ direction: Direction, on monitorId: Monitor.ID? = nil) {
        guard case .open = state else { return }
        let changed = projection.performSelectionNavigation(on: monitorId) { layout, currentHandle in
            OverviewNavigation.findNextWindow(
                in: layout,
                from: currentHandle,
                direction: direction
            )
        }
        if changed { updateWindowDisplays() }
    }

    func cycleSelection(forward: Bool, on monitorId: Monitor.ID? = nil) {
        guard case .open = state else { return }
        let changed = projection.performSelectionNavigation(on: monitorId) { layout, currentHandle in
            OverviewNavigation.findCycledWindow(
                in: layout,
                from: currentHandle,
                forward: forward
            )
        }
        if changed { updateWindowDisplays() }
    }

    func activateSelectedWindow() {
        guard let selectedWindowHandle = projection.selectedWindowHandle else { return }
        selectAndActivateWindow(selectedWindowHandle)
    }

    func dismissToSelection(animated: Bool) {
        guard let selectedWindowHandle = projection.selectedWindowHandle,
              overviewSnapshot.windows[selectedWindowHandle] != nil
        else {
            controller?.dismiss(reason: .cancel, animated: animated)
            return
        }
        controller?.dismiss(reason: .selection, targetWindow: selectedWindowHandle, animated: animated)
    }

    func closeSelectedWindow() {
        guard case .open = state, let selectedWindowHandle = projection.selectedWindowHandle else { return }
        controller?.closeWindow(selectedWindowHandle)
    }

    func adjustScrollOffset(by delta: CGFloat, on monitorId: Monitor.ID) {
        projection.adjustScrollOffset(by: delta, on: monitorId)
        updateWindowDisplays()
    }

    func handleScroll(delta: CGFloat, modifiers: NSEvent.ModifierFlags, isPrecise: Bool, on monitorId: Monitor.ID) {
        if projection.handleScroll(delta: delta, modifiers: modifiers, isPrecise: isPrecise, on: monitorId) {
            updateWindowDisplays()
        }
    }
}
