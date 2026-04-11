import AppKit
import Observation
import SwiftUI

struct WorkspaceBarItem: Identifiable, Equatable {
    let id: WorkspaceDescriptor.ID
    let name: String
    let rawName: String
    let isFocused: Bool
    let tiledWindows: [WorkspaceBarWindowItem]
    let floatingWindows: [WorkspaceBarWindowItem]

    var windows: [WorkspaceBarWindowItem] {
        tiledWindows + floatingWindows
    }
}

struct WorkspaceBarWindowItem: Identifiable, Equatable {
    let id: WindowToken
    let windowId: Int
    let appName: String
    let icon: NSImage?
    let isFocused: Bool
    let windowCount: Int
    let allWindows: [WorkspaceBarWindowInfo]

    static func == (lhs: WorkspaceBarWindowItem, rhs: WorkspaceBarWindowItem) -> Bool {
        lhs.id == rhs.id
            && lhs.windowId == rhs.windowId
            && lhs.appName == rhs.appName
            && lhs.icon === rhs.icon
            && lhs.isFocused == rhs.isFocused
            && lhs.windowCount == rhs.windowCount
            && lhs.allWindows == rhs.allWindows
    }
}

struct WorkspaceBarWindowInfo: Identifiable, Equatable {
    let id: WindowToken
    let windowId: Int
    let title: String
    let isFocused: Bool
}

struct WorkspaceBarSnapshot: Equatable {
    let items: [WorkspaceBarItem]
    let showLabels: Bool
    let backgroundOpacity: Double
    let barHeight: CGFloat
}

@MainActor @Observable
final class WorkspaceBarModel {
    var snapshot: WorkspaceBarSnapshot

    init(snapshot: WorkspaceBarSnapshot) {
        self.snapshot = snapshot
    }
}

@MainActor
struct WorkspaceBarView: View {
    let model: WorkspaceBarModel
    @Bindable var motionPolicy: MotionPolicy
    let onFocusWorkspace: (WorkspaceBarItem) -> Void
    let onFocusWindow: (WindowToken) -> Void

    var body: some View {
        WorkspaceBarContentView(
            snapshot: model.snapshot,
            animationsEnabled: motionPolicy.animationsEnabled,
            onFocusWorkspace: onFocusWorkspace,
            onFocusWindow: onFocusWindow
        )
    }
}

@MainActor
struct WorkspaceBarMeasurementView: View {
    let snapshot: WorkspaceBarSnapshot

    var body: some View {
        WorkspaceBarContentView(
            snapshot: snapshot,
            animationsEnabled: false,
            onFocusWorkspace: { _ in },
            onFocusWindow: { _ in }
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

@MainActor
private struct WorkspaceBarContentView: View {
    let snapshot: WorkspaceBarSnapshot
    let animationsEnabled: Bool
    let onFocusWorkspace: (WorkspaceBarItem) -> Void
    let onFocusWindow: (WindowToken) -> Void

    @Environment(\.colorScheme) var colorScheme: ColorScheme

    private var itemHeight: CGFloat { max(16, snapshot.barHeight - 4) }
    private var iconSize: CGFloat { max(12, itemHeight - 8) }
    private let workspaceSpacing: CGFloat = 3
    private let windowSpacing: CGFloat = 3
    private var pillCornerRadius: CGFloat { itemHeight / 2 }
    private var outerCornerRadius: CGFloat { (itemHeight + 10) / 2 }

    // Subtle fill tint on top of the vibrancy material
    private var tintOverlay: Color {
        colorScheme == .dark
            ? Color.white.opacity(snapshot.backgroundOpacity * 0.6)
            : Color.black.opacity(snapshot.backgroundOpacity * 0.25)
    }

    var body: some View {
        HStack(spacing: workspaceSpacing) {
            ForEach(snapshot.items, id: \.id) { item in
                WorkspaceItemView(
                    item: item,
                    iconSize: iconSize,
                    itemHeight: itemHeight,
                    windowSpacing: windowSpacing,
                    pillCornerRadius: pillCornerRadius,
                    animationsEnabled: animationsEnabled,
                    showLabels: snapshot.showLabels,
                    onFocusWorkspace: { onFocusWorkspace(item) },
                    onFocusWindow: onFocusWindow
                )
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: outerCornerRadius, style: .continuous)
                .fill(tintOverlay)
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: outerCornerRadius, style: .continuous)
                )
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 12, x: 0, y: 4)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.08), radius: 3, x: 0, y: 1)
        }
    }
}

