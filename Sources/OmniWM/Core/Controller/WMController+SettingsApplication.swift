// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    func applyPersistedSettings(_ settings: SettingsStore, startServices: Bool = true) {
        setAnimationsEnabled(settings.animationsEnabled, persist: false)
        applyCurrentAppearanceMode()

        updateHotkeyBindings(settings.hotkeyBindings)
        setHotkeysEnabled(settings.hotkeysEnabled)

        setGapSize(settings.gaps.size, publishChange: false)

        applyPersistedLayoutSettings(settings)

        updateWorkspaceConfig()
        updateMonitorOrientations()
        updateMonitorNiriSettings()
        updateMonitorDwindleSettings()
        updateMonitorGapSettings()
        updateAppRules()

        borderSettingsChanged()
        updateOverviewSettings()

        setFocusFollowsMouse(settings.focus.followsMouse)
        setMoveMouseToFocusedWindow(settings.focus.moveMouseToFocusedWindow)

        setWorkspaceBarEnabled(settings.workspaceBar.enabled)
        setPreventSleepEnabled(settings.preventSleepEnabled)
        setQuakeTerminalEnabled(settings.quakeTerminal.enabled)
        syncClipboardHistoryService()

        quakeTerminalController.applyGeometryToVisibleWindow()
        quakeTerminalController.reloadOpacityConfig()
        quakeTerminalController.reloadBackgroundBlur()
        updateWorkspaceBarSettings()
        updateHiddenBarSettings()
        _ = syncMouseWarpPolicy()

        if startServices {
            setEnabled(true)
        }
        refreshStatusBar()
    }

    func setAnimationsEnabled(_ enabled: Bool, persist: Bool = true) {
        if persist, settings.animationsEnabled != enabled {
            settings.animationsEnabled = enabled
        }

        guard motionPolicy.animationsEnabled != enabled else { return }

        motionPolicy.animationsEnabled = enabled
    }

    func applyCurrentAppearanceMode() {
        settings.appearanceMode.apply()
        workspaceBarManager.updateAppearance()
        surfaceReconciler.noteWorldChanged()
    }

    func setGapSize(_ size: Double, publishChange: Bool = true) {
        workspaceManager.setGaps(to: size)
        if publishChange {
            publishDisplayChanged()
        }
    }

    private func applyPersistedLayoutSettings(_ settings: SettingsStore) {
        if niriEngine == nil {
            enableNiriLayout(
                centerFocusedColumn: settings.niri.centerFocusedColumn,
                alwaysCenterSingleColumn: settings.niri.alwaysCenterSingleColumn
            )
        }
        updateNiriConfig(
            visibleContainerCount: settings.niri.visibleContainerCount,
            infiniteLoop: settings.niri.infiniteLoop,
            centerFocusedColumn: settings.niri.centerFocusedColumn,
            alwaysCenterSingleColumn: settings.niri.alwaysCenterSingleColumn,
            singleWindowFit: settings.niri.singleWindowFit,
            containerPrimarySpanPresets: settings.niri.containerPrimarySpanPresets,
            defaultContainerPrimarySpan: settings.niri.defaultContainerPrimarySpan
        )

        if dwindleEngine == nil {
            enableDwindleLayout()
        }
        updateDwindleConfig(
            smartSplit: settings.dwindle.smartSplit,
            defaultSplitRatio: settings.dwindle.defaultSplitRatio,
            splitWidthMultiplier: settings.dwindle.splitWidthMultiplier,
            singleWindowFit: settings.dwindle.singleWindowFit
        )
    }
}
