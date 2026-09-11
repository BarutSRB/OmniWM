// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

@MainActor
struct NativeFullscreenPlaceholderResolver {
    let descriptor: NativeFullscreenPlaceholderUpdate
    let previous: NativeFullscreenPlaceholderUpdate?
    let currentToken: WindowToken
    let selected: Bool

    func resolveLifecycle(
        record: WorkspaceNativeFullscreenRecord,
        workspaceManager: WorkspaceManager
    ) -> NativeFullscreenPlaceholderResolution? {
        guard record.transition == .suspended else {
            return hidden(reason: .transitionPending)
        }
        guard workspaceManager.layoutReason(for: currentToken) == .nativeFullscreen else {
            return hidden(reason: .layoutNotNativeFullscreen)
        }
        let descriptorIsCurrent = descriptor.currentToken == currentToken
        let lifecycleVisible = if descriptorIsCurrent {
            descriptor.visible
        } else {
            previous?.visible == true
        }

        guard lifecycleVisible else {
            return hidden(reason: descriptorIsCurrent ? .descriptorHidden : .descriptorStale)
        }

        return nil
    }

    func resolveProjection(
        _ projection: AcceptedNativeFullscreenSlotProjection?,
        workspaceManager: WorkspaceManager
    ) -> NativeFullscreenPlaceholderResolution {
        guard let projection else {
            return retained(reason: previous?.visible == true ? .projectionMissingRetained : .projectionMissingHidden)
        }
        guard workspaceManager.monitor(for: descriptor.workspaceId)?.displayId == projection.displayId else {
            return hidden(reason: .displayMismatch)
        }
        guard let slot = projection.slots[descriptor.originalToken] else {
            return hidden(reason: .slotMissing)
        }
        guard slot.currentToken == currentToken else {
            return retained(reason: previous?.visible == true ? .slotTokenMismatchRetained : .slotTokenMismatchHidden)
        }

        return NativeFullscreenPlaceholderResolution(
            update: NativeFullscreenPlaceholderUpdate(
                originalToken: descriptor.originalToken,
                currentToken: currentToken,
                workspaceId: descriptor.workspaceId,
                frame: slot.frame,
                displayContext: projection.displayContext,
                selected: selected,
                visible: slot.visible
            ),
            reason: slot.visible ? .accepted : .slotHidden
        )
    }

    private func hidden(reason: NativeFullscreenPlaceholderTrace.Reason) -> NativeFullscreenPlaceholderResolution {
        NativeFullscreenPlaceholderResolution(
            update: Self.hidden(descriptor, currentToken: currentToken, selected: selected, previous: previous),
            reason: reason
        )
    }

    private func retained(reason: NativeFullscreenPlaceholderTrace.Reason) -> NativeFullscreenPlaceholderResolution {
        NativeFullscreenPlaceholderResolution(
            update: Self.retained(descriptor, currentToken: currentToken, selected: selected, previous: previous),
            reason: reason
        )
    }

    static func retained(
        _ descriptor: NativeFullscreenPlaceholderUpdate,
        currentToken: WindowToken,
        selected: Bool,
        previous: NativeFullscreenPlaceholderUpdate?
    ) -> NativeFullscreenPlaceholderUpdate {
        guard let previous, previous.visible else {
            return hidden(
                descriptor,
                currentToken: currentToken,
                selected: selected,
                previous: previous
            )
        }
        return NativeFullscreenPlaceholderUpdate(
            originalToken: descriptor.originalToken,
            currentToken: currentToken,
            workspaceId: descriptor.workspaceId,
            frame: previous.frame,
            displayContext: previous.displayContext,
            selected: selected,
            visible: true
        )
    }

    static func hidden(
        _ descriptor: NativeFullscreenPlaceholderUpdate,
        currentToken: WindowToken,
        selected: Bool,
        previous: NativeFullscreenPlaceholderUpdate?
    ) -> NativeFullscreenPlaceholderUpdate {
        NativeFullscreenPlaceholderUpdate(
            originalToken: descriptor.originalToken,
            currentToken: currentToken,
            workspaceId: descriptor.workspaceId,
            frame: previous?.frame ?? .zero,
            displayContext: previous?.displayContext,
            selected: selected,
            visible: false
        )
    }
}
