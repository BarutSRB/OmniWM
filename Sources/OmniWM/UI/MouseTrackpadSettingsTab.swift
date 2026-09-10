// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

struct MouseTrackpadSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var missionControlGestureProbe: MissionControlGestureProbe

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
            niriColumnScrollingSection
            workspaceSwipeSection
            trackpadWindowGesturesSection
            trackpadDirectionSection
            mouseMoveAndResizeSection
            focusFollowsMouseSection
        }
        .formStyle(.grouped)
        .onAppear(perform: missionControlGestureProbe.refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            missionControlGestureProbe.refresh()
        }
    }

    private var niriColumnScrollingSection: some View {
        Section("Niri Column Scrolling") {
            Toggle("Enable Column Scrolling", isOn: $settings.scrollGestureEnabled)

            SettingsSliderRow(
                label: "Scroll Sensitivity",
                value: $settings.scrollSensitivity,
                range: 0.1 ... 100.0,
                step: 0.1,
                valueText: String(format: "%.1f", settings.scrollSensitivity) + "x"
            )
            .disabled(!settings.scrollGestureEnabled)

            Picker("Trackpad Gesture Fingers", selection: $settings.gestureFingerCount) {
                ForEach(GestureFingerCount.allCases, id: \.self) { count in
                    Text(count.displayName).tag(count)
                }
            }
            .disabled(!settings.scrollGestureEnabled)

            Picker("Trackpad Scroll Style", selection: $settings.trackpadScrollStyle) {
                ForEach(TrackpadScrollStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .disabled(!settings.scrollGestureEnabled)

            SettingsCaption(settings.trackpadScrollStyle == .momentum
                ? "Free inertial scrolling with rubber-band edges"
                : "Scroll snaps to the nearest column")

            Picker("Mouse Scroll Modifier", selection: $settings.scrollModifierKey) {
                ForEach(ScrollModifierKey.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .disabled(!settings.scrollGestureEnabled)

            SettingsCaption("Hold this key + scroll wheel to scroll through columns")
        }
    }

    private var workspaceSwipeSection: some View {
        Section("Workspace Swipe") {
            Toggle("Enable Workspace Swipe", isOn: $settings.workspaceSwipeEnabled)

            SettingsCaption("Swipe to switch workspaces on the monitor under the cursor")

            Picker("Swipe Fingers", selection: $settings.workspaceSwipeFingerCount) {
                ForEach(GestureFingerCount.allCases, id: \.self) { count in
                    Text(count.displayName).tag(count)
                }
            }
            .disabled(!settings.workspaceSwipeEnabled)
            .accessibilityHint(workspaceSwipeFingerPickerHint)

            if showTwoFingerWorkspaceSwipeWarning {
                SettingsCaption(twoFingerWorkspaceSwipeWarning)
            }

            Picker("Swipe Axis", selection: workspaceSwipeAxisSelection) {
                ForEach(WorkspaceSwipeAxis.allCases) { axis in
                    Text(axis.displayName).tag(axis)
                }
            }
            .disabled(!settings.workspaceSwipeEnabled || settings.workspaceSwipeAxisLockedToVertical)

            SettingsCaption(workspaceSwipeCaption)

            if missionControlGestureProbe.shouldWarn(
                axis: settings.effectiveWorkspaceSwipeAxis,
                fingerCount: settings.workspaceSwipeFingerCount
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

    private var trackpadWindowGesturesSection: some View {
        Section("Trackpad Window Move & Resize") {
            SettingsCaption(
                "Drag with several fingers, without clicking, to move or resize the tiled window under the cursor. "
                    + "Lift your fingers to drop."
            )

            Toggle("Enable Move Gesture", isOn: $settings.windowMoveGestureEnabled)

            Picker("Move Fingers", selection: $settings.windowMoveGestureFingerCount) {
                ForEach(GestureFingerCount.allCases, id: \.self) { count in
                    Text(count.displayName).tag(count)
                }
            }
            .disabled(!settings.windowMoveGestureEnabled)

            Toggle("Enable Resize Gesture", isOn: $settings.windowResizeGestureEnabled)

            Picker("Resize Fingers", selection: $settings.windowResizeGestureFingerCount) {
                ForEach(GestureFingerCount.allCases, id: \.self) { count in
                    Text(count.displayName).tag(count)
                }
            }
            .disabled(!settings.windowResizeGestureEnabled)

            SettingsCaption("Resize pulls the window corner nearest the cursor, like a modifier + right drag.")

            SettingsSliderRow(
                label: "Gesture Sensitivity",
                value: $settings.windowGestureSensitivity,
                range: SettingsStore.windowGestureSensitivityRange,
                step: 0.1,
                valueText: String(format: "%.1f", settings.windowGestureSensitivity) + "x"
            )
            .disabled(!settings.windowMoveGestureEnabled && !settings.windowResizeGestureEnabled)

            SettingsCaption("At 1.0x, sweeping the whole trackpad carries the window across the whole screen.")

            ForEach(windowGestureConflictCaptions, id: \.self) { caption in
                SettingsCaption(caption)
            }

            if showWindowGestureMissionControlWarning {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text("macOS gesture conflict")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }

                    Text(
                        "macOS still sees these fingers. Turn off Mission Control, App Exposé, and Swipe between full-screen applications for this finger count in  → System Settings → Trackpad → More Gestures, or the system gesture fires alongside the window gesture."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button("Open Trackpad Settings", action: missionControlGestureProbe.openTrackpadSettings)
                        .controlSize(.small)
                        .accessibilityHint(
                            "Opens System Settings. Select More Gestures, then turn off the conflicting gestures."
                        )
                }
            }
        }
    }

    private var trackpadDirectionSection: some View {
        Section("Trackpad Direction") {
            Toggle("Invert Direction (Natural)", isOn: $settings.gestureInvertDirection)
                .disabled(!settings.scrollGestureEnabled && !settings.workspaceSwipeEnabled)

            SettingsCaption(settings.gestureInvertDirection
                ? "Affects both Niri column scrolling and workspace swipes. Swipe right = scroll right."
                : "Affects both Niri column scrolling and workspace swipes. Swipe right = scroll left.")
        }
    }

    private var mouseMoveAndResizeSection: some View {
        Section("Mouse Move & Resize") {
            Picker("Left Mouse Move Modifier", selection: $settings.mouseMoveModifierKey) {
                ForEach(MouseMoveModifierKey.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }

            SettingsCaption(
                "Hold this modifier and left-drag to swap Niri tiled windows. "
                    + "Add Shift to insert instead; choose Off to leave modified drags to apps."
            )

            Picker("Right Mouse Resize Modifier", selection: $settings.mouseResizeModifierKey) {
                ForEach(MouseResizeModifierKey.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }

            SettingsCaption("Hold this modifier combo + right mouse drag to resize tiled windows")
        }
    }

    private var focusFollowsMouseSection: some View {
        Section("Focus Follows Mouse") {
            Toggle("Enable Focus Follows Mouse", isOn: $settings.focusFollowsMouse)
                .onChange(of: settings.focusFollowsMouse) { _, newValue in
                    controller.setFocusFollowsMouse(newValue)
                }

            Toggle("Raise Window When Focus Follows Mouse", isOn: $settings.raiseOnMouseFocus)
                .disabled(!settings.focusFollowsMouse)

            Picker("Focus Lock Modifier", selection: $settings.focusLockModifier) {
                ForEach(FocusLockModifier.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .disabled(!settings.focusFollowsMouse)

            SettingsCaption("Hold this modifier to move the cursor over other windows without changing focus.")
        }
    }

    private var workspaceSwipeAxisSelection: Binding<WorkspaceSwipeAxis> {
        Binding(
            get: { settings.effectiveWorkspaceSwipeAxis },
            set: { settings.workspaceSwipeAxis = $0 }
        )
    }

    private var workspaceSwipeCaption: String {
        let natural = settings.gestureInvertDirection
        let hint = switch settings.effectiveWorkspaceSwipeAxis {
        case .horizontal:
            natural ? "Swipe left = next workspace, right = previous" : "Swipe right = next workspace, left = previous"
        case .vertical:
            natural ? "Swipe up = next workspace, down = previous" : "Swipe down = next workspace, up = previous"
        }
        let lockHint = settings.workspaceSwipeAxisLockedToVertical
            ? " Vertical is required while column scrolling uses the same finger count."
            : ""
        return hint + "." + lockHint + " Pick a combination not already used by macOS trackpad gestures."
    }

    private var showTwoFingerWorkspaceSwipeWarning: Bool {
        settings.workspaceSwipeEnabled && settings.workspaceSwipeFingerCount == .two
    }

    private var showWindowGestureMissionControlWarning: Bool {
        (settings.windowMoveGestureEnabled
            && missionControlGestureProbe.shouldWarnForWindowGesture(
                fingerCount: settings.windowMoveGestureFingerCount
            ))
            || (settings.windowResizeGestureEnabled
                && missionControlGestureProbe.shouldWarnForWindowGesture(
                    fingerCount: settings.windowResizeGestureFingerCount
                ))
    }

    /// Window gestures claim their finger count outright, so the user should know which other gestures
    /// that silences.
    private var windowGestureConflictCaptions: [String] {
        var captions: [String] = []
        if settings.windowMoveGestureEnabled,
           settings.windowResizeGestureEnabled,
           settings.windowMoveGestureFingerCount == settings.windowResizeGestureFingerCount
        {
            captions.append(
                "Move and resize share \(settings.windowMoveGestureFingerCount.displayName.lowercased()); "
                    + "move wins and resize never fires."
            )
        }
        if settings.scrollGestureEnabled,
           let shadow = settings.windowGestureShadowing(fingerCount: settings.gestureFingerCount)
        {
            captions.append(
                "\(Self.windowGestureName(shadow)) uses \(settings.gestureFingerCount.displayName.lowercased()), "
                    + "so column scrolling with that count is disabled."
            )
        }
        if settings.workspaceSwipeEnabled,
           let shadow = settings.windowGestureShadowing(fingerCount: settings.workspaceSwipeFingerCount)
        {
            captions.append(
                "\(Self.windowGestureName(shadow)) uses "
                    + "\(settings.workspaceSwipeFingerCount.displayName.lowercased()), "
                    + "so workspace swipe with that count is disabled."
            )
        }
        return captions
    }

    private static func windowGestureName(_ mode: TrackpadGestureMode) -> String {
        switch mode {
        case .windowMove: "The move gesture"
        case .windowResize: "The resize gesture"
        case .columnScroll: "Column scrolling"
        case .workspaceSwitch: "Workspace swipe"
        }
    }

    private var workspaceSwipeFingerPickerHint: String {
        showTwoFingerWorkspaceSwipeWarning ? twoFingerWorkspaceSwipeWarning : ""
    }

    private var twoFingerWorkspaceSwipeWarning: String {
        "Two-finger workspace swipes can intercept normal scrolling in apps."
    }
}
