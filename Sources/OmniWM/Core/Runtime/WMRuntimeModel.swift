// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import ApplicationServices
import Foundation

typealias WMState = ReconcileSnapshot
typealias WMPlan = ActionPlan

@MainActor
protocol PlatformAdapter {
    var windowFocusOperations: WindowFocusOperations { get }
    var activateApplication: (pid_t) -> Void { get }
    var focusSpecificWindow: (pid_t, UInt32, AXUIElement) -> Void { get }
    var raiseWindow: (AXUIElement) -> Void { get }
    var closeWindow: (AXUIElement) -> Void { get }
    var orderWindowAbove: (UInt32) -> Void { get }
    var visibleWindowInfo: () -> [WindowServerInfo] { get }
    var axWindowRef: (UInt32, pid_t) -> AXWindowRef? { get }
    var visibleOwnedWindows: () -> [NSWindow] { get }
    var frontOwnedWindow: (NSWindow) -> Void { get }
    var performMenuAction: (AXUIElement) -> Void { get }
}

extension WMPlatform: PlatformAdapter {}

enum WMRuntimeEffectContext {
    case focusRequest
    case activationObserved(
        observedAXRef: AXWindowRef?,
        managedEntry: WindowModel.Entry?,
        source: ActivationEventSource,
        confirmRequest: Bool
    )
    case refresh
}

@MainActor
protocol EffectExecutor {
    func execute(
        _ result: OrchestrationResult,
        on controller: WMController,
        context: WMRuntimeEffectContext
    )
}

struct WMRuntimeSnapshot {
    var reconcile: WMState
    var orchestration: OrchestrationSnapshot
    var configuration: WMRuntimeConfiguration
}

struct WMRuntimeConfiguration {
    struct LayoutConfiguration {
        struct Niri {
            var maxWindowsPerColumn: Int
            var maxVisibleColumns: Int
            var infiniteLoop: Bool
            var centerFocusedColumn: CenterFocusedColumn
            var alwaysCenterSingleColumn: Bool
            var singleWindowAspectRatio: SingleWindowAspectRatio
            var columnWidthPresets: [Double]
            var defaultColumnWidth: Double?
        }

        struct Dwindle {
            var smartSplit: Bool
            var defaultSplitRatio: Double
            var splitWidthMultiplier: Double
            var singleWindowAspectRatio: CGSize
        }

        var gapSize: Double
        var outerGaps: LayoutGaps.OuterGaps
        var niri: Niri
        var dwindle: Dwindle
    }

    var animationsEnabled: Bool
    var appearanceMode: AppearanceMode
    var hotkeyBindings: [HotkeyBinding]
    var hotkeysEnabled: Bool
    var layout: LayoutConfiguration
    var borderConfig: BorderConfig
    var focusFollowsMouse: Bool
    var moveMouseToFocusedWindow: Bool
    var workspaceBarEnabled: Bool
    var preventSleepEnabled: Bool
    var quakeTerminalEnabled: Bool

    var summary: String {
        [
            "animations=\(animationsEnabled)",
            "appearance=\(appearanceMode.rawValue)",
            "hotkeys=\(hotkeysEnabled)",
            "gaps=\(layout.gapSize)",
            "workspace-bar=\(workspaceBarEnabled)",
            "prevent-sleep=\(preventSleepEnabled)",
            "quake=\(quakeTerminalEnabled)",
            "ffm=\(focusFollowsMouse)",
            "mouse-to-focus=\(moveMouseToFocusedWindow)",
            "column-presets=\(layout.niri.columnWidthPresets.count)",
        ]
        .joined(separator: " ")
    }

    @MainActor
    init(settings: SettingsStore) {
        animationsEnabled = settings.animationsEnabled
        appearanceMode = settings.appearanceMode
        hotkeyBindings = settings.hotkeyBindings
        hotkeysEnabled = settings.hotkeysEnabled
        layout = LayoutConfiguration(
            gapSize: settings.gapSize,
            outerGaps: .init(
                left: settings.outerGapLeft,
                right: settings.outerGapRight,
                top: settings.outerGapTop,
                bottom: settings.outerGapBottom
            ),
            niri: .init(
                maxWindowsPerColumn: settings.niriMaxWindowsPerColumn,
                maxVisibleColumns: settings.niriMaxVisibleColumns,
                infiniteLoop: settings.niriInfiniteLoop,
                centerFocusedColumn: settings.niriCenterFocusedColumn,
                alwaysCenterSingleColumn: settings.niriAlwaysCenterSingleColumn,
                singleWindowAspectRatio: settings.niriSingleWindowAspectRatio,
                columnWidthPresets: settings.niriColumnWidthPresets,
                defaultColumnWidth: settings.niriDefaultColumnWidth
            ),
            dwindle: .init(
                smartSplit: settings.dwindleSmartSplit,
                defaultSplitRatio: settings.dwindleDefaultSplitRatio,
                splitWidthMultiplier: settings.dwindleSplitWidthMultiplier,
                singleWindowAspectRatio: settings.dwindleSingleWindowAspectRatio.size
            )
        )
        borderConfig = BorderConfig.from(settings: settings)
        focusFollowsMouse = settings.focusFollowsMouse
        moveMouseToFocusedWindow = settings.moveMouseToFocusedWindow
        workspaceBarEnabled = settings.workspaceBarEnabled
        preventSleepEnabled = settings.preventSleepEnabled
        quakeTerminalEnabled = settings.quakeTerminalEnabled
    }
}
