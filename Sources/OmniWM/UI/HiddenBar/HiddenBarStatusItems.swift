// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

@MainActor
final class HiddenBarStatusItems {
    private let fallbackIcon = HiddenBarFallbackIconController()
    private weak var omniButton: NSStatusBarButton?
    private weak var omniStatusItem: NSStatusItem?
    var onFallbackIconClick: ((NSEvent, NSView) -> Void)?
    var fallbackPlacementsProvider: (() -> [HiddenBarFallbackIconPlacement])?
    private let hider: AssessmentModeHider

    init(hider: AssessmentModeHider) {
        self.hider = hider
    }

    func setClickHandler(_ handler: @escaping (NSEvent, NSView) -> Void) {
        fallbackIcon.onClick = handler
    }

    func dismiss() {
        fallbackIcon.dismiss()
    }

    func ownsStatusItemWindow(_ window: NSWindow) -> Bool {
        window === omniButton?.window || fallbackIcon.owns(window: window)
    }

    func bind(omniButton: NSStatusBarButton, statusItem: NSStatusItem) {
        self.omniButton = omniButton
        omniStatusItem = statusItem
        statusItem.isVisible = !hider.isConcealing
    }

    func handleConcealingChanged(_ concealing: Bool) {
        omniStatusItem?.isVisible = !concealing
        if concealing {
            syncFallbackIcon()
        } else {
            fallbackIcon.dismiss()
        }
    }

    func syncFallbackIcon() {
        guard hider.isConcealing,
              let placements = fallbackPlacementsProvider?(), !placements.isEmpty
        else {
            fallbackIcon.dismiss()
            return
        }
        fallbackIcon.show(placements: placements)
    }
}
