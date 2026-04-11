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
    let accentColorComponents: ColorComponents?
    let textColorComponents: ColorComponents?
    let labelFontSize: CGFloat

    var accentColor: Color? { accentColorComponents?.color }
    var textColor: Color? { textColorComponents?.color }
}

struct ColorComponents: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
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
    private var iconSize: CGFloat { max(12, itemHeight - 6) }
    private let workspaceSpacing: CGFloat = 8
    private let windowSpacing: CGFloat = 2
    private let cornerRadius: CGFloat = 6

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(snapshot.backgroundOpacity)
            : Color.black.opacity(snapshot.backgroundOpacity * 0.5)
    }

    var body: some View {
        HStack(spacing: workspaceSpacing) {
            ForEach(snapshot.items, id: \.id) { item in
                WorkspaceItemView(
                    item: item,
                    iconSize: iconSize,
                    itemHeight: itemHeight,
                    windowSpacing: windowSpacing,
                    cornerRadius: cornerRadius,
                    animationsEnabled: animationsEnabled,
                    showLabels: snapshot.showLabels,
                    accentColor: snapshot.accentColor,
                    textColor: snapshot.textColor,
                    labelFontSize: snapshot.labelFontSize,
                    onFocusWorkspace: { onFocusWorkspace(item) },
                    onFocusWindow: onFocusWindow
                )
            }
        }
        .padding(.horizontal, 4)
        .frame(height: itemHeight + 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        )
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
    let labelFontSize: CGFloat
    let onFocusWorkspace: () -> Void
    let onFocusWindow: (WindowToken) -> Void

    @State private var isHovered = false

    private var resolvedAccentColor: Color { accentColor ?? .accentColor }
    private var resolvedTextColor: Color { textColor ?? .primary }

    var body: some View {
        HStack(spacing: windowSpacing) {
            if showLabels {
                Text(item.name)
                    .font(.system(size: labelFontSize, weight: .medium, design: .monospaced))
                    .foregroundColor(item.isFocused ? resolvedAccentColor : (textColor?.opacity(0.6) ?? .secondary))
                    .frame(minWidth: 16)

                if !item.windows.isEmpty {
                    Divider()
                        .frame(height: iconSize)
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
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWindow: onFocusWindow
                )
            }

            if !item.tiledWindows.isEmpty && !item.floatingWindows.isEmpty {
                Divider()
                    .frame(height: iconSize)
                    .padding(.horizontal, 2)
            }

            ForEach(item.floatingWindows, id: \.id) { window in
                WindowIconView(
                    window: window,
                    iconSize: iconSize,
                    isFocused: window.isFocused,
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
        .background {
            if item.isFocused || isHovered {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.regularMaterial)
                    .overlay {
                        if item.isFocused {
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .strokeBorder(resolvedAccentColor, lineWidth: 1)
                        }
                    }
            }
        }
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
    let animationsEnabled: Bool
    let accentColor: Color?
    let textColor: Color?
    let onFocusWindow: (WindowToken) -> Void

    @State private var isHovered = false
    @State private var showingWindowList = false

    private var resolvedAccentColor: Color { accentColor ?? .accentColor }

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
            .shadow(color: resolvedAccentColor.opacity(glowOpacity), radius: glowRadius)

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
        .scaleEffect(scale)
        .animation(animationsEnabled ? .easeInOut(duration: 0.15) : nil, value: isFocused)
        .animation(animationsEnabled ? .easeInOut(duration: 0.1) : nil, value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
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
                textColor: textColor,
                onFocusWindow: { token in
                    onFocusWindow(token)
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
            0.4
        } else {
            0.5
        }
    }

    private var scale: CGFloat {
        if isFocused {
            1.1
        } else if isHovered {
            1.05
        } else {
            1.0
        }
    }

    private var glowRadius: CGFloat {
        isFocused ? 4 : 0
    }

    private var glowOpacity: Double {
        isFocused ? 0.5 : 0
    }
}

@MainActor
private struct WindowListSheet: View {
    let windows: [WorkspaceBarWindowInfo]
    let appName: String
    let textColor: Color?
    let onFocusWindow: (WindowToken) -> Void
    @Environment(\.dismiss) private var dismiss

    private var resolvedPrimaryTextColor: Color { textColor ?? .primary }
    private var resolvedSecondaryTextColor: Color {
        textColor?.opacity(0.6) ?? .secondary
    }

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
                            .foregroundColor(
                                windowInfo.isFocused ? resolvedPrimaryTextColor : resolvedSecondaryTextColor
                            )
                        Spacer()
                        if windowInfo.isFocused {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.accentColor)  // Sheet uses system accent
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 300, minHeight: 200)
    }
}
