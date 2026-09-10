// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

@MainActor
struct WorkspaceBarView: View {
    let model: WorkspaceBarModel
    var slice: WorkspaceBarIslandSlice = .all
    var showsSystemStatsButton = false
    @Bindable var motionPolicy: MotionPolicy
    let onFocusWorkspace: (WorkspaceBarItem) -> Void
    let onFocusWindow: (WindowHandle) -> Void
    let onActivateScratchpad: (Int) -> Void
    var onToggleSystemStats: () -> Void = {}
    var onSystemStatsAnchorChange: (CGPoint?) -> Void = { _ in }

    var body: some View {
        WorkspaceBarContentView(
            snapshot: model.snapshot,
            slice: slice,
            showsSystemStatsButton: showsSystemStatsButton,
            animationsEnabled: motionPolicy.animationsEnabled,
            onFocusWorkspace: onFocusWorkspace,
            onFocusWindow: onFocusWindow,
            onActivateScratchpad: onActivateScratchpad,
            onToggleSystemStats: onToggleSystemStats,
            onSystemStatsAnchorChange: onSystemStatsAnchorChange
        )
    }
}

@MainActor
struct WorkspaceBarMeasurementView: View {
    let snapshot: WorkspaceBarSnapshot
    var slice: WorkspaceBarIslandSlice = .all
    var showsSystemStatsButton = false

