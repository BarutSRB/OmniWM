// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Observation

@MainActor @Observable
final class ClipboardSettings {
    private(set) var historyEnabled: Bool
    private(set) var maxItems: Int
    private(set) var maxItemBytes: Int
    private(set) var maxTotalBytes: Int

    init(values: SettingsExport.Clipboard) {
        historyEnabled = values.historyEnabled
        maxItems = values.maxItems
        maxItemBytes = values.maxItemBytes
        maxTotalBytes = values.maxTotalBytes
    }

    func export() -> SettingsExport.Clipboard {
        SettingsExport.Clipboard(
            historyEnabled: historyEnabled,
            maxItems: maxItems,
            maxItemBytes: maxItemBytes,
            maxTotalBytes: maxTotalBytes
        )
    }

    fileprivate func setHistoryEnabled(_ enabled: Bool, didChange: () -> Void) {
        historyEnabled = enabled
        didChange()
    }

    fileprivate func apply(_ values: SettingsExport.Clipboard, didChange: () -> Void) {
        setHistoryEnabled(values.historyEnabled, didChange: didChange)
        maxItems = values.maxItems
        didChange()
        maxItemBytes = values.maxItemBytes
        didChange()
        maxTotalBytes = values.maxTotalBytes
        didChange()
    }
}

extension SettingsStore {
    func setClipboardHistoryEnabled(_ enabled: Bool) {
        clipboard.setHistoryEnabled(enabled, didChange: scheduleSave)
    }

    func applyClipboard(_ values: SettingsExport.Clipboard) {
        clipboard.apply(values, didChange: scheduleSave)
    }
}
