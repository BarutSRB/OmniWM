// SPDX-License-Identifier: GPL-2.0-only
import ApplicationServices
import Foundation

struct MenuItemModel: Identifiable {
    let id: UUID
    let title: String
    let fullPath: String
    let keyboardShortcut: String?
    let axElement: AXUIElement
    let parentTitles: [String]

    init(
        title: String,
        fullPath: String,
        keyboardShortcut: String?,
        axElement: AXUIElement,
        parentTitles: [String]
    ) {
        id = UUID()
        self.title = title
        self.fullPath = fullPath
        self.keyboardShortcut = keyboardShortcut
        self.axElement = axElement
        self.parentTitles = parentTitles
    }
}
