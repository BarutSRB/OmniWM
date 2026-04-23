// SPDX-License-Identifier: GPL-2.0-only
import Carbon

enum DefaultHotkeyBindings {
    static func all() -> [HotkeyBinding] {
        ActionCatalog.defaultHotkeyBindings()
    }
}
