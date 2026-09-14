// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Carbon
import OmniWMIPC

extension ActionCatalog {
    static func appendSizeCycleBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "cycleSizeForward",
                command: .sizing(.cycleSizeForward),
                category: .layout,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Period), modifiers: UInt32(optionKey)),
                visibility: .advanced
            ),
            action(
                id: "cycleSizeBackward",
                command: .sizing(.cycleSizeBackward),
                category: .layout,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(optionKey)),
                visibility: .advanced
            )
        ])
    }

    static func appendWindowSpanCycleBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "cycleWindowPrimarySpanForward",
                command: .sizing(.cycleWindowPrimarySpanForward),
                category: .column,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "cycleWindowPrimarySpanBackward",
                command: .sizing(.cycleWindowPrimarySpanBackward),
                category: .column,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "cycleWindowSecondarySpanForward",
                command: .sizing(.cycleWindowSecondarySpanForward),
                category: .column,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "cycleWindowSecondarySpanBackward",
                command: .sizing(.cycleWindowSecondarySpanBackward),
                category: .column,
                binding: .unassigned,
                visibility: .advanced
            )
        ])
    }

    static func appendContainerSpanBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "toggleContainerFullPrimarySpan",
                command: .sizing(.toggleContainerFullPrimarySpan),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey | shiftKey))
            ),
            action(
                id: "expandContainerToAvailablePrimarySpan",
                command: .sizing(.expandContainerToAvailablePrimarySpan),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey | controlKey)),
                visibility: .advanced
            ),
            action(
                id: "resetWindowSecondarySpan",
                command: .sizing(.resetWindowSecondarySpan),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | controlKey)),
                visibility: .advanced
            )
        ])
    }

    static func appendSpanAdjustmentBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "setContainerPrimarySpan.decrease10Percent",
                command: .sizing(.setContainerPrimarySpan(.adjustProportion(-10))),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Minus), modifiers: UInt32(optionKey)),
                visibility: .advanced,
                keywords: ["shrink container", "resize primary span"]
            ),
            action(
                id: "setContainerPrimarySpan.increase10Percent",
                command: .sizing(.setContainerPrimarySpan(.adjustProportion(10))),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Equal), modifiers: UInt32(optionKey)),
                visibility: .advanced,
                keywords: ["grow container", "resize primary span"]
            ),
            action(
                id: "setWindowPrimarySpan.decrease10Percent",
                command: .sizing(.setWindowPrimarySpan(.adjustProportion(-10))),
                category: .column,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["shrink window", "resize primary span"]
            ),
            action(
                id: "setWindowPrimarySpan.increase10Percent",
                command: .sizing(.setWindowPrimarySpan(.adjustProportion(10))),
                category: .column,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["grow window", "resize primary span"]
            ),
            action(
                id: "setWindowSecondarySpan.decrease10Percent",
                command: .sizing(.setWindowSecondarySpan(.adjustProportion(-10))),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Minus), modifiers: UInt32(optionKey | shiftKey)),
                visibility: .advanced,
                keywords: ["shrink window", "resize secondary span"]
            ),
            action(
                id: "setWindowSecondarySpan.increase10Percent",
                command: .sizing(.setWindowSecondarySpan(.adjustProportion(10))),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Equal), modifiers: UInt32(optionKey | shiftKey)),
                visibility: .advanced,
                keywords: ["grow window", "resize secondary span"]
            )
        ])
    }

    static func appendSplitStructureBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "balanceSizes",
                command: .sizing(.balanceSizes),
                category: .layout,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(optionKey | shiftKey))
            ),
            action(id: "moveToRoot", command: .dwindle(.moveToRoot), category: .layout, binding: .unassigned),
            action(id: "toggleSplit", command: .dwindle(.toggleSplit), category: .layout, binding: .unassigned),
            action(id: "swapSplit", command: .dwindle(.swapSplit), category: .layout, binding: .unassigned)
        ])
    }
}