@MainActor
private struct WorkspaceItemView: View {
    let item: WorkspaceBarItem
    let iconSize: CGFloat
    let itemHeight: CGFloat
    let windowSpacing: CGFloat
    let pillCornerRadius: CGFloat
    let animationsEnabled: Bool
    let showLabels: Bool
    let onFocusWorkspace: () -> Void
    let onFocusWindow: (WindowToken) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var springAnimation: Animation? {
        animationsEnabled
            ? .spring(response: 0.25, dampingFraction: 0.75)
            : nil
    }

    private var pillBackground: some View {
        Group {
            if item.isFocused {
                // Active: accent-tinted fill — the simple-bar "lit" pill
                RoundedRectangle(cornerRadius: pillCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.28 : 0.18))
                    .overlay {
                        RoundedRectangle(cornerRadius: pillCornerRadius, style: .continuous)
                            .strokeBorder(
                                Color.accentColor.opacity(colorScheme == .dark ? 0.55 : 0.45),
                                lineWidth: 1
                            )
                    }
            } else if isHovered {
                // Hover: very subtle white/black tint, no border
                RoundedRectangle(cornerRadius: pillCornerRadius, style: .continuous)
                    .fill(
                        colorScheme == .dark
                            ? Color.white.opacity(0.07)
                            : Color.black.opacity(0.055)
                    )
            }
        }
    }

    var body: some View {
        HStack(spacing: windowSpacing) {
            if showLabels {
                Text(item.name)
                    .font(.system(size: 11, weight: item.isFocused ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(
                        item.isFocused
                            ? AnyShapeStyle(Color.accentColor)
                            : AnyShapeStyle(.secondary)
                    )
                    .frame(minWidth: 14)
                    .animation(springAnimation, value: item.isFocused)

                if !item.windows.isEmpty {
                    Rectangle()
                        .fill(
                            item.isFocused
                                ? Color.accentColor.opacity(0.35)
                                : Color.primary.opacity(0.12)
                        )
                        .frame(width: 1, height: iconSize * 0.7)
                        .padding(.horizontal, 2)
                }
            }

            ForEach(item.tiledWindows, id: \.id) { window in
                WindowIconView(
                    window: window,
                    iconSize: iconSize,
                    isFocused: window.isFocused,
                    isInFocusedWorkspace: item.isFocused,
                    animationsEnabled: animationsEnabled,
                    onFocusWindow: onFocusWindow
                )
            }

            if !item.tiledWindows.isEmpty && !item.floatingWindows.isEmpty {
                Rectangle()
                    .fill(
                        item.isFocused
                            ? Color.accentColor.opacity(0.3)
                            : Color.primary.opacity(0.1)
                    )
                    .frame(width: 1, height: iconSize * 0.65)
                    .padding(.horizontal, 1)
            }

            ForEach(item.floatingWindows, id: \.id) { window in
                WindowIconView(
                    window: window,
                    iconSize: iconSize,
                    isFocused: window.isFocused,
                    isInFocusedWorkspace: item.isFocused,
                    animationsEnabled: animationsEnabled,
                    onFocusWindow: onFocusWindow
                )
            }

            // Empty workspace dot indicator when no windows present
            if item.windows.isEmpty && !showLabels {
                Circle()
                    .fill(
                        item.isFocused
                            ? Color.accentColor
                            : Color.primary.opacity(0.25)
                    )
                    .frame(width: max(5, iconSize * 0.32), height: max(5, iconSize * 0.32))
                    .animation(springAnimation, value: item.isFocused)
            }
        }
        .padding(.horizontal, item.windows.isEmpty && !showLabels ? 10 : 9)
        .padding(.vertical, 3)
        .frame(minHeight: itemHeight)
        .background(pillBackground.animation(springAnimation, value: item.isFocused))
        .animation(springAnimation, value: isHovered)
        .onHover { hovering in
            withAnimation(springAnimation) { isHovered = hovering }
        }
        .onTapGesture {
            onFocusWorkspace()
        }
        .scaleEffect(isHovered && !item.isFocused ? 1.04 : 1.0)
        .animation(animationsEnabled ? .spring(response: 0.2, dampingFraction: 0.7) : nil, value: isHovered)
    }
}

@MainActor
private struct WindowIconView: View {
    let window: WorkspaceBarWindowItem
    let iconSize: CGFloat
    let isFocused: Bool
    let isInFocusedWorkspace: Bool
    let animationsEnabled: Bool
    let onFocusWindow: (WindowToken) -> Void

    @State private var isHovered = false
    @State private var showingWindowList = false

    private var focusAnimation: Animation? {
        animationsEnabled ? .spring(response: 0.22, dampingFraction: 0.72) : nil
    }

    private var hoverAnimation: Animation? {
        animationsEnabled ? .spring(response: 0.18, dampingFraction: 0.7) : nil
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let icon = window.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: iconSize, height: iconSize)
            .opacity(iconOpacity)
            // Subtle drop shadow on focused icon; standard shadow otherwise
            .shadow(
                color: isFocused ? Color.accentColor.opacity(0.5) : .black.opacity(0.18),
                radius: isFocused ? 5 : 2,
                x: 0, y: isFocused ? 1 : 1
            )

            if window.windowCount > 1 {
                Text("\(window.windowCount)")
                    .font(.system(size: max(7, iconSize * 0.38), weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(minWidth: max(11, iconSize * 0.5), minHeight: max(11, iconSize * 0.5))
                    .background(
                        Capsule()
                            .fill(Color.accentColor)
                            .shadow(color: Color.accentColor.opacity(0.4), radius: 3, x: 0, y: 1)
                    )
                    .offset(x: iconSize * 0.22, y: -iconSize * 0.14)
            }
        }
        .scaleEffect(iconScale)
        .animation(focusAnimation, value: isFocused)
        .animation(hoverAnimation, value: isHovered)
        .onHover { hovering in isHovered = hovering }
        .onTapGesture {
            if window.windowCount > 1 {
                showingWindowList = true
            } else {
                onFocusWindow(window.id)
            }
        }
        .sheet(isPresented: $showingWindowList) {
            WindowListSheet(
                windows: window.allWindows,
                appName: window.appName,
                onFocusWindow: { token in
                    onFocusWindow(token)
                    showingWindowList = false
                }
            )
        }
        .help(window.appName)
    }

    private var iconOpacity: Double {
        if isFocused { return 1.0 }
        if isHovered { return 0.85 }
        if isInFocusedWorkspace { return 0.5 }
        return 0.45
    }

    private var iconScale: CGFloat {
        if isFocused { return 1.08 }
        if isHovered { return 1.06 }
        return 1.0
    }
}

@MainActor
private struct WindowListSheet: View {
    let windows: [WorkspaceBarWindowInfo]
    let appName: String
    let onFocusWindow: (WindowToken) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(appName)
                    .font(.headline)
                    .padding()
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .padding()
            }
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            List(windows) { windowInfo in
                Button {
                    onFocusWindow(windowInfo.id)
                } label: {
                    HStack {
                        Text(windowInfo.title)
                            .foregroundColor(windowInfo.isFocused ? .primary : .secondary)
                        Spacer()
                        if windowInfo.isFocused {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 300, minHeight: 200)
    }
}
