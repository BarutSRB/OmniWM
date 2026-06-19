// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Carbon

enum DefaultHotkeyBindings {
    static func all() -> [HotkeyBinding] {
        ActionCatalog.defaultHotkeyBindings()
    }
}
