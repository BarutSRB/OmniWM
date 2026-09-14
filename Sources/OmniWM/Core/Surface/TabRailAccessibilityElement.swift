// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

final class TabRailAccessibilityElement: NSAccessibilityElement {
    private weak var parentElement: AnyObject?
    private var tab: TabRailTabInfo
    private var screenFrame: CGRect
    private let pressAction: (Int) -> Void
    private(set) var isSelected: Bool

    var visualIndex: Int {
        tab.visualIndex
    }

    init(
        parent: AnyObject,
        tab: TabRailTabInfo,
        screenFrame: CGRect,
        pressAction: @escaping (Int) -> Void
    ) {
        parentElement = parent
        self.tab = tab
        self.screenFrame = screenFrame
        self.pressAction = pressAction
        isSelected = tab.isActive
        super.init()
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .radioButton
    }

    override func accessibilityLabel() -> String? {
        tab.accessibilityLabel
    }

    override func accessibilityValue() -> Any? {
        NSNumber(value: isSelected)
    }

    override func accessibilityParent() -> Any? {
        parentElement
    }

    override func accessibilityFrame() -> NSRect {
        screenFrame
    }

    override func isAccessibilityEnabled() -> Bool {
        true
    }

    override func accessibilityPerformPress() -> Bool {
        pressAction(tab.visualIndex)
        return true
    }

    func update(tab: TabRailTabInfo, screenFrame: CGRect) {
        self.tab = tab
        self.screenFrame = screenFrame
    }

    func updateScreenFrame(_ screenFrame: CGRect) {
        self.screenFrame = screenFrame
    }

    func updateSelected(_ selected: Bool, postNotification: Bool) {
        guard isSelected != selected else { return }
        isSelected = selected
        if postNotification {
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }
}
