// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreText

struct NativeFullscreenPlaceholderUpdate: Equatable {
    let originalToken: WindowToken
    let currentToken: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    var frame: CGRect
    var displayContext: NativeFullscreenDisplayContext?
    let selected: Bool
    let visible: Bool
}

struct NativeFullscreenDisplayContext: Equatable {
    let workingFrame: CGRect
    let scale: CGFloat
}

enum NativeFullscreenPlaceholderGeometry {
    static func resolve(
        slotFrame: CGRect,
        workingFrame: CGRect
    ) -> CGRect? {
        guard isValid(slotFrame), isValid(workingFrame) else { return nil }
        let visibleIntersection = slotFrame.intersection(workingFrame)
        guard !visibleIntersection.isNull,
              !visibleIntersection.isEmpty,
              isValid(visibleIntersection)
        else { return nil }
        return slotFrame
    }

    private static func isValid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }
}

enum NativeFullscreenCaptureExclusionOutcome: String, Equatable {
    case failed
    case acceptedUnverified = "accepted_unverified"
    case verified

    static func resolve(writeAccepted: Bool, readback: Bool?) -> NativeFullscreenCaptureExclusionOutcome {
        guard writeAccepted else { return .failed }
        switch readback {
        case true:
            return .verified
        case nil:
            return .acceptedUnverified
        case false:
            return .failed
        }
    }
}

@MainActor
final class NativeFullscreenPlaceholderManager {
    var onActivate: ((WindowToken) -> Void)?
    var appInfoCache: AppInfoCache?

    private var windowsByOriginalToken: [WindowToken: NativeFullscreenPlaceholderWindow] = [:]

    func apply(_ placeholders: [NativeFullscreenPlaceholderUpdate], forceOrdering: Bool = false) {
        let desiredTokens = Set(placeholders.map(\.originalToken))
        let staleTokens = windowsByOriginalToken.keys.filter { !desiredTokens.contains($0) }
        for token in staleTokens {
            destroyPanel(originalToken: token)
        }

        for placeholder in placeholders {
            let window = windowsByOriginalToken[placeholder.originalToken] ?? makePanel(for: placeholder)
            window.update(placeholder, forceOrdering: forceOrdering)
        }
    }

    func moveForAnimation(_ placeholder: NativeFullscreenPlaceholderUpdate) {
        windowsByOriginalToken[placeholder.originalToken]?.moveForAnimation(
            slotFrame: placeholder.frame,
            displayContext: placeholder.displayContext
        )
    }

    func panelIdentity(for originalToken: WindowToken) -> ObjectIdentifier? {
        windowsByOriginalToken[originalToken].map(ObjectIdentifier.init)
    }

    func diagnosticsSnapshot() -> [NativeFullscreenPanelDiagnostics] {
        windowsByOriginalToken.values
            .map { $0.diagnosticsSnapshot() }
            .sorted {
                ($0.originalToken.pid, $0.originalToken.windowId)
                    < ($1.originalToken.pid, $1.originalToken.windowId)
            }
    }

    func removeAll() {
        for token in Array(windowsByOriginalToken.keys) {
            destroyPanel(originalToken: token)
        }
    }

    private func makePanel(for placeholder: NativeFullscreenPlaceholderUpdate) -> NativeFullscreenPlaceholderWindow {
        let appInfo = appInfoCache?.info(for: placeholder.currentToken.pid)
        let window = NativeFullscreenPlaceholderWindow(
            placeholder: placeholder,
            appName: appInfo?.name,
            icon: appInfo?.icon
        )
        window.onActivate = { [weak self] originalToken in
            self?.onActivate?(originalToken)
        }
        windowsByOriginalToken[placeholder.originalToken] = window
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                .panelCreated,
                originalToken: placeholder.originalToken,
                currentToken: placeholder.currentToken,
                workspaceId: placeholder.workspaceId,
                slotFrame: placeholder.frame,
                visible: false,
                windowNumber: window.windowNumber
            )
        )
        window.prepareSurface()
        return window
    }

    private func destroyPanel(originalToken: WindowToken) {
        windowsByOriginalToken.removeValue(forKey: originalToken)?.destroy()
    }
}
