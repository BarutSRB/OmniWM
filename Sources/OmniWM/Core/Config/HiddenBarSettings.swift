// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Observation

@MainActor @Observable
final class HiddenBarSettings {
    private nonisolated static let defaults = SettingsExport.HiddenBar.defaults()
    @ObservationIgnored var onChange: (() -> Void)?

    var enabled = HiddenBarSettings.defaults.enabled {
        didSet { onChange?() }
    }

    var hiddenBundleIDs = HiddenBarSettings.defaults.hiddenBundleIDs {
        didSet { onChange?() }
    }

    var rehideIntervalSeconds = HiddenBarSettings.defaults.rehideIntervalSeconds {
        didSet { onChange?() }
    }

    func export() -> SettingsExport.HiddenBar {
        SettingsExport.HiddenBar(
            enabled: enabled,
            hiddenBundleIDs: hiddenBundleIDs,
            rehideIntervalSeconds: rehideIntervalSeconds
        )
    }

    func apply(_ values: SettingsExport.HiddenBar) {
        enabled = values.enabled
        hiddenBundleIDs = HiddenBarSettingsPolicy.normalizedBundleIDs(values.hiddenBundleIDs)
        rehideIntervalSeconds = HiddenBarSettingsPolicy.validatedRehideIntervalSeconds(values.rehideIntervalSeconds)
    }
}
