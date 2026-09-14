// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

@MainActor
enum NativeFullscreenSurfaceTrace {
    static func traceProjectionAcceptedIfSignificant(
        _ update: NativeFullscreenSurfaceProjectionUpdate,
        previous: AcceptedNativeFullscreenSlotProjection?,
        isActive: Bool
    ) {
        let slots = update.slots
        let workspaceId = update.workspaceId
        let displayId = update.displayId
        let displayContext = update.displayContext
        guard isActive else { return }
        if let previous,
           previous.displayId == displayId,
           previous.displayContext == displayContext,
           previous.slots.count == slots.count,
           slots.allSatisfy({ originalToken, slot in
               guard let prior = previous.slots[originalToken] else { return false }
               return prior.currentToken == slot.currentToken && prior.visible == slot.visible
           })
        {
            return
        }
        guard !slots.isEmpty else {
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    .projectionAccepted,
                    workspaceId: workspaceId,
                    displayId: displayId,
                    workingFrame: displayContext.workingFrame,
                    scale: displayContext.scale,
                    reason: .accepted
                )
            )
            return
        }
        for (originalToken, slot) in slots {
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    .projectionAccepted,
                    originalToken: originalToken,
                    currentToken: slot.currentToken,
                    workspaceId: workspaceId,
                    displayId: displayId,
                    slotFrame: slot.frame,
                    workingFrame: displayContext.workingFrame,
                    scale: displayContext.scale,
                    visible: slot.visible,
                    reason: .accepted
                )
            )
        }
    }

    static func traceIncomingProjectionDiscarded(
        _ update: NativeFullscreenSurfaceProjectionUpdate,
        reason: NativeFullscreenPlaceholderTrace.Reason
    ) {
        let slots = update.slots
        let workspaceId = update.workspaceId
        let displayId = update.displayId
        let displayContext = update.displayContext
        guard NativeFullscreenPlaceholderTrace.isActive else { return }
        guard !slots.isEmpty else {
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    .projectionDiscarded,
                    workspaceId: workspaceId,
                    displayId: displayId,
                    workingFrame: displayContext.workingFrame,
                    scale: displayContext.scale,
                    reason: reason
                )
            )
            return
        }
        for (originalToken, slot) in slots {
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    .projectionDiscarded,
                    originalToken: originalToken,
                    currentToken: slot.currentToken,
                    workspaceId: workspaceId,
                    displayId: displayId,
                    slotFrame: slot.frame,
                    workingFrame: displayContext.workingFrame,
                    scale: displayContext.scale,
                    visible: slot.visible,
                    reason: reason
                )
            )
        }
    }

    static func traceSurfaceAppliedIfSignificant(
        _ applied: NativeFullscreenPlaceholderUpdate,
        previous: NativeFullscreenPlaceholderUpdate?,
        reason: NativeFullscreenPlaceholderTrace.Reason
    ) {
        guard NativeFullscreenPlaceholderTrace.isActive else { return }
        if let previous,
           previous.currentToken == applied.currentToken,
           previous.workspaceId == applied.workspaceId,
           previous.selected == applied.selected,
           previous.visible == applied.visible
        {
            return
        }
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                .surfaceApplied,
                originalToken: applied.originalToken,
                currentToken: applied.currentToken,
                workspaceId: applied.workspaceId,
                slotFrame: applied.frame,
                visible: applied.visible,
                selected: applied.selected,
                reason: reason
            )
        )
    }
}
