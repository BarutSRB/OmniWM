// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Observation
import SwiftUI

struct CommandPaletteWindowRow: View {
    let item: CommandPaletteWindowItem
    let isSelected: Bool
    let isSummonRightAvailable: Bool
    let onSelect: () -> Void

    private var summonHint: CommandPalettePresentation.InlineHint? {
        guard isSelected else { return nil }
        return CommandPalettePresentation.selectedWindowHint(isSummonRightAvailable: isSummonRightAvailable)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                if let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .frame(width: 32, height: 32)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Text(item.appName)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 8) {
                    if let summonHint {
                        Text(summonHint.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        CommandPaletteShortcutBadge(text: summonHint.shortcut)
                    }

                    if item.isAppHidden {
                        AppHiddenStatusBadge()
                    }

                    Text(item.workspaceName)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.18))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(item.isAppHidden
            ? "Unhides the app and focuses this window"
            : "Focuses this window")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var displayTitle: String {
        item.title.isEmpty ? item.appName : item.title
    }

    private var accessibilityLabel: String {
        displayTitle == item.appName ? item.appName : "\(displayTitle), \(item.appName)"
    }

    private var accessibilityValue: String {
        let workspace = "Workspace \(item.workspaceName)"
        return item.isAppHidden ? "App hidden, \(workspace)" : workspace
    }
}

struct CommandPaletteMenuRow: View {
    let item: MenuItemModel
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                if !item.parentTitles.isEmpty {
                    Text(item.parentTitles.joined(separator: " > "))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let shortcut = item.keyboardShortcut {
                CommandPaletteShortcutBadge(text: shortcut)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
    }
}

struct CommandPaletteClipboardRow: View {
    let item: ClipboardPaletteItem
    let isSelected: Bool
    let onPaste: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)
            .contentShape(Rectangle())
            .onTapGesture(perform: onPaste)

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Copy")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
            .foregroundColor(.secondary)
            .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
    }

    private var symbolName: String {
        switch item.kind {
        case .text:
            "text.alignleft"
        case .richText:
            "doc.richtext"
        case .html:
            "chevron.left.forwardslash.chevron.right"
        case .image:
            "photo"
        case .fileURL:
            "doc"
        }
    }
}