    var body: some View {
        WorkspaceBarContentView(
            snapshot: snapshot,
            slice: slice,
            showsSystemStatsButton: showsSystemStatsButton,
            animationsEnabled: false,
            onFocusWorkspace: { _ in },
            onFocusWindow: { _ in },
            onActivateScratchpad: { _ in },
            onToggleSystemStats: {},
            onSystemStatsAnchorChange: { _ in }
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

@MainActor
private struct WorkspaceBarContentView: View {
    let snapshot: WorkspaceBarSnapshot
    var slice: WorkspaceBarIslandSlice = .all
    var showsSystemStatsButton = false
    let animationsEnabled: Bool
    let onFocusWorkspace: (WorkspaceBarItem) -> Void
    let onFocusWindow: (WindowHandle) -> Void
    let onActivateScratchpad: (Int) -> Void
    let onToggleSystemStats: () -> Void
    let onSystemStatsAnchorChange: (CGPoint?) -> Void

    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var itemHeight: CGFloat {
        max(16, snapshot.barHeight - 4)
    }

    private var iconSize: CGFloat {
        max(12, itemHeight - 6)
    }

    private let workspaceSpacing: CGFloat = 8
    private let windowSpacing: CGFloat = 2
    private let cornerRadius: CGFloat = 6

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(snapshot.backgroundOpacity)
            : Color.black.opacity(snapshot.backgroundOpacity * 0.5)
    }

    private var accentColor: Color? {
        snapshot.accentColor?.swiftUIColor
    }

    private var textColor: Color? {
        snapshot.textColor?.swiftUIColor
    }

    private var barShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    var body: some View {
        HStack(spacing: workspaceSpacing) {
            ForEach(slice.items(in: snapshot), id: \.id) { item in
                WorkspaceItemView(
                    item: item,
                    iconSize: iconSize,
                    itemHeight: itemHeight,
                    windowSpacing: windowSpacing,
                    cornerRadius: cornerRadius,
                    animationsEnabled: animationsEnabled,
                    showLabels: snapshot.showLabels,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWorkspace: { onFocusWorkspace(item) },
                    onFocusWindow: onFocusWindow
                )
            }

            ForEach(slice.scratchpads(in: snapshot)) { scratchpad in
                ScratchpadPillView(
                    item: scratchpad,
                    iconSize: iconSize,
                    itemHeight: itemHeight,
                    animationsEnabled: animationsEnabled,
                    accentColor: accentColor,
                    textColor: textColor,
                    onActivateScratchpad: onActivateScratchpad
                )
            }

            if showsSystemStatsButton {
                SystemStatsButtonView(
                    itemHeight: itemHeight,
                    accentColor: accentColor,
                    textColor: textColor,
                    onToggle: onToggleSystemStats,
                    onAnchorChange: onSystemStatsAnchorChange
                )
            }
        }
        .padding(.horizontal, 4)
        .frame(height: itemHeight + 4)
        .background {
            if accessibilityReduceTransparency {
                barShape.fill(Color(NSColor.windowBackgroundColor).opacity(0.96))
            } else {
                barShape
                    .fill(backgroundColor)
                    .background(.ultraThinMaterial, in: barShape)
            }

            barShape.strokeBorder(
                colorSchemeContrast == .increased
                    ? Color.primary.opacity(0.45)
                    : Color.secondary.opacity(0.18),
                lineWidth: colorSchemeContrast == .increased ? 1 : 0.5
            )
        }
    }
}

@MainActor
private struct WorkspaceItemView: View {
    let item: WorkspaceBarItem
    let iconSize: CGFloat
    let itemHeight: CGFloat
    let windowSpacing: CGFloat
    let cornerRadius: CGFloat
    let animationsEnabled: Bool
    let showLabels: Bool
    let accentColor: Color?
    let textColor: Color?
    let onFocusWorkspace: () -> Void
    let onFocusWindow: (WindowHandle) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: windowSpacing) {
            if showLabels {
                WorkspaceLabelButton(
                    item: item,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWorkspace: onFocusWorkspace
                )

                if !item.windows.isEmpty {
                    Divider()
                        .frame(height: iconSize)
                        .padding(.horizontal, 2)
                        .accessibilityHidden(true)
                }
            } else if item.windows.isEmpty {
                WorkspaceLabelButton(
                    item: item,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWorkspace: onFocusWorkspace
                )
            }

            ForEach(item.tiledWindows, id: \.id) { window in
                WindowIconView(
                    window: window,
                    iconSize: iconSize,
                    isFocused: window.isFocused,
                    isInFocusedWorkspace: item.isFocused,
                    context: .tiled,
                    animationsEnabled: animationsEnabled,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWindow: onFocusWindow
                )
            }

            if !item.tiledWindows.isEmpty && !item.floatingWindows.isEmpty {
                Divider()
                    .frame(height: iconSize)
                    .padding(.horizontal, 2)
                    .accessibilityHidden(true)
            }

            if !item.floatingWindows.isEmpty {
                FloatingWindowsGroupView(
                    windows: item.floatingWindows,
                    iconSize: iconSize,
                    itemHeight: itemHeight,
                    isInFocusedWorkspace: item.isFocused,
                    animationsEnabled: animationsEnabled,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWindow: onFocusWindow
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(height: itemHeight)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onTapGesture(perform: onFocusWorkspace)
        .background {
            if item.isFocused || isHovered {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.regularMaterial)
                    .overlay {
                        if item.isFocused {
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .strokeBorder(accentColor ?? .accentColor, lineWidth: 1)
                        }
                    }
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityElement(children: .contain)
    }
}

@MainActor
private struct WorkspaceLabelButton: View {
    let item: WorkspaceBarItem
    let accentColor: Color?
    let textColor: Color?
    let onFocusWorkspace: () -> Void

    private var resolvedAccentColor: Color {
        accentColor ?? .accentColor
    }

    private var resolvedLabelColor: Color {
        textColor ?? (item.isFocused ? resolvedAccentColor : .secondary)
    }

    var body: some View {
        Button(action: onFocusWorkspace) {
            Text(item.name)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundColor(resolvedLabelColor)
                .lineLimit(1)
                .frame(minWidth: 16)
                .fixedSize(horizontal: true, vertical: false)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Workspace \(item.name)")
        .accessibilityValue(item.isFocused ? "Focused" : "")
        .help("Focus workspace \(item.name)")
    }
}

@MainActor
private struct FloatingWindowsGroupView: View {
    let windows: [WorkspaceBarWindowItem]
    let iconSize: CGFloat
    let itemHeight: CGFloat
    let isInFocusedWorkspace: Bool
    let animationsEnabled: Bool
    let accentColor: Color?
    let textColor: Color?
    let onFocusWindow: (WindowHandle) -> Void

    private var resolvedSecondaryTextColor: Color {
        textColor ?? .secondary
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: max(10, iconSize * 0.58), weight: .medium))
                .foregroundStyle(resolvedSecondaryTextColor)
                .accessibilityHidden(true)

            ForEach(windows, id: \.id) { window in
                WindowIconView(
                    window: window,
                    iconSize: iconSize,
                    isFocused: window.isFocused,
                    isInFocusedWorkspace: isInFocusedWorkspace,
                    context: .floating,
                    animationsEnabled: animationsEnabled,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWindow: onFocusWindow
                )
            }
        }
        .padding(.horizontal, 5)
        .frame(height: max(16, itemHeight - 2))
        .background {
            Capsule(style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.24), lineWidth: 0.75)
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Floating windows")
    }
}

@MainActor
private struct ScratchpadPillView: View {
    let item: WorkspaceBarScratchpadItem
    let iconSize: CGFloat
    let itemHeight: CGFloat
    let animationsEnabled: Bool
    let accentColor: Color?
    let textColor: Color?
    let onActivateScratchpad: (Int) -> Void

    @State private var isHovered = false

    private var resolvedAccentColor: Color {
        accentColor ?? .accentColor
    }

    private var resolvedSecondaryTextColor: Color {
        textColor ?? .secondary
    }

    private var isHighlighted: Bool {
        item.isRevealed || item.isFocused
    }

    private var shownWindows: ArraySlice<WorkspaceBarWindowItem> {
        item.windows.prefix(WorkspaceBarScratchpadLayout.maximumVisibleAppIcons)
    }

    private var hiddenAppIconCount: Int {
        max(0, item.windows.count - shownWindows.count)
    }

    var body: some View {
        Button {
            onActivateScratchpad(item.index)
        } label: {
            HStack(spacing: item.presentation == .compact ? 3 : 5) {
                if item.presentation == .expanded {
                    Image(systemName: "tray.fill")
                        .font(.system(size: max(10, iconSize * 0.64), weight: .semibold))
                        .foregroundColor(isHighlighted ? resolvedAccentColor : resolvedSecondaryTextColor)
                        .accessibilityHidden(true)
                }

                Text(item.name)
                    .font(.system(size: max(9, iconSize * 0.6), weight: .medium))
                    .foregroundColor(isHighlighted ? resolvedAccentColor : resolvedSecondaryTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(
                        maxWidth: item.presentation == .compact
                            ? WorkspaceBarScratchpadLayout.compactLabelMaximumWidth
                            : nil
                    )
                    .accessibilityHidden(true)

                if item.presentation == .compact {
                    WindowCountBadge(
                        count: item.windowCount,
                        iconSize: iconSize,
                        textColor: textColor
                    )
                } else {
                    ForEach(shownWindows) { window in
                        AppIconImage(icon: window.icon)
                            .frame(width: iconSize, height: iconSize)
                            .opacity(window.isFocused ? 1 : 0.82)
                            .accessibilityHidden(true)
                    }

                    if hiddenAppIconCount > 0 {
                        WindowCountBadge(
                            count: hiddenAppIconCount,
                            prefix: "+",
                            iconSize: iconSize,
                            textColor: textColor
                        )
                    }
                }
            }
            .padding(.horizontal, item.presentation == .compact ? 5 : 8)
            .frame(height: itemHeight)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(scale)
        .animation(animationsEnabled ? .easeInOut(duration: 0.12) : nil, value: isHovered)
        .animation(animationsEnabled ? .easeInOut(duration: 0.15) : nil, value: isHighlighted)
        .background {
            Capsule(style: .continuous)
                .fill(isHighlighted ? resolvedAccentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                .background(.regularMaterial, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            item.isFocused ? resolvedAccentColor : Color.secondary
                                .opacity(item.isVisible ? 0.36 : 0.22),
                            lineWidth: item.isFocused ? 1.2 : 0.8
                        )
                }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel("Scratchpad \(item.name)")
        .accessibilityValue(accessibilityValue)
        .help("Scratchpad \(item.name): \(windowSummary), \(item.isVisible ? "visible" : "hidden")")
    }

    private var scale: CGFloat {
        if item.isFocused {
            1.04
        } else if isHovered {
            1.03
        } else {
            1
        }
    }

    private var windowSummary: String {
        item.windowCount == 1
            ? item.windows[0].appName
            : "\(item.windowCount) windows"
    }

    private var accessibilityValue: String {
        var parts = [windowSummary, item.isVisible ? "Visible" : "Hidden"]
        if item.isFocused {
            parts.append("Focused")
        }
        return parts.joined(separator: ", ")
    }
}
