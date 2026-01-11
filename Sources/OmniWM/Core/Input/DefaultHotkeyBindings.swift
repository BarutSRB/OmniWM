import Carbon

enum DefaultHotkeyBindings {
    static func all() -> [HotkeyBinding] {
        var bindings: [HotkeyBinding] = []

        let digitCodes: [UInt32] = [
            UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
            UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
            UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9)
        ]
        for (idx, code) in digitCodes.enumerated() {
            bindings.append(HotkeyBinding(
                id: "switchWorkspace.\(idx)",
                command: .switchWorkspace(idx),
                binding: KeyBinding(keyCode: code, modifiers: UInt32(optionKey))
            ))
            bindings.append(HotkeyBinding(
                id: "moveToWorkspace.\(idx)",
                command: .moveToWorkspace(idx),
                binding: KeyBinding(keyCode: code, modifiers: UInt32(optionKey | shiftKey))
            ))
        }

        bindings.append(contentsOf: [
            HotkeyBinding(
                id: "focus.left",
                command: .focus(.left),
                binding: KeyBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(optionKey))
            ),
            HotkeyBinding(
                id: "focus.down",
                command: .focus(.down),
                binding: KeyBinding(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(optionKey))
            ),
            HotkeyBinding(
                id: "focus.up",
                command: .focus(.up),
                binding: KeyBinding(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(optionKey))
            ),
            HotkeyBinding(
                id: "focus.right",
                command: .focus(.right),
                binding: KeyBinding(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(optionKey))
            )
        ])

        bindings.append(HotkeyBinding(
            id: "focusPrevious",
            command: .focusPrevious,
            binding: KeyBinding(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey))
        ))

        bindings.append(contentsOf: [
            HotkeyBinding(id: "focusDownOrLeft", command: .focusDownOrLeft, binding: .unassigned),
            HotkeyBinding(id: "focusUpOrRight", command: .focusUpOrRight, binding: .unassigned)
        ])

        bindings.append(contentsOf: [
            HotkeyBinding(
                id: "moveWindowToWorkspaceUp",
                command: .moveWindowToWorkspaceUp,
                binding: KeyBinding(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(optionKey | controlKey | shiftKey))
            ),
            HotkeyBinding(
                id: "moveWindowToWorkspaceDown",
                command: .moveWindowToWorkspaceDown,
                binding: KeyBinding(
                    keyCode: UInt32(kVK_DownArrow),
                    modifiers: UInt32(optionKey | controlKey | shiftKey)
                )
            )
        ])

        bindings.append(contentsOf: [
            HotkeyBinding(
                id: "moveColumnToWorkspaceUp",
                command: .moveColumnToWorkspaceUp,
                binding: KeyBinding(keyCode: UInt32(kVK_PageUp), modifiers: UInt32(optionKey | controlKey | shiftKey))
            ),
            HotkeyBinding(
                id: "moveColumnToWorkspaceDown",
                command: .moveColumnToWorkspaceDown,
                binding: KeyBinding(keyCode: UInt32(kVK_PageDown), modifiers: UInt32(optionKey | controlKey | shiftKey))
            )
        ])

        for idx in 0 ..< 9 {
            bindings.append(HotkeyBinding(
                id: "moveColumnToWorkspace.\(idx)",
                command: .moveColumnToWorkspace(idx),
                binding: .unassigned
            ))
        }

        bindings.append(contentsOf: [
            HotkeyBinding(
                id: "move.left",
                command: .move(.left),
                binding: KeyBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(optionKey | shiftKey))
            ),
            HotkeyBinding(
                id: "move.down",
                command: .move(.down),
                binding: KeyBinding(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(optionKey | shiftKey))
            ),
            HotkeyBinding(
                id: "move.up",
                command: .move(.up),
                binding: KeyBinding(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(optionKey | shiftKey))
            ),
            HotkeyBinding(
                id: "move.right",
                command: .move(.right),
                binding: KeyBinding(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(optionKey | shiftKey))
            )
        ])

        bindings.append(contentsOf: [
            HotkeyBinding(
                id: "swap.left",
                command: .swap(.left),
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(optionKey | controlKey))
            ),
            HotkeyBinding(
                id: "swap.right",
                command: .swap(.right),
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(optionKey | controlKey))
            )
        ])

        bindings.append(contentsOf: [
            HotkeyBinding(
                id: "moveToMonitor.left",
                command: .moveToMonitor(.left),
                binding: KeyBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(optionKey | controlKey))
            ),
            HotkeyBinding(
                id: "moveToMonitor.down",
                command: .moveToMonitor(.down),
                binding: KeyBinding(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(optionKey | controlKey))
            ),
            HotkeyBinding(
                id: "moveToMonitor.up",
                command: .moveToMonitor(.up),
                binding: KeyBinding(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(optionKey | controlKey))
            ),
            HotkeyBinding(
                id: "moveToMonitor.right",
                command: .moveToMonitor(.right),
                binding: KeyBinding(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(optionKey | controlKey))
            )
        ])

        bindings.append(contentsOf: [
            HotkeyBinding(
                id: "focusMonitor.left",
                command: .focusMonitor(.left),
                binding: KeyBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(controlKey | cmdKey))
            ),
            HotkeyBinding(
                id: "focusMonitor.right",
                command: .focusMonitor(.right),
                binding: KeyBinding(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(controlKey | cmdKey))
            ),
            HotkeyBinding(
                id: "focusMonitor.up",
                command: .focusMonitor(.up),
                binding: KeyBinding(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(controlKey | cmdKey))
            ),
            HotkeyBinding(
                id: "focusMonitor.down",
                command: .focusMonitor(.down),
                binding: KeyBinding(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(controlKey | cmdKey))
            ),
            HotkeyBinding(
                id: "focusMonitorNext",
                command: .focusMonitorNext,
                binding: KeyBinding(keyCode: UInt32(kVK_Tab), modifiers: UInt32(controlKey | cmdKey))
            ),
            HotkeyBinding(
                id: "focusMonitorPrevious",
                command: .focusMonitorPrevious,
                binding: .unassigned
            ),
            HotkeyBinding(
                id: "focusMonitorLast",
                command: .focusMonitorLast,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(controlKey | cmdKey))
            )
        ])

        bindings.append(contentsOf: [
            HotkeyBinding(
                id: "moveColumnToMonitor.left",
                command: .moveColumnToMonitor(.left),
                binding: KeyBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(controlKey | cmdKey | shiftKey))
            ),
            HotkeyBinding(
                id: "moveColumnToMonitor.right",
                command: .moveColumnToMonitor(.right),
                binding: KeyBinding(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(controlKey | cmdKey | shiftKey))
            ),
            HotkeyBinding(
                id: "moveColumnToMonitor.up",
                command: .moveColumnToMonitor(.up),
                binding: KeyBinding(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(controlKey | cmdKey | shiftKey))
            ),
            HotkeyBinding(
                id: "moveColumnToMonitor.down",
                command: .moveColumnToMonitor(.down),
                binding: KeyBinding(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(controlKey | cmdKey | shiftKey))
            )
        ])

        bindings.append(contentsOf: [
            HotkeyBinding(
                id: "moveWorkspaceToMonitor.left",
                command: .moveWorkspaceToMonitor(.left),
                binding: .unassigned
            ),
            HotkeyBinding(
                id: "moveWorkspaceToMonitor.right",
                command: .moveWorkspaceToMonitor(.right),
                binding: .unassigned
            ),
            HotkeyBinding(id: "moveWorkspaceToMonitor.up", command: .moveWorkspaceToMonitor(.up), binding: .unassigned),
            HotkeyBinding(
                id: "moveWorkspaceToMonitor.down",
                command: .moveWorkspaceToMonitor(.down),
                binding: .unassigned
            )
        ])

        bindings.append(contentsOf: [
            HotkeyBinding(
                id: "toggleFullscreen",
                command: .toggleFullscreen,
                binding: KeyBinding(keyCode: UInt32(kVK_Return), modifiers: UInt32(optionKey))
            ),
            HotkeyBinding(
                id: "toggleNativeFullscreen",
                command: .toggleNativeFullscreen,
                binding: .unassigned
            )
        ])

        bindings.append(contentsOf: [
            HotkeyBinding(
                id: "moveColumn.left",
                command: .moveColumn(.left),
                binding: KeyBinding(
                    keyCode: UInt32(kVK_LeftArrow),
                    modifiers: UInt32(optionKey | controlKey | shiftKey)
                )
            ),
            HotkeyBinding(
                id: "moveColumn.right",
                command: .moveColumn(.right),
                binding: KeyBinding(
                    keyCode: UInt32(kVK_RightArrow),
                    modifiers: UInt32(optionKey | controlKey | shiftKey)
                )
            )
        ])

        bindings.append(contentsOf: [
            HotkeyBinding(
                id: "consumeWindow.left",
                command: .consumeWindow(.left),
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_LeftBracket), modifiers: UInt32(optionKey | controlKey))
            ),
            HotkeyBinding(
                id: "consumeWindow.right",
                command: .consumeWindow(.right),
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_RightBracket), modifiers: UInt32(optionKey | controlKey))
            ),
            HotkeyBinding(
                id: "expelWindow.left",
                command: .expelWindow(.left),
                binding: KeyBinding(
                    keyCode: UInt32(kVK_ANSI_LeftBracket),
                    modifiers: UInt32(optionKey | controlKey | shiftKey)
                )
            ),
            HotkeyBinding(
                id: "expelWindow.right",
                command: .expelWindow(.right),
                binding: KeyBinding(
                    keyCode: UInt32(kVK_ANSI_RightBracket),
                    modifiers: UInt32(optionKey | controlKey | shiftKey)
                )
            )
        ])

        bindings.append(HotkeyBinding(
            id: "toggleColumnTabbed",
            command: .toggleColumnTabbed,
            binding: KeyBinding(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey))
        ))

        bindings.append(contentsOf: [
            HotkeyBinding(
                id: "focusColumnFirst",
                command: .focusColumnFirst,
                binding: KeyBinding(keyCode: UInt32(kVK_Home), modifiers: UInt32(optionKey))
            ),
            HotkeyBinding(
                id: "focusColumnLast",
                command: .focusColumnLast,
                binding: KeyBinding(keyCode: UInt32(kVK_End), modifiers: UInt32(optionKey))
            )
        ])

        bindings.append(contentsOf: [
            HotkeyBinding(
                id: "focusWindowTop",
                command: .focusWindowTop,
                binding: KeyBinding(keyCode: UInt32(kVK_Home), modifiers: UInt32(optionKey | shiftKey))
            ),
            HotkeyBinding(
                id: "focusWindowBottom",
                command: .focusWindowBottom,
                binding: KeyBinding(keyCode: UInt32(kVK_End), modifiers: UInt32(optionKey | shiftKey))
            )
        ])

        for (idx, code) in digitCodes.enumerated() {
            bindings.append(HotkeyBinding(
                id: "focusColumn.\(idx)",
                command: .focusColumn(idx),
                binding: KeyBinding(keyCode: code, modifiers: UInt32(optionKey | controlKey))
            ))
        }

        bindings.append(contentsOf: [
            HotkeyBinding(
                id: "cycleColumnWidthForward",
                command: .cycleColumnWidthForward,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Period), modifiers: UInt32(optionKey))
            ),
            HotkeyBinding(
                id: "cycleColumnWidthBackward",
                command: .cycleColumnWidthBackward,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(optionKey))
            ),
            HotkeyBinding(
                id: "toggleColumnFullWidth",
                command: .toggleColumnFullWidth,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey | shiftKey))
            )
        ])

        bindings.append(HotkeyBinding(
            id: "balanceSizes",
            command: .balanceSizes,
            binding: KeyBinding(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(optionKey | shiftKey))
        ))

        bindings.append(HotkeyBinding(
            id: "moveToRoot",
            command: .moveToRoot,
            binding: .unassigned
        ))

        for (idx, code) in digitCodes.enumerated() {
            bindings.append(HotkeyBinding(
                id: "summonWorkspace.\(idx)",
                command: .summonWorkspace(idx),
                binding: KeyBinding(keyCode: code, modifiers: UInt32(controlKey | shiftKey))
            ))
        }

        bindings.append(HotkeyBinding(
            id: "openWindowFinder",
            command: .openWindowFinder,
            binding: KeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))
        ))

        bindings.append(HotkeyBinding(
            id: "raiseAllFloatingWindows",
            command: .raiseAllFloatingWindows,
            binding: KeyBinding(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | shiftKey))
        ))

        bindings.append(HotkeyBinding(
            id: "openMenuAnywhere",
            command: .openMenuAnywhere,
            binding: KeyBinding(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey))
        ))

        bindings.append(HotkeyBinding(
            id: "openMenuPalette",
            command: .openMenuPalette,
            binding: KeyBinding(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey | shiftKey))
        ))

        bindings.append(HotkeyBinding(
            id: "toggleHiddenBar",
            command: .toggleHiddenBar,
            binding: .unassigned
        ))

        return bindings
    }
}
