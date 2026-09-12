// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Observation
import SwiftUI

struct CommandPaletteView: View {
    @Bindable var controller: CommandPaletteController
    @Bindable var motionPolicy: MotionPolicy

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                CommandPaletteModePicker(
                    selectedMode: controller.selectedMode,
                    isMenuModeAvailable: controller.isMenuModeAvailable,
                    onSelect: { controller.selectedMode = $0 }
                )

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField(searchPlaceholder, text: $controller.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                    if !controller.searchText.isEmpty {
                        Button(action: { controller.searchText = "" }, label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        })
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 8) {
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if controller.selectedMode == .clipboard,
                       controller.isClipboardHistoryEnabled,
                       !controller.clipboardItems.isEmpty
                    {
                        Button(action: { controller.clearClipboardHistory() }, label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12, weight: .semibold))
                        })
                        .buttonStyle(.plain)
                        .help("Clear Clipboard History")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if controller.selectedMode == .clipboard && !controller.isClipboardHistoryEnabled {
                CommandPaletteClipboardDisabledView {
                    controller.enableClipboardHistory()
                }
            } else if controller.selectedMode == .menu && controller.isMenuLoading {
                CommandPaletteLoadingView(text: "Loading menu items...")
            } else if isEmptyStateVisible {
                CommandPaletteEmptyStateView(
                    symbolName: emptyStateSymbol,
                    text: emptyStateText
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            switch controller.selectedMode {
                            case .windows:
                                ForEach(controller.filteredWindowItems) { item in
                                    CommandPaletteWindowRow(
                                        item: item,
                                        isSelected: controller.selectedItemID == .window(item.id),
                                        isSummonRightAvailable: controller.isSummonRightAvailable
                                            && CommandPalettePresentation.allowsSummonRight(item),
                                        onSelect: {
                                            controller.selectedItemID = .window(item.id)
                                            controller.selectCurrent()
                                        }
                                    )
                                    .id(CommandPaletteSelectionID.window(item.id))
                                }
                            case .menu:
                                ForEach(controller.filteredMenuItems) { item in
                                    CommandPaletteMenuRow(
                                        item: item,
                                        isSelected: controller.selectedItemID == .menu(item.id)
                                    )
                                    .id(CommandPaletteSelectionID.menu(item.id))
                                    .onTapGesture {
                                        controller.selectedItemID = .menu(item.id)
                                        controller.selectCurrent()
                                    }
                                }
                            case .clipboard:
                                ForEach(controller.filteredClipboardItems) { item in
                                    CommandPaletteClipboardRow(
                                        item: item,
                                        isSelected: controller.selectedItemID == .clipboard(item.id),
                                        onPaste: {
                                            controller.selectedItemID = .clipboard(item.id)
                                            controller.selectCurrent()
                                        },
                                        onCopy: {
                                            controller.copyClipboardItem(item.id)
                                        },
                                        onDelete: {
                                            controller.deleteClipboardItem(item.id)
                                        }
                                    )
                                    .id(CommandPaletteSelectionID.clipboard(item.id))
                                }
                            }
                        }
                    }
                    .onChange(of: controller.selectedItemID) { _, newValue in
                        if let newValue {
                            if motionPolicy.animationsEnabled {
                                withAnimation(.easeInOut(duration: 0.1)) {
                                    proxy.scrollTo(newValue, anchor: .center)
                                }
                            } else {
                                proxy.scrollTo(newValue, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 620, height: 430)
        .omniGlassEffect(in: RoundedRectangle(cornerRadius: 14))
    }

    private var searchPlaceholder: String {
        switch controller.selectedMode {
        case .windows:
            "Search windows..."
        case .menu:
            "Search menu items..."
        case .clipboard:
            "Search clipboard history..."
        }
    }

    private var statusText: String {
        switch controller.selectedMode {
        case .windows:
            CommandPalettePresentation.windowsStatusText(
                selectedItem: selectedWindowItem,
                isSummonRightAvailable: controller.isSummonRightAvailable
            )
        case .menu:
            controller.menuStatusText
        case .clipboard:
            controller.clipboardStatusText
        }
    }

    private var selectedWindowItem: CommandPaletteWindowItem? {
        guard case let .window(token)? = controller.selectedItemID else { return nil }
        return controller.windows.first { $0.id == token }
    }

    private var isEmptyStateVisible: Bool {
        switch controller.selectedMode {
        case .windows:
            controller.filteredWindowItems.isEmpty
        case .menu:
            !controller.isMenuLoading &&
                (!controller.isMenuModeAvailable || controller.filteredMenuItems.isEmpty)
        case .clipboard:
            controller.isClipboardHistoryEnabled && controller.filteredClipboardItems.isEmpty
        }
    }

    private var emptyStateSymbol: String {
        switch controller.selectedMode {
        case .windows:
            "macwindow.on.rectangle"
        case .menu:
            controller.isMenuModeAvailable ? "text.magnifyingglass" : "menubar.rectangle"
        case .clipboard:
            "clipboard"
        }
    }

    private var emptyStateText: String {
        switch controller.selectedMode {
        case .windows:
            return controller.searchText.isEmpty ? "No windows available" : "No windows found"
        case .menu:
            if !controller.isMenuModeAvailable {
                return controller.menuStatusText
            }
            return controller.searchText.isEmpty ? "No menu items available" : "No menu items found"
        case .clipboard:
            return controller.searchText.isEmpty ? "No clipboard items available" : "No clipboard items found"
        }
    }
}

struct CommandPaletteModePicker: View {
    let selectedMode: CommandPaletteMode
    let isMenuModeAvailable: Bool
    let onSelect: (CommandPaletteMode) -> Void

    private let trackColor = Color(red: 0.22, green: 0.22, blue: 0.22)
    private let selectedFillColor = Color(red: 0.49, green: 0.33, blue: 0.20)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CommandPaletteMode.allCases, id: \.self) { mode in
                modeButton(mode, enabled: mode != .menu || isMenuModeAvailable)
            }
        }
        .padding(4)
        .background(trackColor.opacity(0.92))
        .clipShape(Capsule())
    }

    private func modeButton(_ mode: CommandPaletteMode, enabled: Bool) -> some View {
        let hint = CommandPalettePresentation.modeHint(for: mode)
        let isSelected = selectedMode == mode
        return Button(action: { onSelect(mode) }, label: {
            HStack(spacing: 10) {
                Text(hint.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(tabTitleColor(isSelected: isSelected, enabled: enabled))
                Text(hint.shortcut)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tabShortcutColor(isSelected: isSelected, enabled: enabled))
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? selectedFillColor : Color.clear)
            .overlay {
                Capsule()
                    .strokeBorder(
                        isSelected ? selectedFillColor.opacity(0.95) : Color.clear,
                        lineWidth: 1
                    )
            }
            .clipShape(Capsule())
        })
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func tabTitleColor(isSelected: Bool, enabled: Bool) -> Color {
        if !enabled {
            return Color.white.opacity(0.38)
        }
        return isSelected ? .white : Color.white.opacity(0.92)
    }

    private func tabShortcutColor(isSelected: Bool, enabled: Bool) -> Color {
        if !enabled {
            return Color.white.opacity(0.32)
        }
        return isSelected ? Color.white.opacity(0.82) : Color.white.opacity(0.62)
    }
}

struct CommandPaletteShortcutBadge: View {
    let text: String
    var prominent = false
    var enabled = true

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .opacity(enabled ? 1 : 0.6)
    }

    private var foregroundColor: Color {
        enabled ? (prominent ? .primary : .secondary) : .secondary
    }

    private var backgroundColor: Color {
        prominent ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.14)
    }

    private var borderColor: Color {
        prominent ? Color.accentColor.opacity(0.22) : Color.clear
    }
}

struct CommandPaletteLoadingView: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            ProgressView()
                .scaleEffect(0.85)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CommandPaletteEmptyStateView: View {
    let symbolName: String
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Image(systemName: symbolName)
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 8)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CommandPaletteClipboardDisabledView: View {
    let onEnable: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clipboard")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text("Clipboard history is off")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Button(action: onEnable) {
                Label("Enable", systemImage: "power")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
