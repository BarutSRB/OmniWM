import AppKit
import SwiftUI

struct WorkspaceBarItem: Identifiable {
    let id: WorkspaceDescriptor.ID
    let name: String
    let isFocused: Bool
    let windows: [WorkspaceBarWindowItem]
}

struct WorkspaceBarWindowItem: Identifiable {
    let id: UUID
    let windowId: Int
    let appName: String
    let icon: NSImage?
    let isFocused: Bool
    let windowCount: Int
    let allWindows: [WorkspaceBarWindowInfo]
}

struct WorkspaceBarWindowInfo: Identifiable {
    let id: UUID
    let windowId: Int
    let title: String
    let isFocused: Bool
}

@MainActor
struct WorkspaceBarView: View {
    let controller: WMController
    let settings: SettingsStore
    let resolvedSettings: ResolvedBarSettings
    let monitor: Monitor
    let barHeight: CGFloat

    @Environment(\.colorScheme) var colorScheme: ColorScheme

    private var itemHeight: CGFloat { max(16, barHeight - 4) }
    private var iconSize: CGFloat { max(12, itemHeight - 6) }
    private let workspaceSpacing: CGFloat = 8
    private let windowSpacing: CGFloat = 2
    private let cornerRadius: CGFloat = 6

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(resolvedSettings.backgroundOpacity)
            : Color.black.opacity(resolvedSettings.backgroundOpacity * 0.5)
    }

    private var activeBackgroundColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(resolvedSettings.backgroundOpacity * 2)
            : Color.black.opacity(resolvedSettings.backgroundOpacity)
    }

    private var borderColor: Color {
        Color(red: 196 / 255.0, green: 167 / 255.0, blue: 231 / 255.0)
    }

    var body: some View {
        HStack(spacing: workspaceSpacing) {
            ForEach(workspaceItems, id: \.id) { item in
                WorkspaceItemView(
                    item: item,
                    iconSize: iconSize,
                    itemHeight: itemHeight,
                    windowSpacing: windowSpacing,
                    cornerRadius: cornerRadius,
                    backgroundColor: backgroundColor,
                    activeBackgroundColor: activeBackgroundColor,
                    borderColor: borderColor,
                    showLabels: resolvedSettings.showLabels,
                    onFocusWorkspace: { focusWorkspace(item) },
                    onFocusWindow: { windowId in focusWindow(windowId) }
                )
            }
        }
        .padding(.horizontal, 4)
        .frame(height: itemHeight + 4)
    }

    private var workspaceItems: [WorkspaceBarItem] {
        controller.workspaceBarItems(
            for: monitor,
            deduplicate: resolvedSettings.deduplicateAppIcons,
            hideEmpty: resolvedSettings.hideEmptyWorkspaces
        )
    }

    private func focusWorkspace(_ item: WorkspaceBarItem) {
        controller.focusWorkspaceFromBar(named: item.name)
    }

    private func focusWindow(_ windowId: Int) {
        controller.focusWindowFromBar(windowId: windowId)
    }
}

@MainActor
private struct WorkspaceItemView: View {
    let item: WorkspaceBarItem
    let iconSize: CGFloat
    let itemHeight: CGFloat
    let windowSpacing: CGFloat
    let cornerRadius: CGFloat
    let backgroundColor: Color
    let activeBackgroundColor: Color
    let borderColor: Color
    let showLabels: Bool
    let onFocusWorkspace: () -> Void
    let onFocusWindow: (Int) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: windowSpacing) {
            if showLabels {
                Text(item.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(item.isFocused ? borderColor : .secondary)
                    .frame(minWidth: 16)

                if !item.windows.isEmpty {
                    Divider()
                        .frame(height: iconSize)
                        .padding(.horizontal, 2)
                }
            }

            ForEach(item.windows, id: \.id) { window in
                WindowIconView(
                    window: window,
                    iconSize: iconSize,
                    isFocused: window.isFocused,
                    isInFocusedWorkspace: item.isFocused,
                    onFocusWindow: onFocusWindow
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(height: itemHeight)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(item.isFocused ? activeBackgroundColor : (isHovered ? backgroundColor : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(item.isFocused ? borderColor : Color.clear, lineWidth: 1)
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            onFocusWorkspace()
        }
    }
}

@MainActor
private struct WindowIconView: View {
    let window: WorkspaceBarWindowItem
    let iconSize: CGFloat
    let isFocused: Bool
    let isInFocusedWorkspace: Bool
    let onFocusWindow: (Int) -> Void

    @State private var isHovered = false
    @State private var showingWindowList = false

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
                }
            }
            .frame(width: iconSize, height: iconSize)
            .opacity(opacity)

            if window.windowCount > 1 {
                Text("\(window.windowCount)")
                    .font(.system(size: max(8, iconSize * 0.4), weight: .bold))
                    .foregroundColor(.white)
                    .padding(2)
                    .background(
                        Circle()
                            .fill(Color.red)
                    )
                    .offset(x: iconSize * 0.2, y: -iconSize * 0.1)
            }
        }
        .scaleEffect(isHovered ? 1.1 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            if window.windowCount > 1 {
                showingWindowList = true
            } else {
                onFocusWindow(window.windowId)
            }
        }
        .sheet(isPresented: $showingWindowList) {
            WindowListSheet(
                windows: window.allWindows,
                appName: window.appName,
                onFocusWindow: { windowId in
                    onFocusWindow(windowId)
                    showingWindowList = false
                }
            )
        }
        .help(window.appName)
    }

    private var opacity: Double {
        if isFocused {
            1.0
        } else if isInFocusedWorkspace {
            0.6
        } else {
            0.8
        }
    }
}

@MainActor
private struct WindowListSheet: View {
    let windows: [WorkspaceBarWindowInfo]
    let appName: String
    let onFocusWindow: (Int) -> Void
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
                    onFocusWindow(windowInfo.windowId)
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
