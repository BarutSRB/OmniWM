// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

struct StatusMenuDismissAction: Sendable {
    let dismiss: @MainActor () -> Void

    @MainActor
    func callAsFunction(then action: @escaping @MainActor () -> Void) {
        dismiss()
        Task { @MainActor in
            action()
        }
    }
}

extension EnvironmentValues {
    @Entry var statusMenuDismiss = StatusMenuDismissAction(dismiss: {})
}

let statusMenuWidth: CGFloat = 280

@MainActor
enum StatusMenuHost {
    static func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        return menu
    }

    static func makeHostedItem(dismissing rootMenu: NSMenu, content: some View) -> NSMenuItem {
        let dismiss = StatusMenuDismissAction(dismiss: { [weak rootMenu] in
            rootMenu?.cancelTracking()
        })
        let hostingView = NSHostingView(
            rootView: content
                .frame(width: statusMenuWidth)
                .environment(\.statusMenuDismiss, dismiss)
        )
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.setFrameSize(hostingView.fittingSize)
        let item = NSMenuItem()
        item.view = hostingView
        return item
    }

    static func prepareForDisplay(_ menus: [NSMenu], appearance: NSAppearance?) {
        for menu in menus {
            menu.appearance = appearance
            for item in menu.items {
                guard let view = item.view else { continue }
                view.appearance = appearance
                view.layoutSubtreeIfNeeded()
                view.setFrameSize(view.fittingSize)
            }
        }
    }
}
