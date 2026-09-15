// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

struct MouseTrackpadSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var missionControlGestureProbe: MissionControlGestureProbe
    @State private var rejectedGestureConflict: TrackpadGestureConflict?
    @State private var connectedMonitors: [Monitor] = Monitor.current()

    init(
        settings: SettingsStore,
        controller: WMController,
        missionControlGestureProbe: MissionControlGestureProbe = MissionControlGestureProbe()
    ) {
        self.settings = settings
        self.controller = controller
        _missionControlGestureProbe = State(initialValue: missionControlGestureProbe)
    }

    var body: some View {
        Form {
            if let conflict = gestureConflict {
                Section {
                    Label(conflict.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            niriColumnScrollingSection
            workspaceSwipeSection
            overviewGestureSection
            trackpadDirectionSection
            mouseMoveAndResizeSection
            focusFollowsMouseSection
        }
        .formStyle(.grouped)
        .onAppear(perform: missionControlGestureProbe.refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            missionControlGestureProbe.refresh()
        }
        .onReceive(NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification))
        { _ in
            connectedMonitors = Monitor.current()
            rejectedGestureConflict = nil
        }
    }

    private var niriColumnScrollingSection: some View {
        Section("Niri Column Scrolling") {
            Toggle("Enable Column Scrolling", isOn: gestureBinding(\.scrollEnabled) { $0.scrollEnabled = $1 })

            SettingsSliderRow(
                label: "Scroll Sensitivity",
                value: Bindable(settings.gestures).scrollSensitivity,
                range: 0.1 ... 100.0,
                step: 0.1,
                valueText: String(format: "%.1f", settings.gestures.scrollSensitivity) + "x"
            )
            .disabled(!settings.gestures.scrollEnabled)

            Picker("Trackpad Gesture Fingers", selection: gestureBinding(\.fingerCount) { $0.fingerCount = $1 }) {
                ForEach(GestureFingerCount.allCases, id: \.self) { count in
                    Text(count.displayName).tag(count)
                }
            }
            .disabled(!settings.gestures.scrollEnabled)

            Picker("Trackpad Scroll Style", selection: Bindable(settings.gestures).trackpadScrollStyle) {
                ForEach(TrackpadScrollStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .disabled(!settings.gestures.scrollEnabled)

            SettingsCaption(settings.gestures.trackpadScrollStyle == .momentum
                ? "Free inertial scrolling with rubber-band edges"
                : "Scroll snaps to the nearest column")

            Picker("Mouse Scroll Modifier", selection: Bindable(settings.gestures).scrollModifierKey) {
                ForEach(ScrollModifierKey.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .disabled(!settings.gestures.scrollEnabled)

            SettingsCaption("Hold this key + scroll wheel to scroll through columns")
        }
    }

    private var workspaceSwipeSection: some View {
        Section("Workspace Swipe") {
            Toggle(
                "Enable Workspace Swipe",
                isOn: gestureBinding(\.workspaceSwipeEnabled) { $0.workspaceSwipeEnabled = $1 }
            )

            SettingsCaption("Swipe to switch workspaces on the monitor under the cursor")

            Picker(
                "Swipe Fingers",
                selection: gestureBinding(\.workspaceSwipeFingerCount) { $0.workspaceSwipeFingerCount = $1 }
            ) {
                ForEach(GestureFingerCount.allCases, id: \.self) { count in
                    Text(count.displayName).tag(count)
                }
            }
            .disabled(!settings.gestures.workspaceSwipeEnabled)
            .accessibilityHint(workspaceSwipeFingerPickerHint)

            if showTwoFingerWorkspaceSwipeWarning {
                SettingsCaption(twoFingerWorkspaceSwipeWarning)
            }

            Picker("Swipe Axis", selection: workspaceSwipeAxisSelection) {
                ForEach(WorkspaceSwipeAxis.allCases) { axis in
                    Text(axis.displayName).tag(axis)
                }
            }
            .disabled(!settings.gestures.workspaceSwipeEnabled)

            SettingsCaption(workspaceSwipeCaption)

            if missionControlGestureProbe.shouldWarn(
                axis: settings.gestures.effectiveWorkspaceSwipeAxis,
                fingerCount: settings.gestures.workspaceSwipeFingerCount
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text("Mission Control gesture conflict")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }

                    Text(
                        "Mission Control’s three- or four-finger upward swipe can intercept vertical workspace swipes. Turn off Mission Control in  → System Settings → Trackpad → More Gestures before enabling vertical workspace swipes."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button("Open Trackpad Settings", action: missionControlGestureProbe.openTrackpadSettings)
                        .controlSize(.small)
                        .accessibilityHint(
                            "Opens System Settings. Select More Gestures, then turn off Mission Control."
                        )
                }
            }
        }
    }

    private var overviewGestureSection: some View {
        Section("Overview Gesture") {
            Toggle(
                "Enable Overview Gesture",
                isOn: gestureBinding(\.overviewGestureEnabled) { $0.overviewGestureEnabled = $1 }
            )
            Picker(
                "Gesture Fingers",
                selection: gestureBinding(\.overviewGestureFingerCount) { $0.overviewGestureFingerCount = $1 }
            ) {
                Text("3 Fingers").tag(OverviewGestureFingerCount.three)
                Text("4 Fingers").tag(OverviewGestureFingerCount.four)
            }
            .disabled(!settings.gestures.overviewGestureEnabled)
            SettingsCaption(
                "Swipe up to open Overview and down to close it. Lift all fingers between gestures. Use a finger count not already assigned to another vertical gesture."
            )
            if settings.gestures.overviewGestureEnabled, missionControlGestureProbe.status == .enabled {
                SettingsCaption("Disable the matching Mission Control gesture in macOS Trackpad settings.")
                Button("Open Trackpad Settings", action: missionControlGestureProbe.openTrackpadSettings)
            }
        }
    }

    private var trackpadDirectionSection: some View {
        Section("Trackpad Direction") {
            Toggle("Invert Direction (Natural)", isOn: Bindable(settings.gestures).invertDirection)
                .disabled(!settings.gestures.scrollEnabled && !settings.gestures.workspaceSwipeEnabled)

            SettingsCaption(settings.gestures.invertDirection
                ? "Affects both Niri column scrolling and workspace swipes. Swipe right = scroll right."
                : "Affects both Niri column scrolling and workspace swipes. Swipe right = scroll left.")
        }
    }

    private var mouseMoveAndResizeSection: some View {
        Section("Mouse Move & Resize") {
            Picker("Left Mouse Move Modifier", selection: Bindable(settings.gestures).mouseMoveModifierKey) {
                ForEach(MouseMoveModifierKey.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }

            SettingsCaption(
                "Hold this modifier and left-drag to swap Niri tiled windows. "
                    + "Add Shift to insert instead; choose Off to leave modified drags to apps."
            )

            Picker("Right Mouse Resize Modifier", selection: Bindable(settings.gestures).mouseResizeModifierKey) {
                ForEach(MouseResizeModifierKey.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }

            SettingsCaption("Hold this modifier combo + right mouse drag to resize tiled windows")
        }
    }

    private var focusFollowsMouseSection: some View {
        Section("Focus Follows Mouse") {
            Toggle("Enable Focus Follows Mouse", isOn: Bindable(settings.focus).followsMouse)
                .onChange(of: settings.focus.followsMouse) { _, newValue in
                    controller.setFocusFollowsMouse(newValue)
                }

            Toggle("Raise Window When Focus Follows Mouse", isOn: Bindable(settings.focus).raiseOnMouseFocus)
                .disabled(!settings.focus.followsMouse)

            Picker("Focus Lock Modifier", selection: Bindable(settings.focus).lockModifier) {
                ForEach(FocusLockModifier.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .disabled(!settings.focus.followsMouse)

            SettingsCaption("Hold this modifier to move the cursor over other windows without changing focus.")
        }
    }

    private var workspaceSwipeAxisSelection: Binding<WorkspaceSwipeAxis> {
        gestureBinding(\.workspaceSwipeAxis) { $0.workspaceSwipeAxis = $1 }
    }

    private var gestureConflict: TrackpadGestureConflict? {
        rejectedGestureConflict ?? GestureSettingsValidation.conflict(
            gestures: settings.gestures.export(),
            orientationOverrides: settings.monitors.orientationOverrides,
            monitors: connectedMonitors
        )
    }

    private func gestureBinding<Value>(
        _ keyPath: KeyPath<GestureSettings, Value>,
        update: @escaping (inout SettingsExport.Gestures, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { settings.gestures[keyPath: keyPath] },
            set: { value in
                var candidate = settings.gestures.export()
                update(&candidate, value)
                rejectedGestureConflict = settings.updateGestureSettings(
                    candidate,
                    monitors: connectedMonitors
                )
            }
        )
    }

    private var workspaceSwipeCaption: String {
        let natural = settings.gestures.invertDirection
        let hint = switch settings.gestures.workspaceSwipeAxis {
        case .horizontal:
            natural ? "Swipe left = next workspace, right = previous" : "Swipe right = next workspace, left = previous"
        case .vertical:
            natural ? "Swipe up = next workspace, down = previous" : "Swipe down = next workspace, up = previous"
        }
        let lockHint = settings.gestures.workspaceSwipeAxisLockedToVertical
            ? " In Niri, matching column-scrolling fingers use the perpendicular direction instead. "
            + "The selected axis applies without column scrolling."
            : ""
        return hint + "." + lockHint + " Pick a combination not already used by macOS trackpad gestures."
    }

    private var showTwoFingerWorkspaceSwipeWarning: Bool {
        settings.gestures.workspaceSwipeEnabled && settings.gestures.workspaceSwipeFingerCount == .two
    }

    private var workspaceSwipeFingerPickerHint: String {
        showTwoFingerWorkspaceSwipeWarning ? twoFingerWorkspaceSwipeWarning : ""
    }

    private var twoFingerWorkspaceSwipeWarning: String {
        "Two-finger workspace swipes can intercept normal scrolling in apps."
    }
}
