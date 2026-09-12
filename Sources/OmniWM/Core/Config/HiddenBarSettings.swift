// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Observation

@MainActor @Observable
final class HiddenBarSettings {
    private(set) var enabled: Bool
    private(set) var hiddenBundleIDs: [String]
    private(set) var rehideIntervalSeconds: Double

    init(values: SettingsExport.HiddenBar) {
        enabled = values.enabled
        hiddenBundleIDs = values.hiddenBundleIDs
        rehideIntervalSeconds = values.rehideIntervalSeconds
    }

    func export() -> SettingsExport.HiddenBar {
        SettingsExport.HiddenBar(
            enabled: enabled,
            hiddenBundleIDs: hiddenBundleIDs,
            rehideIntervalSeconds: rehideIntervalSeconds
        )
    }

    fileprivate func setEnabled(_ value: Bool, didChange: () -> Void) {
        enabled = value
        didChange()
    }

    fileprivate func setHiddenBundleIDs(_ value: [String], didChange: () -> Void) {
        hiddenBundleIDs = value
        didChange()
    }

    fileprivate func setRehideIntervalSeconds(_ value: Double, didChange: () -> Void) {
        rehideIntervalSeconds = value
        didChange()
    }

    fileprivate func apply(_ values: SettingsExport.HiddenBar, didChange: () -> Void) {
        setEnabled(values.enabled, didChange: didChange)
        setHiddenBundleIDs(HiddenBarSettingsPolicy.normalizedBundleIDs(values.hiddenBundleIDs), didChange: didChange)
        setRehideIntervalSeconds(
            HiddenBarSettingsPolicy.validatedRehideIntervalSeconds(values.rehideIntervalSeconds),
            didChange: didChange
        )
    }
}

extension SettingsStore {
    func setHiddenBarEnabled(_ value: Bool) {
        hiddenBar.setEnabled(value, didChange: scheduleSave)
    }

    func setHiddenBarHiddenBundleIDs(_ value: [String]) {
        hiddenBar.setHiddenBundleIDs(value, didChange: scheduleSave)
    }

    func setHiddenBarRehideIntervalSeconds(_ value: Double) {
        hiddenBar.setRehideIntervalSeconds(value, didChange: scheduleSave)
    }

    func applyHiddenBar(_ values: SettingsExport.HiddenBar) {
        hiddenBar.apply(values, didChange: scheduleSave)
    }
}
