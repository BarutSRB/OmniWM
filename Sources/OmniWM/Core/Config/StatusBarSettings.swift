// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Observation

@MainActor @Observable
final class StatusBarSettings {
    private(set) var showWorkspaceName: Bool
    private(set) var showAppNames: Bool
    private(set) var useWorkspaceId: Bool

    init(values: SettingsExport.StatusBar) {
        showWorkspaceName = values.showWorkspaceName
        showAppNames = values.showAppNames
        useWorkspaceId = values.useWorkspaceId
    }

    func export() -> SettingsExport.StatusBar {
        SettingsExport.StatusBar(
            showWorkspaceName: showWorkspaceName,
            showAppNames: showAppNames,
            useWorkspaceId: useWorkspaceId
        )
    }

    fileprivate func setShowWorkspaceName(_ value: Bool, didChange: () -> Void) {
        showWorkspaceName = value
        didChange()
    }

    fileprivate func setShowAppNames(_ value: Bool, didChange: () -> Void) {
        showAppNames = value
        didChange()
    }

    fileprivate func setUseWorkspaceId(_ value: Bool, didChange: () -> Void) {
        useWorkspaceId = value
        didChange()
    }

    fileprivate func apply(_ values: SettingsExport.StatusBar, didChange: () -> Void) {
        setShowWorkspaceName(values.showWorkspaceName, didChange: didChange)
        setShowAppNames(values.showAppNames, didChange: didChange)
        setUseWorkspaceId(values.useWorkspaceId, didChange: didChange)
    }
}

extension SettingsStore {
    func setStatusBarShowWorkspaceName(_ value: Bool) {
        statusBar.setShowWorkspaceName(value, didChange: scheduleSave)
    }

    func setStatusBarShowAppNames(_ value: Bool) {
        statusBar.setShowAppNames(value, didChange: scheduleSave)
    }

    func setStatusBarUseWorkspaceId(_ value: Bool) {
        statusBar.setUseWorkspaceId(value, didChange: scheduleSave)
    }

    func applyStatusBar(_ values: SettingsExport.StatusBar) {
        statusBar.apply(values, didChange: scheduleSave)
    }
}
