// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
import Foundation
import OmniWMIPC

@MainActor @Observable
final class PointerSettings {
    private nonisolated static let defaults = SettingsExport.MouseWarp.defaults()
    @ObservationIgnored var onChange: (() -> Void)?

    var margin = PointerSettings.defaults.margin {
        didSet { onChange?() }
    }

    var enabled = PointerSettings.defaults.enabled {
        didSet { onChange?() }
    }

    var constrainToArrangement = PointerSettings.defaults.constrainToArrangement {
        didSet { onChange?() }
    }

    func export() -> SettingsExport.MouseWarp {
        SettingsExport.MouseWarp(
            margin: margin,
            enabled: enabled,
            constrainToArrangement: constrainToArrangement
        )
    }
}
